import Foundation
import AppKit
import UniformTypeIdentifiers

struct EditorDoc: Identifiable {
    let path: String
    var text: String
    var id: String { path }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var connected = false
    @Published var portPath = ""
    @Published var currentPath = "/ext"
    @Published var entries: [FEntry] = []
    @Published var selection = Set<String>()
    @Published var logLines: [String] = []
    @Published var busy = false
    @Published var status = ""
    @Published var progress: Double?
    @Published var errorMessage: String?
    @Published var editor: EditorDoc?
    @Published var showConsole = true

    private var serial: FlipperSerial!
    private var watcher: Timer?

    init() {
        serial = FlipperSerial(log: { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        })
        watcher = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPort() }
        }
    }

    var root: String { currentPath.hasPrefix("/int") ? "/int" : "/ext" }

    func appendLog(_ s: String) {
        logLines.append(s)
        if logLines.count > 3000 { logLines.removeFirst(logLines.count - 3000) }
    }

    private func checkPort() {
        if connected && !FileManager.default.fileExists(atPath: portPath) { resetState(lostMessage: true) }
    }

    private func resetState(lostMessage: Bool) {
        let was = connected
        connected = false
        entries = []
        selection = []
        editor = nil
        progress = nil
        status = ""
        Task { await serial.disconnect() }
        if lostMessage && was { errorMessage = FlipperError.disconnected.errorDescription }
    }

    private var progressCB: @Sendable (Double) -> Void {
        { [weak self] p in Task { @MainActor in self?.progress = p } }
    }

    /// Последовательное выполнение операций с обработкой ошибок.
    func perform(_ label: String, _ op: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        status = label
        Task {
            do { try await op() } catch { handle(error) }
            busy = false
            progress = nil
            status = ""
        }
    }

    private func handle(_ error: Error) {
        if let e = error as? FlipperError, case .disconnected = e {
            resetState(lostMessage: true)
            return
        }
        errorMessage = error.localizedDescription
    }

    // MARK: - Подключение

    func toggleConnection() {
        if connected {
            resetState(lostMessage: false)
            return
        }
        perform("Подключение…") { [self] in
            guard let port = FlipperSerial.findPorts().first else { throw FlipperError.noPort }
            try await serial.connect(path: port)
            portPath = port
            connected = true
            try await loadDir(currentPath)
        }
    }

    // MARK: - Навигация

    private func loadDir(_ path: String) async throws {
        let list = try await serial.list(path)
        currentPath = path
        entries = list
        selection = []
    }

    func open(_ path: String) {
        guard connected else { return }
        perform("Чтение каталога…") { [self] in try await loadDir(path) }
    }

    func refresh() { open(currentPath) }

    func goUp() {
        guard currentPath != "/ext" && currentPath != "/int" else { return }
        let parent = (currentPath as NSString).deletingLastPathComponent
        open(parent.isEmpty ? "/" : parent)
    }

    func activate(_ ids: Set<String>) {
        guard ids.count == 1, let e = entries.first(where: { $0.id == ids.first }) else { return }
        if e.isDir { open(e.path) } else { edit(e) }
    }

    var selectedEntries: [FEntry] { entries.filter { selection.contains($0.id) } }

    // MARK: - Операции

    func mkdir(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        perform("Создание папки…") { [self] in
            try await serial.mkdir(joinPath(currentPath, n))
            try await loadDir(currentPath)
        }
    }

    func newFile(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        perform("Создание файла…") { [self] in
            try await serial.writeFile(joinPath(currentPath, n), Data(), progress: { _ in })
            try await loadDir(currentPath)
        }
    }

    func rename(_ e: FEntry, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != e.name else { return }
        perform("Переименование…") { [self] in
            try await serial.rename(e.path, joinPath(currentPath, n))
            try await loadDir(currentPath)
        }
    }

    func delete(_ items: [FEntry]) {
        guard !items.isEmpty else { return }
        perform("Удаление…") { [self] in
            for e in items { try await serial.remove(e) }
            try await loadDir(currentPath)
        }
    }

    func edit(_ e: FEntry) {
        guard !e.isDir else { return }
        if e.size > 1_000_000 { errorMessage = "Файл слишком большой для редактора"; return }
        perform("Чтение \(e.name)…") { [self] in
            let data = try await serial.readFile(e.path, progress: progressCB)
            guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
                throw FlipperError.storage("Файл \(e.name) не текстовый")
            }
            editor = EditorDoc(path: e.path, text: text)
        }
    }

    func save(_ doc: EditorDoc) {
        perform("Сохранение…") { [self] in
            try await serial.writeFile(doc.path, Data(doc.text.utf8), progress: progressCB)
            editor = nil
            try await loadDir(currentPath)
        }
    }

    // MARK: - Скачивание

    func download(_ items: [FEntry]) {
        guard !items.isEmpty else { return }
        if items.count == 1, !items[0].isDir {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = items[0].name
            guard panel.runModal() == .OK, let url = panel.url else { return }
            perform("Скачивание \(items[0].name)…") { [self] in
                let data = try await serial.readFile(items[0].path, progress: progressCB)
                try data.write(to: url)
            }
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Сохранить сюда"
            guard panel.runModal() == .OK, let dir = panel.url else { return }
            perform("Скачивание…") { [self] in try await downloadItems(items, to: dir) }
        }
    }

    private func downloadItems(_ items: [FEntry], to dir: URL) async throws {
        for e in items {
            let dest = dir.appendingPathComponent(e.name)
            if e.isDir {
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                try await downloadItems(try await serial.list(e.path), to: dest)
            } else {
                status = "Скачивание \(e.name)…"
                let data = try await serial.readFile(e.path, progress: progressCB)
                try data.write(to: dest)
            }
        }
    }

    // MARK: - Загрузка

    func uploadDialog() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        upload(panel.urls)
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard connected else { return false }
        let group = DispatchGroup()
        let box = URLBox()
        for p in providers where p.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { box.add(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            Task { @MainActor in self?.upload(box.urls) }
        }
        return true
    }

    func upload(_ urls: [URL]) {
        guard connected, !urls.isEmpty else { return }
        let dir = currentPath
        perform("Загрузка…") { [self] in
            try await uploadItems(urls, to: dir)
            try await loadDir(dir)
        }
    }

    private func uploadItems(_ urls: [URL], to dir: String) async throws {
        for u in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            let dest = joinPath(dir, u.lastPathComponent)
            if isDir.boolValue {
                try? await serial.mkdir(dest)
                let kids = try FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                try await uploadItems(kids, to: dest)
            } else {
                status = "Загрузка \(u.lastPathComponent)…"
                let data = try Data(contentsOf: u)
                try await serial.writeFile(dest, data, progress: progressCB)
            }
        }
    }
}

final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    func add(_ u: URL) { lock.lock(); _urls.append(u); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return _urls }
}

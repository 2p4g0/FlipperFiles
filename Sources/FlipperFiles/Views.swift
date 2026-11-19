import SwiftUI
import AppKit

@main
struct FlipperFilesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("FlipperFiles") {
            ContentView().environmentObject(model)
                .frame(minWidth: 800, minHeight: 500)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

enum InputKind: Equatable {
    case newFolder, newFile, rename(FEntry)
    var title: String {
        switch self {
        case .newFolder: return "Новая папка"
        case .newFile: return "Новый файл"
        case .rename: return "Переименовать"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var input: InputKind?
    @State private var inputText = ""
    @State private var confirmDelete = false
    @State private var dropTarget = false

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { model.root }, set: { if let r = $0 { model.open(r) } })) {
                Section("Flipper") {
                    Label("SD-карта /ext", systemImage: "sdcard").tag("/ext")
                    Label("Внутренняя /int", systemImage: "internaldrive").tag("/int")
                }
            }
            .disabled(!model.connected)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            VStack(spacing: 0) {
                pathBar
                Divider()
                fileTable
                if model.showConsole {
                    Divider()
                    ConsoleView()
                }
                Divider()
                statusBar
            }
            .overlay(dropTarget ? RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 3) : nil)
            .onDrop(of: [.fileURL], isTargeted: $dropTarget) { model.handleDrop($0) }
        }
        .toolbar { toolbar }
        .alert(input?.title ?? "", isPresented: Binding(get: { input != nil }, set: { if !$0 { input = nil } })) {
            TextField("Имя", text: $inputText)
            Button("OK") { submitInput() }
            Button("Отмена", role: .cancel) {}
        }
        .confirmationDialog("Удалить выбранное (\(model.selection.count))?", isPresented: $confirmDelete) {
            Button("Удалить", role: .destructive) { model.delete(model.selectedEntries) }
        }
        .sheet(item: $model.editor) { doc in EditorView(doc: doc) }
        .background(
            Color.clear.alert("Ошибка", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK") {}
            } message: { Text(model.errorMessage ?? "") }
        )
    }

    private var pathBar: some View {
        HStack {
            Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                .disabled(!model.connected || model.busy)
            Text(model.connected ? model.currentPath : "Не подключено")
                .font(.system(.body, design: .monospaced))
                .lineLimit(1).truncationMode(.head)
            Spacer()
        }
        .padding(8)
    }

    private var fileTable: some View {
        Table(model.entries, selection: $model.selection) {
            TableColumn("Имя") { e in
                Label(e.name, systemImage: e.isDir ? "folder.fill" : "doc")
            }
            TableColumn("Размер") { e in
                Text(e.isDir ? "—" : ByteCountFormatter.string(fromByteCount: e.size, countStyle: .file))
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 100, max: 140)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let items = model.entries.filter { ids.contains($0.id) }
            if items.count == 1, let e = items.first {
                if e.isDir { Button("Открыть") { model.open(e.path) } } else { Button("Редактировать") { model.edit(e) } }
                Button("Переименовать…") { inputText = e.name; input = .rename(e) }
            }
            if !items.isEmpty {
                Button("Скачать на Mac…") { model.download(items) }
                Divider()
                Button("Удалить", role: .destructive) { model.selection = ids; confirmDelete = true }
            }
        } primaryAction: { ids in
            model.activate(ids)
        }
        .disabled(model.busy)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle().fill(model.connected ? Color.green : Color.red).frame(width: 8, height: 8)
            Text(model.connected ? model.portPath : "Отключено").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if model.busy {
                Text(model.status).font(.caption).lineLimit(1)
                if let p = model.progress {
                    ProgressView(value: p).frame(width: 180)
                    Text("\(Int(p * 100))%").font(.caption).monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button { model.toggleConnection() } label: {
                Label(model.connected ? "Отключить" : "Подключить", systemImage: model.connected ? "cable.connector.slash" : "cable.connector")
            }
            .disabled(model.busy && !model.connected)
            Button { model.refresh() } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                .disabled(!model.connected || model.busy)
            Button { inputText = ""; input = .newFolder } label: { Label("Новая папка", systemImage: "folder.badge.plus") }
                .disabled(!model.connected || model.busy)
            Button { inputText = ""; input = .newFile } label: { Label("Новый файл", systemImage: "doc.badge.plus") }
                .disabled(!model.connected || model.busy)
            Button { model.uploadDialog() } label: { Label("Загрузить", systemImage: "square.and.arrow.up") }
                .disabled(!model.connected || model.busy)
            Button { model.download(model.selectedEntries) } label: { Label("Скачать", systemImage: "square.and.arrow.down") }
                .disabled(!model.connected || model.busy || model.selection.isEmpty)
            Button { confirmDelete = true } label: { Label("Удалить", systemImage: "trash") }
                .disabled(!model.connected || model.busy || model.selection.isEmpty)
            Button { model.showConsole.toggle() } label: { Label("Консоль", systemImage: "terminal") }
        }
    }

    private func submitInput() {
        guard let kind = input else { return }
        switch kind {
        case .newFolder: model.mkdir(inputText)
        case .newFile: model.newFile(inputText)
        case .rename(let e): model.rename(e, to: inputText)
        }
    }
}

struct ConsoleView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Консоль").font(.caption.bold())
                Spacer()
                Button("Очистить") { model.logLines.removeAll() }.buttonStyle(.borderless).font(.caption)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.logLines.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: model.logLines.count) { proxy.scrollTo("end") }
            }
        }
        .frame(height: 170)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct EditorView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var doc: EditorDoc

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(doc.path).font(.system(.headline, design: .monospaced)).lineLimit(1).truncationMode(.head)
                Spacer()
                if model.busy, let p = model.progress { ProgressView(value: p).frame(width: 120) }
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить на Flipper") { model.save(doc) }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.busy)
            }
            .padding(10)
            Divider()
            TextEditor(text: $doc.text)
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
        }
        .frame(minWidth: 750, minHeight: 520)
    }
}

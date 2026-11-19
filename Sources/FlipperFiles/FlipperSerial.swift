import Foundation
import Darwin

enum FlipperError: LocalizedError {
    case noPort, openFailed(String), notConnected, timeout, disconnected, storage(String)

    var errorDescription: String? {
        switch self {
        case .noPort: return "Flipper не найден (/dev/cu.usbmodemflip*)"
        case .openFailed(let s): return "Не удалось открыть порт: \(s)"
        case .notConnected: return "Нет подключения"
        case .timeout: return "Таймаут ответа Flipper"
        case .disconnected: return "Flipper отключён"
        case .storage(let s): return s
        }
    }
}

struct FEntry: Identifiable, Hashable {
    let name: String
    let isDir: Bool
    let size: Int64
    let path: String
    var id: String { path }
}

func joinPath(_ dir: String, _ name: String) -> String {
    dir.hasSuffix("/") ? dir + name : dir + "/" + name
}

/// Весь последовательный I/O с Flipper CLI.
actor FlipperSerial {
    private var fd: Int32 = -1
    private var buf = Data()
    private let prompt = Data("\n>: ".utf8)
    private let chunk = 512
    nonisolated let log: @Sendable (String) -> Void

    init(log: @escaping @Sendable (String) -> Void) { self.log = log }

    static func findPorts() -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return items.filter { $0.hasPrefix("cu.usbmodemflip") }.sorted().map { "/dev/" + $0 }
    }

    // MARK: - Порт

    func connect(path: String) throws {
        closePort()
        let f = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard f >= 0 else { throw FlipperError.openFailed(String(cString: strerror(errno))) }
        var t = termios()
        tcgetattr(f, &t)
        cfmakeraw(&t)
        cfsetspeed(&t, speed_t(230400))
        t.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CSIZE | CRTSCTS)
        t.c_cflag |= tcflag_t(CS8 | CLOCAL | CREAD)
        tcsetattr(f, TCSANOW, &t)
        tcflush(f, TCIOFLUSH)
        fd = f
        buf.removeAll()
        log("Открыт \(path)")
        do {
            try writeRaw(Data([0x03]))
            try writeRaw(Data("\r".utf8))
            _ = try readUntil(prompt, timeout: 5)
            drain(0.3)
            log("Подключено")
        } catch {
            closePort()
            throw error
        }
    }

    func disconnect() {
        if fd >= 0 { log("Отключено") }
        closePort()
    }

    private func closePort() {
        if fd >= 0 { close(fd) }
        fd = -1
        buf.removeAll()
    }

    private func lost() -> FlipperError {
        closePort()
        log("Связь потеряна")
        return .disconnected
    }

    private func fill(timeout: Double) throws -> Bool {
        guard fd >= 0 else { throw FlipperError.notConnected }
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let r = poll(&p, 1, Int32(max(0, timeout) * 1000))
        if r < 0 { if errno == EINTR { return false }; throw lost() }
        if r == 0 { return false }
        if p.revents & Int16(POLLIN) == 0 && p.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { throw lost() }
        var tmp = [UInt8](repeating: 0, count: 8192)
        let n = read(fd, &tmp, tmp.count)
        if n > 0 { buf.append(contentsOf: tmp[0..<n]); return true }
        if n < 0 && (errno == EAGAIN || errno == EINTR) { return false }
        throw lost()
    }

    private func drain(_ t: Double) {
        let end = Date().addingTimeInterval(t)
        while Date() < end, (try? fill(timeout: end.timeIntervalSinceNow)) != nil {}
        buf.removeAll()
    }

    private func writeRaw(_ d: Data) throws {
        guard fd >= 0 else { throw FlipperError.notConnected }
        var off = 0
        let deadline = Date().addingTimeInterval(10)
        try d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while off < d.count {
                let n = write(fd, base + off, d.count - off)
                if n > 0 { off += n; continue }
                if n < 0 && (errno == EAGAIN || errno == EINTR) {
                    if Date() > deadline { throw FlipperError.timeout }
                    var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&p, 1, 100)
                    continue
                }
                throw lost()
            }
        }
    }

    /// Ждёт первый из шаблонов; возвращает (индекс шаблона, данные до конца совпадения).
    private func readUntilAny(_ pats: [Data], timeout: Double) throws -> (Int, Data) {
        let end = Date().addingTimeInterval(timeout)
        while true {
            var best: (Int, Range<Data.Index>)?
            for (i, p) in pats.enumerated() {
                if let r = buf.range(of: p), best == nil || r.lowerBound < best!.1.lowerBound { best = (i, r) }
            }
            if let (i, r) = best {
                let out = Data(buf[buf.startIndex..<r.upperBound])
                buf = Data(buf[r.upperBound...])
                return (i, out)
            }
            let left = end.timeIntervalSinceNow
            if left <= 0 { throw FlipperError.timeout }
            _ = try fill(timeout: min(left, 0.5))
        }
    }

    private func readUntil(_ p: Data, timeout: Double) throws -> Data {
        try readUntilAny([p], timeout: timeout).1
    }

    private func readExact(_ n: Int, timeout: Double) throws -> Data {
        let end = Date().addingTimeInterval(timeout)
        while buf.count < n {
            let left = end.timeIntervalSinceNow
            if left <= 0 { throw FlipperError.timeout }
            _ = try fill(timeout: min(left, 0.5))
        }
        let out = Data(buf.prefix(n))
        buf = Data(buf.dropFirst(n))
        return out
    }

    private func q(_ p: String) -> String { "\"\(p)\"" }

    private func send(_ cmd: String) throws {
        guard fd >= 0 else { throw FlipperError.notConnected }
        buf.removeAll()
        log("> \(cmd)")
        try writeRaw(Data((cmd + "\r").utf8))
    }

    /// Текстовая часть ответа без эха и приглашения.
    private func clean(_ d: Data) -> String {
        var s = String(decoding: d, as: UTF8.self)
        if s.hasSuffix(">: ") { s.removeLast(3) }
        var lines = s.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        if !lines.isEmpty { lines.removeFirst() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isError(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.contains("storage error") || l.contains("error") || l.contains("usage:") || l.contains("invalid")
    }

    @discardableResult
    func run(_ cmd: String, timeout: Double = 15) throws -> String {
        try send(cmd)
        let out = clean(try readUntil(prompt, timeout: timeout))
        if !out.isEmpty { log(out.count > 4000 ? String(out.prefix(4000)) + "…" : out) }
        return out
    }

    private func storageCmd(_ cmd: String) throws -> String {
        let out = try run(cmd)
        if isError(out) { throw FlipperError.storage(out) }
        return out
    }

    // MARK: - Storage

    func list(_ path: String) throws -> [FEntry] {
        let out = try storageCmd("storage list \(q(path))")
        var res: [FEntry] = []
        for raw in out.split(separator: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("[D] ") {
                let name = String(l.dropFirst(4))
                res.append(FEntry(name: name, isDir: true, size: 0, path: joinPath(path, name)))
            } else if l.hasPrefix("[F] ") {
                let rest = String(l.dropFirst(4))
                var name = rest
                var size: Int64 = 0
                if let sp = rest.lastIndex(of: " ") {
                    let s = rest[rest.index(after: sp)...]
                    if s.hasSuffix("b"), let n = Int64(s.dropLast()) {
                        name = String(rest[..<sp]); size = n
                    }
                }
                res.append(FEntry(name: name, isDir: false, size: size, path: joinPath(path, name)))
            }
        }
        return res.sorted { $0.isDir != $1.isDir ? $0.isDir : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func mkdir(_ path: String) throws { _ = try storageCmd("storage mkdir \(q(path))") }

    func rename(_ from: String, _ to: String) throws { _ = try storageCmd("storage rename \(q(from)) \(q(to))") }

    func remove(_ e: FEntry) throws {
        if e.isDir {
            for c in try list(e.path) { try remove(c) }
        }
        _ = try storageCmd("storage remove \(q(e.path))")
    }

    func readFile(_ path: String, progress: @Sendable (Double) -> Void) throws -> Data {
        try send("storage read_chunks \(q(path)) \(chunk)")
        let (i, head) = try readUntilAny([Data("Size: ".utf8), prompt], timeout: 10)
        if i == 1 { let e = clean(head); log(e); throw FlipperError.storage(e.isEmpty ? "Ошибка чтения" : e) }
        let sizeLine = String(decoding: try readUntil(Data("\r\n".utf8), timeout: 5), as: UTF8.self)
        guard let total = Int(sizeLine.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw FlipperError.storage("Некорректный ответ: Size: \(sizeLine)")
        }
        log("Size: \(total)")
        var out = Data(capacity: total)
        progress(0)
        while out.count < total {
            _ = try readUntil(Data("Ready?\r\n".utf8), timeout: 10)
            try writeRaw(Data("y".utf8))
            out.append(try readExact(min(chunk, total - out.count), timeout: 10))
            progress(Double(out.count) / Double(max(total, 1)))
        }
        _ = try readUntil(prompt, timeout: 10)
        log("Прочитано \(total) байт")
        return out
    }

    func writeFile(_ path: String, _ data: Data, progress: @Sendable (Double) -> Void) throws {
        _ = try run("storage remove \(q(path))")
        var off = 0
        progress(0)
        repeat {
            let part = data.subdata(in: off..<min(off + chunk, data.count))
            try send("storage write_chunk \(q(path)) \(part.count)")
            let (i, head) = try readUntilAny([Data("Ready\r\n".utf8), prompt], timeout: 10)
            if i == 1 { let e = clean(head); log(e); throw FlipperError.storage(e.isEmpty ? "Ошибка записи" : e) }
            try writeRaw(part)
            let tail = clean(Data("x\n".utf8) + (try readUntil(prompt, timeout: 15)))
            if isError(tail) { log(tail); throw FlipperError.storage(tail) }
            off += part.count
            progress(Double(off) / Double(max(data.count, 1)))
        } while off < data.count
        log("Записано \(data.count) байт")
    }
}

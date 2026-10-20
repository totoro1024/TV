import Foundation
import Network
import TVCore
import Darwin

/// 仅向局域网提供随机地址下的 HLS 文件，不转发 Cookie、签名下载地址或任意本地文件。
final class AirPlayHLSBridge: @unchecked Sendable {
    private final class Job: @unchecked Sendable {
        let pointer: OpaquePointer
        init(input: URL, directory: URL, start: Double) throws {
            guard let pointer = TVRemuxCreate(input.absoluteString, directory.path, max(0, start)) else { throw TVError.message("无法创建投放任务") }
            self.pointer = pointer
        }
        deinit { TVRemuxDestroy(pointer) }
        func cancel() { TVRemuxCancel(pointer) }
    }
    private let directory: URL
    private let path = "/" + UUID().uuidString + "/"
    private let source: QuarkStreamProxy?
    private let localInput: URL?
    private let listener: NWListener
    private let queue = DispatchQueue(label: "tv.airplay.hls")
    private let lock = NSLock()
    private var job: Job?
    private var connections: [NWConnection] = []
    private var stopped = false
    private var result: Int32?
    private var startCompleted = false
    private var readyContinuation: CheckedContinuation<URL, Error>?
    private var address = ""
    func updatePlaybackTime(_ seconds: Double) { lock.withLock { if let job { TVRemuxPlaybackTime(job.pointer, seconds) } } }
    var baseTime: Double { lock.withLock { job.map { TVRemuxStartTime($0.pointer) } ?? 0 } }
    var duration: Double { lock.withLock { job.map { TVRemuxDuration($0.pointer) } ?? 0 } }
    var failure: Int32? { lock.withLock { result.flatMap { $0 < 0 ? $0 : nil } } }
    init(media: ResolvedMedia) throws {
        source = try QuarkStreamProxy(media: media)
        localInput = nil
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AirPlay-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        listener = try NWListener(using: .tcp)
    }
    /// 海绵等站点仅在本机重新封装，不为本地播放打开局域网服务。
    init(localInput: URL) throws {
        guard localInput.host == "127.0.0.1",localInput.scheme == "http" else { throw TVError.message("本地封装输入地址无效") }
        source = nil; self.localInput = localInput
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalHLS-" + UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:.ipv4(.loopback),port:.any)
        listener = try NWListener(using:parameters)
    }
    func start(at seconds: Double) async throws -> URL {
        do {
            let input:URL
            if let localInput { input = localInput }
            else if let source { input = try await source.start() }
            else { throw TVError.message("播放封装输入未就绪") }
            let job = try Job(input: input, directory: directory, start: seconds)
            lock.withLock { self.job = job }
            DispatchQueue.global(qos: .userInitiated).async { [self, job] in
                let result = TVRemuxRun(job.pointer)
                lock.withLock { self.result = result }
                if lock.withLock({ stopped }) { try? FileManager.default.removeItem(at: directory) }
            }
            let url: URL = try await withCheckedThrowingContinuation { continuation in
                lock.withLock { readyContinuation = continuation }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        let host = localInput == nil ? (Self.localIPv4() ?? "127.0.0.1") : "127.0.0.1"
                        address = "http://\(host):\(listener.port!.rawValue)\(path)"
                        finishStart(.success(URL(string: address + "index.m3u8")!))
                    case .failed, .cancelled: finishStart(.failure(TVError.message("投放服务无法启动，请允许局域网访问")))
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self, !self.lock.withLock({ self.stopped }) else { connection.cancel(); return }
                    self.lock.withLock { self.connections.append(connection) }
                    connection.start(queue: queue)
                    receive(connection, buffer: Data())
                }
                listener.start(queue: queue)
            }
            for _ in 0..<120 {
                try Task.checkCancellation()
                if let code = failure { throw TVError.message(code == -38 ? "此原画编码暂不支持直接投放（需 H.264/HEVC 与 AAC）" : "投放流封装失败，请检查网络和剩余空间") }
                let file = directory.appendingPathComponent("index.m3u8")
                if let text = try? String(contentsOf: file, encoding: .utf8), text.contains("#EXTINF:"), text.contains("segment-") { return url }
                try await Task.sleep(for: .milliseconds(500))
            }
            throw TVError.message("投放流准备超时，请检查网络后重试")
        } catch { stop(); throw error }
    }
    private func finishStart(_ value: Result<URL, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            guard !startCompleted else { return nil }; startCompleted = true
            defer { readyContinuation = nil }; return readyContinuation
        }
        continuation?.resume(with: value)
    }
    func stop() {
        let state = lock.withLock { () -> (Job?, [NWConnection], Bool) in
            guard !stopped else { return (nil, [], false) }; stopped = true
            let active = connections; connections = []; return (job, active, true)
        }
        guard state.2 else { return }
        state.0?.cancel(); source?.stop(); listener.cancel(); state.1.forEach { $0.cancel() }
        finishStart(.failure(CancellationError()))
        // 工作线程结束后再清理仍在写入的文件。
        if lock.withLock({ result != nil || job == nil }) { try? FileManager.default.removeItem(at: directory) }
    }
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = buffer; buffer.append(data ?? Data())
            guard buffer.count <= 8192 else { connection.cancel(); return }
            if let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") {
                Task { await self.respond(connection, request: request) }
            } else if !complete { receive(connection, buffer: buffer) } else { connection.cancel() }
        }
    }
    private func send(_ connection: NWConnection, data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in if let error { c.resume(throwing: error) } else { c.resume() } })
        }
    }
    private func respond(_ connection: NWConnection, request: String) async {
        defer {
            connection.cancel()
            lock.withLock { connections.removeAll { $0 === connection } }
        }
        do {
            let lines = request.components(separatedBy: "\r\n"), words = (lines.first ?? "").split(separator: " ")
            guard words.count == 3, ["GET", "HEAD"].contains(String(words[0])), String(words[1]).hasPrefix(path) else { return }
            let name = String(words[1].dropFirst(path.count))
            guard name == "index.m3u8" || name == "init.mp4" || name.range(of: #"^segment-[0-9]{6}\.(?:ts|m4s)$"#, options: .regularExpression) != nil else { return }
            let file = directory.appendingPathComponent(name)
            guard let handle = try? FileHandle(forReadingFrom: file) else {
                try await send(connection, data: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)); return
            }
            defer { try? handle.close() }
            let size = Int(try handle.seekToEnd())
            // 打开后读取同一 inode 的长度，避免播放清单原子更新时截断响应。
            guard size > 0, size <= 64 * 1024 * 1024 else { return }
            let rawRange = lines.first { $0.lowercased().hasPrefix("range:") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            let range = try StreamByteRange(header: rawRange, size: Int64(size), offset: 0)
            let type = name.hasSuffix("m3u8") ? "application/vnd.apple.mpegurl" : name.hasSuffix("ts") ? "video/mp2t" : "video/mp4"
            let partial = rawRange != nil
            let extra = partial ? "Content-Range: bytes \(range.start)-\(range.end)/\(size)\r\n" : ""
            let header = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\nContent-Type: \(type)\r\nCache-Control: no-store\r\nAccept-Ranges: bytes\r\n\(extra)Content-Length: \(range.end - range.start + 1)\r\nConnection: close\r\n\r\n"
            try handle.seek(toOffset: UInt64(range.start))
            try await send(connection, data: Data(header.utf8))
            if words[0] == "HEAD" { return }
            var remaining = range.end - range.start + 1
            while remaining > 0 && !self.lock.withLock({ self.stopped }) {
                guard let data = try handle.read(upToCount: Int(min(remaining, 128 * 1024))), !data.isEmpty else { return }
                try await send(connection, data: data); remaining -= Int64(data.count)
            }
        } catch { }
    }
    private static func localIPv4() -> String? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return nil }; defer { freeifaddrs(first) }
        var cursor = first
        while let pointer = cursor {
            let item = pointer.pointee; defer { cursor = item.ifa_next }
            guard let addr = item.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), String(cString: item.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { return String(cString: host) }
        }
        return nil
    }
}

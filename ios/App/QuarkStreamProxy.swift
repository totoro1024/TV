import Foundation
import Network
import TVCore

/// 仅绑定回环地址。按 Range 去掉玩偶图片前缀，Cookie 只发往已解析的夸克地址。
final class QuarkStreamProxy: @unchecked Sendable {
    private let media: ResolvedMedia
    private let listener: NWListener
    private let path = "/" + UUID().uuidString + "/movie.mkv"
    private let queue = DispatchQueue(label: "tv.quark.stream")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var tasks: [Task<Void, Never>] = []
    private var startCompleted = false
    private let session: URLSession
    init(media: ResolvedMedia) throws {
        self.media = media
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 3600
        session = URLSession(configuration: config, delegate: StreamRedirectBlocker(), delegateQueue: nil)
    }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.lock.lock(); defer { self.lock.unlock() }
                guard !self.startCompleted else { return }
                switch state {
                case .ready:
                    self.startCompleted = true
                    let local = URL(string: "http://127.0.0.1:\(self.listener.port!.rawValue)\(self.path)")!
                    continuation.resume(returning: local)
                case .failed, .cancelled:
                    self.startCompleted = true; continuation.resume(throwing: TVError.message("本地播放流启动失败"))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.lock.lock(); self.connections.append(connection); self.lock.unlock()
                connection.start(queue: self.queue)
                self.receive(connection, buffer: Data())
            }
            listener.start(queue: queue)
        }
    }
    func stop() {
        listener.cancel(); session.invalidateAndCancel()
        lock.lock(); let active = connections; connections = []; let jobs = tasks; tasks = []; lock.unlock()
        active.forEach { $0.cancel() }; jobs.forEach { $0.cancel() }
    }
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = buffer; buffer.append(data ?? Data())
            if buffer.count > 16384 { connection.cancel(); return }
            if let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") {
                let task = Task { await self.respond(connection, request: text) }
                self.lock.lock(); self.tasks.append(task); self.lock.unlock()
            } else if !done { self.receive(connection, buffer: buffer) }
            else { connection.cancel() }
        }
    }
    private func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    private func respond(_ connection: NWConnection, request: String) async {
        defer { connection.cancel() }
        do {
            let lines = request.components(separatedBy: "\r\n")
            let words = (lines.first ?? "").split(separator: " ")
            guard words.count == 3, String(words[1]) == path, ["GET","HEAD"].contains(String(words[0])) else { return }
            let requested = lines.first(where: { $0.lowercased().hasPrefix("range:") }).map { $0.dropFirst(6).trimmingCharacters(in: .whitespaces) }
            let range = try StreamByteRange(header: requested, size: media.size, offset: media.byteOffset)
            let start = range.start, end = range.end, length = range.length
            let header = "HTTP/1.1 206 Partial Content\r\nContent-Type: video/x-matroska\r\nAccept-Ranges: bytes\r\nContent-Range: bytes \(start)-\(end)/\(length)\r\nContent-Length: \(end-start+1)\r\nConnection: close\r\n\r\n"
            if words[0] == "HEAD" { try await send(connection, Data(header.utf8)); return }
            try await send(connection, Data(header.utf8))
            var cursor = start
            let chunkSize: Int64 = 2 * 1024 * 1024
            var pending: Task<Data, Error>? = Task { try await self.chunk(start: start, end: min(end, start + chunkSize - 1)) }
            defer { pending?.cancel() }
            while cursor <= end {
                try Task.checkCancellation()
                guard let job = pending else { break }
                let data = try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
                cursor += Int64(data.count)
                if cursor <= end {
                    let next = cursor
                    pending = Task { try await self.chunk(start: next, end: min(end, next + chunkSize - 1)) }
                } else { pending = nil }
                try await send(connection, data)
            }

        } catch { /* 播放器关闭连接属于正常取消；不记录签名地址和请求头。 */ }
    }
    private func chunk(start: Int64, end: Int64) async throws -> Data {
        var request = URLRequest(url: URL(string: media.url)!)
        request.allHTTPHeaderFields = media.headers
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("bytes=\(start + media.byteOffset)-\(end + media.byteOffset)", forHTTPHeaderField: "Range")
        let (data, reply) = try await session.data(for: request)
        guard let response = reply as? HTTPURLResponse, response.statusCode == 206,
              response.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes \(start + media.byteOffset)-") == true,
              data.count == Int(end-start+1) else { throw TVError.message("原画分段读取失败") }
        return data
    }

}
private final class StreamRedirectBlocker: NSObject, URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        completionHandler(response.expectedContentLength >= 0 && response.expectedContentLength <= 2 * 1024 * 1024 ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

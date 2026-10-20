import Foundation
import Network
import TVCore

/// 网页 HLS 清单与图片伪装分片适配；仅监听回环地址。
final class WebsiteHLSProxy: @unchecked Sendable {
    private let listener: NWListener
    private let media: ResolvedMedia
    private let origin: URL
    private let session: URLSession
    private let queue = DispatchQueue(label: "tv.website.hls")
    private let lock = NSLock()
    private var routes: [String: URL] = [:]
    private var connections: [NWConnection] = []
    private var jobs: [Task<Void, Never>] = []
    private var started = false
    private let prefix = "/" + UUID().uuidString + "/"
    init(media: ResolvedMedia) throws {
        guard let url = URL(string: media.url) else { throw TVError.message("网页播放参数无效") }
        self.media = media; self.origin = url
        let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        let config = URLSessionConfiguration.ephemeral; config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 45
        session = URLSession(configuration: config,delegate:WebsiteHLSRedirectBlocker(),delegateQueue:nil)
        routes[prefix + "index.m3u8"] = url
    }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }; self.lock.lock(); defer { self.lock.unlock() }
                guard !self.started else { return }
                switch state {
                case .ready:
                    self.started = true
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(self.listener.port!.rawValue)\(self.prefix)index.m3u8")!)
                case .failed, .cancelled: self.started = true; continuation.resume(throwing: TVError.message("网页本地播放服务启动失败"))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.lock.withLock { self.connections.append(connection) }
                connection.start(queue: self.queue); self.receive(connection, data: Data())
            }
            listener.start(queue: queue)
        }
    }
    func stop() {
        listener.cancel(); session.invalidateAndCancel()
        let active = lock.withLock { let result = (connections, jobs); connections = []; jobs = []; routes = [:]; return result }
        active.0.forEach { $0.cancel() }; active.1.forEach { $0.cancel() }
    }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] next, _, done, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = data; buffer.append(next ?? Data())
            guard buffer.count <= 16384 else { connection.cancel(); return }
            if let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") {
                let job = Task { await self.respond(connection, request: text) }; self.lock.withLock { self.jobs.append(job) }
            } else if !done { self.receive(connection, data: buffer) } else { connection.cancel() }
        }
    }
    private func local(_ remote: URL) throws -> String {
        guard ["http", "https"].contains(remote.scheme?.lowercased() ?? ""), let host = remote.host, !host.isEmpty, host != "localhost", host != "127.0.0.1" else { throw TVError.message("网页媒体子地址无效") }
        return try lock.withLock {
            if let path = routes.first(where: { $0.value == remote })?.key { return "http://127.0.0.1:\(listener.port!.rawValue)" + path }
            guard routes.count < 50000 else { throw TVError.message("网页清单条目过多") }
            let ext = remote.pathExtension.lowercased()
            let path = prefix + UUID().uuidString + "." + (["png","jpg","jpeg"].contains(ext) ? "ts" : ext.isEmpty ? "bin" : ext)
            routes[path] = remote
            return "http://127.0.0.1:\(listener.port!.rawValue)" + path
        }
    }
    private func rewrite(_ data: Data, base: URL) throws -> Data {
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else { throw TVError.message("网页媒体清单无效") }
        let regex = try NSRegularExpression(pattern: #"URI="([^"]+)""#)
        let lines = try text.components(separatedBy: .newlines).map { line -> String in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { return line }
            if !value.hasPrefix("#") {
                guard let url = URL(string: value, relativeTo: base)?.absoluteURL else { throw TVError.message("网页清单地址无效") }
                return try local(url)
            }
            var result = line
            for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
                guard let range = Range(match.range(at: 1), in: line), let url = URL(string: String(line[range]), relativeTo: base)?.absoluteURL else { continue }
                result.replaceSubrange(range, with: try local(url))
            }
            return result
        }
        return Data(lines.joined(separator: "\n").utf8)
    }
    private func respond(_ connection: NWConnection, request: String) async {
        defer { connection.cancel() }
        do {
            let lines = request.components(separatedBy: "\r\n"), words = (lines.first ?? "").split(separator: " ")
            guard words.count == 3, ["GET", "HEAD"].contains(String(words[0])), let remote = lock.withLock({ routes[String(words[1])] }) else { return }
            var req = URLRequest(url: remote); req.allHTTPHeaderFields = WebsiteHLSPolicy.headers(media.headers,origin:origin,target:remote)
            // 图片前缀修正必须先取得完整分片，不能沿用播放器的原始字节偏移。
            var fetched:(Data,URLResponse)?
            for _ in 0..<5 {
                let result = try await session.data(for:req)
                if let response = result.1 as? HTTPURLResponse,[301,302,303,307,308].contains(response.statusCode),let location = response.value(forHTTPHeaderField:"Location"),let next = URL(string:location,relativeTo:req.url)?.absoluteURL,["https","http"].contains(next.scheme ?? "") {
                    req = URLRequest(url:next);req.allHTTPHeaderFields = WebsiteHLSPolicy.headers(media.headers,origin:origin,target:next)
                    continue
                }
                fetched = result;break
            }
            guard let (raw,reply) = fetched else { throw TVError.message("网页媒体跳转次数过多") }
            guard let response = reply as? HTTPURLResponse, [200,206].contains(response.statusCode), raw.count <= 64*1024*1024 else { throw TVError.message("网页分片读取失败") }
            let playlist = remote.pathExtension.lowercased() == "m3u8" || raw.starts(with: Data("#EXTM3U".utf8))
            let transformed = playlist ? try rewrite(raw, base: response.url ?? remote) : try WebsiteHLSPolicy.transportStream(raw)
            let isTS = !playlist && transformed.first == 0x47
            let data = transformed
            var header = "HTTP/1.1 200 OK\r\nContent-Type: \(playlist ? "application/vnd.apple.mpegurl" : isTS ? "video/mp2t" : response.mimeType ?? "application/octet-stream")\r\nContent-Length: \(data.count)\r\nConnection: close\r\n"
            try await send(connection, Data((header + "\r\n").utf8))
            if words[0] != "HEAD" { try await send(connection, data) }
        } catch {
            try? await send(connection, Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)) }
    }
    private func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } })
        }
    }
}

private final class WebsiteHLSRedirectBlocker:NSObject,URLSessionTaskDelegate {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) { completionHandler(nil) }
}

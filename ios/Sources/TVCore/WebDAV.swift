import Foundation

public struct DAVSettings: Equatable, Sendable {
    public var address: String, username: String, password: String, userDirectory: String
    public init(address: String = "", username: String = "", password: String = "", userDirectory: String = "") { self.address = address; self.username = username; self.password = password; self.userDirectory = userDirectory }
    public func directoryAddress() throws -> String {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = userDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else { return address }
        let parts = directory.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("%") && !$0.contains(":") && !$0.contains("?") && !$0.contains("#") && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }),
              var url = URL(string: address) else { throw TVError.message("用户目录请填写相对目录名，例如 alice 或 family/alice") }
        for part in parts { url.appendPathComponent(part, isDirectory: true) }
        return url.absoluteString
    }
}
public struct HTTPReply: Sendable {
    public var status: Int, body: Data, headers: [String: String]
    public init(status: Int, body: Data = Data(), headers: [String: String] = [:]) { self.status = status; self.body = body; self.headers = headers }
}
public protocol HTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> HTTPReply }
private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public final class NetworkTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 40
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }
    public func send(_ request: URLRequest) async throws -> HTTPReply {
        let (stream, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw TVError.message("服务器响应无效") }
        guard response.expectedContentLength <= 8 * 1024 * 1024 else { throw TVError.message("响应超过 8 MiB") }
        var bytes = Data()
        for try await byte in stream {
            bytes.append(byte)
            if bytes.count > 8 * 1024 * 1024 { throw TVError.message("响应超过 8 MiB") }
        }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
        return HTTPReply(status: response.statusCode, body: bytes, headers: headers)
    }
}
public struct DAVSnapshot: Sendable { public var document: SyncDocument?, etag: String? }
public enum DAVFailure: LocalizedError {
    case conflict, status(Int)
    public var errorDescription: String? {
        switch self {
        case .conflict: return "其他设备正在更新云端，请稍后重试"
        case .status(let code): return "服务器返回 HTTP \(code)，请检查地址、账号和权限"
        }
    }
}
private actor DAVReadCache {
    var snapshot: DAVSnapshot?
    func get() -> DAVSnapshot? { snapshot }
    func set(_ value: DAVSnapshot?) { snapshot = value }
}
public struct WebDAVClient: Sendable {
    private let cache = DAVReadCache()
    private let folder: URL, authorization: String
    private let transport: any HTTPTransport
    public init(settings: DAVSettings, transport: any HTTPTransport = NetworkTransport()) throws {
        guard let base = URL(string: try settings.directoryAddress()),
              ["http","https"].contains(base.scheme?.lowercased() ?? ""), base.host != nil,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil else { throw TVError.message("请填写不含账号、查询参数的 HTTP 或 HTTPS 目录地址") }
        folder = base.appendingPathComponent("fongmi-sync-v1", isDirectory: true)
        authorization = "Basic " + Data((settings.username + ":" + settings.password).utf8).base64EncodedString()
        self.transport = transport
    }
    private func send(_ method: String, _ name: String = "", body: Data? = nil, condition: (String, String)? = nil) async throws -> HTTPReply {
        var r = URLRequest(url: name.isEmpty ? folder : folder.appendingPathComponent(name))
        r.httpMethod = method; r.httpBody = body
        r.setValue(authorization, forHTTPHeaderField: "Authorization"); r.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if body != nil { r.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type") }
        if let condition { r.setValue(condition.1, forHTTPHeaderField: condition.0) }
        return try await transport.send(r)
    }
    private func successful(_ reply: HTTPReply) throws {
        if reply.status == 412 { throw DAVFailure.conflict }
        if !(200..<300).contains(reply.status) { throw DAVFailure.status(reply.status) }
    }
    private func strongTag(_ tag: String?) throws -> String {
        guard let tag, tag.hasPrefix("\""), tag.hasSuffix("\""), !tag.hasPrefix("W/") else { throw TVError.message("服务器缺少强 ETag，不能安全同步") }; return tag
    }
    public func ensureFolder() async throws {
        try await ensureFolder(folder)
    }
    private func ensureFolder(_ directory: URL) async throws {
        var request = URLRequest(url: directory)
        request.httpMethod = "MKCOL"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        let reply = try await transport.send(request)
        if reply.status == 405 || (200..<300).contains(reply.status) { return }
        guard reply.status == 409 else { try successful(reply); return }
        let parent = directory.deletingLastPathComponent()
        guard parent.path != directory.path, !parent.path.isEmpty, parent.path != "/" else { throw DAVFailure.status(409) }
        try await ensureFolder(parent)
        let retried = try await transport.send(request)
        if retried.status != 405 { try successful(retried) }
    }
    public func read() async throws -> DAVSnapshot {
        let previous = await cache.get()
        let r = try await send("GET", "state.json", condition: previous?.etag.map { ("If-None-Match", $0) })
        if r.status == 304, let previous { return previous }
        if r.status == 404 { await cache.set(nil); return DAVSnapshot(document: nil, etag: nil) }
        try successful(r)
        let value = DAVSnapshot(document: try SyncDocument(data: r.body), etag: try strongTag(r.headers["etag"]))
        await cache.set(value)
        return value
    }
    public func write(_ document: SyncDocument, before: DAVSnapshot) async throws {
        try document.validate()
        guard document.raw.data.count <= 8 * 1024 * 1024 else { throw TVError.message("同步文件超过 8 MiB") }
        let condition = before.document == nil ? ("If-None-Match", "*") : ("If-Match", try strongTag(before.etag))
        try successful(await send("PUT", "state.json", body: try document.wireData(preservingLegacyAndroidLayout: before.document?.usesLegacyAndroidLayout == true), condition: condition))
    }
    public func test() async throws {
        try await ensureFolder()
        let name = "probe-ios-\(UUID().uuidString).json"
        let payload = Data("{\"probe\":true}".utf8)
        do {
            try successful(await send("PUT", name, body: payload, condition: ("If-None-Match", "*")))
            let read = try await send("GET", name); try successful(read)
            guard read.body == payload else { throw TVError.message("连接测试读写结果不一致") }
            _ = try strongTag(read.headers["etag"])
            let stale = try await send("PUT", name, body: payload, condition: ("If-Match", "\"invalid-\(UUID().uuidString)\""))
            guard stale.status == 412 else { throw TVError.message("服务器不支持条件写入，不能安全同步") }
            try successful(await send("DELETE", name))
        } catch {
            _ = try? await send("DELETE", name); throw error
        }
    }
}

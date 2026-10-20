import Foundation
import Network
import Security

/// 仅 UC CAS 域名使用公共 HTTPS DNS；TLS SNI 和系统证书校验仍使用原域名。
public actor UCLoginTransport: HTTPTransport {
    private let regular: any HTTPTransport
    private var addresses: [String] = []
    private var expires = Date.distantPast
    public init(regular: any HTTPTransport = NetworkTransport()) { self.regular = regular }
    public func send(_ request: URLRequest) async throws -> HTTPReply {
        guard request.url?.host == "api.open.uc.cn" else { return try await regular.send(request) }
        guard let url = request.url, url.scheme == "https", url.port == nil || url.port == 443,
              url.path.hasPrefix("/cas/ajax/"), request.httpMethod == "POST" else { throw TVError.message("UC 授权请求地址无效") }
        if addresses.isEmpty || expires < Date() {
            var dns = URLRequest(url: URL(string:"https://cloudflare-dns.com/dns-query?name=api.open.uc.cn&type=A")!)
            dns.setValue("application/dns-json", forHTTPHeaderField:"Accept")
            let reply = try await regular.send(dns)
            guard reply.status == 200 else { throw TVError.message("UC 授权域名解析失败") }
            let root = try JSON.parse(reply.body)
            addresses = root["Answer"].array.filter { $0["type"].int == 1 }.map { $0["data"].string }.filter {
                let parts = $0.split(separator:"."); return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } == true }
            }
            guard !addresses.isEmpty else { throw TVError.message("UC 授权域名未返回可用地址") }
            expires = Date().addingTimeInterval(60)
        }
        var last: Error = URLError(.cannotConnectToHost)
        for address in addresses.prefix(2) {
            do {
                try Task.checkCancellation()
                let exchange = try UCLoginExchange(address:address, request:request)
                return try UCLoginWire.decode(await exchange.run())
            } catch { if NetworkIssue.cancelled(error) { throw CancellationError() }; last = error }
        }
        throw last
    }
}

/// 小型有界 HTTP/1.1 响应解码器，仅服务于 UC 的 JSON 授权接口。
enum UCLoginWire {
    static func decode(_ raw: Data) throws -> HTTPReply {
        guard raw.count <= 1024 * 1024, let boundary = raw.range(of:Data("\r\n\r\n".utf8)),
              let text = String(data:raw[..<boundary.lowerBound],encoding:.utf8) else { throw TVError.message("UC 授权响应无效") }
        let lines = text.components(separatedBy:"\r\n")
        guard let first = lines.first?.split(separator:" "), first.count >= 2, let status = Int(first[1]) else { throw TVError.message("UC 授权响应状态无效") }
        var headers: [String:String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of:":") else { continue }
            headers[String(line[..<colon]).lowercased()] = line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces)
        }
        var body = Data(raw[boundary.upperBound...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            var decoded = Data(), cursor = body.startIndex
            while true {
                guard let end = body[cursor...].range(of:Data("\r\n".utf8)),
                      let sizeText = String(data:body[cursor..<end.lowerBound],encoding:.ascii),
                      let token = sizeText.split(separator:";").first, let size = Int(token,radix:16), size >= 0 else { throw TVError.message("UC 授权响应分段无效") }
                cursor = end.upperBound
                if size == 0 { body = decoded; break }
                guard size <= 1024 * 1024, cursor + size + 2 <= body.endIndex,
                      body[cursor+size..<cursor+size+2] == Data("\r\n".utf8) else { throw TVError.message("UC 授权响应分段不完整") }
                decoded.append(body[cursor..<cursor+size]); cursor += size + 2
            }
        } else if let length = headers["content-length"].flatMap(Int.init), body.count != length { throw TVError.message("UC 授权响应不完整") }
        return HTTPReply(status:status,body:body,headers:headers)
    }
}

private final class UCLoginExchange: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label:"tv.uc.login")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var outcome: Result<Data, Error>?
    private var buffer = Data()
    private let request: Data
    init(address: String, request r: URLRequest) throws {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions,"api.open.uc.cn")
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions,"http/1.1")
        connection = NWConnection(host:NWEndpoint.Host(address),port:443,using:NWParameters(tls:tls,tcp:NWProtocolTCP.Options()))
        let url = r.url!, path = url.path + (url.query.map { "?"+$0 } ?? "")
        var header = "POST \(path) HTTP/1.1\r\nHost: api.open.uc.cn\r\nConnection: close\r\nAccept-Encoding: identity\r\n"
        for (key,value) in r.allHTTPHeaderFields ?? [:] where !["host","connection","content-length","accept-encoding"].contains(key.lowercased()) {
            guard !key.contains("\r"),!key.contains("\n"),!value.contains("\r"),!value.contains("\n") else { throw TVError.message("UC 授权请求头无效") }
            header += key+": "+value+"\r\n"
        }
        let body = r.httpBody ?? Data()
        request = Data((header+"Content-Length: \(body.count)\r\n\r\n").utf8)+body
    }
    func run() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                lock.lock()
                if let outcome { lock.unlock(); c.resume(with:outcome); return }
                continuation = c; lock.unlock()
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.connection.send(content:self.request,completion:.contentProcessed { [weak self] error in
                            guard let self else { return }
                            if let error { self.finish(.failure(error)) } else { self.receive() }
                        })
                    case .failed(let error): self.finish(.failure(error))
                    case .cancelled: self.finish(.failure(CancellationError()))
                    default: break
                    }
                }
                queue.asyncAfter(deadline:.now()+15) { [weak self] in self?.finish(.failure(URLError(.timedOut))) }
                connection.start(queue:queue)
            }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength:1,maximumLength:65536) { [weak self] data,_,complete,error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if self.buffer.count > 1024 * 1024 { self.finish(.failure(TVError.message("UC 授权响应过大"))) }
            else if let error { self.finish(.failure(error)) }
            else if complete { self.finish(.success(self.buffer)) }
            else { self.receive() }
        }
    }
    private func finish(_ result: Result<Data, Error>) {
        lock.lock(); guard outcome == nil else { lock.unlock(); return }
        outcome = result; let c = continuation; continuation = nil; lock.unlock()
        c?.resume(with:result); connection.cancel()
    }
}

import Foundation

public struct CloudLoginCredentials: Sendable {
    public var cookie: String
    public var serviceTicket: String?
    public init(cookie: String, serviceTicket: String? = nil) { self.cookie = cookie; self.serviceTicket = serviceTicket }
}

/// UC 官方 CAS 二维码协议；二维码令牌只在本次登录任务的内存中使用。
public struct UCLoginClient: Sendable {
    private let transport: any HTTPTransport
    private let requestID: String
    public init(transport: any HTTPTransport = NetworkTransport(), requestID: String = String(SyncDocument.now)) {
        self.transport = transport; self.requestID = requestID
    }
    private func request(_ method: String, token: String? = nil) async throws -> JSON {
        var url = URLComponents(string: "https://api.open.uc.cn/cas/ajax/" + method)!
        url.queryItems = [URLQueryItem(name: "__t", value: String(SyncDocument.now))]
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "client_id", value: "381"), URLQueryItem(name: "v", value: "1.2"), URLQueryItem(name: "request_id", value: requestID)]
        if let token { form.queryItems?.append(URLQueryItem(name: "token", value: token)) }
        var r = URLRequest(url: url.url!); r.httpMethod = "POST"
        r.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        r.allHTTPHeaderFields = ["User-Agent":Self.userAgent, "Origin":"https://broccoli.uc.cn", "Referer":"https://drive.uc.cn/", "Content-Type":"application/x-www-form-urlencoded"]
        let reply = try await transport.send(r)
        guard reply.status == 200 else { throw TVError.message("UC 授权接口连接失败（HTTP \(reply.status)）") }
        return try JSON.parse(reply.body)
    }
    public func token() async throws -> String {
        let root = try await request("getTokenForQrcodeLogin")
        let token = root["data"]["members"]["token"].string
        guard !token.isEmpty else { throw TVError.message("UC 未生成二维码，请刷新重试") }
        return token
    }
    public static func qrURL(token: String) -> URL {
        var url = URLComponents(string:"https://broccoli.uc.cn/apps/ZY5qIZiK/routes/scan_confirm")!
        url.queryItems = [URLQueryItem(name:"token",value:token),URLQueryItem(name:"client_id",value:"381"),URLQueryItem(name:"uc_biz_str",value:"S:custom|C:titlebar_fix")]
        return url.url!
    }
    public func poll(token: String) async throws -> String? {
        let root = try await request("getServiceTicketByQrcodeToken", token: token)
        let ticket = root["data"]["members"]["service_ticket"].string
        return ticket.isEmpty ? nil : ticket
    }
    public func account(ticket: String) async throws -> CloudLoginCredentials {
        guard !ticket.isEmpty else { throw TVError.message("UC 登录授权尚未完成") }
        var url = URLComponents(string:"https://drive.uc.cn/account/mobileinfo")!
        url.queryItems = [URLQueryItem(name:"pr",value:"UCBrowser"),URLQueryItem(name:"fr",value:"h5"),URLQueryItem(name:"st",value:ticket)]
        var request = URLRequest(url:url.url!)
        request.allHTTPHeaderFields = ["User-Agent":Self.userAgent,"Referer":"https://drive.uc.cn/"]
        let reply = try await transport.send(request)
        guard reply.status == 200 else { throw TVError.message("UC 登录信息获取失败，请重新扫码") }
        let data = try JSON.parse(reply.body)["data"]
        let cookie = "__pus=" + data["__pus"].string
        guard SyncedQuarkAccount.validCookie(cookie) else { throw TVError.message("UC 未返回登录状态，请在手机确认授权") }
        return .init(cookie:cookie, serviceTicket:data["serviceTicket"].string)
    }
    private static let userAgent = "Mozilla/5.0 (Linux; U; Android 13; zh-CN) AppleWebKit/537.36 (KHTML, like Gecko) UCBrowser/15.5.8.1238 Mobile Safari/537.36"
}

import Foundation
import CryptoKit

/// 海绵 Android 插件的表单签名与 AES 响应协议；令牌由当前客户端初始化获取。
public actor HmysClient {
    public static let shared = HmysClient()
    public let transport: any HTTPTransport
    private var origin = "https://u.uccao.cn"
    private var token = ""
    private let deviceID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
    private static let responseKey = "aZ9$kU5%qI7=yC2=zH2#gM0@pX7^wF3a"
    private static let responseIV = "hY2&tN3]kF7,dL7="
    private static let signingSalt = "zD9[bM4~sF4~uY2)"
    public init(transport: any HTTPTransport = NetworkTransport()) { self.transport = transport }
    private static func text(_ value: JSON) -> String { value.string.isEmpty ? (value.int == 0 ? "" : String(value.int)) : value.string }
    private static func md5(_ value: String) -> String { Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func request(_ path: String, params: [String: String] = [:]) async throws -> JSON {
        guard let url = URL(string: origin + path) else { throw TVError.message("海绵接口地址无效") }
        let now = String(SyncDocument.now)
        var req = URLRequest(url: url); req.httpMethod = "POST"
        var body = URLComponents(); body.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = Data((body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") ?? "").utf8)
        req.allHTTPHeaderFields = ["Content-Type": "application/x-www-form-urlencoded", "User-Agent": "okhttp/4.12.0", "log-header": "I am the log request header.", "app_id": "tianjishipin", "channel_code": "tjsp_sp01", "cur_time": now, "device_id": deviceID, "mob_mfr": "Apple", "mobmodel": "iPhone", "package_name": "com.wfighter.zmz", "sign": Self.md5(Self.signingSalt + deviceID + now).uppercased(), "sys_platform": "2", "sysrelease": "12", "token": token, "version": "51000"]
        let reply = try await transport.send(req)
        guard reply.status == 200 else { throw DAVFailure.status(reply.status) }
        guard let raw = String(data: reply.body, encoding: .utf8), let cipher = Data(base64Encoded: raw.trimmingCharacters(in: .whitespacesAndNewlines)), !cipher.isEmpty else { throw TVError.message("海绵接口未返回预期加密数据") }
        let decoded = try AppSxClient.crypt(cipher, key: Data(Self.responseKey.utf8), iv: Data(Self.responseIV.utf8), encrypt: false)
        let root = try JSON.parse(decoded)
        guard root["result"] != .null else { throw TVError.message("海绵接口请求失败或授权已失效") }
        return root["result"]
    }
    private func initialize() async throws {
        guard token.isEmpty else { return }
        let result = try await request("/api/new_public/init_v2", params: ["invited_by": "", "is_install": "1", "ua": "Mozilla/5.0 (Linux; Android 12; iPhone Build/SKQ1.211113.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/97.0.4692.98 Mobile Safari/537.36"])
        guard !result["user_info"]["token"].string.isEmpty else { throw TVError.message("海绵初始化未返回客户端令牌") }
        token = result["user_info"]["token"].string
    }
    public func categories() async throws -> [(id: String, name: String)] {
        try await initialize()
        return try await request("/api/new_type/list_v2").array.compactMap { row in
            let id = Self.text(row["id"]), name = row["name"].string
            return id.isEmpty || name.isEmpty ? nil : (id, name)
        }
    }
    private static func item(_ row: JSON) -> MediaItem? {
        let id = text(row["id"]), name = row["vod_name"].string
        guard !id.isEmpty, !name.isEmpty else { return nil }
        return MediaItem(id: id, name: name, picture: row["vod_pic"].string, remarks: row["remarks"].string.isEmpty ? row["collection_new_title"].string : row["remarks"].string)
    }
    public func browse(keyword: String = "", page: Int = 1, category: String = "") async throws -> [MediaItem] {
        try await initialize()
        let rows: [JSON]
        if !keyword.isEmpty { rows = try await request("/api/new_search/result_v2", params: ["pn": String(page), "kw": keyword]).array }
        else if !category.isEmpty { rows = try await request("/api/new_search/screen_v2", params: ["pn": String(page), "type_id": category, "tag_type": "", "type": "", "area": "", "sort": "", "year": ""]).array }
        else {
            guard page == 1 else { return [] }
            let modules = try await request("/api/new_channel/get_info_v2", params: ["pn": "1", "psize": "100", "channel_id": "331"]).array
            rows = modules.flatMap { $0["block_list"].array }.flatMap { block -> [JSON] in
                if case .object = block["vod_info"] { return [block["vod_info"]] }
                return block["vod_list"].array
            }
        }
        var seen = Set<String>()
        let items = rows.compactMap(Self.item).filter { seen.insert($0.id).inserted }
        return keyword.isEmpty && category.isEmpty ? Array(items.prefix(30)) : items
    }
    public func detail(id: String) async throws -> MediaDetail {
        try await initialize()
        let row = try await request("/api/new_video/result_v2", params: ["vod_id": id, "sig": "", "nc_token": "", "session_id": "", "code": "", "phone": ""])
        guard let item = Self.item(row) else { throw TVError.message("海绵未返回影片详情") }
        let episodes = row["vod_collection"].array.compactMap { entry -> Episode? in
            let collection = Self.text(entry["id"]), secret = entry["vod_token"].string
            guard !collection.isEmpty, !secret.isEmpty else { return nil }
            return Episode(name: entry["title"].string, url: [collection, secret, Self.text(row["server_time"]), id].joined(separator: "@@@"), line: "秒播")
        }
        return MediaDetail(item: item, episodes: episodes, synopsis: row["intro"].string)
    }
    public func resolve(_ episode: Episode) async throws -> ResolvedMedia {
        try await initialize()
        let ids = episode.url.components(separatedBy: "@@@")
        guard ids.count == 4 else { throw TVError.message("海绵选集标识无效，请重新打开详情") }
        let row = try await request("/api/new_video/collection_v2", params: ["vod_id": ids[3], "sig": "", "nc_token": "", "code": "", "phone": "", "session_id": "", "cur_time": ids[2], "vod_token": ids[1], "collection_id": ids[0]])
        guard row["check_url"].string.isEmpty, row["check_page_url"].string.isEmpty else { throw TVError.message("当前海绵线路要求交互验证，请换一条线路") }
        let raw = row["vod_url"].string
        let address = CatalogParser.validHTTP(raw) ? raw : origin + (raw.hasPrefix("/") ? "" : "/") + raw
        guard !raw.isEmpty, CatalogParser.validHTTP(address) else { throw TVError.message("海绵线路未返回有效播放地址") }
        if URL(string: address)?.pathExtension.lowercased() == "mp4" { return ResolvedMedia(url: address, headers: ["User-Agent": "Mozi", "Accept": "*/*"]) }
        let signing = try HmysSigning(query: row["ck"].string, key: "IysJHCZ2Z7HBEoPPKC8nXIibjGHkKNrc")
        var media = ResolvedMedia(url: address, headers: ["User-Agent": "Mozi", "Accept": "*/*"], useVLC: true)
        media.hmysSigning = signing
        return media
    }
}

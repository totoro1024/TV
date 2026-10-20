import Foundation

/// 对照 Android Bili 插件的分类配置、搜索、分 P 与播放接口。
/// 不内置第三方登录凭据，也不把搜索风控响应当成空列表。
private actor BiliReadCache {
    static let shared=BiliReadCache()
    private var values:[String:(Date,JSON)]=[:]
    func get(_ key:String) -> JSON? {
        guard let (time,value)=values[key],Date().timeIntervalSince(time)<60 else { values.removeValue(forKey:key);return nil };return value
    }
    func set(_ key:String,_ value:JSON) { if values.count >= 32 { values.removeAll() };values[key]=(Date(),value) }
}
public struct BiliClient: Sendable {
    public var transport: any HTTPTransport
    public init(transport: any HTTPTransport = NetworkTransport()) { self.transport = transport }
    private var headers: [String:String] { ["User-Agent":"Mozilla/5.0", "Referer":"https://www.bilibili.com/"] }
    private func request(_ address: String, _ query: [String:String] = [:]) async throws -> JSON {
        guard CatalogParser.validHTTP(address), var parts = URLComponents(string:address) else { throw TVError.message("哔哩配置地址无效") }
        parts.queryItems = (parts.queryItems ?? []) + query.sorted { $0.key < $1.key }.map { URLQueryItem(name:$0.key,value:$0.value) }
        guard let url=parts.url else { throw TVError.message("哔哩接口地址无效") }
        let cached = transport is NetworkTransport
        if cached,let value=await BiliReadCache.shared.get(url.absoluteString) { return value }
        var request=URLRequest(url:url); request.allHTTPHeaderFields=headers
        let reply=try await transport.send(request)
        guard (200..<300).contains(reply.status) else { throw TVError.message(reply.status == 412 ? "哔哩触发访问限制（HTTP412），请稍后重试" : "哔哩接口返回HTTP\(reply.status)，请稍后重试") }
        let root=try JSON.parse(reply.body)
        if root.object["code"] != nil && root["code"].int != 0 { throw TVError.message("哔哩接口拒绝请求（\(root["code"].int)），可能需要登录或稍后重试") }
        if cached { await BiliReadCache.shared.set(url.absoluteString,root) }
        return root
    }
    public func categories(_ source:MediaSource) async throws -> [(id:String,name:String)] {
        let config:JSON
        if !source.ext["json"].string.isEmpty { config=try await request(source.ext["json"].string) }
        else { config=source.ext }
        return config["class"].array.compactMap { row in
            let id=row["type_id"].string
            return id.isEmpty || id == "peizhi" ? nil : (id,row["type_name"].string)
        }
    }
    public func browse(_ source:MediaSource, keyword:String="", page:Int=1, category:String="") async throws -> [MediaItem] {
        var word=keyword.isEmpty ? category : keyword
        // Android 的 homeVideoContent 使用热门视频；各站点仍保留自己的分类配置。
        let root:JSON
        if word.isEmpty {
            root=try await request("https://api.bilibili.com/x/web-interface/popular",["ps":"20","pn":String(page)])
            return Self.items(root["data"]["list"])
        }
        word=word.trimmingCharacters(in:.whitespacesAndNewlines)
        root=try await request("https://api.bilibili.com/x/web-interface/search/type",["search_type":"video","keyword":word,"page":String(page),"order":"totalrank"])
        guard case .array = root["data"]["result"] else { throw TVError.message("哔哩搜索未返回视频列表") }
        return Self.items(root["data"]["result"])
    }
    static func items(_ list:JSON) -> [MediaItem] {
        list.array.compactMap { row in
            let aid = row["aid"].string.isEmpty ? (row["aid"].int > 0 ? String(row["aid"].int) : "") : row["aid"].string
            let id = !row["bvid"].string.isEmpty && !aid.isEmpty ? row["bvid"].string+"@"+aid : row["bvid"].string.isEmpty ? aid:row["bvid"].string
            guard !id.isEmpty else { return nil }
            let raw=row["pic"].string
            let title=row["title"].string.replacingOccurrences(of:"<[^>]+>",with:"",options:.regularExpression).replacingOccurrences(of:"&amp;",with:"&")
            return MediaItem(id:id,name:title,picture:raw.hasPrefix("//") ? "https:"+raw : raw,remarks:row["duration"].string)
        }
    }
    public func detail(_ source:MediaSource,id:String) async throws -> MediaDetail {
        let pieces=id.components(separatedBy:"@"), lookup=pieces.count > 1 ? pieces[1]:id
        let root=try await request("https://api.bilibili.com/x/web-interface/view",[lookup.hasPrefix("BV") ? "bvid":"aid":lookup])["data"]
        let bvid=root["bvid"].string
        guard !bvid.isEmpty else { throw TVError.message("哔哩视频详情缺少标识") }
        let aid=root["aid"].string.isEmpty ? (root["aid"].int > 0 ? String(root["aid"].int):""):root["aid"].string
        let item=MediaItem(id:aid.isEmpty ? id:bvid+"@"+aid,name:root["title"].string,picture:root["pic"].string)
        let episodes=root["pages"].array.compactMap { row -> Episode? in
            guard row["cid"].int > 0 else { return nil }
            let payload=JSON.object(["bvid":.string(bvid),"cid":row["cid"]])
            return Episode(name:row["part"].string,url:aid.isEmpty ? payload.text:aid+"+"+String(row["cid"].int),line:"哔哩")
        }
        guard !episodes.isEmpty else { throw TVError.message("哔哩视频没有可用分集") }
        return MediaDetail(item:item,episodes:episodes,synopsis:root["desc"].string,metadata:["作者":root["owner"]["name"].string])
    }
    public func resolve(_ episode:Episode) async throws -> ResolvedMedia {
        let payload:JSON
        let android=episode.url.components(separatedBy:"+")
        if android.count >= 2,Int64(android[0]) != nil,let cid=Int64(android[1]) { payload = .object(["aid":.string(android[0]),"cid":.integer(cid)]) }
        else { payload=try JSON.parse(Data(episode.url.utf8)) }
        guard (!payload["bvid"].string.isEmpty || !payload["aid"].string.isEmpty),payload["cid"].int > 0 else { throw TVError.message("哔哩分集标识无效") }
        let root=try await request("https://api.bilibili.com/x/player/playurl",[payload["bvid"].string.isEmpty ? "avid":"bvid":payload["bvid"].string.isEmpty ? payload["aid"].string:payload["bvid"].string,"cid":String(payload["cid"].int),"qn":"64","fnval":"0","platform":"html5"])["data"]
        let segments=root["durl"].array
        guard segments.count == 1,let first=segments.first,CatalogParser.validHTTP(first["url"].string) else { throw TVError.message("哔哩未提供单段播放地址，当前视频可能需要登录或其他播放格式") }
        // 已在模拟器复现部分哔哩MP4系统解码绿屏，使用内置VLC软件解码。
        return ResolvedMedia(url:first["url"].string,headers:headers,size:max(0,first["size"].int),useVLC:true)
    }
}

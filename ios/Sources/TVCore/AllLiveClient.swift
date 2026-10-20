import Foundation

/// 一直播的聚合服务协议；本地不保存或转发站外登录 Cookie。
public struct AllLiveClient: Sendable {
    public static let categories = [(id:"huya",name:"虎牙"),(id:"douyu",name:"斗鱼"),(id:"bilibili",name:"哔哩哔哩")]
    public var transport: any HTTPTransport
    public init(transport:any HTTPTransport = NetworkTransport()) { self.transport = transport }
    private func base(_ source:MediaSource) throws -> URL {
        let raw = source.ext.string
        let decoded = CatalogParser.validHTTP(raw) ? raw : (try? App99Crypto.decodePluginText(raw)) ?? ""
        guard let url = URL(string:decoded), CatalogParser.validHTTP(decoded) else { throw TVError.message("一直播的聚合服务地址无效") }
        return url
    }
    private func request(_ source:MediaSource,platform:String,action:String,query:[String:String] = [:]) async throws -> JSON {
        guard Self.categories.contains(where:{$0.id == platform}) else { throw TVError.message("一直播平台无效") }
        let root = try base(source)
        var parts = URLComponents(url:root.appendingPathComponent("api/\(platform)/\(action)"),resolvingAgainstBaseURL:false)!
        parts.queryItems = query.sorted{$0.key < $1.key}.map { URLQueryItem(name:$0.key,value:$0.value) }
        var req = URLRequest(url:parts.url!)
        req.setValue(SeedhubClient.userAgent,forHTTPHeaderField:"User-Agent")
        req.setValue(root.absoluteString,forHTTPHeaderField:"Referer")
        let reply = try await transport.send(req)
        guard reply.status == 200 else { throw DAVFailure.status(reply.status) }
        let body: JSON
        do { body = try JSON.parse(reply.body) }
        catch {
            guard let text = String(data:reply.body,encoding:.utf8),let decoded = try? LZStringResponse.decode(text),let result = try? JSON.parse(decoded) else {
                throw TVError.message("一直播聚合服务响应无法解码，可能需要访问验证或接口已变更")
            }
            body = result
        }
        guard body["data"] != .null else { throw TVError.message("一直播服务未返回 data 数据") }
        return body["data"]
    }
    private static func text(_ value:JSON) -> String { if case .number(let n) = value { return n };return value.string }
    private static func items(_ rows:[JSON],platform:String) -> [MediaItem] {
        rows.compactMap { row in
            let id = text(row["roomId"]), name = row["title"].string
            guard !id.isEmpty,!name.isEmpty else { return nil }
            return MediaItem(id:platform+"_"+id,name:name,picture:row["cover"].string,remarks:row["nickname"].string)
        }
    }
    public func browse(_ source:MediaSource,keyword:String="",page:Int=1,category:String="") async throws -> [MediaItem] {
        if !keyword.isEmpty {
            // Android 的“搜索”聚合三平台；各平台失败不能冒充成功的零结果。
            var result:[MediaItem] = [], failures = 0
            for platform in Self.categories {
                do {
                    let root = try await request(source,platform:platform.id,action:"searchRooms",query:["page":String(page),"kw":keyword])
                    guard case .array = root["list"] else { throw TVError.message("一直播搜索未返回房间列表") }
                    result += Self.items(root["list"].array,platform:platform.id)
                } catch { if error is CancellationError { throw error };failures += 1 }
            }
            guard failures < Self.categories.count else { throw TVError.message("一直播三平台搜索均失败，请检查聚合服务状态") }
            return result
        }
        // 原插件首页只列平台入口；默认目录使用哔哩推荐，平台分类使用各自首分类。
        let pieces = category.split(separator:"|",maxSplits:1).map(String.init), platform = pieces.first ?? "bilibili"
        if platform == "bilibili" {
            let root = try await request(source,platform:platform,action:"getRecommendRooms",query:["page":String(page)])
            guard case .array = root["list"] else { throw TVError.message("一直播推荐未返回房间列表") }
            return Self.items(root["list"].array,platform:platform)
        }
        let categoryID:String
        if pieces.count == 2 { categoryID = pieces[1] }
        else {
            let groups = try await request(source,platform:platform,action:"getCategories")
            guard let first = groups.array.first, let row = first["list"].array.first else { throw TVError.message("一直播未返回平台分类") }
            categoryID = Self.text(row["id"])
        }
        guard !categoryID.isEmpty else { throw TVError.message("一直播平台分类编号无效") }
        let root = try await request(source,platform:platform,action:"getCategoryRooms",query:["id":categoryID,"pid":"1","page":String(page)])
        guard case .array = root["list"] else { throw TVError.message("一直播分类未返回房间列表") }
        return Self.items(root["list"].array,platform:platform)
    }
    public func detail(_ source:MediaSource,id:String) async throws -> MediaDetail {
        let parts = id.split(separator:"_",maxSplits:1).map(String.init)
        guard parts.count == 2,!parts[1].isEmpty else { throw TVError.message("一直播房间标识无效") }
        let row = try await request(source,platform:parts[0],action:"getRoomDetail",query:["id":parts[1]])
        var episodes:[Episode] = []
        for stream in row["stream"].array {
            for line in stream["lines"].array {
                let raw = line["url"].string
                let url = raw.hasPrefix("//") ? "https:"+raw : raw
                guard CatalogParser.validHTTP(url) else { continue }
                episodes.append(Episode(name:line["name"].string,url:url,line:stream["name"].string))
            }
        }
        // 虎牙 info.code 需临时签名。复用原生虎牙签名实现，不能把未签名线路当媒体。
        if parts[0] == "huya", row["info"] != .null {
            episodes = [Episode(name:"直播",url:"https://m.huya.com/"+parts[1],line:"虎牙")]
        }
        guard !episodes.isEmpty else { throw TVError.message("直播间未开播或聚合服务未返回播放线路") }
        return MediaDetail(item:MediaItem(id:id,name:row["title"].string,picture:row["cover"].string,remarks:row["nickname"].string),episodes:episodes,synopsis:row["category"].string)
    }
    public func resolve(_ episode:Episode) async throws -> ResolvedMedia {
        if URL(string:episode.url)?.host == "m.huya.com" {
            let source = MediaSource(id:"huya",sourceID:"",name:"虎牙",address:"",kind:.streamSite,ext:.string("https://example.invalid/虎牙.js"))
            return try await PublicStreamClient(transport:transport).resolve(source,episode:episode)
        }
        guard CatalogParser.validHTTP(episode.url) else { throw TVError.message("一直播媒体地址无效") }
        return ResolvedMedia(url:episode.url,headers:["User-Agent":SeedhubClient.userAgent],useVLC:URL(string:episode.url)?.pathExtension == "flv")
    }
}

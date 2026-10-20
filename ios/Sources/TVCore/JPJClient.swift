import Foundation

/// 荐片目录接口及域名发现；特殊P2P线路不冒充HTTP直链。
public actor JPJClient {
    public static let shared = JPJClient()
    public static let categories = [(id:"1",name:"电影"),(id:"2",name:"电视剧"),(id:"3",name:"动漫"),(id:"4",name:"综艺"),(id:"50",name:"纪录片"),(id:"99",name:"Netflix")]
    public var transport:any HTTPTransport
    private var endpoints:[String:(Date,URL,String)] = [:]
    private static let userAgent = "Mozilla/5.0 (Linux; Android 9; V2196A Build/PQ3A.190705.08211809; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/91.0.4472.114 Mobile Safari/537.36;webank/h5face;webank/1.0;netType:NETWORK_WIFI;appVersion:416;packageName:com.jp3.xg3"
    public init(transport:any HTTPTransport = NetworkTransport()) { self.transport = transport }
    private func json(_ url:URL,referer:String? = nil) async throws -> JSON {
        var req = URLRequest(url:url);req.timeoutInterval = 12
        req.allHTTPHeaderFields = ["User-Agent":Self.userAgent]
        if let referer { req.setValue(referer,forHTTPHeaderField:"Referer") }
        let reply = try await transport.send(req);guard reply.status == 200 else { throw DAVFailure.status(reply.status) }
        do { return try JSON.parse(reply.body) } catch { throw TVError.message("荐片服务未返回有效JSON，可能需要访问验证或接口已变更") }
    }
    private func endpoint(_ source:MediaSource) async throws -> (URL,String) {
        let key = source.ext.text
        if let cached = endpoints[key],Date().timeIntervalSince(cached.0) < 1800 { return (cached.1,cached.2) }
        var candidates:[URL] = []
        if CatalogParser.validHTTP(source.ext.string),let url = URL(string:source.ext.string) { candidates = [url] }
        else {
            if let dns = try? await json(URL(string:"https://dns.alidns.com/resolve?name=swrdsfeiujo25sw.cc&type=TXT")!) {
                for answer in dns["Answer"].array where answer["type"].int == 16 {
                    for suffix in answer["data"].string.replacingOccurrences(of:"\"",with:"").split(separator:",").prefix(4) {
                        let domain = String(suffix).trimmingCharacters(in:.whitespacesAndNewlines)
                        guard !domain.isEmpty,domain.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),let url = URL(string:"https://fan123."+domain) else { continue }
                        candidates.append(url)
                    }
                }
            }
            candidates.append(URL(string:"https://ev5356.970xw.com")!)
        }
        for root in candidates {
            try Task.checkCancellation()
            do {
                let result = try await json(root.appendingPathComponent("api/v2/settings/resourceDomainConfig"),referer:root.absoluteString)
                guard result["data"] != .null else { continue }
                let image = result["data"]["imgDomain"].string.components(separatedBy:",").first ?? ""
                endpoints[key] = (Date(),root,image)
                return (root,image)
            } catch { if error is CancellationError { throw error } }
        }
        throw TVError.message("荐片发布域名和备用服务均不可用，尚不能读取目录")
    }
    private func request(_ source:MediaSource,path:String,query:[String:String]) async throws -> (JSON,URL,String) {
        let (root,image) = try await endpoint(source)
        var parts = URLComponents(url:root.appendingPathComponent(path),resolvingAgainstBaseURL:false)!
        parts.queryItems = query.sorted{$0.key < $1.key}.map{URLQueryItem(name:$0.key,value:$0.value)}
        return (try await json(parts.url!,referer:root.absoluteString),root,image)
    }
    private static func text(_ value:JSON) -> String { if case .number(let n) = value { return n };return value.string }
    private static func item(_ row:JSON,image:String,home:Bool = false) -> MediaItem? {
        let id = text(row[home ? "jump_id" : "id"]),name = row["title"].string
        guard !id.isEmpty,!name.isEmpty else { return nil }
        let raw = row["thumbnail"].string.isEmpty ? row["path"].string : row["thumbnail"].string
        let base = image.hasPrefix("http") ? image : "https://"+image
        let picture = CatalogParser.validHTTP(raw) ? raw : URL(string:raw,relativeTo:URL(string:base))?.absoluteURL.absoluteString ?? ""
        return MediaItem(id:id,name:name,picture:picture,remarks:row["mask"].string)
    }
    public func browse(_ source:MediaSource,keyword:String="",page:Int=1,category:String="") async throws -> [MediaItem] {
        let path:String,query:[String:String]
        if !keyword.isEmpty { path = "api/v2/search/videoV2";query = ["key":keyword,"category_id":"88","page":String(page),"pageSize":"20"] }
        else if ["50","99"].contains(category) { path = "api/dyTag/list";query = ["category_id":category,"page":String(page)] }
        else if !category.isEmpty { path = "api/crumb/list";query = ["fcate_pid":category,"area":"0","year":"0","type":"0","sort":"0","page":String(page),"category_id":""] }
        else { guard page == 1 else { return [] };path = "api/slide/list";query = ["pos_id":"88"] }
        let (root,_,image) = try await request(source,path:path,query:query)
        let data = root["data"],rows = data.array.isEmpty ? data["dataList"].array : data.array
        if case .array = data {} else if case .array = data["dataList"] {} else { throw TVError.message("荐片未返回影片列表") }
        return rows.compactMap{Self.item($0,image:image,home:keyword.isEmpty && category.isEmpty)}
    }
    public func detail(_ source:MediaSource,id:String) async throws -> MediaDetail {
        let (root,_,image) = try await request(source,path:"api/video/detailv2",query:["id":id]),row = root["data"]
        guard let item = Self.item(row,image:image) else { throw TVError.message("荐片详情未返回影片信息") }
        var episodes:[Episode] = []
        for group in row["source_list_source"].array {
            for file in group["source_list"].array {
                let raw = file["url"].string
                guard !raw.isEmpty else { continue }
                episodes.append(Episode(name:file["source_name"].string,url:raw,line:group["name"].string))
            }
        }
        guard !episodes.isEmpty else { throw TVError.message("荐片详情未返回选集") }
        return MediaDetail(item:item,episodes:episodes,synopsis:row["description"].string,metadata:["年份":row["year"].string,"地区":row["area"].string])
    }
    public func resolve(_ source:MediaSource,episode:Episode) async throws -> ResolvedMedia {
        guard CatalogParser.validHTTP(episode.url) else { throw TVError.message("此荐片线路使用特殊P2P／FTP协议，iPhone播放引擎尚未支持，请选择HTTP线路") }
        let (base,_) = try await endpoint(source)
        return ResolvedMedia(url:episode.url,headers:["User-Agent":Self.userAgent,"Referer":base.absoluteString])
    }
}

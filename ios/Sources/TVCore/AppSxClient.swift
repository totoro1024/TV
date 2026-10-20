import Foundation
import CommonCrypto

/// 剧圈/咕咕当前 getappapi 协议；保留每条线路自己的解析参数和请求头。
public actor AppSxClient {
    public static let shared=AppSxClient()
    public let transport:any HTTPTransport
    private var initialized:[String:JSON]=[:]
    public init(transport:any HTTPTransport = NetworkTransport()) { self.transport=transport }
    private func config(_ source:MediaSource) throws -> JSON { try App99Crypto.configuration(source.ext) }
    private func cacheKey(_ source:MediaSource) -> String { source.sourceID+"\u{0}"+source.id+"\u{0}"+source.ext.text }
    public static func crypt(_ data:Data,key:Data,iv:Data,encrypt:Bool) throws -> Data {
        guard [16,24,32].contains(key.count),iv.count == 16 else { throw TVError.message("剧圈加密配置无效") }
        var output=Data(count:data.count+16),written=0;let capacity=output.count
        let status=output.withUnsafeMutableBytes { out in data.withUnsafeBytes { input in key.withUnsafeBytes { key in iv.withUnsafeBytes { iv in
            CCCrypt(CCOperation(encrypt ? kCCEncrypt:kCCDecrypt),CCAlgorithm(kCCAlgorithmAES),CCOptions(kCCOptionPKCS7Padding),key.baseAddress,key.count,iv.baseAddress,input.baseAddress,data.count,out.baseAddress,capacity,&written)
        } } } }
        guard status == kCCSuccess else { throw TVError.message("剧圈响应解密失败") };output.count=written;return output
    }
    private func request(_ source:MediaSource,method:String,params:[String:String]=[:]) async throws -> JSON {
        let config=try config(source),host=config["host"].string.trimmingCharacters(in:CharacterSet(charactersIn:"/"))
        guard CatalogParser.validHTTP(host),let url=URL(string:host+"/api.php/getappapi.index/"+method) else { throw TVError.message("剧圈接口地址无效") }
        var parts=URLComponents();parts.queryItems=params.sorted { $0.key < $1.key }.map { URLQueryItem(name:$0.key,value:$0.value) }
        var request=URLRequest(url:url);request.httpMethod="POST";request.httpBody=Data((parts.percentEncodedQuery?.replacingOccurrences(of:"+",with:"%2B") ?? "").utf8)
        request.allHTTPHeaderFields=["Content-Type":"application/x-www-form-urlencoded","User-Agent":"okhttp/3.14.9","app-version-code":config["version"].string.isEmpty ? "113":config["version"].string,"app-platform":"android"]
        let reply=try await transport.send(request);guard reply.status == 200 else { throw DAVFailure.status(reply.status) }
        let root=try JSON.parse(reply.body)
        if case .object = root["data"] { return root["data"] }
        let raw=root["data"].string
        if raw.hasPrefix("{") { return try JSON.parse(Data(raw.utf8)) }
        guard let cipher=Data(base64Encoded:raw),!cipher.isEmpty else { throw TVError.message("剧圈接口未返回预期数据") }
        let key=Data(config["key"].string.utf8),iv=Data((config["iv"].string.isEmpty ? config["key"].string:config["iv"].string).utf8)
        return try JSON.parse(Self.crypt(cipher,key:key,iv:iv,encrypt:false))
    }
    private func initialize(_ source:MediaSource) async throws -> JSON {
        let key=cacheKey(source);if let value=initialized[key] { return value }
        let value=try await request(source,method:"initV119")
        guard !value["type_list"].array.isEmpty || !value["recommend_list"].array.isEmpty else { throw TVError.message("剧圈初始化缺少分类或推荐") }
        if initialized.count >= 16 { initialized.removeAll() };initialized[key]=value;return value
    }
    public func categories(_ source:MediaSource) async throws -> [(id:String,name:String)] {
        try await initialize(source)["type_list"].array.map { (Self.id($0["type_id"]),$0["type_name"].string) }
    }
    private static func id(_ value:JSON) -> String { value.string.isEmpty ? String(value.int):value.string }
    public func browse(_ source:MediaSource,keyword:String="",page:Int=1,category:String="") async throws -> [MediaItem] {
        let rows:JSON
        if !keyword.isEmpty {
            // 当前 Android 插件的搜索接口固定第一页；分类分页独立处理。
            guard page == 1 else { return [] }
            rows=try await request(source,method:"searchList",params:["keywords":keyword,"type_id":"0","page":"1"])["search_list"]
        } else if !category.isEmpty {
            rows=try await request(source,method:"typeFilterVodList",params:["type_id":category,"page":String(page),"area":"","year":"","class":"","sort":"最新","lang":""])["recommend_list"]
        } else {
            guard page == 1 else { return [] };rows=try await initialize(source)["recommend_list"]
        }
        guard case .array = rows else { throw TVError.message("剧圈未返回影片列表") }
        return try CatalogParser.items(JSON.object(["list":rows]).data)
    }
    public func detail(_ source:MediaSource,id:String) async throws -> MediaDetail {
        let root=try await request(source,method:"vodDetail",params:["vod_id":id])
        let detail=try CatalogParser.detail(JSON.object(["list":.array([root["vod"]])]).data)
        var episodes:[Episode]=[]
        for group in root["vod_play_list"].array {
            for entry in group["urls"].array {
                guard !entry["url"].string.isEmpty else { continue }
                let payload=JSON.object(["entry":entry,"player":group["player_info"],"vod_id":.string(id)])
                episodes.append(Episode(name:entry["name"].string,url:payload.text,line:group["player_info"]["show"].string))
            }
        }
        return MediaDetail(item:detail.item,episodes:episodes,synopsis:detail.synopsis,metadata:detail.metadata)
    }
    public func resolve(_ source:MediaSource,episode:Episode) async throws -> ResolvedMedia {
        let payload=try JSON.parse(Data(episode.url.utf8)),entry=payload["entry"],player=payload["player"],raw=entry["url"].string
        var headers:[String:String]=[:]
        if case .object = player["headers"] { headers=player["headers"].object.mapValues(\.string) }
        else if let object=try? JSON.parse(Data(player["headers"].string.utf8)) { headers=object.object.mapValues(\.string) }
        if !player["user_agent"].string.isEmpty { headers["User-Agent"]=player["user_agent"].string }
        if CatalogParser.validHTTP(raw),["mp4","m3u8","mkv","flv"].contains(URL(string:raw)?.pathExtension.lowercased() ?? ""),(entry["parse_api_url"].string.isEmpty || player["parse_type"].string == "0" || player["parse_type"].int == 0 && player["parse_type"].string.isEmpty) { return ResolvedMedia(url:raw,headers:headers) }
        let parser=player["parse"].string
        if CatalogParser.validHTTP(parser),let url=URL(string:parser+raw) {
            let reply=try await transport.send(URLRequest(url:url))
            if reply.status == 200,let root=try? JSON.parse(reply.body) {
                let media=root["url"].string.isEmpty ? root["data"]["url"].string:root["url"].string
                if CatalogParser.validHTTP(media) { return ResolvedMedia(url:media,headers:headers) }
            }
        }
        throw TVError.message("当前剧圈线路需要额外的播放授权或网页解析，请尝试其他线路")
    }
}

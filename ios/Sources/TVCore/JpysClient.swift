import Foundation
import CryptoKit

/// 文采原插件的毫秒时间签名接口，分集沿用 Android 的 vodId@nid 标识。
public actor JpysClient {
    public static let shared=JpysClient()
    public let transport:any HTTPTransport
    private let device=UUID().uuidString.replacingOccurrences(of:"-",with:"")
    private static let salt="cb808529bae6b6be45ecfab29a4889bc"
    public init(transport:any HTTPTransport=NetworkTransport()) { self.transport=transport }
    public static let userAgent="Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36"
    public static func verificationURL(_ source:MediaSource) throws -> URL {
        URL(string:try JpysClient.originAddress(source))!
    }
    private func origin(_ source:MediaSource) throws -> String { try Self.originAddress(source) }
    private static func originAddress(_ source:MediaSource) throws -> String {
        let raw=source.ext.string.trimmingCharacters(in:.whitespacesAndNewlines)
        if CatalogParser.validHTTP(raw) { return raw.trimmingCharacters(in:CharacterSet(charactersIn:"/")) }
        if let decoded=try? App99Crypto.decodePluginText(raw),CatalogParser.validHTTP(decoded) { return decoded.trimmingCharacters(in:CharacterSet(charactersIn:"/")) }
        return "https://www.ghw9zwp5.com"
    }
    public static func signature(query:String,timestamp:String)->String {
        let value=(query.isEmpty ? "" : query+"&")+"key="+salt+"&t="+timestamp
        let md5=Insecure.MD5.hash(data:Data(value.utf8)).map{String(format:"%02x",$0)}.joined()
        return Insecure.SHA1.hash(data:Data(md5.utf8)).map{String(format:"%02x",$0)}.joined()
    }
    private func request(_ source:MediaSource,path:String,params:[(String,String)]=[]) async throws -> JSON {
        let base=try origin(source),timestamp=String(SyncDocument.now)
        var parts=URLComponents(string:base+"/api/mw-movie/anonymous/"+path)!
        parts.queryItems=params.isEmpty ? nil:params.map{URLQueryItem(name:$0.0,value:$0.1)}
        let signing=params.map{$0.0+"="+$0.1}.joined(separator:"&")
        var req=URLRequest(url:parts.url!);req.allHTTPHeaderFields=["User-Agent":Self.userAgent,"sign":Self.signature(query:signing,timestamp:timestamp),"T":timestamp,"deviceid":device]
        if let cookie=await MusicVerificationSession.shared.header(for:parts.url!) { req.setValue(cookie,forHTTPHeaderField:"Cookie") }
        let reply=try await transport.send(req);if reply.status==403 { throw TVError.message("文采需要网站验证（HTTP403），可打开验证后重试") };guard reply.status==200 else { throw DAVFailure.status(reply.status) }
        let root=try JSON.parse(reply.body);guard root["data"] != .null else { throw TVError.message("文采接口未返回节目数据") };return root["data"]
    }
    private static func text(_ x:JSON)->String { x.string.isEmpty ? String(x.int):x.string }
    private static func item(_ row:JSON)->MediaItem? {
        let id=text(row["vodId"]),name=row["vodName"].string
        guard !id.isEmpty,id != "0",!name.isEmpty else { return nil }
        return MediaItem(id:id,name:name,picture:row["vodPic"].string,remarks:row["vodVersion"].string)
    }
    public func browse(_ source:MediaSource,keyword:String="",page:Int=1,category:String="") async throws -> [MediaItem] {
        let rows:JSON
        if !keyword.isEmpty {
            guard page==1 else { return [] }
            rows=try await request(source,path:"video/searchByWord",params:[("keyword",keyword),("pageNum","1"),("pageSize","8")])["result"]["list"]
        } else if !category.isEmpty {
            // 接口查询顺序与签名规范分别保持原 Android 实现。
            let base=try origin(source),timestamp=String(SyncDocument.now)
            var parts=URLComponents(string:base+"/api/mw-movie/anonymous/video/list")!
            parts.queryItems=[URLQueryItem(name:"type1",value:category),URLQueryItem(name:"pageNum",value:String(page)),URLQueryItem(name:"area",value:""),URLQueryItem(name:"year",value:"")]
            var req=URLRequest(url:parts.url!);req.allHTTPHeaderFields=["sign":Self.signature(query:"area=&pageNum=\(page)&type1=\(category)&year=",timestamp:timestamp),"T":timestamp,"User-Agent":"Mozilla/5.0"]
            if let cookie=await MusicVerificationSession.shared.header(for:parts.url!) { req.setValue(cookie,forHTTPHeaderField:"Cookie") }
        let reply=try await transport.send(req);if reply.status==403 { throw TVError.message("文采需要网站验证（HTTP403），可打开验证后重试") };guard reply.status==200 else { throw DAVFailure.status(reply.status) };rows=try JSON.parse(reply.body)["data"]["list"]
        } else {
            guard page==1 else { return [] };rows=try await request(source,path:"home/hotSearch")
        }
        guard case .array=rows else { throw TVError.message("文采接口没有返回节目列表") };return rows.array.compactMap(Self.item)
    }
    public func detail(_ source:MediaSource,id:String) async throws -> MediaDetail {
        let row=try await request(source,path:"video/detail",params:[("id",id)])
        var value=row;value["vodId"] = .string(id)
        guard let item=Self.item(value) else { throw TVError.message("文采影片详情无效") }
        let episodes=row["episodeList"].array.compactMap { entry -> Episode? in
            let nid=Self.text(entry["nid"]);guard !nid.isEmpty else { return nil }
            return Episode(name:entry["name"].string,url:id+"@"+nid,line:"文采")
        }
        return MediaDetail(item:item,episodes:episodes,synopsis:row["vodBlurb"].string.isEmpty ? row["vodContent"].string:row["vodBlurb"].string)
    }
    public func resolve(_ source:MediaSource,episode:Episode) async throws -> ResolvedMedia {
        let ids=episode.url.components(separatedBy:"@");guard ids.count==2 else { throw TVError.message("文采选集标识无效") }
        let row=try await request(source,path:"v2/video/episode/url",params:[("clientType","3"),("id",ids[0]),("nid",ids[1])])
        let raw=row["list"].array.first?["url"].string ?? ""
        guard CatalogParser.validHTTP(raw) else { throw TVError.message("文采未返回播放地址") }
        let base=try origin(source)
        return ResolvedMedia(url:raw,headers:["User-Agent":"Mozilla/5.0","Origin":base,"Referer":base])
    }
}

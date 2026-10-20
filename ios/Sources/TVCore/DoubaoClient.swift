import Foundation

/// 对照 Android Doubao 的赛事回放接口；直播入口另由直播模块处理。
public actor DoubaoClient {
    public static let shared=DoubaoClient()
    public let transport:any HTTPTransport
    private var entries:[String:JSON]=[:]
    public init(transport:any HTTPTransport=NetworkTransport()) { self.transport=transport }
    public static let categories=[(id:"1",name:"足球回放"),(id:"2",name:"篮球回放")]
    private func rows(page:Int,category:String="") async throws -> [JSON] {
        var parts=URLComponents(string:"https://www.doubaozhibo.com/api/v1/playbacks")!
        parts.queryItems=[URLQueryItem(name:"page",value:String(page)),URLQueryItem(name:"pageSize",value:"20")]
        if !category.isEmpty { parts.queryItems?.append(URLQueryItem(name:"dataType",value:category)) }
        var req=URLRequest(url:parts.url!);req.allHTTPHeaderFields=["User-Agent":"Mozilla/5.0","Referer":"https://www.doubaozhibo.com/"]
        let reply=try await transport.send(req);guard reply.status==200 else { throw DAVFailure.status(reply.status) }
        let root=try JSON.parse(reply.body);guard case .array=root["data"]["list"] else { throw TVError.message("多多回放接口未返回比赛列表") }
        for row in root["data"]["list"].array {
            let id=Self.id(row["playback"]["id"]);if !id.isEmpty { entries[id]=row }
        }
        if entries.count>1200 { entries=Dictionary(uniqueKeysWithValues:root["data"]["list"].array.map { (Self.id($0["playback"]["id"]),$0) }) }
        return root["data"]["list"].array
    }
    private static func id(_ value:JSON) -> String { value.string.isEmpty ? value.int>0 ? String(value.int):"":value.string }
    public func browse(keyword:String="",page:Int=1,category:String="") async throws -> [MediaItem] {
        let rows=try await rows(page:max(1,page),category:category)
        return rows.compactMap { row in
            let item=row["playback"],id=Self.id(item["id"]),title=item["title"].string
            guard !id.isEmpty,!title.isEmpty,keyword.isEmpty || title.localizedCaseInsensitiveContains(keyword) else { return nil }
            return MediaItem(id:id,name:title,remarks:row["schedule"]["league"].string)
        }
    }
    public func detail(id:String) async throws -> MediaDetail {
        guard !id.isEmpty,id.allSatisfy(\.isNumber) else { throw TVError.message("回放标识无效") }
        if entries[id]==nil {
            for page in 1...20 { let next=try await rows(page:page);if entries[id] != nil || next.count<20 { break };try Task.checkCancellation() }
        }
        guard let row=entries[id] else { throw TVError.message("当前回放列表没有此比赛，可能已过期或超出最近400条范围") }
        let item=row["playback"]
        let episodes=item["lines"].array.compactMap { line -> Episode? in
            let raw=line["proxyUrl"].string
            let url=URL(string:raw,relativeTo:URL(string:"https://www.doubaozhibo.com/")!)?.absoluteURL.absoluteString ?? ""
            guard CatalogParser.validHTTP(url) else { return nil }
            let label=line["title"].string.isEmpty ? "线路 "+Self.id(line["lineNo"]):line["title"].string
            return Episode(name:item["title"].string,url:url,line:label)
        }
        return MediaDetail(item:MediaItem(id:id,name:item["title"].string),episodes:episodes,synopsis:row["schedule"]["league"].string)
    }
    public func resolve(_ episode:Episode) throws -> ResolvedMedia {
        guard CatalogParser.validHTTP(episode.url) else { throw TVError.message("回放线路地址无效") }
        return ResolvedMedia(url:episode.url,headers:["Referer":"https://www.doubaozhibo.com/","User-Agent":"Mozilla/5.0"])
    }
}

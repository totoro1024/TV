import Foundation
import CryptoKit

/// 按 Android Tingshu275 的发布页、章节协议与原生签名移植。
public actor AudioBookClient {
    public static let shared=AudioBookClient()
    public static let categories=[(id:"6",name:"玄幻奇幻"),(id:"7",name:"都市言情"),(id:"8",name:"宫斗女频"),(id:"9",name:"官场商战"),(id:"10",name:"武侠仙侠"),(id:"11",name:"刑侦推理"),(id:"12",name:"探险科幻"),(id:"13",name:"重生穿越"),(id:"14",name:"恐怖惊悚"),(id:"15",name:"文学历史"),(id:"49",name:"两性情感")]
    private static let publisher="http://117.72.112.234:8090/config/tingchina2025.txt"
    private static let signingSuffix="J9gSpfUlzYxE8Hn5IXiGaD2jVMrwAm0K"
    public let transport:any HTTPTransport
    private var root:URL?
    public init(transport:any HTTPTransport=NetworkTransport()) { self.transport=transport }
    public static func signature(_ timestamp:String) -> String {
        func md5(_ text:String)->String { Insecure.MD5.hash(data:Data(text.utf8)).map {String(format:"%02x",$0)}.joined() }
        return md5(md5(timestamp+signingSuffix)+signingSuffix)
    }
    private func base() async throws -> URL {
        if let root { return root }
        let response=try await transport.send(URLRequest(url:URL(string:Self.publisher)!))
        guard response.status==200,let address=String(data:response.body,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines),CatalogParser.validHTTP(address),let root=URL(string:address) else { throw TVError.message("有声接口发布地址读取失败") }
        self.root=root;return root
    }
    private func request(_ path:String,params:[String:String]=[:]) async throws -> JSON {
        let root=try await base();var parts=URLComponents(url:root.appendingPathComponent(path),resolvingAgainstBaseURL:true)!
        parts.queryItems=params.sorted { $0.key<$1.key }.map { URLQueryItem(name:$0.key,value:$0.value) }
        var req=URLRequest(url:parts.url!);req.setValue("Mozilla/5.0",forHTTPHeaderField:"User-Agent")
        let reply=try await transport.send(req);guard reply.status==200 else { throw DAVFailure.status(reply.status) }
        return try JSON.parse(reply.body)
    }
    private static func text(_ value:JSON)->String { value.string.isEmpty ? value.int>0 ? String(value.int):"":value.string }
    public func browse(keyword:String="",page:Int=1,category:String="6") async throws -> [MediaItem] {
        let rows:[JSON]
        if !keyword.isEmpty {
            guard page==1 else { return [] }
            let response=try await request("search",params:["search":keyword])
            guard case .array=response["data"] else { throw TVError.message("有声搜索接口未返回列表") };rows=response["data"].array
        } else {
            let response=try await request("categoryList",params:["size":"10","page":String(page),"categoryId":category.isEmpty ? "6":category])
            guard case .array=response["data"]["list"] else { throw TVError.message("有声分类接口未返回列表") };rows=response["data"]["list"].array
        }
        return rows.compactMap { row in
            let id=Self.text(row["id"]),name=row["bookTitle"].string
            guard !id.isEmpty,!name.isEmpty else { return nil }
            return MediaItem(id:id,name:name,picture:row["bookImage"].string,remarks:row["bookAnchor"].string)
        }
    }
    public func detail(id:String) async throws -> MediaDetail {
        guard !id.isEmpty,id.allSatisfy(\.isNumber) else { throw TVError.message("有声书标识无效") }
        let row=try await request("book",params:["bookId":id])["data"]["bookData"]
        guard !row["bookTitle"].string.isEmpty else { throw TVError.message("有声书详情不存在") }
        let response=try await request("chapter",params:["size":"9999","page":"1","sort":"asc","bookId":id])
        guard case .array=response["data"]["list"] else { throw TVError.message("有声章节列表无效") }
        let episodes=response["data"]["list"].array.compactMap { chapter -> Episode? in
            let chapterID=Self.text(chapter["chapterId"])
            guard !chapterID.isEmpty else { return nil }
            return Episode(name:chapter["title"].string,url:chapterID+"|||"+id,line:row["bookAnchor"].string.isEmpty ? "有声小说":row["bookAnchor"].string)
        }
        if response["data"]["count"].int>Int64(episodes.count) { throw TVError.message("章节超过接口单次返回上限，未返回不完整选集") }
        return MediaDetail(item:MediaItem(id:id,name:row["bookTitle"].string,picture:row["bookImage"].string,remarks:row["bookAnchor"].string),episodes:episodes,synopsis:row["bookDesc"].string)
    }
    public func resolve(_ episode:Episode) async throws -> ResolvedMedia {
        let ids=episode.url.components(separatedBy:"|||")
        guard ids.count==2,ids.allSatisfy({!$0.isEmpty && $0.allSatisfy(\.isNumber)}) else { throw TVError.message("有声章节标识无效") }
        let timestamp=String(SyncDocument.now)
        let response=try await request("AppGetChapterUrl2023",params:["timeStamp":timestamp,"uid":"","chapterId":ids[0],"addItParapet":Self.signature(timestamp),"bookId":ids[1]])
        guard CatalogParser.validHTTP(response["src"].string) else { throw TVError.message("有声接口未返回音频地址，章节可能已失效或需要授权") }
        return ResolvedMedia(url:response["src"].string,headers:["User-Agent":"listen/1.8.9 (Linux;Android 12) ExoPlayerLib/2.8.4"])
    }
}

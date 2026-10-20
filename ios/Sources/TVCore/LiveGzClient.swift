import Foundation

/// 吃瓜体育原插件的赛事与线路接口；赛事开始前无可播放线路时如实提示。
public actor LiveGzClient {
    public static let shared = LiveGzClient()
    public static let categories = [(id:"1-0-0",name:"热播"),(id:"0-37-0",name:"NBA"),(id:"0-0-1",name:"足球"),(id:"0-0-2",name:"篮球")]
    public let transport: any HTTPTransport
    private static let key = Data("KANGEQIU@8868!~.".utf8), iv = Data("0200010900030207".utf8)
    public init(transport: any HTTPTransport = NetworkTransport()) { self.transport = transport }
    private static func text(_ x:JSON) -> String { x.string.isEmpty ? String(x.int) : x.string }
    private func request(_ path:String, body:JSON) async throws -> JSON {
        let encoded = try AppSxClient.crypt(body.data,key:Self.key,iv:Self.iv,encrypt:true).base64EncodedString()
        var parts=URLComponents();parts.queryItems=[URLQueryItem(name:"parameter",value:encoded)]
        var req=URLRequest(url:URL(string:"https://api.moe3dze.com/gz/live/"+path+"?parameter=key")!);req.httpMethod="POST"
        req.httpBody=Data((parts.percentEncodedQuery?.replacingOccurrences(of:"+",with:"%2B") ?? "").utf8)
        req.allHTTPHeaderFields=["Content-Type":"application/x-www-form-urlencoded","User-Agent":"okhttp/3.12.0","client-version":"3.0.4.0"]
        let reply=try await transport.send(req);guard reply.status==200 else { throw DAVFailure.status(reply.status) }
        let envelope=try JSON.parse(reply.body)
        guard let encrypted=Data(base64Encoded:envelope["data"].string,options:.ignoreUnknownCharacters),!encrypted.isEmpty else { throw TVError.message("吃瓜赛事接口未返回加密数据") }
        return try JSON.parse(AppSxClient.crypt(encrypted,key:Self.key,iv:Self.iv,encrypt:false))
    }
    private static func item(_ x:JSON)->MediaItem {
        let id=[text(x["mid"]),text(x["match_id"]),text(x["ball_type"])].joined(separator:"-")
        return MediaItem(id:id,name:x["home"]["name"].string+" vs "+x["visiting"]["name"].string,picture:x["home"]["logo"].string,remarks:x["match_status_info"].string+" "+x["event_name"].string)
    }
    public func browse(keyword:String="",page:Int=1,category:String="") async throws -> [MediaItem] {
        guard page==1 else { return [] }
        let ids=(category.isEmpty ? "1-0-0" : category).components(separatedBy:"-")
        guard ids.count==3 else { throw TVError.message("吃瓜赛事分类无效") }
        let rows=try await request("sports",body:.object(["frame":.string("0"),"hot":.string(ids[0]),"tag":.string(ids[1]),"type":.string(ids[2])])).array
        // Android 此源没有远程搜索；保留赛事标题筛选，不伪造远程搜索。
        return rows.map(Self.item).filter { keyword.isEmpty || $0.name.localizedCaseInsensitiveContains(keyword) }
    }
    public func detail(id:String) async throws -> MediaDetail {
        let ids=id.components(separatedBy:"-");guard ids.count==3 else { throw TVError.message("吃瓜赛事标识无效") }
        let row=try await request("detail",body:.object(["ball_type":.string(ids[2]),"match_id":.string(ids[1]),"mid":.string(ids[0])]))
        let episodes=row["live_line"].array.enumerated().compactMap { index,line -> Episode? in
            guard CatalogParser.validHTTP(line["m3u8"].string) else { return nil }
            return Episode(name:String(index+1),url:line["m3u8"].string,line:line["name"].string)
        }
        return MediaDetail(item:Self.item(row),episodes:episodes,synopsis:row["match_status_info"].string)
    }
}

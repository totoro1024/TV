import Foundation

/// Android 的纯搜索网盘入口；查询与详情分离，Cookie 只交给对应网盘客户端。
public struct CloudSearchClient:Sendable {
    public static let plugins=["csp_YpanSoGuard","csp_BpanSoGuard","csp_S_zpsGuard"]
    public var transport:any HTTPTransport
    public init(transport:any HTTPTransport=NetworkTransport()) { self.transport=transport }
    public func search(_ source:MediaSource,keyword:String,page:Int=1) async throws -> [MediaItem] {
        guard !keyword.isEmpty else { return [] }
        var request:URLRequest
        let melost=["csp_YpanSoGuard","csp_BpanSoGuard"].contains(source.address)
        let baidu=source.address=="csp_BpanSoGuard"
        if melost {
            request=URLRequest(url:URL(string:"https://www.melost.cn/v1/search/disk")!);request.httpMethod="POST"
            request.httpBody=JSON.object(["page":.integer(Int64(max(1,page))),"q":.string(keyword),"user":.string(""),"exact":.bool(true),"distinct":.bool(true),"share_time":.string(""),"order":.string("create_desc"),"size":.integer(15),"type":.string(baidu ? "BDY":"QUARK"),"exclude_user":.array([]),"format":.array([".mp4",".mkv",".flv",".rmvb",".wmv",".mov",".m3u8",".avi",".mpg",".mpeg"].map(JSON.string)),"adv_params":.object(["wechat_pwd":.string(""),"platform":.string("pc")])]).data
            request.allHTTPHeaderFields=["Content-Type":"application/json","User-Agent":"Mozilla/5.0","Referer":"https://www.melost.cn/film/","Origin":"https://www.melost.cn"]
        } else {
            guard page==1 else { return [] }
            let config=try App99Crypto.configuration(source.ext)
            let base=config["siteUrl"].string.isEmpty ? "https://so.252035.xyz/":config["siteUrl"].string
            guard CatalogParser.validHTTP(base),let url=URL(string:base) else { throw TVError.message("盘搜接口配置无效") }
            var parts=URLComponents(url:url.appendingPathComponent("api/search"),resolvingAgainstBaseURL:true)!
            parts.queryItems=[URLQueryItem(name:"kw",value:keyword)];request=URLRequest(url:parts.url!);request.setValue("Mozilla/5.0",forHTTPHeaderField:"User-Agent")
        }
        let reply=try await transport.send(request);guard reply.status==200 else { throw DAVFailure.status(reply.status) }
        let root=try JSON.parse(reply.body),rows:[(String,JSON)]
        if melost {
            guard case .array=root["data"]["list"] else { throw TVError.message("盘她接口没有返回搜索列表") }
            rows=root["data"]["list"].array.map { (baidu ? "baidu":"quark",$0) }
        } else {
            if root["code"] == .integer(0),root["data"]["total"] == .integer(0),root["data"]["merged_by_type"] == .null { return [] }
            guard case .object=root["data"]["merged_by_type"] else { throw TVError.message("盘搜接口没有返回分类结果") }
            rows=root["data"]["merged_by_type"].object.sorted { $0.key<$1.key }.flatMap { key,values in values.array.map { (key,$0) } }
        }
        var seen=Set<String>()
        return rows.compactMap { type,row in
            let raw=row[melost ? "link":"url"].string
            guard CatalogParser.validHTTP(raw),var parts=URLComponents(string:raw) else { return nil }
            let password=row[melost ? "disk_pass":"password"].string
            if !password.isEmpty,parts.queryItems?.contains(where:{$0.name=="pwd"}) != true { parts.queryItems=(parts.queryItems ?? [])+[URLQueryItem(name:"pwd",value:password)] }
            guard let url=parts.url?.absoluteString,seen.insert(url).inserted else { return nil }
            let rawName=row[melost ? "disk_name":"note"].string
            let name=rawName.replacingOccurrences(of:"<[^>]*>",with:"",options:.regularExpression)
            return MediaItem(id:url,name:name.isEmpty ? keyword:name,picture:row["images"].array.first?.string ?? "",remarks:type=="quark" ? "夸克网盘":type=="uc" ? "UC网盘":type+"（此网盘播放尚未移植）")
        }
    }
    public func detail(id:String,cookie:String?,ucCookie:String? = nil) async throws -> MediaDetail {
        let drive:CloudDrive
        switch URL(string:id)?.host {
        case "pan.quark.cn": drive = .quark
        case "drive.uc.cn": drive = .uc
        default: throw TVError.message("此网盘的登录及播放协议仍待移植")
        }
        guard let credential = drive == .uc ? ucCookie : cookie, !credential.isEmpty else { throw TVError.message("请先通过 WebDAV 同步\(drive.name) Cookie") }
        let line = drive == .uc ? "优汐原1" : "夸父原1"
        let files = try await QuarkClient(cookie:credential,transport:transport,drive:drive).episodes(shareURL:id,line:line,movieName:"")
        guard !files.isEmpty else { throw TVError.message("分享目录内没有可播放的视频") }
        let episodes = drive == .uc ? files : files + files.map { Episode(name:$0.name,url:$0.url,line:"夸父智1") }
        return MediaDetail(item:MediaItem(id:id,name:files.first?.name ?? "网盘分享"),episodes:episodes,synopsis:"通过同步的\(drive.name) Cookie读取分享目录")
    }
}

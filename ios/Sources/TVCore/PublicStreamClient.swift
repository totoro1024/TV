import Foundation
import SwiftSoup
import CryptoKit

/// 对照当前配置中的虎牙、斗鱼及兔小贝规则移植；不依赖 Android 的 drpy 运行时。
public struct PublicStreamClient:Sendable {
    public var transport:any HTTPTransport
    public init(transport:any HTTPTransport=NetworkTransport()) { self.transport=transport }
    public static func provider(_ source:MediaSource)->String? {
        let path=(source.ext.string.removingPercentEncoding ?? source.ext.string)
        if path.hasSuffix("/虎牙.js") { return "huya" }
        if path.hasSuffix("/斗鱼直播.js") { return "douyu" }
        if path.hasSuffix("/兔小贝.js") { return "children" }
        return nil
    }
    public static func categories(_ source:MediaSource)->[(id:String,name:String)] {
        switch provider(source) {
        case "huya":return [("2135","娱乐"),("1","网游"),("1732","单机"),("2336","手游")]
        case "douyu":return [("yltj","娱乐天地"),("LOL","网游竞技"),("djry","单机热游"),("syxx","手游休闲"),("yz","颜值"),("kjwh","科技文化"),("yp","语音互动"),("voice","语音直播"),("znl","正能量")]
        default:return [("2","儿歌"),("3","故事"),("4","国学"),("25","启蒙")]
        }
    }
    private static let androidUA="Mozilla/5.0 (Linux; Android 11; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36"
    private static let mobileUA="Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    private static func text(_ x:JSON)->String { x.string.isEmpty ? String(x.int):x.string }
    private func fetch(_ address:String,query:[String:String]=[:],post:Bool=false) async throws -> Data {
        guard var parts=URLComponents(string:address) else { throw TVError.message("站点地址无效") }
        let items=query.sorted{$0.key<$1.key}.map { URLQueryItem(name:$0.key,value:$0.value) }
        if !post && !items.isEmpty { parts.queryItems=(parts.queryItems ?? [])+items }
        var req=URLRequest(url:parts.url!);req.setValue(Self.androidUA,forHTTPHeaderField:"User-Agent")
        if post { var body=URLComponents();body.queryItems=items;req.httpMethod="POST";req.httpBody=Data((body.percentEncodedQuery?.replacingOccurrences(of:"+",with:"%2B") ?? "").utf8);req.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type") }
        for _ in 0..<5 {
            let reply=try await transport.send(req)
            if [301,302,303,307,308].contains(reply.status),let location=reply.headers.first(where:{$0.key.lowercased()=="location"})?.value,let target=URL(string:location,relativeTo:req.url)?.absoluteURL {
                let before=req.url?.host ?? "",after=target.host ?? ""
                guard ["http","https"].contains(target.scheme ?? ""),before==after || before.hasSuffix(".tuxiaobei.com") && after.hasSuffix(".tuxiaobei.com") else { throw TVError.message("站点跳转到了未识别的地址") }
                req.url=target
                if reply.status==303 || (req.httpMethod=="POST" && [301,302].contains(reply.status)) { req.httpMethod="GET";req.httpBody=nil }
                continue
            }
            guard reply.status==200 else { throw DAVFailure.status(reply.status) };return reply.body
        }
        throw TVError.message("站点跳转次数过多")
    }
    private static func liveItems(_ rows:[JSON],huya:Bool,search:Bool=false)->[MediaItem] {
        rows.compactMap { row in
            let id=text(row[huya ? (search ? "room_id":"profileRoom"):(search ? "roomId":"rid")])
            let name=row[huya ? (search ? "gameName":"introduction"):"roomName"].string
            guard !id.isEmpty,id != "0",!name.isEmpty else { return nil }
            return MediaItem(id:id,name:name,picture:row[huya ? (search ? "game_screenshot":"screenshot"):"roomSrc"].string,remarks:row[huya ? (search ? "game_nick":"nick"):"nickname"].string)
        }
    }
    public func browse(_ source:MediaSource,keyword:String="",page:Int=1,category:String="") async throws -> [MediaItem] {
        switch Self.provider(source) {
        case "huya":
            if !keyword.isEmpty {
                guard page==1 else { return [] }
                let root=try JSON.parse(await fetch("https://search.cdn.huya.com/",query:["m":"Search","do":"getSearchContent","q":keyword,"uid":"0","v":"4","typ":"-5","livestate":"0","rows":"40","start":"0"]))
                guard case .array=root["response"]["3"]["docs"] else { throw TVError.message("虎牙搜索未返回直播列表") }
                return Self.liveItems(root["response"]["3"]["docs"].array,huya:true,search:true)
            }
            let root=try JSON.parse(await fetch("https://www.huya.com/cache.php",query:["m":"LiveList","do":"getLiveListByPage","gameId":category.isEmpty ? "2168":category,"tagAll":"0","page":String(page)]))
            guard case .array=root["data"]["datas"] else { throw TVError.message("虎牙未返回直播列表") };return Self.liveItems(root["data"]["datas"].array,huya:true)
        case "douyu":
            let rows:[JSON]
            if !keyword.isEmpty {
                let root=try JSON.parse(await fetch("https://m.douyu.com/api/search/liveRoom",query:["did":"10000000000000000000000000001501","limit":"20","offset":String((page-1)*20),"sk":keyword],post:true))
                guard case .array=root["data"]["list"] else { throw TVError.message("斗鱼搜索未返回直播列表") };rows=root["data"]["list"].array
            } else if !category.isEmpty {
                let root=try JSON.parse(await fetch("https://m.douyu.com/api/room/list",query:["page":String(page),"type":category]))
                guard case .array=root["data"]["list"] else { throw TVError.message("斗鱼分类未返回直播列表") };rows=root["data"]["list"].array
            } else {
                guard page==1 else { return [] }
                let root=try JSON.parse(await fetch("https://m.douyu.com/api/home/mix"))
                guard case .array=root["data"] else { throw TVError.message("斗鱼未返回推荐列表") };rows=root["data"].array.flatMap{$0["list"].array}
            }
            return Self.liveItems(rows,huya:false,search:!keyword.isEmpty)
        case "children":
            if !keyword.isEmpty || category.isEmpty {
                guard page==1 else { return [] }
                let data=try await fetch(keyword.isEmpty ? "https://www.tuxiaobei.com":"https://www.tuxiaobei.com/search/"+(keyword.addingPercentEncoding(withAllowedCharacters:.urlPathAllowed) ?? ""),query:[:])
                let doc=try SwiftSoup.parse(String(decoding:data,as:UTF8.self),"https://www.tuxiaobei.com")
                let items = try doc.select(keyword.isEmpty ? ".pic-list.list-box .items":".list-con .items").array().compactMap { row -> MediaItem? in
                    let href=try row.select("a").first()?.attr("href") ?? "",name=try row.select(".text").text()
                    guard let url=URL(string:href,relativeTo:URL(string:"https://www.tuxiaobei.com")),url.path.hasPrefix("/play/"),!name.isEmpty else { return nil }
                    return MediaItem(id:url.lastPathComponent,name:name,picture:try row.select("mip-img").attr("src"),remarks:try row.select(keyword.isEmpty ? ".all":".time").text())
                }
                // 原站首页已改为App宣传页，使用仍在线的儿歌分类作为默认内容。
                if items.isEmpty && keyword.isEmpty { return try await browse(source,page:1,category:"2") }
                return items
            }
            let bytes=try await fetch("https://www.tuxiaobei.com/list/mip-data",query:["typeId":category,"page":String(page),"callback":""])
            let raw=String(decoding:bytes,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
            let wrapper = raw.hasSuffix(";") ? String(raw.dropLast()).trimmingCharacters(in:.whitespacesAndNewlines) : raw
            let content = wrapper.hasPrefix("(") && wrapper.hasSuffix(")") ? String(wrapper.dropFirst().dropLast()) : wrapper
            let root:JSON
            do { root = try JSON.parse(Data(content.utf8)) }
            catch { throw TVError.message("儿童分类接口未返回有效数据") }
            guard case .array=root["data"]["items"] else { throw TVError.message("儿童分类未返回视频列表") }
            return root["data"]["items"].array.map { MediaItem(id:Self.text($0["video_id"]),name:$0["name"].string,picture:$0["image"].string,remarks:$0["duration_string"].string) }
        default:throw TVError.message("未知的原生脚本适配器")
        }
    }
    public func detail(_ source:MediaSource,id:String) async throws -> MediaDetail {
        let provider=Self.provider(source),origin=provider=="huya" ? "https://m.huya.com/":provider=="douyu" ? "https://m.douyu.com/":"https://www.tuxiaobei.com/play/"
        guard !id.isEmpty,id.allSatisfy(\.isNumber) else { throw TVError.message("节目或直播间编号无效") }
        let address=origin+id,data=try await fetch(address),doc=try SwiftSoup.parse(String(decoding:data,as:UTF8.self),origin)
        let title=try doc.title().components(separatedBy:CharacterSet(charactersIn:"-_|")).first ?? "节目"
        return MediaDetail(item:MediaItem(id:id,name:title),episodes:[Episode(name:provider=="children" ? "播放":"直播",url:address,line:provider=="huya" ? "虎牙":provider=="douyu" ? "斗鱼":"儿童启蒙")],synopsis:"")
    }
    public func resolve(_ source:MediaSource,episode:Episode) async throws -> ResolvedMedia {
        if Self.provider(source)=="huya" {
            let id=URL(string:episode.url)?.lastPathComponent ?? ""
            let root=try JSON.parse(await fetch("https://mp.huya.com/cache.php",query:["m":"Live","do":"profileRoom","roomid":id]))
            let raw=root["data"]["stream"]["flv"]["multiLine"].array.first?["url"].string ?? ""
            guard let parts=URLComponents(string:raw),let url=parts.url,let fm=parts.queryItems?.first(where:{$0.name=="fm"})?.value,let bytes=Data(base64Encoded:fm),let decoded=String(data:bytes,encoding:.utf8),let prefix=decoded.split(separator:"_").first,let time=parts.queryItems?.first(where:{$0.name=="wsTime"})?.value else { throw TVError.message("虎牙直播间未开播或未返回有效线路") }
            let stream=url.deletingPathExtension().lastPathComponent,sequence=String(SyncDocument.now)+"0000"
            let secret=Insecure.MD5.hash(data:Data([String(prefix),"0",stream,sequence,time].joined(separator:"_").utf8)).map{String(format:"%02x",$0)}.joined()
            var target=URLComponents(url:url,resolvingAgainstBaseURL:true)!
            target.queryItems=[URLQueryItem(name:"wsSecret",value:secret),URLQueryItem(name:"wsTime",value:time),URLQueryItem(name:"u",value:"0"),URLQueryItem(name:"seqid",value:sequence)]+(parts.queryItems ?? []).filter{!["fm","wsSecret","wsTime","u","seqid"].contains($0.name)}
            guard let address=target.url?.absoluteString else { throw TVError.message("虎牙媒体地址无效") }
            if var hls=URLComponents(string:address),hls.path.hasSuffix(".flv") {
                hls.path=String(hls.path.dropLast(4))+".m3u8";hls.host=hls.host?.replacingOccurrences(of:".flv.",with:".hls.")
                if let url=hls.url {
                    var probe=URLRequest(url:url);probe.setValue("Mozilla/5.0",forHTTPHeaderField:"User-Agent")
                    if let reply=try? await transport.send(probe),reply.status==200,reply.body.starts(with:Data("#EXTM3U".utf8)) { return ResolvedMedia(url:url.absoluteString,headers:["User-Agent":"Mozilla/5.0"]) }
                }
            }
            return ResolvedMedia(url:address,headers:["User-Agent":"Mozilla/5.0"],useVLC:URL(string:address)?.pathExtension=="flv")
        }
        if Self.provider(source)=="children" {
            let data=try await fetch(episode.url),doc=try SwiftSoup.parse(String(decoding:data,as:UTF8.self),episode.url)
            let raw=try doc.select("#videoWrap").attr("video-src")
            guard CatalogParser.validHTTP(raw) else { throw TVError.message("儿童播放页未返回视频地址") }
            return ResolvedMedia(url:raw,headers:["User-Agent":Self.mobileUA,"Referer":episode.url])
        }
        throw HTMLPlaybackRequired(page:episode.url,headers:["User-Agent":Self.mobileUA],preferVLC:true)
    }
}

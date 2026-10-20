import Foundation
import SwiftSoup

/// 按当前 Android YGP / FirstAid / Dm84 插件的选择器读取页面。
public struct WebsiteClient: Sendable {
    public static let plugins = ["csp_YGPGuard", "csp_FirstAidGuard", "csp_Dm84Guard"]
    public var transport: any HTTPTransport
    public init(transport:any HTTPTransport = NetworkTransport()) { self.transport=transport }
    private func base(_ source:MediaSource) throws -> URL {
        let address:String
        switch source.address {
        case "csp_YGPGuard": address="https://www.6huo.com/"
        case "csp_FirstAidGuard": address="https://m.youlai.cn/"
        case "csp_Dm84Guard": address="http://dmbus.cc/"
        default: throw TVError.message("没有对应的网页插件")
        }
        return URL(string:address)!
    }
    private func get(_ url:URL, query:[String:String]=[:]) async throws -> (Data,URL) {
        var parts=URLComponents(url:url,resolvingAgainstBaseURL:true)!
        if !query.isEmpty { parts.queryItems=(parts.queryItems ?? [])+query.sorted { $0.key < $1.key }.map { URLQueryItem(name:$0.key,value:$0.value) } }
        guard var target=parts.url else { throw TVError.message("页面地址无效") }
        for _ in 0..<5 {
            var req=URLRequest(url:target); req.setValue("Mozilla/5.0",forHTTPHeaderField:"User-Agent")
            let reply=try await transport.send(req)
            if [301,302,303,307,308].contains(reply.status),let location=reply.headers.first(where: { $0.key.lowercased() == "location" })?.value,let next=URL(string:location,relativeTo:target)?.absoluteURL,CatalogParser.validHTTP(next.absoluteString) { target=next; continue }
            guard (200..<300).contains(reply.status) else { throw DAVFailure.status(reply.status) }
            return (reply.body,target)
        }
        throw TVError.message("站点重定向次数过多")
    }
    private func page(_ url:URL,query:[String:String]=[:]) async throws -> Document {
        let (data,url)=try await get(url,query:query)
        guard let html=String(data:data,encoding:.utf8) else { throw TVError.message("页面不是UTF-8文本") }
        return try SwiftSoup.parse(html,url.absoluteString)
    }
    public func categories(_ source:MediaSource) async throws -> [(id:String,name:String)] {
        switch source.address {
        case "csp_FirstAidGuard":return ["急救技能","家庭生活","急危重症","常见损伤","动物致伤","海洋急救","中毒急救","意外事故"].enumerated().map { ("jijiu|\($0.offset)",$0.element) }
        case "csp_YGPGuard": return [("movlist/","新片预告")]
        default:
            let doc=try await page(base(source))
            return try doc.select("ul.nav_row > li > a").array().compactMap { a in
                let href=try a.attr("href"), name=try a.text()
                guard href.contains("show-"),let id=href.components(separatedBy:"show-").last?.components(separatedBy:".").first else { return nil }
                return (id,name)
            }
        }
    }
    public func browse(_ source:MediaSource,keyword:String="",page number:Int=1,category:String="") async throws -> [MediaItem] {
        let origin=try base(source), doc:Document
        switch source.address {
        case "csp_FirstAidGuard":
            if keyword.isEmpty {
                guard number == 1 else { return [] }
                doc=try await page(origin.appendingPathComponent("jijiu"))
                let i=Int(category.components(separatedBy:"|").last ?? "0") ?? 0
                let groups=try doc.select(".jj-title-li").array(), images=try doc.select(".block100").array()
                guard groups.indices.contains(i) else { throw TVError.message("急救站点未返回对应分类") }
                let picture=try images.indices.contains(i) ? images[i].absUrl("src") : ""
                return try groups[i].select(".list-br3 a").array().compactMap { a in
                    let id=try a.absUrl("href"), name=try a.text()
                    return id.isEmpty ? nil:MediaItem(id:id,name:name,picture:picture)
                }
            }
            guard number == 1 else { return [] }
            doc=try await page(origin.appendingPathComponent("cse/search"),query:["q":keyword])
            return try doc.select(".search-video-li.list-br2").array().compactMap { node in
                let id=try node.select("a").first()?.absUrl("href") ?? ""
                return id.isEmpty ? nil:MediaItem(id:id,name:try node.select("h5.line-clamp1").text(),picture:try node.select("dt.logo-bg img").first()?.absUrl("src") ?? "")
            }
        case "csp_YGPGuard":
            if !keyword.isEmpty { guard number == 1 else { return [] };doc=try await page(origin,query:["keyword":keyword,"view":"search"]) }
            else if category.isEmpty && number == 1 { doc=try await page(origin) }
            else { doc=try await page(origin.appendingPathComponent("movlist/____\(max(1,number))")) }
            let selector = keyword.isEmpty ? "div.movlist > ul li > a" : "h1.tabs-title + div.movlist > ul li > a"
            return try doc.select(selector).array().compactMap { a in
                let id=try a.attr("href"), title=try a.select("span").first()?.attr("title") ?? ""
                guard !id.isEmpty,!title.isEmpty else { return nil }
                return MediaItem(id:id,name:title,picture:try a.select("img").first()?.absUrl("src") ?? "",remarks:try a.select("span").last()?.text() ?? "")
            }
        default:
            if !keyword.isEmpty { doc=try await page(origin.appendingPathComponent("s----------.html"),query:["wd":keyword]) }
            else if category.isEmpty && number == 1 { doc=try await page(origin) }
            else { doc=try await page(origin.appendingPathComponent("show-\(category.isEmpty ? "1":category)--time----\(max(1,number)).html")) }
            return try doc.select("div.item").array().compactMap { node in
                guard let a=try node.select("a.title").first() else { return nil }
                let id=try a.attr("href").components(separatedBy:"/").last ?? "",raw=try node.select("a.cover").attr("data-bg")
                return id.isEmpty ? nil:MediaItem(id:id,name:try a.text(),picture:URL(string:raw,relativeTo:origin)?.absoluteString ?? "",remarks:try node.select("span.desc").text())
            }
        }
    }
    public func detail(_ source:MediaSource,id:String) async throws -> MediaDetail {
        let origin=try base(source)
        let detailID=source.address == "csp_Dm84Guard" && !id.contains("/") ? "v/"+id:id
        guard let url=URL(string:detailID,relativeTo:origin)?.absoluteURL,url.host == origin.host else { throw TVError.message("影片标识不属于当前站点") }
        let doc=try await page(url)
        let name:String,picture:String,synopsis:String,episodes:[Episode]
        switch source.address {
        case "csp_FirstAidGuard":
            name=try doc.select(".video-title.h1-title").text(); picture=try doc.select(".video-cover.list-flex-in img").first()?.absUrl("src") ?? ""
            synopsis=try doc.select(".img-text-con").text()
            let media=try doc.select("#video source").first()?.absUrl("src") ?? ""
            episodes=CatalogParser.validHTTP(media) ? [Episode(name:name,url:media,line:"Qile")]:[]
        case "csp_YGPGuard":
            name=try doc.select("h1.movie-name").text();picture=try doc.select("div.movie-title-mpic > a > img").first()?.absUrl("src") ?? "";synopsis=try doc.select("div.movie-title-detail p").text()
            episodes=try doc.select("div#tabwrapper-all a.tlist-btn").array().compactMap { a in
                let href=try a.attr("href")
                return href.isEmpty ? nil:Episode(name:try a.text(),url:href,line:"预告")
            }
        default:
            name=try doc.select("h1.v_title").text();picture=try doc.select("meta[property=og:image]").attr("content");synopsis=try doc.select("meta[property=og:description]").attr("content")
            let names=try doc.select("ul.tab_control > li").array()
            var all:[Episode]=[]
            for (i,list) in try doc.select("ul.play_list").array().enumerated() {
                let line=try names.indices.contains(i) ? names[i].text():"线路 \(i+1)"
                all += try list.select("a").array().compactMap { a in
                    let href=try a.attr("href");return href.isEmpty ? nil:Episode(name:try a.text(),url:href,line:line)
                }
            }
            episodes=all
        }
        guard !name.isEmpty else { throw TVError.message("站点页面缺少影片详情，可能需要验证或页面已变更") }
        return MediaDetail(item:MediaItem(id:id,name:name,picture:picture),episodes:episodes,synopsis:synopsis)
    }
    public func resolve(_ source:MediaSource,episode:Episode) async throws -> ResolvedMedia {
        if source.address == "csp_FirstAidGuard" { return ResolvedMedia(url:episode.url) }
        if source.address == "csp_YGPGuard" {
            let parts=URL(string:episode.url)?.pathComponents.filter { $0 != "/" } ?? []
            guard parts.count >= 2 else { throw TVError.message("预告播放标识无效") }
            let (data,_)=try await get(base(source),query:["view":"api","mode":"download-data","ttid":parts[1],"rand":String(Double.random(in:0..<1))])
            let url=try JSON.parse(data).array.first?["movurl"].string ?? ""
            guard CatalogParser.validHTTP(url) else { throw TVError.message("预告接口未返回视频地址") }
            return ResolvedMedia(url:url)
        }
        guard let url=URL(string:episode.url,relativeTo:try base(source))?.absoluteURL else { throw TVError.message("播放页地址无效") }
        let doc=try await page(url)
        let iframe=try doc.select("iframe").first()?.absUrl("src") ?? ""
        if CatalogParser.validHTTP(iframe),URL(string:iframe)?.pathExtension == "m3u8" { return ResolvedMedia(url:iframe,headers:["Referer":try base(source).absoluteString]) }
        // 现行巴士播放器把签名参数放在 hhplayer 内嵌页，外层只保留 iframe。
        let playbackDoc:Document
        if let player=URL(string:iframe),player.scheme == "https",player.host?.lowercased() == "hhjx.hhplayer.com" {
            playbackDoc=try await page(player)
        } else { playbackDoc=doc }
        for script in try playbackDoc.select("script").array() {
            let raw=try script.html().trimmingCharacters(in:.whitespacesAndNewlines)
            guard raw.hasPrefix("window.__HHJX_BOOTSTRAP__") || raw.hasPrefix("var player_"),let first=raw.firstIndex(of:"{"),let last=raw.lastIndex(of:"}") else { continue }
            let payload=try JSON.parse(Data(raw[first...last].utf8))
            var request=URLRequest(url:URL(string:"https://hhjx.hhplayer.com/api/parse")!)
            request.httpMethod="POST";request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.setValue("https://hhjx.hhplayer.com",forHTTPHeaderField:"Referer")
            request.httpBody=JSON.object(["url":payload["url"],"t":payload["t"],"key":payload["key"],"client_fallback":.bool(false)]).data
            let reply=try await transport.send(request)
            guard reply.status == 200 else { throw DAVFailure.status(reply.status) }
            let media=try JSON.parse(reply.body)["url"].string
            guard CatalogParser.validHTTP(media) else { throw TVError.message("巴士解析接口未返回视频地址") }
            return ResolvedMedia(url:media,headers:["Referer":try base(source).absoluteString])
        }
        throw TVError.message("巴士播放页需要尚未支持的网页解析")
    }
}

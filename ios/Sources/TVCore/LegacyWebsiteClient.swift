import Foundation
import SwiftSoup

public struct HTMLPlaybackRequired: Error, Sendable {
    public let page: String
    public let headers: [String:String]
    public let preferVLC:Bool
    public init(page:String,headers:[String:String]=[:],preferVLC:Bool=false) { self.page=page;self.headers=headers;self.preferVLC=preferVLC }
}

/// 以当前 Android 业务插件的选择器为准；JS 播放页交给 iPhone 的 WebKit 解析。
public struct LegacyWebsiteClient:Sendable {
    public static let plugins=["csp_AueteGuard","csp_NewCzGuard","csp_BttwooGuard","csp_LibvioGuard","csp_NmyswvGuard","csp_YCyzGuard"]
    public var transport:any HTTPTransport
    public init(transport:any HTTPTransport=NetworkTransport()) { self.transport=transport }
    public func base(_ source:MediaSource) throws -> URL {
        let defaults=["csp_AueteGuard":"https://auete.cc/","csp_NewCzGuard":"https://www.4kcz.com/","csp_BttwooGuard":"https://www.bttwo.life/","csp_LibvioGuard":"https://www.libvio.io/","csp_NmyswvGuard":"https://vip.wwgz.cn/","csp_YCyzGuard":"https://v.xl01.eu.cc/"]
        let ext=source.ext.object.isEmpty ? ((try? App99Crypto.configuration(source.ext)) ?? .null):source.ext
        let override=ext["siteUrl"].string
        guard let text=override.isEmpty ? defaults[source.address]:override,CatalogParser.validHTTP(text),let url=URL(string:text) else { throw TVError.message("网页站点配置无效") };return url
    }
    public func fetch(_ url:URL,query:[String:String]=[:]) async throws -> (Data,URL) {
        guard CatalogParser.validHTTP(url.absoluteString),var parts=URLComponents(url:url,resolvingAgainstBaseURL:true) else { throw TVError.message("网页地址无效") }
        if !query.isEmpty { let names=Set(query.keys);parts.queryItems=(parts.queryItems ?? []).filter { !names.contains($0.name) }+query.sorted { $0.key<$1.key }.map { URLQueryItem(name:$0.key,value:$0.value) } }
        guard var target=parts.url else { throw TVError.message("网页地址无效") }
        for _ in 0..<5 {
            var req=URLRequest(url:target);req.allHTTPHeaderFields=["User-Agent":SeedhubClient.userAgent,"Referer":target.deletingLastPathComponent().absoluteString]
            if let cookie=await MusicVerificationSession.shared.header(for:target) { req.setValue(cookie,forHTTPHeaderField:"Cookie") }
            let reply=try await transport.send(req)
            if [301,302,303,307,308].contains(reply.status),let location=reply.headers.first(where:{$0.key.lowercased()=="location"})?.value,let next=URL(string:location,relativeTo:target)?.absoluteURL,CatalogParser.validHTTP(next.absoluteString) { target=next;continue }
            if reply.status == 403 { throw TVError.message("此站点拒绝请求（HTTP403），可打开网站验证后重试") }
            guard (200..<300).contains(reply.status) else { throw DAVFailure.status(reply.status) }
            return (reply.body,target)
        }
        throw TVError.message("网页站点重定向次数过多")
    }
    private func page(_ url:URL,query:[String:String]=[:]) async throws -> Document {
        let (data,url)=try await fetch(url,query:query)
        guard let html=String(data:data,encoding:.utf8) else { throw TVError.message("站点页面编码不支持") }
        let doc=try SwiftSoup.parse(html,url.absoluteString)
        if try ["404","Just a moment...","Attention Required! | Cloudflare"].contains(doc.title()) { throw TVError.message("站点返回错误或访问验证页面") }
        return doc
    }
    private func id(_ href:String,source:MediaSource) -> String? {
        guard !href.isEmpty else { return nil }
        let path=URL(string:href)?.path ?? href
        switch source.address {
        case "csp_AueteGuard":return Self.match(path,#"/([\w]+/[\w]+/[\w]+)(?:/|$)"#)
        case "csp_LibvioGuard":return Self.match(path,#"/detail/([^/]+)\.html"#)
        default:return href
        }
    }
    private func detailURL(_ source:MediaSource,id:String) throws -> URL {
        let base=try base(source),path:String
        if source.address=="csp_AueteGuard" { path=id.trimmingCharacters(in:CharacterSet(charactersIn:"/"))+"/" }
        else if source.address=="csp_LibvioGuard" && !id.contains("/") { path="detail/"+id+".html" }
        else { path=id }
        guard let url=URL(string:path,relativeTo:base)?.absoluteURL,url.host==base.host else { throw TVError.message("影片标识不属于当前站点") };return url
    }
    public func categories(_ source:MediaSource) async throws -> [(id:String,name:String)] {
        let doc=try await page(base(source))
        let selector:String
        switch source.address {
        case "csp_AueteGuard":selector="ul.navbar-nav li a"
        case "csp_NewCzGuard":selector="li.menu-item a"
        case "csp_LibvioGuard":selector="ul.stui-header__menu li a"
        default:selector="nav a"
        }
        var seen=Set<String>()
        return try doc.select(selector).array().compactMap { a in
            let name=try a.text(),href=try a.attr("href")
            guard ["电影","电视剧","动漫","综艺","纪录片","美剧","韩剧","日剧"].contains(name),!href.isEmpty,seen.insert(href).inserted else { return nil }
            return (href,name)
        }
    }
    public func browse(_ source:MediaSource,keyword:String="",page number:Int=1,category:String="") async throws -> [MediaItem] {
        let origin=try base(source),doc:Document
        if !keyword.isEmpty {
            if source.address=="csp_LibvioGuard" {
                guard number==1 else { return [] }
                let (data,_)=try await fetch(origin.appendingPathComponent("index.php/ajax/suggest"),query:["mid":"1","wd":keyword,"limit":"10"])
                let root=try JSON.parse(data)
                guard case .array=root["list"] else { throw TVError.message("立播搜索没有返回列表") }
                return root["list"].array.map { MediaItem(id:$0["id"].string.isEmpty ? String($0["id"].int):$0["id"].string,name:$0["name"].string,picture:$0["pic"].string) }
            }
            let path:String,params:[String:String]
            switch source.address {
            case "csp_AueteGuard":path="auete4so.php";params=["searchword":keyword,"page":String(number)]
            case "csp_NewCzGuard":path="nimasile";params=["q":keyword,"page":String(number)]
            case "csp_BttwooGuard":path="search";params=["q":keyword,"page":String(number)]
            case "csp_NmyswvGuard":path="index.php";params=["m":"vod-search","wd":keyword]
            case "csp_YCyzGuard":path="search.php";params=["searchword":keyword]
            default:throw TVError.message("此站点尚未接入搜索")
            }
            doc=try await page(origin.appendingPathComponent(path),query:params)
        } else if !category.isEmpty {
            guard let url=URL(string:category,relativeTo:origin)?.absoluteURL,url.host==origin.host else { throw TVError.message("分类地址不属于当前站点") }
            doc=try await page(url,query:number>1 ? ["page":String(number)]:[:])
        } else {
            guard number==1 else { return [] };doc=try await page(origin)
        }
        let result=try items(doc,source:source)
        if result.isEmpty && keyword.isEmpty && category.isEmpty { throw TVError.message("站点首页未找到影片卡片，页面可能已变更或需要验证") }
        return result
    }
    public func items(_ doc:Document,source:MediaSource) throws -> [MediaItem] {
        let selector:String,titleSelector:String,imageSelector:String,remarksSelector:String
        switch source.address {
        case "csp_AueteGuard":selector="ul.threadlist li";titleSelector="h2 a";imageSelector="a.pic img";remarksSelector="span.hdtag"
        case "csp_NewCzGuard":selector="div.mi_ne_kd > ul > li";titleSelector="h3 a";imageSelector="img";remarksSelector="div.hdinfo > span"
        case "csp_LibvioGuard":selector="div.stui-vodlist__box";titleSelector="a";imageSelector="a";remarksSelector=".pic-text"
        case "csp_BttwooGuard":selector="div[data-vod-id], div.group.relative";titleSelector="a[href*=play]";imageSelector="img";remarksSelector="span"
        case "csp_NmyswvGuard":selector="ul.resize_list > li, ul#data_list > li";titleSelector="a";imageSelector="img";remarksSelector=".vod_remarks"
        default:selector="div.movie-card";titleSelector="a[href*=htm]";imageSelector="img";remarksSelector=".card-meta"
        }
        var seen=Set<String>(),result:[MediaItem]=[]
        for node in try doc.select(selector).array() {
            guard let a=try node.select(titleSelector).first(),let id=id(try a.attr("href"),source:source),seen.insert(id).inserted else { continue }
            let title=try a.attr("title"),image=try node.select(imageSelector).first()
            let text=try source.address=="csp_BttwooGuard" ? node.select("h3, h2").text():a.text()
            let alt=try image?.attr("alt") ?? ""
            let name=title.isEmpty ? (text.isEmpty ? alt:text):title
            guard !name.isEmpty else { continue }
            var picture=""
            for key in ["data-original","data-src","data-bg","src"] {
                if let image { let value=try image.absUrl(key);if !value.isEmpty { picture=value;break } }
            }
            result.append(MediaItem(id:id,name:name,picture:picture,remarks:try node.select(remarksSelector).text()))
        }
        let challenge = try !doc.select("script[src*='challenge'], #challenge-running").isEmpty
        let validation = try !doc.select("input[name=validate]").isEmpty
        if result.isEmpty && (challenge || validation) { throw TVError.message("站点页面需要访问验证") }
        return result
    }
    public func detail(_ source:MediaSource,id:String,quarkCookie:String?=nil,ucCookie:String?=nil) async throws -> MediaDetail {
        let doc=try await page(detailURL(source,id:id)),title:String,picture:String,synopsis:String
        let groups:[Element],lineNames:[Element]
        switch source.address {
        case "csp_AueteGuard":title=try doc.select("h1.detail-title").text().replacingOccurrences(of:"《",with:"").replacingOccurrences(of:"》",with:"");picture=try doc.select("div.detail-poster img").first()?.absUrl("src") ?? "";synopsis=try doc.select(".detail-des").text();groups=try doc.select("div.play-card#player_list").array();lineNames=[]
        case "csp_NewCzGuard":title=try doc.select("div.moviedteail_tt > h1").text();picture=try doc.select("div.dyimg > img").first()?.absUrl("src") ?? "";synopsis=try doc.select("div.yp_context").text();groups=try doc.select("div.paly_list_btn").array();lineNames=[]
        case "csp_LibvioGuard":title=try doc.select(".stui-content__detail .title, h1").first()?.text() ?? "";picture=try doc.select(".stui-content__thumb img").first()?.absUrl("data-original") ?? "";synopsis=try doc.select(".detail-content").text();groups=try doc.select(".stui-content__playlist").array();lineNames=try doc.select(".stui-pannel__head .title").array()
        case "csp_BttwooGuard":title=try doc.select("h1").text();picture=try doc.select("meta[property=og:image]").attr("content");synopsis=try doc.select("p.text-xs.text-text-secondary").text();groups=try doc.select("div[style]:has(a[href*=play])").array();lineNames=[]
        case "csp_NmyswvGuard":title=try doc.select("h1.title > a").text();picture=try doc.select(".globalPicList img").first()?.absUrl("src") ?? "";synopsis=try doc.select(".detail").text();groups=try doc.select("div.numList").array();lineNames=try doc.select("div.id").array()
        default:title=try doc.select("h1").text();picture=try doc.select("meta[property=og:image]").attr("content");synopsis=try doc.select("div.desc").text();groups=try doc.select("div.play-list").array();lineNames=[]
        }
        guard !title.isEmpty else { throw TVError.message("站点未返回有效影片详情") }
        var episodes:[Episode]=[],seen=Set<String>()
        for (index,group) in groups.enumerated() {
            let label=try source.address=="csp_AueteGuard" ? group.select("div.card-header span b").text():lineNames.indices.contains(index) ? lineNames[index].text():"线路 \(index+1)"
            for a in try group.select("a[href]").array() {
                let href=try a.attr("href"),name=try a.text()
                guard !href.isEmpty,!name.isEmpty,seen.insert(label+"\u{0}"+href).inserted else { continue }
                episodes.append(Episode(name:name,url:href,line:label))
            }
        }
        if source.address == "csp_LibvioGuard",episodes.isEmpty {
            var shares=Set<String>(),lastFailure:Error?
            for link in try doc.select("a.netdisk-item[href]").array() {
                let href=try link.attr("href")
                guard let url=URL(string:href),url.scheme == "https",["pan.quark.cn","drive.uc.cn"].contains(url.host ?? ""),shares.insert(href).inserted else { continue }
                do {
                    let detail=try await CloudSearchClient(transport:transport).detail(id:href,cookie:quarkCookie,ucCookie:ucCookie)
                    let index=shares.count
                    episodes += detail.episodes.map{Episode(name:$0.name,url:$0.url,line:$0.line.replacingOccurrences(of:"1",with:String(index)))}
                } catch is CancellationError { throw CancellationError() }
                  catch { lastFailure=error }
            }
            if episodes.isEmpty,let lastFailure { throw lastFailure }
        }
        return MediaDetail(item:MediaItem(id:id,name:title,picture:picture),episodes:episodes,synopsis:synopsis)
    }
    public func resolve(_ source:MediaSource,episode:Episode) async throws -> ResolvedMedia {
        let origin=try base(source)
        guard let url=URL(string:episode.url,relativeTo:origin)?.absoluteURL,CatalogParser.validHTTP(url.absoluteString) else { throw TVError.message("选集地址无效") }
        let headers=["Referer":url.absoluteString,"User-Agent":SeedhubClient.userAgent]
        if ["m3u8","mp4","mkv","mp3","m4a"].contains(url.pathExtension.lowercased()) { return ResolvedMedia(url:url.absoluteString,headers:headers) }
        let (data,target)=try await fetch(url)
        guard let html=String(data:data,encoding:.utf8) else { throw TVError.message("播放页面编码不支持") }
        if let media=Self.media(in:html,base:target) { return ResolvedMedia(url:media,headers:headers) }
        throw HTMLPlaybackRequired(page:target.absoluteString,headers:headers,preferVLC:source.address=="csp_NewCzGuard")
    }
    public static func media(in html:String,base:URL) -> String? {
        if let doc=try? SwiftSoup.parse(html,base.absoluteString),let node=try? doc.select("video[src], video source[src], audio[src]").first(),let media=try? node.absUrl("src"),CatalogParser.validHTTP(media) { return media }
        for marker in ["var player_","window.player_"] {
            guard let range=html.range(of:marker),let first=html[range.upperBound...].firstIndex(of:"{") else { continue }
            var quoted=false,escape=false,depth=0
            for i in html[first...].indices {
                let c=html[i]
                if quoted { if escape { escape=false } else if c=="\\" { escape=true } else if c=="\"" { quoted=false };continue }
                if c=="\"" { quoted=true };if c=="{" { depth+=1 };if c=="}" { depth-=1 }
                if depth==0 {
                    if let root=try? JSON.parse(Data(html[first...i].utf8)) {
                        var raw=root["url"].string
                        if root["encrypt"].int==2,let bytes=Data(base64Encoded:raw),let text=String(data:bytes,encoding:.utf8) { raw=text }
                        raw=raw.removingPercentEncoding ?? raw
                        if let url=URL(string:raw,relativeTo:base)?.absoluteURL,CatalogParser.validHTTP(url.absoluteString),["m3u8","mp4","mp3","mkv","flv"].contains(url.pathExtension.lowercased()) { return url.absoluteString }
                    };break
                }
            }
        }
        return nil
    }
    static func match(_ text:String,_ pattern:String) -> String? {
        guard let regex=try? NSRegularExpression(pattern:pattern),let m=regex.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)),let r=Range(m.range(at:1),in:text) else { return nil };return String(text[r])
    }
}

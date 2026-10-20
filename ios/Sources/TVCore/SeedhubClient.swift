import Foundation
import SwiftSoup

/// 聚剧目录与分享页；网盘 Cookie 不发送到目录站点。
public struct SeedhubClient:Sendable {
    public static let categories=[(id:"1",name:"电影"),(id:"3",name:"剧集"),(id:"2",name:"动漫")]
    public static let userAgent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36 Edg/148.0.0.0"
    public var transport:any HTTPTransport
    public init(transport:any HTTPTransport=NetworkTransport()) { self.transport=transport }
    private func base(_ source:MediaSource)->URL {
        let raw=source.ext.string
        if CatalogParser.validHTTP(raw),let url=URL(string:raw) { return url }
        return URL(string:"https://seedhub.pro/")!
    }
    private func fetch(_ url:URL) async throws -> Document {
        var target=url
        for _ in 0..<5 {
            var req=URLRequest(url:target);req.allHTTPHeaderFields=["User-Agent":Self.userAgent,"Referer":target.deletingLastPathComponent().absoluteString]
            let reply=try await transport.send(req)
            if [301,302,303,307,308].contains(reply.status),let location=reply.headers.first(where:{$0.key.lowercased()=="location"})?.value,let next=URL(string:location,relativeTo:target)?.absoluteURL,CatalogParser.validHTTP(next.absoluteString) { target=next;continue }
            guard reply.status==200 else { throw DAVFailure.status(reply.status) }
            let doc=try SwiftSoup.parse(String(decoding:reply.body,as:UTF8.self),target.absoluteString)
            if try !doc.select("#challenge-running,input[name=validate]").isEmpty { throw TVError.message("聚剧页面需要访问验证") };return doc
        }
        throw TVError.message("聚剧跳转次数过多")
    }
    public func browse(_ source:MediaSource,keyword:String="",page:Int=1,category:String="") async throws -> [MediaItem] {
        let root=base(source),url:URL
        if !keyword.isEmpty { url=root.appendingPathComponent("s/"+keyword+"/") }
        else if !category.isEmpty { var parts=URLComponents(url:root.appendingPathComponent("categories/"+category+"/movies/"),resolvingAgainstBaseURL:true)!;parts.queryItems=[URLQueryItem(name:"page",value:String(page))];url=parts.url! }
        else { guard page==1 else { return [] };url=root }
        let doc=try await fetch(url)
        let cards=try doc.select("div.cover-container div.cover").array().compactMap { row -> MediaItem? in
            guard let link=try row.select("a[title]").first() else { return nil }
            let name=try link.attr("title"),href=try link.attr("href")
            guard !href.isEmpty,!name.isEmpty else { return nil }
            let picture=try row.select("a img").first()?.absUrl("src") ?? ""
            return MediaItem(id:href+"@folder",name:name,picture:picture,remarks:try row.select("ul li").text())
        }
        if cards.isEmpty { throw TVError.message("聚剧页面未返回影片目录，可能接口或页面已变化") };return cards
    }
    static func sharePageLink(href:String,dataLink:String) -> String {
        if href.contains("link_start") || href.contains("pan_id") { return href }
        return CatalogParser.validHTTP(dataLink) ? dataLink:href
    }
    public func detail(_ source:MediaSource,id:String,cookie:String?,ucCookie:String? = nil) async throws -> MediaDetail {
        let root=base(source)
        let raw=id.hasSuffix("@folder") ? String(id.dropLast(7)):id
        guard let target=URL(string:raw,relativeTo:root)?.absoluteURL,target.host==root.host else { throw TVError.message("聚剧目录标识无效") }
        let doc=try await fetch(target),title=try doc.select("h1").text()
        if !target.path.contains("link_start") {
            var seen=Set<String>(),choices:[MediaItem]=[]
            for link in try doc.select("ul.pan-links a[data-link]").array() {
                guard ["pan.quark.cn","drive.uc.cn"].contains(try link.attr("data-link")) else { continue }
                let path=Self.sharePageLink(href:try link.attr("href"),dataLink:try link.attr("data-link"))
                guard path.contains("link_start"),let url=URL(string:path,relativeTo:root)?.absoluteURL,url.host == target.host,seen.insert(url.absoluteString).inserted else { continue }
                let name=try link.text()
                choices.append(MediaItem(id:url.absoluteString,name:name.isEmpty ? "夸克资源 \(choices.count+1)":name,remarks:"夸克网盘"))
            }
            if choices.count>8 { return MediaDetail(item:MediaItem(id:id,name:title),episodes:[],synopsis:try doc.select("div.content p").text(),resources:choices) }
        }
        var pending=[doc],seen=Set<String>(),shares:[String]=[]
        for level in 0..<3 {
            var next:[Document]=[]
            for page in pending {
                let html=try page.html().replacingOccurrences(of:"\\/",with:"/")
                let regex=try NSRegularExpression(pattern:#"https://(?:pan\.quark\.cn|drive\.uc\.cn)/s/[A-Za-z0-9]+(?:\?[^\s"'<>]+)?"#)
                for match in regex.matches(in:html,range:NSRange(html.startIndex...,in:html)) { if let range=Range(match.range,in:html) { let value=String(html[range]).replacingOccurrences(of:"&amp;",with:"&");if seen.insert(value).inserted { shares.append(value) } } }
                for element in try page.select("ul.pan-links a[data-link],a[href*=link_start],a[href*=pan_id]").array() {
                    let provider=try element.attr("data-link")
                    if provider.contains("."),!CatalogParser.validHTTP(provider),!["pan.quark.cn","drive.uc.cn"].contains(provider) { continue }
                    let link=Self.sharePageLink(href:try element.attr("href"),dataLink:provider)
                    guard level<2,(link.contains("link_start") || link.contains("pan_id")),let url=URL(string:link,relativeTo:root)?.absoluteURL,url.host==target.host,seen.insert(url.absoluteString).inserted else { continue }
                    guard seen.count<60 else { throw TVError.message("聚剧分享条目过多，请选择具体资源") }
                    do { next.append(try await fetch(url)) } catch is CancellationError { throw CancellationError() } catch { continue }
                }
                let encoded=try NSRegularExpression(pattern:#"const data\s*=\s*"([A-Za-z0-9+/=]+)""#)
                for match in encoded.matches(in:html,range:NSRange(html.startIndex...,in:html)) {
                    if let range=Range(match.range(at:1),in:html),let bytes=Data(base64Encoded:String(html[range])),let value=String(data:bytes,encoding:.utf8),["pan.quark.cn","drive.uc.cn"].contains(URL(string:value)?.host ?? ""),seen.insert(value).inserted { shares.append(value) }
                }
            }
            if !shares.isEmpty { break };pending=next;if pending.isEmpty { break }
        }
        guard !shares.isEmpty else { throw TVError.message("聚剧详情未找到可播放的夸克分享；其他网盘仍待移植") }
        var episodes:[Episode]=[],lastFailure:Error?
        for (index,share) in shares.enumerated() {
            do {
                let detail=try await CloudSearchClient(transport:transport).detail(id:share,cookie:cookie,ucCookie:ucCookie)
                episodes += detail.episodes.map{Episode(name:$0.name,url:$0.url,line:$0.line.replacingOccurrences(of:"1",with:String(index+1)))}
            } catch is CancellationError { throw CancellationError() }
              catch { lastFailure=error }
        }
        if episodes.isEmpty { throw lastFailure ?? TVError.message("聚剧分享均未返回可播放选集") }
        return MediaDetail(item:MediaItem(id:id,name:title.isEmpty ? "聚剧资源":title),episodes:episodes,synopsis:try doc.select("div.content p").text())
    }
}

import Foundation
import SwiftSoup

/// 易听网页目录与分钟签名音频接口，不依赖 Android 二维码输入代理。
public struct MusicClient: Sendable {
    public var transport:any HTTPTransport
    public init(transport:any HTTPTransport = NetworkTransport()) { self.transport = transport }
    public static func verificationURL(_ source:MediaSource) -> URL {
        URL(string:CatalogParser.validHTTP(source.ext.string) ? source.ext.string : "https://www.4c44.com/")!
    }
    private func base(_ source:MediaSource) -> URL { Self.verificationURL(source) }
    private func page(_ source:MediaSource,path:String) async throws -> Document {
        let root = base(source)
        guard let url = path.isEmpty ? root : URL(string:path,relativeTo:root)?.absoluteURL,url.host == root.host else { throw TVError.message("易听目录地址无效") }
        var finalURL = url
        var bytes:Data?
        for _ in 0..<5 {
            var request = URLRequest(url:finalURL)
            request.allHTTPHeaderFields = ["User-Agent":SeedhubClient.userAgent,"Referer":root.absoluteString]
            if let cookie = await MusicVerificationSession.shared.header(for:finalURL) { request.setValue(cookie,forHTTPHeaderField:"Cookie") }
            let reply = try await transport.send(request)
            if [301,302,303,307,308].contains(reply.status),let location = reply.headers.first(where:{$0.key.lowercased() == "location"})?.value,let next = URL(string:location,relativeTo:finalURL)?.absoluteURL,next.host == root.host,CatalogParser.validHTTP(next.absoluteString),!(finalURL.scheme == "https" && next.scheme == "http") {
                finalURL = next;continue
            }
            guard reply.status == 200 else { throw DAVFailure.status(reply.status) }
            bytes = reply.body;break
        }
        guard let bytes else { throw TVError.message("易听站点跳转次数过多") }
        let doc = try SwiftSoup.parse(String(decoding:bytes,as:UTF8.self),finalURL.absoluteString)
        let title = try doc.title()
        let challenged = try !doc.select("input[name=validate],#challenge-running").isEmpty
        if title.contains("验证") || title.contains("Just a moment") || challenged { throw TVError.message("易听站点需要人机验证，当前无法读取目录") }
        return doc
    }
    public func categories(_ source:MediaSource) async throws -> [(id:String,name:String)] {
        let doc = try await page(source,path:"")
        return try doc.select("div.pull-right > div > ul > li > a").array().dropFirst().compactMap { link in
            let href = try link.attr("href"),title = try link.attr("title")
            guard !href.isEmpty,!title.isEmpty else { return nil }
            return (href.replacingOccurrences(of:".html",with:""),title)
        }
    }
    public func browse(_ source:MediaSource,keyword:String="",page:Int=1,category:String="") async throws -> [MediaItem] {
        let path:String
        if !keyword.isEmpty { guard page == 1 else { return [] };path = "/so/" + (keyword.addingPercentEncoding(withAllowedCharacters:.urlPathAllowed) ?? "") + ".html" }
        else if !category.isEmpty { path = category + "/\(page).html" }
        else { guard page == 1 else { return [] };path = "" }
        let doc = try await self.page(source,path:path)
        var seen = Set<String>()
        let cards = try doc.select("div.lksinger_list > ul > li,div.singer_list > ul > li,div.video_list > ul > li,.ilingku_fl > li").array().compactMap { row -> MediaItem? in
            guard let link = try row.select(".name a").first() ?? row.select("a").first() else { return nil }
            let href = try link.attr("href"), name = try link.text()
            guard !href.isEmpty,!name.isEmpty,seen.insert(href).inserted else { return nil }
            let image = try row.select("img").first()
            let lazy = try image?.absUrl("data-src") ?? ""
            let picture = try lazy.isEmpty ? image?.absUrl("src") ?? "" : lazy
            return MediaItem(id:href,name:name,picture:picture)
        }
        // 搜索页直接返回歌曲列表；按 Android 的搜索入口打开选集详情。
        if cards.isEmpty && !keyword.isEmpty, try !doc.select(".play_list > ul > li .name a").isEmpty {
            return [MediaItem(id:path,name:keyword,picture:try doc.select("div.play_left img").first()?.absUrl("src") ?? "")]
        }
        if cards.isEmpty && keyword.isEmpty { throw TVError.message("易听页面未返回音乐目录，页面规则可能已变更") }
        return cards
    }
    public func detail(_ source:MediaSource,id:String) async throws -> MediaDetail {
        let doc = try await page(source,path:id)
        let name = try doc.select(".play_list h1").text().components(separatedBy:",").first ?? "音乐"
        let rows = try doc.select(".play_list > ul > li").array()
        var episodes:[Episode] = []
        for row in rows {
            for link in try row.select(".name a,.mv a,a.mv").array() {
                let href = try link.attr("href"), title = try link.text()
                guard !href.isEmpty else { continue }
                episodes.append(Episode(name:title.isEmpty ? "播放" : title,url:href,line:href.contains("mp4") ? "MV" : "音乐"))
            }
        }
        if episodes.isEmpty, id.hasSuffix(".html"), !id.contains("/so/"), try !doc.select("div.play_left").isEmpty { episodes = [Episode(name:name,url:id,line:"音乐")] }
        guard !episodes.isEmpty else { throw TVError.message("易听未返回歌曲或播放列表") }
        return MediaDetail(item:MediaItem(id:id,name:name,picture:try doc.select("div.play_left img").first()?.absUrl("src") ?? ""),episodes:episodes,synopsis:"")
    }
    static func minuteKey(at date:Date) -> String {
        let format = DateFormatter();format.locale = Locale(identifier:"en_US_POSIX");format.timeZone = TimeZone(secondsFromGMT:8*3600);format.dateFormat = "yyyyMMddHHmm"
        return format.string(from:date)+"4c44"
    }
    public func resolve(_ source:MediaSource,episode:Episode,at date:Date = Date()) async throws -> ResolvedMedia {
        let root = base(source)
        guard let url = URL(string:episode.url,relativeTo:root)?.absoluteURL,url.host == root.host else { throw TVError.message("易听播放条目标识无效") }
        var id = url.deletingPathExtension().lastPathComponent
        if episode.url.contains("radio") {
            let doc = try await page(source,path:episode.url), html = try doc.html()
            let pattern = try NSRegularExpression(pattern:"[\"']music[\"']\\s*,\\s*[\"']([^\"']+)[\"']")
            guard let match = pattern.firstMatch(in:html,range:NSRange(html.startIndex...,in:html)),let range = Range(match.range(at:1),in:html) else { throw TVError.message("易听电台未返回歌曲编号") };id = String(html[range])
        }
        guard !id.isEmpty else { throw TVError.message("易听歌曲编号无效") }
        let headers = ["User-Agent":SeedhubClient.userAgent,"Referer":url.absoluteString]
        if episode.url.contains("mp4") {
            var parts = URLComponents(url:root.appendingPathComponent("data/down.php"),resolvingAgainstBaseURL:false)!
            parts.queryItems = [URLQueryItem(name:"ac",value:"vplay"),URLQueryItem(name:"id",value:id),URLQueryItem(name:"q",value:"1080")]
            return ResolvedMedia(url:parts.url!.absoluteString,headers:headers)
        }
        var req = URLRequest(url:root.appendingPathComponent("js/play.php"));req.httpMethod = "POST"
        var body = URLComponents();body.queryItems = [URLQueryItem(name:"id",value:id),URLQueryItem(name:"type",value:"music"),URLQueryItem(name:"key",value:Self.minuteKey(at:date))]
        req.httpBody = Data((body.percentEncodedQuery?.replacingOccurrences(of:"+",with:"%2B") ?? "").utf8)
        req.allHTTPHeaderFields = headers.merging(["Content-Type":"application/x-www-form-urlencoded"]) { _,new in new }
        if let cookie = await MusicVerificationSession.shared.header(for:req.url!) { req.setValue(cookie,forHTTPHeaderField:"Cookie") }
        let reply = try await transport.send(req);guard reply.status == 200 else { throw DAVFailure.status(reply.status) }
        let result:JSON
        do { result = try JSON.parse(reply.body) } catch { throw TVError.message("易听播放接口未返回有效数据，可能需要人机验证") }
        let raw = result["url"].string,address = raw.hasPrefix("//") ? "http:"+raw : raw
        guard CatalogParser.validHTTP(address) else { throw TVError.message("易听未返回可播放音频") }
        return ResolvedMedia(url:address,headers:headers)
    }
}

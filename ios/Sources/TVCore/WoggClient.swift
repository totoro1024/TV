import Foundation
import SwiftSoup

/// WoGG 的 HTML 接口与分类路径来自现有 Android 插件；独立读取网页，不执行 JAR。
public actor WoggClient {
    public static let shared = WoggClient()
    public static let categories: [(id: String, name: String)] = [("", "推荐"), ("1", "电影"), ("2", "剧集"), ("44", "臻彩"), ("6", "短漫剧"), ("3", "动漫"), ("4", "综艺"), ("46", "纪录片"), ("5", "音乐")]
    private let transport: any HTTPTransport
    private var bases: [String: URL] = [:]
    public init(transport: any HTTPTransport = NetworkTransport()) { self.transport = transport }
    private static let mirrors = ["http://woggpan.888484.xyz/", "http://edgeong.wogg.333232.xyz/", "http://www.wogg.live/", "http://woggpan.333232.xyz/", "http://www.wogg.net/"]
    private let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/135.0.0.0 Safari/537.36"
    private func key(_ source: MediaSource) -> String { SyncDocument.identity(source.sourceID, source.id, source.ext.text) }
    private func fetch(_ url: URL) async throws -> (html: String, url: URL) {
        var next = url
        for _ in 0..<5 {
            try Task.checkCancellation()
            var request = URLRequest(url: next)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            // 公开网页无需登录；绝不发送 WebDAV 密码或夸克 Cookie。
            let reply = try await transport.send(request)
            if [301,302,303,307,308].contains(reply.status), let location = reply.headers.first(where: { $0.key.lowercased() == "location" })?.value,
               let destination = URL(string: location, relativeTo: next)?.absoluteURL, CatalogParser.validHTTP(destination.absoluteString) {
                next = destination; continue
            }
            guard reply.status == 200 else { throw TVError.message("玩偶站点返回 HTTP \(reply.status)") }
            guard let html = String(data: reply.body, encoding: .utf8), html.contains("module-") else { throw TVError.message("玩偶返回的页面格式不兼容或需要验证") }
            return (html, next)
        }
        throw TVError.message("玩偶站点重定向次数过多")
    }
    private func base(_ source: MediaSource) async throws -> URL {
        if let cached = bases[key(source)] { return cached }
        let ext = source.ext.string.isEmpty ? source.ext : ((try? JSON.parse(Data(source.ext.string.utf8))) ?? .null)
        let configured = ext["siteUrl"].string
        let candidates = configured.isEmpty ? Self.mirrors : [configured]
        for address in candidates where CatalogParser.validHTTP(address) {
            do {
                let response = try await fetch(URL(string: address)!)
                guard response.html.contains("玩偶") else { continue }
                let root = response.url.deletingLastPathComponentIfNeeded
                bases[key(source)] = root; return root
            } catch { if Task.isCancelled { throw CancellationError() } }
        }
        throw TVError.message("玩偶站点暂时无法访问，请检查网络后重试")
    }
    public func browse(_ source: MediaSource, keyword: String = "", category: String = "", page: Int = 1) async throws -> [MediaItem] {
        let base = try await base(source)
        let path: String
        if !keyword.isEmpty {
            path = "vodsearch/----------\(max(1,page))---.html"
        } else if !category.isEmpty {
            guard Self.categories.contains(where: { $0.id == category }) else { throw TVError.message("未知玩偶分类") }
            var parts = [String](repeating: "", count: 12); parts[0] = category; parts[8] = String(max(1,page))
            path = "vodshow/" + parts.joined(separator: "-") + ".html"
        } else if page > 1 {
            var parts = [String](repeating: "", count: 12); parts[8] = String(page)
            path = "vodshow/" + parts.joined(separator: "-") + ".html"
        } else { path = "" }
        let target = path.isEmpty ? base : base.appendingPathComponent(path)
        guard var url = URLComponents(url: target, resolvingAgainstBaseURL: true) else { throw TVError.message("玩偶页面地址无效") }
        if !keyword.isEmpty { url.queryItems = [URLQueryItem(name: "wd", value: keyword)] }
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let endpoint = url.url else { throw TVError.message("玩偶搜索地址无效") }
        let response = try await fetch(endpoint)
        return try Self.items(response.html, base: response.url, search: !keyword.isEmpty)
    }
    public static func items(_ html: String, base: URL, search: Bool = false) throws -> [MediaItem] {
        let document = try SwiftSoup.parse(html, base.absoluteString)
        let nodes = try document.select(search ? "div.module-search-item" : "div.module-item")
        var seen = Set<String>(), result: [MediaItem] = []
        for node in nodes.array() {
            guard let link = try node.select(search ? "div.video-info-header h3 a" : "div.module-item-pic > a").first() else { continue }
            let href = try link.attr("href")
            guard let id = numericID(href), seen.insert(id).inserted else { continue }
            let title = try link.attr("title")
            let name = try title.isEmpty ? link.text() : title
            guard !name.isEmpty else { continue }
            let img = try node.select("div.module-item-pic img").first()
            let image = try img?.attr("data-src") ?? ""
            let fallback = try img?.attr("src") ?? ""
            let picture = pictureURL(image.isEmpty ? fallback : image, base: base)
            let remarks = try node.select(search ? "a.video-serial" : "div.module-item-text").text()
            result.append(MediaItem(id: id, name: name, picture: picture, remarks: remarks))
        }
        return result
    }
    public func shareDetail(_ source: MediaSource, id: String) async throws -> MediaDetail {
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw TVError.message("玩偶影片标识无效") }
        let base = try await base(source)
        let response = try await fetch(URL(string: "voddetail/\(id).html", relativeTo: base)!.absoluteURL)
        return try Self.detail(response.html, id: id, base: response.url)
    }
    public static func detail(_ html: String, id: String, base: URL) throws -> MediaDetail {
        let document = try SwiftSoup.parse(html, base.absoluteString)
        let cover = try document.select("div.video-cover div.module-item-pic img").first()
        var name = try cover?.attr("alt") ?? ""
        if name.isEmpty { name = try document.select("h1").text() }
        guard !name.isEmpty else { throw TVError.message("玩偶详情页面未返回影片名称") }
        let picture = pictureURL(try cover?.attr("data-src") ?? "", base: base)
        let synopsis = try document.select("div.video-info-content").text()
        let remarks = try document.select("div.video-info-header a.video-serial").text()
        var shares: [Episode] = [], seen = Set<String>()
        for element in try document.select("div.module-row-info > a").array() {
            let text = try element.attr("data-clipboard-text")
            let raw = text.isEmpty ? try element.attr("href") : text
            guard let range = raw.range(of: #"https://(?:pan\.quark\.cn|drive\.uc\.cn)/s/[A-Za-z0-9]+(?:\?[^\s<>\"]*)?"#, options: .regularExpression) else { continue }
            let url = String(raw[range])
            guard let share = try? QuarkClient.shareID(url,drive:URL(string:url)?.host == "drive.uc.cn" ? .uc : .quark), seen.insert((URL(string:url)?.host ?? "") + share).inserted else { continue }
            var label = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
            if label.isEmpty || label.contains("http") { label = "夸克 \(shares.count+1)" }
            shares.append(Episode(name: label, url: url, line: label))
        }
        var metadata: [String:String] = [:]
        for row in try document.select(".video-info-items").array() {
            let label = try row.select(".video-info-itemtitle").text().replacingOccurrences(of:"：",with:"").replacingOccurrences(of:":",with:"")
            let value = try row.select(".video-info-item").text()
            if ["年份","地区","类型","导演","演员","主演"].contains(label), !value.isEmpty { metadata[label == "主演" ? "演员":label] = value }
        }
        guard !shares.isEmpty else { throw TVError.message("此影片没有夸克或 UC 分享线路") }
        return MediaDetail(item: MediaItem(id: id, name: name, picture: picture, remarks: remarks), episodes: shares, synopsis: synopsis, metadata: metadata)
    }
    private static func numericID(_ href: String) -> String? {
        guard let range = href.range(of: #"/voddetail/[0-9]+\.html"#, options: .regularExpression) else { return nil }
        return String(href[range]).dropFirst("/voddetail/".count).dropLast(".html".count).description
    }
    private static func pictureURL(_ raw: String, base: URL) -> String {
        let text = raw.replacingOccurrences(of: "/db.php?url=", with: "")
        guard !text.isEmpty, let url = URL(string: text, relativeTo: base)?.absoluteURL, CatalogParser.validHTTP(url.absoluteString) else { return "" }
        return url.absoluteString
    }
}
private extension URL {
    var deletingLastPathComponentIfNeeded: URL {
        var parts = URLComponents(url: self, resolvingAgainstBaseURL: true)!
        parts.path = "/"; parts.query = nil; parts.fragment = nil
        return parts.url!
    }
}

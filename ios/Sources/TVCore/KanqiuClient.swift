import Foundation
import SwiftSoup

/// 八八赛事目录及原插件的链接封装；未开赛赛事不伪造播放线路。
public struct KanqiuClient: Sendable {
    public static let categories = [(id:"all",name:"全部"),(id:"1",name:"足球"),(id:"8",name:"篮球"),(id:"21",name:"综合")]
    public var transport: any HTTPTransport
    public init(transport: any HTTPTransport = NetworkTransport()) { self.transport = transport }
    private func root(_ source: MediaSource) -> URL {
        URL(string: CatalogParser.validHTTP(source.ext.string) ? source.ext.string : "https://www.88kanqiu.us")!
    }
    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url:url)
        request.allHTTPHeaderFields = ["User-Agent":SeedhubClient.userAgent,"Referer":url.deletingLastPathComponent().absoluteString]
        for _ in 0..<5 {
            let reply = try await transport.send(request)
            if [301,302,303,307,308].contains(reply.status),
               let location = reply.headers.first(where: { $0.key.lowercased() == "location" })?.value,
               let next = URL(string:location,relativeTo:request.url)?.absoluteURL,
               next.host == url.host, ["http","https"].contains(next.scheme ?? ""),
               !(request.url?.scheme == "https" && next.scheme == "http") {
                request.url = next
                continue
            }
            guard reply.status == 200 else { throw DAVFailure.status(reply.status) }
            return reply.body
        }
        throw TVError.message("八八站点跳转次数过多")
    }
    public func browse(_ source:MediaSource, keyword:String="", page:Int=1, category:String="") async throws -> [MediaItem] {
        guard page == 1 else { return [] }
        let base = root(source)
        let url = category.isEmpty || category == "all" ? base : base.appendingPathComponent("match/\(category)/live")
        let doc = try SwiftSoup.parse(String(decoding:await fetch(url),as:UTF8.self),url.absoluteString)
        guard try !doc.select(".list-group").isEmpty || !doc.select(".list-group-item").isEmpty else {
            throw TVError.message("八八未返回赛事目录，站点可能需要验证或已更换地址")
        }
        return try doc.select(".list-group-item").array().compactMap { row in
            let href = try row.select(".btn.btn-primary").attr("href")
            guard !href.isEmpty, let address = URL(string:href,relativeTo:base)?.absoluteURL, CatalogParser.validHTTP(address.absoluteString) else { return nil }
            let hidden = try row.select(".row.d-none").text()
            let name = try hidden.isEmpty ? row.text() : hidden
            guard keyword.isEmpty || name.localizedCaseInsensitiveContains(keyword) else { return nil }
            let picture = try row.select(".col-xs-1 img").first()?.absUrl("data-src") ?? ""
            return MediaItem(id:address.absoluteString,name:name,picture:picture)
        }
    }
    public func detail(_ source:MediaSource,id:String) async throws -> MediaDetail {
        guard let url = URL(string:id), url.host == root(source).host, CatalogParser.validHTTP(id) else { throw TVError.message("八八赛事标识无效") }
        // Android 历史记录保留原 play 地址；source 接口返回前六后两字符包裹的 Base64。
        var endpoint = URLComponents(url:url,resolvingAgainstBaseURL:false)!
        endpoint.path = endpoint.path.replacingOccurrences(of:"play",with:"source")
        let envelope = try JSON.parse(await fetch(endpoint.url!))["data"].string
        guard envelope.count > 8, let decoded = Data(base64Encoded:String(envelope.dropFirst(6).dropLast(2)),options:.ignoreUnknownCharacters) else { throw TVError.message("八八未返回赛事线路") }
        let rows = try JSON.parse(decoded)["links"].array
        let episodes = rows.compactMap { row -> Episode? in
            guard let address = URL(string:row["url"].string,relativeTo:url)?.absoluteURL, CatalogParser.validHTTP(address.absoluteString) else { return nil }
            return Episode(name:"直播",url:address.absoluteString,line:row["name"].string)
        }
        guard !episodes.isEmpty else { throw TVError.message("本场赛事暂无直播线路，可能尚未开赛或已经结束") }
        return MediaDetail(item:MediaItem(id:id,name:"八八体育赛事"),episodes:episodes,synopsis:"")
    }
    public func resolve(_ episode:Episode) async throws -> ResolvedMedia {
        guard let url = URL(string:episode.url), CatalogParser.validHTTP(episode.url) else { throw TVError.message("八八线路地址无效") }
        let headers = ["User-Agent":SeedhubClient.userAgent,"Referer":episode.url]
        if let raw = URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name == "url"})?.value, CatalogParser.validHTTP(raw) {
            return ResolvedMedia(url:raw,headers:headers)
        }
        if ["m3u8","mp4","mkv","flv","ts","m4v","mpd"].contains(url.pathExtension.lowercased()) { return ResolvedMedia(url:episode.url,headers:headers) }
        var html = String(decoding:try await fetch(url),as:UTF8.self)
        if !html.contains("encodedStr"),
           let id = URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first(where: { $0.name == "id" })?.value,
           let prefix = LegacyWebsiteClient.match(html, #"src\s*=\s*'([^'\"]*)\"\s*\+\s*id"#) {
            // Android 的包装页把播放器前缀与 id 拼接；只读取同站 HTTPS/HTTP 页面。
            let encodedID = id.addingPercentEncoding(withAllowedCharacters:CharacterSet.alphanumerics.union(CharacterSet(charactersIn:"-._~"))) ?? ""
            if let inner = URL(string:prefix+encodedID,relativeTo:url)?.absoluteURL,
               inner.host == url.host, CatalogParser.validHTTP(inner.absoluteString),
               !(url.scheme == "https" && inner.scheme == "http") {
                html = String(decoding:try await fetch(inner),as:UTF8.self)
            }
        }
        let regex = try NSRegularExpression(pattern:"encodedStr\\s*=\\s*['\"]([^'\"]+)['\"]")
        if let match = regex.firstMatch(in:html,range:NSRange(html.startIndex...,in:html)), let range = Range(match.range(at:1),in:html), let bytes = Data(base64Encoded:String(html[range])) {
            let clear = try Self.decrypt(bytes,key:Data("ABCDEFGHIJKLMNOPQRSTUVWX".utf8))
            let address = try JSON.parse(clear)["url"].string
            guard CatalogParser.validHTTP(address) else { throw TVError.message("八八解密线路未返回媒体地址") }
            return ResolvedMedia(url:address,headers:headers)
        }
        throw HTMLPlaybackRequired(page:episode.url,headers:headers,preferVLC:false)
    }
    /// 对照原插件 XXTEA（小端字、末字记录明文长度），不是 AES。
    static func decrypt(_ data:Data,key:Data) throws -> Data {
        guard data.count >= 8, data.count % 4 == 0 else { throw TVError.message("八八线路密文长度无效") }
        func words(_ bytes:Data) -> [UInt32] {
            var result = [UInt32](repeating:0,count:(bytes.count+3)/4)
            for (i,byte) in bytes.enumerated() { result[i/4] |= UInt32(byte) << UInt32((i%4)*8) }
            return result
        }
        var values = words(data), keys = Array(words(key).prefix(4))
        while keys.count < 4 { keys.append(0) }
        let n = values.count-1, delta:UInt32 = 0x9e3779b9
        var sum = UInt32(6+52/values.count) &* delta, y = values[0]
        func mix(_ z:UInt32,_ y:UInt32,_ sum:UInt32,_ p:Int,_ e:Int) -> UInt32 {
            ((z >> 5 ^ y << 2) &+ (y >> 3 ^ z << 4)) ^ ((sum ^ y) &+ (keys[(p & 3) ^ e] ^ z))
        }
        while sum != 0 {
            let e = Int((sum >> 2) & 3)
            for p in stride(from:n,through:1,by:-1) { values[p] = values[p] &- mix(values[p-1],y,sum,p,e);y = values[p] }
            values[0] = values[0] &- mix(values[n],y,sum,0,e);y = values[0];sum = sum &- delta
        }
        let count = Int(values[n]), maximum = n*4
        guard count >= maximum-3, count <= maximum else { throw TVError.message("八八线路解密长度校验失败") }
        return Data((0..<count).map { UInt8(truncatingIfNeeded:values[$0/4] >> UInt32(($0%4)*8)) })
    }
}

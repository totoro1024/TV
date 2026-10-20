import Foundation
import SwiftSoup

/// 新6V目录与磁力选集。磁力须由支持该协议的播放引擎处理，不能交给 AVPlayer 当直链。
public struct SixVClient: Sendable {
    public static let categories = ["dianshiju/guoju","dianshiju/rihanju","dianshiju/oumeiju","xijupian","dongzuopian","aiqingpian","kehuanpian","kongbupian","juqingpian","zhanzhengpian","jilupian","donghuapian"].enumerated().map { (id:$0.element,name:["国剧","日韩剧","欧美剧","喜剧片","动作片","爱情片","科幻片","恐怖片","剧情片","战争片","纪录片","动画片"][$0.offset]) }
    public var transport:any HTTPTransport
    public init(transport:any HTTPTransport = NetworkTransport()) { self.transport = transport }
    private func base(_ source:MediaSource) throws -> URL {
        guard CatalogParser.validHTTP(source.ext.string),let url = URL(string:source.ext.string) else { throw TVError.message("新6V需要有效的站点网址配置") }
        return url
    }
    private func document(_ source:MediaSource,path:String,keyword:String? = nil) async throws -> Document {
        let root = try base(source)
        guard let url = path.isEmpty ? root : URL(string:path,relativeTo:root)?.absoluteURL,url.host == root.host else { throw TVError.message("新6V目录标识无效") }
        var request = URLRequest(url:url)
        request.allHTTPHeaderFields = ["User-Agent":SeedhubClient.userAgent,"Referer":root.absoluteString,"Origin":root.absoluteString.trimmingCharacters(in:CharacterSet(charactersIn:"/"))]
        if let keyword {
            request.httpMethod = "POST"
            var body = URLComponents();body.queryItems = ["show":"title","tempid":"1","tbname":"article","mid":"1","dopost":"search","submit":"","keyboard":keyword].sorted{$0.key < $1.key}.map { URLQueryItem(name:$0.key,value:$0.value) }
            request.httpBody = Data((body.percentEncodedQuery?.replacingOccurrences(of:"+",with:"%2B") ?? "").utf8);request.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type")
        }
        for _ in 0..<5 {
            let reply = try await transport.send(request)
            if [301,302,303,307,308].contains(reply.status),let location = reply.headers.first(where:{$0.key.lowercased() == "location"})?.value,let next = URL(string:location,relativeTo:request.url)?.absoluteURL,next.host == root.host,CatalogParser.validHTTP(next.absoluteString) {
                request.url = next
                if reply.status == 303 || [301,302].contains(reply.status) && request.httpMethod == "POST" { request.httpMethod = "GET";request.httpBody = nil }
                continue
            }
            guard reply.status == 200 else { throw DAVFailure.status(reply.status) }
            guard let html = String(data:reply.body,encoding:.utf8) else { throw TVError.message("新6V页面编码暂不支持") }
            let doc = try SwiftSoup.parse(html,request.url!.absoluteString)
            let title = try doc.title()
            guard !title.contains("验证"),!title.contains("Just a moment") else { throw TVError.message("新6V站点需要访问验证") }
            return doc
        }
        throw TVError.message("新6V站点跳转次数过多")
    }
    public func browse(_ source:MediaSource,keyword:String="",page:Int=1,category:String="") async throws -> [MediaItem] {
        if !keyword.isEmpty && page > 1 { return [] }
        let folder = category.isEmpty ? "" : "/"+category.trimmingCharacters(in:CharacterSet(charactersIn:"/"))+"/"
        let path:String
        if !keyword.isEmpty {
            let home = try await document(source,path:"")
            let action = try home.select("form[name=searchform]").first()?.attr("action") ?? "/e/search/11index.php"
            path = action
        } else { path = page == 1 ? folder : folder+"index_\(page).html" }
        let doc = try await document(source,path:path,keyword:keyword.isEmpty ? nil : keyword)
        let rows = try doc.select("#post_container .zoom").array()
        if rows.isEmpty && keyword.isEmpty { throw TVError.message("新6V页面未返回影片目录") }
        return try rows.compactMap { link in
            let href = try link.attr("href"),name = try SwiftSoup.parse(link.attr("title")).text()
            guard !href.isEmpty,!name.isEmpty else { return nil }
            return MediaItem(id:href,name:name,picture:try link.select("img").first()?.absUrl("src") ?? "")
        }
    }
    public func detail(_ source:MediaSource,id:String,cookie:String? = nil,ucCookie:String? = nil) async throws -> MediaDetail {
        let doc = try await document(source,path:id)
        var episodes:[Episode] = []
        for (index,section) in try doc.select("#post_content").array().enumerated() {
            for link in try section.select("table a[href^=magnet]").array() {
                let url = try link.attr("href"),name = try link.text()
                guard URLComponents(string:url)?.queryItems?.contains(where:{$0.name == "xt" && $0.value?.hasPrefix("urn:btih:") == true}) == true else { continue }
                episodes.append(Episode(name:name.isEmpty ? "磁力资源" : name,url:url,line:"磁力\(index+1)"))
            }
        }
        let name = try doc.select(".article_container > h1").text()
        let shares = try doc.select("#post_content a[href]").array().map { try $0.attr("href") }.filter {
            (try? QuarkClient.shareID($0)) != nil || (try? QuarkClient.shareID($0,drive:.uc)) != nil
        }
        var seen = Set<String>(),lastFailure:Error?
        for (index,share) in shares.prefix(8).enumerated() where seen.insert(share).inserted {
            do {
                let detail=try await CloudSearchClient(transport:transport).detail(id:share,cookie:cookie,ucCookie:ucCookie)
                episodes += detail.episodes.map { Episode(name:$0.name,url:$0.url,line:$0.line.replacingOccurrences(of:"1",with:String(index+1))) }
            } catch is CancellationError { throw CancellationError() }
              catch { lastFailure=error }
        }
        if episodes.isEmpty,let lastFailure { throw lastFailure }
        // 有可播放夸克线路时优先展示，避免默认落到尚无引擎的磁力线路。
        episodes = episodes.filter { !$0.url.hasPrefix("magnet:") } + episodes.filter { $0.url.hasPrefix("magnet:") }
        guard !episodes.isEmpty else { throw TVError.message("新6V详情未返回可用磁力、夸克或 UC 分享；其他网盘尚待适配") }
        return MediaDetail(item:MediaItem(id:id,name:try doc.select(".article_container > h1").text(),picture:try doc.select("#post_content img").first()?.absUrl("src") ?? ""),episodes:episodes,synopsis:try doc.select(".context").text())
    }
}

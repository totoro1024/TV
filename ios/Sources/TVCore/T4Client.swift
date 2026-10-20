import Foundation
import SwiftSoup

/// 对照 Android T4 插件，保留 ext 中的接口、分类和搜索模式。
public struct T4Client:Sendable {
    public var transport:any HTTPTransport
    public init(transport:any HTTPTransport = NetworkTransport()) { self.transport=transport }
    private func configuration(_ source:MediaSource) throws -> JSON { try App99Crypto.configuration(source.ext) }
    private func address(_ source:MediaSource) throws -> String {
        let ext=try configuration(source), address=ext.string.isEmpty ? ext["siteUrl"].string:ext.string
        guard CatalogParser.validHTTP(address) else { throw TVError.message("T4接口配置无效") };return address
    }
    public func categories(_ source:MediaSource) async throws -> [(id:String,name:String)] {
        let config=try configuration(source)
        let root=try JSON.parse(await CatalogClient(transport:transport).fetch(address(source)))
        let allowed=Set(config["categories"].array.map(\.string))
        return root["class"].array.compactMap { row in
            let name=row["type_name"].string,id=row["type_id"].string.isEmpty ? String(row["type_id"].int):row["type_id"].string
            return allowed.isEmpty || allowed.contains(name) ? (id,name):nil
        }
    }
    public func browse(_ source:MediaSource,keyword:String="",page:Int=1,category:String="") async throws -> [MediaItem] {
        let config=try configuration(source), client=CatalogClient(transport:transport)
        let mode=config["searchMode"].string
        if !keyword.isEmpty && mode.hasPrefix("web&") {
            let site=String(mode.dropFirst(4))
            guard CatalogParser.validHTTP(site),let base=URL(string:site) else { throw TVError.message("T4网页搜索地址无效") }
            let path=base.appendingPathComponent("index.php/vod/search/page/\(max(1,page))/wd/\(keyword).html")
            let data=try await client.fetch(path.absoluteString)
            guard let html=String(data:data,encoding:.utf8),!html.contains("系统安全验证") else { throw TVError.message("此源搜索需要网页安全验证") }
            let doc=try SwiftSoup.parse(html,base.absoluteString)
            var seen=Set<String>()
            return try doc.select("a[href*='index.php/vod/detail']").array().compactMap { a in
                let path=try a.attr("href"), id=path.components(separatedBy:"/id/").last?.components(separatedBy:".").first ?? ""
                let name=try a.attr("title").isEmpty ? a.text():a.attr("title")
                guard !id.isEmpty,!name.isEmpty,seen.insert(id).inserted else { return nil }
                return MediaItem(id:id,name:name,picture:try a.select("img").first()?.absUrl("data-original") ?? "")
            }
        }
        var params=["ac":"detail","pg":String(max(1,page))]
        if !keyword.isEmpty { params["wd"]=keyword };if !category.isEmpty { params["t"]=category }
        return try CatalogParser.items(await client.fetch(address(source),parameters:params))
    }
    public func detail(_ source:MediaSource,id:String) async throws -> MediaDetail {
        try CatalogParser.detail(await CatalogClient(transport:transport).fetch(address(source),parameters:["ac":"detail","ids":id]))
    }
    public func resolve(_ source:MediaSource,episode:Episode) async throws -> ResolvedMedia {
        let config=try configuration(source)
        if config["type"].int == 4 {
            let root=try JSON.parse(await CatalogClient(transport:transport).fetch(address(source),parameters:["play":episode.url,"flag":episode.line]))
            guard root["parse"].int == 0,CatalogParser.validHTTP(root["url"].string) else { throw TVError.message("T4线路需要网页解析") }
            return ResolvedMedia(url:root["url"].string,headers:root["header"].object.mapValues(\.string))
        }
        let parser=config["playUrl"].string
        if !parser.isEmpty {
            let root=try JSON.parse(await CatalogClient(transport:transport).fetch(parser+episode.url))
            guard CatalogParser.validHTTP(root["url"].string) else { throw TVError.message("T4解析未返回媒体地址") }
            return ResolvedMedia(url:root["url"].string)
        }
        guard CatalogParser.validHTTP(episode.url) else { throw TVError.message("此T4线路没有可用的直连地址") }
        return ResolvedMedia(url:episode.url)
    }
}

import Foundation
import CryptoKit

/// 对照热播 Android 插件的 multipart 签名接口；解析信息随分集保存，重启后仍可播放。
public struct AppTTClient:Sendable {
    public var transport:any HTTPTransport
    public init(transport:any HTTPTransport = NetworkTransport()) { self.transport=transport }
    private static let salt = "7gp0bnd2sr85ydii2j32pcypscoc4w6c7g5spl"
    private func root(_ source:MediaSource) throws -> String {
        let raw=source.ext.string
        let decoded=CatalogParser.validHTTP(raw) ? raw:try App99Crypto.decodePluginText(raw)
        guard CatalogParser.validHTTP(decoded) else { throw TVError.message("热播接口配置无效") };return decoded.trimmingCharacters(in:CharacterSet(charactersIn:"/"))
    }
    private func request(_ source:MediaSource,path:String,params:[String:String]=[:]) async throws -> JSON {
        guard let url=URL(string:try root(source)+path) else { throw TVError.message("热播接口地址无效") }
        let timestamp=String(Int(Date().timeIntervalSince1970)), boundary="TV-"+UUID().uuidString
        let sign=Insecure.MD5.hash(data:Data((Self.salt+timestamp).utf8)).map { String(format:"%02x",$0) }.joined()
        var fields=params;fields["sign"]=sign;fields["timestamp"]=timestamp
        var body=""
        for (key,value) in fields.sorted(by: { $0.key < $1.key }) { body += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n" }
        body += "--\(boundary)--\r\n"
        var request=URLRequest(url:url);request.httpMethod="POST";request.httpBody=Data(body.utf8)
        request.setValue("multipart/form-data; boundary=\(boundary)",forHTTPHeaderField:"Content-Type");request.setValue("okhttp-okgo/jeasonlzy",forHTTPHeaderField:"User-Agent")
        let reply=try await transport.send(request)
        guard reply.status == 200 else { throw DAVFailure.status(reply.status) }
        let root=try JSON.parse(reply.body)
        guard case .object = root["data"] else { throw TVError.message("热播接口未返回预期数据") }
        return root["data"]
    }
    public func categories(_ source:MediaSource) async throws -> [(id:String,name:String)] {
        try await request(source,path:"/v3/type/top_type")["list"].array.map { row in (Self.id(row["type_id"]),row["type_name"].string) }
    }
    private static func id(_ value:JSON) -> String { value.string.isEmpty ? String(value.int):value.string }
    public func browse(_ source:MediaSource,keyword:String="",page:Int=1,category:String="") async throws -> [MediaItem] {
        let rows:[JSON]
        if !keyword.isEmpty {
            guard page == 1 else { return [] }
            rows=try await request(source,path:"/v3/home/search",params:["keyword":keyword])["list"].array
        } else if !category.isEmpty {
            rows=try await request(source,path:"/v3/home/type_search",params:["limit":"12","type_id":category,"page":String(page)])["list"].array
        } else {
            guard page == 1 else { return [] }
            rows=try await request(source,path:"/v3/type/tj_vod")["type_vod"].array.flatMap { $0["vod"].array }
        }
        return try CatalogParser.items(JSON.object(["list":.array(rows)]).data)
    }
    public func detail(_ source:MediaSource,id:String) async throws -> MediaDetail {
        let row=try await request(source,path:"/v3/home/vod_details",params:["vod_id":id])
        var episodes:[Episode]=[]
        for group in row["vod_play_list"].array {
            for entry in group["urls"].array {
                let raw=entry["url"].string
                guard !raw.isEmpty else { continue }
                let payload=JSON.object(["url":.string(raw),"parsers":group["parse_urls"]])
                episodes.append(Episode(name:entry["name"].string,url:payload.text,line:group["flag"].string))
            }
        }
        let fallback=try CatalogParser.detail(JSON.object(["list":.array([row])]).data)
        return MediaDetail(item:fallback.item,episodes:episodes,synopsis:fallback.synopsis,metadata:fallback.metadata)
    }
    public func resolve(_ episode:Episode) async throws -> ResolvedMedia {
        let payload=try JSON.parse(Data(episode.url.utf8)),raw=payload["url"].string
        if CatalogParser.validHTTP(raw),["m3u8","mp4","mkv","flv"].contains(URL(string:raw)?.pathExtension.lowercased() ?? "") { return ResolvedMedia(url:raw) }
        for parser in payload["parsers"].array {
            guard CatalogParser.validHTTP(parser.string),let url=URL(string:parser.string+raw) else { continue }
            let reply=try await transport.send(URLRequest(url:url));guard reply.status == 200 else { continue }
            guard let root=try? JSON.parse(reply.body) else { continue }
            let media=root["url"].string.isEmpty ? root["data"]["url"].string:root["url"].string
            if CatalogParser.validHTTP(media) { return ResolvedMedia(url:media) }
        }
        throw TVError.message("热播线路未返回可用视频，可能需要网页解析")
    }
}

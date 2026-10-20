import Foundation

/// 原生读取 DouDou 片单使用的豆瓣推荐接口，不执行 Android 插件。
public struct DouDouClient: Sendable {
    public var transport: any HTTPTransport
    public init(transport: any HTTPTransport = NetworkTransport()) { self.transport = transport }
    public func recommendations(page: Int = 1) async throws -> [MediaItem] {
        var url = URLComponents(string: "https://frodo.douban.com/api/v2/subject_collection/subject_real_time_hotest/items")!
        url.queryItems = [URLQueryItem(name: "apikey", value: "0ac44ae016490db2204ce0a042db2916"), URLQueryItem(name: "start", value: String(max(0, page - 1) * 20)), URLQueryItem(name: "count", value: "20")]
        var request = URLRequest(url: url.url!)
        request.setValue("Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/53.0.2785.143 Safari/537.36 MicroMessenger/7.0.9.501 NetType/WIFI MiniProgramEnv/Windows WindowsWechat", forHTTPHeaderField: "User-Agent")
        request.setValue("https://servicewechat.com/wx2f9b06c1de1ccfca/84/page-frame.html", forHTTPHeaderField: "Referer")
        let response = try await transport.send(request)
        guard response.status == 200 else { throw TVError.message("豆豆推荐接口返回 HTTP \(response.status)") }
        return try Self.items(response.body)
    }
    public static func items(_ data: Data) throws -> [MediaItem] {
        let root = try JSON.parse(data)
        guard case .array(let rows) = root["subject_collection_items"] else { throw TVError.message("豆豆推荐未返回片单") }
        return rows.compactMap { row in
            let name = row["title"].string, type = row["type"].string
            guard !name.isEmpty, type != "ad", type != "playlist" else { return nil }
            let id = row["id"].string.isEmpty ? row["id"].text : row["id"].string
            guard !id.isEmpty, id != "null" else { return nil }
            let picture = row["pic"]["normal"].string.isEmpty ? row["cover_url"].string : row["pic"]["normal"].string
            let rating = row["rating"]["value"]
            let remark = rating == .null || rating.int == 0 && rating.text == "0" ? "" : "评分 " + (rating.string.isEmpty ? rating.text : rating.string)
            return MediaItem(id: id, name: name, picture: picture, remarks: remark)
        }
    }
}

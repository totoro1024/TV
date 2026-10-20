import Foundation

public struct MediaSource: Identifiable, Hashable, Sendable {
    public func hash(into hasher: inout Hasher) { hasher.combine(sourceID); hasher.combine(id); hasher.combine(ext.text) }
    public enum Kind: String, Sendable { case api, cloudConfiguration, pushInput, notice, jpj, music, sixv, alllive, kanqiu, aidj, seedhub, jpys, appgz, streamSite, cloudMirror, livegz, hmys, audiobook, cloudSearch, doubao, legacySite, appsx, apptt, t4, website, bili, app99, wogg, doudou, playlist, direct, unsupported }
    public var isUtility: Bool { [.cloudConfiguration,.pushInput,.notice].contains(kind) }
    public var utilityDescription: String {
        switch kind {
        case .cloudConfiguration: return "网盘配置入口：统一扫码登录夸克、UC，或读取 WebDAV 同步的登录配置。"
        case .pushInput: return "视频输入入口：粘贴HTTP或HTTPS视频直链播放。"
        case .notice: return "此项是源配置中的使用提醒，没有影片推荐、搜索或播放内容。\n" + name
        default: return ""
        }
    }
    public var usesQuark: Bool { kind == .wogg || kind == .cloudSearch || kind == .cloudMirror || kind == .seedhub || kind == .sixv || address == "csp_LibvioGuard" }
    public func isQuarkEpisode(_ episode:Episode) -> Bool {
        guard usesQuark else { return false }
        guard kind == .legacySite else { return true }
        guard let payload=try? JSON.parse(Data(episode.url.utf8)) else { return false }
        return !payload["sId"].string.isEmpty && !payload["fid"].string.isEmpty
    }
    public var supportsCatalog: Bool { [.api,.jpj,.music,.sixv,.alllive,.kanqiu,.aidj,.seedhub,.jpys,.appgz,.streamSite,.cloudMirror,.livegz,.hmys,.audiobook,.cloudSearch,.doubao,.legacySite,.appsx,.apptt,.t4,.website,.bili,.app99,.wogg,.doudou].contains(kind) }
    public var supportsSearch: Bool { supportsCatalog && kind != .doudou }
    public var ext: JSON = .null
    public var id: String, sourceID: String, name: String, address: String, kind: Kind, reason: String
    public init(id: String, sourceID: String, name: String, address: String, kind: Kind, reason: String = "", ext: JSON = .null) {
        self.id = id; self.sourceID = sourceID; self.name = name; self.address = address; self.kind = kind; self.reason = reason; self.ext = ext
    }
}
public struct MediaItem: Identifiable, Hashable, Sendable {
    public var id: String, name: String, picture: String, remarks: String
    public init(id: String, name: String, picture: String = "", remarks: String = "") { self.id = id; self.name = name; self.picture = picture; self.remarks = remarks }
}
public struct Episode: Identifiable, Hashable, Sendable {
    public var name: String, url: String, line: String
    public var id: String { line + "\u{0}" + name + "\u{0}" + url }
    public func matchesHistory(_ record: JSON?) -> Bool {
        guard let record else { return false }
        if name == record["episode"].string && line == record["line"].string { return true }
        let oldURL = record["episodeUrl"].string
        if !url.isEmpty && url == oldURL { return true }
        guard let current = try? JSON.parse(Data(url.utf8)), let old = try? JSON.parse(Data(oldURL.utf8)),
              !current["sId"].string.isEmpty, !current["fid"].string.isEmpty else { return false }
        return current["sId"] == old["sId"] && current["fid"] == old["fid"]
    }

    public init(name: String, url: String, line: String = "直连") { self.name = name; self.url = url; self.line = line }
}
public struct MediaDetail: Sendable {
    public var item: MediaItem, episodes: [Episode], synopsis: String
    public var metadata: [String:String]
    public var resources:[MediaItem] = []
    public init(item: MediaItem, episodes: [Episode], synopsis: String, metadata: [String:String] = [:],resources:[MediaItem] = []) { self.item = item; self.episodes = episodes; self.synopsis = synopsis; self.metadata = metadata; self.resources=resources }
}
public enum CatalogParser {
    public static func configuration(data: Data, address: String, sourceID: String) throws -> [MediaSource] {
        if let text = String(data: data, encoding: .utf8), text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") {
            return [MediaSource(id: "m3u", sourceID: sourceID, name: "直播列表", address: address, kind: .playlist)]
        }
        let root = try SourceConfiguration.parse(data)
        if !root["sites"].array.isEmpty {
            return root["sites"].array.map { row in
                let api = row["api"].string
                let native = api == "csp_App99Guard"
                let streamProvider = PublicStreamClient.provider(MediaSource(id:"",sourceID:"",name:"",address:api,kind:.unsupported,ext:row["ext"]))
                let supported = row["type"].int == 1 && validHTTP(api)
                return MediaSource(id: row["key"].string, sourceID: sourceID, name: row["name"].string,
                    address: api, kind: api == "csp_MyDriveGuard" ? .cloudConfiguration : api == "csp_PushGuard" ? .pushInput : api == "csp_XPathGuard" ? .notice : api == "csp_JPJGuard" ? .jpj : api == "csp_MusicGuard" ? .music : api == "csp_SixVGuard" ? .sixv : api == "csp_AllliveGuard" ? .alllive : api == "csp_KanqiuGuard" ? .kanqiu : api == "csp_AiDjGuard" ? .aidj : api == "csp_SeedhubGuard" ? .seedhub : api == "csp_JpysGuard" ? .jpys : api == "csp_AppgzGuard" ? .appgz : streamProvider != nil ? .streamSite : CloudMirrorClient.plugins.contains(api) ? .cloudMirror : api == "csp_LiveGzGuard" ? .livegz : api == "csp_HmysGuard" ? .hmys : api == "csp_Tingshu275Guard" ? .audiobook : CloudSearchClient.plugins.contains(api) ? .cloudSearch : api == "csp_DoubaoGuard" ? .doubao : LegacyWebsiteClient.plugins.contains(api) ? .legacySite : api == "csp_AppSxGuard" ? .appsx : api == "csp_AppTTGuard" ? .apptt : api == "csp_T4Guard" ? .t4 : WebsiteClient.plugins.contains(api) ? .website : api == "csp_BiliGuard" ? .bili : native ? .app99 : api == "csp_WoGGGuard" ? .wogg : ["csp_DouDou", "csp_DouDouGuard"].contains(api) ? .doudou : supported ? .api : .unsupported,
                    reason: "此站点的插件尚未移植到 iPhone，首页、搜索、详情与播放暂未接入。", ext: row["ext"])
            }
        }
        if case .array = root["list"] { return [MediaSource(id: "api", sourceID: sourceID, name: "影视 API", address: address, kind: .api)] }
        throw TVError.message("未识别的配置：请使用影视 JSON API、兼容 JSON 源配置或 M3U 列表")
    }
    public static func items(_ data: Data) throws -> [MediaItem] {
        let root = try JSON.parse(data)
        guard case .array(let list) = root["list"] else { throw TVError.message("影视 API 未返回 list 数组") }
        return list.map { row in
            let id: String
            switch row["vod_id"] { case .number(let n): id = n; default: id = row["vod_id"].string }
            return MediaItem(id: id, name: row["vod_name"].string, picture: row["vod_pic"].string, remarks: row["vod_remarks"].string)
        }.filter { !$0.id.isEmpty }
    }
    public static func detail(_ data: Data) throws -> MediaDetail {
        let items = try items(data); guard let item = items.first else { throw TVError.message("影片不存在") }
        let row = try JSON.parse(data)["list"].array[0]
        let lines = row["vod_play_from"].string.components(separatedBy: "$$$")
        let groups = row["vod_play_url"].string.components(separatedBy: "$$$")
        var episodes: [Episode] = []
        for (index, group) in groups.enumerated() {
            let line = index < lines.count ? lines[index] : "线路 \(index + 1)"
            for (number, part) in group.components(separatedBy: "#").enumerated() where !part.isEmpty {
                if let divider = part.firstIndex(of: "$") {
                    episodes.append(Episode(name: String(part[..<divider]), url: String(part[part.index(after: divider)...]), line: line))
                } else { episodes.append(Episode(name: "第 \(number + 1) 集", url: part, line: line)) }
            }
        }
        let year: String
        if case .number(let value) = row["vod_year"] { year=value } else { year=row["vod_year"].string }
        return MediaDetail(item: item, episodes: episodes, synopsis: row["vod_content"].string.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression), metadata: ["年份":year,"地区":row["vod_area"].string,"类型":row["type_name"].string,"导演":row["vod_director"].string,"演员":row["vod_actor"].string].filter { !$0.value.isEmpty && $0.value != "null" })
    }
    public static func playlist(_ data: Data, base: URL) throws -> [Episode] {
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else { throw TVError.message("不是 UTF-8 M3U 列表") }
        var name = "直播", group = "直播", result: [Episode] = []
        for line in text.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            if line.hasPrefix("#EXTINF:") {
                name = line.components(separatedBy: ",").dropFirst().joined(separator: ",")
                if let range = line.range(of: #"group-title="[^"]*""#, options: .regularExpression) {
                    group = String(line[range]).replacingOccurrences(of: "group-title=\"", with: "").dropLast().description
                }
            } else if !line.isEmpty && !line.hasPrefix("#"), let url = URL(string: line, relativeTo: base)?.absoluteURL, validHTTP(url.absoluteString) {
                result.append(Episode(name: name, url: url.absoluteString, line: group))
            }
        }
        return result
    }
    public static func validHTTP(_ text: String) -> Bool {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return false }
        return ["http","https"].contains(scheme) && url.host != nil && url.user == nil && url.password == nil
    }
    public static func playable(_ text: String) -> Bool {
        guard validHTTP(text), let url = URL(string: text) else { return false }
        return !["html","htm","php"].contains(url.pathExtension.lowercased())
    }
}
public struct CatalogClient: Sendable {
    public var transport: any HTTPTransport
    public init(transport: any HTTPTransport = NetworkTransport()) { self.transport = transport }
    public func fetch(_ address: String, parameters: [String: String] = [:]) async throws -> Data {
        guard CatalogParser.validHTTP(address), var parts = URLComponents(string: address) else { throw TVError.message("请填写有效的 HTTP 或 HTTPS 地址") }
        var query = parts.queryItems ?? []; let names = Set(parameters.keys)
        query.removeAll { names.contains($0.name) }; query += parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        if !query.isEmpty { parts.queryItems = query }
        guard let url = parts.url else { throw TVError.message("地址无效") }
        let reply = try await transport.send(URLRequest(url: url))
        guard (200..<300).contains(reply.status) else { throw DAVFailure.status(reply.status) }
        return reply.body
    }
    public func browse(_ source: MediaSource, keyword: String = "", page: Int = 1, category: String = "") async throws -> [MediaItem] {
        if source.isUtility { throw TVError.message(source.utilityDescription) }
        if source.kind == .jpj { return try await JPJClient.shared.browse(source,keyword:keyword,page:page,category:category) }
        if source.kind == .music { return try await MusicClient(transport:transport).browse(source,keyword:keyword,page:page,category:category) }
        if source.kind == .sixv { return try await SixVClient(transport:transport).browse(source,keyword:keyword,page:page,category:category) }
        if source.kind == .alllive { return try await AllLiveClient(transport:transport).browse(source,keyword:keyword,page:page,category:category) }
        if source.kind == .kanqiu { return try await KanqiuClient(transport:transport).browse(source,keyword:keyword,page:page,category:category) }
        if source.kind == .aidj { return try await EmbeddedAIClient().browse(keyword:keyword,page:page,category:category) }
        if source.kind == .seedhub { return try await SeedhubClient(transport:transport).browse(source,keyword:keyword,page:page,category:category) }
        if source.kind == .jpys { return try await JpysClient.shared.browse(source,keyword:keyword,page:page,category:category) }
        if source.kind == .appgz { return try await AppGzClient.shared.browse(keyword:keyword,page:page,category:category) }
        if source.kind == .streamSite { return try await PublicStreamClient(transport:transport).browse(source,keyword:keyword,page:page,category:category) }
        if source.kind == .cloudMirror { return try await CloudMirrorClient(transport:transport).search(source,keyword:keyword,page:page) }
        if source.kind == .livegz { return try await LiveGzClient.shared.browse(keyword:keyword,page:page,category:category) }
        if source.kind == .hmys { return try await HmysClient.shared.browse(keyword:keyword,page:page,category:category) }
        if source.kind == .audiobook { return try await AudioBookClient.shared.browse(keyword:keyword,page:page,category:category) }
        if source.kind == .cloudSearch { return try await CloudSearchClient(transport:transport).search(source,keyword:keyword,page:page) }
        if source.kind == .doubao { return try await DoubaoClient.shared.browse(keyword:keyword,page:page,category:category) }
        if source.kind == .legacySite { return try await LegacyWebsiteClient(transport:transport).browse(source,keyword:keyword,page:page,category:category) }
        if source.kind == .appsx { return try await AppSxClient.shared.browse(source,keyword:keyword,page:page,category:category) }
        if source.kind == .apptt { return try await AppTTClient(transport:transport).browse(source,keyword:keyword,page:page,category:category) }
        if source.kind == .t4 { return try await T4Client(transport:transport).browse(source,keyword:keyword,page:page,category:category) }
        if source.kind == .website { return try await WebsiteClient(transport: transport).browse(source, keyword: keyword, page: page, category: category) }
        if source.kind == .bili { return try await BiliClient(transport: transport).browse(source, keyword: keyword, page: page, category: category) }
        if source.kind == .wogg { return try await WoggClient.shared.browse(source, keyword: keyword, category: category, page: page) }
        if source.kind == .doudou { return try await DouDouClient().recommendations(page: page) }
        if source.kind == .app99 { return try await App99Client.shared.browse(source, keyword: keyword, page: page) }
        var params = ["ac":"detail", "pg":String(page)]; if !keyword.isEmpty { params["wd"] = keyword }
        return try CatalogParser.items(await fetch(source.address, parameters: params))
    }
    public func detail(_ source: MediaSource, id: String, quarkCookie: String? = nil, ucCookie: String? = nil) async throws -> MediaDetail {
        if source.isUtility { throw TVError.message(source.utilityDescription) }
        if source.kind == .jpj { return try await JPJClient.shared.detail(source,id:id) }
        if source.kind == .music { return try await MusicClient(transport:transport).detail(source,id:id) }
        if source.kind == .sixv { return try await SixVClient(transport:transport).detail(source,id:id,cookie:quarkCookie,ucCookie:ucCookie) }
        if source.kind == .alllive { return try await AllLiveClient(transport:transport).detail(source,id:id) }
        if source.kind == .kanqiu { return try await KanqiuClient(transport:transport).detail(source,id:id) }
        if source.kind == .aidj { return try await EmbeddedAIClient().detail(id:id) }
        if source.kind == .seedhub { return try await SeedhubClient(transport:transport).detail(source,id:id,cookie:quarkCookie,ucCookie:ucCookie) }
        if source.kind == .jpys { return try await JpysClient.shared.detail(source,id:id) }
        if source.kind == .appgz { return try await AppGzClient.shared.detail(id:id) }
        if source.kind == .streamSite { return try await PublicStreamClient(transport:transport).detail(source,id:id) }
        if source.kind == .cloudMirror { return try await CloudMirrorClient(transport:transport).detail(id:id,cookie:quarkCookie,ucCookie:ucCookie) }
        if source.kind == .livegz { return try await LiveGzClient.shared.detail(id:id) }
        if source.kind == .hmys { return try await HmysClient.shared.detail(id:id) }
        if source.kind == .audiobook { return try await AudioBookClient.shared.detail(id:id) }
        if source.kind == .cloudSearch { return try await CloudSearchClient(transport:transport).detail(id:id,cookie:quarkCookie,ucCookie:ucCookie) }
        if source.kind == .doubao { return try await DoubaoClient.shared.detail(id:id) }
        if source.kind == .legacySite { return try await LegacyWebsiteClient(transport:transport).detail(source,id:id,quarkCookie:quarkCookie,ucCookie:ucCookie) }
        if source.kind == .appsx { return try await AppSxClient.shared.detail(source,id:id) }
        if source.kind == .apptt { return try await AppTTClient(transport:transport).detail(source,id:id) }
        if source.kind == .t4 { return try await T4Client(transport:transport).detail(source,id:id) }
        if source.kind == .website { return try await WebsiteClient(transport: transport).detail(source, id: id) }
        if source.kind == .bili { return try await BiliClient(transport: transport).detail(source, id: id) }
        if source.kind == .wogg {
            var detail = try await WoggClient.shared.shareDetail(source, id: id)
            var episodes: [Episode] = [], failures = 0
            for (index, share) in detail.episodes.enumerated() {
                try Task.checkCancellation()
                guard index < 20 else { throw TVError.message("此影片分享线路过多，未加载全部选集") }
                do {
                    let shared = try await CloudSearchClient(transport:transport).detail(id:share.url,cookie:quarkCookie,ucCookie:ucCookie)
                    episodes += shared.episodes.map { Episode(name:$0.name,url:$0.url,line:$0.line.replacingOccurrences(of:"1",with:String(index+1))) }
                }
                catch { if Task.isCancelled { throw CancellationError() }; failures += 1 }
            }
            guard !episodes.isEmpty else { throw TVError.message(failures > 0 ? "网盘分享线路读取失败，请检查分享有效期、Cookie 或稍后重试" : "分享目录中没有支持的视频文件") }
            if failures > 0 { detail.synopsis += "\n部分网盘分享线路暂时无法读取，已显示其余可用线路。" }
            detail.episodes = episodes
            return detail
        }
        if source.kind == .app99 { return try await App99Client.shared.detail(source, id: id) }
        return try CatalogParser.detail(await fetch(source.address, parameters: ["ac":"detail","ids":id]))
    }
}

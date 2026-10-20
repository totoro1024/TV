import Foundation

public struct LiveSource: Identifiable, Hashable, Sendable {
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public var id: String { SyncDocument.identity(name, address) }
    public var name: String, address: String, epg: String, logo: String
    public var headers: [String:String]
    public var groups: JSON
    public var catchup: JSON
    public init(name: String, address: String, epg: String = "", logo: String = "", headers: [String:String] = [:], groups: JSON = .null, catchup: JSON = .null) {
        self.name = name; self.address = address; self.epg = epg; self.logo = logo; self.headers = headers; self.groups = groups; self.catchup = catchup
    }
}
public struct LiveRoute: Identifiable, Hashable, Sendable {
    public var id: String { url }
    public var url: String, name: String
    public var headers: [String:String]
}
public struct LiveChannel: Identifiable, Hashable, Sendable {
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public var id: String { SyncDocument.identity(group, name) }
    public var name: String, group: String, number: String, logo: String, tvgID: String, tvgName: String, epg: String
    public var routes: [LiveRoute]
    public var catchup: JSON
    public func matches(_ query: String) -> Bool {
        let value=query.trimmingCharacters(in:.whitespacesAndNewlines)
        if value.isEmpty { return true }
        if let number=Int(value) { return Int(self.number)==number }
        return name.localizedStandardContains(value) || group.localizedStandardContains(value)
    }
    public func episode(route: Int = 0) -> Episode { .init(name: name, url: routes.indices.contains(route) ? routes[route].url : "", line: group) }
}
public enum LiveParser {
    public static func playable(_ value: String) -> Bool {
        guard let url = URL(string:value), let scheme = url.scheme?.lowercased(), url.host != nil,
              url.user == nil, url.password == nil else { return false }
        return ["http","https","rtsp","rtmp","rtmps","udp","rtp"].contains(scheme)
    }
    static func resolve(_ value: String, base: String) -> String {
        guard !value.isEmpty, let url = URL(string:value,relativeTo:URL(string:base))?.absoluteURL else { return "" }
        return url.absoluteString
    }
    static func attributes(_ line: String) -> [String:String] {
        let pattern = #"([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s]+))"#
        guard let regex = try? NSRegularExpression(pattern:pattern) else { return [:] }
        let ns = line as NSString
        return regex.matches(in:line,range:NSRange(location:0,length:ns.length)).reduce(into:[:]) { values, match in
            for index in 2...4 where match.range(at:index).location != NSNotFound {
                values[ns.substring(with:match.range(at:1)).lowercased()] = ns.substring(with:match.range(at:index)); break
            }
        }
    }
    static func headers(_ value: JSON, inheriting: [String:String] = [:]) -> [String:String] {
        var result = inheriting
        for (key,value) in value["header"].object { if !key.contains("\r") && !key.contains("\n") && !value.string.contains("\n") && !value.string.contains("\r") { result[key] = value.string } }
        for (field,key) in [("ua","User-Agent"),("referer","Referer"),("origin","Origin")] where !value[field].string.isEmpty { result[key] = value[field].string }
        return result
    }
    public static func sources(_ data: Data, address: String) throws -> [LiveSource] {
        let text = String(decoding:data,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        if text.hasPrefix("#EXTM3U") || (!text.hasPrefix("{") && !text.hasPrefix("[") && (text.contains("#genre#") || text.components(separatedBy:.newlines).contains { $0.contains(",") && $0.contains("://") })) {
            return [.init(name:"直播",address:address)]
        }
        let root = try SourceConfiguration.parse(data)
        let rows = root["lives"].array
        if !rows.isEmpty {
            return rows.enumerated().map { index,row in
                LiveSource(name:row["name"].string.isEmpty ? "直播 \(index+1)" : row["name"].string,
                    address:resolve(row["url"].string,base:address),epg:row["epg"].string,logo:row["logo"].string,
                    headers:headers(row),groups:row["groups"],catchup:row["catchup"])
            }
        }
        if case .array = root { return [.init(name:"直播",address:address,groups:root)] }
        if !root["groups"].array.isEmpty { return [.init(name:"直播",address:address,groups:root["groups"])] }
        throw TVError.message("此配置没有直播列表，请在设置中选择包含 lives 的配置、M3U 或 TXT 直播源")
    }
    private static func route(_ text: String, source: LiveSource, headers: [String:String]) -> LiveRoute? {
        let pieces = text.split(separator:"|",maxSplits:1,omittingEmptySubsequences:false)
        var address = String(pieces.first ?? "").trimmingCharacters(in:.whitespacesAndNewlines), name = ""
        if let dollar = address.lastIndex(of:"$") { name = String(address[address.index(after:dollar)...]); address = String(address[..<dollar]) }
        address = resolve(address,base:source.address)
        guard playable(address) else { return nil }
        var requestHeaders = headers
        if pieces.count > 1 {
            for field in pieces[1].split(separator:"&") {
                let pair = field.split(separator:"=",maxSplits:1,omittingEmptySubsequences:false)
                if pair.count == 2 {
                    let key = String(pair[0]).removingPercentEncoding ?? String(pair[0]), value = String(pair[1]).removingPercentEncoding ?? String(pair[1])
                    if !key.contains("\n") && !key.contains("\r") && !value.contains("\n") && !value.contains("\r") { requestHeaders[key] = value }
                }
            }
        }
        return .init(url:address,name:name,headers:requestHeaders)
    }
    public static func channels(_ data: Data, source: LiveSource) throws -> [LiveChannel] {
        var result: [LiveChannel] = []
        func append(name: String, group: String, number: String = "", logo: String = "", tvg: String = "", tvgName: String = "", epg: String = "", catchup: JSON = .null, urls: [String], headers: [String:String]) {
            let routes = urls.compactMap { route($0,source:source,headers:headers) }
            guard !name.isEmpty, !routes.isEmpty else { return }
            let group = group.isEmpty ? "直播" : group
            if let index = result.firstIndex(where: { $0.name == name && $0.group == group }) {
                let known = Set(result[index].routes.map(\.url)); result[index].routes += routes.filter { !known.contains($0.url) }; return
            }
            let template = logo.isEmpty ? source.logo : logo
            let artwork = template.replacingOccurrences(of:"{name}",with:tvgName.isEmpty ? name : tvgName).replacingOccurrences(of:"{id}",with:tvg)
            var guide=epg.isEmpty ? source.epg:epg
            if !guide.hasPrefix("http") && source.epg.contains("{") { guide=source.epg.replacingOccurrences(of:"{epg}",with:epg) }
            if !guide.isEmpty && !guide.contains("{") { guide=resolve(guide,base:source.address) }
            result.append(.init(name:name,group:group,number:number.isEmpty ? String(result.count+1) : number,
                logo:resolve(artwork,base:source.address),tvgID:tvg,tvgName:tvgName.isEmpty ? name : tvgName,epg:guide,
                routes:routes,catchup:catchup == .null ? source.catchup : catchup))
        }
        var groups = source.groups
        let text = String(decoding:data,as:UTF8.self).replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n")
        if text.contains("#EXT-X-TARGETDURATION:") || text.contains("#EXT-X-STREAM-INF:") {
            append(name:source.name,group:"直播",urls:[source.address],headers:source.headers)
            return result
        }
        if groups == .null, text.trimmingCharacters(in:.whitespacesAndNewlines).hasPrefix("[") { groups = try SourceConfiguration.parse(data) }
        if case .array(let rows) = groups {
            for group in rows {
                for channel in group["channel"].array {
                    let urls = channel["urls"].array.map(\.string)
                    append(name:channel["name"].string,group:group["name"].string,number:channel["number"].string.isEmpty ? (channel["number"] == .null ? "" : String(channel["number"].int)) : channel["number"].string,
                        logo:channel["logo"].string,tvg:channel["tvgId"].string,tvgName:channel["tvgName"].string,epg:channel["epg"].string,catchup:channel["catchup"],
                        urls:urls.isEmpty ? [channel["url"].string] : urls,headers:headers(channel,inheriting:source.headers))
                }
            }
        } else {
            var info: [String:String] = [:], name = "", group = "直播", extra = source.headers, rootEPG = source.epg, rootCatchup = source.catchup
            let m3u = text.contains("#EXTM3U")
            for raw in text.components(separatedBy:.newlines) {
                let line = raw.trimmingCharacters(in:.whitespacesAndNewlines)
                if line.hasPrefix("#EXTM3U") {
                    let a = attributes(line); rootEPG = a["x-tvg-url"] ?? a["url-tvg"] ?? a["tvg-url"] ?? rootEPG
                    if let type = a["catchup"] { rootCatchup = .object(["type":.string(type),"source":.string(a["catchup-source"] ?? ""),"days":.string(a["catchup-days"] ?? "7")]) }
                } else if line.hasPrefix("#EXTINF:") {
                    info = attributes(line); extra = source.headers
                    var quoted = false; var quote: Character = "\""; var comma: String.Index?
                    for index in line.indices { let c = line[index]; if c == "\"" || c == "'" { if !quoted { quoted=true;quote=c } else if c==quote { quoted=false } }; if c == "," && !quoted { comma=index;break } }
                    name = comma.map { String(line[line.index(after:$0)...]) } ?? ""
                    group = info["group-title"] ?? "直播"
                    if let ua = info["http-user-agent"] { extra["User-Agent"] = ua }
                } else if line.hasPrefix("#EXTGRP:") { group = String(line.dropFirst(8)) }
                else if line.hasPrefix("#EXTVLCOPT:") {
                    let pair = line.dropFirst(11).split(separator:"=",maxSplits:1)
                    if pair.count == 2, let key = ["http-user-agent":"User-Agent","http-referrer":"Referer","http-referer":"Referer","http-origin":"Origin"][String(pair[0])] { extra[key] = String(pair[1]) }
                } else if !line.isEmpty && !line.hasPrefix("#") {
                    if m3u {
                        var catchup = rootCatchup
                        if let type = info["catchup"] { catchup = .object(["type":.string(type),"source":.string(info["catchup-source"] ?? ""),"days":.string(info["catchup-days"] ?? "7")]) }
                        append(name:name,group:group,number:info["tvg-chno"] ?? "",logo:info["tvg-logo"] ?? "",tvg:info["tvg-id"] ?? "",tvgName:info["tvg-name"] ?? "",epg:rootEPG,catchup:catchup,urls:[line],headers:extra)
                    } else {
                        let parts = line.split(separator:",",maxSplits:1,omittingEmptySubsequences:false)
                        guard parts.count == 2 else { continue }
                        if parts[1].contains("#genre#") { group=String(parts[0]);continue }
                        append(name:String(parts[0]),group:group,urls:parts[1].components(separatedBy:"#"),headers:source.headers)
                    }
                }
            }
        }
        guard !result.isEmpty else { throw TVError.message("直播列表没有可播放频道；源可能已失效或依赖 Android 插件解析") }
        return result
    }
}
public struct LiveClient: Sendable {
    public var transport: any HTTPTransport
    public init(transport: any HTTPTransport = NetworkTransport()) { self.transport = transport }
    func fetch(_ address: String, headers: [String:String] = [:]) async throws -> Data {
        guard CatalogParser.validHTTP(address), let url = URL(string:address) else { throw TVError.message("直播列表需要 HTTP 或 HTTPS 地址；Android 本机代理地址不能直接移到 iPhone") }
        var request = URLRequest(url:url); request.allHTTPHeaderFields = headers
        let response = try await transport.send(request)
        guard (200..<300).contains(response.status) else { throw TVError.message("直播列表请求失败（HTTP \(response.status)）") }
        return response.body
    }
    public func sources(address: String) async throws -> [LiveSource] { try LiveParser.sources(await fetch(address),address:address) }
    public func channels(_ source: LiveSource) async throws -> [LiveChannel] {
        try LiveParser.channels(source.groups == .null ? await fetch(source.address,headers:source.headers) : Data(),source:source)
    }
}

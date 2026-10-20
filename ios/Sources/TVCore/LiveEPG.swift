import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import zlib

public struct LiveProgram: Identifiable, Hashable, Sendable {
    public var id: String { SyncDocument.identity(channelID,String(start.timeIntervalSince1970),title) }
    public var channelID: String, title: String, start: Date, end: Date
    public func isCurrent(_ now: Date = Date()) -> Bool { start <= now && now < end }
}
public enum LiveEPGParser {
    public static func unpack(_ data: Data) throws -> Data {
        guard data.starts(with:[0x1f,0x8b]) else { return data }
        var stream = z_stream()
        guard inflateInit2_(&stream,15+32,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw TVError.message("节目单解压初始化失败") }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating:input.bindMemory(to:Bytef.self).baseAddress)
            stream.avail_in = UInt32(input.count)
            var output = Data(), chunk = [UInt8](repeating:0,count:32*1024)
            while true {
                stream.avail_out = UInt32(chunk.count)
                let status = chunk.withUnsafeMutableBytes { bytes -> Int32 in
                    stream.next_out = bytes.bindMemory(to:Bytef.self).baseAddress
                    return inflate(&stream,Z_NO_FLUSH)
                }
                output.append(contentsOf:chunk.prefix(chunk.count-Int(stream.avail_out)))
                guard output.count <= 32*1024*1024 else { throw TVError.message("节目单解压后超过 32 MiB") }
                if status == Z_STREAM_END { return output }
                guard status == Z_OK else { throw TVError.message("节目单 GZip 文件损坏") }
            }
        }
    }
    static func date(_ value: String) -> Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX")
        for format in ["yyyyMMddHHmmss Z","yyyyMMddHHmmss","yyyy-MM-dd HH:mm:ss","yyyy-MM-dd'T'HH:mm:ssXXXXX"] {
            formatter.dateFormat = format
            if let date = formatter.date(from:value.trimmingCharacters(in:.whitespacesAndNewlines)) { return date }
        }
        return nil
    }
    public static func parse(_ data: Data, channel: LiveChannel, day: Date = Date()) throws -> [LiveProgram] {
        let body = try unpack(data)
        if String(decoding:body.prefix(100),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines).hasPrefix("<") {
            let delegate = EPGXMLDelegate(); let parser = XMLParser(data:body)
            parser.shouldResolveExternalEntities = false; parser.delegate = delegate
            guard parser.parse() else { throw TVError.message("XML 节目单格式无效") }
            var keys = Set([channel.tvgID,channel.tvgName,channel.name].filter { !$0.isEmpty })
            for (key,names) in delegate.names where !keys.isDisjoint(with:names) { keys.insert(key) }
            return delegate.programs.filter { keys.contains($0.channelID) }.sorted { $0.start < $1.start }
        }
        let json = try JSON.parse(body), rows = json["epg_data"].array.isEmpty ? json["list"].array : json["epg_data"].array
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let dayText = json["date"].string.isEmpty ? formatter.string(from:day) : json["date"].string
        var result: [LiveProgram] = []
        for row in rows {
            func time(_ field: String) -> Date? {
                if case .number(let number) = row[field], let seconds = Double(number) { return Date(timeIntervalSince1970:seconds > 1e12 ? seconds/1000 : seconds) }
                let raw = row[field].string
                return date(raw) ?? date(dayText+" "+raw+(raw.count == 5 ? ":00" : ""))
            }
            guard let start = time("start"), var end = time("end") else { continue }
            if end <= start { end = end.addingTimeInterval(86400) }
            let title = row["title"].string.isEmpty ? row["name"].string : row["title"].string
            if !title.isEmpty { result.append(.init(channelID:channel.tvgID.isEmpty ? channel.name : channel.tvgID,title:title,start:start,end:end)) }
        }
        return result.sorted { $0.start < $1.start }
    }
    public static func catchupURL(channel: LiveChannel, route: LiveRoute, program: LiveProgram, now: Date = Date()) throws -> String {
        let options = channel.catchup, type = options["type"].string, template = options["source"].string
        let days = Double(options["days"].string) ?? (options["days"].int > 0 ? Double(options["days"].int) : 7)
        guard !type.isEmpty, !template.isEmpty, program.end <= now, program.start >= now.addingTimeInterval(-max(0,days)*86400) else { throw TVError.message("此节目不在源提供的回看范围内") }
        let regex = try NSRegularExpression(pattern:#"\$?\{([^}]+)\}"#)
        var rendered = template
        let ns = template as NSString
        for match in regex.matches(in:template,range:NSRange(location:0,length:ns.length)).reversed() {
            let token = ns.substring(with:match.range(at:1)); var value: String
            if token == "utc" || token.hasPrefix("utc:") { value = String(Int(program.start.timeIntervalSince1970)) }
            else if token == "utcend" || token.hasPrefix("utcend:") { value = String(Int(program.end.timeIntervalSince1970)) }
            else if token == "duration" { value = String(Int(program.end.timeIntervalSince(program.start))) }
            else if token.hasPrefix("(b)") || token.hasPrefix("(e)") {
                let date = token.hasPrefix("(b)") ? program.start : program.end, format = String(token.dropFirst(3))
                if format == "timestamp" { value = String(Int(date.timeIntervalSince1970)) }
                else { let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX");formatter.dateFormat = format;value = formatter.string(from:date) }
            } else { throw TVError.message("此回看模板参数暂不支持") }
            guard let range = Range(match.range,in:rendered) else { continue }; rendered.replaceSubrange(range,with:value)
        }
        var address = route.url
        let replacement = options["replace"].string.split(separator:",",maxSplits:1,omittingEmptySubsequences:false)
        if replacement.count == 2 { address = address.replacingOccurrences(of:String(replacement[0]),with:String(replacement[1]),options:.regularExpression) }
        if type == "default" { address = LiveParser.resolve(rendered,base:address) }
        else { if address.contains("?"), rendered.hasPrefix("?") { rendered = "&"+rendered.dropFirst() }; address += rendered }
        guard LiveParser.playable(address) else { throw TVError.message("源没有返回有效的回看地址") }
        return address
    }
}
private final class EPGXMLDelegate: NSObject, XMLParserDelegate {
    var names: [String:Set<String>] = [:], programs: [LiveProgram] = []
    private var channel = "", attributes: [String:String] = [:], text = "", title = "", field = ""
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String:String]) {
        if name == "channel" { channel = attributes["id"] ?? "" }
        if name == "programme" { self.attributes = attributes; title = "" }
        if name == "display-name" || name == "title" { field = name; text = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if !field.isEmpty { text += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "display-name" { names[channel,default:[]].insert(text.trimmingCharacters(in:.whitespacesAndNewlines)); field = "" }
        if name == "title" { if title.isEmpty { title = text.trimmingCharacters(in:.whitespacesAndNewlines) }; field = "" }
        if name == "programme", let start = LiveEPGParser.date(attributes["start"] ?? ""), let end = LiveEPGParser.date(attributes["stop"] ?? ""), end > start, !title.isEmpty {
            programs.append(.init(channelID:attributes["channel"] ?? "",title:title,start:start,end:end))
        }
    }
}
public actor LiveEPGClient {
    public static let shared = LiveEPGClient()
    private var cache: [String:(Date,Data)] = [:]
    private let transport: any HTTPTransport
    public init(transport: any HTTPTransport = NetworkTransport()) { self.transport = transport }
    public func programs(channel: LiveChannel, day: Date = Date()) async throws -> [LiveProgram] {
        guard !channel.epg.isEmpty else { return [] }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier:"en_US_POSIX")
        var address = channel.epg.components(separatedBy:",").first ?? ""
        for (key,value) in [("{name}",channel.tvgName),("{id}",channel.tvgID),("{epg}",channel.tvgID),("{date}",formatter.string(from:day))] {
            address = address.replacingOccurrences(of:key,with:value.addingPercentEncoding(withAllowedCharacters:.alphanumerics) ?? "")
        }
        guard CatalogParser.validHTTP(address), let url = URL(string:address) else { return [] }
        let data: Data
        if let saved = cache[address], Date().timeIntervalSince(saved.0) < 6*3600 { data = saved.1 }
        else {
            let response = try await transport.send(URLRequest(url:url))
            guard (200..<300).contains(response.status) else { throw TVError.message("节目单读取失败（HTTP \(response.status)）") }
            data = response.body; cache[address] = (Date(),data)
            while cache.count > 24 || cache.values.reduce(0,{ $0+$1.1.count }) > 32*1024*1024 {
                guard let oldest=cache.min(by:{ $0.value.0 < $1.value.0 })?.key else { break };cache.removeValue(forKey:oldest)
            }
        }
        return try LiveEPGParser.parse(data,channel:channel,day:day)
    }
}

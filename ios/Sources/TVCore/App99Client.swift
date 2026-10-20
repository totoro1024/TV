// Adapted from jo32/tvbox-silicon, commit c28c27b98e2c18799a47b5db1527c2e59780cc96.
// Copyright (C) 2026 jo32 and Yingxia contributors. GPL-3.0-only.
import Foundation
import CommonCrypto
import CryptoKit
import Compression
import Security

public enum App99Crypto {
    private static let stream = Data(base64Encoded: "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")!
    private static let table: [Int] = [97, 96, 95, 94, 101, 100, 99, 98, 105, 104, 103, 102, 109, 108, 107, 106, 113, 112, 111, 110, 117, 116, 115, 114, 121, 120, 119, 118, 125, 124, 123, 122, 65, 64, 63, 62, 69, 68, 67, 66, 73, 72, 71, 70, 77, 76, 75, 74, 81, 80, 79, 78, 85, 84, 83, 82, 89, 88, 87, 86, 93, 92, 91, 90, 33, 32, 31, 30, 37, 36, 35, 34, 41, 40, 39, 38, 45, 44, 43, 42, 49, 48, 47, 46, 53, 52, 51, 50, 57, 56, 55, 54, 61, 60, 59, 58, 1, -1, -1, -1, 5, 4, 3, 2, 9, 8, 7, 6, 10, 12, 11, -1, 17, 16, 15, 14, 21, 20, 19, 18, 25, 24, 23, 22, 29, 28, 27, 26, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1]
    public static func configuration(_ ext: JSON) throws -> JSON {
        if case .object = ext { return ext }
        let text = ext.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "rfOX1voDIQhH8epBwtCFsuby/mmdmIu8kGlnJc+7VkMRLQ1K+jMy+KN1MKQe0MZ6tmGSO5oFzD8/vWwiSqEpFczDqLrdGT3iH6fZmryrFzKijwYkJUMctdztE0O4CsgYZdBu8XhZSwuhSqqllQz4AZMa1l0sT+1NrbhNIxHkrY0upiYSTLNqEaledgZikMCviOXWr3cPBP4COOeoGUyJSJrrybmUppnWGeDAOHhHOVUSXjwSb+QQvcJIT2lmrf1Bk68myGs7qOqc19tD/rnzf2WOb2MzJZqtURBmUFgaW6ea2dL8OPSpSeVAvaGCAnqwuUNGE9hHpK8jfOs0bLJRdkFLnijAn5Q+ofVM5hgGb8c=" { return try JSON.parse(Data("{\"host\":\"http://124.221.3.182:19987/app/bn\",\"appkey\":\"d1f0c269eab74d93821fffc9befdbbba\",\"versionName\":\"1.2.0\",\"name\":\"剧圈圈\",\"package\":\"com.qingtangxiaozhuan.xyz\",\"buildNumber\":\"2002\",\"buildSignature\":\"054FA8DDA4319C6B6A9B954CA5777541C993F00B1B0BD4394F7EDE48184C4594\"}".utf8)) }
        if text.hasPrefix("{") { return try JSON.parse(Data(text.utf8)) }
        return try JSON.parse(Data(decodePluginText(text).utf8))
    }
    /// 仅在内存解码同步来的插件字符串；不记录或缓存明文。
    public static func decodePluginText(_ text: String) throws -> String {
        guard text.count <= 512 * 1024, let bytes = Data(base64Encoded: text), bytes.count <= stream.count else { throw TVError.message("插件配置编码暂不支持") }
        let shifted = Data(bytes.enumerated().map { index, byte in byte ^ stream[index] ^ 99 })
        guard let text = String(data: shifted, encoding: .utf8) else { throw TVError.message("插件配置不是有效文本") }
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            guard scalar.value >= 2, let original = UnicodeScalar(scalar.value - 2) else { throw TVError.message("插件配置字符编码无效") }
            result.append(original)
        }
        return String(result)
    }
    /// 与 Android 网盘插件相同的兼容编码，不是保密加密。
    public static func encodePluginText(_ text: String) throws -> String {
        var shifted = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            guard let value = UnicodeScalar(scalar.value + 2) else { throw TVError.message("网盘配置字符编码无效") }
            shifted.append(value)
        }
        let bytes = Data(String(shifted).utf8)
        guard bytes.count <= stream.count else { throw TVError.message("登录信息超过插件支持长度") }
        return Data(bytes.enumerated().map { $0.element ^ stream[$0.offset] ^ 99 }).base64EncodedString()
    }
    public static func aes(_ input: Data, key: Data, iv: Data, encrypt: Bool) throws -> Data {
        guard key.count == 32, iv.count == 16, encrypt || (!input.isEmpty && input.count % 16 == 0) else { throw TVError.message("视界加密参数无效") }
        var output = Data(count: input.count + 16), written = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { data in key.withUnsafeBytes { key in iv.withUnsafeBytes { iv in
                CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), key.baseAddress, 32, iv.baseAddress, data.baseAddress, input.count, out.baseAddress, capacity, &written)
            } } }
        }
        guard status == kCCSuccess else { throw TVError.message("视界数据解密失败") }
        output.count = written; return output
    }
    static func random(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw TVError.message("无法生成请求随机数") }; return data
    }
    static func inflate(_ input: Data) throws -> Data {
        guard input.count > 2 else { throw TVError.message("视界压缩数据无效") }
        let source = input.dropFirst(2)
        var capacity = 65536
        while capacity <= 8 * 1024 * 1024 {
            var output = Data(count: capacity)
            let size = output.withUnsafeMutableBytes { out in source.withUnsafeBytes { src in
                compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, capacity, src.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, COMPRESSION_ZLIB)
            } }
            if size > 0 && size < capacity { output.count = size; return output }
            capacity *= 2
        }
        throw TVError.message("视界解压失败或数据过大")
    }
}

public struct ResolvedMedia: Sendable {
    public var url: String
    public var headers: [String: String]
    public var byteOffset: Int64
    public var size: Int64
    public var qualityID = "auto"
    public var qualities: [StreamQuality] = []
    public var hmysSigning: HmysSigning?
    public var useVLC: Bool
    public init(url: String, headers: [String: String] = [:], byteOffset: Int64 = 0, size: Int64 = 0, useVLC: Bool = false) {
        self.url = url; self.headers = headers; self.byteOffset = byteOffset; self.size = size; self.useVLC = useVLC
    }
}
public actor App99Client {
    public static let shared = App99Client()
    private struct Session { let config: JSON, uuid: String, players: JSON, parsers: [JSON] }
    private var sessions: [String: Session] = [:]
    private let transport: any HTTPTransport
    public init(transport: any HTTPTransport = NetworkTransport()) { self.transport = transport }
    private func request(_ config: JSON, uuid: String, path: String, parameters: [String: JSON]) async throws -> JSON {
        let host = config["host"].string.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard CatalogParser.validHTTP(host), let url = URL(string: host + path) else { throw TVError.message("视界接口地址无效") }
        let nonce = try App99Crypto.random(16).base64EncodedString(), timestamp = String(SyncDocument.now)
        var params = parameters; params["nonce"] = .string(nonce); params["timestamp"] = .string(timestamp); params["token"] = .string(config["token"].string)
        let key = Data(uuid.replacingOccurrences(of: "-", with: "").utf8), iv = try App99Crypto.random(16)
        let encrypted = try App99Crypto.aes(JSON.object(params).data, key: key, iv: iv, encrypt: true)
        let body = (iv + encrypted).base64EncodedString()
        let signing = "\(body):\(timestamp):\(nonce):\(config["token"].string):\(config["appkey"].string)"
        let sign = SHA256.hash(data: Data(signing.utf8)).map { String(format: "%02x", $0) }.joined()
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.httpBody = Data(body.utf8)
        req.allHTTPHeaderFields = ["Accept":"application/json", "Content-Type":"application/json", "client_type":"android", "User-Agent":"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.6299.95 Safari/537.36", "uuid":uuid, "timestamp":timestamp, "nonce":nonce, "sign":sign, "appkey":config["appkey"].string, "version":config["version"].string.isEmpty ? "0b4328287a5d953e" : config["version"].string, "api_version":"v1"]
        let reply = try await transport.send(req)
        guard (200..<300).contains(reply.status) else { throw TVError.message("视界接口返回 HTTP \(reply.status)") }
        guard let encoded = String(data: reply.body, encoding: .utf8), let bytes = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)), bytes.count >= 32 else { throw TVError.message("视界接口返回无效的加密数据") }
        let plain = try App99Crypto.aes(Data(bytes.dropFirst(16)), key: key, iv: Data(bytes.prefix(16)), encrypt: false)
        if let json = try? JSON.parse(plain) { return json }
        return try JSON.parse(App99Crypto.inflate(plain))
    }
    private func session(_ source: MediaSource) async throws -> Session {
        let identity = source.sourceID + ":" + source.id + ":" + source.ext.text
        if let cached = sessions[identity] { return cached }
        let config = try App99Crypto.configuration(source.ext)
        let deviceKey = "ios.app99.uuid." + SyncDocument.identity(source.sourceID, source.id)
        let uuid = config["uuid"].string.isEmpty ? (UserDefaults.standard.string(forKey: deviceKey) ?? UUID().uuidString.lowercased()) : config["uuid"].string
        UserDefaults.standard.set(uuid, forKey: deviceKey)
        let initialized = try await request(config, uuid: uuid, path: "/app/systemInit", parameters: ["s":config["buildSignature"],"apiVersion":.string("v2"),"v":config["versionName"],"pl":.string("1"),"n":config["name"]])
        _ = try await request(config, uuid: uuid, path: config["LoginPath"].string.isEmpty ? "/app/userInfo" : config["LoginPath"].string, parameters: ["package":config["package"],"appName":config["name"],"appkey":config["appkey"],"buildSignature":config["buildSignature"],"buildNumber":config["buildNumber"],"uuid":.string(uuid),"version":config["versionName"]])
        let session = Session(config: config, uuid: uuid, players: initialized["player"], parsers: initialized["parser_api"].array)
        sessions[identity] = session; return session
    }
    public func browse(_ source: MediaSource, keyword: String, page: Int) async throws -> [MediaItem] {
        let s = try await session(source)
        var parameters: [String:JSON] = ["limit":.integer(21), "page":.string(String(page)), "kw":.string(keyword)]
        if keyword.isEmpty { parameters["isCategory"] = .integer(1); parameters["orderBy"] = .string("time"); parameters["pid"] = .string("0") }
        else { parameters["orderBy"] = .string("vod_hits_month"); parameters["sort"] = .string("desc") }
        let data = try await request(s.config, uuid: s.uuid, path: "/vod/search", parameters: parameters)
        return data["data"].array.map { row in MediaItem(id: Self.identifier(row["id"]), name: row["name"].string, picture: row["pic"].string, remarks: row["remarks"].string) }
    }
    static func identifier(_ value: JSON) -> String { if case .number(let n) = value { return n }; return value.string }
    public func detail(_ source: MediaSource, id: String) async throws -> MediaDetail {
        let s = try await session(source)
        let data = try await request(s.config, uuid: s.uuid, path: "/vod/detail", parameters: ["v":.string("2.0.0"),"eps":.string("1"),"id":.string(id),"pl":.integer(1)])
        let v = data["data"]; guard v != .null else { throw TVError.message("视界未返回影片详情") }
        let codes = v["play_from"].string.components(separatedBy: "$$$"), groups = v["play_url"].string.components(separatedBy: "$$$")
        let blocked = Set(v["un_player"].array.map(Self.identifier))
        var episodes: [Episode] = []
        for (index, code) in codes.enumerated() where index < groups.count && !blocked.contains(code) {
            let line = s.players[code]["name"].string.isEmpty ? code : s.players[code]["name"].string
            for part in groups[index].components(separatedBy: "#") {
                guard let dollar = part.firstIndex(of: "$") else { continue }
                let name = String(part[..<dollar]), url = String(part[part.index(after: dollar)...])
                episodes.append(Episode(name: name, url: url + "@" + code + "@" + v["name"].string + "@" + name, line: line))
            }
        }
        return MediaDetail(item: MediaItem(id: Self.identifier(v["id"]), name: v["name"].string, picture: v["pic"].string), episodes: episodes, synopsis: v["content"].string.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression), metadata: ["年份":Self.identifier(v["year"]),"地区":v["area"].string,"类型":v["class"].string,"导演":v["director"].string,"演员":v["actor"].string].filter { !$0.value.isEmpty })
    }
    public func resolve(_ source: MediaSource, episode: Episode) async throws -> ResolvedMedia {
        let s = try await session(source), parts = episode.url.components(separatedBy: "@")
        let code = parts.count >= 4 ? parts[parts.count - 3] : ""
        var url = parts.count >= 4 ? parts.dropLast(3).joined(separator: "@") : episode.url
        let player = s.players[code]
        var headers: [String:String] = [:]
        if let json = try? JSON.parse(Data(player["headers"].string.utf8)) { for (k,v) in json.object { headers[k] = v.string } }
        let media = URL(string: url).map { ["m3u8","mp4","mov","m4v"].contains($0.pathExtension.lowercased()) } ?? false
        if !media {
            guard let parser = s.parsers.first(where: { Self.identifier($0["id"]) == Self.identifier(player["parseUrl"]) }), parser["api_type"].string == "json",
                  let escaped = url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { throw TVError.message("此线路需要网页解析，请选择其他兼容线路") }
            let body = try await CatalogClient(transport: transport).fetch(parser["api_url"].string + escaped)
            let result = try JSON.parse(body); let field = parser["idx_play_url"].string
            url = result[field.isEmpty ? "url" : field].string
        }
        guard CatalogParser.playable(url) else { throw TVError.message("视界未返回可播放直链") }
        return ResolvedMedia(url: url, headers: headers)
    }
}

import Foundation
import CryptoKit

/// 复用两种网盘的目录与转存协议，账号、主机和播放线路按网盘隔离。
public enum CloudDrive: String, Sendable {
    case quark, uc
    public var name: String { self == .uc ? "UC" : "夸克" }
    public var shareHost: String { self == .uc ? "drive.uc.cn" : "pan.quark.cn" }
    var apiHost: String { self == .uc ? "pc-api.uc.cn" : "drive-pc.quark.cn" }
    public static func episode(_ encoded: String) -> CloudDrive {
        let payload = try? JSON.parse(Data(encoded.utf8))
        return payload?["cloudDrive"].string == "uc" || payload?["flag"].string.hasPrefix("优汐") == true ? .uc : .quark
    }
}

public actor QuarkClient {
    public private(set) var cookie: String
    public let drive: CloudDrive
    public var transport: any HTTPTransport
    public init(cookie: String, transport: any HTTPTransport = NetworkTransport(), drive: CloudDrive = .quark) { self.cookie = cookie; self.transport = transport; self.drive = drive }
    private func call(_ path: String, query: [String:String] = [:], body: JSON? = nil, userAgent: String? = nil) async throws -> JSON {
        guard !cookie.isEmpty else { throw TVError.message("请先从 WebDAV 同步\(drive.name)登录 Cookie") }
        var components = URLComponents(string: "https://" + drive.apiHost + "/1/clouddrive/" + path)!
        components.queryItems = (["pr":drive == .uc ? "UCBrowser" : "ucpro","fr":"pc","uc_param_str":""].merging(query) { _, new in new }).sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLQueryItem 默认保留 +，但夸克按表单规则解码，授权中的 + 必须转义。
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!); request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body?.data
        request.allHTTPHeaderFields = ["Cookie":cookie,"Referer":drive == .uc && path == "file/download" ? "https://pc-api.uc.cn/" : "https://" + drive.shareHost + "/","User-Agent":userAgent ?? Self.userAgent,"Content-Type":"application/json"]
        let response = try await transport.send(request)
        if let raw = response.headers.first(where: { $0.key.lowercased() == "set-cookie" })?.value {
            let updates = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie":raw], for: request.url!)
            for update in updates where ["__pus", "__puus"].contains(update.name) {
                var pairs = cookie.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.hasPrefix(update.name + "=") && !$0.isEmpty }
                pairs.append(update.name + "=" + update.value); cookie = pairs.joined(separator: "; ")
            }
        }
        guard response.status == 200 else {
            let code = (try? JSON.parse(response.body))?["code"].int ?? 0
            throw TVError.message("\(drive.name) \(path) 返回 HTTP \(response.status)（\(code)）")
        }
        let json = try JSON.parse(response.body)
        guard json["code"].int == 0 && json["status"].int == 200 else { throw TVError.message("\(drive.name) \(path) 请求未通过（\(json["code"].int)），请检查分享有效期或访问权限") }
        return json
    }
    public static let downloadUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.56 Chrome/100.0.4896.160 Electron/18.3.5.12-a038f7b798 Safari/537.36 Channel/pckk_other_ch"
    public static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
    public func validateAccount() async throws {
        guard drive == .quark else { throw TVError.message("UC 登录状态以分享目录及播放请求为准") }
        var request = URLRequest(url: URL(string: "https://pan.quark.cn/account/info?fr=pc&platform=pc")!)
        request.allHTTPHeaderFields = ["Cookie":cookie,"Referer":"https://" + drive.shareHost + "/","User-Agent":Self.userAgent]
        let reply = try await transport.send(request)
        guard reply.status == 200 else { throw TVError.message("无法验证\(drive.name)账号，请重试") }
        let json = try JSON.parse(reply.body)
        guard json["data"]["nickname"].string.count > 0 || json["data"]["uid"].string.count > 0 else { throw TVError.message("\(drive.name)尚未登录，请在登录页面完成授权") }
    }
    public static func shareID(_ url: String, drive: CloudDrive = .quark) throws -> String {
        guard let parts = URLComponents(string: url), parts.scheme == "https", parts.host == drive.shareHost else { throw TVError.message("不是有效的\(drive.name)分享链接") }
        let path = parts.path.split(separator: "/")
        guard path.count == 2, path[0] == "s", path[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw TVError.message("\(drive.name)分享链接格式无效") }
        return String(path[1])
    }
    public func shareToken(id: String, passcode: String = "") async throws -> String {
        let result = try await call("share/sharepage/token", body: .object(["pwd_id":.string(id),"passcode":.string(passcode)]))
        let token = result["data"]["stoken"].string
        guard !token.isEmpty else { throw TVError.message("未获取到\(drive.name)分享授权") }; return token
    }
    public func files(id: String, token: String, parent: String = "0", page: Int = 1) async throws -> [JSON] {
        let result = try await call("share/sharepage/detail", query: ["pwd_id":id,"stoken":token,"pdir_fid":parent,"force":"0","_page":String(page),"_size":"50","_fetch_total":"1","_sort":"file_type:asc,updated_at:desc","ver":"2"])
        guard case .array(let list) = result["data"]["list"] else { throw TVError.message("\(drive.name)未返回目录数据") }; return list
    }

    /// 将分享目录展开为与 Android 历史字段兼容的播放条目；Cookie 仅发送夸克接口。
    public func episodes(shareURL: String, line: String, movieName: String) async throws -> [Episode] {
        let share = try Self.shareID(shareURL, drive: drive)
        let query = URLComponents(string: shareURL)?.queryItems ?? []
        let passcode = query.first { ["pwd", "passcode", "password"].contains($0.name) }?.value ?? ""
        let token = try await shareToken(id: share, passcode: passcode)
        var pending: [(String, String, Int)] = [("0", "", 0)], seen = Set<String>(), result: [Episode] = [], entries = 0
        while !pending.isEmpty {
            try Task.checkCancellation()
            let (parent, prefix, depth) = pending.removeFirst()
            guard seen.insert(parent).inserted else { continue }
            guard depth <= 10 else { throw TVError.message("\(drive.name)分享目录层级过深") }
            for page in 1...100 {
                let rows = try await files(id: share, token: token, parent: parent, page: page)
                entries += rows.count
                guard entries <= 10000 else { throw TVError.message("\(drive.name)分享条目过多，请选择较小的分享线路") }
                for row in rows {
                    let name = row["file_name"].string, fid = row["fid"].string
                    guard !fid.isEmpty else { continue }
                    if row["dir"].flag {
                        pending.append((fid, prefix + name + " / ", depth + 1)); continue
                    }
                    let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
                    guard ["mp4", "mkv", "mov", "m4v", "avi", "ts", "m2ts", "flv", "webm", "rmvb"].contains(ext), !row["share_fid_token"].string.isEmpty else { continue }
                    var payload = row
                    payload["sId"] = .string(share); payload["sToken"] = .string(token)
                    payload["pdir_fid"] = .string(parent); payload["parent"] = .string(parent)
                    payload["pg"] = .integer(Int64(page)); payload["vodName"] = .string(movieName)
                    payload["cloudDrive"] = .string(drive.rawValue)
                    payload["flag"] = .string(drive == .uc ? "优汐盘" : "夸父盘"); payload["sub"] = .string("")
                    if !passcode.isEmpty { payload["passcode"] = .string(passcode) }
                    result.append(Episode(name: prefix + name, url: payload.text, line: line))
                }
                if rows.count < 50 { break }
                if page == 100 { throw TVError.message("\(drive.name)目录分页超过限制，未返回不完整选集") }
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 原始玩偶历史是 JSON，Token 内可能含 +，不能按分隔符拆分。
    public func resolveHistory(_ encoded: String, preferOriginal: Bool = false, resolution: String? = nil) async throws -> ResolvedMedia {
        let file = try JSON.parse(Data(encoded.utf8))
        let share = file["sId"].string, original = file["fid"].string
        guard !share.isEmpty, !original.isEmpty, share.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw TVError.message("玩偶历史缺少\(drive.name)文件标识")
        }
        let token = try await shareToken(id: share, passcode: file["passcode"].string)
        let parent = file["pdir_fid"].string.isEmpty ? "0" : file["pdir_fid"].string
        var matched: JSON?
        for page in 1...100 {
            let list = try await files(id: share, token: token, parent: parent, page: page)
            if let found = list.first(where: { $0["fid"].string == original }) { matched = found; break }
            if list.count < 50 { break }
        }
        guard let matched, !matched["share_fid_token"].string.isEmpty else { throw TVError.message("原分享中未找到历史文件，可能已失效或移动") }
        let root = try await folder(name: "影视同步-iPhone", parent: "0")
        let key = SHA256.hash(data: Data((share + ":" + original).utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = try await folder(name: key, parent: root)
        let own = try await ownFiles(parent: directory)
        let name = matched["file_name"].string
        let saved: String
        if let existing = own.first(where: { $0["file_name"].string == name && $0["size"] == matched["size"] && !$0["dir"].flag }) {
            saved = existing["fid"].string
        } else {
            let result = try await call("share/sharepage/save", body: .object([
                "fid_list":.array([.string(original)]), "fid_token_list":.array([matched["share_fid_token"]]),
                "to_pdir_fid":.string(directory), "pwd_id":.string(share), "stoken":.string(token),
                "pdir_fid":.string(parent), "scene":.string("link")]))
            let task = result["data"]["task_id"].string
            guard !task.isEmpty else { throw TVError.message("\(drive.name)转存未返回任务标识") }
            var fid = ""
            for index in 0..<30 {
                try Task.checkCancellation()
                let result = try await call("task", query: ["task_id":task,"retry_index":String(index)])
                if result["data"]["status"].int == 2 {
                    fid = result["data"]["save_as"]["save_as_top_fids"].array.first?.string ?? ""; break
                }
                try await Task.sleep(for: .seconds(1))
            }
            guard !fid.isEmpty else { throw TVError.message("\(drive.name)转存尚未完成，请稍后重试") }
            saved = fid
        }
        guard !saved.isEmpty else { throw TVError.message("\(drive.name)文件标识无效") }
        let wrapped = matched["format_type"].string.hasPrefix("image/")
        if drive == .uc {
            guard resolution == nil || resolution == "original" else { throw TVError.message("UC 当前仅提供原画播放") }
            var media = try await originalMedia(saved: saved, matched: matched)
            media.qualityID = "original"; media.qualities = [.original]
            return media
        }
        if wrapped || resolution == "original" || (preferOriginal && resolution == nil) {
            if wrapped, let resolution, resolution != "original" { throw TVError.message("此文件仅提供原画，无法选择转码清晰度") }
            var media = try await originalMedia(saved: saved, matched: matched)
            media.qualityID = "original"; media.qualities = [.original]
            if !wrapped, let response = try? await playbackOptions(saved) {
                media.qualities += StreamQuality.quark(response["data"]["video_list"].array)
            }
            return media
        }
        for attempt in 0..<12 {
            try Task.checkCancellation()
            let response = try await playbackOptions(saved)
            let options = response["data"]["video_list"].array
            let order = ["super", "high", "normal", "low", "2k", "4k"]
            let sorted = options.sorted { (order.firstIndex(of: $0["resolution"].string) ?? 99) < (order.firstIndex(of: $1["resolution"].string) ?? 99) }
            if let playable = sorted.first(where: { CatalogParser.validHTTP($0["video_info"]["url"].string) && (resolution == nil || $0["resolution"].string == resolution) }) {
                let url = playable["video_info"]["url"].string
                // 播放器只接收签名媒体地址与通用头，不向第三方 CDN 转发账号 Cookie。
                let headers = ["Referer":"https://" + drive.shareHost + "/", "User-Agent":Self.userAgent]
                var probe = URLRequest(url: URL(string: url)!)
                probe.allHTTPHeaderFields = headers
                let response = try await transport.send(probe)
                if [403, 412].contains(response.status) {
                    if resolution != nil { throw TVError.message("所选清晰度被\(drive.name)服务器拒绝（HTTP \(response.status)），已保留当前播放，请使用原画") }
                    var media = try await originalMedia(saved: saved, matched: matched)
                    media.qualityID = "original"; media.qualities = [.original] + StreamQuality.quark(options)
                    return media
                }
                guard response.status == 200, String(data: response.body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") == true else {
                    throw TVError.message("\(drive.name)转码播放列表无效，请切换夸父原线路")
                }
                var media = ResolvedMedia(url: url, headers: headers)
                media.qualityID = playable["resolution"].string; media.qualities = [.original] + StreamQuality.quark(options)
                return media
            }
            if resolution != nil { throw TVError.message("此源尚未提供所选清晰度，请选择其他档位") }
            if attempt < 11 { try await Task.sleep(for: .seconds(2)) }
        }
        throw TVError.message("\(drive.name)尚未生成兼容播放流，请稍后重试")
    }
    private func playbackOptions(_ saved: String) async throws -> JSON {
        try await call("file/v2/play", body: .object(["fid":.string(saved),"resolutions":.string("normal,low,high,super,2k,4k"),"supports":.string("fmp4,m3u8")]))
    }
    private func ownFiles(parent: String) async throws -> [JSON] {
        var all: [JSON] = []
        for page in 1...100 {
            let result = try await call("file/sort", query: ["pdir_fid":parent,"_page":String(page),"_size":"100","_sort":"file_type:asc,file_name:asc"])
            guard case .array(let list) = result["data"]["list"] else { throw TVError.message("\(drive.name)个人目录读取失败") }
            all += list
            if list.count < 100 { return all }
        }
        throw TVError.message("\(drive.name)目录条目过多，未执行转存")
    }
    private func folder(name: String, parent: String) async throws -> String {
        if let existing = try await ownFiles(parent: parent).first(where: { $0["file_name"].string == name && $0["dir"].flag }) { return existing["fid"].string }
        let result = try await call("file", body: .object(["pdir_fid":.string(parent),"file_name":.string(name),"dir_path":.string(""),"dir_init_lock":.bool(false)]))
        let fid = result["data"]["fid"].string
        guard !fid.isEmpty else { throw TVError.message("无法创建 iPhone 播放目录") }
        return fid
    }
    private var downloadAgent: String {
        drive == .uc ? "Mozilla/5.0 (Linux; U; Android 12; zh-CN; V2055A Build/SP1A.210812.003) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/100.0.4896.58 UCBrowser/17.3.8.1369 Mobile Safari/537.36" : Self.downloadUserAgent
    }
    private func originalMedia(saved: String, matched: JSON) async throws -> ResolvedMedia {
        let response = try await call("file/download", body: .object(["fids":.array([.string(saved)])]), userAgent: downloadAgent)
        let url = response["data"].array.first?["download_url"].string ?? ""
        guard CatalogParser.validHTTP(url) else { throw TVError.message("\(drive.name)未返回原画地址") }
        var headers = ["Referer":"https://" + drive.shareHost + "/", "User-Agent":downloadAgent]
        if let host = URL(string: url)?.host, host == drive.shareHost || (drive == .quark && host.hasSuffix(".quark.cn")) || (drive == .uc && host.hasSuffix(".uc.cn")) { headers["Cookie"] = cookie }
        var probe = URLRequest(url: URL(string: url)!)
        probe.allHTTPHeaderFields = headers; probe.setValue("bytes=0-31", forHTTPHeaderField: "Range")
        let head = try await transport.send(probe)
        let wrapped = matched["format_type"].string.hasPrefix("image/")
        if drive == .uc, head.status == 206 {
            let range = head.headers.first(where: { $0.key.lowercased() == "content-range" })?.value ?? ""
            let total = range.split(separator: "/").last.flatMap { Int64($0) }
            guard let total, total == matched["size"].int else {
                throw TVError.message("UC 未返回原文件，可能需要 UC 会员或在 UC 浏览器内播放。请切换其他网盘线路。")
            }
        }
        guard head.status == 206, head.body.count >= 12, !wrapped || head.body.starts(with: Data([137,80,78,71,13,10,26,10,0x1a,0x45,0xdf,0xa3])) else {
            throw TVError.message("原画封装格式暂不支持，未按错误偏移播放")
        }
        return ResolvedMedia(url: url, headers: headers, byteOffset: wrapped ? 8 : 0, size: matched["size"].int, useVLC: true)
    }

}

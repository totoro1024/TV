import Foundation
import CryptoKit

public struct SyncDocument: Equatable, Sendable {
    public var raw: JSON
    public private(set) var usesLegacyAndroidLayout = false
    public static func == (lhs: SyncDocument, rhs: SyncDocument) -> Bool { lhs.raw == rhs.raw }
    public init() { raw = .object(["schema": .integer(1), "epoch": .string(UUID().uuidString.lowercased()), "mode": .string("merge"), "reset": .string(""), "records": .object([:])]) }
    public init(data: Data) throws {
        let parsed = try JSON.parse(data)
        if let migrated = try LegacyAndroidSync.decode(parsed) { raw = migrated; usesLegacyAndroidLayout = true }
        else { raw = parsed }
        try validate()
    }
    public func wireData(preservingLegacyAndroidLayout legacy: Bool = false) throws -> Data {
        try validate()
        return legacy ? try LegacyAndroidSync.encode(raw) : raw.data
    }
    public var epoch: String { get { raw["epoch"].string } set { raw["epoch"] = .string(newValue) } }
    public var mode: String { get { raw["mode"].string } set { raw["mode"] = .string(newValue) } }
    public var reset: String { get { raw["reset"].string } set { raw["reset"] = .string(newValue) } }
    public var records: [String: JSON] { get { raw["records"].object } set { raw["records"] = .object(newValue) } }
    public static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    public static func identity(_ parts: String...) -> String { identity(parts) }
    public static func identity(_ parts: [String]) -> String {
        var data = Data()
        for part in parts {
            let b = Data(part.utf8); var count = UInt32(b.count).bigEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }; data.append(b)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public func validate() throws {
        guard raw["schema"].int == 1, !epoch.isEmpty, ["merge","replace","reset"].contains(mode),
              case .string = raw["reset"], case .object = raw["records"], records.count <= 30_000,
              mode != "reset" || records.isEmpty else { throw TVError.message("同步文件版本或格式无效") }
        for (key, e) in records {
            guard key.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  !e["kind"].string.isEmpty, !e["device"].string.isEmpty,
                  case .number(let modified) = e["modified"], let timestamp = Int64(modified), timestamp >= 0,
                  timestamp <= Self.now + 86_400_000, case .number(let sequence) = e["sequence"], Int64(sequence) != nil,
                  case .bool = e["deleted"], e["deleted"].flag || e["value"] != .null else { throw TVError.message("同步记录无效或设备时间相差过大") }
            if !e["deleted"].flag { try validateKnown(key: key, entry: e) }
        }
    }
    private func validateKnown(key: String, entry: JSON) throws {
        let v = entry["value"]
        func text(_ name: String) throws -> String {
            guard case .string(let value) = v[name] else { throw TVError.message("同步记录缺少文字字段") }; return value
        }
        func number(_ name: String) throws -> Int64 {
            guard case .number(let raw) = v[name], let value = Int64(raw) else { throw TVError.message("同步记录数字字段无效") }; return value
        }
        func source(_ id: String) throws {
            guard let row = records[id], row["kind"].string == "source" else { throw TVError.message("同步记录引用的源不存在") }
        }
        var expected: String?
        switch entry["kind"].string {
        case "source":
            let type = try number("type"), url = try text("url")
            guard [0,1].contains(type), !url.isEmpty else { throw TVError.message("源记录无效") }
            _ = try text("name"); _ = try text("home")
            expected = Self.identity("source", String(type), url)
        case "history", EpisodeProgress.kind:
            let parent = try text("source"); try source(parent)
            for field in ["name","picture","line","episode","episodeUrl"] { _ = try text(field) }
            for field in ["watchedAt","positionMs","durationMs","openingMs","endingMs"] { _ = try number(field) }
            for field in ["reverseSort","reversePlay"] { guard case .bool = v[field] else { throw TVError.message("观看偏好字段无效") } }
            expected = entry["kind"].string == EpisodeProgress.kind ? EpisodeProgress.id(v) : try Self.identity("history", parent, text("site"), text("vod"))
        case "favorite":
            let type = try number("type")
            for field in ["name","picture","siteName"] { _ = try text(field) }; _ = try number("addedAt")
            if type == 0 {
                let parent = try text("source"); try source(parent)
                expected = try Self.identity("favorite", "vod", parent, text("site"), text("vod"))
            } else if type == 1 { expected = try Self.identity("favorite", "live", text("channel")) }
            else { throw TVError.message("收藏类型无效") }
        case "site":
            let searchable = try number("searchable")
            guard [0,1,2].contains(searchable) else { throw TVError.message("站点搜索偏好无效") }
            expected = try Self.identity("site", text("site"))
        case "preference":
            let type = try number("type"), name = try text("name")
            guard [0,1].contains(type), name == "activeSource\(type)" else { throw TVError.message("源偏好无效") }
            _ = try text("url"); expected = Self.identity("preference", name)
        default: break // iOS 不支持的插件配置按原始 JSON 保留。
        }
        if let expected, key != expected { throw TVError.message("同步记录标识与字段不一致") }
    }
    public func merged(with remote: SyncDocument) throws -> SyncDocument {
        guard epoch == remote.epoch else { throw TVError.message("同步代次不同") }
        var result = remote
        for (key, e) in records {
            if let old = result.records[key], !Self.newer(e, than: old) { continue }
            result.records[key] = e
        }
        return result
    }
    static func newer(_ a: JSON, than b: JSON) -> Bool {
        if a["modified"].int != b["modified"].int { return a["modified"].int > b["modified"].int }
        if a["device"].string != b["device"].string { return JSON.javaLess(b["device"].string, a["device"].string) }
        if a["sequence"].int != b["sequence"].int { return a["sequence"].int > b["sequence"].int }
        if a["deleted"].flag != b["deleted"].flag { return a["deleted"].flag }
        return JSON.javaLess(b["value"].text, a["value"].text)
    }
}
public struct Replica: Sendable {
    public var document = SyncDocument()
    public var acknowledgedEpoch = "", acceptedReset = ""
    public var clock: Int64 = 0
    public var paused = false
    public var localRevision: Int64 = 0, uploadedRevision: Int64 = -1
    public var retryNeeded = false
    public var pendingUpload: Bool { localRevision > uploadedRevision }
    public mutating func acknowledge(_ revision: Int64) {
        uploadedRevision = max(uploadedRevision, min(revision, localRevision)); retryNeeded = false
    }
    public func deliveryText(syncing: Bool, configured: Bool, automatic: Bool, deferred: Bool) -> String {
        if !configured { return "未配置" }
        if syncing { return "同步中…" }
        if paused { return "同步已暂停" }
        if retryNeeded { return automatic ? "同步失败，等待重试" : "同步失败，等待手动重试" }
        if pendingUpload { return automatic ? "待同步" : "待同步（自动同步已关闭）" }
        return deferred ? "已同步，云端进度将在退出播放后应用" : "已同步"
    }
    public init() {}
    public init(json: JSON) throws {
        self.init()
        if json == .null { return }
        document = try SyncDocument(data: json["document"].data)
        acknowledgedEpoch = json["acknowledgedEpoch"].string; acceptedReset = json["acceptedReset"].string
        clock = json["clock"].int; paused = json["paused"].flag
        localRevision = json["localRevision"].int
        uploadedRevision = json["uploadedRevision"] == .null ? -1 : json["uploadedRevision"].int
        retryNeeded = json["retryNeeded"].flag
    }
    public var json: JSON { .object(["document": document.raw, "acknowledgedEpoch": .string(acknowledgedEpoch), "acceptedReset": .string(acceptedReset), "clock": .integer(clock), "paused": .bool(paused), "localRevision": .integer(localRevision), "uploadedRevision": .integer(uploadedRevision), "retryNeeded": .bool(retryNeeded)]) }
    public mutating func edit(id: String, kind: String, value: JSON?, device: String, now: Int64 = SyncDocument.now) {
        clock = max(clock + 1, now)
        var e = document.records[id] ?? .object([:])
        e["kind"] = .string(kind); e["modified"] = .integer(now); e["sequence"] = .integer(clock)
        e["device"] = .string(device); e["deleted"] = .bool(value == nil)
        e["value"] = value ?? .null
        document.records[id] = e
        localRevision += 1
    }
    public mutating func applyDeferred(_ doc: SyncDocument) throws {
        var current = document; current.epoch = doc.epoch
        receive(try current.merged(with: doc))
    }
    public mutating func receive(_ doc: SyncDocument) {
        document = doc; acknowledgedEpoch = doc.epoch
        clock = max(clock, doc.records.values.map { $0["modified"].int }.max() ?? 0)
    }
}

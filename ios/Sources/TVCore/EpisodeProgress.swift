import Foundation

/// 与 Android 共用身份规则；签名地址、分享令牌和线路别名不影响夸克文件身份。
public enum EpisodeProgress {
    public static let kind = "episodeProgress"
    public static func key(line: String, episode: String, url: String) -> String {
        if let file = try? JSON.parse(Data(url.utf8)), !file["sId"].string.isEmpty, !file["fid"].string.isEmpty {
            return SyncDocument.identity("quark", file["sId"].string, file["fid"].string)
        }
        return SyncDocument.identity("episode", line, episode.isEmpty ? url : episode)
    }
    public static func key(_ value: JSON) -> String { key(line: value["line"].string, episode: value["episode"].string, url: value["episodeUrl"].string) }
    public static func id(_ value: JSON) -> String { SyncDocument.identity(kind, value["source"].string, value["site"].string, value["vod"].string, key(value)) }
    public static func historyID(_ value: JSON) -> String { SyncDocument.identity("history", value["source"].string, value["site"].string, value["vod"].string) }
    public static func value(in document: SyncDocument, source: String, site: String, vod: String, episode: Episode) -> JSON? {
        let key = key(line: episode.line, episode: episode.name, url: episode.url)
        let id = SyncDocument.identity(kind, source, site, vod, key)
        if let entry = document.records[id], !entry["deleted"].flag { return entry["value"] }
        let parent = SyncDocument.identity("history", source, site, vod)
        if let entry = document.records[parent], !entry["deleted"].flag, Self.key(entry["value"]) == key { return entry["value"] }
        return nil
    }
    /// 重复保存暂停位置不生成新观看时间，避免旧设备退出时反向覆盖云端。
    @discardableResult public static func record(_ value: JSON, in replica: inout Replica, device: String) -> Bool {
        let parent = historyID(value), episodeID = id(value)
        let oldHistory = replica.document.records[parent].flatMap { $0["deleted"].flag ? nil : $0["value"] }
        let previous = replica.document.records[episodeID].flatMap { $0["deleted"].flag ? nil : $0["value"] }
            ?? oldHistory.flatMap { id($0) == episodeID ? $0 : nil }
        if previous?["positionMs"].int == value["positionMs"].int { return false }
        if let oldHistory, oldHistory["positionMs"].int >= 0, oldHistory["durationMs"].int > 0,
           replica.document.records[id(oldHistory)] == nil {
            replica.edit(id: id(oldHistory), kind: kind, value: oldHistory, device: device, now: oldHistory["watchedAt"].int)
        }
        for (recordID, recordKind) in [(episodeID, kind), (parent, "history")] {
            var fields = replica.document.records[recordID]?["value"].object ?? [:]
            value.object.forEach { fields[$0.key] = $0.value }
            replica.edit(id: recordID, kind: recordKind, value: .object(fields), device: device, now: value["watchedAt"].int)
        }
        return true
    }

}

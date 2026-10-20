import Foundation

public enum SyncedQuarkAccount {
    /// 按当前同步文档读取；不另外落盘，不回写解密值。
    public static func cookie(in document: SyncDocument, drive: CloudDrive = .quark) throws -> String? {
        let key = drive == .uc ? "uc_ck" : "quark_ck"
        let id = SyncDocument.identity("cloudAccount", "catvod-sp-utils-v1")
        guard let record = document.records[id], !record["deleted"].flag else { return nil }
        let value = record["value"]
        guard value["adapter"].string == "catvod-sp-utils-v1" else { return nil }
        for group in ["prefs", "defaults"] {
            let encoded = value[group][key].string
            guard !encoded.isEmpty else { continue }
            let decoded = validCookie(encoded) ? encoded : (try? App99Crypto.decodePluginText(encoded))
            if let decoded, validCookie(decoded) { return decoded }
        }
        if !value["prefs"][key].string.isEmpty || !value["defaults"][key].string.isEmpty {
            throw TVError.message("同步的\(drive.name)登录格式尚无法解码，请同步完整网盘配置")
        }
        return nil
    }
    public static func loginValue(in document: SyncDocument, drive: CloudDrive, credentials: CloudLoginCredentials) throws -> JSON {
        guard validCookie(credentials.cookie) else { throw TVError.message("登录 Cookie 无效") }
        let record = document.records[SyncDocument.identity("cloudAccount", "catvod-sp-utils-v1")]
        var value = record != nil && record?["deleted"].flag == false ? record!["value"] : .object([:])
        value["adapter"] = .string("catvod-sp-utils-v1")
        for group in ["prefs", "defaults", "files"] {
            if value[group] == .null { value[group] = .object([:]) }
            guard case .object = value[group] else { throw TVError.message("同步网盘配置结构无效，请先检查同步数据") }
        }
        let key = drive == .uc ? "uc_ck" : "quark_ck"
        var loginPrefs = value["prefs"].object
        loginPrefs[key] = .string(try App99Crypto.encodePluginText(credentials.cookie))
        value["prefs"] = .object(loginPrefs)
        var defaults = value["defaults"].object; defaults.removeValue(forKey: key); value["defaults"] = .object(defaults)
        let ticketKey = drive == .uc ? "ucSt" : "quarkSt"
        var prefs = value["prefs"].object
        if let ticket = credentials.serviceTicket, !ticket.isEmpty { prefs[ticketKey] = .string(ticket) } else { prefs.removeValue(forKey:ticketKey) }
        value["prefs"] = .object(prefs)
        var ticketDefaults = value["defaults"].object; ticketDefaults.removeValue(forKey:ticketKey); value["defaults"] = .object(ticketDefaults)
        return value
    }
    public static func validCookie(_ value: String) -> Bool {
        guard value.utf8.count <= 256 * 1024, !value.utf8.contains(13), !value.utf8.contains(10) else { return false }
        return value.split(separator: ";").contains {
            let pair = $0.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return pair.count == 2 && pair[0] == "__pus" && !pair[1].isEmpty
        }
    }
}

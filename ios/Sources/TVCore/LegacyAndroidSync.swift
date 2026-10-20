import Foundation

/// 仅兼容已核对 R8 mapping.txt 的错误发布格式，不推断任意短字段 JSON。
enum LegacyAndroidSync {
    private static let documentFields = ["a":"epoch", "b":"mode", "c":"reset", "d":"records"]
    private static let entryFields = ["a":"kind", "b":"modified", "c":"sequence", "d":"device", "e":"deleted", "f":"value"]
    static func decode(_ value: JSON) throws -> JSON? {
        guard case .object(let object) = value, object["schema"] == nil else { return nil }
        guard object["epoch"] == nil, object["mode"] == nil, object["reset"] == nil, object["records"] == nil,
              case .string(let epoch) = value["a"], UUID(uuidString: epoch) != nil,
              ["merge", "replace", "reset"].contains(value["b"].string),
              case .string = value["c"], case .object = value["d"] else { return nil }
        var result = try rename(value, fields: documentFields)
        result["schema"] = .integer(1)
        var records: [String: JSON] = [:]
        for (key, entry) in value["d"].object {
            guard case .string = entry["a"], case .number = entry["b"], case .number = entry["c"],
                  case .string = entry["d"], case .bool = entry["e"] else { throw TVError.message("旧版 Android 同步记录格式无效") }
            records[key] = try rename(entry, fields: entryFields)
        }
        result["records"] = .object(records)
        return result
    }
    private static func rename(_ value: JSON, fields: [String: String]) throws -> JSON {
        var object = value.object
        for (old, new) in fields {
            guard object[new] == nil else { throw TVError.message("同步字段存在冲突，未转换旧格式") }
            if let field = object.removeValue(forKey: old) { object[new] = field }
        }
        return .object(object)
    }
    static func encode(_ canonical: JSON) throws -> Data {
        var root = canonical.object
        // 短键与未知扩展字段冲突时拒绝写入，不能覆盖未知数据。
        guard documentFields.keys.allSatisfy({ root[$0] == nil }) else { throw TVError.message("旧格式字段冲突，请先更新 Android 客户端") }
        var records: [String: JSON] = [:]
        for (key, entry) in canonical["records"].object {
            guard entryFields.keys.allSatisfy({ entry.object[$0] == nil }) else { throw TVError.message("旧格式记录字段冲突，请先更新 Android 客户端") }
            var row = entry.object
            for (short, name) in entryFields { if let field = row.removeValue(forKey: name) { row[short] = field } }
            records[key] = .object(row)
        }
        root["records"] = .object(records); root.removeValue(forKey: "schema")
        for (short, name) in documentFields { if let field = root.removeValue(forKey: name) { root[short] = field } }
        return JSON.object(root).data
    }
}

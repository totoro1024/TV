import Foundation

/// 保留未知字段和数字原文，避免未知插件数据经过 iPhone 写回后被截断。
public indirect enum JSON: Equatable, Sendable {
    case object([String: JSON]), array([JSON]), string(String), number(String), bool(Bool), null
    public subscript(_ key: String) -> JSON {
        get { if case .object(let map) = self { return map[key] ?? .null }; return .null }
        set { if case .object(var map) = self { map[key] = newValue; self = .object(map) } }
    }
    public var object: [String: JSON] { if case .object(let v) = self { return v }; return [:] }
    public var array: [JSON] { if case .array(let v) = self { return v }; return [] }
    public var string: String { if case .string(let v) = self { return v }; return "" }
    public var int: Int64 { if case .number(let v) = self { return Int64(v) ?? 0 }; return 0 }
    public var flag: Bool { if case .bool(let v) = self { return v }; return false }
    public static func integer(_ value: Int64) -> JSON { .number(String(value)) }
    public var data: Data { Data(text.utf8) }
    public var text: String {
        switch self {
        case .null: return "null"
        case .bool(let v): return v ? "true" : "false"
        case .number(let v): return v
        case .string(let v):
            var out = "\""
            for s in v.unicodeScalars {
                switch s.value {
                case 34: out += "\\\""
                case 92: out += "\\\\"
                case 8: out += "\\b"
                case 9: out += "\\t"
                case 10: out += "\\n"
                case 12: out += "\\f"
                case 13: out += "\\r"
                case 0..<32, 0x2028, 0x2029: out += String(format: "\\u%04x", s.value)
                default: out.unicodeScalars.append(s)
                }
            }
            return out + "\""
        case .array(let v): return "[" + v.map(\.text).joined(separator: ",") + "]"
        case .object(let v): return "{" + v.keys.sorted(by: Self.javaLess).map { JSON.string($0).text + ":" + v[$0]!.text }.joined(separator: ",") + "}"
        }
    }
    public static func javaLess(_ a: String, _ b: String) -> Bool { a.utf16.lexicographicallyPrecedes(b.utf16) }
    public static func parse(_ data: Data, maxBytes: Int = 8 * 1024 * 1024) throws -> JSON {
        guard data.count <= maxBytes else { throw TVError.message("数据超过允许的大小") }
        var parser = Parser(bytes: Array(data)); let value = try parser.value(0); parser.space()
        guard parser.index == parser.bytes.count else { throw TVError.message("JSON 尾部有多余内容") }
        return value
    }
}
private struct Parser {
    let bytes: [UInt8]; var index = 0
    mutating func space() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
    mutating func take(_ c: UInt8) -> Bool { space(); if index < bytes.count && bytes[index] == c { index += 1; return true }; return false }
    mutating func value(_ depth: Int) throws -> JSON {
        space(); guard depth < 64, index < bytes.count else { throw TVError.message("JSON 格式或嵌套深度无效") }
        if take(123) {
            var map: [String: JSON] = [:]; if take(125) { return .object(map) }
            repeat {
                let key = try quoted(); guard map[key] == nil, take(58) else { throw TVError.message("JSON 字段重复或缺少冒号") }
                map[key] = try value(depth + 1)
                if take(125) { return .object(map) }
            } while take(44)
            throw TVError.message("JSON 对象无效")
        }
        if take(91) {
            var values: [JSON] = []; if take(93) { return .array(values) }
            repeat { values.append(try value(depth + 1)); if take(93) { return .array(values) } } while take(44)
            throw TVError.message("JSON 数组无效")
        }
        if bytes[index] == 34 { return .string(try quoted()) }
        for (token, result) in [("true", JSON.bool(true)), ("false", .bool(false)), ("null", .null)] {
            let b = Array(token.utf8)
            if bytes[index...].starts(with: b) { index += b.count; return result }
        }
        let start = index
        while index < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }
        let number = String(decoding: bytes[start..<index], as: UTF8.self)
        guard number.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil else { throw TVError.message("JSON 数字无效") }
        return .number(number)
    }
    mutating func quoted() throws -> String {
        space(); let start = index; guard take(34) else { throw TVError.message("JSON 字符串无效") }
        while index < bytes.count {
            let c = bytes[index]; index += 1
            if c == 92 { index += 1; continue }
            if c == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
        }
        throw TVError.message("JSON 字符串未结束")
    }
}
public enum TVError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let text): return text } }
}

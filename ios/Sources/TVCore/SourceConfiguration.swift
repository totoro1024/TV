import Foundation

/// 电视源兼容层；只用于源配置，不改变 WebDAV 协议的严格 JSON 解析。
enum SourceConfiguration {
    static func parse(_ data: Data) throws -> JSON {
        guard data.count <= 8 * 1024 * 1024 else { throw TVError.message("源配置超过允许的大小") }
        var payload = data
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // Android Decoder 的八位标记 + ** Base64 封装，前缀可以是图片。
        if !trimmed.hasPrefix("{"), !trimmed.hasPrefix("["),
           let range = trimmed.range(of: #"[A-Za-z0-9]{8}\*\*"#, options: .regularExpression) {
            let encoded = String(trimmed[range.upperBound...]).filter { !$0.isWhitespace }
            guard let decoded = Data(base64Encoded: encoded) else { throw TVError.message("源配置的 Base64 封装无效") }
            payload = decoded
        }
        if payload.starts(with: [0xef, 0xbb, 0xbf]) { payload.removeFirst(3) }
        guard let text = String(data: payload, encoding: .utf8) else { throw TVError.message("此源不是可读取的 UTF-8 配置，可能使用了图片或加密封装") }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("2423") {
            throw TVError.message("此源使用 Android 加密封装，iPhone 暂不支持，请使用兼容 JSON 源")
        }
        let bytes = Array(text.utf8)
        var result: [UInt8] = [], index = 0, quoted = false
        while index < bytes.count {
            let byte = bytes[index]
            if quoted {
                result.append(byte); index += 1
                if byte == 92, index < bytes.count { result.append(bytes[index]); index += 1 }
                else if byte == 34 { quoted = false }
                continue
            }
            if byte == 34 { quoted = true; result.append(byte); index += 1; continue }
            if byte == 47, index + 1 < bytes.count {
                if bytes[index + 1] == 47 {
                    index += 2
                    while index < bytes.count && ![10, 13].contains(bytes[index]) { index += 1 }
                    result.append(32); continue
                }
                if bytes[index + 1] == 42 {
                    index += 2; var closed = false
                    while index + 1 < bytes.count {
                        if bytes[index] == 42 && bytes[index + 1] == 47 { index += 2; closed = true; break }
                        index += 1
                    }
                    guard closed else { throw TVError.message("源配置的注释未结束") }
                    result.append(32); continue
                }
            }
            result.append(byte); index += 1
        }
        // 第二遍只移除字符串外、对象或数组结尾前的逗号。
        var normalized: [UInt8] = []; index = 0; quoted = false
        while index < result.count {
            let byte = result[index]
            if quoted {
                normalized.append(byte); index += 1
                if byte == 92, index < result.count { normalized.append(result[index]); index += 1 }
                else if byte == 34 { quoted = false }
                continue
            }
            if byte == 34 { quoted = true }
            if byte == 44 {
                var next = index + 1
                while next < result.count && [9, 10, 13, 32].contains(result[next]) { next += 1 }
                if next < result.count && [93, 125].contains(result[next]) { index += 1; continue }
            }
            normalized.append(byte); index += 1
        }
        do { return try JSON.parse(Data(normalized)) }
        catch { throw TVError.message("源配置格式无效，请检查是否为兼容 JSON 配置或是否需要 Android 解密插件") }
    }
}

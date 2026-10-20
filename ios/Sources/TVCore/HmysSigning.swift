import Foundation
import CryptoKit

/// 海绵 CDN 每个清单与分片各自签名，原始查询由接口的 ck 字段提供。
public struct HmysSigning: Sendable {
    public let query: String
    public let key: String
    public init(query: String, key: String) throws {
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded = Data(base64Encoded: raw, options: .ignoreUnknownCharacters).flatMap { String(data: $0, encoding: .utf8) }
        let value = [raw, decoded ?? ""].first { $0.contains("Time=") || $0.hasPrefix("k=") || $0.hasPrefix("az=") }
        guard let value, !value.contains("\r"), !value.contains("\n"), !key.isEmpty else { throw TVError.message("海绵分片授权参数无效") }
        self.query = value.hasPrefix("?") ? String(value.dropFirst()) : value
        self.key = key
    }
    public func signed(_ url: URL, at seconds: Int64 = SyncDocument.now / 1000) throws -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { throw TVError.message("海绵分片地址无效") }
        let time = String(seconds, radix: 16)
        let digest = Insecure.MD5.hash(data: Data((key + parts.percentEncodedPath + time).utf8)).map { String(format: "%02x", $0) }.joined()
        parts.percentEncodedQuery = query + "&wsSecret=" + digest + "&wsTime=" + time
        guard let result = parts.url else { throw TVError.message("海绵签名地址无效") }; return result
    }
}

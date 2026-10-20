import Foundation

/// 将播放器看到的净视频字节范围映射到含前缀的原文件。
public struct StreamByteRange: Equatable, Sendable {
    public let start: Int64, end: Int64, length: Int64, offset: Int64
    public var upstream: String { "bytes=\(start + offset)-\(end + offset)" }
    public var contentRange: String { "bytes \(start)-\(end)/\(length)" }
    public var count: Int64 { end - start + 1 }
    public init(header: String?, size: Int64, offset: Int64) throws {
        guard offset >= 0, size > offset else { throw TVError.message("播放文件长度无效") }
        let length = size-offset
        var start: Int64 = 0, end = length-1
        if let header {
            guard header.hasPrefix("bytes=") else { throw TVError.message("播放字节范围无效") }
            let pair = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            guard pair.count == 2 else { throw TVError.message("播放字节范围无效") }
            if pair[0].isEmpty {
                guard let suffix = Int64(pair[1]), suffix > 0 else { throw TVError.message("播放字节范围无效") }
                start = max(0, length - suffix)
            } else {
                guard let first = Int64(pair[0]), first >= 0, first < length else { throw TVError.message("播放字节范围无效") }
                start = first
                if !pair[1].isEmpty {
                    guard let last = Int64(pair[1]), last >= start else { throw TVError.message("播放字节范围无效") }
                    end = min(end, last)
                }
            }
        }
        self.start = start; self.end = end; self.length = length; self.offset = offset
    }
}

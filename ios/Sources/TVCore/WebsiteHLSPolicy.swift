import Foundation

public enum WebsiteHLSPolicy {
    public static func headers(_ headers:[String:String], origin:URL, target:URL) -> [String:String] {
        headers.filter { key,_ in
            let key = key.lowercased(), host = target.host?.lowercased() ?? ""
            if origin.host?.lowercased() != host && ["cookie","authorization"].contains(key) { return false }
            if origin.host?.lowercased() == "www.doubaozhibo.com",origin.host?.lowercased() != host,key == "referer" { return false }
            if (host == "xhscdn.com" || host.hasSuffix(".xhscdn.com")) && key == "referer" { return false }
            return true
        }
    }
    /// 厂长 PNG 分片中的图片头不属于 MPEG-TS，按连续包同步字节识别边界。
    public static func transportStream(_ data:Data) throws -> Data {
        guard data.starts(with:[0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]) else { return data }
        let bytes = [UInt8](data)
        guard bytes.count >= 188*5 else { throw TVError.message("网页视频分片不完整") }
        for offset in 8...min(65536,bytes.count-188*4-1) {
            if (0..<5).allSatisfy({bytes[offset+$0*188] == 0x47}) { return Data(bytes[offset...]) }
        }
        throw TVError.message("网页图片分片中未找到视频数据")
    }
}

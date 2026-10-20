import Foundation

public enum NetworkIssue {
    public static func cancelled(_ error: Error) -> Bool {
        error is CancellationError || ((error as NSError).domain == NSURLErrorDomain && (error as NSError).code == URLError.cancelled.rawValue)
    }
    public static func transient(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == NSURLErrorDomain && [-1001,-1003,-1004,-1005,-1006,-1009].contains(e.code)
    }
    /// 不包含原始 URL、请求头或 NSError.userInfo，避免暴露媒体签名和凭据。
    public static func message(_ error: Error, context: String) -> String {
        let e = error as NSError
        guard e.domain == NSURLErrorDomain else { return context + "失败" }
        let reason: String
        switch e.code {
        case -1001: reason = "请求超时，请稍后重试"
        case -1003,-1006: reason = "无法解析服务器地址，请检查地址或 DNS"
        case -1004: reason = "无法连接服务器，请检查地址、端口及服务是否运行"
        case -1005: reason = "连接中断，稍后将重试"
        case -1009: reason = "当前网络不可用，请检查 Wi-Fi 或移动网络"
        case -1020: reason = "网络访问未获允许，请检查应用的网络权限"
        case -1200,-1202: reason = "HTTPS 安全连接或证书校验失败"
        case -1000,-1002: reason = "请求地址无效或协议不受支持"
        default: reason = "网络请求失败，请稍后重试"
        }
        return context + "：" + reason + "（\(e.code)）"
    }
}
public struct SyncRetryState: Sendable {
    public private(set) var failures = 0
    public private(set) var nextAttempt = Date.distantPast
    public init() {}
    public func canAttempt(at now: Date = Date()) -> Bool { now >= nextAttempt }
    public mutating func failed(at now: Date = Date()) {
        let delays: [TimeInterval] = [5,15,60,300]
        failures += 1; nextAttempt = now.addingTimeInterval(delays[min(failures - 1, delays.count - 1)])
    }
    public mutating func succeeded() { failures = 0; nextAttempt = .distantPast }
}

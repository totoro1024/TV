import Foundation

/// 只在内存中保存用户完成网站验证后取得的Cookie，按域名、路径和有效期隔离。
public actor MusicVerificationSession {
    public static let shared = MusicVerificationSession()
    private var saved:[String:[HTTPCookie]] = [:]
    public init() {}
    public func install(_ cookies:[HTTPCookie],origin:URL) {
        guard let host = origin.host?.lowercased() else { return }
        saved[host] = cookies.filter { cookie in
            let domain = cookie.domain.trimmingCharacters(in:CharacterSet(charactersIn:".")).lowercased()
            return host == domain || host.hasSuffix("."+domain)
        }
    }
    public func header(for url:URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let cookies = (saved[host] ?? []).filter { cookie in
            let path = url.path.isEmpty ? "/" : url.path
            let pathMatches = path == cookie.path || path.hasPrefix(cookie.path.hasSuffix("/") ? cookie.path : cookie.path+"/")
            return pathMatches && (!cookie.isSecure || url.scheme == "https") && (cookie.expiresDate == nil || cookie.expiresDate! > Date())
        }
        return cookies.isEmpty ? nil : HTTPCookie.requestHeaderFields(with:cookies)["Cookie"]
    }
}

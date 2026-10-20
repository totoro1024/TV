import Foundation
import Security
import TVCore

/// WebDAV 配置仅写应用私有目录；钥匙串只用于迁移旧版本。
enum CredentialVault {
    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TVWebDAV/webdav-settings.json")
    }
    private static var legacyQuery: [String: Any] {
        [kSecClass as String:kSecClassGenericPassword,
         kSecAttrService as String:"com.totoro.tv.webdav.credentials",
         kSecAttrAccount as String:"webdav"]
    }
    private static func decode(_ data: Data) throws -> DAVSettings {
        let json = try JSON.parse(data)
        guard case .string = json["address"], case .string = json["username"],
              case .string = json["password"] else { throw TVError.message("本地 WebDAV 配置格式无效") }
        return DAVSettings(address: json["address"].string, username: json["username"].string, password: json["password"].string, userDirectory: json["userDirectory"].string)
    }
    static func read() throws -> DAVSettings {
        if FileManager.default.fileExists(atPath: file.path) {
            return try decode(Data(contentsOf: file))
        }
        var query = legacyQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        // 没有旧凭据或自签后无法访问旧钥匙串时，仍可直接配置本地文件。
        guard status == errSecSuccess, let data = result as? Data else { return DAVSettings() }
        let settings = try decode(data)
        try save(settings)
        return settings
    }
    static func save(_ settings: DAVSettings) throws {
        let data = JSON.object(["address":.string(settings.address), "username":.string(settings.username), "password":.string(settings.password), "userDirectory":.string(settings.userDirectory)]).data
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        // 只有本地文件成功落盘后才清理旧项；以后不再写入钥匙串。
        SecItemDelete(legacyQuery as CFDictionary)
    }
}

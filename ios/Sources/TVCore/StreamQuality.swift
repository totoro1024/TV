import Foundation

public struct StreamQuality: Identifiable, Equatable, Sendable {
    public let id: String, name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
    public static let original = StreamQuality(id: "original", name: "原画")
    public static func quark(_ rows: [JSON]) -> [StreamQuality] {
        let labels = ["normal":"标清", "low":"流畅", "high":"高清", "super":"超清", "2k":"2K", "4k":"4K"]
        var seen = Set<String>()
        return rows.compactMap { row in
            let id = row["resolution"].string
            guard !id.isEmpty, CatalogParser.validHTTP(row["video_info"]["url"].string), seen.insert(id).inserted else { return nil }
            return StreamQuality(id: id, name: labels[id] ?? id)
        }
    }
}

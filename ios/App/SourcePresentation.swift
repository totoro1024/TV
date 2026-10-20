import Foundation
import TVCore

/// 对照 Android Config.getDesc：名称优先，没有名称则显示原网址。
enum SourcePresentation {
    static func description(_ value: JSON) -> String {
        let name = value["name"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let address = value["url"].string
        return address.isEmpty ? "未配置" : address
    }
}

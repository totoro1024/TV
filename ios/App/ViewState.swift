import SwiftUI

// 明确使用可部署到 iOS 17 的属性包装器，避免新 SDK 的同名 State 宏影响旧系统构建。
typealias ViewState<Value> = SwiftUI.State<Value>

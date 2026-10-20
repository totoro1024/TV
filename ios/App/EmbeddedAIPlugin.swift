import Foundation
import TVCore

/// Python及插件在应用包内；所有解释器调用离开主线程，账号配置不传入运行时。
final class EmbeddedAIPlugin:@unchecked Sendable {
    static let shared=EmbeddedAIPlugin()
    private let queue=DispatchQueue(label:"tv.ai.plugin",qos:.userInitiated)
    private var initialized=false
    func call(_ method:String,payload:JSON) async throws -> JSON {
        try Task.checkCancellation()
        let data:Data=try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if !self.initialized {
                    let root=Bundle.main.bundleURL.appendingPathComponent("python").path
                    guard TVPythonInitialize(root)==1 else { continuation.resume(throwing:TVError.message("AI播放组件初始化失败，请重新安装完整版本"));return }
                    self.initialized=true
                }
                guard let value=TVPythonCall(method,payload.text) else { continuation.resume(throwing:TVError.message("AI短漫剧请求失败，请检查网络或稍后重试"));return }
                defer { TVPythonFree(value) }
                continuation.resume(returning:Data(String(cString:value).utf8))
            }
        }
        try Task.checkCancellation();return try JSON.parse(data)
    }
}

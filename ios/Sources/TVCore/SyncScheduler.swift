import Foundation

/// 合并短时间内的同步触发。
@MainActor public final class SyncScheduler {
    private var pending: Task<Void, Never>?
    private let delay: Duration
    public init(delay: Duration = .milliseconds(800)) { self.delay = delay }
    public func request(_ operation: @escaping @MainActor () async -> Void) {
        pending?.cancel()
        pending = Task {
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            // 防抖仅管理等待计时；已启动的请求由同步流程管理，不能被后续触发取消。
            pending = nil
            await operation()
        }
    }
    deinit { pending?.cancel() }
}

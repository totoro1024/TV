import XCTest
@testable import TVCore

final class SyncSchedulerTests: XCTestCase {
    @MainActor func testLaterTriggerMustNotCancelAnAlreadyStartedNetworkRequest() async throws {
        let scheduler = SyncScheduler(delay: .milliseconds(10))
        var starts = 0, cancelled = 0, completed = 0
        let operation: @MainActor () async -> Void = {
            starts += 1
            do { try await Task.sleep(for: .milliseconds(100)); completed += 1 }
            catch { cancelled += 1 }
        }
        scheduler.request(operation)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(starts, 1)
        scheduler.request(operation)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(cancelled, 0, "新触发只应取消尚未开始的防抖计时，不能取消已开始的网络请求")
        XCTAssertEqual(completed, 2)
    }
    @MainActor func testRapidTriggersStillDebounceBeforeNetworkStarts() async throws {
        let scheduler = SyncScheduler(delay: .milliseconds(30))
        var starts = 0
        for _ in 0..<4 { scheduler.request { starts += 1 } }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(starts, 1)
    }
}

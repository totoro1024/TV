import XCTest
@testable import TVCore
final class NetworkIssueTests: XCTestCase {
    func testCancellationNeverMasqueradesAsConnectionFailure() {
        XCTAssertTrue(NetworkIssue.cancelled(URLError(.cancelled)))
        XCTAssertTrue(NetworkIssue.cancelled(CancellationError()))
        XCTAssertFalse(NetworkIssue.transient(URLError(.cancelled)))
        XCTAssertFalse(NetworkIssue.cancelled(URLError(.timedOut)))
    }
    func testMessagesIdentifyOperationAndErrorWithoutLeakingURL() {
        let error=NSError(domain:NSURLErrorDomain,code:-1001,userInfo:[NSURLErrorFailingURLStringErrorKey:"https://private.test/?token=synthetic-secret"])
        let text=NetworkIssue.message(error,context:"WebDAV 同步")
        XCTAssertTrue(text.contains("WebDAV 同步"));XCTAssertTrue(text.contains("超时"));XCTAssertTrue(text.contains("-1001"))
        XCTAssertFalse(text.contains("private.test"));XCTAssertFalse(text.contains("synthetic-secret"))
        XCTAssertTrue(NetworkIssue.message(URLError(.notConnectedToInternet),context:"搜索").contains("当前网络不可用"))
    }
    func testAutomaticRetryBackoffAndSuccessReset() {
        var retry=SyncRetryState();let start=Date(timeIntervalSince1970:100)
        for delay in [5.0,15,60,300,300] {
            retry.failed(at:start)
            XCTAssertFalse(retry.canAttempt(at:start.addingTimeInterval(delay-1)))
            XCTAssertTrue(retry.canAttempt(at:start.addingTimeInterval(delay)))
        }
        retry.succeeded();XCTAssertEqual(retry.failures,0);XCTAssertTrue(retry.canAttempt(at:start))
    }
}

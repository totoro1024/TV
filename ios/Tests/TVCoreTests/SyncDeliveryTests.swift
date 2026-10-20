import XCTest
@testable import TVCore

final class SyncDeliveryTests: XCTestCase {
    func testPendingAndFailureSurviveRestartUntilCorrectRevisionIsAcknowledged() throws {
        var local = Replica()
        let id = SyncDocument.identity("future")
        local.edit(id:id,kind:"future",value:.object(["position":.integer(1)]),device:"phone")
        let sent = local.localRevision
        local.edit(id:id,kind:"future",value:.object(["position":.integer(2)]),device:"phone")
        local.retryNeeded = true
        var loaded = try Replica(json: JSON.parse(local.json.data))
        XCTAssertTrue(loaded.pendingUpload)
        XCTAssertEqual(loaded.deliveryText(syncing:false,configured:true,automatic:true,deferred:false),"同步失败，等待重试")
        XCTAssertEqual(loaded.deliveryText(syncing:true,configured:true,automatic:true,deferred:false),"同步中…")
        loaded.acknowledge(sent)
        XCTAssertTrue(loaded.pendingUpload)
        XCTAssertEqual(loaded.deliveryText(syncing:false,configured:true,automatic:false,deferred:false),"待同步（自动同步已关闭）")
        loaded.acknowledge(loaded.localRevision)
        XCTAssertFalse(loaded.pendingUpload)
        XCTAssertEqual(loaded.deliveryText(syncing:false,configured:true,automatic:true,deferred:true),"已同步，云端进度将在退出播放后应用")
    }
    func testLegacyLocalStateIsCheckedBeforeBeingShownAsSynced() throws {
        var json = Replica().json; json["uploadedRevision"] = .null
        let loaded = try Replica(json:json)
        XCTAssertTrue(loaded.pendingUpload)
    }
}

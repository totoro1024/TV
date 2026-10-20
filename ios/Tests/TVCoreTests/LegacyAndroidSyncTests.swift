import XCTest
@testable import TVCore

final class LegacyAndroidSyncTests: XCTestCase {
    func testKnownR8ReleaseShapeLoadsAndWritesCanonicalFields() throws {
        let id = SyncDocument.identity("future", "synthetic")
        let compact: JSON = .object([
            "a":.string("12345678-1234-1234-1234-123456789abc"), "b":.string("merge"), "c":.string(""),
            "d":.object([id:.object(["a":.string("future"),"b":.integer(100),"c":.integer(1),"d":.string("test-device"),"e":.bool(false),"f":.object(["opaque":.string("synthetic"),"huge":.number("123456789012345678901234567890")]),"futureEntry":.bool(true)])]),
            "futureRoot":.string("preserve")])
        let document = try SyncDocument(data: compact.data)
        XCTAssertEqual(document.raw["schema"].int, 1)
        XCTAssertEqual(document.epoch, compact["a"].string)
        XCTAssertEqual(document.records[id]?["kind"].string, "future")
        XCTAssertEqual(document.records[id]?["value"]["huge"], compact["d"][id]["f"]["huge"])
        XCTAssertEqual(document.records[id]?["futureEntry"], .bool(true))
        XCTAssertEqual(document.raw["futureRoot"].string, "preserve")
        XCTAssertNil(document.raw.object["a"])
        XCTAssertNil(document.records[id]?.object["a"])
        XCTAssertEqual(try SyncDocument(data: document.raw.data), document)
    }
    func testUnknownVersionsAndAmbiguousShortKeysRemainRejected() {
        for text in [
            #"{"a":"not-an-epoch","b":"merge","c":"","d":{}}"#,
            #"{"schema":2,"a":"12345678-1234-1234-1234-123456789abc","b":"merge","c":"","d":{}}"#,
            #"{"schema":1,"a":"12345678-1234-1234-1234-123456789abc","b":"merge","c":"","d":{}}"#,
            #"{"a":"12345678-1234-1234-1234-123456789abc","b":"other","c":"","d":{}}"#
        ] { XCTAssertThrowsError(try SyncDocument(data: Data(text.utf8))) }
    }
    func testLegacyEncodingRoundTripKeepsResetAndTombstone() throws {
        let id = SyncDocument.identity("future", "deleted")
        let text = "{\"a\":\"12345678-1234-1234-1234-123456789abc\",\"b\":\"merge\",\"c\":\"reset-marker\",\"d\":{\"\(id)\":{\"a\":\"future\",\"b\":100,\"c\":1,\"d\":\"test-device\",\"e\":true}}}"
        let document = try SyncDocument(data: Data(text.utf8))
        XCTAssertTrue(document.usesLegacyAndroidLayout)
        let wire = try document.wireData(preservingLegacyAndroidLayout: true)
        let raw = try JSON.parse(wire)
        XCTAssertEqual(raw["c"].string, "reset-marker")
        XCTAssertEqual(raw["d"][id]["e"], .bool(true))
        XCTAssertEqual(try SyncDocument(data: wire), document)
        XCTAssertNotNil(try JSON.parse(document.wireData()).object["schema"])
    }
    func testLiveReadOnlyWebDAVMigration() async throws {
        guard let path = ProcessInfo.processInfo.environment["TV_SYNC_READ_SETTINGS"] else { throw XCTSkip("未指定只读 WebDAV 检查配置") }
        let config = try JSON.parse(Data(contentsOf: URL(fileURLWithPath: path)))
        let client = try WebDAVClient(settings: DAVSettings(address: config["address"].string, username: config["username"].string, password: config["password"].string))
        let snapshot = try await client.read()
        let document = try XCTUnwrap(snapshot.document)
        try document.validate()
        XCTAssertNotNil(snapshot.etag)
        XCTAssertEqual(try SyncDocument(data: document.wireData(preservingLegacyAndroidLayout: document.usesLegacyAndroidLayout)), document)
        print("真实 WebDAV 只读验证通过：schema=1，记录数=\(document.records.count)，旧 Android 布局=\(document.usesLegacyAndroidLayout)。未执行 PUT。")
    }
}

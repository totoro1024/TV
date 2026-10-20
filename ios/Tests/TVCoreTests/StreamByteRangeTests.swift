import XCTest
@testable import TVCore
final class StreamByteRangeTests: XCTestCase {
    func testPrefixRemovedFromRangeAndLength() throws {
        let range = try StreamByteRange(header: "bytes=0-31", size: 1008, offset: 8)
        XCTAssertEqual(range.upstream, "bytes=8-39")
        XCTAssertEqual(range.contentRange, "bytes 0-31/1000")
        XCTAssertEqual(range.count, 32)
    }
    func testOpenEndedAndTailSeeks() throws {
        XCTAssertEqual(try StreamByteRange(header: "bytes=900-", size: 1008, offset: 8).upstream, "bytes=908-1007")
        XCTAssertEqual(try StreamByteRange(header: "bytes=-100", size: 1008, offset: 8).upstream, "bytes=908-1007")
        XCTAssertEqual(try StreamByteRange(header: nil, size: 1008, offset: 8).count, 1000)
    }
    func testInvalidRangesNeverFetchWrongBytes() {
        for header in ["bytes=-", "bytes=2-1", "bytes=1000-", "bytes=1-2,4-5", "bytes=-0", "bytes=-1-4", "bytes=9223372036854775808-"] {
            XCTAssertThrowsError(try StreamByteRange(header: header, size: 1008, offset: 8))
        }
    }
}

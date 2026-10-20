import XCTest
@testable import TVCore
final class SyncedQuarkTests: XCTestCase {
    private func replica(_ cookie: String) -> Replica {
        var r = Replica()
        r.edit(id: SyncDocument.identity("cloudAccount", "catvod-sp-utils-v1"), kind: "cloudAccount", value: .object(["adapter":.string("catvod-sp-utils-v1"),"prefs":.object(["quark_ck":.string(cookie)]),"defaults":.object([:]),"files":.object([:])]), device: "test", now: 100)
        return r
    }
    func testEncryptedCookieDecodedWithoutChangingDocument() throws {
        let r = replica("sbaP0PpKcE8T7fZQxofRvvenqSve282z0z4hadT2FRZR")
        let before = r.document.raw
        XCTAssertEqual(try SyncedQuarkAccount.cookie(in: r.document), "__pus=synthetic; __puus=test-only")
        XCTAssertEqual(r.document.raw, before)
    }
    func testDeletionAndEmptyScopeDoNotReuseOldCookie() throws {
        var r = replica("__pus=synthetic")
        XCTAssertNotNil(try SyncedQuarkAccount.cookie(in: r.document))
        r.edit(id: SyncDocument.identity("cloudAccount", "catvod-sp-utils-v1"), kind: "cloudAccount", value: nil, device: "test", now: 200)
        XCTAssertNil(try SyncedQuarkAccount.cookie(in: r.document))
        XCTAssertNil(try SyncedQuarkAccount.cookie(in: Replica().document))
    }
    func testMalformedCookieAndHeaderInjectionRejected() {
        XCTAssertFalse(SyncedQuarkAccount.validCookie("__pus=x\r\nHost: other"))
        XCTAssertFalse(SyncedQuarkAccount.validCookie("__pus="))
        XCTAssertFalse(SyncedQuarkAccount.validCookie("not__pus=test"))
        XCTAssertThrowsError(try SyncedQuarkAccount.cookie(in: replica("invalid").document))
    }
}

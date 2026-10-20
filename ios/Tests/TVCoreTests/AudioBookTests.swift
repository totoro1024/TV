import XCTest
@testable import TVCore
final class AudioBookTests:XCTestCase {
    func testSignatureMatchesOriginalAndroidNativeVectors() {
        XCTAssertEqual(AudioBookClient.signature("tvbox-runtime-probe"),"084e25b91203d0d72bc1ff0fbed5fe8a")
        XCTAssertEqual(AudioBookClient.signature("abc"),"a3b92204d42ec91e74fabe4c74620bfc")
        XCTAssertEqual(AudioBookClient.signature("1700000000000"),"373703f74c37d22df282535f4264dddb")
    }
}

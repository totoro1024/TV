import XCTest
@testable import TVCore
final class WebsiteHLSPolicyTests:XCTestCase {
    func testImagePrefixIsRemovedOnlyWithFiveTransportPackets() throws {
        var data = Data([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]);data.append(Data(repeating:0,count:112))
        var packets = Data(repeating:0,count:188*6)
        for index in stride(from:0,to:packets.count,by:188) { packets[index] = 0x47 }
        data.append(packets)
        XCTAssertEqual(try WebsiteHLSPolicy.transportStream(data),packets)
        XCTAssertEqual(try WebsiteHLSPolicy.transportStream(packets),packets)
        XCTAssertThrowsError(try WebsiteHLSPolicy.transportStream(data.prefix(120)))
    }
    func testPlaybackProxyReferrerDoesNotLeakToExternalCDN() {
        let origin = URL(string:"https://www.doubaozhibo.com/api/playback.m3u8")!
        let h = ["Referer":"https://www.doubaozhibo.com/","User-Agent":"fixture"]
        XCTAssertNil(WebsiteHLSPolicy.headers(h,origin:origin,target:URL(string:"https://vod.example/stream.m3u8")!)["Referer"])
        XCTAssertNotNil(WebsiteHLSPolicy.headers(h,origin:origin,target:origin)["Referer"])
    }
    func testCDNHeadersAvoidForbiddenReferrerAndCrossHostCredentials() {
        let origin = URL(string:"https://playlist.example/index.m3u8")!, target = URL(string:"https://dc.xhscdn.com/part.png")!
        let h = ["Cookie":"fixture","Authorization":"fixture","Referer":"https://player.example/","User-Agent":"fixture"]
        let result = WebsiteHLSPolicy.headers(h,origin:origin,target:target)
        XCTAssertEqual(result,["User-Agent":"fixture"])
        XCTAssertEqual(WebsiteHLSPolicy.headers(h,origin:origin,target:origin),h)
        XCTAssertNotNil(WebsiteHLSPolicy.headers(h,origin:origin,target:URL(string:"https://xhscdn.com.other.test/part")!)["Referer"])
    }
}

import XCTest
@testable import TVCore
private actor QuarkMock: HTTPTransport {
    var paths: [String] = []
    func send(_ request: URLRequest) async throws -> HTTPReply {
        XCTAssertTrue(["pan.quark.cn","drive-pc.quark.cn"].contains(request.url!.host!))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "synthetic=test-only")
        paths.append(request.url!.path)
        if request.url!.path.hasSuffix("account/info") { return HTTPReply(status: 200, body: Data(#"{"data":{"nickname":"test"}}"#.utf8)) }
        if request.url!.path.hasSuffix("token") {
            let body = try JSON.parse(request.httpBody!)
            XCTAssertEqual(body["pwd_id"].string, "test123")
            return HTTPReply(status: 200, body: Data(#"{"status":200,"code":0,"data":{"stoken":"synthetic-token"}}"#.utf8))
        }
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "stoken" }?.value, "synthetic-token")
        return HTTPReply(status: 200, body: Data(#"{"status":200,"code":0,"data":{"list":[{"fid":"1","file_name":"test.mp4"}]}}"#.utf8))
    }
}
final class QuarkTests: XCTestCase {
    func testShareURLRequiresOfficialHTTPSHost() throws {
        XCTAssertEqual(try QuarkClient.shareID("https://pan.quark.cn/s/test123"), "test123")
        for value in ["http://pan.quark.cn/s/test123", "https://pan.quark.cn.evil.test/s/test123", "https://other.test/s/test123", "https://pan.quark.cn/s/"] { XCTAssertThrowsError(try QuarkClient.shareID(value)) }
    }
    func testAccountTokenAndReadOnlyDirectory() async throws {
        let client = QuarkClient(cookie: "synthetic=test-only", transport: QuarkMock())
        try await client.validateAccount()
        let token = try await client.shareToken(id: "test123")
        let files = try await client.files(id: "test123", token: token)
        XCTAssertEqual(files.first?["file_name"].string, "test.mp4")
    }
    func testNoCredentialFailsBeforeNetwork() async {
        do { _ = try await QuarkClient(cookie: "", transport: QuarkMock()).shareToken(id: "test123"); XCTFail("无凭据不能请求分享") }
        catch { XCTAssertTrue(error.localizedDescription.contains("登录")) }
    }
}

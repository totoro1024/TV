import XCTest
import CryptoKit
@testable import TVCore

private actor App99Transport: HTTPTransport {
    var paths: [String] = []
    func send(_ request: URLRequest) async throws -> HTTPReply {
        let uuid = request.value(forHTTPHeaderField: "uuid")!
        let key = Data(uuid.replacingOccurrences(of: "-", with: "").utf8)
        let body = String(data: request.httpBody!, encoding: .utf8)!
        let bytes = Data(base64Encoded: body)!
        let params = try JSON.parse(App99Crypto.aes(Data(bytes.dropFirst(16)), key: key, iv: Data(bytes.prefix(16)), encrypt: false))
        let input = "\(body):\(params["timestamp"].string):\(params["nonce"].string)::synthetic"
        let signature = SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(request.value(forHTTPHeaderField: "sign"), signature)
        let path = request.url!.path; paths.append(path)
        let response: JSON
        if path.hasSuffix("systemInit") {
            response = .object(["player":.object(["line":.object(["name":.string("测试线路"),"headers":.string("{\"Referer\":\"https://example.test/\"}")])])])
        } else if path.hasSuffix("detail") {
            response = .object(["data":.object(["id":.integer(1),"name":.string("测试"),"play_from":.string("line"),"play_url":.string("第1集$https://example.test/a.mp4?x=@1")])])
        } else if path.hasSuffix("search") {
            response = .object(["data":.array([.object(["id":.integer(1),"name":.string("测试")])])])
        } else { response = .object([:]) }
        let iv = Data(repeating: 1, count: 16)
        let encrypted = try App99Crypto.aes(response.data, key: key, iv: iv, encrypt: true)
        return HTTPReply(status: 200, body: Data((iv + encrypted).base64EncodedString().utf8))
    }
}
final class App99Tests: XCTestCase {
    func testEncryptedBrowseDetailAndPlaybackKeepIdentityAndHeaders() async throws {
        let client = App99Client(transport: App99Transport())
        let config: JSON = .object(["host":.string("https://example.test"),"appkey":.string("synthetic")])
        let source = MediaSource(id: "视界", sourceID: "original", name: "茉莉", address: "csp_App99Guard", kind: .app99, ext: config)
        let items = try await client.browse(source, keyword: "测试", page: 1)
        XCTAssertEqual(items.first?.id, "1")
        let detail = try await client.detail(source, id: "1")
        XCTAssertEqual(detail.episodes.first?.line, "测试线路")
        let media = try await client.resolve(source, episode: XCTUnwrap(detail.episodes.first))
        XCTAssertEqual(media.url, "https://example.test/a.mp4?x=@1")
        XCTAssertEqual(media.headers["Referer"], "https://example.test/")
    }
    func testNativeSitesAreEnabledAndConfigurationIsPreserved() throws {
        let data = Data(#"{"sites":[{"key":"视界","type":3,"api":"csp_App99Guard","ext":{"host":"https://example.test"}},{"key":"玩偶","type":3,"api":"csp_WoGGGuard"}]}"#.utf8)
        let sources = try CatalogParser.configuration(data: data, address: "https://example.test/config", sourceID: "original")
        XCTAssertEqual(sources[0].kind, .app99)
        XCTAssertEqual(sources[0].id, "视界")
        XCTAssertEqual(sources[0].ext["host"].string, "https://example.test")
        XCTAssertEqual(sources[1].kind, .wogg)
    }
    func testAESRoundtripAndInvalidCiphertext() throws {
        let plain = Data("中文 JSON 数据".utf8), key = Data(repeating: 3, count: 32), iv = Data(repeating: 7, count: 16)
        let cipher = try App99Crypto.aes(plain, key: key, iv: iv, encrypt: true)
        XCTAssertEqual(try App99Crypto.aes(cipher, key: key, iv: iv, encrypt: false), plain)
        XCTAssertThrowsError(try App99Crypto.aes(Data([1]), key: key, iv: iv, encrypt: false))
        XCTAssertThrowsError(try App99Crypto.configuration(.string("invalid")))
    }
}

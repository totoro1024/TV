import XCTest
@testable import TVCore

private struct DouDouTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPReply {
        XCTAssertEqual(request.url?.host, "frodo.douban.com")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Referer"))
        XCTAssertTrue(request.url?.query?.contains("start=20") == true)
        return HTTPReply(status: 200, body: Data(#"{"subject_collection_items":[{"id":"1","type":"movie","title":"推荐影片","pic":{"normal":"https://example.test/a.jpg"},"rating":{"value":8.5}}]}"#.utf8))
    }
}
final class DouDouTests: XCTestCase {
    func testNativePluginAndRecommendationPagination() async throws {
        let sites = try CatalogParser.configuration(data: Data(#"{"sites":[{"key":"片单","api":"csp_DouDouGuard","type":3}]}"#.utf8), address: "https://example.test/config", sourceID: "original")
        XCTAssertEqual(sites.first?.kind, .doudou)
        let items = try await DouDouClient(transport: DouDouTransport()).recommendations(page: 2)
        XCTAssertEqual(items.first?.name, "推荐影片")
        XCTAssertEqual(items.first?.remarks, "评分 8.5")
    }
    func testFiltersAdvertisementsAndKeepsNumericIdentity() throws {
        let data = Data(#"{"subject_collection_items":[{"id":123,"type":"tv","title":"剧集","cover_url":"https://example.test/p.jpg"},{"id":2,"type":"ad","title":"广告"},{"id":3,"type":"playlist","title":"合集"},{"id":4,"title":""}]}"#.utf8)
        let items = try DouDouClient.items(data)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, "123")
        XCTAssertEqual(items.first?.picture, "https://example.test/p.jpg")
        XCTAssertThrowsError(try DouDouClient.items(Data(#"{"message":"not a list"}"#.utf8)))
    }
}

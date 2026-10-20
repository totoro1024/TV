import XCTest
@testable import TVCore
final class MediaDetailMetadataTests: XCTestCase {
    func testDetailKeepsAndroidMetadataAndStripsSynopsisMarkup() throws {
        let text=#"{"list":[{"vod_id":"1","vod_name":"测试影片","vod_pic":"","vod_year":2026,"vod_area":"中国大陆","type_name":"剧情","vod_director":"导演甲","vod_actor":"演员乙","vod_content":"<p>简介内容</p>","vod_play_from":"线路1","vod_play_url":"第1集$https://example.test/1.mp4"}]}"#
        let detail=try CatalogParser.detail(Data(text.utf8))
        XCTAssertEqual(detail.metadata["年份"],"2026")
        XCTAssertEqual(detail.metadata["地区"],"中国大陆")
        XCTAssertEqual(detail.metadata["导演"],"导演甲")
        XCTAssertEqual(detail.metadata["演员"],"演员乙")
        XCTAssertEqual(detail.synopsis,"简介内容")
        XCTAssertEqual(detail.episodes.count,1)
    }
    func testMissingMetadataIsNotInvented() throws {
        let detail=try CatalogParser.detail(Data(#"{"list":[{"vod_id":"1","vod_name":"无资料"}]}"#.utf8))
        XCTAssertTrue(detail.metadata.isEmpty)
    }
}

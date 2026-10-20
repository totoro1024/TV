import XCTest
@testable import TVCore
final class ProtocolTests: XCTestCase {
    func testAndroidIdentityVector() {
        XCTAssertEqual(SyncDocument.identity("source", "0", "https://example.test/影视?a=1&b=2"), "9039481f690907dc08356d94c53835454fa5adc0e402964c9108e00c86a653d0")
    }
    func testUnknownNumbersAndFieldsSurvive() throws {
        let data = Data(#"{"huge":123456789012345678901234567890,"decimal":1.000e+3,"future":{"文本":"😀&/"}}"#.utf8)
        let value = try JSON.parse(data)
        XCTAssertEqual(try JSON.parse(value.data), value)
        XCTAssertEqual(value["huge"], .number("123456789012345678901234567890"))
    }
    func testDuplicateKeysAndTruncatedStringsFail() {
        XCTAssertThrowsError(try JSON.parse(Data(#"{"a":1,"a":2}"#.utf8)))
        XCTAssertThrowsError(try JSON.parse(Data(#"{"a":"unterminated"#.utf8)))
        XCTAssertThrowsError(try JSON.parse(Data("01".utf8)))
    }
    func testRecentWatchCanMoveBackwards() throws {
        var a = Replica(); var b = Replica(); b.document.epoch = a.document.epoch
        let id = SyncDocument.identity("history", "source", "site", "vod")
        a.edit(id: id, kind: "history", value: .object(["positionMs":.integer(5000)]), device: "a", now: 100)
        b.edit(id: id, kind: "history", value: .object(["positionMs":.integer(1000)]), device: "b", now: 200)
        XCTAssertEqual(try a.document.merged(with: b.document).records[id]?["value"]["positionMs"].int, 1000)
    }
    func testDeletionPropagatesAndUnknownCloudDataSurvives() throws {
        var a = Replica(); let id = SyncDocument.identity("cloudAccount", "future")
        a.edit(id: id, kind: "cloudAccount", value: .object(["opaque":.string("synthetic")]), device: "a", now: 100)
        var b = a; b.edit(id: "new", kind: "future", value: .object([:]), device: "b", now: 200)
        XCTAssertNotNil(try a.document.merged(with: b.document).records[id])
        b.edit(id: id, kind: "cloudAccount", value: nil, device: "b", now: 300)
        XCTAssertTrue(try a.document.merged(with: b.document).records[id]!["deleted"].flag)
    }
    func testDuplicateVersionFallbackMatchesAndroidCanonicalOrder() throws {
        var a = Replica(), b = Replica(); b.document.epoch = a.document.epoch
        let id = SyncDocument.identity("future")
        a.edit(id: id, kind: "future", value: .object(["z":.integer(0), "a":.integer(1)]), device: "same", now: 100)
        b.edit(id: id, kind: "future", value: .object(["a":.integer(2), "z":.integer(0)]), device: "same", now: 100)
        XCTAssertEqual(try a.document.merged(with: b.document).records[id]?["value"]["a"].int, 2)
    }
    func testJarSourceIsExplicitlyUnsupported() throws {
        let data = Data(#"{"sites":[{"key":"jar","name":"电视源","type":3,"api":"csp_Test"},{"key":"api","name":"JSON","type":1,"api":"https://example.test/api"}]}"#.utf8)
        let sources = try CatalogParser.configuration(data: data, address: "https://example.test/config", sourceID: "source")
        XCTAssertEqual(sources[0].kind, .unsupported); XCTAssertEqual(sources[1].kind, .api)
    }
    func testWrappedCommentedSourceConfiguration() throws {
        let text = """
        { // 电视源注释
          "sites": [
            {"key":"jar","name":"电视源","type":3,"api":"csp_Test"},
            {"key":"api","name":"JSON","type":1,"api":"https://example.test/a//b?x=/*literal*/",},
          ], /* 保留字符串内部的斜杠 */
        }
        """
        var wrapped = Data([0xff, 0xd8, 0xff, 0xe0])
        wrapped.append(Data("abcdefgh**".utf8)); wrapped.append(Data(Data(text.utf8).base64EncodedString().utf8))
        let sources = try CatalogParser.configuration(data: wrapped, address: "https://example.test/config.jpg", sourceID: "source")
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(sources[0].kind, .unsupported)
        XCTAssertEqual(sources[1].address, "https://example.test/a//b?x=/*literal*/")
        XCTAssertEqual(sources[1].kind, .api)
        XCTAssertThrowsError(try JSON.parse(Data(text.utf8)))
    }
    func testSourceBOMAndMalformedComments() throws {
        var bom = Data([0xef, 0xbb, 0xbf]); bom.append(Data(#"{"sites":[{"key":"a","name":"API","type":1,"api":"https://example.test/api"}]}"#.utf8))
        XCTAssertEqual(try CatalogParser.configuration(data: bom, address: "https://example.test/config", sourceID: "source").count, 1)
        XCTAssertThrowsError(try CatalogParser.configuration(data: Data("{/* never closed".utf8), address: "https://example.test/config", sourceID: "source"))
    }
    func testM3URelativeURLsAndGroups() throws {
        let text = "#EXTM3U\n#EXTINF:-1 group-title=\"新闻\",频道一\nstream/live.m3u8\n"
        let channels = try CatalogParser.playlist(Data(text.utf8), base: URL(string: "http://example.test/list.m3u")!)
        XCTAssertEqual(channels.first?.url, "http://example.test/stream/live.m3u8")
        XCTAssertEqual(channels.first?.line, "新闻")
    }
    func testEpisodesKeepQueryAndLineIdentity() throws {
        let data = Data(#"{"list":[{"vod_id":12,"vod_name":"测试","vod_play_from":"线路一$$$线路二","vod_play_url":"第一集$http://example.test/a.m3u8?x=$1$$$第二集$http://example.test/b.mp4"}]}"#.utf8)
        let detail = try CatalogParser.detail(data)
        XCTAssertEqual(detail.item.id, "12"); XCTAssertEqual(detail.episodes.count, 2)
        XCTAssertEqual(detail.episodes[0].url, "http://example.test/a.m3u8?x=$1")
    }
    func testKnownRecordIdentityIsValidatedBeforeUpload() {
        var replica = Replica()
        replica.edit(id: SyncDocument.identity("wrong"), kind: "source", value: .object([
            "url":.string("http://example.test/source"),"type":.integer(0),"name":.string("合成源"),"home":.string("")]), device: "test")
        XCTAssertThrowsError(try replica.document.validate())
    }
    func testEmbeddedCredentialsRejected() {
        XCTAssertThrowsError(try WebDAVClient(settings: .init(address: "http://user:secret@example.test/")))
        XCTAssertFalse(CatalogParser.playable("https://example.test/watch.html"))
    }
}

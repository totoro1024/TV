import XCTest
@testable import TVCore

final class LiveTVTests: XCTestCase {
    private var source: LiveSource { .init(name:"测试直播",address:"https://example.test/live/list.m3u",headers:["User-Agent":"test-agent"]) }
    private func channel() throws -> LiveChannel {
        try LiveParser.channels(Data("#EXTM3U\n#EXTINF:-1 tvg-id=\"cctv1\" tvg-name=\"CCTV1\" catchup=\"append\" catchup-source=\"?start={utc}&end={utcend}\" catchup-days=\"7\",央视一套\nhttps://example.test/live.m3u8?token=test\n".utf8),source:source)[0]
    }
    func testReadsAndroidLiveConfigurationRatherThanVodSites() throws {
        let data=Data(#"{"sites":[{"name":"点播站"}],"lives":[{"name":"综合直播","type":0,"url":"./tv.txt","ua":"TV"},{"name":"内置频道","groups":[{"name":"央视","channel":[{"name":"CCTV1","urls":["https://example.test/1.m3u8"]}]}]}]}"#.utf8)
        let sources=try LiveParser.sources(data,address:"https://example.test/config/source.json")
        XCTAssertEqual(sources.count,2);XCTAssertEqual(sources[0].address,"https://example.test/config/tv.txt")
        XCTAssertEqual(sources[0].headers["User-Agent"],"TV")
        XCTAssertEqual(try LiveParser.channels(Data(),source:sources[1])[0].group,"央视")
    }
    func testM3UMergesRoutesAndPreservesHeadersNumbersLogoAndEPG() throws {
        let text="""
        #EXTM3U url-tvg="https://example.test/epg.xml.gz"
        #EXTINF:-1 tvg-id="one" tvg-name="频道一" tvg-chno="101" tvg-logo="./logo.png" group-title="央视",频道一
        #EXTVLCOPT:http-referrer=https://example.test/
        first.m3u8
        #EXTINF:-1 tvg-id="one" group-title="央视",频道一
        https://example.test/backup.m3u8|User-Agent=Other%20Agent
        """
        let channels=try LiveParser.channels(Data(text.utf8),source:source)
        XCTAssertEqual(channels.count,1);XCTAssertEqual(channels[0].routes.count,2)
        XCTAssertEqual(channels[0].routes[0].url,"https://example.test/live/first.m3u8")
        XCTAssertEqual(channels[0].routes[0].headers["Referer"],"https://example.test/")
        XCTAssertEqual(channels[0].routes[1].headers["User-Agent"],"Other Agent")
        XCTAssertEqual(channels[0].number,"101");XCTAssertEqual(channels[0].epg,"https://example.test/epg.xml.gz")
        XCTAssertEqual(channels[0].logo,"https://example.test/live/logo.png")
    }
    func testTXTGroupsAndMultipleNamedRoutes() throws {
        let text="央视,#genre#\nCCTV1,https://example.test/one.ts$超清#https://example.test/two.m3u8$高清\n卫视,#genre#\n湖南卫视,https://example.test/hunan.m3u8"
        let result=try LiveParser.channels(Data(text.utf8),source:source)
        XCTAssertEqual(result.map(\.group),["央视","卫视"])
        XCTAssertEqual(result[0].routes.map(\.name),["超清","高清"])
        XCTAssertEqual(result[1].number,"2")
    }
    func testJSONChannelHeadersAndNumericChannelNumber() throws {
        let data=Data(#"[{"name":"央视","channel":[{"name":"CCTV1","number":1,"urls":["https://example.test/a.m3u8"],"header":{"Referer":"https://example.test/"}}]}]"#.utf8)
        let result=try LiveParser.channels(data,source:source)
        XCTAssertEqual(result[0].number,"1")
        XCTAssertEqual(result[0].routes[0].headers["User-Agent"],"test-agent")
        XCTAssertEqual(result[0].routes[0].headers["Referer"],"https://example.test/")
    }
    func testEPGRespectsXMLTimezoneAndChannelIdentity() throws {
        let data=Data(#"<?xml version="1.0"?><tv><channel id="cctv1"><display-name>CCTV1</display-name></channel><programme channel="cctv1" start="20261020000000 +0800" stop="20261020010000 +0800"><title>午夜节目</title></programme><programme channel="other" start="20261020000000 +0800" stop="20261020010000 +0800"><title>其他频道</title></programme></tv>"#.utf8)
        let result=try LiveEPGParser.parse(data,channel:channel())
        XCTAssertEqual(result.count,1);XCTAssertEqual(result[0].title,"午夜节目")
        XCTAssertEqual(result[0].end.timeIntervalSince(result[0].start),3600)
        XCTAssertTrue(result[0].isCurrent(result[0].start.addingTimeInterval(5)))
        XCTAssertFalse(result[0].isCurrent(result[0].end))
        let utc=ISO8601DateFormatter().string(from:result[0].start)
        XCTAssertEqual(utc,"2026-10-19T16:00:00Z")
    }
    func testJSONEPGCrossesMidnightAndCatchupUsesExistingQuery() throws {
        let data=Data(#"{"date":"2026-10-19","epg_data":[{"start":"23:30","end":"00:30","title":"跨日节目"}]}"#.utf8)
        let channel=try channel(),program=try XCTUnwrap(LiveEPGParser.parse(data,channel:channel).first)
        XCTAssertEqual(program.end.timeIntervalSince(program.start),3600)
        let url=try LiveEPGParser.catchupURL(channel:channel,route:channel.routes[0],program:program,now:program.end.addingTimeInterval(100))
        XCTAssertTrue(url.hasPrefix("https://example.test/live.m3u8?token=test&start="))
        XCTAssertFalse(url.contains("{"))
        XCTAssertThrowsError(try LiveEPGParser.catchupURL(channel:channel,route:channel.routes[0],program:program,now:program.end.addingTimeInterval(8*86400)))
    }
    func testGZipEPGCanActuallyBeDecoded() throws {
        let data=Data(base64Encoded:"H4sIAAAAAAAC/7MpKbOzKSjKTy9KzM1NVUjOSMzLS82xVUpOLikzVFIoLkksKrFVMjIwMjM0MDKAAAVtAwsDA5BkfgGSnCGSnJ1NSWZJTqqde1RmgY0+hG2jD7cHyAbaCwABMxTBfAAAAA==")!
        let programs=try LiveEPGParser.parse(data,channel:channel())
        XCTAssertEqual(programs.count,1);XCTAssertEqual(programs[0].title,"GZip")
    }
    func testDirectHLSIsOneLiveChannelRatherThanMediaSegments() throws {
        let data=Data("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nsegment1.ts\n#EXTINF:6,\nsegment2.ts\n".utf8)
        let channels=try LiveParser.channels(data,source:source)
        XCTAssertEqual(channels.count,1);XCTAssertEqual(channels[0].routes[0].url,source.address)
    }
    func testNumericSearchUsesChannelNumberRatherThanSubstringOfName() throws {
        let text="央视,#genre#\nCCTV13,https://example.test/a.m3u8\nCCTV15,https://example.test/b.m3u8"
        let channels=try LiveParser.channels(Data(text.utf8),source:source)
        XCTAssertEqual(channels.filter { $0.matches("1") }.map(\.name),["CCTV13"])
        XCTAssertEqual(channels.filter { $0.matches("CCTV15") }.map(\.number),["2"])
        XCTAssertTrue(channels[0].matches("001"))
    }
    func testInvalidAndUnsupportedListsDoNotPretendToHaveChannels() {
        XCTAssertThrowsError(try LiveParser.channels(Data("<html>登录</html>".utf8),source:source))
        XCTAssertFalse(LiveParser.playable("proxy://android-only/channel"))
        XCTAssertFalse(LiveParser.playable("https://user:secret@example.test/a.m3u8"))
        XCTAssertTrue(LiveParser.playable("rtsp://example.test/live"))
        XCTAssertThrowsError(try LiveEPGParser.unpack(Data([0x1f,0x8b,0,1,2,3])))
    }
}

import XCTest
import SwiftSoup
@testable import TVCore
private struct WebsiteFixture:HTTPTransport {
    var body:Data
    func send(_ request:URLRequest) async throws -> HTTPReply { HTTPReply(status:200,body:body) }
}
final class LegacyWebsiteTests:XCTestCase {
    func testAueteCardsKeepAndroidThreePartIdentity() throws {
        let source=MediaSource(id:"s",sourceID:"c",name:"奥特",address:"csp_AueteGuard",kind:.legacySite)
        let doc=try SwiftSoup.parse(#"<ul class="threadlist"><li><a class="pic" href="/Tv/wangju/example/"><img src="/poster.jpg"></a><h2><a title="标题" href="/Tv/wangju/example/">标题</a></h2><span class="hdtag">全8集</span></li></ul>"#,"https://auete.cc/")
        let items=try LegacyWebsiteClient().items(doc,source:source)
        XCTAssertEqual(items.count,1);XCTAssertEqual(items.first?.id,"Tv/wangju/example")
        XCTAssertEqual(items.first?.picture,"https://auete.cc/poster.jpg")
    }
    func testBalancedPlayerObjectAndEncodedURL() throws {
        let html=#"<script>var player_test={"url":"aHR0cHM6Ly9jZG4uZXhhbXBsZS92Lm0zdTg=","encrypt":2,"extra":{"x":"}"}};</script>"#
        XCTAssertEqual(LegacyWebsiteClient.media(in:html,base:URL(string:"https://example.test/play")!),"https://cdn.example/v.m3u8")
        XCTAssertNil(LegacyWebsiteClient.media(in:#"<script>var player_test={"url":"https://example.test/watch.html","encrypt":0};</script>"#,base:URL(string:"https://example.test")!))
    }
    func testFailedPageIsNotSuccessfulEmptyHome() async throws {
        let source=MediaSource(id:"s",sourceID:"c",name:"糯米",address:"csp_NmyswvGuard",kind:.legacySite)
        do { _=try await LegacyWebsiteClient(transport:WebsiteFixture(body:Data("<title>404</title>".utf8))).browse(source);XCTFail("错误页不能当成空首页") } catch { }
    }
    func testDetailsRetainSeparateLinesAndEpisodePages() async throws {
        let html=#"<h1 class="detail-title">节目</h1><div id="player_list" class="play-card"><div class="card-header"><span><b>云播B线</b></span></div><ul class="episode-list"><li><a href="/Tv/wangju/example/play-1-1.html">第一集</a></li></ul></div><div id="player_list" class="play-card"><div class="card-header"><span><b>云播Y线</b></span></div><a href="/Tv/wangju/example/play-2-1.html">第一集</a></div>"#
        let source=MediaSource(id:"s",sourceID:"c",name:"奥特",address:"csp_AueteGuard",kind:.legacySite)
        let detail=try await LegacyWebsiteClient(transport:WebsiteFixture(body:Data(html.utf8))).detail(source,id:"Tv/wangju/example")
        XCTAssertEqual(detail.episodes.map(\.line),["云播B线","云播Y线"])
        XCTAssertEqual(detail.episodes[0].url,"/Tv/wangju/example/play-1-1.html")
    }
}

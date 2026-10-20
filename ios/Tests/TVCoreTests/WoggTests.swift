import XCTest
@testable import TVCore

private let listHTML = #"<html><title>玩偶</title><div class="module-item"><div class="module-item-pic"><a title="剧集 &amp; 第一季" href="/voddetail/123.html"><img data-src="/poster.jpg"></a></div><div class="module-item-text">更新至2集</div></div><div class="module-item"><div class="module-item-pic"><a title="重复" href="/voddetail/123.html"></a></div></div></html>"#
private actor WoggTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPReply {
        XCTAssertEqual(request.url?.host, "wogg.test")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        if request.url!.path.contains("vodsearch") {
            XCTAssertTrue(request.url!.path.contains("2"))
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "wd" }?.value, "中文+剧")
        }
        return HTTPReply(status: 200, body: Data(listHTML.utf8))
    }
}
private actor WoggDirectoryTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPReply {
        XCTAssertEqual(request.url?.host, "drive-pc.quark.cn")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "synthetic=test-only")
        var data: JSON
        if request.url!.path.hasSuffix("token") { data = .object(["stoken":.string("test+token")]) }
        else {
            let parent = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "pdir_fid" }!.value!
            if parent == "0" {
                data = .object(["list":.array([.object(["fid":.string("folder"),"file_name":.string("第一季"),"dir":.bool(true)])])])
            } else {
                data = .object(["list":.array([
                    .object(["fid":.string("f10"),"file_name":.string("第10集.mkv"),"share_fid_token":.string("fresh"),"size":.integer(20),"format_type":.string("image/png")]),
                    .object(["fid":.string("f2"),"file_name":.string("第02集.mkv"),"share_fid_token":.string("fresh")]),
                    .object(["fid":.string("txt"),"file_name":.string("说明.txt"),"share_fid_token":.string("fresh")])])])
            }
        }
        return HTTPReply(status: 200, body: JSON.object(["status":.integer(200),"code":.integer(0),"data":data]).data)
    }
}
final class WoggTests: XCTestCase {
    func testHTMLCardsDeduplicateAndResolvePoster() throws {
        let items = try WoggClient.items(listHTML, base: URL(string: "https://wogg.test/")!)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, "123")
        XCTAssertEqual(items[0].name, "剧集 & 第一季")
        XCTAssertEqual(items[0].picture, "https://wogg.test/poster.jpg")
        XCTAssertEqual(items[0].remarks, "更新至2集")
    }
    func testDetailOnlyReturnsOfficialQuarkSharesAndDeduplicates() throws {
        let html = #"<h1>测试剧</h1><div class="module-row-info"><a data-clipboard-text="https://pan.quark.cn/s/test123">原画</a><a data-clipboard-text="https://pan.quark.cn/s/test123">重复</a><a data-clipboard-text="https://pan.quark.cn.evil.test/s/no">错误域名</a><a href="https://other.test/s/abc">其他网盘</a></div><div class="video-info-content">剧情 <b>简介</b></div>"#
        let detail = try WoggClient.detail(html, id: "123", base: URL(string: "https://wogg.test/")!)
        XCTAssertEqual(detail.item.name, "测试剧")
        XCTAssertEqual(detail.synopsis, "剧情 简介")
        XCTAssertEqual(detail.episodes.count, 1)
        XCTAssertEqual(detail.episodes[0].url, "https://pan.quark.cn/s/test123")
    }
    func testSearchEscapesKeywordAndReadsConfiguredSite() async throws {
        let client = WoggClient(transport: WoggTransport())
        let source = MediaSource(id: "玩偶", sourceID: "s", name: "玩偶", address: "csp_WoGGGuard", kind: .wogg, ext: .object(["siteUrl":.string("https://wogg.test/")]))
        let items = try await client.browse(source, keyword: "中文+剧", page: 2)
        // 合成响应是推荐结构，搜索选择器不能误把它当成搜索结果。
        XCTAssertTrue(items.isEmpty)
    }
    func testShareDirectoryExpandsSeasonsAndKeepsAndroidPayload() async throws {
        let client = QuarkClient(cookie: "synthetic=test-only", transport: WoggDirectoryTransport())
        let episodes = try await client.episodes(shareURL: "https://pan.quark.cn/s/test123", line: "原画", movieName: "测试剧")
        XCTAssertEqual(episodes.count, 2)
        XCTAssertTrue(episodes[0].name.contains("第02集"))
        let payload = try JSON.parse(Data(episodes[1].url.utf8))
        XCTAssertEqual(payload["sId"].string, "test123")
        XCTAssertEqual(payload["pdir_fid"].string, "folder")
        XCTAssertEqual(payload["sToken"].string, "test+token")
        XCTAssertEqual(payload["format_type"].string, "image/png")
        XCTAssertEqual(payload["flag"].string, "夸父盘")
    }
    func testLivePublicWoggHomeCategorySearchAndDetail() async throws {
        guard ProcessInfo.processInfo.environment["TV_WOGG_LIVE"] == "1" else { throw XCTSkip("仅在显式开启时访问公开站点") }
        let client = WoggClient()
        let source = MediaSource(id: "玩偶", sourceID: "live", name: "玩偶", address: "csp_WoGGGuard", kind: .wogg)
        let home = try await client.browse(source)
        XCTAssertGreaterThan(home.count, 0)
        let first = try await client.browse(source, category: "2", page: 1)
        let second = try await client.browse(source, category: "2", page: 2)
        XCTAssertGreaterThan(first.count, 0)
        XCTAssertGreaterThan(second.count, 0)
        XCTAssertNotEqual(first.first?.id, second.first?.id)
        let search = try await client.browse(source, keyword: "嫁金钗")
        XCTAssertTrue(search.contains { $0.name.contains("嫁金钗") })
        let detail = try await client.shareDetail(source, id: XCTUnwrap(search.first?.id))
        XCTAssertGreaterThan(detail.episodes.count, 0)
        print("玩偶公开接口验证：首页\(home.count)条、分类两页\(first.count)/\(second.count)条、搜索\(search.count)条、夸克线路\(detail.episodes.count)条")
    }
}

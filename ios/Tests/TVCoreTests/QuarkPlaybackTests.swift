import XCTest
@testable import TVCore

private actor PlaybackMock: HTTPTransport {
    var paths: [String] = []
    let existing: Bool
    let missing: Bool
    let wrapped: Bool
    let multipleQualities: Bool
    let blockedTranscode: Bool
    let corrupt: Bool
    init(existing: Bool = false, missing: Bool = false, wrapped: Bool = false, corrupt: Bool = false, blockedTranscode: Bool = false, multipleQualities: Bool = false) { self.multipleQualities = multipleQualities; self.blockedTranscode = blockedTranscode; self.existing = existing; self.missing = missing; self.wrapped = wrapped; self.corrupt = corrupt }
    func send(_ request: URLRequest) async throws -> HTTPReply {
        if request.url?.host == "media.example.test" {
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            if request.url?.pathExtension == "m3u8" {
                return HTTPReply(status: blockedTranscode ? 412 : 200, body: Data("#EXTM3U\n#EXT-X-ENDLIST\n".utf8))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-31")
            return HTTPReply(status: 206, body: corrupt ? Data(repeating: 0, count: 32) : wrapped ? Data([137,80,78,71,13,10,26,10,0x1a,0x45,0xdf,0xa3]) : Data([0,0,0,24,102,116,121,112,105,115,111,109]))
        }
        XCTAssertEqual(request.url?.host, "drive-pc.quark.cn")
        let path = request.url!.lastPathComponent
        paths.append(path)
        let body = try request.httpBody.map { try JSON.parse($0) } ?? .null
        var data: JSON = .object([:])
        switch path {
        case "token":
            XCTAssertEqual(body["pwd_id"].string, "share1")
            data = .object(["stoken":.string("new+token")])
        case "detail":
            XCTAssertTrue(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.percentEncodedQuery!.contains("new%2Btoken"))
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "stoken" }?.value, "new+token")
            data = .object(["list":.array(missing ? [] : [.object(["fid":.string("original1"),"share_fid_token":.string("fresh"),"file_name":.string("movie.mkv"),"size":.integer(123),"format_type":.string(wrapped ? "image/png" : "video/mp4")])])])
        case "sort":
            let parent = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "pdir_fid" }!.value!
            if parent == "0" { data = .object(["list":.array([.object(["file_name":.string("影视同步-iPhone"),"dir":.bool(true),"fid":.string("root")])])]) }
            else if parent == "root" { data = .object(["list":.array([])]) }
            else { data = .object(["list":.array(existing ? [.object(["file_name":.string("movie.mkv"),"fid":.string("saved1"),"size":.integer(123)])] : [])]) }
        case "file": data = .object(["fid":.string("folder")])
        case "save":
            XCTAssertEqual(body["fid_list"].array, [.string("original1")])
            XCTAssertEqual(body["fid_token_list"].array, [.string("fresh")])
            data = .object(["task_id":.string("task1")])
        case "task": data = .object(["status":.integer(2),"save_as":.object(["save_as_top_fids":.array([.string("saved1")])])])
        case "download":
            data = .array([.object(["download_url":.string("https://media.example.test/movie.png")])])
        case "play":
            XCTAssertEqual(body["fid"].string, "saved1")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")!.contains("__puus=renewed"))
            var rows: [JSON] = [.object(["resolution":.string("normal"),"video_info":.object(["url":.string("https://media.example.test/movie.m3u8")])])]
            if multipleQualities { rows.append(.object(["resolution":.string("high"),"video_info":.object(["url":.string("https://media.example.test/movie-high.m3u8")])])) }
            data = .object(["video_list":.array(rows)])
        default: XCTFail("不应出现额外请求")
        }
        return HTTPReply(status: 200, body: JSON.object(["status":.integer(200),"code":.integer(0),"data":data]).data, headers: ["Set-Cookie":"__puus=renewed; Path=/; Domain=.quark.cn"])
    }
    func requests() -> [String] { paths }
}
final class QuarkPlaybackTests: XCTestCase {
    private let history = #"{"sId":"share1","fid":"original1","sToken":"old+token","pdir_fid":"parent","share_fid_token":"expired"}"#
    func testOriginalHistoryRefreshesTokenSavesAndResolvesWithoutLeakingCookieToCDN() async throws {
        let mock = PlaybackMock()
        let media = try await QuarkClient(cookie: "__pus=synthetic", transport: mock).resolveHistory(history)
        XCTAssertEqual(media.url, "https://media.example.test/movie.m3u8")
        XCTAssertNil(media.headers["Cookie"])
        let paths = await mock.requests()
        XCTAssertTrue(paths.contains("save")); XCTAssertTrue(paths.contains("task"))
    }
    func testExistingExactFileIsReusedWithoutSavingAgain() async throws {
        let mock = PlaybackMock(existing: true)
        _ = try await QuarkClient(cookie: "__pus=synthetic", transport: mock).resolveHistory(history)
        let paths = await mock.requests()
        XCTAssertFalse(paths.contains("save"))
    }
    func testWrappedMKVUsesOriginalStreamWithValidatedEightByteOffset() async throws {
        let mock = PlaybackMock(existing: true, wrapped: true)
        let media = try await QuarkClient(cookie: "__pus=synthetic", transport: mock).resolveHistory(history)
        XCTAssertTrue(media.useVLC)
        XCTAssertEqual(media.byteOffset, 8)
        XCTAssertEqual(media.size, 123)
        let paths = await mock.requests()
        XCTAssertTrue(paths.contains("download")); XCTAssertFalse(paths.contains("play"))
    }
    func testQuarkHistorySurvivesLineRenameAndTokenRefresh() {
        let old: JSON = .object(["episode":.string("Android 剧集名"), "line":.string("夸克 1 · 夸克 1"), "episodeUrl":.string(history)])
        let episode = Episode(name: "iPhone 剧集名", url: #"{"sId":"share1","fid":"original1","sToken":"renewed"}"#, line: "夸父原1")
        XCTAssertTrue(episode.matchesHistory(old))
        XCTAssertFalse(Episode(name: episode.name, url: #"{"sId":"other","fid":"original1"}"#, line: episode.line).matchesHistory(old))
        XCTAssertFalse(Episode(name: episode.name, url: #"{"sId":"share1","fid":"other"}"#, line: episode.line).matchesHistory(old))
        XCTAssertFalse(Episode(name: "", url: "{}", line: "").matchesHistory(old))
    }
    func testNormalVideoOriginalLineKeepsAllBytesAndAvoidsTranscode() async throws {
        let mock = PlaybackMock(existing: true)
        let media = try await QuarkClient(cookie: "__pus=synthetic", transport: mock).resolveHistory(history, preferOriginal: true)
        XCTAssertTrue(media.useVLC)
        XCTAssertEqual(media.byteOffset, 0)
        XCTAssertEqual(media.size, 123)
        XCTAssertNil(media.headers["Cookie"])
        let paths = await mock.requests()
        XCTAssertTrue(paths.contains("download"))
        XCTAssertTrue(paths.contains("play"))
    }
    func testBlockedSmartLineFallsBackToOriginalWithoutSendingCookieToCDN() async throws {
        let mock = PlaybackMock(existing: true, blockedTranscode: true)
        let media = try await QuarkClient(cookie: "__pus=synthetic", transport: mock).resolveHistory(history)
        XCTAssertTrue(media.useVLC)
        XCTAssertEqual(media.byteOffset, 0)
        let paths = await mock.requests()
        XCTAssertTrue(paths.contains("play"))
        XCTAssertTrue(paths.contains("download"))
    }
    func testExplicitQualityUsesActualRequestedVariant() async throws {
        let mock=PlaybackMock(existing:true,multipleQualities:true)
        let media=try await QuarkClient(cookie:"__pus=synthetic",transport:mock).resolveHistory(history,resolution:"high")
        XCTAssertEqual(media.qualityID,"high")
        XCTAssertEqual(media.url,"https://media.example.test/movie-high.m3u8")
        XCTAssertEqual(media.qualities.map(\.id),["original","normal","high"])
        XCTAssertFalse(media.useVLC)
        XCTAssertNil(media.headers["Cookie"])
    }
    func testRejectedExplicitQualityNeverSilentlyReplacesWithOriginal() async {
        let mock=PlaybackMock(existing:true,blockedTranscode:true)
        do {
            _=try await QuarkClient(cookie:"__pus=synthetic",transport:mock).resolveHistory(history,resolution:"normal")
            XCTFail("指定档位被拒绝时应保留原播放并报告失败")
        } catch { XCTAssertTrue(error.localizedDescription.contains("HTTP 412")) }
        let paths=await mock.requests()
        XCTAssertFalse(paths.contains("download"))
    }
    func testQualityListRejectsInvalidAddressesAndDeduplicates() {
        let rows:[JSON]=[
            .object(["resolution":.string("high"),"video_info":.object(["url":.string("https://example.test/high.m3u8")])]),
            .object(["resolution":.string("high"),"video_info":.object(["url":.string("https://example.test/duplicate.m3u8")])]),
            .object(["resolution":.string("4k"),"video_info":.object(["url":.string("javascript:test")])])]
        XCTAssertEqual(StreamQuality.quark(rows),[.init(id:"high",name:"高清")])
    }
    func testUnexpectedWrapperNeverStripsArbitraryBytes() async {
        do { _ = try await QuarkClient(cookie: "__pus=synthetic", transport: PlaybackMock(existing: true, wrapped: true, corrupt: true)).resolveHistory(history); XCTFail("未知封装应拒绝") } catch { }
    }
    func testMissingOriginalFileNeverSavesAnUnrelatedMovie() async {
        let mock = PlaybackMock(missing: true)
        do { _ = try await QuarkClient(cookie: "__pus=synthetic", transport: mock).resolveHistory(history); XCTFail("文件不存在应失败") } catch { }
        let paths = await mock.requests()
        XCTAssertEqual(paths, ["token","detail"])
    }
}

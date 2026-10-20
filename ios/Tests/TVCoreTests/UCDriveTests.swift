import XCTest
@testable import TVCore

private actor UCTransport: HTTPTransport {
    let replacement: Bool
    init(replacement: Bool = false) { self.replacement = replacement }
    func send(_ request: URLRequest) async throws -> HTTPReply {
        if request.url?.host == "media.example.test" {
            XCTAssertNil(request.value(forHTTPHeaderField:"Cookie"))
            return HTTPReply(status:206,body:Data([0,0,0,24,102,116,121,112,105,115,111,109]),headers:["content-range": replacement ? "bytes 0-11/99" : "bytes 0-11/123"])
        }
        XCTAssertEqual(request.url?.host,"pc-api.uc.cn")
        XCTAssertEqual(request.value(forHTTPHeaderField:"Cookie"),"__pus=uc-test")
        XCTAssertEqual(request.value(forHTTPHeaderField:"Referer"),request.url!.lastPathComponent == "download" ? "https://pc-api.uc.cn/" : "https://drive.uc.cn/")
        let query=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!
        XCTAssertEqual(query.first{$0.name=="pr"}?.value,"UCBrowser")
        let path=request.url!.lastPathComponent
        var data:JSON = .object([:])
        switch path {
        case "token":data = .object(["stoken":.string("uc+token")])
        case "detail":
            XCTAssertEqual(query.first{$0.name=="stoken"}?.value,"uc+token")
            data = .object(["list":.array([.object(["fid":.string("f1"),"file_name":.string("测试.mp4"),"share_fid_token":.string("synthetic"),"size":.integer(123)])])])
        case "sort":data = .object(["list":.array([])])
        case "file":data = .object(["fid":.string("folder")])
        case "save":data = .object(["task_id":.string("task")])
        case "task":data = .object(["status":.integer(2),"save_as":.object(["save_as_top_fids":.array([.string("saved")])])])
        case "download":data = .array([.object(["download_url":.string("https://media.example.test/video.mp4")])])
        default:XCTFail("UC 不应调用夸克转码接口")
        }
        return HTTPReply(status:200,body:JSON.object(["status":.integer(200),"code":.integer(0),"data":data]).data)
    }
}
final class UCDriveTests:XCTestCase {
    func testUCShareDirectoryAndOriginalPlaybackUseOnlyUCCredential() async throws {
        let detail=try await CloudSearchClient(transport:UCTransport()).detail(id:"https://drive.uc.cn/s/share1",cookie:"__pus=quark-do-not-send",ucCookie:"__pus=uc-test")
        XCTAssertEqual(detail.episodes.count,1)
        let episode=try XCTUnwrap(detail.episodes.first)
        XCTAssertEqual(episode.line,"优汐原1")
        XCTAssertEqual(CloudDrive.episode(episode.url),.uc)
        let media=try await QuarkClient(cookie:"__pus=uc-test",transport:UCTransport(),drive:.uc).resolveHistory(episode.url)
        XCTAssertTrue(media.useVLC)
        XCTAssertNil(media.headers["Cookie"])
        XCTAssertEqual(media.qualityID,"original")
    }
    func testUCReplacementVideoIsRejectedBeforeStartingPlayer() async throws {
        let transport = UCTransport(replacement: true)
        let detail = try await CloudSearchClient(transport: transport).detail(id:"https://drive.uc.cn/s/share1",cookie:nil,ucCookie:"__pus=uc-test")
        do {
            _ = try await QuarkClient(cookie:"__pus=uc-test",transport:transport,drive:.uc).resolveHistory(detail.episodes[0].url)
            XCTFail("替代提示视频不能被当成原文件交给播放器")
        } catch { XCTAssertTrue(error.localizedDescription.contains("原文件")) }
    }
    func testMissingUCCookieDoesNotReuseQuarkLogin() async {
        do {
            _ = try await CloudSearchClient(transport:UCTransport()).detail(id:"https://drive.uc.cn/s/share1",cookie:"__pus=quark-test")
            XCTFail("UC 不能复用夸克登录")
        } catch { XCTAssertTrue(error.localizedDescription.contains("UC Cookie")) }
    }
    func testUCCookieSeparateAndDeletionApplied() throws {
        var replica=Replica()
        let id=SyncDocument.identity("cloudAccount","catvod-sp-utils-v1")
        replica.edit(id:id,kind:"cloudAccount",value:.object(["adapter":.string("catvod-sp-utils-v1"),"prefs":.object(["uc_ck":.string("__pus=uc-test"),"quark_ck":.string("__pus=quark-test")])]),device:"test",now:100)
        XCTAssertEqual(try SyncedQuarkAccount.cookie(in:replica.document,drive:.uc),"__pus=uc-test")
        XCTAssertEqual(try SyncedQuarkAccount.cookie(in:replica.document),"__pus=quark-test")
        replica.edit(id:id,kind:"cloudAccount",value:nil,device:"test",now:200)
        XCTAssertNil(try SyncedQuarkAccount.cookie(in:replica.document,drive:.uc))
    }
    func testUCShareHostCannotSendCredentialToOtherSites() throws {
        XCTAssertEqual(try QuarkClient.shareID("https://drive.uc.cn/s/share1",drive:.uc),"share1")
        for value in ["https://drive.uc.cn.evil.test/s/share1","https://pan.quark.cn/s/share1","http://drive.uc.cn/s/share1"] {
            XCTAssertThrowsError(try QuarkClient.shareID(value,drive:.uc))
        }
    }
    func testWoggIncludesUCShare() throws {
        let html = #"<h1>测试</h1><div class="module-row-info"><a href="https://drive.uc.cn/s/share1">UC</a></div>"#
        let detail=try WoggClient.detail(html,id:"1",base:URL(string:"https://example.test/")!)
        XCTAssertEqual(detail.episodes.first?.url,"https://drive.uc.cn/s/share1")
    }
}

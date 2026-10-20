// 自动从 Tests/TVCoreTests 生成；修改测试后运行 scripts/generate-checks.py。
import Foundation
import TVCore
final class ProtocolTests {
    func testAndroidIdentityVector() {
        checkEqual(SyncDocument.identity("source", "0", "https://example.test/影视?a=1&b=2"), "9039481f690907dc08356d94c53835454fa5adc0e402964c9108e00c86a653d0")
    }
    func testUnknownNumbersAndFieldsSurvive() throws {
        let data = Data(#"{"huge":123456789012345678901234567890,"decimal":1.000e+3,"future":{"文本":"😀&/"}}"#.utf8)
        let value = try JSON.parse(data)
        checkEqual(try JSON.parse(value.data), value)
        checkEqual(value["huge"], .number("123456789012345678901234567890"))
    }
    func testDuplicateKeysAndTruncatedStringsFail() {
        checkThrows(try JSON.parse(Data(#"{"a":1,"a":2}"#.utf8)))
        checkThrows(try JSON.parse(Data(#"{"a":"unterminated"#.utf8)))
        checkThrows(try JSON.parse(Data("01".utf8)))
    }
    func testRecentWatchCanMoveBackwards() throws {
        var a = Replica(); var b = Replica(); b.document.epoch = a.document.epoch
        let id = SyncDocument.identity("history", "source", "site", "vod")
        a.edit(id: id, kind: "history", value: .object(["positionMs":.integer(5000)]), device: "a", now: 100)
        b.edit(id: id, kind: "history", value: .object(["positionMs":.integer(1000)]), device: "b", now: 200)
        checkEqual(try a.document.merged(with: b.document).records[id]?["value"]["positionMs"].int, 1000)
    }
    func testDeletionPropagatesAndUnknownCloudDataSurvives() throws {
        var a = Replica(); let id = SyncDocument.identity("cloudAccount", "future")
        a.edit(id: id, kind: "cloudAccount", value: .object(["opaque":.string("synthetic")]), device: "a", now: 100)
        var b = a; b.edit(id: "new", kind: "future", value: .object([:]), device: "b", now: 200)
        checkNotNil(try a.document.merged(with: b.document).records[id])
        b.edit(id: id, kind: "cloudAccount", value: nil, device: "b", now: 300)
        checkTrue(try a.document.merged(with: b.document).records[id]!["deleted"].flag)
    }
    func testDuplicateVersionFallbackMatchesAndroidCanonicalOrder() throws {
        var a = Replica(), b = Replica(); b.document.epoch = a.document.epoch
        let id = SyncDocument.identity("future")
        a.edit(id: id, kind: "future", value: .object(["z":.integer(0), "a":.integer(1)]), device: "same", now: 100)
        b.edit(id: id, kind: "future", value: .object(["a":.integer(2), "z":.integer(0)]), device: "same", now: 100)
        checkEqual(try a.document.merged(with: b.document).records[id]?["value"]["a"].int, 2)
    }
    func testJarSourceIsExplicitlyUnsupported() throws {
        let data = Data(#"{"sites":[{"key":"jar","name":"电视源","type":3,"api":"csp_Test"},{"key":"api","name":"JSON","type":1,"api":"https://example.test/api"}]}"#.utf8)
        let sources = try CatalogParser.configuration(data: data, address: "https://example.test/config", sourceID: "source")
        checkEqual(sources[0].kind, .unsupported); checkEqual(sources[1].kind, .api)
    }
    func testM3URelativeURLsAndGroups() throws {
        let text = "#EXTM3U\n#EXTINF:-1 group-title=\"新闻\",频道一\nstream/live.m3u8\n"
        let channels = try CatalogParser.playlist(Data(text.utf8), base: URL(string: "http://example.test/list.m3u")!)
        checkEqual(channels.first?.url, "http://example.test/stream/live.m3u8")
        checkEqual(channels.first?.line, "新闻")
    }
    func testEpisodesKeepQueryAndLineIdentity() throws {
        let data = Data(#"{"list":[{"vod_id":12,"vod_name":"测试","vod_play_from":"线路一$$$线路二","vod_play_url":"第一集$http://example.test/a.m3u8?x=$1$$$第二集$http://example.test/b.mp4"}]}"#.utf8)
        let detail = try CatalogParser.detail(data)
        checkEqual(detail.item.id, "12"); checkEqual(detail.episodes.count, 2)
        checkEqual(detail.episodes[0].url, "http://example.test/a.m3u8?x=$1")
    }
    func testKnownRecordIdentityIsValidatedBeforeUpload() {
        var replica = Replica()
        replica.edit(id: SyncDocument.identity("wrong"), kind: "source", value: .object([
            "url":.string("http://example.test/source"),"type":.integer(0),"name":.string("合成源"),"home":.string("")]), device: "test")
        checkThrows(try replica.document.validate())
    }
    func testEmbeddedCredentialsRejected() {
        checkThrows(try WebDAVClient(settings: .init(address: "http://user:secret@example.test/")))
        checkFalse(CatalogParser.playable("https://example.test/watch.html"))
    }
}

import Foundation
import TVCore
actor FakeDAV: HTTPTransport {
    var document: Data?, version = 1, conflicts = 0, writes = 0
    var probe: [String: Data] = [:]
    func set(_ doc: SyncDocument?) { document = doc?.raw.data }
    func conflictOnce() { conflicts = 1 }
    func send(_ request: URLRequest) async throws -> HTTPReply {
        let method = request.httpMethod ?? "GET", name = request.url!.lastPathComponent
        if method == "MKCOL" { return HTTPReply(status: 405) }
        let state = name == "state.json"
        if method == "GET" {
            let value = state ? document : probe[name]
            return HTTPReply(status: value == nil ? 404 : 200, body: value ?? Data(), headers: ["etag":"\"v\(version)\""])
        }
        if method == "DELETE" { probe.removeValue(forKey: name); return HTTPReply(status: 204) }
        if method == "PUT" {
            if state && conflicts > 0 { conflicts -= 1; return HTTPReply(status: 412) }
            if let condition = request.value(forHTTPHeaderField: "If-Match"), condition != "\"v\(version)\"" { return HTTPReply(status: 412) }
            if request.value(forHTTPHeaderField: "If-None-Match") == "*" && (state ? document != nil : probe[name] != nil) { return HTTPReply(status: 412) }
            if state { document = request.httpBody; writes += 1 } else { probe[name] = request.httpBody }
            version += 1; return HTTPReply(status: 201)
        }
        return HTTPReply(status: 400)
    }
}
final class SyncEngineTests {
    func engine(_ server: FakeDAV) throws -> SyncEngine {
        SyncEngine(client: try WebDAVClient(settings: .init(address: "http://example.test/dav", username: "synthetic", password: "test-only"), transport: server))
    }
    func testCreatesAndRetriesStaleETag() async throws {
        let server = FakeDAV(); await server.conflictOnce()
        let result = try await engine(server).run(.sync, replica: Replica())
        checkEqual(result.message, "同步成功")
        let count = await server.writes; checkEqual(count, 1)
    }
    func testPullMergeDoesNotUpload() async throws {
        let server = FakeDAV(); var remote = SyncDocument(); let local = Replica(); remote.epoch = local.document.epoch
        await server.set(remote)
        _ = try await engine(server).run(.merge, replica: local)
        let count = await server.writes; checkEqual(count, 0)
    }
    func testMergingAnEmptyNewRemoteDoesNotCauseFalseReset() async throws {
        let server = FakeDAV()
        let merged = try await engine(server).run(.merge, replica: Replica())
        checkTrue(merged.replica.acknowledgedEpoch.isEmpty)
        let synced = try await engine(server).run(.sync, replica: merged.replica)
        checkFalse(synced.replica.paused)
    }
    func testRemoteClearRequiresExplicitConsent() async throws {
        let server = FakeDAV(); var remote = SyncDocument(); remote.mode = "reset"; remote.reset = remote.epoch
        await server.set(remote)
        let result = try await engine(server).run(.sync, replica: Replica())
        checkTrue(result.replica.paused); checkFalse(result.install)
        let count = await server.writes; checkEqual(count, 0)
    }
    func testMissingPreviouslySeenRemotePausesInsteadOfReuploading() async throws {
        let server = FakeDAV(); var replica = Replica(); replica.acknowledgedEpoch = "seen"
        let result = try await engine(server).run(.sync, replica: replica)
        checkTrue(result.replica.paused)
    }
    func testReplacementIsNotAppliedDuringPlayback() async throws {
        let server = FakeDAV(); var remote = SyncDocument(); remote.mode = "replace"; await server.set(remote)
        do { _ = try await engine(server).run(.sync, replica: Replica(), playing: true); checkFail("播放时应拒绝覆盖") }
        catch { checkTrue(error.localizedDescription.contains("退出播放")) }
    }
    func testClearDoesNotDeleteLocalRecords() async throws {
        let server = FakeDAV(); var replica = Replica()
        replica.edit(id: SyncDocument.identity("future"), kind: "future", value: .object(["opaque":.string("test")]), device: "test")
        let result = try await engine(server).run(.clear, replica: replica)
        checkTrue(result.replica.paused); checkEqual(result.replica.document.records.count, 1)
    }
    func testProbeCleansTemporaryFile() async throws {
        let server = FakeDAV(); try await engine(server).client.test()
        let files = await server.probe; checkTrue(files.isEmpty)
    }
}

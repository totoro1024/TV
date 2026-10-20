import XCTest
@testable import TVCore
actor FakeDAV: HTTPTransport {
    var document: Data?, version = 1, conflicts = 0, writes = 0
    var probe: [String: Data] = [:]
    var notModified = 0
    var failWrites = false
    func setFailWrites(_ value: Bool) { failWrites = value }
    func set(_ doc: SyncDocument?) { document = doc?.raw.data; version += 1 }
    func conflictOnce() { conflicts = 1 }
    func send(_ request: URLRequest) async throws -> HTTPReply {
        let method = request.httpMethod ?? "GET", name = request.url!.lastPathComponent
        if method == "MKCOL" { return HTTPReply(status: 405) }
        let state = name == "state.json"
        if method == "GET" {
            let value = state ? document : probe[name]
            if value != nil && request.value(forHTTPHeaderField: "If-None-Match") == "\"v\(version)\"" {
                notModified += 1; return HTTPReply(status: 304)
            }
            return HTTPReply(status: value == nil ? 404 : 200, body: value ?? Data(), headers: ["etag":"\"v\(version)\""])
        }
        if method == "DELETE" { probe.removeValue(forKey: name); return HTTPReply(status: 204) }
        if method == "PUT" {
            if failWrites { return HTTPReply(status: 503) }
            if state && conflicts > 0 { conflicts -= 1; return HTTPReply(status: 412) }
            if let condition = request.value(forHTTPHeaderField: "If-Match"), condition != "\"v\(version)\"" { return HTTPReply(status: 412) }
            if request.value(forHTTPHeaderField: "If-None-Match") == "*" && (state ? document != nil : probe[name] != nil) { return HTTPReply(status: 412) }
            if state { document = request.httpBody; writes += 1 } else { probe[name] = request.httpBody }
            version += 1; return HTTPReply(status: 201)
        }
        return HTTPReply(status: 400)
    }
}
final class SyncEngineTests: XCTestCase {
    func engine(_ server: FakeDAV) throws -> SyncEngine {
        SyncEngine(client: try WebDAVClient(settings: .init(address: "http://example.test/dav", username: "synthetic", password: "test-only"), transport: server))
    }
    func testIdleSyncUsesConditionalGetWithoutUploading() async throws {
        let server = FakeDAV(), engine = try engine(server)
        let first = try await engine.run(.sync, replica: Replica())
        _ = try await engine.run(.sync, replica: first.replica)
        _ = try await engine.run(.sync, replica: first.replica)
        let writes = await server.writes, unchanged = await server.notModified
        XCTAssertEqual(writes, 1); XCTAssertGreaterThan(unchanged, 0)
    }
    func testFailedUploadSurvivesRestartAndRetriesWithoutLosingProgress() async throws {
        let server = FakeDAV(), engine = try engine(server)
        var local = Replica()
        let id = SyncDocument.identity("future")
        local.edit(id: id, kind: "future", value: .object(["positionMs":.integer(120_000)]), device: "phone")
        await server.setFailWrites(true)
        do { _ = try await engine.run(.sync, replica: local); XCTFail("必须上传失败") } catch { }
        var restarted = try Replica(json: JSON.parse(local.json.data))
        XCTAssertTrue(restarted.pendingUpload)
        await server.setFailWrites(false)
        restarted = try await engine.run(.sync, replica: restarted).replica
        XCTAssertFalse(restarted.pendingUpload)
        XCTAssertEqual(restarted.document.records[id]?["value"]["positionMs"].int,120_000)
    }
    func testMergeOnlyKeepsLocalChangesPending() async throws {
        let server = FakeDAV(), engine = try engine(server)
        var local = Replica()
        local.edit(id: SyncDocument.identity("future"), kind: "future", value: .object([:]), device: "phone")
        await server.set(SyncDocument())
        let outcome = try await engine.run(.merge, replica: local)
        XCTAssertTrue(outcome.replica.pendingUpload)
    }
    func testIncomingPositionIsDeferredAndNewEditsDuringUploadRemainPending() async throws {
        let server = FakeDAV(), engine = try engine(server)
        let id = SyncDocument.identity("future")
        var local = Replica()
        local.edit(id:id,kind:"future",value:.object(["positionMs":.integer(10_000)]),device:"phone",now:100)
        local = try await engine.run(.sync,replica:local).replica
        var remote = local
        remote.edit(id:id,kind:"future",value:.object(["positionMs":.integer(90_000)]),device:"tv",now:200)
        await server.set(remote.document)
        let outcome = try await engine.run(.sync,replica:local,playing:true)
        let applied = try outcome.applying(to:local,playing:true)
        XCTAssertEqual(applied.replica.document.records[id]?["value"]["positionMs"].int,10_000)
        XCTAssertEqual(applied.deferred?.records[id]?["value"]["positionMs"].int,90_000)
        var afterExit = applied.replica
        try afterExit.applyDeferred(applied.deferred!)
        XCTAssertEqual(afterExit.document.records[id]?["value"]["positionMs"].int,90_000)
        local.edit(id:id,kind:"future",value:.object(["positionMs":.integer(120_000)]),device:"phone",now:300)
        let duringRequest = try outcome.applying(to:local,playing:true)
        XCTAssertTrue(duringRequest.replica.pendingUpload)
        var latestAfterExit = duringRequest.replica
        try latestAfterExit.applyDeferred(duringRequest.deferred!)
        XCTAssertEqual(latestAfterExit.document.records[id]?["value"]["positionMs"].int,120_000)
        let retried = try await engine.run(.sync,replica:latestAfterExit)
        XCTAssertFalse(retried.replica.pendingUpload)
        XCTAssertEqual(retried.replica.document.records[id]?["value"]["positionMs"].int,120_000)
    }
    func testCreatesAndRetriesStaleETag() async throws {
        let server = FakeDAV(); await server.conflictOnce()
        let result = try await engine(server).run(.sync, replica: Replica())
        XCTAssertEqual(result.message, "同步成功")
        let count = await server.writes; XCTAssertEqual(count, 1)
    }
    func testPullMergeDoesNotUpload() async throws {
        let server = FakeDAV(); var remote = SyncDocument(); let local = Replica(); remote.epoch = local.document.epoch
        await server.set(remote)
        _ = try await engine(server).run(.merge, replica: local)
        let count = await server.writes; XCTAssertEqual(count, 0)
    }
    func testMergingAnEmptyNewRemoteDoesNotCauseFalseReset() async throws {
        let server = FakeDAV()
        let merged = try await engine(server).run(.merge, replica: Replica())
        XCTAssertTrue(merged.replica.acknowledgedEpoch.isEmpty)
        let synced = try await engine(server).run(.sync, replica: merged.replica)
        XCTAssertFalse(synced.replica.paused)
    }
    func testRemoteClearRequiresExplicitConsent() async throws {
        let server = FakeDAV(); var remote = SyncDocument(); remote.mode = "reset"; remote.reset = remote.epoch
        await server.set(remote)
        let result = try await engine(server).run(.sync, replica: Replica())
        XCTAssertTrue(result.replica.paused); XCTAssertFalse(result.install)
        let count = await server.writes; XCTAssertEqual(count, 0)
    }
    func testMissingPreviouslySeenRemotePausesInsteadOfReuploading() async throws {
        let server = FakeDAV(); var replica = Replica(); replica.acknowledgedEpoch = "seen"
        let result = try await engine(server).run(.sync, replica: replica)
        XCTAssertTrue(result.replica.paused)
    }
    func testReplacementIsNotAppliedDuringPlayback() async throws {
        let server = FakeDAV(); var remote = SyncDocument(); remote.mode = "replace"; await server.set(remote)
        do { _ = try await engine(server).run(.sync, replica: Replica(), playing: true); XCTFail("播放时应拒绝覆盖") }
        catch { XCTAssertTrue(error.localizedDescription.contains("退出播放")) }
    }
    func testClearDoesNotDeleteLocalRecords() async throws {
        let server = FakeDAV(); var replica = Replica()
        replica.edit(id: SyncDocument.identity("future"), kind: "future", value: .object(["opaque":.string("test")]), device: "test")
        let result = try await engine(server).run(.clear, replica: replica)
        XCTAssertTrue(result.replica.paused); XCTAssertEqual(result.replica.document.records.count, 1)
    }
    func testProbeCleansTemporaryFile() async throws {
        let server = FakeDAV(); try await engine(server).client.test()
        let files = await server.probe; XCTAssertTrue(files.isEmpty)
    }
}

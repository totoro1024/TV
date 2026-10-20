import Foundation
import TVCore

enum HTTPChecks {
    static func run(address: String) async throws {
        guard URL(string: address)?.host == "127.0.0.1" else { throw TVError.message("集成校验仅允许隔离的本机服务") }
        let client = try WebDAVClient(settings: .init(address: address, username: "synthetic", password: "test-only"))
        try await client.test()
        let engine = SyncEngine(client: client)
        var replica = Replica()
        let id = SyncDocument.identity("source", "0", "https://example.test/catalog")
        replica.edit(id: id, kind: "source", value: .object(["url":.string("https://example.test/catalog"),"type":.integer(0),"name":.string("合成测试源"),"home":.string("")]), device: "test")
        let first = try await engine.run(.sync, replica: replica)
        let remote = try await client.read()
        checkTrue(remote.document?.records[id] != nil)
        var edited = first.replica
        edited.edit(id: id, kind: "source", value: nil, device: "test", now: SyncDocument.now + 1)
        _ = try await engine.run(.sync, replica: edited)
        let after = try await client.read()
        checkTrue(after.document!.records[id]!["deleted"].flag)
        let stale = try await client.read()
        _ = try await engine.run(.sync, replica: edited)
        do { try await client.write(edited.document, before: stale); checkFail("失效 ETag 应被拒绝") }
        catch DAVFailure.conflict { }
        let redirect = try WebDAVClient(settings: .init(address: address + "/redirect", username: "synthetic", password: "test-only"))
        do { _ = try await redirect.read(); checkFail("应拒绝重定向") }
        catch DAVFailure.status(let status) { checkEqual(status, 302) }
        print("真实本机 HTTP 校验通过：探测清理、创建、读取、删除记录、条件更新、拒绝重定向")
    }
}

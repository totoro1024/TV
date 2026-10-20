import XCTest
@testable import TVCore

private actor DirectoryDAV: HTTPTransport {
    var paths: Set<String> = ["/"]
    func send(_ request: URLRequest) async throws -> HTTPReply {
        let path = request.url!.path
        if paths.contains(path) { return HTTPReply(status: 405) }
        let parent = request.url!.deletingLastPathComponent().path
        guard paths.contains(parent) else { return HTTPReply(status: 409) }
        paths.insert(path)
        return HTTPReply(status: 201)
    }
}
final class DAVFolderTests: XCTestCase {
    func testOptionalUserDirectoryPreservesOldAddressAndRejectsTraversal() throws {
        XCTAssertEqual(try DAVSettings(address: "https://example.test/dav/").directoryAddress(), "https://example.test/dav/")
        XCTAssertEqual(try DAVSettings(address: "https://example.test/dav/", userDirectory: "family/alice").directoryAddress(), "https://example.test/dav/family/alice/")
        for invalid in ["../bob", "a/../b", "%2e%2e", "https://other.test", "a?b"] {
            XCTAssertThrowsError(try DAVSettings(address: "https://example.test/dav/", userDirectory: invalid).directoryAddress())
        }
    }
    func testCreatesMissingUserParentsAndKeepsFoldersSeparate() async throws {
        let server = DirectoryDAV()
        for user in ["alice", "bob", "alice"] {
            let client = try WebDAVClient(settings: .init(address: "https://example.test/dav/" + user + "/"), transport: server)
            try await client.ensureFolder()
        }
        let paths = await server.paths
        XCTAssertTrue(paths.contains("/dav/alice/fongmi-sync-v1"))
        XCTAssertTrue(paths.contains("/dav/bob/fongmi-sync-v1"))
    }
}

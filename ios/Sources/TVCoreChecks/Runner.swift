import Foundation
import TVCore
func checkEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: T) { do { let value = try a(); precondition(value == b, "值不一致") } catch { fatalError("断言抛错") } }
func checkTrue(_ a: @autoclosure () throws -> Bool) { do { let value = try a(); precondition(value, "条件应为真") } catch { fatalError("断言抛错") } }
func checkFalse(_ a: @autoclosure () throws -> Bool) { do { let value = try a(); precondition(!value, "条件应为假") } catch { fatalError("断言抛错") } }
func checkNotNil<T>(_ a: @autoclosure () throws -> T?) { do { let value = try a(); precondition(value != nil, "不应为空") } catch { fatalError("断言抛错") } }
func checkThrows<T>(_ a: @autoclosure () throws -> T) { do { _ = try a() } catch { return }; fatalError("预期拒绝输入") }
func checkFail(_ message: String) { fatalError(message) }
@main struct Runner {
    static func main() async throws {
        if CommandLine.arguments.contains("--uc-login-probe") {
            do {
                let client = UCLoginClient(transport:UCLoginTransport())
                let token = try await client.token()
                let pending = try await client.poll(token:token)
                print("UC 官方二维码已取得；未扫码时等待授权：", pending == nil)
            } catch { print((error as? TVError)?.localizedDescription ?? NetworkIssue.message(error,context:"UC 授权接口")); exit(1) }
            return
        }
        if let index=CommandLine.arguments.firstIndex(of:"--sports-samples"), CommandLine.arguments.indices.contains(index+2) {
            try await SportsSamples.run(config:CommandLine.arguments[index+1],output:CommandLine.arguments[index+2])
            return
        }
        if let index=CommandLine.arguments.firstIndex(of:"--vod-config"), CommandLine.arguments.indices.contains(index+1) {
            try await VODChecks.run(path:CommandLine.arguments[index+1],output:CommandLine.arguments.indices.contains(index+2) ? CommandLine.arguments[index+2] : "/tmp/tv-vod-validation.json")
            return
        }
        if let index=CommandLine.arguments.firstIndex(of:"--live-config"),CommandLine.arguments.indices.contains(index+1) {
            let data=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[index+1]))
            let sources=try LiveParser.sources(data,address:"https://example.invalid/config.json")
            for source in sources {
                do {
                    let channels=try await LiveClient().channels(source)
                    print(source.name+"：\(channels.count) 个频道，\(Set(channels.map(\.group)).count) 个分组，\(channels.reduce(0) { $0+$1.routes.count }) 条线路")
                } catch { print(source.name+"："+((error as? TVError)?.localizedDescription ?? "网络请求失败")) }
            }
            return
        }
        let protocolTests = ProtocolTests()
        let syncEngineTests = SyncEngineTests()
        protocolTests.testAndroidIdentityVector()
        try protocolTests.testUnknownNumbersAndFieldsSurvive()
        protocolTests.testDuplicateKeysAndTruncatedStringsFail()
        try protocolTests.testRecentWatchCanMoveBackwards()
        try protocolTests.testDeletionPropagatesAndUnknownCloudDataSurvives()
        try protocolTests.testDuplicateVersionFallbackMatchesAndroidCanonicalOrder()
        try protocolTests.testJarSourceIsExplicitlyUnsupported()
        try protocolTests.testM3URelativeURLsAndGroups()
        try protocolTests.testEpisodesKeepQueryAndLineIdentity()
        protocolTests.testKnownRecordIdentityIsValidatedBeforeUpload()
        protocolTests.testEmbeddedCredentialsRejected()
        try await syncEngineTests.testCreatesAndRetriesStaleETag()
        try await syncEngineTests.testPullMergeDoesNotUpload()
        try await syncEngineTests.testMergingAnEmptyNewRemoteDoesNotCauseFalseReset()
        try await syncEngineTests.testRemoteClearRequiresExplicitConsent()
        try await syncEngineTests.testMissingPreviouslySeenRemotePausesInsteadOfReuploading()
        try await syncEngineTests.testReplacementIsNotAppliedDuringPlayback()
        try await syncEngineTests.testClearDoesNotDeleteLocalRecords()
        try await syncEngineTests.testProbeCleansTemporaryFile()
        if let address = ProcessInfo.processInfo.environment["TVCORE_LOCAL_DAV"] { try await HTTPChecks.run(address: address) }
        print("19 项核心合同校验通过（独立 Swift 运行器）")
    }
}

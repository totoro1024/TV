import XCTest
@testable import TVCore

final class EpisodeProgressTests: XCTestCase {
    private func value(_ name: String, _ position: Int64, url: String = "") -> JSON {
        .object(["source":.string("source"),"site":.string("site"),"vod":.string("vod"),"line":.string("线路"),"episode":.string(name),"episodeUrl":.string(url),"positionMs":.integer(position),"durationMs":.integer(600_000),"watchedAt":.integer(100)])
    }
    func testDifferentEpisodesMergeAndResumeIndependentlyWhileHistoryHasOneCard() throws {
        var phone = Replica(), tv = Replica(); tv.document.epoch = phone.document.epoch
        let first = value("第1集", 10_000), second = value("第2集", 90_000)
        for (value, device) in [(first,"phone"),(second,"tv")] {
            if device == "phone" {
                phone.edit(id: EpisodeProgress.id(value), kind: EpisodeProgress.kind, value: value, device: device, now: 100)
                phone.edit(id: EpisodeProgress.historyID(value), kind: "history", value: value, device: device, now: 100)
            } else {
                tv.edit(id: EpisodeProgress.id(value), kind: EpisodeProgress.kind, value: value, device: device, now: 200)
                tv.edit(id: EpisodeProgress.historyID(value), kind: "history", value: value, device: device, now: 200)
            }
        }
        let merged = try phone.document.merged(with: tv.document)
        XCTAssertEqual(merged.records.values.filter { $0["kind"].string == "history" }.count, 1)
        XCTAssertEqual(merged.records[EpisodeProgress.historyID(first)]?["value"]["episode"].string, "第2集")
        for (name, position) in [("第1集",Int64(10_000)),("第2集",Int64(90_000))] {
            XCTAssertEqual(EpisodeProgress.value(in: merged, source: "source", site: "site", vod: "vod", episode: Episode(name: name,url: "",line: "线路"))?["positionMs"].int, position)
        }
    }
    func testPausedOldDeviceCannotOverwriteNewerWatchOnExitButIntentionalRewindCan() throws {
        var oldDevice = Replica()
        var old = value("第1集", 10_000); old["watchedAt"] = .integer(100)
        XCTAssertTrue(EpisodeProgress.record(old,in:&oldDevice,device:"tv"))
        let revision = oldDevice.localRevision
        var phone = oldDevice
        var advanced = value("第1集",90_000); advanced["watchedAt"] = .integer(200)
        XCTAssertTrue(EpisodeProgress.record(advanced,in:&phone,device:"phone"))
        var paused = old; paused["watchedAt"] = .integer(300)
        XCTAssertFalse(EpisodeProgress.record(paused,in:&oldDevice,device:"tv"))
        XCTAssertEqual(oldDevice.localRevision,revision)
        var combined = try oldDevice.document.merged(with:phone.document)
        XCTAssertEqual(combined.records[EpisodeProgress.id(old)]?["value"]["positionMs"].int,90_000)
        var rewind = old; rewind["positionMs"] = .integer(5_000); rewind["watchedAt"] = .integer(400)
        XCTAssertTrue(EpisodeProgress.record(rewind,in:&oldDevice,device:"tv"))
        combined = try oldDevice.document.merged(with:phone.document)
        XCTAssertEqual(combined.records[EpisodeProgress.id(old)]?["value"]["positionMs"].int,5_000)
    }
    func testQuarkIdentityIgnoresRouteAndRenewedTokens() {
        let a = EpisodeProgress.key(line: "夸父原1", episode: "Android名称", url: #"{"sId":"share1","fid":"fid1","sToken":"old"}"#)
        let b = EpisodeProgress.key(line: "夸父智1", episode: "iPhone名称", url: #"{"sId":"share1","fid":"fid1","sToken":"new"}"#)
        XCTAssertEqual(a,b)
        let golden: JSON = .object(["source":.string("source"),"site":.string("site"),"vod":.string("vod"),"line":.string("夸父原1"),"episode":.string("Android名称"),"episodeUrl":.string(#"{"sId":"share1","fid":"fid1","sToken":"old"}"#)])
        XCTAssertEqual(EpisodeProgress.id(golden), "a27d2a01d4889587714424a1ee9b937c3876b5ca23140f656f39821fcbeba700")
        XCTAssertEqual(a, SyncDocument.identity("quark","share1","fid1"))
        XCTAssertNotEqual(a, EpisodeProgress.key(line:"夸父原1",episode:"",url:#"{"sId":"share1","fid":"fid2"}"#))
    }
    func testLegacyLatestEpisodeFallbackAndLowerRewatchPosition() throws {
        let old = value("第1集", 90_000)
        var tv = Replica(); tv.edit(id: EpisodeProgress.historyID(old),kind:"history",value:old,device:"tv",now:100)
        let episode=Episode(name:"第1集",url:"",line:"线路")
        XCTAssertEqual(EpisodeProgress.value(in:tv.document,source:"source",site:"site",vod:"vod",episode:episode)?["positionMs"].int,90_000)
        tv.edit(id:EpisodeProgress.id(old),kind:EpisodeProgress.kind,value:old,device:"tv",now:100)
        var phone=tv
        let rewatch=value("第1集",5_000)
        phone.edit(id:EpisodeProgress.id(rewatch),kind:EpisodeProgress.kind,value:rewatch,device:"phone",now:200)
        let merged=try tv.document.merged(with:phone.document)
        XCTAssertEqual(EpisodeProgress.value(in:merged,source:"source",site:"site",vod:"vod",episode:episode)?["positionMs"].int,5_000)
    }
    func testSharedAndroidIPhoneWireFixtureRestoresBothEpisodes() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let document = try SyncDocument(data: Data(contentsOf: root.appendingPathComponent("docs/fixtures/episode-progress-v1.json")))
        let source = SyncDocument.identity("source","0","https://example.invalid/cross-platform.json")
        XCTAssertEqual(document.records.values.filter { $0["kind"].string == "history" }.count,1)
        for (fid, position) in [("fid1",Int64(10_000)),("fid2",Int64(90_000))] {
            let episode = Episode(name:"iPhone名称", url:JSON.object(["sId":.string("share1"),"fid":.string(fid),"sToken":.string("new")]).text,line:"夸父智1")
            XCTAssertEqual(EpisodeProgress.value(in:document,source:source,site:"site",vod:"vod",episode:episode)?["positionMs"].int,position)
        }
        let history = document.records.values.first { $0["kind"].string == "history" }?["value"]
        XCTAssertEqual(PlaybackSkip(value: history).opening, 90)
        XCTAssertEqual(PlaybackSkip(value: history).ending, 60)
        XCTAssertEqual(try SyncDocument(data:document.wireData()),document)
    }
}

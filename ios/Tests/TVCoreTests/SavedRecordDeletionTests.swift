import XCTest
@testable import TVCore

final class SavedRecordDeletionTests:XCTestCase {
    func testSelectedHistoryAndEpisodesAreDeletedAndDeletionMerges() throws {
        var replica = Replica()
        let a:JSON = .object(["source":.string("s"),"site":.string("site"),"vod":.string("a"),"episode":.string("1")])
        var b = a; b["vod"] = .string("b")
        let history = EpisodeProgress.historyID(a), other = EpisodeProgress.historyID(b)
        replica.edit(id:history,kind:"history",value:a,device:"tv",now:10)
        replica.edit(id:other,kind:"history",value:b,device:"tv",now:10)
        replica.edit(id:"ep1",kind:EpisodeProgress.kind,value:a,device:"tv",now:10)
        replica.edit(id:"ep2",kind:EpisodeProgress.kind,value:a,device:"tv",now:10)
        replica.edit(id:"otherEpisode",kind:EpisodeProgress.kind,value:b,device:"tv",now:10)
        replica.edit(id:"favorite",kind:"favorite",value:a,device:"tv",now:10)
        let remote = replica.document
        XCTAssertEqual(replica.removeSaved([history,"favorite","missing"],kind:"history",device:"phone",now:20),1)
        let merged = try remote.merged(with:replica.document)
        for id in [history,"ep1","ep2"] { XCTAssertEqual(merged.records[id]?["deleted"].flag,true) }
        for id in [other,"otherEpisode","favorite"] { XCTAssertEqual(merged.records[id]?["deleted"].flag,false) }
        XCTAssertEqual(replica.removeSaved([history],kind:"history",device:"phone",now:21),0)
    }
    func testFavoritesBatchLeavesHistoryAndSourcesUntouched() {
        var replica = Replica()
        for (id,kind) in [("a","favorite"),("b","favorite"),("c","favorite"),("h","history"),("s","source")] {
            replica.edit(id:id,kind:kind,value:.object(["name":.string(id)]),device:"phone",now:1)
        }
        XCTAssertEqual(replica.removeSaved(["a","b","h","s"],kind:"favorite",device:"phone",now:2),2)
        for id in ["c","h","s"] { XCTAssertEqual(replica.document.records[id]?["deleted"].flag,false) }
        XCTAssertTrue(replica.pendingUpload)
        XCTAssertEqual(replica.removeSaved(["s"],kind:"source",device:"phone"),0)
    }
}

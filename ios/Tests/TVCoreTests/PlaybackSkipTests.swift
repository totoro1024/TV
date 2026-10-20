import XCTest
@testable import TVCore
final class PlaybackSkipTests: XCTestCase {
    func testAndroidLimitsAndNegativeUnsetValues() {
        XCTAssertEqual(PlaybackSkip.limit(duration:899),180)
        XCTAssertEqual(PlaybackSkip.limit(duration:900),360)
        XCTAssertEqual(PlaybackSkip.limit(duration:1800),600)
        let skip=PlaybackSkip(value:.object(["openingMs":.integer(-1),"endingMs":.integer(-1)]))
        XCTAssertEqual(skip.opening,0);XCTAssertEqual(skip.ending,0)
    }
    func testOpeningAndResumeUseLaterPositionWithoutSeekingPastEnd() {
        let skip=PlaybackSkip(value:.object(["openingMs":.integer(90000)]))
        XCTAssertEqual(skip.start(resume:30,duration:3600),90)
        XCTAssertEqual(skip.start(resume:180,duration:3600),180)
        XCTAssertEqual(skip.start(resume:4000,duration:3600),90)
        XCTAssertEqual(skip.start(resume:0,duration:30),0)
    }
    func testEndingUsesRemainingTimeAndDoesNotTriggerForUnknownOrShortDuration() {
        let skip=PlaybackSkip(value:.object(["endingMs":.integer(60000)]))
        XCTAssertFalse(skip.reachedEnding(position:3539,duration:3600))
        XCTAssertTrue(skip.reachedEnding(position:3540,duration:3600))
        XCTAssertFalse(skip.reachedEnding(position:0,duration:0))
        XCTAssertFalse(skip.reachedEnding(position:1,duration:30))
    }
}

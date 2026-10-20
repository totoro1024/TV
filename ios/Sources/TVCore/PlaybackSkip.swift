import Foundation

/// Android Constant.getOpEdLimit / startPositionMs 的秒制对应。
public struct PlaybackSkip: Equatable, Sendable {
    public var opening: Double, ending: Double
    public init(value: JSON? = nil) {
        opening = max(0, Double(value?["openingMs"].int ?? 0) / 1000)
        ending = max(0, Double(value?["endingMs"].int ?? 0) / 1000)
    }
    public static func limit(duration: Double) -> Double { duration < 900 ? 180 : duration < 1800 ? 360 : 600 }
    public func start(resume: Double, duration: Double) -> Double {
        let target = max(opening, resume.isFinite ? max(0, resume) : 0)
        return duration.isFinite && duration > 0 && target >= duration ? (opening < duration ? opening : 0) : target
    }
    public func reachedEnding(position: Double, duration: Double) -> Bool {
        ending > 0 && duration.isFinite && duration > ending && position.isFinite && position >= duration - ending
    }
}

import AVFoundation
import MobileVLCKit

struct PlaybackTrackOption: Identifiable, Equatable {
    let id: Int, name: String
}
struct AdaptiveQualityOption: Identifiable {
    let id: Int, name: String, size: CGSize, bitrate: Double
}

@MainActor extension PlaybackSession {
    func refreshVLCTracks() {
        guard let vlc = vlcPlayer else { return }
        func options(_ names: [Any]?, _ indexes: [Any]?, subtitle: Bool) -> [PlaybackTrackOption] {
            zip(names ?? [], indexes ?? []).compactMap { name, index in
                guard let index = index as? NSNumber else { return nil }
                let id = index.intValue
                return .init(id: id, name: id == -1 ? (subtitle ? "关闭字幕" : "关闭音频") : String(describing: name))
            }
        }
        audioTracks = options(vlc.audioTrackNames, vlc.audioTrackIndexes, subtitle: false)
        subtitleTracks = options(vlc.videoSubTitlesNames, vlc.videoSubTitlesIndexes, subtitle: true)
        if !subtitleTracks.contains(where: { $0.id == -1 }) { subtitleTracks.insert(.init(id: -1, name: "关闭字幕"), at: 0) }
        selectedAudio = Int(vlc.currentAudioTrackIndex); selectedSubtitle = Int(vlc.currentVideoSubTitleIndex)
    }
    func loadSystemTracks() async {
        guard let item = player.currentItem else { return }
        audioGroup = try? await item.asset.loadMediaSelectionGroup(for: .audible)
        subtitleGroup = try? await item.asset.loadMediaSelectionGroup(for: .legible)
        guard player.currentItem === item else { return }
        audioTracks = audioGroup?.options.enumerated().map { .init(id: $0.offset, name: $0.element.displayName) } ?? []
        subtitleTracks = [.init(id: -1, name: "关闭字幕")] + (subtitleGroup?.options.enumerated().map { .init(id: $0.offset, name: $0.element.displayName) } ?? [])
        if let group = audioGroup { selectedAudio = group.options.firstIndex(where: { $0 == item.currentMediaSelection.selectedMediaOption(in: group) }) ?? -2 }
        if let group = subtitleGroup { selectedSubtitle = group.options.firstIndex(where: { $0 == item.currentMediaSelection.selectedMediaOption(in: group) }) ?? -1 }
        guard let asset = item.asset as? AVURLAsset, let variants = try? await asset.load(.variants) else { return }
        var seen = Set<String>()
        adaptiveQualities = variants.compactMap { variant in
            guard let video = variant.videoAttributes else { return nil }
            let size = video.presentationSize, height = Int(min(size.width, size.height))
            guard height > 0 else { return nil }
            let name = "\(height)p"
            guard seen.insert(name).inserted else { return nil }
            return AdaptiveQualityOption(id: height, name: name, size: size, bitrate: max(0, variant.peakBitRate ?? 0))
        }.sorted { $0.id > $1.id }
    }
    func selectTrack(_ id: Int, subtitle: Bool) {
        if let vlc = vlcPlayer {
            if subtitle { vlc.currentVideoSubTitleIndex = Int32(id) } else { vlc.currentAudioTrackIndex = Int32(id) }
            refreshVLCTracks(); return
        }
        guard let group = subtitle ? subtitleGroup : audioGroup, let item = player.currentItem else { return }
        if id == -2 { item.selectMediaOptionAutomatically(in: group) }
        else if id == -1 && subtitle { item.select(nil, in: group) }
        else if group.options.indices.contains(id) { item.select(group.options[id], in: group) }
        else { return }
        if subtitle { selectedSubtitle = id } else { selectedAudio = id }
    }
    func selectAdaptiveQuality(_ id: Int) {
        guard let item = player.currentItem else { return }
        if id == 0 { item.preferredPeakBitRate = 0; item.preferredMaximumResolution = .zero }
        else if let quality = adaptiveQualities.first(where: { $0.id == id }) {
            item.preferredPeakBitRate = quality.bitrate
            item.preferredMaximumResolution = quality.size
        } else { return }
        selectedAdaptiveQuality = id
    }
}

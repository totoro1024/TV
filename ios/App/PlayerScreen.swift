import SwiftUI
import AVKit
import MobileVLCKit
import Observation
import TVCore

@MainActor @Observable final class PlaybackSession {
    let player: AVPlayer
    let media: ResolvedMedia
    private let airPlayBridge: AirPlayHLSBridge?
    private var seekOutsideWindow: ((Double) -> Void)?
    private var timelineOffset: Double { airPlayBridge?.baseTime ?? 0 }
    var vlcPlayer: VLCMediaPlayer?
    private var proxy: QuarkStreamProxy?
    private var hmysProxy: HmysStreamProxy?
    private var websiteProxy: WebsiteHLSProxy?
    private var vlcTimer: Timer?
    var audioTracks: [PlaybackTrackOption] = []
    var subtitleTracks: [PlaybackTrackOption] = []
    var selectedAudio = -2
    var selectedSubtitle = -1
    var audioGroup: AVMediaSelectionGroup?
    var subtitleGroup: AVMediaSelectionGroup?
    var adaptiveQualities: [AdaptiveQualityOption] = []
    var selectedAdaptiveQuality = 0
    private let startAt: Double?
    private let initiallyPlaying: Bool
    private let initialRate: Double?
    private var pauseAfterSeek = false
    var scrubbing = false
    var endingReached = false
    var error: String?
    var position = 0.0
    var duration = 0.0
    var playing = false
    var rate = 1.0
    private var lastSave = -5.0
    private var timer: Any?
    private var observation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var pendingSeek: Double?
    private var ready = false
    private var stopped = false
    private weak var store: AppStore?
    private let request: PlaybackRequest
    init(request: PlaybackRequest, store: AppStore, media: ResolvedMedia, airPlayBridge: AirPlayHLSBridge? = nil, startAt: Double? = nil, initiallyPlaying: Bool = true, initialRate: Double? = nil, hmysProxy: HmysStreamProxy? = nil, websiteProxy: WebsiteHLSProxy? = nil, seekOutsideWindow: ((Double) -> Void)? = nil) {
        self.websiteProxy = websiteProxy
        self.seekOutsideWindow = seekOutsideWindow
        self.startAt = startAt; self.initiallyPlaying = initiallyPlaying; self.initialRate = initialRate
        self.request = request; self.store = store; self.media = media; self.airPlayBridge = airPlayBridge; self.hmysProxy = hmysProxy
        if media.useVLC {
            player = AVPlayer()
            let options = ["--quiet", "--no-video-title-show", "--freetype-font=PingFang SC"] + (request.source.kind == .bili ? ["--avcodec-hw=none"] : [])
            vlcPlayer = VLCMediaPlayer(options: options)
            do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback); try AVAudioSession.sharedInstance().setActive(true) } catch { self.error = "无法初始化音频播放" }
            Task { [weak self] in
                guard let self, !self.stopped else { return }
                do {
                    let url: URL
                    if media.hmysSigning != nil {
                        let proxy = try HmysStreamProxy(media:media); self.hmysProxy = proxy
                        url = try await proxy.start()
                    } else if !request.source.usesQuark && media.byteOffset == 0 {
                        guard let direct = URL(string:media.url), LiveParser.playable(media.url) else { throw TVError.message("直播地址无效") }
                        url = direct
                    } else {
                        let proxy = try QuarkStreamProxy(media: media); self.proxy = proxy
                        url = try await proxy.start()
                    }
                    guard !self.stopped else { self.proxy?.stop(); self.hmysProxy?.stop(); return }
                    let content = VLCMedia(url: url)
                    var options: [String:Any] = ["network-caching":3000, "verbose":-1, "freetype-font":"PingFang SC"]
                    if let ua = media.headers.first(where: { $0.key.lowercased()=="user-agent" })?.value { options["http-user-agent"] = ua }
                    if let referer = media.headers.first(where: { $0.key.lowercased()=="referer" })?.value { options["http-referrer"] = referer }
                    content.addOptions(options)
                    self.vlcPlayer?.media = content
                    self.vlcPlayer?.play()
                    self.vlcTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                        Task { @MainActor [weak self] in self?.updateVLC() }
                    }
                } catch { self.error = "原画播放流启动失败" }
            }
            return
        }
        let asset = AVURLAsset(url: URL(string: media.url)!, options: media.headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": media.headers])
        let item = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        #if os(iOS)
        do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback); try AVAudioSession.sharedInstance().setActive(true) }
        catch { self.error = "无法初始化音频播放" }
        #endif
        observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if item.status == .failed {
                    let failure = item.error as NSError?
                    let underlying = failure?.userInfo[NSUnderlyingErrorKey] as? NSError
                    let code = [failure, underlying].compactMap { $0 }.map { "\($0.domain) \($0.code)" }.joined(separator: " / ")
                    self.error = "系统播放器无法播放此地址。" + (code.isEmpty ? "" : "（\(code)）")
                }
                if item.status == .readyToPlay && !self.ready {
                    self.ready = true
                    let record = store.episodeProgress(request)
                    let sameEpisode = request.episode.matchesHistory(record)
                    let resumeEnabled = request.source.kind != .playlist && (UserDefaults.standard.object(forKey: "ios.resumePlayback") as? Bool ?? true)
                    let saved = sameEpisode && resumeEnabled ? Double(record?["positionMs"].int ?? 0) / 1000 : 0
                    let resume = store.playbackSkip(request).start(resume: self.startAt ?? saved, duration: item.duration.seconds)
                    let duration = item.duration.seconds
                    if self.airPlayBridge == nil && resume > 0 && (!duration.isFinite || resume < duration) {
                        await self.player.seek(to: CMTime(seconds: resume, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                    let rate = self.initialRate ?? (request.source.kind == .playlist ? 1.0 : (UserDefaults.standard.object(forKey: "ios.playbackRate") as? Double ?? 1.0))
                    self.player.defaultRate = Float([0.5, 0.75, 1, 1.25, 1.5, 2].contains(rate) ? rate : 1)
                    if self.initiallyPlaying { self.player.play() }
                    Task { await self.loadSystemTracks() }
                }
            }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                if player.timeControlStatus == .paused, self?.ready == true, self?.stopped == false { self?.save(); self?.store?.requestSync() }
            }
        }
        timer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 10), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.ready else { return }
                self.position = self.timelineOffset + max(0, self.player.currentTime().seconds.isFinite ? self.player.currentTime().seconds : 0)
                let duration = self.player.currentItem?.duration.seconds ?? 0
                self.airPlayBridge?.updatePlaybackTime(self.position)
                self.duration = self.airPlayBridge?.duration ?? (duration.isFinite ? max(0, duration) : 0)
                if self.airPlayBridge?.failure != nil { self.error = "投放流准备中断，请检查网络或剩余空间后重新加载" }
                self.playing = self.player.timeControlStatus == .playing
                self.rate = Double(self.player.defaultRate)
                self.checkEnding()
                if abs(self.position - self.lastSave) >= 5 { self.save(); self.lastSave = self.position }
            }
        }
    }
    private func updateVLC() {
        guard let vlc = vlcPlayer, !stopped else { return }
        duration = max(0, Double(vlc.media?.length.intValue ?? 0) / 1000)
        position = max(0, Double(vlc.time.intValue) / 1000)
        playing = vlc.isPlaying
        refreshVLCTracks()
        if vlc.state == .error { error = request.source.kind == .playlist ? "直播播放失败，请切换线路或重新加载" : "原画播放失败，请重试获取新的播放地址" }
        if let target = pendingSeek {
            if abs(position - target) < 3 { pendingSeek = nil } else { return }
        }
        if !ready && (duration > 0 || request.source.kind == .playlist) && (vlc.media?.statistics.displayedPictures ?? 0) > 0 {
            ready = true
            let record = store?.episodeProgress(request)
            let resumeEnabled = request.source.kind != .playlist && (UserDefaults.standard.object(forKey: "ios.resumePlayback") as? Bool ?? true)
            let saved = resumeEnabled && request.episode.matchesHistory(record) ? Double(record?["positionMs"].int ?? 0) / 1000 : 0
            let resume = store?.playbackSkip(request).start(resume: startAt ?? saved, duration: duration) ?? (startAt ?? saved)
            if resume > 0 && resume < duration { seek(resume) }
            pauseAfterSeek = !initiallyPlaying
            setRate(initialRate ?? (request.source.kind == .playlist ? 1 : (UserDefaults.standard.object(forKey: "ios.playbackRate") as? Double ?? 1)))
            return
        }
        if pauseAfterSeek && ready { pauseAfterSeek = false; pause() }
        checkEnding()
        if ready && abs(position - lastSave) >= 5 { save(); lastSave = position }
    }
    private func checkEnding() {
        guard request.source.kind != .playlist, ready, playing, !scrubbing, pendingSeek == nil, !endingReached,
              store?.playbackSkip(request).reachedEnding(position: position, duration: duration) == true else { return }
        save(); endingReached = true
    }
    func pause() {
        vlcPlayer?.pause(); player.pause(); playing = false; save(); store?.requestSync()
    }
    func seek(_ seconds: Double) {
        if store?.playbackSkip(request).reachedEnding(position: seconds, duration: duration) != true { endingReached = false }
        if let vlc = vlcPlayer, duration > 0 { pendingSeek = seconds; vlc.position = Float(min(1, max(0, seconds / duration))) }
        else {
            let target = seconds - timelineOffset
            if airPlayBridge != nil {
                let ranges = player.currentItem?.seekableTimeRanges.map { $0.timeRangeValue } ?? []
                guard ranges.contains(where: { target >= $0.start.seconds && target <= CMTimeRangeGetEnd($0).seconds }) else {
                    if let seekOutsideWindow { seekOutsideWindow(seconds); return }
                    error = "该位置尚未准备好；直接投放时暂可跳转已生成的片段。"; return
                }
            }
            player.seek(to: CMTime(seconds: max(0, target), preferredTimescale: 1000))
        }
    }
    func toggle() {
        if let vlc = vlcPlayer { if vlc.isPlaying { vlc.pause(); save(); store?.requestSync() } else { vlc.play() } }
        else { if playing { player.pause() } else { player.play() } }
        playing.toggle()
    }
    func setRate(_ value: Double) {
        let value = [0.5,0.75,1,1.25,1.5,2].contains(value) ? value : 1
        rate = value
        if let vlc = vlcPlayer { vlc.rate = Float(value) }
        else { player.defaultRate = Float(value); if playing { player.rate = Float(value) } }
    }
    func save() {
        guard ready, pendingSeek == nil, let store else { return }
        if let vlc = vlcPlayer { store.progress(request, seconds: Double(vlc.time.intValue)/1000, duration: duration) }
        else { store.progress(request, seconds: timelineOffset + player.currentTime().seconds, duration: airPlayBridge?.duration ?? (player.currentItem?.duration.seconds ?? 0)) }
    }
    func stop() {
        guard !stopped else { return }; save(); stopped = true
        seekOutsideWindow = nil
        vlcTimer?.invalidate(); vlcTimer = nil; vlcPlayer?.stop(); proxy?.stop(); proxy = nil; hmysProxy?.stop(); hmysProxy = nil; websiteProxy?.stop(); websiteProxy = nil
        observation?.invalidate(); statusObservation?.invalidate(); player.pause(); airPlayBridge?.stop()
        if let timer { player.removeTimeObserver(timer); self.timer = nil }
        store?.requestSync()
    }
}
struct PlayerScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let request: PlaybackRequest
    @ViewState private var session: PlaybackSession?
    @ViewState private var resolveError: String?
    @ViewState private var current: Episode?
    @ViewState private var changedLive: LivePlaybackContext?
    @ViewState private var showLiveChannels = false
    @ViewState private var showGuide = false
    @ViewState private var changingLiveSource = false
    @ViewState private var replayTitle: String?
    @ViewState private var currentPrograms: [LiveProgram] = []
    @ViewState private var failedLiveRoutes=Set<String>()
    private var liveContext: LivePlaybackContext? { changedLive ?? request.live }
    private var liveChannel: LiveChannel? { liveContext?.channels.first { $0.name == episode.name && $0.group == episode.line } }
    private var liveRoute: LiveRoute? { liveChannel?.routes.first { $0.url == episode.url } ?? liveChannel?.routes.first }
    private var displayName: String { liveChannel?.name ?? request.item.name }
    private var effectiveRequest: PlaybackRequest {
        guard let context = liveContext, let channel = liveChannel else { return .init(source:request.source,item:request.item,episode:episode) }
        return .init(source:.init(id:context.source.id,sourceID:request.source.sourceID,name:context.source.name,address:context.source.address,kind:.playlist),item:.init(id:channel.name,name:channel.name,picture:channel.logo),episode:episode,live:context)
    }
    @ViewState private var detail: MediaDetail?
    @ViewState private var fullscreen = false
    @AppStorage("ios.fillScreen") private var fillScreen = true
    @ViewState private var controlsVisible = true
    @ViewState private var controlsGeneration = 0
    @ViewState private var retry = 0
    @ViewState private var requestedRemuxStart: Double?
    @ViewState private var remuxEpisodeID = ""
    @ViewState private var airPlayHelp = false
    @ViewState private var preparingAirPlay = false
    @ViewState private var airPlayPreparation: Task<Void, Never>?
    @ViewState private var preparingBridge: AirPlayHLSBridge?
    @ViewState private var qualityTask: Task<Void, Never>?
    @ViewState private var changingQuality = false
    @ViewState private var seekValue = 0.0
    @ViewState private var seeking = false
    private var episode: Episode { current ?? request.episode }
    var body: some View {
        GeometryReader { proxy in
            let expanded = fullscreen || proxy.size.width > proxy.size.height
            VStack(spacing: 0) {
                if !expanded { header }
                ZStack(alignment: .topTrailing) {
                    Color.black
                    if let session {
                        if let vlc = session.vlcPlayer {
                            VLCPlayerSurface(player: vlc, fill: expanded && fillScreen)
                        } else {
                            PlayerSurface(player: session.player, fill: expanded && fillScreen)
                        }
                    } else if let resolveError {
                        VStack(spacing: 16) { Text(resolveError).multilineTextAlignment(.center); Button("重试") { retry += 1 } }.padding(24)
                    } else { ProgressView("正在解析播放地址…").tint(.white) }
                    if expanded && session != nil {
                        Button { controlsVisible.toggle(); controlsGeneration += 1 } label: {
                            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(controlsVisible ? "隐藏播放控制" : "显示播放控制")
                    }
                    if expanded && controlsVisible {
                        HStack {
                            Button { leaveFullscreen() } label: { Image(systemName: "chevron.left").padding(12).background(.black.opacity(0.5), in: Circle()) }.accessibilityLabel("退出全屏")
                            Text(liveContext == nil ? request.item.name + " · " + episode.name : displayName).lineLimit(1).shadow(radius: 3)
                            Spacer()
                            airPlayControl
                            Button { close() } label: { Image(systemName: "xmark").padding(12).background(.black.opacity(0.5), in: Circle()) }.accessibilityLabel("关闭播放")
                        }.padding(.horizontal, 56).padding(.vertical, 16)
                    }
                    if expanded && controlsVisible {
                        VStack { Spacer(); controls(expanded: true).padding(.horizontal, 38).padding(.bottom, 12) }
                    }
                }.frame(maxWidth: .infinity).frame(height: expanded ? proxy.size.height : proxy.size.width * 9 / 16)
                if !expanded { controls(expanded: false) }
                if !expanded {
                    ScrollViewReader { episodeScroll in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                Text(displayName).font(.title2.bold())
                                Text("站源：" + request.source.name).font(.subheadline)
                                Text(episode.line + " · " + episode.name).font(.subheadline).foregroundStyle(.white.opacity(0.8))
                                HStack {
                                    FavoriteButton(request: effectiveRequest)
                                    if store.incognito { Label("无痕", systemImage: "eye.slash").font(.caption) }
                                }
                                if let error = session?.error {
                                    Text(liveContext == nil ? error:"当前直播线路无法播放，请切换线路、频道或直播源。").foregroundStyle(.orange)
                                    Button("重新加载播放") { session?.stop(); session = nil; retry += 1 }
                                }
                                if liveContext != nil { liveOptions }
                                if let detail {
                                    EpisodeSelector(episodes: detail.episodes, selected: episode, initialLine: episode.line) { next in current = next }
                                }
                            }.frame(maxWidth:.infinity,alignment:.leading).padding(20)
                        }.frame(maxWidth:.infinity).background { AndroidBackground() }
                            .task(id: "\(episode.id)-\(detail?.episodes.count ?? 0)-\(session != nil)") {
                                guard detail?.episodes.contains(where: { $0.id == episode.id }) == true else { return }
                                await Task.yield()
                                guard !Task.isCancelled else { return }
                                episodeScroll.scrollTo(episode.id, anchor: .center)
                            }
                    }
                }
            }.background(.black).foregroundStyle(.white)
                .task(id: "\(expanded)-\(controlsGeneration)-\(session?.playing == true)-\(seeking)") {
                    guard expanded, controlsVisible, !seeking else { return }
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled, session?.playing == true else { return }
                    controlsVisible = false
                }
                .statusBarHidden(expanded).persistentSystemOverlays(expanded ? .hidden : .automatic)
                .onChange(of:liveChannel?.id) { _,_ in failedLiveRoutes=[] }
                .onChange(of:session?.error) { _,error in
                    guard error != nil, replayTitle == nil, let channel=liveChannel else { return }
                    failedLiveRoutes.insert(episode.url)
                    if let route=channel.routes.first(where: { !failedLiveRoutes.contains($0.url) }) { current=Episode(name:channel.name,url:route.url,line:channel.group) }
                }
                .onChange(of: session?.endingReached) { _, reached in
                    guard reached == true else { return }
                    if next != nil { nextEpisode() } else { session?.pause() }
                }
                .task(id: episode.id + String(retry)) { await load() }
                .task(id:"live-timeout-"+episode.id+String(retry)) {
                    guard liveContext != nil else { return }
                    try? await Task.sleep(for:.seconds(20))
                    guard !Task.isCancelled,let session,session.error==nil,!session.playing else { return }
                    if session.player.timeControlStatus == .waitingToPlayAtSpecifiedRate || session.vlcPlayer?.state == .opening || session.vlcPlayer?.state == .buffering {
                        session.error="直播线路加载超时，请切换线路"
                    }
                }
                .task {
                    if let loaded = request.detail { detail = loaded }
                    else if request.source.supportsCatalog && request.source.kind != .doudou {
                        detail = try? await store.mediaDetail(request.source, id: request.item.id)
                    }
                }
                .task(id:liveChannel?.id) {
                    currentPrograms=[]
                    if let channel=liveChannel { currentPrograms=(try? await LiveEPGClient.shared.programs(channel:channel)) ?? [] }
                }
                .onDisappear { qualityTask?.cancel(); airPlayPreparation?.cancel(); preparingBridge?.stop(); session?.stop() }
        }.background(.black).ignoresSafeArea(.container, edges: fullscreen || verticalSizeClass == .compact ? .all : [])
            .sheet(isPresented:$showLiveChannels) {
                if let context=liveContext { LiveChannelPicker(channels:context.channels) { selectLiveChannel($0) }.environment(store) }
            }
            .sheet(isPresented:$showGuide) {
                if let channel=liveChannel, let route=liveRoute {
                    LiveGuideView(channel:channel,route:route) { program,url in replayTitle=program.title;current=Episode(name:channel.name,url:url,line:channel.group) }
                }
            }
            .alert("AirPlay 投放", isPresented: $airPlayHelp) {
                Button("知道了", role: .cancel) { }
            } message: {
                Text("已生成电视可播放的 HLS 视频流。请再点 AirPlay 按钮选择电视，手机和电视需连接同一 Wi-Fi。投放期间请保持应用运行；影片会逐步缓存，暂时只能跳转已生成的片段。")
            }
    }
    private var header: some View {
        HStack {
            Button { close() } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("返回")
            Text(displayName).font(.headline).lineLimit(1)
            Spacer()
            airPlayControl
        }.padding(.horizontal, 8).background(.black.opacity(0.75))
    }
    @ViewBuilder private var airPlayControl: some View {
        if let session {
            if session.vlcPlayer != nil && liveContext == nil {
                Button { prepareAirPlay() } label: {
                    if preparingAirPlay { ProgressView().frame(width: 44, height: 44) }
                    else { Image(systemName: "airplay.video").frame(width: 44, height: 44) }
                }.disabled(preparingAirPlay).accessibilityLabel(preparingAirPlay ? "正在准备直接 AirPlay" : "AirPlay，准备原画直接投放")
            } else if session.vlcPlayer != nil {
                Image(systemName:"airplay.video").foregroundStyle(.gray).frame(width:44,height:44).accessibilityLabel("此直播线路需切换为 HLS 后投放")
            } else {
                AirPlayRoutePicker().frame(width: 44, height: 44)
                    .accessibilityLabel("AirPlay，选择电视")
            }
        }
    }
    private var liveRouteMenu: some View {
        Menu {
            if let channel=liveChannel {
                ForEach(Array(channel.routes.enumerated()),id:\.offset) { index,route in
                    Button(route.name.isEmpty ? "线路 \(index+1)" : route.name) {
                        replayTitle=nil;current=channel.episode(route:index)
                        UserDefaults.standard.set(index,forKey:"ios.live.route."+request.source.sourceID+"."+channel.id)
                    }
                }
            }
        } label: { Label("线路",systemImage:"arrow.triangle.branch") }
    }
    private var liveSourceMenu: some View {
        Menu {
            if let context=liveContext {
                ForEach(context.sources) { source in Button(source.name) {
                    guard !changingLiveSource else { return };changingLiveSource=true
                    Task { @MainActor in
                        defer { changingLiveSource=false }
                        do {
                            let channels=try await LiveClient().channels(source)
                            try Task.checkCancellation()
                            changedLive=LivePlaybackContext(source:source,sources:context.sources,channels:channels)
                            if let first=channels.first { selectLiveChannel(first) }
                            if let row=store.replica.document.records[request.source.sourceID] {
                                var value=row["value"];value["home"] = .string(source.name)
                                store.edit(id:request.source.sourceID,kind:"source",value:value)
                            }
                        } catch { store.issue=(error as? TVError)?.localizedDescription ?? "切换直播源失败，请检查网络" }
                    }
                } }
            }
        } label: { Label(changingLiveSource ? "切换中…":"直播源",systemImage:"tv") }.disabled(changingLiveSource)
    }
    private var liveOptions: some View {
        VStack(alignment:.leading,spacing:16) {
            if let title=replayTitle { Label("回看："+title,systemImage:"clock.arrow.circlepath")
                Button("返回直播") { if let channel=liveChannel { selectLiveChannel(channel) } }
            } else if let program=currentPrograms.first(where: { $0.isCurrent() }) {
                Label("正在播出："+program.title,systemImage:"play.tv")
            } else { Text("直播中").font(.subheadline) }
            HStack(spacing:18) { liveRouteMenu;liveSourceMenu;Button("频道列表") { showLiveChannels=true };Button("节目单") { showGuide=true } }.font(.subheadline)
            if let channel=liveChannel { Text("频道 "+channel.number+" · "+channel.group+" · \(channel.routes.count) 条线路").font(.caption).foregroundStyle(.white.opacity(0.7)) }
        }
    }
    private func selectLiveChannel(_ channel:LiveChannel) {
        failedLiveRoutes=[]
        let index=UserDefaults.standard.integer(forKey:"ios.live.route."+request.source.sourceID+"."+channel.id)
        replayTitle=nil;current=channel.episode(route:channel.routes.indices.contains(index) ? index:0)
        if let context=liveContext { UserDefaults.standard.set(channel.id,forKey:"ios.live.channel."+request.source.sourceID+"."+context.source.id) }
    }
    private func prepareAirPlay() {
        guard let current = session, current.vlcPlayer != nil, !preparingAirPlay else { return }
        preparingAirPlay = true; controlsVisible = true; controlsGeneration += 1
        airPlayPreparation = Task { @MainActor in
            defer { preparingAirPlay = false }
            do {
                let bridge = try AirPlayHLSBridge(media: current.media)
                preparingBridge = bridge
                let url = try await bridge.start(at: max(0, current.position - 2))
                try Task.checkCancellation()
                guard session === current else { bridge.stop(); return }
                current.stop()
                session = PlaybackSession(request: .init(source: request.source, item: request.item, episode: episode), store: store, media: .init(url: url.absoluteString), airPlayBridge: bridge)
                preparingBridge = nil
                airPlayHelp = true
            } catch {
                preparingBridge?.stop(); preparingBridge = nil
                if !Task.isCancelled { store.issue = error.localizedDescription }
            }
        }
    }
    private func controls(expanded: Bool) -> some View {
        VStack(spacing: 8) {
            if let session {
                if liveContext == nil || replayTitle != nil { HStack(spacing: 10) {
                    Text(time(seeking ? seekValue : session.position)).font(.caption.monospacedDigit())
                    Slider(value: Binding(get: { seeking ? seekValue : min(session.position, max(session.duration, 1)) }, set: { seekValue = $0 }), in: 0...max(session.duration, 1), onEditingChanged: { editing in
                        if editing { seekValue = min(session.position, max(session.duration, 1)) }
                        else { session.seek(seekValue) }
                        seeking = editing; session.scrubbing = editing
                        controlsVisible = true; controlsGeneration += 1
                    }).tint(.white).disabled(session.duration <= 0).accessibilityLabel("播放进度")
                    Text(time(session.duration)).font(.caption.monospacedDigit())
                }
                .overlay(alignment: .top) {
                    if seeking {
                        Text("\(time(seekValue)) / \(time(session.duration))")
                            .font(.headline.monospacedDigit()).padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                            .offset(y: -44).allowsHitTesting(false).accessibilityLabel("跳转到 \(time(seekValue))")
                    }
                }
                }
                HStack(spacing: 20) {
                    if liveContext != nil { Button { previousEpisode() } label: { Image(systemName:"backward.end.fill") }.accessibilityLabel("上一频道") }
                    else { Button { session.seek(max(0, session.position - 10)) } label: { Image(systemName: "gobackward.10") }.accessibilityLabel("后退10秒") }
                    Button { session.toggle() } label: { Image(systemName: session.playing ? "pause.fill" : "play.fill") }.accessibilityLabel(session.playing ? "暂停" : "播放")
                    if liveContext == nil { Button { session.seek(min(session.duration, session.position + 10)) } label: { Image(systemName: "goforward.10") }.accessibilityLabel("前进10秒") }
                    else { Button { nextEpisode() } label: { Image(systemName:"forward.end.fill") }.accessibilityLabel("下一频道"); Button("频道") { showLiveChannels=true }; Button("节目单") { showGuide=true } }
                    Spacer(minLength: 0)
                    if liveContext == nil || replayTitle != nil { Menu {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                            Button("\(rate.formatted()) 倍") { session.setRate(rate) }
                        }
                    } label: { Text("\(session.rate.formatted())×").font(.subheadline) }.accessibilityLabel("播放倍速") }
                    if expanded {
                        Button { fillScreen.toggle(); controlsGeneration += 1 } label: { Text(fillScreen ? "铺满" : "适应").font(.subheadline) }
                            .accessibilityLabel(fillScreen ? "画面铺满，切换为适应" : "画面适应，切换为铺满")
                    }
                    if liveContext == nil { Button { nextEpisode() } label: { Image(systemName: "forward.end.fill") }.disabled(next == nil).accessibilityLabel("下一集") }
                    Button { if expanded { leaveFullscreen() } else { enterFullscreen() } } label: { Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }.accessibilityLabel(expanded ? "退出全屏" : "全屏")
                }.font(.system(size: 20)).frame(minHeight: 40)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        if liveContext == nil {
                            Button { previousEpisode() } label: { Label("上一集", systemImage: "backward.end") }.disabled(previous == nil)
                            markerMenu(ending: false, session: session)
                            markerMenu(ending: true, session: session)
                        } else { liveRouteMenu }
                        trackMenu(subtitle: false, session: session)
                        trackMenu(subtitle: true, session: session)
                        qualityMenu(session: session)
                        if liveContext == nil { Button { session.seek(store.playbackSkip(request).opening) } label: { Label("重播", systemImage: "arrow.counterclockwise") } }
                        else { liveSourceMenu }
                        Button { retry += 1 } label: { Label("重新加载", systemImage: "arrow.clockwise") }
                        if !expanded {
                            Button { fillScreen.toggle() } label: { Label(fillScreen ? "铺满" : "适应", systemImage: "aspectratio") }
                        }
                    }.font(.subheadline).padding(.vertical, 6)
                }
            }
        }.padding(.horizontal, 18).padding(.vertical, 10).background(Color.black.opacity(expanded ? 0.55 : 0.85)).buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded { controlsVisible = true; controlsGeneration += 1 })
    }
    private func trackMenu(subtitle: Bool, session: PlaybackSession) -> some View {
        let options = subtitle ? session.subtitleTracks : session.audioTracks
        let selected = subtitle ? session.selectedSubtitle : session.selectedAudio
        let title = subtitle ? "字幕" : "音轨"
        return Menu {
            if session.vlcPlayer == nil && (subtitle ? session.subtitleGroup : session.audioGroup) != nil {
                Button { session.selectTrack(-2, subtitle: subtitle) } label: { choiceLabel("自动", selected: selected == -2) }
            }
            ForEach(options) { option in
                Button { session.selectTrack(option.id, subtitle: subtitle) } label: { choiceLabel(option.name, selected: option.id == selected) }
            }
            if options.isEmpty || (subtitle && options.allSatisfy({ $0.id == -1 })) {
                Text(subtitle ? "此视频没有内嵌字幕" : "此视频暂无可选音轨")
            }
        } label: { Label(title, systemImage: subtitle ? "captions.bubble" : "speaker.wave.2") }
        .accessibilityLabel(title)
    }
    @ViewBuilder private func choiceLabel(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
    private func qualityMenu(session: PlaybackSession) -> some View {
        Menu {
            if !session.media.qualities.isEmpty {
                ForEach(session.media.qualities) { quality in
                    Button { selectQuality(quality.id) } label: { choiceLabel(quality.name, selected: session.media.qualityID == quality.id) }
                        .disabled(changingQuality)
                }
            } else if session.adaptiveQualities.count > 1 {
                Button { session.selectAdaptiveQuality(0) } label: { choiceLabel("自动", selected: session.selectedAdaptiveQuality == 0) }
                ForEach(session.adaptiveQualities) { quality in
                    Button { session.selectAdaptiveQuality(quality.id) } label: { choiceLabel("最高 " + quality.name, selected: session.selectedAdaptiveQuality == quality.id) }
                }
            } else { Text(session.vlcPlayer != nil ? "当前为原画，源未提供其他清晰度" : "当前源仅提供一种清晰度") }
        } label: {
            if changingQuality { ProgressView().frame(width: 44) }
            else { Label("清晰度", systemImage: "slider.horizontal.3") }
        }.accessibilityLabel(changingQuality ? "正在切换清晰度" : "清晰度")
    }
    private func selectQuality(_ id: String) {
        guard let playing = session, request.source.usesQuark, id != playing.media.qualityID, !changingQuality else { return }
        qualityTask?.cancel(); changingQuality = true
        let selected = episode
        qualityTask = Task { @MainActor in
            defer { changingQuality = false }
            do {
                let drive = CloudDrive.episode(selected.url)
                guard let cookie = try SyncedQuarkAccount.cookie(in: store.replica.document, drive: drive) else { throw TVError.message("请先同步\(drive.name) Cookie") }
                let media = try await QuarkClient(cookie: cookie, drive: drive).resolveHistory(selected.url, resolution: id)
                try Task.checkCancellation()
                guard session === playing else { return }
                let position = playing.position, wasPlaying = playing.playing
                playing.stop()
                session = PlaybackSession(request: .init(source: request.source, item: request.item, episode: selected), store: store, media: media, startAt: position, initiallyPlaying: wasPlaying, initialRate: playing.rate)
            } catch is CancellationError { }
            catch { store.report(error, context: "清晰度切换") }
        }
    }
    private func markerMenu(ending: Bool, session: PlaybackSession) -> some View {
        let skip = store.playbackSkip(request)
        let value = ending ? skip.ending : skip.opening
        let title = ending ? "片尾" : "片头"
        let limit = PlaybackSkip.limit(duration: session.duration)
        let atCurrent = ending ? session.duration - session.position : session.position
        let available = !store.incognito && session.duration > 0
        return Menu {
            Button(ending ? "从当前位置跳过片尾" : "片头设为当前位置") { setMarker(ending: ending, seconds: atCurrent) }
                .disabled(!available || session.position <= 0 || atCurrent <= 0 || atCurrent > limit)
            Button("增加 1 秒") { setMarker(ending: ending, seconds: min(limit, value + 1)) }.disabled(!available)
            Button("减少 1 秒") { setMarker(ending: ending, seconds: max(0, value - 1)) }.disabled(!available || value <= 0)
            Button("重置" + title) { setMarker(ending: ending, seconds: 0) }.disabled(!available || value <= 0)
        } label: {
            Text(value > 0 ? "\(title) \(time(value))" : title).monospacedDigit()
        }.accessibilityLabel(value > 0 ? "\(title) \(time(value))" : title)
    }
    private func setMarker(ending: Bool, seconds: Double) {
        guard let session else { return }
        session.save()
        if ending { store.setPlaybackSkip(request, ending: seconds) }
        else { store.setPlaybackSkip(request, opening: seconds) }
        controlsVisible = true; controlsGeneration += 1
    }
    private var previous: Episode? {
        if let context=liveContext,let channel=liveChannel,let index=context.channels.firstIndex(where: { $0.id==channel.id }),!context.channels.isEmpty {
            return context.channels[(index+context.channels.count-1)%context.channels.count].episode()
        }
        let episodes = detail?.episodes.filter { $0.line == episode.line } ?? []
        guard let index = episodes.firstIndex(where: { $0.id == episode.id }), index > 0 else { return nil }
        return episodes[index - 1]
    }
    private func previousEpisode() { if let previous { replayTitle=nil;current = previous } }
    private var next: Episode? {
        if let context=liveContext,let channel=liveChannel,let index=context.channels.firstIndex(where: { $0.id==channel.id }),!context.channels.isEmpty {
            return context.channels[(index+1)%context.channels.count].episode()
        }
        let episodes = detail?.episodes.filter { $0.line == episode.line } ?? []
        guard let index = episodes.firstIndex(where: { $0.id == episode.id }), index + 1 < episodes.count else { return nil }
        return episodes[index + 1]
    }
    private func enterFullscreen() {
        controlsVisible = true; controlsGeneration += 1; fullscreen = true
        #if os(iOS)
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
        }
        #endif
    }
    private func leaveFullscreen() {
        fullscreen = false
        #if os(iOS)
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
        }
        #endif
    }
    private func nextEpisode() { if let next { replayTitle=nil;current = next } }
    private func close() { airPlayPreparation?.cancel(); preparingBridge?.stop(); leaveFullscreen(); session?.stop(); dismiss() }
    private func load() async {
        qualityTask?.cancel(); changingQuality = false
        airPlayPreparation?.cancel(); preparingBridge?.stop(); preparingBridge = nil; preparingAirPlay = false
        session?.stop(); session = nil; resolveError = nil; seeking = false; seekValue = 0
        let selected = episode
        if remuxEpisodeID != selected.id { requestedRemuxStart = nil; remuxEpisodeID = selected.id }
        let requestedStart = requestedRemuxStart
        requestedRemuxStart = nil
        do {
            let media: ResolvedMedia
            if request.source.kind == .jpj {
                media = try await JPJClient.shared.resolve(request.source,episode:selected)
            } else if request.source.kind == .music {
                media = try await MusicClient().resolve(request.source,episode:selected)
            } else if request.source.kind == .alllive {
                media = try await AllLiveClient().resolve(selected)
            } else if request.source.kind == .kanqiu {
                do { media = try await KanqiuClient().resolve(selected) }
                catch let page as HTMLPlaybackRequired { media = try await WebPlaybackResolver.resolve(page) }
            } else if request.source.kind == .aidj {
                media = try await EmbeddedAIClient().resolve(selected)
            } else if request.source.kind == .jpys {
                media = try await JpysClient.shared.resolve(request.source,episode:selected)
            } else if request.source.kind == .appgz {
                media = try await AppGzClient.shared.resolve(selected)
            } else if request.source.kind == .streamSite {
                do { media = try await PublicStreamClient().resolve(request.source,episode:selected) }
                catch let page as HTMLPlaybackRequired { media = try await WebPlaybackResolver.resolve(page) }
            } else if request.source.kind == .hmys {
                media = try await HmysClient.shared.resolve(selected)
            } else if request.source.kind == .audiobook {
                media = try await AudioBookClient.shared.resolve(selected)
            } else if request.source.kind == .doubao {
                media = try await DoubaoClient.shared.resolve(selected)
            } else if request.source.kind == .legacySite && !request.source.isQuarkEpisode(selected) {
                do { media = try await LegacyWebsiteClient().resolve(request.source,episode:selected) }
                catch let page as HTMLPlaybackRequired { media = try await WebPlaybackResolver.resolve(page) }
            } else if request.source.kind == .appsx {
                media = try await AppSxClient.shared.resolve(request.source,episode:selected)
            } else if request.source.kind == .apptt {
                media = try await AppTTClient().resolve(selected)
            } else if request.source.kind == .t4 {
                media = try await T4Client().resolve(request.source,episode:selected)
            } else if request.source.kind == .website {
                media = try await WebsiteClient().resolve(request.source, episode: selected)
            } else if request.source.kind == .bili {
                media = try await BiliClient().resolve(selected)
            } else if request.source.kind == .app99 {
                media = try await App99Client.shared.resolve(request.source, episode: selected)
            } else if request.source.usesQuark {
                let drive = CloudDrive.episode(selected.url)
                guard let cookie = try SyncedQuarkAccount.cookie(in: store.replica.document, drive: drive) else { throw TVError.message("请先通过 WebDAV 同步\(drive.name) Cookie") }
                media = try await QuarkClient(cookie: cookie, drive: drive).resolveHistory(selected.url, preferOriginal: !selected.line.hasPrefix("夸父智"))
            } else if let route=liveRoute {
                let scheme=URL(string:selected.url)?.scheme?.lowercased() ?? "", ext=URL(string:selected.url)?.pathExtension.lowercased() ?? ""
                media=ResolvedMedia(url:selected.url,headers:route.headers,useVLC:!["http","https"].contains(scheme) || ext=="flv")
            } else { media = ResolvedMedia(url: selected.url) }
            try Task.checkCancellation()
            let websiteHLS = (request.source.address == "csp_NewCzGuard" || request.source.kind == .doubao) && URL(string:media.url)?.pathExtension.lowercased() == "m3u8"
            if media.hmysSigning != nil || websiteHLS {
                let hmysProxy = try websiteHLS ? nil : HmysStreamProxy(media:media)
                let websiteProxy = try websiteHLS ? WebsiteHLSProxy(media:media) : nil
                do {
                    let local:URL
                    if let websiteProxy { local = try await websiteProxy.start() }
                    else if let hmysProxy { local = try await hmysProxy.start() }
                    else { throw TVError.message("本地播放输入未就绪") }
                    try Task.checkCancellation()
                    let bridge = try AirPlayHLSBridge(localInput:local)
                    do {
                        let record = store.episodeProgress(effectiveRequest)
                        let enabled = UserDefaults.standard.object(forKey:"ios.resumePlayback") as? Bool ?? true
                        let saved = enabled && selected.matchesHistory(record) ? Double(record?["positionMs"].int ?? 0)/1000 : 0
                        let target = store.playbackSkip(effectiveRequest).start(resume:requestedStart ?? saved,duration:0)
                        let remuxed = try await bridge.start(at:target)
                        try Task.checkCancellation()
                        var adapted = media; adapted.url = remuxed.absoluteString; adapted.useVLC = false; adapted.hmysSigning = nil;adapted.headers = [:]
                        session = PlaybackSession(request:effectiveRequest,store:store,media:adapted,airPlayBridge:bridge,hmysProxy:hmysProxy,websiteProxy:websiteProxy,seekOutsideWindow:{ seconds in requestedRemuxStart = seconds; retry += 1 })
                    } catch { bridge.stop(); throw error }
                } catch { hmysProxy?.stop();websiteProxy?.stop(); throw error }
            } else {
                session = PlaybackSession(request: effectiveRequest, store: store, media: media)
            }
        } catch is CancellationError { }
        catch { resolveError = error.localizedDescription }
    }
    private func time(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "00:00" }
        let seconds = Int(value)
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds/3600, seconds/60%60, seconds%60) : String(format: "%02d:%02d", seconds/60, seconds%60)
    }
}
#if os(iOS)
/// 使用系统设备选择器发现 AirPlay 接收设备。
struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.tintColor = .white
        view.activeTintColor = .systemGreen
        view.backgroundColor = .clear
        return view
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) { }
}
struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    var fill = false
    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
    }
    func makeUIView(context: Context) -> Surface { let view = Surface(); view.clipsToBounds = true; (view.layer as? AVPlayerLayer)?.videoGravity = fill ? .resizeAspectFill : .resizeAspect; return view }
    func updateUIView(_ view: Surface, context: Context) { (view.layer as? AVPlayerLayer)?.player = player; (view.layer as? AVPlayerLayer)?.videoGravity = fill ? .resizeAspectFill : .resizeAspect }
    static func dismantleUIView(_ view: Surface, coordinator: ()) { (view.layer as? AVPlayerLayer)?.player = nil }
}
#endif

struct VLCPlayerSurface: UIViewRepresentable {
    let player: VLCMediaPlayer
    var fill = false
    final class Surface: UIView {
        weak var player: VLCMediaPlayer?
        var fill = false
        private var geometry = "unset"
        override func layoutSubviews() {
            super.layoutSubviews(); applyGeometry()
        }
        func applyGeometry() {
            guard let player, bounds.width > 0, bounds.height > 0 else { return }
            let next = fill ? "\(Int(bounds.width * 100)):\(Int(bounds.height * 100))" : ""
            guard geometry != next else { return }
            geometry = next
            if next.isEmpty { player.videoCropGeometry = nil }
            else { next.withCString { player.videoCropGeometry = UnsafeMutablePointer(mutating: $0) } }
            player.scaleFactor = 0
        }
        func bind(_ next: VLCMediaPlayer) {
            guard player !== next else { return }
            player = next; geometry = "unset"; next.drawable = self
        }
    }
    func makeUIView(context: Context) -> Surface {
        let view = Surface(); view.backgroundColor = .black; view.clipsToBounds = true
        view.fill = fill; view.bind(player); return view
    }
    func updateUIView(_ view: Surface, context: Context) {
        view.bind(player); view.fill = fill; view.applyGeometry()
    }
    static func dismantleUIView(_ view: Surface, coordinator: ()) {
        if (view.player?.drawable as? UIView) === view { view.player?.drawable = nil }
    }
}

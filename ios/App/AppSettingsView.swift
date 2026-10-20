import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                NavigationLink { WebDAVSettingsView() } label: {
                    SettingRow(title: "WebDAV 跨设备同步", symbol: "icloud.and.arrow.up", value: store.settings.address.isEmpty ? "未配置" : "已配置")
                }
                NavigationLink { SourceLibraryScreen(live: false).androidScreen() } label: {
                    SettingRow(title: "点播", symbol: "film", value: store.sourceDescription(type: 0))
                }
                NavigationLink { SourceLibraryScreen(live: true).androidScreen() } label: {
                    SettingRow(title: "直播", symbol: "video", value: store.sourceDescription(type: 1))
                }
                NavigationLink { QuarkAccountView() } label: { SettingRow(title: "网盘账号", symbol: "externaldrive", value: "夸克 / UC") }
                NavigationLink { WallpaperSettingsView() } label: { SettingRow(title: "壁纸", symbol: "photo", value: "内置壁纸") }
                NavigationLink { PlaybackSettingsView() } label: { SettingRow(title: "播放设置", symbol: "play.circle", value: "自动选择播放器") }
                NavigationLink { PlatformNoteView(title: "弹幕设置", message: "iPhone 首版暂未接入弹幕服务。Android 的弹幕配置可随 WebDAV 原样保留，但不会在 iPhone 播放器生效。") } label: { SettingRow(title: "弹幕设置", symbol: "text.bubble", value: "暂不支持") }
                HStack {
                    Label("无痕观看", systemImage: "eye.slash")
                    Spacer()
                    Toggle("无痕观看", isOn: Binding(get: { store.incognito }, set: { store.setIncognito($0) })).labelsHidden().tint(.green)
                }.padding(18).androidCard()
                NavigationLink { PlatformNoteView(title: "安全 DNS", message: "iPhone 当前使用系统 DNS。Android 应用内的 DoH 设置不适用于系统 AVPlayer；如需自定义 DNS，请在 iPhone 系统或网络配置中设置。") } label: { SettingRow(title: "安全 DNS", symbol: "network", value: "跟随系统") }
                NavigationLink { PlatformNoteView(title: "应用信息", message: "影视 · iPhone 0.1.0\n界面语言：简体中文\n\n支持视频直链、M3U 和兼容影视 JSON API。原生支持茉莉／视界，以及玩偶夸克历史接续；其他 Android 插件尚未适配。\n\n使用个人证书自签安装。") } label: { SettingRow(title: "版本", symbol: "info.circle", value: "0.1.0") }
            }.padding(20)
        }.androidScreen().navigationTitle("设置").navigationBarTitleDisplayMode(.inline).buttonStyle(.plain)
    }
}
struct SettingRow: View {
    let title: String, symbol: String, value: String
    var body: some View {
        HStack(spacing: 12) {
            Label(title, systemImage: symbol)
            Spacer(minLength: 8)
            Text(value).font(.subheadline).foregroundStyle(.white.opacity(0.75)).lineLimit(1).truncationMode(.middle)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.white.opacity(0.7))
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).androidCard().contentShape(Rectangle())
    }
}
struct WallpaperSettingsView: View {
    @AppStorage("ios.wallpaper") private var wallpaper = 1
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 16) {
                ForEach(1...4, id: \.self) { index in
                    Button { wallpaper = index } label: {
                        VStack {
                            Image(index == 1 ? "AndroidWallpaper" : "AndroidWallpaper\(index)").resizable().scaledToFill().frame(height: 130).clipped()
                            HStack { Text("壁纸 \(index)"); if wallpaper == index { Image(systemName: "checkmark.circle.fill") } }.padding(12)
                        }.androidCard().clipShape(RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityLabel("壁纸 \(index)\(wallpaper == index ? "，已选择" : "")")
                }
            }.padding(20)
            Text("与 Android 共用内置壁纸，选择仅影响这台 iPhone。").font(.footnote).padding(.horizontal, 20)
        }.androidScreen().navigationTitle("壁纸")
    }
}
struct PlaybackSettingsView: View {
    @AppStorage("ios.resumePlayback") private var resume = true
    @AppStorage("ios.playbackRate") private var rate = 1.0
    var body: some View {
        Form {
            Section("播放器") {
                LabeledContent("播放核心", value: "自动选择 AVPlayer / VLC")
                Toggle("自动接续播放进度", isOn: $resume).tint(.green)
                Picker("默认播放速度", selection: $rate) {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in Text("\(value.formatted()) 倍").tag(value) }
                }
            }.listRowBackground(Color.black.opacity(0.26))
            Section {
                Text("倍速与接续开关仅在这台 iPhone 生效。清晰度、音轨和字幕可在播放控制栏切换，可选内容取决于视频源；小屏和全屏均可设置片头、片尾。")
                Text("Android 的 MPV、Exo、解码器及 libass 设置不会应用到 iPhone。")
            }.font(.footnote).foregroundStyle(.white.opacity(0.8)).listRowBackground(Color.black.opacity(0.26))
        }.androidScreen().navigationTitle("播放设置")
    }
}
struct PlatformNoteView: View {
    let title: String, message: String
    var body: some View {
        ScrollView { Text(message).frame(maxWidth: .infinity, alignment: .leading).padding(20).androidCard().padding(20) }
            .androidScreen().navigationTitle(title)
    }
}

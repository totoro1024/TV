import SwiftUI
import TVCore

/// 复用电视端壁纸与透明卡片，保留手机的触屏导航和动态字体。
struct AndroidBackground: View {
    @AppStorage("ios.wallpaper") private var wallpaper = 1
    var body: some View {
        GeometryReader { proxy in
            Image(wallpaper == 1 ? "AndroidWallpaper" : "AndroidWallpaper\(wallpaper)").resizable().scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                .overlay(Color.black.opacity(0.30))
        }.ignoresSafeArea().accessibilityHidden(true)
    }
}
struct AndroidScreen: ViewModifier {
    func body(content: Content) -> some View {
        content.scrollContentBackground(.hidden).background { AndroidBackground() }
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarBackground(Color.black.opacity(0.45), for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .foregroundStyle(.white).tint(.white)
    }
}
extension View {
    func androidScreen() -> some View { modifier(AndroidScreen()) }
    func androidCard() -> some View {
        background(Color.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 10))
    }
}
struct HomeTile: View {
    let title: String, symbol: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30, weight: .regular)).accessibilityHidden(true)
            Text(title).font(.body)
        }.frame(maxWidth: .infinity).frame(minHeight: 100).contentShape(Rectangle())
    }
}
struct AndroidTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(.white)
            .background(Color.black.opacity(configuration.isPressed ? 0.5 : 0.26), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(configuration.isPressed ? 1 : 0), lineWidth: 2))
    }
}
struct PosterCard: View {
    let name: String, picture: String, remark: String
    var badge: String = ""
    var width: CGFloat? = 132
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.white.opacity(0.12)).aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay {
                    AsyncImage(url: URL(string: picture)) { image in image.resizable().scaledToFill() } placeholder: {
                        Image(systemName: "paperplane").font(.title2)
                    }
                }.clipped()
                .overlay(alignment: .topLeading) {
                    if !badge.isEmpty { Text(badge).font(.caption).lineLimit(1).padding(5).background(Color.red.opacity(0.7), in: RoundedRectangle(cornerRadius: 6)).padding(4) }
                }
                .overlay(alignment: .bottomLeading) {
                    if !remark.isEmpty { Text(remark).font(.caption).lineLimit(1).padding(5).background(.black.opacity(0.5)) }
                }
            if let width {
                Text(name).font(.subheadline).lineLimit(1).frame(width: width - 20).padding(10)
            } else {
                Text(name).font(.caption).lineLimit(2).frame(maxWidth: .infinity, minHeight: 30).padding(6)
            }
        }.frame(width: width).androidCard().clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
struct SourceLibraryScreen: View {
    @Environment(AppStore.self) private var store
    let live: Bool?
    @ViewState private var query = ""
    @ViewState private var adding = false
    var body: some View {
        List {
            ForEach(store.records("source").filter { record in
                (live == nil || (record.entry["value"]["type"].int == 1) == live!) &&
                (query.isEmpty || (record.entry["value"]["name"].string.localizedStandardContains(query) || record.entry["value"]["url"].string.localizedStandardContains(query)))
            }, id: \.id) { record in
                NavigationLink { if record.entry["value"]["type"].int == 1 { LiveTVScreen(initialSourceID:record.id).androidScreen() } else { SourceScreen(sourceID: record.id, value: record.entry["value"]).androidScreen() } } label: {
                    Label(SourcePresentation.description(record.entry["value"]), systemImage: live == true ? "video" : "film")
                }.listRowBackground(Color.black.opacity(0.26))
                    .swipeActions {
                        Button("删除", role: .destructive) { store.remove(record.id) }
                            .tint(.red)
                    }
            }
            Section {
                Button { adding = true } label: { Label("添加源或视频直链", systemImage: "plus.circle") }
                if live == nil { Text("先选择影视源，再搜索该源内的影片。").font(.footnote).foregroundStyle(.white.opacity(0.8)) }
            }.listRowBackground(Color.black.opacity(0.26))
        }.buttonStyle(.automatic)
            .navigationTitle(live == nil ? "搜索" : live == true ? "直播" : "点播")
            .searchable(text: $query, prompt: "筛选名称或网址")
            .sheet(isPresented: $adding) { AddSourceView(live: live == true).environment(store).androidScreen() }
    }
}

import SwiftUI
import TVCore

struct MediaDetailScreen: View {
    @Environment(AppStore.self) private var store
    let source: MediaSource, item: MediaItem
    var resume: JSON? = nil
    var restored: MediaDetail? = nil
    @ViewState private var detail: MediaDetail?
    @ViewState private var error: String?
    @ViewState private var showingSynopsis = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        preview.frame(width: 320, height: 180)
                        information.frame(minWidth: 280, maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        preview.aspectRatio(16/9, contentMode: .fit)
                        information
                    }
                }
                if let detail {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            Button { showingSynopsis = true } label: { Label("简介", systemImage: "doc.text").padding(12).androidCard() }.disabled(detail.synopsis.isEmpty)
                            if let first = detail.episodes.first { FavoriteButton(request: .init(source: source, item: detail.item, episode: first)) }
                            NavigationLink { SourceSearchScreen(sourceID: source.sourceID, preferredSiteID: source.id, initialQuery: detail.item.name) } label: { Label("换源", systemImage: "arrow.triangle.2.circlepath").padding(12).androidCard() }
                        }.buttonStyle(.plain)
                    }
                    if !detail.resources.isEmpty {
                        HStack { Text("选择资源").font(.headline);Spacer();Text("\(detail.resources.count) 个版本").font(.caption) }
                        ForEach(detail.resources) { resource in
                            NavigationLink { MediaDetailScreen(source:source,item:.init(id:resource.id,name:detail.item.name,picture:detail.item.picture,remarks:resource.remarks)) } label: {
                                HStack(alignment:.top) { Text(resource.name).frame(maxWidth:.infinity,alignment:.leading);Image(systemName:"chevron.right") }.padding(14).androidCard()
                            }.buttonStyle(.plain)
                        }
                    } else {
                    EpisodeSelector(episodes: detail.episodes, selected: nil, initialLine: detail.episodes.first(where: { $0.matchesHistory(resume) })?.line ?? resume?["line"].string) { play($0, detail: detail) }
                    }
                } else if let error {
                    Text(error).foregroundStyle(.orange)
                    Button("重试") { Task { await load() } }
                } else { ProgressView("读取影片…").frame(maxWidth: .infinity) }
            }.padding(20)
        }.androidScreen().navigationTitle(item.name).navigationBarTitleDisplayMode(.inline)
            .task(id: item.id) { await load() }
            .sheet(isPresented: $showingSynopsis) {
                NavigationStack {
                    ScrollView { Text(detail?.synopsis ?? "").frame(maxWidth:.infinity,alignment:.leading).padding(20) }
                        .androidScreen().navigationTitle("简介")
                        .toolbar { ToolbarItem(placement:.confirmationAction) { Button("关闭") { showingSynopsis=false } } }
                }.presentationDetents([.medium,.large])
            }
    }
    private var preview: some View {
        Button {
            if let detail, let first=detail.episodes.first { play(detail.episodes.first(where:{$0.matchesHistory(resume)}) ?? first,detail:detail) }
        } label: {
            ZStack {
                FilmPoster(item:detail?.item ?? item)
                Color.black.opacity(0.2)
                Image(systemName:"play.circle.fill").font(.system(size:52)).shadow(radius:5)
                VStack { Spacer();Text(resume == nil ? "立即播放":"继续观看").font(.subheadline).padding(10) }
            }.clipped().androidCard()
        }.buttonStyle(.plain).disabled(detail?.episodes.isEmpty != false).accessibilityLabel(resume == nil ? "立即播放":"继续观看")
    }
    private var information: some View {
        VStack(alignment:.leading,spacing:9) {
            Text(detail?.item.name ?? item.name).font(.title2.bold())
            Text("站源："+source.name).font(.subheadline)
            if !(detail?.item.remarks ?? item.remarks).isEmpty { Text(detail?.item.remarks ?? item.remarks).font(.subheadline) }
            ForEach(["年份","地区","类型","导演","演员"],id:\.self) { key in
                if let value=detail?.metadata[key], !value.isEmpty { Text(key+"："+value).font(.subheadline).lineLimit(key == "演员" ? 3:2) }
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private func play(_ episode: Episode, detail: MediaDetail) { store.play(.init(source: source, item: detail.item, episode: episode, detail: detail)) }
    private func load() async {
        error = nil
        do {
            if let restored { detail = restored }
            else {
                var loaded = try await store.mediaDetail(source, id: item.id)
                if source.kind == .seedhub && (loaded.item.name.isEmpty || loaded.item.name == "聚剧资源") {
                    loaded.item.name = item.name
                    if loaded.item.picture.isEmpty { loaded.item.picture = item.picture }
                }
                detail = loaded
            }
        }
        catch {
            if source.kind == .wogg, let resume, !resume["episodeUrl"].string.isEmpty {
                detail = MediaDetail(item: item, episodes: [.init(name: resume["episode"].string, url: resume["episodeUrl"].string, line: resume["line"].string)], synopsis: "完整选集暂时读取失败，仍可接续原观看记录。")
            } else { self.error = (error as? TVError)?.localizedDescription ?? (error as? DAVFailure)?.localizedDescription ?? NetworkIssue.message(error, context: "读取详情") }
        }
    }
}

struct FavoriteButton: View {
    @Environment(AppStore.self) private var store
    let request: PlaybackRequest
    var body: some View {
        let selected = store.isFavorite(request)
        Button { store.toggleFavorite(request) } label: {
            Label(selected ? "取消收藏" : "收藏", systemImage: selected ? "star.fill" : "star")
                .foregroundStyle(selected ? Color.yellow : Color.white)
                .padding(12).androidCard()
        }
        .accessibilityValue(selected ? "已收藏" : "未收藏")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 对照电视端 flag/episode/array：横向线路、排序入口、网格选集。
struct EpisodeSelector: View {
    let episodes: [Episode]
    let selected: Episode?
    var initialLine: String? = nil
    let choose: (Episode) -> Void
    @ViewState private var line = ""
    @ViewState private var reversed = false
    private var lines: [String] { episodes.reduce(into: []) { if !$0.contains($1.line) { $0.append($1.line) } } }
    private var activeLine: String { lines.contains(line) ? line : (lines.contains(initialLine ?? "") ? initialLine! : lines.first ?? "") }
    private var visible: [Episode] { let result = episodes.filter { $0.line == activeLine }; return reversed ? result.reversed() : result }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("播放线路").font(.headline); Spacer(); Text("\(lines.count) 条线路").font(.caption).foregroundStyle(.white.opacity(0.7)) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(lines, id: \.self) { name in
                        Button { line = name } label: { Text(name).padding(.horizontal, 16).padding(.vertical, 12).background(Color.black.opacity(name == activeLine ? 0.55 : 0.25), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(name == activeLine ? 1 : 0), lineWidth: 1.5)) }.accessibilityAddTraits(name == activeLine ? .isSelected : [])
                    }
                }
            }
            HStack { Text("选集").font(.headline); Spacer(); Button { reversed.toggle() } label: { Label(reversed ? "倒序" : "正序", systemImage: "arrow.up.arrow.down") } }
            LazyVGrid(columns: [GridItem(.flexible(minimum: 0), spacing: 12), GridItem(.flexible(minimum: 0), spacing: 12)], spacing: 12) {
                ForEach(visible) { episode in
                    Button { choose(episode) } label: {
                        Text(episode.name).font(.subheadline).lineLimit(nil).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, minHeight: 56).padding(.horizontal, 10).padding(.vertical, 8).androidCard()
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(episode.id == selected?.id ? 1 : 0), lineWidth: 2))
                    }.id(episode.id)
                        .accessibilityAddTraits(episode.id == selected?.id ? .isSelected : []).accessibilityLabel("\(episode.name)，\(episode.line)")
                }
            }
            if episodes.isEmpty { Text("此源未提供可播放剧集").foregroundStyle(.white.opacity(0.7)) }
        }.buttonStyle(.plain)
            .onChange(of: selected?.id) { _, _ in
                if let selected, lines.contains(selected.line) { line = selected.line }
            }
    }
}
struct FilmPoster: View {
    let item: MediaItem
    var body: some View {
        GeometryReader { proxy in
            RemotePoster(address: item.picture).frame(width: proxy.size.width, height: proxy.size.height).clipped()
                .overlay(alignment: .bottomTrailing) { if !item.remarks.isEmpty { Text(item.remarks).font(.caption2).lineLimit(1).padding(5).background(.black.opacity(0.6)) } }
        }.clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
struct FilmGridCard: View {
    let item: MediaItem
    var body: some View {
        VStack(spacing: 0) {
            FilmPoster(item: item).aspectRatio(0.72, contentMode: .fit)
            Text(item.name).font(.subheadline).lineLimit(2).frame(maxWidth: .infinity, minHeight: 42).padding(.horizontal, 6)
        }.androidCard().clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
struct SavedListView: View {
    @Environment(AppStore.self) private var store
    let kind: String, title: String
    @ViewState private var selecting = false
    @ViewState private var selected = Set<String>()
    @ViewState private var confirmingDelete = false
    private var records: [(id:String,entry:JSON)] { store.records(kind) }
    private var availableIDs: Set<String> { Set(records.map(\.id)) }
    var body: some View {
        Group {
            if records.isEmpty { EmptyHint(title: "还没有\(title)", message: "播放或收藏影片后显示在这里，也可以先从 WebDAV 同步。", symbol: kind == "history" ? "clock" : "star") }
            else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 12) {
                        ForEach(records, id: \.id) { record in
                            if selecting {
                                Button {
                                    if !selected.insert(record.id).inserted { selected.remove(record.id) }
                                } label: {
                                    poster(record).overlay(alignment:.topTrailing) {
                                        Image(systemName:selected.contains(record.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.title2).foregroundStyle(.white,Color.green)
                                            .padding(6).background(.black.opacity(0.45),in:Circle()).padding(4)
                                    }.overlay { RoundedRectangle(cornerRadius:12).stroke(selected.contains(record.id) ? Color.white : .clear,lineWidth:2) }
                                }.buttonStyle(.plain)
                                    .accessibilityLabel(record.entry["value"]["name"].string)
                                    .accessibilityValue(selected.contains(record.id) ? "已选择" : "未选择")
                            } else {
                                NavigationLink { SavedDestination(value: record.entry["value"], isHistory: kind == "history").androidScreen() } label: { poster(record) }
                                    .buttonStyle(.plain)
                                    .contextMenu { Button("删除", role: .destructive) { store.remove(record.id) } }
                            }
                        }
                    }.padding(12)
                }.refreshable { await store.synchronize() }
            }
        }.androidScreen().navigationTitle(title)
        .toolbar {
            ToolbarItem(placement:.topBarTrailing) {
                if selecting {
                    Button("取消") { selecting = false; selected = [] }
                } else if !records.isEmpty {
                    Button("多选") { selecting = true; selected = [] }
                }
            }
            ToolbarItem(placement:.topBarLeading) {
                if selecting {
                    Button(selected == availableIDs ? "取消全选" : "全选") {
                        selected = selected == availableIDs ? [] : availableIDs
                    }
                }
            }
        }
        .safeAreaInset(edge:.bottom) {
            if selecting {
                HStack {
                    Text("已选择 \(selected.count) 项").font(.subheadline)
                    Spacer()
                    Button("删除所选",role:.destructive) { confirmingDelete = true }
                        .disabled(selected.isEmpty)
                }.padding(16).background(.black.opacity(0.8))
            }
        }
        .confirmationDialog("删除选中的 \(selected.count) 项？",isPresented:$confirmingDelete,titleVisibility:.visible) {
            Button("删除 \(selected.count) 项",role:.destructive) {
                if store.removeSaved(selected,kind:kind) { selected = []; selecting = false }
            }
            Button("取消",role:.cancel) { }
        } message: {
            Text(kind == "history" ? "同时删除所选节目的各集播放进度；删除结果将随 WebDAV 同步。" : "从收藏中移除所选条目；删除结果将随 WebDAV 同步。")
        }
        .onChange(of:availableIDs) { _, ids in
            selected.formIntersection(ids)
            if ids.isEmpty { selecting = false; confirmingDelete = false }
        }
    }
    private func poster(_ record:(id:String,entry:JSON)) -> some View {
        PosterCard(name:record.entry["value"]["name"].string,picture:record.entry["value"]["picture"].string,remark:record.entry["value"]["episode"].string,width:nil)
    }
}
struct SavedDestination: View {
    @Environment(AppStore.self) private var store
    let value: JSON, isHistory: Bool
    @ViewState private var source: MediaSource?
    @ViewState private var error: String?
    @ViewState private var loading = true
    var body: some View {
        Group {
            if !isHistory && value["type"].int == 1 {
                LiveTVScreen(initialSourceID:value["iosSource"].string.isEmpty ? nil:value["iosSource"].string,initialChannel:value["channel"].string.isEmpty ? value["name"].string:value["channel"].string)
            } else if let source {
                if (source.kind == .api || source.kind == .app99) { MediaDetailScreen(source: source, item: .init(id: value["vod"].string, name: value["name"].string, picture: value["picture"].string), resume: isHistory ? value : nil) }
                else if source.kind == .wogg {
                    let item = MediaItem(id: value["vod"].string, name: value["name"].string, picture: value["picture"].string)
                    let episode = Episode(name: value["episode"].string, url: value["episodeUrl"].string, line: value["line"].string)
                    MediaDetailScreen(source: source, item: item, resume: isHistory ? value : nil,
                        restored: item.id.isEmpty || !item.id.allSatisfy({ $0.isASCII && $0.isNumber }) ? MediaDetail(item: item, episodes: [episode], synopsis: "从已同步的观看记录接续此剧集。") : nil)
                }
                else if source.kind == .unsupported { EmptyHint(title: "此源待适配 iPhone", message: source.reason, symbol: "iphone.slash") }
                else {
                    List {
                        Text(value["name"].string).font(.title2)
                        Button("播放") {
                            let url = value["episodeUrl"].string.isEmpty ? source.address : value["episodeUrl"].string
                            store.play(.init(source: source, item: .init(id: value["vod"].string, name: value["name"].string, picture: value["picture"].string), episode: .init(name: value["episode"].string, url: url, line: value["line"].string)))
                        }
                    }
                }
            } else if loading { ProgressView("正在解析原始源…") }
            else { EmptyHint(title: "暂时无法接续", message: error ?? "原始源不存在", symbol: "exclamationmark.triangle") }
        }.task {
            if !isHistory && value["type"].int == 1 { loading=false;return }
            defer { loading = false }
            do {
                if value["type"].int == 1 && value["iosSource"].string.isEmpty && value["source"].string.isEmpty {
                    throw TVError.message("电视端直播收藏只包含频道名，请先打开对应 M3U 列表选择频道")
                }
                let id = value["source"].string.isEmpty ? value["iosSource"].string : value["source"].string
                guard let record = store.replica.document.records[id], !record["deleted"].flag else { throw TVError.message("原始源不存在，请先同步源配置") }
                let sources = try await SourceResolver.resolve(sourceID: id, value: record["value"])
                guard let match = sources.first(where: { $0.id == (value["site"].string.isEmpty ? value["iosSite"].string : value["site"].string) }) else { throw TVError.message("原始站点不存在，不会按片名跨源匹配") }
                source = match
            } catch { self.error = (error as? TVError)?.localizedDescription ?? "源配置读取失败" }
        }
    }
}

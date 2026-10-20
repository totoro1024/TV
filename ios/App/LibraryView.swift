import SwiftUI
import TVCore

struct LibraryView: View {
    @Environment(AppStore.self) private var store
    @ViewState private var choosingSource = false
    @ViewState private var home: MediaSource?
    @ViewState private var recommendations: [MediaItem] = []
    @ViewState private var loading = false
    @ViewState private var recommendationHint = ""
    @ViewState private var homeRequest = UUID()
    @ViewState private var selectionRevision = 0
    private var selected: (id: String, entry: JSON)? {
        let sources = store.records("source").filter { $0.entry["value"]["type"].int == 0 }
        let preference = store.replica.document.records[SyncDocument.identity("preference", "activeSource0")]
        if let preference, !preference["deleted"].flag {
            return sources.first { $0.entry["value"]["url"].string == preference["value"]["url"].string }
        }
        return sources.first
    }
    private var selectionKey: String { (selected?.id ?? "") + "|" + (selected?.entry["value"]["home"].string ?? "") }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Image("AndroidLogo").resizable().scaledToFit().frame(width: 44, height: 44)
                    Button { choosingSource = true } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(home?.name ?? selected.map { SourcePresentation.description($0.entry["value"]) } ?? "影视")
                                .font(.title3).lineLimit(1)
                            Label("切换源", systemImage: "chevron.down").font(.caption).foregroundStyle(.white.opacity(0.8))
                        }
                    }.buttonStyle(.plain).accessibilityLabel("切换源，当前" + (home?.name ?? "未选择站点"))
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(context.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                            .font(.subheadline.monospacedDigit())
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    NavigationLink { currentCatalog(search: false) } label: { HomeTile(title: "点播", symbol: "film") }.disabled(loading)
                    NavigationLink { LiveTVScreen().androidScreen() } label: { HomeTile(title: "直播", symbol: "video") }
                    NavigationLink { currentCatalog(search: true) } label: { HomeTile(title: "搜索", symbol: "magnifyingglass") }.disabled(loading)
                }.buttonStyle(AndroidTileStyle())
                HStack {
                    Text("历史").font(.title2)
                    Spacer()
                    NavigationLink("查看全部") { SavedListView(kind: "history", title: "继续观看").androidScreen() }.font(.subheadline)
                }
                if store.records("history").isEmpty {
                    Text("暂无观看记录").foregroundStyle(.white.opacity(0.8)).padding(18).frame(maxWidth: .infinity, alignment: .leading).androidCard()
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(Array(store.records("history").prefix(12)), id: \.id) { record in
                                NavigationLink { SavedDestination(value: record.entry["value"], isHistory: true).androidScreen() } label: {
                                    PosterCard(name: record.entry["value"]["name"].string, picture: record.entry["value"]["picture"].string, remark: record.entry["value"]["episode"].string, badge: record.entry["value"]["site"].string)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                Text("推荐").font(.title2)
                if loading { ProgressView("正在加载推荐…").frame(maxWidth: .infinity) }
                if let home, !recommendations.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 18) {
                        ForEach(recommendations) { item in
                            NavigationLink { if home.kind == .doudou { DouDouPlaybackSearch(source: home, title: item.name, item: item) } else { MediaDetailScreen(source: home, item: item) } } label: { FilmGridCard(item: item) }.buttonStyle(.plain)
                        }
                    }
                } else if !loading {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(recommendationHint).font(.subheadline).foregroundStyle(.white.opacity(0.8))
                        Button("切换站点") { choosingSource = true }
                        Button("重新加载") { Task { await loadHome() } }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).androidCard()
                }
            }.padding(20)
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $choosingSource) {
            HomeSourcePicker(initialID: selected?.id) { source in
                homeRequest = UUID()
                home = source
                recommendations = []
                recommendationHint = ""
                loading = true
                selectionRevision += 1
            }.environment(store)
        }
        .task(id: selectionKey + "|" + String(selectionRevision) + "|" + String(store.siteAccessRevision)) { await loadHome() }
        .refreshable { await store.synchronize(); await loadHome() }
    }
    @ViewBuilder private func currentCatalog(search: Bool) -> some View {
        if let home {
            if home.isUtility { UtilitySourceView(source:home) }
            else if search {
                SourceSearchScreen(sourceID: home.sourceID, preferredSiteID: home.id)
            } else if home.kind == .unsupported {
                EmptyHint(title: "此站点待适配 iPhone", message: home.reason, symbol: "iphone.slash").androidScreen()
            } else if home.kind == .doudou && search {
                DouDouPlaybackSearch(source: home, title: "")
            } else {
                CatalogScreen(source: home, searchMode: search)
            }
        } else {
            EmptyHint(title: "当前源尚未就绪", message: "请返回首页切换源，或重新加载当前源。", symbol: "exclamationmark.triangle").androidScreen()
        }
    }
    private func loadHome() async {
        let request = UUID(), key = selectionKey
        homeRequest = request
        home = nil; recommendations = []; recommendationHint = "请先配置影视源"; loading = true
        defer { if homeRequest == request { loading = false } }
        guard let selected else { return }
        do {
            let sites = try await SourceResolver.resolve(sourceID: selected.id, value: selected.entry["value"])
            try Task.checkCancellation()
            guard homeRequest == request, selectionKey == key else { return }
            let site = sites.first { $0.id == selected.entry["value"]["home"].string } ?? sites.first
            home = site
            guard let site else { recommendationHint = "此源未提供站点"; return }
            if site.isUtility { recommendationHint = site.utilityDescription; return }
            guard site.supportsCatalog else {
                recommendationHint = "\(site.name) 依赖尚未适配的 Android 插件，暂时无法读取推荐。请切换到已支持的站点。"
                return
            }
            if [.cloudSearch,.cloudMirror].contains(site.kind) { recommendationHint="此源是网盘搜索入口，请进入点播或搜索输入片名";return }
            let items = try await CatalogClient().browse(site)
            try Task.checkCancellation()
            guard homeRequest == request, selectionKey == key else { return }
            recommendations = items
            recommendationHint = "此站点暂无推荐内容"
        } catch {
            guard !Task.isCancelled, homeRequest == request, selectionKey == key else { return }
            if let kind = home?.kind, [.music, .legacySite, .jpys].contains(kind), let failure = error as? TVError {
                recommendationHint = failure.localizedDescription + "。请进入点播打开网站验证。"
            } else if let failure = error as? DAVFailure { recommendationHint = failure.localizedDescription }
            else { recommendationHint = NetworkIssue.message(error, context: "推荐加载") }
        }
    }
}

/// 先浏览配置中的站点，选择后一次提交首页配置和站点。
struct HomeSourcePicker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let initialID: String?
    let onSelect: (MediaSource) -> Void
    @ViewState private var sourceID = ""
    @ViewState private var sites: [MediaSource] = []
    @ViewState private var query = ""
    @ViewState private var loading = false
    @ViewState private var error: String?
    @ViewState private var adding = false
    private var configurations: [(id: String, entry: JSON)] {
        store.records("source").filter { $0.entry["value"]["type"].int == 0 }
    }
    var body: some View {
        NavigationStack {
            List {
                Section("影视源配置") {
                    ForEach(configurations, id: \.id) { record in
                        Button { sourceID = record.id } label: {
                            HStack {
                                Text(SourcePresentation.description(record.entry["value"])).lineLimit(2)
                                Spacer()
                                if sourceID == record.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    Button("添加影视源") { adding = true }
                }.listRowBackground(Color.black.opacity(0.26))
                Section("选择首页站点") {
                    if loading { ProgressView("正在读取站点…") }
                    if let error {
                        Text(error).font(.subheadline)
                        Button("重试") { Task { await loadSites() } }
                    }
                    ForEach(sites.filter { query.isEmpty || $0.name.localizedStandardContains(query) }) { site in
                        Button {
                            store.selectSource(site.sourceID)
                            store.selectSite(site)
                            onSelect(site)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(site.name)
                                    if site.isUtility { Text("功能入口，非点播目录").font(.caption).foregroundStyle(.secondary) }
                                    if site.kind == .unsupported { Text("此站点待适配 iPhone").font(.caption).foregroundStyle(.secondary) }
                                    if site.kind == .wogg { Text("支持推荐、分类、搜索与夸克、UC播放").font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if sourceID == initialID, let record = store.replica.document.records[sourceID], record["value"]["home"].string == site.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    if !loading && error == nil && sites.isEmpty { Text("请先选择影视源配置") }
                }.listRowBackground(Color.black.opacity(0.26))
            }.androidScreen().navigationTitle("切换源").navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: "搜索站点名称")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                .onAppear { if sourceID.isEmpty { sourceID = initialID ?? configurations.first?.id ?? "" } }
                .task(id: sourceID) { await loadSites() }
                .sheet(isPresented: $adding) { AddSourceView().environment(store) }
        }
    }
    private func loadSites() async {
        let requestedID = sourceID
        sites = []; error = nil
        guard let record = configurations.first(where: { $0.id == requestedID }) else { return }
        loading = true
        do {
            let result = try await SourceResolver.resolve(sourceID: requestedID, value: record.entry["value"])
            try Task.checkCancellation()
            guard sourceID == requestedID else { return }
            sites = result; loading = false
        } catch {
            guard sourceID == requestedID, !Task.isCancelled else { return }
            self.error = "读取站点失败，请检查网络后重试"; loading = false
        }
    }
}

/// DouDou 原插件的推荐条目使用片名搜索，不包含视频直链。
struct DouDouPlaybackSearch: View {
    let source: MediaSource
    let title: String
    var item: MediaItem? = nil
    var body: some View {
        SourceSearchScreen(sourceID: source.sourceID, preferredSiteID: source.id, initialQuery: title, recommendation: item)
    }
}

/// iPhone 接收直链输入；不冒充 Android 的局域网扫码接收服务。
struct PushVideoView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @ViewState private var address = ""
    @ViewState private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("视频网址") {
                    TextField("粘贴 HTTP / HTTPS 视频直链", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Button("播放") {
                        let url = address.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard CatalogParser.playable(url) else { error = "请输入支持的视频直链"; return }
                        dismiss()
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            store.play(.init(source: .init(id: "push", sourceID: "push", name: "推送", address: url, kind: .direct), item: .init(id: SyncDocument.identity(url), name: "推送视频"), episode: .init(name: "播放", url: url)))
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
                Text("在此粘贴手机收到的视频直链即可播放；影视源请在设置中配置。")
            }.androidScreen().navigationTitle("推送").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }
}
struct AddSourceView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    @ViewState private var address = ""
    @ViewState private var live = false
    init(live: Bool = false) { _live = ViewState(wrappedValue: live) }
    @ViewState private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("名称（可选）", text: $name)
                TextField("HTTP / HTTPS 地址", text: $address).autocorrectionDisabled()
                Toggle("直播列表", isOn: $live)
                if let error { Text(error).foregroundStyle(.red) }
                Section { Text("直播支持 Android TV 的 lives 配置、M3U、TXT、JSON 频道列表及 HLS 直链。登录页面和网盘分享页请使用对应的点播源。") .font(.footnote) }
            }.androidScreen().navigationTitle("添加源")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") {
                        do { try store.addSource(name: name, address: address.trimmingCharacters(in: .whitespacesAndNewlines), live: live); dismiss() }
                        catch { self.error = error.localizedDescription }
                    } }
                }
        }
    }
}
struct SourceScreen: View {
    @Environment(AppStore.self) private var store
    let sourceID: String, value: JSON
    @ViewState private var sources: [MediaSource] = []
    @ViewState private var error: String?
    @ViewState private var loading = true
    var body: some View {
        Group {
            if loading { ProgressView("正在读取源…") }
            else if let error { EmptyHint(title: "无法读取此源", message: error, symbol: "exclamationmark.triangle") }
            else {
                List(sources) { source in
                    if source.kind == .unsupported {
                        VStack(alignment: .leading, spacing: 6) { Label(source.name, systemImage: "iphone.slash"); Text(source.reason).font(.caption).foregroundStyle(.secondary) }
                    } else if source.isUtility { NavigationLink(source.name) { UtilitySourceView(source:source) } }
                    else { NavigationLink(source.name) { CatalogScreen(source: source) } }
                }
            }
        }.androidScreen().navigationTitle(SourcePresentation.description(value))
            .task(id: sourceID) {
                store.selectSource(sourceID)
                do { sources = try await SourceResolver.resolve(sourceID: sourceID, value: value).sorted { ($0.kind == .unsupported ? 1 : 0) < ($1.kind == .unsupported ? 1 : 0) } }
                catch { self.error = (error as? TVError)?.localizedDescription ?? "读取失败，请检查网络和源格式" }; loading = false
            }
    }
}
enum SourceResolver {
    static func resolve(sourceID: String, value: JSON) async throws -> [MediaSource] {
        let address = value["url"].string, ext = URL(string: address)?.pathExtension.lowercased() ?? ""
        guard CatalogParser.validHTTP(address) else { throw TVError.message("此源依赖本地文件或 Android 插件，iPhone 无法直接读取") }
        let name = SourcePresentation.description(value)
        if ["m3u8","mp4","mov","m4v","mp3","aac"].contains(ext) { return [MediaSource(id: "direct", sourceID: sourceID, name: name, address: address, kind: .direct)] }
        if ext == "m3u" { return [MediaSource(id: "m3u", sourceID: sourceID, name: name, address: address, kind: .playlist)] }
        return try CatalogParser.configuration(data: await CatalogClient().fetch(address), address: address, sourceID: sourceID)
    }
}
struct CatalogScreen: View {
    @Environment(AppStore.self) private var store
    let source: MediaSource
    var searchMode = false
    var initialQuery = ""
    @FocusState private var searchFocused: Bool
    @ViewState private var submittedQuery = ""
    @ViewState private var category = ""
    @ViewState private var items: [MediaItem] = []
    @ViewState private var channels: [Episode] = []
    @ViewState private var nativeCategories: [(id:String,name:String)] = []
    @ViewState private var query = ""
    @ViewState private var page = 1
    @ViewState private var loading = false
    @ViewState private var verifyingMusic = false
    @ViewState private var musicVerified = false
    @ViewState private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(source.name).font(.title3.bold()).lineLimit(1)
                    Spacer()
                    Text(source.kind == .playlist ? "直播" : "点播").font(.caption).padding(8).androidCard()
                }
                if [.cloudSearch,.cloudMirror].contains(source.kind) { Text("此源仅支持搜索；夸克、UC使用WebDAV同步的Cookie，其他网盘播放仍待移植").font(.caption).foregroundStyle(.secondary) }
                if source.kind == .doudou {
                    NavigationLink("搜索片单中的影片") { DouDouPlaybackSearch(source: source, title: "") }
                    Text("豆豆提供推荐片单；点击影片后选择兼容站点搜索播放。失效的广告及片单占位条目会自动过滤。 ").font(.caption).foregroundStyle(.secondary)
                } else { HStack {
                    Image(systemName: "magnifyingglass")
                    TextField("搜索影视", text: $query).submitLabel(.search).autocorrectionDisabled().focused($searchFocused)
                    if !query.isEmpty { Button { query = ""; reload() } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("清空搜索") }
                    Button("搜索") { reload() }
                }.padding(14).androidCard().onSubmit { reload() } }
                if (source.kind == .bili || source.kind == .website || source.kind == .t4 || source.kind == .apptt || source.kind == .appsx || source.kind == .legacySite || source.kind == .doubao || source.kind == .jpj || source.kind == .music || source.kind == .sixv || source.kind == .alllive || source.kind == .kanqiu || source.kind == .aidj || source.kind == .seedhub || source.kind == .jpys || source.kind == .appgz || source.kind == .streamSite || source.kind == .livegz || source.kind == .hmys || source.kind == .audiobook) && !searchMode {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(nativeCategories, id: \.id) { entry in
                                Button(entry.name) { guard !loading else { return }; category = entry.id; query = ""; reload() }
                                    .padding(10).androidCard().accessibilityAddTraits(category == entry.id ? .isSelected : [])
                            }
                        }
                    }
                }
                if source.kind == .wogg && !searchMode {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(WoggClient.categories, id: \.id) { entry in
                                Button {
                                    guard !loading else { return }
                                    category = entry.id; query = ""; reload()
                                } label: {
                                    Text(entry.name).padding(.horizontal, 16).padding(.vertical, 10).androidCard()
                                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(category == entry.id ? 1 : 0), lineWidth: 1.5))
                                }.accessibilityAddTraits(category == entry.id ? .isSelected : [])
                            }
                        }
                    }
                }
                if source.kind == .direct {
                    Button { store.play(.init(source: source, item: .init(id: SyncDocument.identity(source.address), name: source.name), episode: .init(name: source.name, url: source.address))) } label: { Label("播放视频", systemImage: "play.fill").padding(18).androidCard() }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 18) {
                    ForEach(items) { item in
                        NavigationLink { if source.kind == .doudou { DouDouPlaybackSearch(source: source, title: item.name, item: item) } else { MediaDetailScreen(source: source, item: item) } } label: { FilmGridCard(item: item) }.buttonStyle(.plain)
                    }
                }
                ForEach(channels.filter { query.isEmpty || $0.name.localizedStandardContains(query) || $0.line.localizedStandardContains(query) }) { episode in
                    Button { store.play(.init(source: source, item: .init(id: episode.name, name: episode.name), episode: episode)) } label: {
                        HStack { Image(systemName: "play.tv"); Text(episode.name); Spacer(); Text(episode.line).font(.caption) }.padding(16).androidCard()
                    }.buttonStyle(.plain)
                }
                if loading { ProgressView("加载中…").frame(maxWidth: .infinity) }
                if let error { Text(error).foregroundStyle(.white.opacity(0.8)) }
                if [.music,.legacySite,.jpys].contains(source.kind),error?.contains("验证") == true {
                    Button("打开网站验证") { musicVerified = false;verifyingMusic = true }.padding(14).androidCard()
                }
                if (source.supportsCatalog) && !loading && (!searchMode || !submittedQuery.isEmpty) {
                    Button { if error == nil { page += 1 }; Task { await load() } } label: { Text(error == nil ? "加载下一页" : "重试加载").frame(maxWidth: .infinity).padding(14).androidCard() }
                }
                if searchMode && submittedQuery.isEmpty {
                    Text("在当前站点输入影片名称搜索").font(.subheadline).foregroundStyle(.white.opacity(0.8))
                }
            }.padding(20)
        }.androidScreen().navigationTitle(searchMode ? "搜索" : "影片列表").navigationBarTitleDisplayMode(.inline)
            .task {
                if !initialQuery.isEmpty && submittedQuery.isEmpty { query = initialQuery; submittedQuery = initialQuery }
                if searchMode && initialQuery.isEmpty { searchFocused = true }
                if items.isEmpty && channels.isEmpty && (!searchMode || source.kind == .playlist || !submittedQuery.isEmpty) { await load() }
            }
            .sheet(isPresented:$verifyingMusic,onDismiss:{ if musicVerified { reload() } }) {
                MusicVerificationView(source:source) { musicVerified = true }
            }
            .refreshable { if !searchMode || !submittedQuery.isEmpty { page = 1; items = []; await load() } }
    }
    private func reload() {
        guard !loading else { return }
        submittedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchFocused = false
        page = 1; items = []; error = nil
        guard !searchMode || !submittedQuery.isEmpty || source.kind == .playlist else { return }
        Task { await load() }
    }
    private func load() async {
        if [.cloudSearch,.cloudMirror].contains(source.kind) && submittedQuery.isEmpty { return }
        guard !loading else { return }; loading = true; error = nil; defer { loading = false }
        do {
            if source.kind == .playlist {
                channels = try CatalogParser.playlist(await CatalogClient().fetch(source.address), base: URL(string: source.address)!)
            } else if (source.supportsCatalog) {
                if nativeCategories.isEmpty && !searchMode {
                    if source.kind == .bili { nativeCategories = try await BiliClient().categories(source) }
                    if source.kind == .aidj { nativeCategories = EmbeddedAIClient.categories }
                    if source.kind == .seedhub { nativeCategories = SeedhubClient.categories }
                    if source.kind == .jpys { nativeCategories = AppGzClient.categories }
                    if source.kind == .appgz { nativeCategories = AppGzClient.categories }
                    if source.kind == .jpj { nativeCategories = JPJClient.categories }
                    if source.kind == .music { nativeCategories = try await MusicClient().categories(source) }
                    if source.kind == .sixv { nativeCategories = SixVClient.categories }
                    if source.kind == .alllive { nativeCategories = AllLiveClient.categories }
                    if source.kind == .kanqiu { nativeCategories = KanqiuClient.categories }
                    if source.kind == .streamSite { nativeCategories = PublicStreamClient.categories(source) }
                    if source.kind == .livegz { nativeCategories = LiveGzClient.categories }
                    if source.kind == .hmys { nativeCategories = try await HmysClient.shared.categories() }
                    if source.kind == .audiobook { nativeCategories=AudioBookClient.categories }
                    if source.kind == .doubao { nativeCategories=DoubaoClient.categories }
                    if source.kind == .legacySite { nativeCategories = try await LegacyWebsiteClient().categories(source) }
                    if source.kind == .appsx { nativeCategories = try await AppSxClient.shared.categories(source) }
                    if source.kind == .apptt { nativeCategories = try await AppTTClient().categories(source) }
                    if source.kind == .t4 { nativeCategories = try await T4Client().categories(source) }
                    if source.kind == .website { nativeCategories = try await WebsiteClient().categories(source) }
                }
                let next = try await CatalogClient().browse(source, keyword: submittedQuery, page: page, category: category)
                let existing = Set(items.map(\.id)); items += next.filter { !existing.contains($0.id) }
                if next.isEmpty { error = page == 1 && !submittedQuery.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? "该站点未找到相关内容，请尝试其他关键词" : "没有更多内容" }
            }
        } catch { self.error = (error as? TVError)?.localizedDescription ?? (error as? DAVFailure)?.localizedDescription ?? NetworkIssue.message(error, context: "加载源") }
    }
}
struct MediaRow: View {
    let item: MediaItem
    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: URL(string: item.picture)) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "film").foregroundStyle(.secondary) }
                .frame(width: 55, height: 76).background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) { Text(item.name).font(.headline); Text(item.remarks).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 3)
    }
}

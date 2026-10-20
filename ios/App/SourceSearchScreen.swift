import SwiftUI
import TVCore

private struct SiteSearchResult: Sendable {
    let source: MediaSource
    var items: [MediaItem] = []
    var error: String?
}

/// 对照 CollectActivity：全部结果、各站点分页签，保留同一影视配置内的站点顺序。
struct SourceSearchScreen: View {
    @Environment(AppStore.self) private var store
    let sourceID: String
    var preferredSiteID: String? = nil
    var initialQuery = ""
    var recommendation: MediaItem? = nil
    @ViewState private var query = ""
    @ViewState private var submitted = ""
    @ViewState private var selected = "all"
    @ViewState private var sites: [MediaSource] = []
    @ViewState private var results: [String: SiteSearchResult] = [:]
    @ViewState private var loading = true
    @ViewState private var searching = false
    @ViewState private var error: String?
    @ViewState private var revision = 0
    @ViewState private var pages: [String:Int] = [:]
    @ViewState private var loadingMore = Set<String>()
    @ViewState private var exhausted = Set<String>()
    @FocusState private var focused: Bool
    private func supported(_ site: MediaSource) -> Bool { site.supportsSearch }
    private func enabled(_ site: MediaSource) -> Bool {
        let key = SyncDocument.identity("site", site.id)
        guard let entry = store.replica.document.records[key], !entry["deleted"].flag else { return true }
        return entry["value"]["searchable"].int == 1
    }
    private func hint(_ site: MediaSource) -> String {
        if site.isUtility { return "功能入口，无影片搜索" }
        if site.kind == .doudou { return "推荐片单，无独立搜索" }
        if !supported(site) { return "暂不兼容 iPhone" }
        return enabled(site) ? "可搜索" : "已关闭搜索"
    }
    private var resultSites: [MediaSource] {
        sites.filter { selected == "all" ? (supported($0) && enabled($0)) : $0.id == selected }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let recommendation {
                    HStack(alignment: .top, spacing: 16) {
                        FilmPoster(item: recommendation).frame(width: 160,height: 90)
                        VStack(alignment: .leading,spacing: 10) {
                            Text(recommendation.name).font(.title2.bold())
                            if !recommendation.remarks.isEmpty { Text(recommendation.remarks).font(.subheadline) }
                            Text("选择播放源").font(.headline)
                            Text("正在同一影视配置中查找播放线路").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth:.infinity,alignment:.leading)
                    }
                }
                HStack {
                    Image(systemName:"magnifyingglass")
                    TextField("搜索影视",text:$query).submitLabel(.search).focused($focused).autocorrectionDisabled().onSubmit(submit)
                    Button("搜索",action:submit).disabled(loading || query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                }.padding(14).androidCard()
                if loading { ProgressView("读取所有站点…") }
                if let error { Text(error).foregroundStyle(.orange) }
                ScrollView(.horizontal,showsIndicators:false) {
                    LazyHStack(spacing:10) {
                        sourceTab("全部",id:"all")
                        ForEach(sites) { sourceTab($0.name,id:$0.id) }
                    }
                }
                if submitted.isEmpty {
                    Text("全部站点 · \(sites.count) 个").font(.headline)
                    ForEach(sites) { site in
                        Button { selected=site.id } label: {
                            HStack { Text(site.name);Spacer();Text(hint(site)).font(.caption).foregroundStyle(.secondary) }.padding(14).androidCard()
                        }.buttonStyle(.plain)
                    }.id("available-sites")
                } else {
                    if searching { ProgressView("搜索中，已完成 \(results.count) 个站点") }
                    ForEach(resultSites) { site in
                        VStack(alignment:.leading,spacing:12) {
                            HStack { Text(site.name).font(.headline);Spacer();if let result=results[site.id] { Text("\(result.items.count) 项").font(.caption) } }
                            if !supported(site) || !enabled(site) { Text(hint(site)).font(.subheadline).foregroundStyle(.secondary) }
                            else if let result=results[site.id] {
                                if let error=result.error { Text(error).font(.caption).foregroundStyle(.orange) }
                                else if result.items.isEmpty { Text("没有搜索结果").foregroundStyle(.secondary) }
                                LazyVGrid(columns:[GridItem(.adaptive(minimum:104),spacing:12)],spacing:18) {
                                    ForEach(result.items) { item in
                                        NavigationLink { MediaDetailScreen(source:site,item:item) } label: { FilmGridCard(item:item) }.buttonStyle(.plain)
                                    }
                                }
                                if !result.items.isEmpty && !exhausted.contains(site.id) {
                                    Button(loadingMore.contains(site.id) ? "加载中…":"加载更多") { Task { await loadMore(site) } }.disabled(loadingMore.contains(site.id))
                                }
                            } else { ProgressView("等待搜索…") }
                        }.padding(16).androidCard()
                    }.id("search-results-\(revision)")
                }
            }.padding(20)
        }.androidScreen().navigationTitle(recommendation?.name ?? "搜索").navigationBarTitleDisplayMode(.inline)
        .task { await loadSites(); if initialQuery.isEmpty { focused=true } else { query=initialQuery;submit() } }
        .task(id:revision) { if revision>0 { await search() } }
    }
    private func sourceTab(_ title:String,id:String) -> some View {
        Button { selected=id } label: {
            Text(title).padding(.horizontal,14).padding(.vertical,12).background(Color.black.opacity(selected==id ? 0.55:0.22),in:RoundedRectangle(cornerRadius:8))
                .overlay(RoundedRectangle(cornerRadius:8).stroke(.white.opacity(selected==id ? 1:0),lineWidth:1.5))
        }.buttonStyle(.plain).accessibilityAddTraits(selected==id ? .isSelected:[])
    }
    private func submit() {
        let text=query.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        focused=false;submitted=text;results=[:];pages=[:];loadingMore=[];exhausted=[];revision+=1
    }
    private func loadSites() async {
        defer { loading=false }
        guard let entry=store.replica.document.records[sourceID], !entry["deleted"].flag else { error="请先配置影视源";return }
        do { sites=try await SourceResolver.resolve(sourceID:sourceID,value:entry["value"]) }
        catch { if !NetworkIssue.cancelled(error) { self.error=error is TVError ? error.localizedDescription:NetworkIssue.message(error,context:"读取搜索源") } }
    }
    private func loadMore(_ site: MediaSource) async {
        guard !loadingMore.contains(site.id) else { return }
        let version=revision, term=submitted, page=(pages[site.id] ?? 1)+1
        loadingMore.insert(site.id)
        defer { if revision==version { loadingMore.remove(site.id) } }
        do {
            let next=try await CatalogClient().browse(site,keyword:term,page:page)
            guard !Task.isCancelled, revision==version else { return }
            var result=results[site.id] ?? SiteSearchResult(source:site)
            var ids=Set(result.items.map(\.id))
            result.items += next.filter { ids.insert($0.id).inserted };result.error=nil
            results[site.id]=result;pages[site.id]=page
            if next.isEmpty { exhausted.insert(site.id) }
        } catch {
            guard revision==version, !NetworkIssue.cancelled(error) else { return }
            results[site.id]?.error=error is TVError ? error.localizedDescription:NetworkIssue.message(error,context:"加载更多")
        }
    }
    private func search() async {
        let term=submitted, version=revision
        searching=true
        defer { if revision==version { searching=false } }
        var queue=sites.filter { supported($0) && enabled($0) }
        if let preferredSiteID, let index=queue.firstIndex(where:{$0.id==preferredSiteID}) { queue.insert(queue.remove(at:index),at:0) }
        await withTaskGroup(of:SiteSearchResult.self) { group in
            func add(_ site:MediaSource) {
                group.addTask {
                    do { return SiteSearchResult(source:site,items:try await CatalogClient().browse(site,keyword:term,page:1)) }
                    catch { return SiteSearchResult(source:site,error:NetworkIssue.cancelled(error) ? nil : (error is TVError ? error.localizedDescription:NetworkIssue.message(error,context:"站点搜索"))) }
                }
            }
            for _ in 0..<min(3,queue.count) { add(queue.removeFirst()) }
            for await result in group {
                guard !Task.isCancelled, revision==version else { group.cancelAll();return }
                results[result.source.id]=result
                if !queue.isEmpty { add(queue.removeFirst()) }
            }
        }
    }
}

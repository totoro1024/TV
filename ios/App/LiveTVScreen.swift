import SwiftUI
import TVCore

struct LivePlaybackContext {
    let source: LiveSource
    let sources: [LiveSource]
    let channels: [LiveChannel]
}
struct LiveTVScreen: View {
    @Environment(AppStore.self) private var store
    var initialSourceID: String? = nil
    var initialChannel: String? = nil
    @ViewState private var autoStarted=false
    @ViewState private var searched=Set<String>()
    @ViewState private var loadedConfiguration=""
    @ViewState private var loadedLive=""
    @ViewState private var sourceID = ""
    @ViewState private var sources: [LiveSource] = []
    @ViewState private var selected = ""
    @ViewState private var channels: [LiveChannel] = []
    @ViewState private var group = "全部"
    @ViewState private var query = ""
    @ViewState private var loading = false
    @ViewState private var error: String?
    @ViewState private var adding = false
    private var configurations: [(id:String,entry:JSON)] { store.records("source").filter { $0.entry["value"]["type"].int == 1 } }
    private var active: LiveSource? { sources.first { $0.id == selected } }
    private var groups: [String] { ["全部","收藏"]+channels.map(\.group).reduce(into:[String]()) { if !$0.contains($1) { $0.append($1) } } }
    private var visible: [LiveChannel] { channels.filter { channel in
        (group == "全部" || group == channel.group || group == "收藏" && favorite(channel)) &&
        channel.matches(query)
    } }
    private func favorite(_ channel: LiveChannel) -> Bool {
        store.replica.document.records[SyncDocument.identity("favorite","live",channel.name)]?["deleted"].flag == false
    }
    var body: some View {
        VStack(spacing:12) {
            HStack {
                Menu {
                    ForEach(configurations,id:\.id) { row in Button(SourcePresentation.description(row.entry["value"])) { sourceID=row.id;store.selectSource(row.id) } }
                    Button("添加直播源") { adding=true }
                } label: { Label("直播配置",systemImage:"slider.horizontal.3") }
                Spacer()
                Menu {
                    ForEach(sources) { source in Button { selected=source.id } label: {
                        if selected == source.id { Label(source.name,systemImage:"checkmark") } else { Text(source.name) }
                    } }
                } label: { Label(active?.name ?? "选择直播源",systemImage:"tv") }
            }.font(.subheadline).padding(.horizontal,16)
            HStack {
                Image(systemName:"magnifyingglass")
                TextField("频道名称或频道号",text:$query).autocorrectionDisabled().submitLabel(.search)
                if !query.isEmpty { Button { query="" } label: { Image(systemName:"xmark.circle.fill") }.accessibilityLabel("清空频道搜索") }
            }.padding(12).androidCard().padding(.horizontal,16)
            ScrollView(.horizontal,showsIndicators:false) {
                HStack { ForEach(groups,id:\.self) { name in Button { group=name } label: {
                    Text(name).padding(.horizontal,14).padding(.vertical,10).background(.black.opacity(group==name ? 0.55:0.22),in:RoundedRectangle(cornerRadius:8))
                }.accessibilityAddTraits(group==name ? .isSelected:[]) } }.padding(.horizontal,16)
            }
            if loading { ProgressView("正在加载直播…").frame(maxHeight:.infinity) }
            else if let error { VStack(spacing:16) { EmptyHint(title:"直播加载失败",message:error,symbol:"exclamationmark.triangle");Button("重试") { Task { if sources.isEmpty { await loadSources() } else { await loadChannels() } } } }.padding() }
            else if visible.isEmpty { EmptyHint(title:channels.isEmpty ? "请添加直播源":"没有匹配频道",message:group=="收藏" ? "播放频道后可加入收藏，并通过 WebDAV 与电视同步。":"支持 Android TV 的 lives 配置、M3U、TXT 和 JSON 频道列表。",symbol:"tv") }
            else {
                ScrollView { LazyVStack(spacing:10) {
                    ForEach(visible) { channel in Button { play(channel) } label: {
                        HStack(spacing:12) {
                            Text(channel.number).font(.caption.monospacedDigit()).frame(width:30)
                            if let url=URL(string:channel.logo), !channel.logo.isEmpty { AsyncImage(url:url) { image in image.resizable().scaledToFit() } placeholder: { Image(systemName:"tv") }.frame(width:44,height:34) }
                            VStack(alignment:.leading,spacing:4) { Text(channel.name).font(.headline);Text(channel.group+" · \(channel.routes.count) 条线路").font(.caption).foregroundStyle(.white.opacity(0.65)) }
                            Spacer()
                            if favorite(channel) { Image(systemName:"star.fill").foregroundStyle(.yellow) }
                            Image(systemName:"play.fill")
                        }.padding(14).androidCard()
                    }.buttonStyle(.plain) }
                }.padding(.horizontal,16).padding(.bottom,20) }
            }
        }.padding(.top,12).androidScreen().navigationTitle("直播").navigationBarTitleDisplayMode(.inline)
            .task {
                guard sourceID.isEmpty else { return }
                let preferred=store.replica.document.records[SyncDocument.identity("preference","activeSource1")]?["value"]["url"].string
                let initial=initialSourceID.flatMap { id in configurations.contains(where: { $0.id==id }) ? id:nil }
                sourceID=initial ?? configurations.first(where: { $0.entry["value"]["url"].string==preferred })?.id ?? configurations.first?.id ?? ""
            }
            .task(id:sourceID) { await loadSources() }
            .task(id:selected) { await loadChannels() }
            .sheet(isPresented:$adding) { AddSourceView(live:true).environment(store) }
    }
    private func loadSources() async {
        guard loadedConfiguration != sourceID || sources.isEmpty else { return }
        guard let row=configurations.first(where: { $0.id==sourceID }) else { return }
        sources=[];channels=[];error=nil;loading=true
        do {
            let result=try await LiveClient().sources(address:row.entry["value"]["url"].string)
            try Task.checkCancellation(); sources=result;loadedConfiguration=sourceID
            selected=result.first(where: { $0.name==row.entry["value"]["home"].string })?.id ?? result.first?.id ?? ""
        } catch { if !Task.isCancelled { self.error=(error as? TVError)?.localizedDescription ?? "直播配置读取失败，请检查网络" } }
        if !Task.isCancelled { loading=false }
    }
    private func loadChannels() async {
        guard let source=active else { return }
        guard loadedLive != source.id || channels.isEmpty else { return }
        loading=true;error=nil;channels=[];group="全部"
        do {
            let result=try await LiveClient().channels(source);try Task.checkCancellation();channels=result;loadedLive=source.id
            if !autoStarted {
                if let target=initialChannel, !target.isEmpty {
                    if let channel=result.first(where: { $0.name==target }) { autoStarted=true;play(channel) }
                    else {
                        searched.insert(source.id)
                        if let next=sources.first(where: { !searched.contains($0.id) }) { selected=next.id;return }
                        error="当前直播配置中未找到收藏频道："+target
                    }
                } else {
                    let key="ios.live.channel."+sourceID+"."+source.id
                    let saved=UserDefaults.standard.string(forKey:key)
                    if let channel=result.first(where: { $0.id==saved }) ?? result.first { autoStarted=true;play(channel) }
                }
            }
            if let row=store.replica.document.records[sourceID], row["value"]["home"].string != source.name {
                var value=row["value"];value["home"] = .string(source.name);store.edit(id:sourceID,kind:"source",value:value)
            }
        } catch { if !Task.isCancelled { self.error=(error as? TVError)?.localizedDescription ?? "频道列表读取失败，请检查网络" } }
        if !Task.isCancelled { loading=false }
    }
    private func play(_ channel:LiveChannel) {
        guard let source=active else { return }
        let context=LivePlaybackContext(source:source,sources:sources,channels:channels)
        UserDefaults.standard.set(channel.id,forKey:"ios.live.channel."+sourceID+"."+source.id)
        let route=UserDefaults.standard.integer(forKey:"ios.live.route."+sourceID+"."+channel.id)
        store.play(.init(source:.init(id:source.id,sourceID:sourceID,name:source.name,address:source.address,kind:.playlist),item:.init(id:channel.name,name:channel.name,picture:channel.logo),episode:channel.episode(route:channel.routes.indices.contains(route) ? route:0),live:context))
    }
}

struct LiveChannelPicker: View {
    @Environment(\.dismiss) private var dismiss
    let channels: [LiveChannel]
    let select: (LiveChannel)->Void
    @ViewState private var query=""
    var body: some View {
        NavigationStack {
            List(channels.filter { $0.matches(query) }) { channel in
                Button { select(channel);dismiss() } label: { HStack { Text(channel.number).monospacedDigit();Text(channel.name);Spacer();Text(channel.group).font(.caption) } }
                    .listRowBackground(Color.black.opacity(0.26))
            }.searchable(text:$query,prompt:"频道名称、分组或频道号").androidScreen().navigationTitle("频道列表")
                .toolbar { ToolbarItem(placement:.cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }
}
struct LiveGuideView: View {
    @Environment(\.dismiss) private var dismiss
    let channel: LiveChannel
    let route: LiveRoute
    let play: (LiveProgram,String)->Void
    @ViewState private var day=Date()
    @ViewState private var programs: [LiveProgram]=[]
    @ViewState private var loading=false
    @ViewState private var error: String?
    var body: some View {
        NavigationStack {
            List {
                DatePicker("节目日期",selection:$day,in:Date().addingTimeInterval(-7*86400)...Date(),displayedComponents:.date).listRowBackground(Color.black.opacity(0.26))
                if loading { ProgressView("读取节目单…") }
                if let error { Text(error).foregroundStyle(.orange) }
                if !loading && programs.isEmpty && error==nil { Text("该频道未提供节目单") }
                ForEach(programs.filter { Calendar.current.isDate($0.start,inSameDayAs:day) }) { program in
                    Button {
                        do { let url=try LiveEPGParser.catchupURL(channel:channel,route:route,program:program);play(program,url);dismiss() }
                        catch { self.error=(error as? TVError)?.localizedDescription ?? "无法回看此节目" }
                    } label: {
                        HStack { Text(program.start,style:.time).monospacedDigit();Text(program.title);Spacer();if program.isCurrent() { Text("正在播出").font(.caption) } else if program.end<Date() && channel.catchup != .null { Image(systemName:"play.rectangle") } }
                    }.disabled(program.end>Date() || channel.catchup == .null).listRowBackground(Color.black.opacity(0.26))
                }
            }.androidScreen().navigationTitle(channel.name+" · 节目单")
                .toolbar { ToolbarItem(placement:.cancellationAction) { Button("关闭") { dismiss() } } }
                .task(id:day) {
                    loading=true;error=nil
                    do { let result=try await LiveEPGClient.shared.programs(channel:channel,day:day);try Task.checkCancellation();programs=result }
                    catch { if !Task.isCancelled { self.error=(error as? TVError)?.localizedDescription ?? "节目单读取失败" } }
                    if !Task.isCancelled { loading=false }
                }
        }
    }
}

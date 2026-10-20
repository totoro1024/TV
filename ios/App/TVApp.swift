import SwiftUI
import TVCore

@main struct TVWebDAVApp: App {
    init() { EmbeddedAIRuntime.install { method,payload in try await EmbeddedAIPlugin.shared.call(method,payload:payload) } }
    @ViewState private var store = AppStore()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RootView().environment(store).preferredColorScheme(.dark).tint(.white)
                .task {
                    await store.automaticSync()
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(60))
                        if phase == .active { await store.automaticSync() }
                    }
                }
                .onChange(of: phase) { _, next in
                    if next == .active { Task { await store.automaticSync() } }
                    if next == .background { store.syncBeforeBackground() }
                }
        }
    }
}
struct RootView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        @Bindable var store = store
        TabView {
            NavigationStack { LibraryView().androidScreen() }
                .tabItem { Label("首页", systemImage: "house.fill") }
            NavigationStack { SavedListView(kind: "favorite", title: "收藏").androidScreen() }
                .tabItem { Label("收藏", systemImage: "star.fill") }
            NavigationStack { SettingsView().androidScreen() }
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
        .fullScreenCover(item: $store.playback, onDismiss: { store.finishPlayback() }) { request in PlayerScreen(request: request).environment(store) }
        .alert("提示", isPresented: Binding(get: { store.issue != nil }, set: { if !$0 { store.issue = nil } })) {
            Button("知道了", role: .cancel) { store.issue = nil }
        } message: { Text(store.issue ?? "") }
    }
}
struct EmptyHint: View {
    let title: String, message: String, symbol: String
    var body: some View { ContentUnavailableView(title, systemImage: symbol, description: Text(message)) }
}

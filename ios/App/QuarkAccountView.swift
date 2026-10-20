import SwiftUI
import TVCore

struct QuarkAccountView: View {
    @Environment(AppStore.self) private var store
    private func summary(_ drive: CloudDrive) -> String {
        do { return try SyncedQuarkAccount.cookie(in: store.replica.document, drive: drive) == nil ? "未登录（可扫码或从 WebDAV 同步）" : "已有登录配置" }
        catch { return error.localizedDescription }
    }
    var body: some View {
        Form {
            Section {
                NavigationLink { CloudLoginProvidersView() } label: { Label("统一扫码登录",systemImage:"qrcode") }
            }.listRowBackground(Color.black.opacity(0.26))
            ForEach([CloudDrive.quark, .uc], id: \.rawValue) { drive in
            Section(drive.name + "网盘") {
                LabeledContent("登录方式", value: "扫码登录 / WebDAV 同步")
                Text(summary(drive))
                Button("同步网盘配置") { Task { await store.synchronize() } }.disabled(store.busy)
            }.listRowBackground(Color.black.opacity(0.26))
            }
            Section {
                Text("直接读取当前同步文档中的夸克及 UC Cookie，在内存中解码使用，不另存钥匙串或明文文件。切换同步账号或应用云端删除后，按当前文档重新读取。")
                Text("已有同步登录态无需重复扫码。重新扫码确认后自动保存并尝试同步；网盘是否接受登录状态，以实际请求为准。UC 部分资源仍可能受客户端或会员限制。")
            }.font(.footnote).listRowBackground(Color.black.opacity(0.26))
        }.androidScreen().navigationTitle("网盘账号")
    }
}

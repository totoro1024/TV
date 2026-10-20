import SwiftUI
import TVCore

struct WebDAVSettingsView: View {
    @Environment(AppStore.self) private var store
    @ViewState private var address = ""
    @ViewState private var userDirectory = ""
    @ViewState private var username = ""
    @ViewState private var password = ""
    @ViewState private var automatic = false
    @ViewState private var loaded = false
    @ViewState private var operation: SyncOperation?
    @ViewState private var confirmingRestore = false
    var body: some View {
        Form {
            Section("WebDAV") {
                TextField("服务器目录地址", text: $address).autocorrectionDisabled()
                TextField("用户目录（选填，例如 alice）", text: $userDirectory).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("留空沿用现有目录；不同用户填写不同名称，同一用户各设备填写相同名称。目录自动创建。") .font(.footnote).foregroundStyle(.secondary)
                TextField("账号", text: $username).autocorrectionDisabled()
                TextField("密码", text: $password).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                Toggle("自动同步", isOn: $automatic)
                Button("保存配置") { save() }.disabled(store.busy)
                Button("保存并测试连接") { if save() { Task { await store.testConnection() } } }.disabled(store.busy)
                Text("同一用户各设备填写相同目录，不同用户填写不同目录（如 /dav/用户甲/）。首次同步自动创建缺少的目录。凭据保存在本机应用私有目录的配置文件中。同步内容不加密，HTTP 传输按你的配置启用。") .font(.footnote).foregroundStyle(.secondary)
            }.listRowBackground(Color.black.opacity(0.26))
            Section("同步状态") {
                LabeledContent("数据状态", value: store.deliveryStatus)
                Label(store.status, systemImage: store.busy ? "arrow.triangle.2.circlepath" : "icloud")
                LabeledContent("最近同步成功", value: store.lastSyncAt.map {
                    $0.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).locale(Locale(identifier: "zh_CN")))
                } ?? "尚未成功同步")
                if store.replica.paused { Text("同步已暂停，请在下方选择重置处理方式").foregroundStyle(.orange) }
                Button("立即同步") { Task { await store.synchronize() } }.disabled(store.busy)
                Text("启动、配置/收藏变更、打开播放、暂停和退出播放时同步；前台运行约每 60 秒同步。未完成的上传保留到本地，下次启动或恢复前台后补传。播放期间不应用其他设备进度；退出后按实际观看时间合并。iOS 后台执行时间由系统决定。") .font(.footnote).foregroundStyle(.secondary)
            }.listRowBackground(Color.black.opacity(0.26))
            Section("高级操作") {
                ForEach([SyncOperation.merge, .push, .pull, .clear], id: \.rawValue) { op in
                    Button(op.title, role: op.destructive ? .destructive : nil) {
                        if op.destructive { operation = op } else { Task { await store.synchronize(op) } }
                    }.disabled(store.busy || (store.playback != nil && op.destructive))
                }
            }.listRowBackground(Color.black.opacity(0.26))
            Section("重置与恢复") {
                ForEach([SyncOperation.rebuild, .acceptReset], id: \.rawValue) { op in Button(op.title) { operation = op }.disabled(store.busy) }
                Button("恢复最近的本地副本") { confirmingRestore = true }.disabled(store.busy)
                Text("覆盖前保留最近 5 份本地副本，恢复后暂停自动同步。清空远端仅影响本应用的同步文件，不会删除网盘文件。") .font(.footnote).foregroundStyle(.secondary)
            }.listRowBackground(Color.black.opacity(0.26))
            Section("本机设置") {
                Toggle("无痕观看", isOn: Binding(get: { store.incognito }, set: { store.setIncognito($0) }))
                Text("iPhone 首版 · 自签安装").foregroundStyle(.secondary)
                Text("Android 网盘插件登录数据会原样保留在同步文档，但 iPhone 首版不解密或使用这类插件登录态。") .font(.footnote).foregroundStyle(.secondary)
            }.listRowBackground(Color.black.opacity(0.26))
        }.androidScreen().navigationTitle("WebDAV 跨设备同步")
            .task { if !loaded { address = store.settings.address; userDirectory = store.settings.userDirectory; username = store.settings.username; password = store.settings.password; automatic = store.autoSync; loaded = true } }
            .confirmationDialog(operation?.title ?? "确认操作", isPresented: Binding(get: { operation != nil }, set: { if !$0 { operation = nil } }), titleVisibility: .visible) {
                if let op = operation { Button("确认执行", role: .destructive) { Task { await store.synchronize(op) }; operation = nil } }
                Button("取消", role: .cancel) { operation = nil }
            } message: { Text(explanation) }
            .confirmationDialog("恢复最近的本地副本？", isPresented: $confirmingRestore, titleVisibility: .visible) {
                Button("确认恢复", role: .destructive) { store.restore() }
            } message: { Text("替换本机同步数据并暂停同步。") }
    }
    private var explanation: String {
        switch operation {
        case .push, .rebuild: return "用本机同步数据替换云端。其他设备下次同步时会应用此版本。"
        case .pull, .acceptReset: return "用云端替换本机同步数据。如果确认从空云端重新开始，本机同步数据也会清空。"
        case .clear: return "清空远端同步文件内容并写入重置标记，各设备检测到后暂停同步。本机数据保留。"
        default: return "请确认数据流向后继续。"
        }
    }
    @discardableResult private func save() -> Bool {
        do { try store.saveSettings(.init(address: address.trimmingCharacters(in: .whitespacesAndNewlines), username: username, password: password, userDirectory: userDirectory), automatic: automatic); return true }
        catch { store.report(error); return false }
    }
}

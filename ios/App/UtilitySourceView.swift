import SwiftUI
import TVCore

/// 配置中的功能入口不当成电影站点请求，明确展示当前已实现的能力。
struct UtilitySourceView: View {
    let source: MediaSource
    @ViewState private var enteringVideo = false
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                Text(source.utilityDescription).frame(maxWidth:.infinity,alignment:.leading).padding(18).androidCard()
                if source.kind == .cloudConfiguration {
                    NavigationLink { CloudLoginProvidersView() } label: {
                        SettingRow(title:"统一扫码登录",symbol:"qrcode",value:"夸克 / UC")
                    }
                    NavigationLink { QuarkAccountView() } label: {
                        SettingRow(title:"夸克 / UC账号配置",symbol:"externaldrive",value:"登录状态 / 同步")
                    }
                    Text("个人云盘目录浏览、文件管理和其他网盘账号的播放仍待移植。").font(.footnote).foregroundStyle(.white.opacity(0.8))
                } else if source.kind == .pushInput {
                    Button { enteringVideo = true } label: {
                        SettingRow(title:"输入视频直链",symbol:"link",value:"HTTP / HTTPS")
                    }
                    Text("此入口接收视频直链；Android 的局域网接收服务、磁力和分享链接解析尚未移植。").font(.footnote).foregroundStyle(.white.opacity(0.8))
                }
            }.padding(20)
        }.androidScreen().navigationTitle(source.name).navigationBarTitleDisplayMode(.inline)
            .buttonStyle(.plain)
            .sheet(isPresented:$enteringVideo) { PushVideoView() }
    }
}

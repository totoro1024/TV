import SwiftUI
import TVCore

/// 豆瓣海报要求来源头；只对其图片域名添加公开 Referer，不携带任何网盘凭据。
struct RemotePoster: View {
    let address: String
    var placeholder = "film"
    @ViewState private var image: UIImage?
    private var doubanImage: Bool {
        guard let host = URL(string: address)?.host else { return false }
        return host == "doubanio.com" || host.hasSuffix(".doubanio.com")
    }
    private var hint: some View {
        Rectangle().fill(.white.opacity(0.12)).overlay(Image(systemName: placeholder).font(.largeTitle))
    }
    var body: some View {
        Group {
            if doubanImage {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { hint }
            } else {
                AsyncImage(url: URL(string: address)) { image in image.resizable().scaledToFill() } placeholder: { hint }
            }
        }.task(id: address) {
            image = nil
            guard doubanImage, let url = URL(string: address) else { return }
            var request = URLRequest(url: url)
            request.httpShouldHandleCookies = false
            request.setValue("https://api.douban.com/", forHTTPHeaderField: "Referer")
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            guard let reply = try? await NetworkTransport().send(request), reply.status == 200, !Task.isCancelled else { return }
            image = UIImage(data: reply.body)
        }
    }
}

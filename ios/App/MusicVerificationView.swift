import SwiftUI
import WebKit
import TVCore

@MainActor private final class MusicVerificationBrowser: NSObject, ObservableObject, WKNavigationDelegate {
    let origin:URL
    let web:WKWebView
    @Published var loadError:String?
    @Published var loading = true
    init(origin:URL,userAgent:String = SeedhubClient.userAgent) {
        self.origin = origin
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(source:"""
        if (!document.querySelector('meta[name=viewport]')) {
            const viewport = document.createElement('meta');
            viewport.name = 'viewport'; viewport.content = 'width=device-width, initial-scale=1';
            document.head.appendChild(viewport);
        }
        """,injectionTime:.atDocumentEnd,forMainFrameOnly:true))
        web = WKWebView(frame:.zero,configuration:configuration)
        super.init()
        web.navigationDelegate = self
        web.customUserAgent = userAgent
        web.load(URLRequest(url:origin))
    }
    func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void) {
        guard let url = navigationAction.request.url,["http","https"].contains(url.scheme ?? ""),url.host == origin.host else { decisionHandler(.cancel);return }
        decisionHandler(.allow)
    }
    func webView(_ webView:WKWebView,didStartProvisionalNavigation navigation:WKNavigation!) { loading = true;loadError = nil }
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) { loading = false }
    func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        loading = false;loadError = NetworkIssue.message(error,context:"网站加载")
    }
    func complete() async throws {
        let title = try await web.evaluateJavaScript("document.title") as? String ?? ""
        guard !web.isLoading,!title.isEmpty,!title.contains("验证"),!title.contains("Just a moment") else { throw TVError.message("请先在网页中完成验证，页面跳转后再点击完成。") }
        let lowered=title.lowercased()
        guard !["403","404","502","503"].contains(where:lowered.hasPrefix),!["forbidden","access denied","bad gateway","service unavailable","not found"].contains(where:lowered.contains) else { throw TVError.message("网站仍返回访问错误，尚未完成验证，请稍后重试。") }
        let cookies = await withCheckedContinuation { continuation in
            web.configuration.websiteDataStore.httpCookieStore.getAllCookies { continuation.resume(returning:$0) }
        }
        await MusicVerificationSession.shared.install(cookies,origin:origin)
    }
}
private struct MusicVerificationWeb: UIViewRepresentable {
    let web:WKWebView
    func makeUIView(context:Context) -> WKWebView { web }
    func updateUIView(_ view:WKWebView,context:Context) {}
}
struct MusicVerificationView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser:MusicVerificationBrowser
    @ViewState private var issue:String?
    let onVerified:() -> Void
    let title:String
    init(source:MediaSource,onVerified:@escaping() -> Void) {
        let origin = source.kind == .legacySite ? (try? LegacyWebsiteClient().base(source)) ?? MusicClient.verificationURL(source) : source.kind == .jpys ? (try? JpysClient.verificationURL(source)) ?? MusicClient.verificationURL(source) : MusicClient.verificationURL(source)
        _browser = StateObject(wrappedValue:MusicVerificationBrowser(origin:origin,userAgent:source.kind == .jpys ? JpysClient.userAgent:SeedhubClient.userAgent))
        self.title = source.kind == .music ? "易听网站验证" : source.name+"网站验证"
        self.onVerified = onVerified
    }
    var body: some View {
        NavigationStack {
            VStack(spacing:0) {
                Text("请在站点页面手动完成验证；验证状态仅在本次应用运行期间保留。").font(.footnote).padding(12)
                if browser.loading { ProgressView("正在加载验证页面…").padding(10) }
                if let error = browser.loadError {
                    Text(error).font(.footnote).padding(12)
                    Button("重新载入") { browser.web.reload() }.padding(10)
                }
                MusicVerificationWeb(web:browser.web)
            }.androidScreen().navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button("关闭") { dismiss() } }
                    ToolbarItem(placement:.confirmationAction) {
                        Button("完成验证") { Task {
                            do { try await browser.complete();store.siteAccessRevision += 1;onVerified();dismiss() }
                            catch { issue = (error as? TVError)?.localizedDescription ?? "验证状态读取失败，请重试" }
                        } }
                    }
                }
                .alert("提示",isPresented:Binding(get:{issue != nil},set:{if !$0 { issue = nil }})) { Button("知道了",role:.cancel) { issue = nil } } message: { Text(issue ?? "") }
        }
    }
}

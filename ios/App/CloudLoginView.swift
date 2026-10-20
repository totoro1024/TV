import SwiftUI
import TVCore
import WebKit
import CoreImage.CIFilterBuiltins

struct CloudLoginProvidersView: View {
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                Text("选择网盘，用对应手机应用扫码确认。登录成功后保存到本机，并立即尝试 WebDAV 同步。").font(.subheadline)
                NavigationLink { UCCloudLoginView() } label: { SettingRow(title:"UC 网盘扫码登录",symbol:"qrcode",value:"优汐") }
                NavigationLink { QuarkCloudLoginView() } label: { SettingRow(title:"夸克网盘扫码登录",symbol:"qrcode",value:"官网登录") }
                Text("已有 WebDAV 登录配置仍可直接使用；重新扫码只更新选中的网盘。登录信息使用现有同步文档保存，不写入钥匙串。").font(.footnote).foregroundStyle(.secondary)
            }.padding(20)
        }.androidScreen().navigationTitle("统一扫码登录").navigationBarTitleDisplayMode(.inline).buttonStyle(.plain)
    }
}

private struct UCCloudLoginView: View {
    @Environment(AppStore.self) private var store
    @ViewState private var image: UIImage?
    @ViewState private var status = "正在获取 UC 登录二维码…"
    @ViewState private var revision = 0
    @ViewState private var saved = false
    @ViewState private var fetching = true
    var body: some View {
        ScrollView {
            VStack(spacing:20) {
                if let image { Image(uiImage:image).interpolation(.none).resizable().scaledToFit().frame(maxWidth:280).padding(16).background(.white).accessibilityLabel("UC 登录二维码") }
                else if fetching { ProgressView().tint(.white).frame(height:200) }
                Text(status).frame(maxWidth:.infinity,alignment:.leading)
                if !saved { Button("刷新二维码") { image=nil; revision += 1 }.padding(14).androidCard() }
                Text("请用 UC 浏览器扫码并确认授权；二维码有效期约 8 分钟。返回上一页会停止等待登录。").font(.footnote).foregroundStyle(.secondary)
            }.padding(20)
        }.androidScreen().navigationTitle("UC 网盘扫码登录").navigationBarTitleDisplayMode(.inline)
            .task(id:revision) { await login() }
    }
    @MainActor private func login() async {
        let scope = store.scope
        status = "正在获取 UC 登录二维码…"; saved = false; fetching = true
        let client = UCLoginClient(transport:UCLoginTransport())
        do {
            let token = try await client.token(); try Task.checkCancellation()
            let filter = CIFilter.qrCodeGenerator(); filter.message=Data(UCLoginClient.qrURL(token:token).absoluteString.utf8); filter.correctionLevel="M"
            guard let output=filter.outputImage, let cg=CIContext().createCGImage(output.transformed(by:CGAffineTransform(scaleX:8,y:8)),from:output.extent.applying(CGAffineTransform(scaleX:8,y:8))) else { throw TVError.message("二维码生成失败，请刷新") }
            image=UIImage(cgImage:cg); fetching=false; status="请用 UC 浏览器扫码，并在手机确认登录。"
            for _ in 0..<240 {
                try await Task.sleep(for:.seconds(2))
                guard let ticket = try await client.poll(token:token) else { continue }
                let credentials = try await client.account(ticket:ticket)
                try Task.checkCancellation()
                guard scope == store.scope else { throw TVError.message("同步账号已变化，请重新打开登录页") }
                status="正在保存登录并同步…"
                try await store.saveCloudLogin(drive:.uc,credentials:credentials)
                saved=true; image=nil; status="UC 登录已保存。"+store.status
                return
            }
            image=nil; fetching=false; status="二维码已超时，请刷新后重新扫码。"
        } catch {
            guard !NetworkIssue.cancelled(error) else { return }
            image=nil; fetching=false; status=(error as? TVError)?.localizedDescription ?? NetworkIssue.message(error,context:"UC 登录")
        }
    }
}

@MainActor private final class QuarkLoginBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let web: WKWebView
    @Published var error: String?
    @Published var qrImage: UIImage?
    @Published var loading = true
    override init() {
        let config=WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        web=WKWebView(frame:.zero,configuration:config)
        super.init(); web.navigationDelegate=self; web.uiDelegate=self; web.customUserAgent=QuarkClient.userAgent
        reload()
    }
    private func allowed(_ url:URL?) -> Bool {
        guard let url, url.scheme == "https", let host=url.host?.lowercased() else { return false }
        return host == "quark.cn" || host.hasSuffix(".quark.cn")
    }
    func reload() { error=nil;qrImage=nil;web.load(URLRequest(url:URL(string:"https://pan.quark.cn/list")!)) }
    func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void) {
        decisionHandler(allowed(navigationAction.request.url) ? .allow:.cancel)
    }
    func webView(_ webView:WKWebView,createWebViewWith configuration:WKWebViewConfiguration,for navigationAction:WKNavigationAction,windowFeatures:WKWindowFeatures)->WKWebView? {
        if allowed(navigationAction.request.url) { webView.load(navigationAction.request) };return nil
    }
    func webView(_ webView:WKWebView,didStartProvisionalNavigation navigation:WKNavigation!) { loading=true;error=nil }
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) { loading=false }
    func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) {
        guard !NetworkIssue.cancelled(error) else { return };loading=false;self.error=NetworkIssue.message(error,context:"夸克登录页")
    }
    func refreshQR() async {
        let script = """
        (() => {
            const nodes = Array.from(document.querySelectorAll('canvas,img'));
            for (const el of nodes) {
                const w = el.naturalWidth || el.width, h = el.naturalHeight || el.height;
                if (w < 120 || Math.abs(w-h)>3) continue;
                let parent=el, login=false;
                for(let i=0;i<5 && parent && parent.tagName!=='BODY';i++,parent=parent.parentElement) {
                    const text=parent.innerText || '';
                    if(text.includes('扫码') && text.includes('登录')) { login=true;break; }
                }
                if(!login) continue;
                try {
                    if(el.tagName==='CANVAS') return el.toDataURL('image/png');
                    if(el.src.startsWith('data:image/')) return el.src;
                    const c=document.createElement('canvas');c.width=w;c.height=h;
                    c.getContext('2d').drawImage(el,0,0);return c.toDataURL('image/png');
                } catch (_) {}
            }
            return null;
        })()
        """
        guard let raw=try? await web.evaluateJavaScript(script) as? String,
              let comma=raw.firstIndex(of:","), let data=Data(base64Encoded:String(raw[raw.index(after:comma)...])),
              let image=UIImage(data:data) else { return }
        qrImage=image
    }
    func cookie() async -> String? {
        let cookies = await withCheckedContinuation { continuation in web.configuration.websiteDataStore.httpCookieStore.getAllCookies { continuation.resume(returning:$0) } }
        let valid=cookies.filter {
            let domain=$0.domain.trimmingCharacters(in:CharacterSet(charactersIn:".")).lowercased()
            return (domain == "quark.cn" || domain == "pan.quark.cn") && ($0.expiresDate == nil || $0.expiresDate! > Date())
        }
        let value=HTTPCookie.requestHeaderFields(with:valid)["Cookie"] ?? ""
        return SyncedQuarkAccount.validCookie(value) ? value:nil
    }
}
private struct CloudLoginWeb: UIViewRepresentable {
    let web:WKWebView
    func makeUIView(context:Context)->WKWebView { web }
    func updateUIView(_ uiView:WKWebView,context:Context) {}
}
private struct QuarkCloudLoginView: View {
    @Environment(AppStore.self) private var store
    @StateObject private var browser=QuarkLoginBrowser()
    @ViewState private var status="在官网登录页选择扫码，使用夸克手机端确认登录。"
    @ViewState private var saved=false
    @ViewState private var saving=false
    @ViewState private var initialScope:String?
    @ViewState private var active=true
    @ViewState private var showingWebsite=false
    var body: some View {
        VStack(spacing:12) {
            Text(status).font(.footnote).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,16)
            if let error=browser.error { Text(error).font(.footnote).foregroundStyle(.orange) }
            if browser.loading { ProgressView().tint(.white) }
            if !saved {
                if let image=browser.qrImage, !showingWebsite {
                    Image(uiImage:image).interpolation(.none).resizable().scaledToFit().frame(maxWidth:240,maxHeight:240).padding(16).background(.white).accessibilityLabel("夸克登录二维码")
                    Text("请用夸克手机端扫码，确认后自动保存并同步。").font(.footnote)
                    Spacer(minLength:0)
                }
                CloudLoginWeb(web:browser.web).background(.white)
                    .frame(maxHeight:browser.qrImage != nil && !showingWebsite ? 1:.infinity)
                    .opacity(browser.qrImage != nil && !showingWebsite ? 0:1)
            }
            HStack {
                if !saved {
                    Button("重新加载") { browser.reload() }.disabled(saving)
                    if browser.qrImage != nil { Button(showingWebsite ? "显示二维码":"查看网页登录") { showingWebsite.toggle() } }
                    Spacer()
                    Button("完成登录") { Task { await complete(manual:true) } }.disabled(saving)
                }
            }.padding(16)
        }.androidScreen().navigationTitle("夸克网盘扫码登录").navigationBarTitleDisplayMode(.inline)
            .task {
                active=true;initialScope=store.scope
                while !Task.isCancelled && !saved {
                    do { try await Task.sleep(for:.seconds(2));await browser.refreshQR();await complete(manual:false) } catch { return }
                }
            }.onDisappear { active=false;browser.web.stopLoading() }
    }
    @MainActor private func complete(manual:Bool) async {
        guard !saved,!saving else { return }
        guard let cookie=await browser.cookie() else { if manual { status="尚未取得登录状态，请先在手机确认扫码登录。" };return }
        saving=true;defer { saving=false }
        var validated=false
        do {
            try await QuarkClient(cookie:cookie).validateAccount();validated=true;try Task.checkCancellation()
            guard active else { throw CancellationError() }
            guard initialScope == store.scope else { throw TVError.message("同步账号已变化，请重新打开登录页") }
            status="正在保存登录并同步…"
            try await store.saveCloudLogin(drive:.quark,credentials:.init(cookie:cookie))
            saved=true;browser.web.stopLoading();status="夸克登录已保存。"+store.status
        } catch {
            guard !NetworkIssue.cancelled(error) else { return }
            if manual || validated { status=(error as? TVError)?.localizedDescription ?? NetworkIssue.message(error,context:"夸克登录") }
        }
    }
}

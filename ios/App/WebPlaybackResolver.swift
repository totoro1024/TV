import Foundation
import WebKit
import TVCore

/// 与 Android 的网页嗅探用途一致，在设备上运行播放页脚本；只返回实际媒体请求。
@MainActor final class WebPlaybackResolver:NSObject,WKScriptMessageHandler,WKNavigationDelegate {
    private var web:WKWebView?
    private var continuation:CheckedContinuation<ResolvedMedia,Error>?
    private var deadline:Task<Void,Never>?
    private var resolving=false
    private var preferVLC=false
    private var headers:[String:String]=[:]
    static func resolve(_ page:HTMLPlaybackRequired) async throws -> ResolvedMedia {
        try Task.checkCancellation()
        let worker=WebPlaybackResolver()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                worker.continuation=continuation
                if Task.isCancelled { worker.finish(.failure(CancellationError()));return }
                worker.start(page)
            }
        },onCancel:{ Task { @MainActor in worker.finish(.failure(CancellationError())) } })
    }
    private func start(_ page:HTMLPlaybackRequired) {
        guard CatalogParser.validHTTP(page.page),let url=URL(string:page.page) else { finish(.failure(TVError.message("播放页地址无效")));return }
        headers=page.headers;preferVLC=page.preferVLC
        let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent();config.allowsInlineMediaPlayback=true;config.mediaTypesRequiringUserActionForPlayback=[]
        config.userContentController.add(self,name:"tvMedia")
        config.userContentController.addUserScript(WKUserScript(source:Self.script,injectionTime:.atDocumentStart,forMainFrameOnly:false))
        let web=WKWebView(frame:.zero,configuration:config);self.web=web;web.navigationDelegate=self
        web.customUserAgent=page.headers["User-Agent"]
        var request=URLRequest(url:url);request.allHTTPHeaderFields=page.headers;web.load(request)
        deadline=Task { [weak self] in
            try? await Task.sleep(nanoseconds:35_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finish(.failure(TVError.message("播放页未返回可用媒体，可能需要网页验证或该线路已失效")))
        }
    }
    func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage) {
        guard !resolving,let body=message.body as? [String:String],let raw=body["url"],CatalogParser.validHTTP(raw),let url=URL(string:raw),["m3u8","mp4","m4v","mp3","m4a","flv","mkv"].contains(url.pathExtension.lowercased()) else { return }
        resolving=true
        var requestHeaders=headers
        if let ref=body["page"],CatalogParser.validHTTP(ref) { requestHeaders["Referer"]=ref }
        guard let web else { return }
        web.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self,self.continuation != nil else { return }
                let applicable=cookies.filter { cookie in
                    let domain=cookie.domain.trimmingCharacters(in:CharacterSet(charactersIn:".")).lowercased(),host=url.host?.lowercased() ?? ""
                    return (host==domain || host.hasSuffix("."+domain)) && url.path.hasPrefix(cookie.path) && (!cookie.isSecure || url.scheme=="https")
                }
                var finalHeaders=requestHeaders
                if !applicable.isEmpty { finalHeaders.merge(HTTPCookie.requestHeaderFields(with:applicable)) { _,new in new } }
                self.finish(.success(ResolvedMedia(url:raw,headers:finalHeaders,useVLC:self.preferVLC && !["m3u8","mp4"].contains(url.pathExtension.lowercased()))))
            }
        }
    }
    func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) {
        if (error as NSError).code != NSURLErrorCancelled { finish(.failure(TVError.message("播放页加载失败，请检查该线路是否可用"))) }
    }
    private func finish(_ result:Result<ResolvedMedia,Error>) {
        guard let continuation else { return };self.continuation=nil
        deadline?.cancel();deadline=nil
        web?.stopLoading();web?.configuration.userContentController.removeScriptMessageHandler(forName:"tvMedia");web?.navigationDelegate=nil;web=nil
        continuation.resume(with:result)
    }
    private static let script = #"""
    (()=>{
      const send=(value)=>{try {
        const u=new URL(value,location.href);
        if(/^https?:$/.test(u.protocol)&&/\.(m3u8|mp4|m4v|mp3|m4a|flv|mkv)$/i.test(u.pathname))
          window.webkit.messageHandlers.tvMedia.postMessage({url:u.href,page:location.href});
      }catch(e){}};
      const fetch0=window.fetch;
      window.fetch=function(input,...args){send(typeof input==='string'?input:input.url);return fetch0.call(this,input,...args)};
      const open0=XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open=function(method,url,...args){send(url);return open0.call(this,method,url,...args)};
      const scan=()=>{
        document.querySelectorAll('video,audio').forEach(v=>{if(v.currentSrc)send(v.currentSrc);else if(v.src)send(v.src);try{v.play()?.catch(()=>{})}catch(e){}});
        document.querySelectorAll('video source,audio source').forEach(v=>send(v.src));
        performance.getEntriesByType('resource').forEach(r=>send(r.name));
      };
      setInterval(scan,700);document.addEventListener('DOMContentLoaded',scan);
    })();
    """#
}

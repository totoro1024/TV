import Foundation
import SwiftSoup

/// 抠抠、优汐的多镜像搜索协议。详情仍按各盘自身授权读取，不向镜像站发送网盘 Cookie。
public struct CloudMirrorClient: Sendable {
    public static let plugins = ["csp_KkSsGuard", "csp_UuSsGuard"]
    public var transport: any HTTPTransport
    public init(transport: any HTTPTransport = NetworkTransport()) { self.transport=transport }
    private func mirrors(_ source: MediaSource) throws -> [String] {
        let config = try App99Crypto.configuration(source.ext)
        let override = config["pturl"].string
        if !override.isEmpty { return override.split(separator:",").map(String.init).filter(CatalogParser.validHTTP) }
        return source.address == "csp_KkSsGuard" ? ["http://xiaocge.fun/","http://2xiaopan.fun/","https://feimao666.fun/","https://tv.yydsys.top/","http://www.miqk.cc/","https://mihdr.top/","http://xiaomi666.fun/"] : ["http://123.666291.xyz/","http://666.666291.xyz/","http://103.45.162.207:20720/","https://www.muou.site/","http://milvdou.fun/","https://www.muou.asia/","http://xsayang.fun:12512/"]
    }
    private func fetch(_ initial:URLRequest) async throws -> (HTTPReply,URL) {
        var request=initial
        for _ in 0..<5 {
            let reply=try await transport.send(request)
            if [301,302,303,307,308].contains(reply.status),let location=reply.headers.first(where:{$0.key.lowercased()=="location"})?.value,let before=request.url,let target=URL(string:location,relativeTo:before)?.absoluteURL,CatalogParser.validHTTP(target.absoluteString),!(before.scheme == "https" && target.scheme == "http") {
                if before.host != target.host { request.setValue(nil,forHTTPHeaderField:"Cookie");request.setValue(nil,forHTTPHeaderField:"Authorization") }
                request.url=target;continue
            }
            guard reply.status==200,let url=request.url else { throw DAVFailure.status(reply.status) }
            return (reply,url)
        }
        throw TVError.message("网盘镜像跳转次数过多")
    }
    public func search(_ source:MediaSource, keyword:String, page:Int=1) async throws -> [MediaItem] {
        guard !keyword.isEmpty,page==1 else { return [] }
        let bases=try mirrors(source)
        let results=await withTaskGroup(of:([MediaItem],Bool).self, returning:([MediaItem],Int).self) { group in
            for base in bases {
                group.addTask {
                    do {
                        guard let root=URL(string:base) else { return ([],false) }
                        var parts=URLComponents(url:root.appendingPathComponent("index.php/vod/search.html"),resolvingAgainstBaseURL:true)!
                        parts.queryItems=[URLQueryItem(name:"wd",value:keyword)]
                        var request=URLRequest(url:parts.url!);request.timeoutInterval=8;request.setValue("Mozilla/5.0",forHTTPHeaderField:"User-Agent")
                        let (reply,finalURL)=try await fetch(request)
                        var origin=URLComponents(url:finalURL,resolvingAgainstBaseURL:false)!
                        origin.path="/";origin.query=nil;origin.fragment=nil
                        let finalBase=origin.url!.absoluteString
                        let doc=try SwiftSoup.parse(String(decoding:reply.body,as:UTF8.self),finalBase)
                        if !(try doc.select("input[name=validate],#challenge-running").isEmpty) { return ([],false) }
                        let items=try doc.select("div.module-search-item").array().compactMap { row -> MediaItem? in
                            guard let link=try row.select("[href*=detail][title]").first() else { return nil }
                            let href=try link.attr("href"),name=try link.attr("title"),image=try row.select("[data-src]").first()
                            let id=href.split(separator:"/").last?.replacingOccurrences(of:".html",with:"") ?? ""
                            guard !id.isEmpty,!name.isEmpty else { return nil }
                            return MediaItem(id:finalBase+"&"+id,name:name,picture:try image?.attr("data-src") ?? "",remarks:root.host ?? "网盘搜索")
                        }
                        return (items,true)
                    } catch { return ([],false) }
                }
            }
            var rows:[MediaItem]=[],responded=0
            for await (items,success) in group { rows += items;if success { responded += 1 } }
            return (rows,responded)
        }
        guard results.1>0 else { throw TVError.message("所有镜像均未返回可用搜索页面，可能超时或需要验证") }
        return results.0.sorted { $0.id<$1.id }
    }
    public func detail(id:String,cookie:String?,ucCookie:String? = nil) async throws -> MediaDetail {
        guard let split=id.lastIndex(of:"&"),let base=URL(string:String(id[..<split])),CatalogParser.validHTTP(base.absoluteString) else { throw TVError.message("网盘镜像影片标识无效") }
        let number=String(id[id.index(after:split)...]);guard !number.isEmpty,number.allSatisfy(\.isNumber) else { throw TVError.message("网盘镜像影片编号无效") }
        let url=base.appendingPathComponent("index.php/vod/detail/id/"+number+".html")
        var request=URLRequest(url:url);request.setValue("Mozilla/5.0",forHTTPHeaderField:"User-Agent")
        let (reply,finalURL)=try await fetch(request)
        let doc=try SwiftSoup.parse(String(decoding:reply.body,as:UTF8.self),finalURL.absoluteString)
        let name=try doc.select("div.video-cover div.module-item-pic img.lazyload").first()?.attr("alt") ?? "网盘分享"
        var shares=try doc.select("div.module-row-info > a, [data-clipboard-text]").array().compactMap { element -> String? in
            let value=try element.hasAttr("data-clipboard-text") ? element.attr("data-clipboard-text") : element.attr("href")
            return ["pan.quark.cn","drive.uc.cn"].contains(URL(string:value)?.host ?? "") ? value : nil
        }
        var seen=Set<String>();shares=shares.filter { seen.insert($0).inserted }
        guard !shares.isEmpty else { throw TVError.message("详情未找到夸克分享；其他网盘播放协议仍待移植") }
        var episodes:[Episode]=[],lastFailure:Error?
        for (index,share) in shares.enumerated() {
            do {
                let detail=try await CloudSearchClient(transport:transport).detail(id:share,cookie:cookie,ucCookie:ucCookie)
                episodes += detail.episodes.map { Episode(name:$0.name,url:$0.url,line:$0.line.replacingOccurrences(of:"1",with:String(index+1))) }
            } catch is CancellationError { throw CancellationError() }
              catch { lastFailure=error }
        }
        if episodes.isEmpty { throw lastFailure ?? TVError.message("镜像分享均未返回可播放选集") }
        return MediaDetail(item:MediaItem(id:id,name:name),episodes:episodes,synopsis:"网盘镜像分享")
    }
}

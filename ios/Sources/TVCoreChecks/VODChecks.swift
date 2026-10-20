import Foundation
import TVCore

enum VODChecks {
    static func run(path:String, output:String) async throws {
        let sites=try CatalogParser.configuration(data:Data(contentsOf:URL(fileURLWithPath:path)),address:"https://example.invalid/config",sourceID:"validation")
        var cookie:String?,ucCookie:String?
        if let path=ProcessInfo.processInfo.environment["TVCORE_REPLICA_FILE"] {
            let saved=try JSON.parse(Data(contentsOf:URL(fileURLWithPath:path)),maxBytes:24*1024*1024)
            let document=try Replica(json:saved["replica"]).document
            cookie=try SyncedQuarkAccount.cookie(in:document)
            ucCookie=try SyncedQuarkAccount.cookie(in:document,drive:.uc)
        }
        var results:[[String:String]]=[]
        for site in sites {
            if let filter=ProcessInfo.processInfo.environment["TVCORE_SITE_FILTER"],!filter.split(separator:",").contains(where: { site.name.contains(String($0)) || site.address.contains(String($0)) }) { continue }
            var row=["站点":site.name,"插件":site.address.hasPrefix("csp_") ? site.address:"脚本或HTTP","首页":"未测","搜索":"未测","详情":"未测","播放解析":"未测","画面实测":"未测"]
            if site.isUtility {
                row["首页"] = "功能入口，非点播目录";row["搜索"] = "不适用";row["详情"] = "不适用";row["播放解析"] = "不适用"
            } else if site.kind == .unsupported {
                row["首页"]="待移植"; row["搜索"]="待移植"; row["详情"]="待移植"; row["播放解析"]="待移植"
            } else {
                var selected:MediaItem?
                do { let items=try await CatalogClient().browse(site)
                    if let path=ProcessInfo.processInfo.environment["TVCORE_CAPTURE_CATALOG_FILE"] {
                        let rows=items.map { JSON.object(["id":.string($0.id),"name":.string($0.name),"remarks":.string($0.remarks)]) }
                        FileManager.default.createFile(atPath:path,contents:JSON.array(rows).data,attributes:[.posixPermissions:0o600])
                    }
                    selected=items.dropFirst(max(0,Int(ProcessInfo.processInfo.environment["TVCORE_ITEM_INDEX"] ?? "0") ?? 0)).first; row["首页"]=[.cloudSearch,.cloudMirror].contains(site.kind) ? "不适用：Android纯搜索入口":"成功：\(items.count)项" }
                catch { row["首页"]=safe(error) }
                let searchWord=ProcessInfo.processInfo.environment["TVCORE_SEARCH_WORD"] ?? (site.kind == .legacySite ? selected?.name ?? "花儿":"花儿")
                row["搜索样本词"]=searchWord
                do { let items=try await CatalogClient().browse(site,keyword:searchWord,page:1); if selected == nil {
                    let uc=ProcessInfo.processInfo.environment["TVCORE_DRIVE"] == "uc"
                    selected=[.cloudSearch,.cloudMirror].contains(site.kind) ? items.first(where:{URL(string:$0.id)?.host == (uc ? "drive.uc.cn":"pan.quark.cn")}) ?? items.dropFirst(max(0,Int(ProcessInfo.processInfo.environment["TVCORE_ITEM_INDEX"] ?? "0") ?? 0)).first:items.first
                }; row["搜索"]=[.doubao,.livegz,.kanqiu].contains(site.kind) ? "本页筛选（非远程搜索）":site.kind == .doudou ? "不适用：片单转聚合搜索":items.isEmpty ? "请求成功，未命中（不能确认搜索有效）":"成功：\(items.count)项" }
                catch { row["搜索"]=safe(error) }
                if let detailPath = ProcessInfo.processInfo.environment["TVCORE_DETAIL_ID_FILE"] {
                    let id = try String(contentsOfFile: detailPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                    selected = MediaItem(id: id, name: "指定详情样本")
                    row["样本来源"] = "私有文件指定详情；不作为首页或搜索验证"
                }
                if site.kind == .doudou { row["详情"]="片单转聚合搜索";row["播放解析"]="片单转聚合搜索" }
                else if let selected {
                    do {
                        var detail=try await CatalogClient().detail(site,id:selected.id,quarkCookie:cookie,ucCookie:ucCookie)
                        if let resource=detail.resources.dropFirst(max(0,Int(ProcessInfo.processInfo.environment["TVCORE_RESOURCE_INDEX"] ?? "0") ?? 0)).first {
                            row["资源版本"]="\(detail.resources.count)个版本，验证指定资源"
                            detail=try await CatalogClient().detail(site,id:resource.id,quarkCookie:cookie,ucCookie:ucCookie)
                        }
                        row["详情"]=detail.episodes.isEmpty ? "详情可读，无选集（未通过播放）":"成功：\(detail.episodes.count)集"
                        var candidates=ProcessInfo.processInfo.environment["TVCORE_DRIVE"] == "uc" ? detail.episodes.filter { CloudDrive.episode($0.url) == .uc }:detail.episodes
                        if let line = ProcessInfo.processInfo.environment["TVCORE_LINE_FILTER"] { candidates = candidates.filter { $0.line.contains(line) } }
                        if let episode=candidates.dropFirst(max(0,Int(ProcessInfo.processInfo.environment["TVCORE_EPISODE_INDEX"] ?? "0") ?? 0)).first {
                            do {
                                let media:ResolvedMedia
                                if site.kind == .sixv && episode.url.hasPrefix("magnet:") { throw TVError.message("磁力选集已读取，iPhone磁力播放引擎尚未接入") }
                                else if site.kind == .jpj { media=try await JPJClient.shared.resolve(site,episode:episode) }
                                else if site.kind == .music { media=try await MusicClient().resolve(site,episode:episode) }
                                else if site.kind == .alllive { media=try await AllLiveClient().resolve(episode) }
                                else if site.kind == .kanqiu { media=try await KanqiuClient().resolve(episode) }
                                else if site.kind == .jpys { media=try await JpysClient.shared.resolve(site,episode:episode) }
                                else if site.kind == .appgz { media=try await AppGzClient.shared.resolve(episode) }
                                else if site.kind == .streamSite { media=try await PublicStreamClient().resolve(site,episode:episode) }
                                else if site.kind == .hmys { media=try await HmysClient.shared.resolve(episode) }
                                else if site.kind == .audiobook { media=try await AudioBookClient.shared.resolve(episode) }
                                else if site.kind == .doubao { media=try await DoubaoClient.shared.resolve(episode) }
                                else if site.kind == .legacySite && !site.isQuarkEpisode(episode) { media=try await LegacyWebsiteClient().resolve(site,episode:episode) }
                                else if site.kind == .appsx { media=try await AppSxClient.shared.resolve(site,episode:episode) }
                                else if site.kind == .apptt { media=try await AppTTClient().resolve(episode) }
                                else if site.kind == .t4 { media=try await T4Client().resolve(site,episode:episode) }
                                else if site.kind == .website { media=try await WebsiteClient().resolve(site,episode:episode) }
                                else if site.kind == .bili { media=try await BiliClient().resolve(episode) }
                                else if site.kind == .app99 { media=try await App99Client.shared.resolve(site,episode:episode) }
                                else if site.usesQuark { let drive=CloudDrive.episode(episode.url);guard let credential = drive == .uc ? ucCookie : cookie else { throw TVError.message("独立验证器未载入\(drive.name) Cookie") };media=try await QuarkClient(cookie:credential,drive:drive).resolveHistory(episode.url,preferOriginal:!episode.line.hasPrefix("夸父智")) }
                                else { media=ResolvedMedia(url:episode.url) }
                                if let path = ProcessInfo.processInfo.environment["TVCORE_CAPTURE_MEDIA_FILE"] {
                                    let data = try JSONSerialization.data(withJSONObject:["url":media.url,"headers":media.headers,"useVLC":media.useVLC,"byteOffset":media.byteOffset,"size":media.size])
                                    guard FileManager.default.createFile(atPath:path,contents:data,attributes:[.posixPermissions:0o600]) else { throw TVError.message("本地媒体验证文件写入失败") }
                                }
                                row["播放解析"]=CatalogParser.validHTTP(media.url) ? "已取得地址，待画面实测":"未取得媒体地址"
                                if let signing=media.hmysSigning, let url=URL(string:media.url) {
                                    var request=URLRequest(url:try signing.signed(url));request.allHTTPHeaderFields=media.headers
                                    let reply=try await NetworkTransport().send(request)
                                    if reply.status==200,let text=String(data:reply.body,encoding:.utf8),text.hasPrefix("#EXTM3U") {
                                        row["媒体请求"]="签名清单HTTP200"
                                        if let path=ProcessInfo.processInfo.environment["TVCORE_CAPTURE_HLS_FILE"] { let file=URL(fileURLWithPath:path);try reply.body.write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path) }
                                        if let entry=text.components(separatedBy:.newlines).first(where:{ !$0.isEmpty && !$0.hasPrefix("#") }),let part=URL(string:entry,relativeTo:url)?.absoluteURL {
                                            var segment=URLRequest(url:try signing.signed(part));segment.allHTTPHeaderFields=media.headers
                                            let bytes=try await NetworkTransport().send(segment)
                                            if let path=ProcessInfo.processInfo.environment["TVCORE_CAPTURE_HLS_FILE"] { try bytes.body.write(to:URL(fileURLWithPath:path+".ts"));try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path+".ts") }
                                            row["媒体请求"]="签名清单HTTP200；首分片HTTP\(bytes.status)，\(bytes.body.count)字节，文件头\(bytes.body.prefix(4).map{String(format:"%02x",$0)}.joined())（尚未解码）"
                                        }
                                    } else { row["媒体请求"]="签名清单HTTP\(reply.status)，未通过" }
                                }
                            } catch { row["播放解析"]=safe(error) }
                        }
                    } catch { row["详情"]=safe(error) }
                }
            }
            results.append(row)
            let bytes=try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys])
            try bytes.write(to:URL(fileURLWithPath:output),options:.atomic)
            print("\(results.count)/\(sites.count) \(site.name)：首页\(row["首页"]!)；搜索\(row["搜索"]!)；详情\(row["详情"]!)；解析\(row["播放解析"]!)")
        }
    }
    private static func safe(_ error:Error) -> String {
        if let failure=error as? DAVFailure,case .status(let status)=failure { return "HTTP \(status)" }
        if error is HTMLPlaybackRequired { return "需在iPhone运行播放页脚本，待画面实测" }
        if error is CancellationError { return "已取消" }
        // 网络错误/服务端原文可能携带签名URL或凭据，禁止直接记入报告。
        if let tv=error as? TVError {
            let text=tv.localizedDescription
            if !text.contains("http"),!text.contains("Cookie="),text.count < 180 { return text }
        }
        return "请求或解析失败（\((error as NSError).code)）"
    }
}

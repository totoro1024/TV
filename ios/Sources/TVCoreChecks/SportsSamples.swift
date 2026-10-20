import Foundation
import TVCore

/// 逐场检查当前赛事，避免把首项完场或失效线路当成整个源不可用。
enum SportsSamples {
    static func run(config: String, output: String) async throws {
        let sources = try CatalogParser.configuration(data:Data(contentsOf:URL(fileURLWithPath:config)),address:"https://example.invalid/config",sourceID:"validation")
        var report = [[String:String]]()
        for source in sources where [.kanqiu,.livegz].contains(source.kind) {
            let catalog = try await CatalogClient().browse(source)
            print(source.name + "：当前目录 \(catalog.count) 场；逐场检查详情及媒体响应，不代表实播通过")
            for (index,item) in catalog.prefix(60).enumerated() {
                var row = ["站点":source.name,"样本":item.name,"目录序号":String(index),"赛事状态":item.remarks]
                do {
                    let detail = try await CatalogClient().detail(source,id:item.id)
                    row["详情"] = "\(detail.episodes.count) 条线路"
                    var statuses = [String]()
                    for (lineIndex,episode) in detail.episodes.prefix(4).enumerated() {
                        do {
                            let media = source.kind == .kanqiu ? try await KanqiuClient().resolve(episode) : ResolvedMedia(url:episode.url)
                            guard let url=URL(string:media.url) else { continue }
                            var request=URLRequest(url:url);request.timeoutInterval=8;request.allHTTPHeaderFields=media.headers;request.setValue("bytes=0-65535",forHTTPHeaderField:"Range")
                            let reply=try await NetworkTransport().send(request)
                            statuses.append("\(episode.line)：HTTP\(reply.status)，\(reply.body.count)字节")
                            if [200,206].contains(reply.status),!reply.body.isEmpty {
                                let payload:JSON = .object(["source":.string(source.id),"item":.string(item.id),"name":.string(item.name),"line":.string(episode.line),"url":.string(media.url),"headers":.object(media.headers.mapValues(JSON.string))])
                                let path=output+".\(source.kind.rawValue)-\(index)-\(lineIndex).private.json"
                                FileManager.default.createFile(atPath:path,contents:payload.data,attributes:[.posixPermissions:0o600])
                            }
                        } catch { statuses.append("\(episode.line)：\(safe(error))") }
                    }
                    row["媒体响应"] = statuses.joined(separator:"；")
                } catch { row["详情"] = safe(error) }
                row["实际播放"] = "未验证画面/声音"
                report.append(row)
                try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output),options:.atomic)
                print("\(source.name) #\(index)：\(row["详情"] ?? "未测")；\(row["媒体响应"] ?? "")")
            }
        }
    }
    private static func safe(_ error:Error)->String {
        if let error=error as? DAVFailure,case .status(let status)=error { return "HTTP\(status)" }
        if error is HTMLPlaybackRequired { return "需网页脚本解析" }
        return "请求/解析错误（\((error as NSError).code)）"
    }
}

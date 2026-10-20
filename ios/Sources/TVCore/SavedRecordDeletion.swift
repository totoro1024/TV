import Foundation

extension Replica {
    /// 保留同步删除标记；删除节目历史时同时删除该节目的各集进度。
    @discardableResult
    public mutating func removeSaved(_ ids: Set<String>, kind: String, device: String, now: Int64 = SyncDocument.now) -> Int {
        guard kind == "history" || kind == "favorite" else { return 0 }
        let selected = ids.filter { id in
            guard let entry = document.records[id] else { return false }
            return !entry["deleted"].flag && entry["kind"].string == kind
        }
        guard !selected.isEmpty else { return 0 }
        var deleting = Set(selected)
        if kind == "history" {
            for (id, entry) in document.records where !entry["deleted"].flag && entry["kind"].string == EpisodeProgress.kind {
                if selected.contains(EpisodeProgress.historyID(entry["value"])) { deleting.insert(id) }
            }
        }
        for id in deleting.sorted() {
            guard let entry = document.records[id] else { continue }
            edit(id:id,kind:entry["kind"].string,value:nil,device:device,now:now)
        }
        return selected.count
    }
}

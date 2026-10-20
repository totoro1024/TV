import Foundation

public enum SyncOperation: String, CaseIterable, Sendable {
    case sync, push, pull, merge, clear, rebuild, acceptReset
    public var title: String {
        switch self {
        case .sync: return "立即同步"
        case .push: return "覆盖远端"
        case .pull: return "覆盖本地"
        case .merge: return "拉取合并"
        case .clear: return "清空远端"
        case .rebuild: return "用本机重新建立云端"
        case .acceptReset: return "从云端重新开始"
        }
    }
    public var destructive: Bool { self != .sync && self != .merge }
}
public struct SyncOutcome: Sendable {
    public var replica: Replica
    public var install: Bool, replacing: Bool
    public var message: String
    /// 网络请求期间的本机编辑必须留下待上传状态；播放中仅暂存云端进度。
    public func applying(to latest: Replica, playing: Bool) throws -> (replica: Replica, deferred: SyncDocument?) {
        var updated = replica
        if install && !replacing {
            var local = latest.document; local.epoch = updated.document.epoch
            updated.document = try local.merged(with: updated.document)
        }
        var pending: SyncDocument?
        if install && playing {
            pending = updated.document; updated.document = latest.document
            if !updated.paused { updated.acknowledgedEpoch = pending!.epoch }
        } else if !install {
            var local = latest.document; local.epoch = updated.document.epoch
            updated.document = try local.merged(with: updated.document)
        }
        updated.clock = max(updated.clock, latest.clock)
        updated.localRevision = max(updated.localRevision, latest.localRevision)
        return (updated, pending)
    }
}
public struct SyncEngine: Sendable {
    public let client: WebDAVClient
    public init(client: WebDAVClient) { self.client = client }
    public func run(_ operation: SyncOperation, replica original: Replica, playing: Bool = false) async throws -> SyncOutcome {
        if playing && ![.sync, .merge, .clear].contains(operation) { throw TVError.message("请先退出播放，再执行覆盖操作") }
        if original.paused && ![.clear,.rebuild,.acceptReset].contains(operation) { throw TVError.message("同步已暂停，请选择重建云端或从云端重新开始") }
        try await client.ensureFolder()
        for _ in 0..<4 {
            let remote = try await client.read(); var incoming = remote.document; var replica = original
            replica.retryNeeded = false
            if operation == .clear {
                var reset = SyncDocument(); reset.mode = "reset"; reset.reset = reset.epoch
                do { try await client.write(reset, before: remote) } catch DAVFailure.conflict { continue }
                replica.acknowledgedEpoch = reset.epoch; replica.paused = true
                return .init(replica: replica, install: false, replacing: false, message: "云端已清空，自动同步已暂停")
            }
            if operation == .acceptReset {
                var value = incoming ?? SyncDocument()
                if value.mode == "reset" {
                    value.mode = "merge"
                    do { try await client.write(value, before: remote) } catch DAVFailure.conflict { continue }
                }
                replica.acceptedReset = value.reset; replica.receive(value); replica.paused = false; replica.acknowledge(original.localRevision)
                return .init(replica: replica, install: true, replacing: true, message: "已从云端重新开始")
            }
            let forcePush = operation == .push || operation == .rebuild
            if !forcePush && ((incoming == nil && !replica.acknowledgedEpoch.isEmpty) ||
                (incoming?.reset.isEmpty == false && incoming!.reset != replica.acceptedReset)) {
                replica.paused = true
                return .init(replica: replica, install: false, replacing: false, message: "检测到云端重置，已暂停同步；请选择处理方式")
            }
            if forcePush {
                var replacement = replica.document
                replacement.epoch = UUID().uuidString.lowercased(); replacement.mode = "replace"
                replacement.reset = incoming?.reset ?? replica.document.reset
                do { try await client.write(replacement, before: remote) } catch DAVFailure.conflict { continue }
                replica.receive(replacement); replica.acceptedReset = replacement.reset; replica.paused = false; replica.acknowledge(original.localRevision)
                return .init(replica: replica, install: false, replacing: false, message: "已用本机数据覆盖远端")
            }
            if operation == .pull {
                guard let incoming else { throw TVError.message("云端没有同步数据") }
                replica.receive(incoming); replica.acknowledge(original.localRevision)
                return .init(replica: replica, install: true, replacing: true, message: "已用云端覆盖本地")
            }
            if operation == .merge && incoming == nil {
                return .init(replica: replica, install: false, replacing: false, message: "云端没有同步数据，未修改本地")
            }
            var current = replica.document
            let replace = incoming?.mode == "replace" && incoming!.epoch != replica.acknowledgedEpoch
            if replace && playing { throw TVError.message("云端有覆盖版本，请退出播放后同步") }
            if incoming == nil { incoming = current } else if !replace { current.epoch = incoming!.epoch }
            let combined = try replace ? incoming! : current.merged(with: incoming!)
            if operation != .merge && combined.raw != remote.document?.raw {
                do { try await client.write(combined, before: remote) } catch DAVFailure.conflict { continue }
            }
            replica.receive(combined)
            if operation != .merge { replica.acknowledge(original.localRevision) }
            return .init(replica: replica, install: true, replacing: replace, message: operation == .merge ? "已拉取合并（未上传）" : "同步成功")
        }
        throw DAVFailure.conflict
    }
}

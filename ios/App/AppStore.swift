import Foundation
import Observation
import TVCore
import UIKit

struct PlaybackRequest: Identifiable {
    let id = UUID()
    let source: MediaSource, item: MediaItem, episode: Episode
    var detail: MediaDetail? = nil
    var live: LivePlaybackContext? = nil
    var historyID: String { SyncDocument.identity("history", source.sourceID, source.id, item.id) }
}
@MainActor @Observable final class AppStore {
    var replica = Replica()
    var siteAccessRevision = 0
    var settings = DAVSettings()
    var autoSync = UserDefaults.standard.bool(forKey: "autoSync")
    var incognito = UserDefaults.standard.bool(forKey: "incognito")
    var status = "尚未同步"
    var lastSyncAt: Date?
    var issue: String?
    var busy = false
    var playback: PlaybackRequest?
    private var deferred: SyncDocument?
    private let syncScheduler = SyncScheduler()
    private var syncRetry = SyncRetryState()
    private var lastAutomaticIssue: String?
    private var davClient: WebDAVClient?
    private var davClientSettings: DAVSettings?
    private func syncClient() throws -> WebDAVClient {
        if davClientSettings != settings || davClient == nil {
            davClient = try WebDAVClient(settings: settings); davClientSettings = settings
        }
        return davClient!
    }
    var deliveryStatus: String {
        replica.deliveryText(syncing: busy, configured: !settings.address.isEmpty, automatic: autoSync, deferred: deferred != nil)
    }
    private var backgroundTaskID = UIBackgroundTaskIdentifier.invalid
    private var backgroundToken: UUID?
    private var backgroundSyncTask: Task<Void, Never>?
    func syncBeforeBackground() {
        do { try save() } catch { report(error); return }
        guard autoSync, !replica.paused, backgroundTaskID == .invalid else { return }
        let token = UUID(); backgroundToken = token
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "保存观看进度") { [weak self] in
            Task { @MainActor in
                guard let self, self.backgroundToken == token else { return }
                self.backgroundSyncTask?.cancel(); self.endBackgroundSync(token)
            }
        }
        backgroundSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { endBackgroundSync(token) }
            while busy && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
            if !Task.isCancelled { await automaticSync() }
        }
    }
    private func endBackgroundSync(_ token: UUID) {
        guard backgroundToken == token else { return }
        if backgroundTaskID != .invalid { UIApplication.shared.endBackgroundTask(backgroundTaskID); backgroundTaskID = .invalid }
        backgroundSyncTask = nil; backgroundToken = nil
    }
    private var openingPlayback = false
    private var rerun = false
    private var loadFailed = false
    private let device: String
    private let root: URL
    init() {
        device = UserDefaults.standard.string(forKey: "device") ?? UUID().uuidString.lowercased()
        UserDefaults.standard.set(device, forKey: "device")
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TVWebDAV", isDirectory: true)
        do { settings = try CredentialVault.read(); try load() } catch { loadFailed = true; report(error) }
    }
    var scope: String { SyncDocument.identity((try? settings.directoryAddress()) ?? settings.address.trimmingCharacters(in: .whitespacesAndNewlines), settings.username) }
    private var directory: URL { root.appendingPathComponent(scope, isDirectory: true) }
    var activeRecords: [(id: String, entry: JSON)] {
        replica.document.records.filter { !$0.value["deleted"].flag }.map { ($0.key, $0.value) }
    }
    func records(_ kind: String) -> [(id: String, entry: JSON)] {
        activeRecords.filter { $0.entry["kind"].string == kind }.sorted { $0.entry["modified"].int > $1.entry["modified"].int }
    }
    private func load() throws {
        let file = directory.appendingPathComponent("replica.json")
        guard FileManager.default.fileExists(atPath: file.path) else { replica = Replica(); deferred = nil; lastSyncAt = nil; return }
        let json = try JSON.parse(Data(contentsOf: file), maxBytes: 24 * 1024 * 1024)
        replica = try Replica(json: json["replica"])
        lastSyncAt = json["lastSyncAtMs"].int > 0 ? Date(timeIntervalSince1970: Double(json["lastSyncAtMs"].int) / 1000) : nil
        if json["deferred"] != .null {
            let pending = try SyncDocument(data: json["deferred"].data)
            var latest = replica.document; latest.epoch = pending.epoch
            replica.receive(try latest.merged(with: pending)); deferred = nil; try save()
        }
    }
    private func write(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: .atomic)
        #endif
    }
    func save() throws {
        try write(JSON.object(["replica":replica.json, "deferred":deferred?.raw ?? .null, "lastSyncAtMs":lastSyncAt.map { .integer(Int64($0.timeIntervalSince1970 * 1000)) } ?? .null]).data, to: directory.appendingPathComponent("replica.json"))
    }
    func saveSettings(_ value: DAVSettings, automatic: Bool) throws {
        guard !busy, playback == nil else { throw TVError.message("请退出播放或等待同步完成后修改账号") }
        _ = try WebDAVClient(settings: value)
        try save(); try CredentialVault.save(value)
        syncRetry.succeeded(); lastAutomaticIssue = nil
        settings = value; autoSync = automatic; UserDefaults.standard.set(automatic, forKey: "autoSync")
        loadFailed = false
        do { try load(); status = "配置已保存" } catch { loadFailed = true; throw error }
    }
    func setIncognito(_ value: Bool) { incognito = value; UserDefaults.standard.set(value, forKey: "incognito") }
    func report(_ error: Error, context: String = "操作", automatic: Bool = false) {
        guard !NetworkIssue.cancelled(error) else { return }
        let message: String
        if error is TVError || error is DAVFailure { message = context == "操作" ? error.localizedDescription : context + "：" + error.localizedDescription }
        else if (error as NSError).domain == NSURLErrorDomain { message = NetworkIssue.message(error, context: context) }
        else { message = context + "失败，本机数据已保留；请检查配置或恢复副本" }
        status = message
        if automatic {
            if NetworkIssue.transient(error) { return }
            guard message != lastAutomaticIssue else { return }
            lastAutomaticIssue = message
        }
        issue = message
    }
    private func backup() throws {
        let folder = directory.appendingPathComponent("backups", isDirectory: true)
        try write(replica.json.data, to: folder.appendingPathComponent("\(SyncDocument.now)-\(UUID().uuidString).json"))
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in files.dropFirst(5) { try FileManager.default.removeItem(at: old) }
    }
    func restore() {
        guard !busy, playback == nil else { issue = "请退出播放或等待同步结束"; return }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("backups"), includingPropertiesForKeys: nil).sorted { $0.lastPathComponent > $1.lastPathComponent }
            guard let file = files.first else { throw TVError.message("没有可恢复的副本") }
            let recovered = try Replica(json: JSON.parse(Data(contentsOf: file), maxBytes: 24 * 1024 * 1024))
            try backup(); replica = recovered; replica.paused = true; deferred = nil; try save(); loadFailed = false; status = "已恢复本地副本，同步已暂停"
        } catch { report(error) }
    }
    func synchronize(_ operation: SyncOperation = .sync, automatic: Bool = false) async {
        guard !loadFailed else { issue = "本地同步文件未能读取，已停止同步以保护数据"; return }
        guard !settings.address.isEmpty else { status = "请先配置 WebDAV"; return }
        if busy { rerun = true; return }
        busy = true
        let previousAcknowledgement = replica.uploadedRevision
        defer {
            busy = false
            if rerun { rerun = false; requestSync() }
        }
        do {
            if operation.destructive { try backup() }
            let result = try await SyncEngine(client: syncClient()).run(operation, replica: replica, playing: playback != nil)
            if result.replacing { try backup() }
            let applied = try result.applying(to: replica, playing: playback != nil)
            var updated = applied.replica
            if let pending = applied.deferred { deferred = pending }
            replica = updated
            let previousSyncAt = lastSyncAt
            if !updated.paused && ([.sync, .push, .pull, .rebuild].contains(operation) || operation == .merge && result.install) { lastSyncAt = Date() }
            do { try save() } catch { lastSyncAt = previousSyncAt; throw error }
            status = result.message
            syncRetry.succeeded(); lastAutomaticIssue = nil
        } catch {
            replica.uploadedRevision = min(replica.uploadedRevision, previousAcknowledgement)
            replica.retryNeeded = true
            try? save()
            if automatic && NetworkIssue.transient(error) { syncRetry.failed() }
            report(error, context: "WebDAV 同步", automatic: automatic)
        }
    }
    func testConnection() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { try await WebDAVClient(settings: settings).test(); status = "连接测试成功（读写及并发保护正常）" } catch { report(error, context: "WebDAV 连接测试") }
    }
    func saveCloudLogin(drive: CloudDrive, credentials: CloudLoginCredentials) async throws {
        let loginScope = scope
        while busy { try await Task.sleep(for: .milliseconds(100)) }
        try Task.checkCancellation()
        guard scope == loginScope else { throw TVError.message("同步账号已变化，请重新打开登录页") }
        guard !loadFailed, playback == nil else { throw TVError.message("请退出播放后保存登录，或先处理本地同步文件错误") }
        let value = try SyncedQuarkAccount.loginValue(in: replica.document, drive: drive, credentials: credentials)
        let previous = replica
        replica.edit(id: SyncDocument.identity("cloudAccount", "catvod-sp-utils-v1"), kind: "cloudAccount", value: value, device: device)
        do { try replica.document.validate(); try save() } catch { replica = previous; throw error }
        siteAccessRevision += 1
        if settings.address.isEmpty { status = drive.name + "登录已保存，请配置 WebDAV 后同步" }
        else if replica.paused { status = drive.name + "登录已保存，同步已暂停，请先处理同步状态" }
        else { await synchronize() }
    }
    func automaticSync() async {
        if autoSync && !replica.paused && syncRetry.canAttempt() { await synchronize(automatic: true) }
    }
    func requestSync() {
        guard autoSync, !replica.paused else { return }
        syncScheduler.request { [weak self] in await self?.automaticSync() }
    }
    func edit(id: String, kind: String, value: JSON?, upload: Bool = true, now: Int64 = SyncDocument.now) {
        guard !loadFailed else { issue = "本地同步文件损坏，已停止修改"; return }
        var merged = value
        if case .object(let fields) = value {
            var existing = replica.document.records[id]?["value"].object ?? [:]
            fields.forEach { existing[$0.key] = $0.value }; merged = .object(existing)
        }
        if let old = replica.document.records[id], !old["deleted"].flag, old["value"] == merged { return }
        replica.edit(id: id, kind: kind, value: merged, device: device, now: now)
        do { try save(); if upload { requestSync() } } catch { report(error) }
    }
    func addSource(name: String, address: String, live: Bool) throws {
        guard CatalogParser.validHTTP(address) else { throw TVError.message("请填写有效的 HTTP 或 HTTPS 地址") }
        let type = live ? "1" : "0", id = SyncDocument.identity("source", type, address)
        edit(id: id, kind: "source", value: .object(["name":.string(name), "url":.string(address), "type":.number(type), "home":.string("")]))
    }
    func sourceDescription(type: Int64) -> String {
        let sources = records("source").filter { $0.entry["value"]["type"].int == type }
        let id = SyncDocument.identity("preference", "activeSource\(type)")
        if let preference = replica.document.records[id], !preference["deleted"].flag {
            let address = preference["value"]["url"].string
            if let selected = sources.first(where: { $0.entry["value"]["url"].string == address }) {
                return SourcePresentation.description(selected.entry["value"])
            }
            return "未配置"
        }
        return sources.first.map { SourcePresentation.description($0.entry["value"]) } ?? "未配置"
    }
    func selectSource(_ id: String) {
        guard let source = replica.document.records[id], !source["deleted"].flag else { return }
        let type = source["value"]["type"].int, name = "activeSource\(type)"
        edit(id: SyncDocument.identity("preference", name), kind: "preference", value: .object([
            "name":.string(name), "type":.integer(type), "url":source["value"]["url"]]))
    }
    func selectSite(_ source: MediaSource) {
        guard let entry = replica.document.records[source.sourceID], !entry["deleted"].flag else { return }
        var value = entry["value"]; value["home"] = .string(source.id)
        edit(id: source.sourceID, kind: "source", value: value)
    }
    func remove(_ id: String) {
        guard let e = replica.document.records[id] else { return }
        if e["kind"].string == "source" {
            for (key, entry) in replica.document.records where entry["value"]["source"].string == id { edit(id: key, kind: entry["kind"].string, value: nil, upload: false) }
        }
        if e["kind"].string == "history" {
            for (key, entry) in replica.document.records where entry["kind"].string == EpisodeProgress.kind && EpisodeProgress.historyID(entry["value"]) == id {
                edit(id: key, kind: EpisodeProgress.kind, value: nil, upload: false)
            }
        }
        edit(id: id, kind: e["kind"].string, value: nil)
    }
    func removeSaved(_ ids: Set<String>, kind: String) -> Bool {
        guard !loadFailed else { issue = "本地同步文件损坏，已停止修改"; return false }
        let previous = replica
        guard replica.removeSaved(ids,kind:kind,device:device) > 0 else { return true }
        do { try save(); requestSync(); return true }
        catch { replica = previous; report(error); return false }
    }
    func mediaDetail(_ source: MediaSource, id: String) async throws -> MediaDetail {
        let cookie = source.usesQuark ? try SyncedQuarkAccount.cookie(in: replica.document) : nil
        let ucCookie = source.usesQuark ? try SyncedQuarkAccount.cookie(in: replica.document, drive: .uc) : nil
        return try await CatalogClient().detail(source, id: id, quarkCookie: cookie, ucCookie: ucCookie)
    }
    func play(_ request: PlaybackRequest) {
        if request.source.kind == .sixv && request.episode.url.hasPrefix("magnet:") { issue = "新6V提供的是磁力线路，iPhone当前没有磁力下载与播放引擎，暂时不能播放。"; return }
        guard request.live != nil && LiveParser.playable(request.episode.url) || request.source.kind == .jpj || request.source.kind == .music || request.source.kind == .alllive || request.source.kind == .kanqiu || request.source.kind == .aidj || request.source.kind == .jpys || request.source.kind == .appgz || request.source.kind == .streamSite || request.source.kind == .hmys || request.source.kind == .audiobook || request.source.kind == .doubao || request.source.kind == .legacySite || request.source.kind == .appsx || request.source.kind == .apptt || request.source.kind == .t4 || request.source.kind == .website || request.source.kind == .bili || request.source.kind == .app99 || request.source.usesQuark || CatalogParser.playable(request.episode.url) else { issue = "此播放地址需要 Android 插件或网页解析，iPhone 首版无法直接播放"; return }
        guard !openingPlayback else { return }
        openingPlayback = true
        Task { @MainActor in
            defer { openingPlayback = false }
            if autoSync && !settings.address.isEmpty {
                while busy { try? await Task.sleep(for: .milliseconds(50)) }
                await automaticSync()
            }
            playback = request
        }
    }
    func playbackSkip(_ request: PlaybackRequest) -> PlaybackSkip {
        PlaybackSkip(value: replica.document.records[request.historyID]?["value"])
    }
    func setPlaybackSkip(_ request: PlaybackRequest, opening: Double? = nil, ending: Double? = nil) {
        guard !incognito, let entry = replica.document.records[request.historyID], !entry["deleted"].flag else { return }
        var value = entry["value"]
        if let opening, opening.isFinite { value["openingMs"] = .integer(Int64(max(0, opening) * 1000)) }
        if let ending, ending.isFinite { value["endingMs"] = .integer(Int64(max(0, ending) * 1000)) }
        edit(id: request.historyID, kind: "history", value: value, now: min(SyncDocument.now, value["watchedAt"].int))
    }
    func episodeProgress(_ request: PlaybackRequest) -> JSON? {
        EpisodeProgress.value(in: replica.document, source: request.source.sourceID, site: request.source.id, vod: request.item.id, episode: request.episode)
    }
    func progress(_ request: PlaybackRequest, seconds: Double, duration: Double) {
        guard !loadFailed, !incognito, request.source.kind != .playlist, seconds.isFinite, seconds >= 0, duration.isFinite, duration > 0 else { return }
        let value: JSON = .object(["source":.string(request.source.sourceID), "site":.string(request.source.id), "vod":.string(request.item.id),
            "name":.string(request.item.name), "picture":request.item.picture.isEmpty ? (replica.document.records[request.historyID]?["value"]["picture"] ?? .string("")) : .string(request.item.picture), "line":.string(request.episode.line),
            "episode":.string(request.episode.name), "episodeUrl":.string(request.episode.url), "watchedAt":.integer(SyncDocument.now),
            "positionMs":.integer(Int64(seconds * 1000)), "durationMs":.integer(duration.isFinite ? Int64(max(duration,0) * 1000) : 0),
            "openingMs":replica.document.records[request.historyID]?["value"]["openingMs"] ?? .integer(0),
            "endingMs":replica.document.records[request.historyID]?["value"]["endingMs"] ?? .integer(0),
            "reverseSort":replica.document.records[request.historyID]?["value"]["reverseSort"] ?? .bool(false),
            "reversePlay":replica.document.records[request.historyID]?["value"]["reversePlay"] ?? .bool(false)])
        guard EpisodeProgress.record(value, in: &replica, device: device) else { return }
        do { try save() } catch { report(error) }
    }
    func finishPlayback() {
        playback = nil
        do {
            if let deferred {
                try replica.applyDeferred(deferred); self.deferred = nil; try save()
            }
            requestSync()
        } catch { report(error) }
    }
    private func favoriteID(_ request: PlaybackRequest) -> String {
        request.source.kind == .playlist
            ? SyncDocument.identity("favorite", "live", request.item.name)
            : SyncDocument.identity("favorite", "vod", request.source.sourceID, request.source.id, request.item.id)
    }
    func isFavorite(_ request: PlaybackRequest) -> Bool {
        replica.document.records[favoriteID(request)]?["deleted"].flag == false
    }
    func toggleFavorite(_ request: PlaybackRequest) {
        let live = request.source.kind == .playlist
        let id = favoriteID(request)
        if isFavorite(request) { remove(id); return }
        var value: JSON = .object(["type":.integer(live ? 1 : 0), "name":.string(request.item.name), "picture":.string(request.item.picture), "siteName":.string(request.source.name), "addedAt":.integer(SyncDocument.now)])
        if live {
            value["channel"] = .string(request.item.name)
            value["iosSource"] = .string(request.source.sourceID); value["iosSite"] = .string(request.source.id)
        }
        else { value["source"] = .string(request.source.sourceID); value["site"] = .string(request.source.id); value["vod"] = .string(request.item.id) }
        value["episodeUrl"] = .string(request.episode.url); value["episode"] = .string(request.episode.name); value["line"] = .string(request.episode.line)
        edit(id: id, kind: "favorite", value: value)
    }
}

package com.fongmi.android.tv.sync;

import java.io.IOException;

/** Android 正式实现与本地 HTTP 集成测试共用的跨平台操作状态机。 */
public final class SyncEngine {
    public enum Operation { SYNC, PUSH, PULL, MERGE, CLEAR, REBUILD, ACCEPT_RESET }
    public interface Local {
        SyncReplica replica();
        boolean isPlaying();
        void validate(SyncDocument document);
        void capture() throws Exception;
        SyncDocument snapshot();
        void backup() throws Exception;
        void install(SyncDocument document) throws Exception;
        void applyMerged(SyncDocument document, boolean replacing) throws Exception;
        void save() throws Exception;
        void pause(String message) throws Exception;
        void success(String message);
    }
    private final WebDavClient dav;
    private final Local local;
    public SyncEngine(WebDavClient dav, Local local) { this.dav = dav; this.local = local; }
    public void run(Operation operation) throws Exception {
        SyncReplica replica = local.replica();
        if (local.isPlaying() && (operation == Operation.PULL || operation == Operation.PUSH || operation == Operation.ACCEPT_RESET))
            throw new IOException("请先退出播放，再执行覆盖操作");
        if (replica.paused && operation != Operation.REBUILD && operation != Operation.ACCEPT_RESET && operation != Operation.CLEAR)
            throw new IOException("同步已暂停，请选择重建云端或从云端重新开始");
        dav.ensureFolder();
        for (int attempt = 0; attempt < 4; attempt++) {
            WebDavClient.Snapshot remote = dav.read();
            SyncDocument incoming = remote.document;
            if (incoming != null) local.validate(incoming);
            if (operation == Operation.CLEAR) {
                SyncDocument reset = new SyncDocument(); reset.mode = "reset"; reset.reset = reset.epoch;
                try { dav.write(reset, remote); }
                catch (WebDavClient.Conflict e) { continue; }
                replica.acknowledgedEpoch = reset.epoch;
                local.pause("云端已清空，自动同步已暂停");
                return;
            }
            if (operation == Operation.ACCEPT_RESET) {
                local.backup();
                SyncDocument value = incoming == null ? new SyncDocument() : incoming;
                if ("reset".equals(value.mode)) {
                    value = value.copy(); value.mode = "merge";
                    try { dav.write(value, remote); }
                    catch (WebDavClient.Conflict e) { continue; }
                }
                replica.acceptedReset = value.reset;
                local.install(value); replica.paused = false;
                checkpoint(replica.localRevision); local.success("已从云端重新开始"); return;
            }
            boolean forcePush = operation == Operation.PUSH || operation == Operation.REBUILD;
            if (!forcePush && (incoming == null && !replica.acknowledgedEpoch.isEmpty()
                    || replica.needsResetConsent(incoming))) {
                local.pause("检测到云端被清空，自动同步已暂停；请选择重建云端或从云端重新开始");
                return;
            }
            local.capture();
            long uploadedRevision = replica.localRevision;
            if (forcePush) {
                local.backup();
                SyncDocument replacement = local.snapshot(); replacement.mode = "replace";
                if (incoming != null) replacement.reset = incoming.reset;
                try { dav.write(replacement, remote); }
                catch (WebDavClient.Conflict e) { continue; }
                replica.receive(replacement); replica.acceptedReset = replacement.reset; replica.paused = false; checkpoint(uploadedRevision);
                local.success("已用本机数据覆盖远端"); return;
            }
            if (operation == Operation.PULL) {
                if (incoming == null) throw new IOException("云端没有同步数据");
                local.backup(); local.install(incoming); checkpoint(uploadedRevision); local.success("已用云端数据覆盖本地"); return;
            }
            SyncDocument current = replica.document.copy();
            boolean replace = incoming != null && "replace".equals(incoming.mode)
                    && !incoming.epoch.equals(replica.acknowledgedEpoch);
            if (replace && local.isPlaying()) throw new IOException("云端有覆盖版本，请退出播放后同步");
            if (incoming == null) incoming = current.copy();
            else if (!replace) current.epoch = incoming.epoch;
            SyncDocument combined = replace ? incoming.copy() : SyncDocument.merge(current, incoming);
            if (operation != Operation.MERGE && (remote.document == null || !new com.google.gson.Gson().toJsonTree(combined).equals(new com.google.gson.Gson().toJsonTree(remote.document)))) {
                try { dav.write(combined, remote); }
                catch (WebDavClient.Conflict e) { continue; }
            }
            if (replace) local.backup();
            // 应用下载结果前，再捕获网络请求期间发生的本机编辑。
            // 使用 Room 事务，将最终捕获及应用与其他数据库写入串行化。
            final SyncDocument uploaded = combined;
            final boolean replacing = replace;
            local.applyMerged(uploaded, replacing);
            if (operation != Operation.MERGE) checkpoint(uploadedRevision);
            else { replica.retryNeeded = false; local.save(); }

            local.success(operation == Operation.MERGE ? "已拉取合并（未上传）" : "同步成功");
            return;
        }
        throw new IOException("其他设备正在更新云端，已保留本地数据，请稍后重试");
    }

    private void checkpoint(long revision) throws Exception {
        SyncReplica replica = local.replica();
        long previous = replica.uploadedRevision; boolean retry = replica.retryNeeded;
        replica.acknowledge(revision);
        try { local.save(); }
        catch (Exception e) { replica.uploadedRevision = previous; replica.retryNeeded = retry; throw e; }
    }
}

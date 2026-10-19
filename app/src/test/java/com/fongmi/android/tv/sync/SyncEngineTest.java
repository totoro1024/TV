package com.fongmi.android.tv.sync;

import com.google.gson.JsonObject;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import java.io.IOException;
import java.util.Map;
import java.util.TreeMap;
import static org.junit.Assert.*;

/** 两份独立副本通过真实 HTTP 执行生产使用的操作状态机。 */
public class SyncEngineTest {
    private TestDavServer server;
    private Map<String, byte[]> files;
    private WebDavClient client;
    private final MemoryLocal tv = new MemoryLocal("tv"), phone = new MemoryLocal("phone");
    @Before public void start() throws Exception {
        server = new TestDavServer(); server.start(); files = server.files;
        client = new WebDavClient(server.address(), "test", "test-only");
    }
    @After public void stop() { server.stop(); }

    private void run(MemoryLocal local, SyncEngine.Operation op) throws Exception { new SyncEngine(client, local).run(op); }
    @Test public void firstJoinMergesBothDevicesAndDeletionPropagates() throws Exception {
        tv.put("a", 1); phone.put("b", 2);
        run(tv, SyncEngine.Operation.SYNC); run(phone, SyncEngine.Operation.SYNC); run(tv, SyncEngine.Operation.SYNC);
        assertEquals(tv.values, phone.values); assertEquals(2, tv.values.size());
        phone.values.remove(id("a")); run(phone, SyncEngine.Operation.SYNC); run(tv, SyncEngine.Operation.SYNC);
        assertFalse(tv.values.containsKey(id("a")));
    }
    @Test public void pullMergeNeverUploads() throws Exception {
        tv.put("remote", 1); phone.put("local", 2); run(tv, SyncEngine.Operation.SYNC);
        String etag = client.read().etag;
        run(phone, SyncEngine.Operation.MERGE);
        assertEquals(2, phone.values.size()); assertEquals(etag, client.read().etag);
        assertEquals(1, client.read().document.records.size());
    }
    @Test public void forcePushIsAppliedWithoutResurrectingOldRemoteRows() throws Exception {
        tv.put("old", 1); run(tv, SyncEngine.Operation.SYNC); run(phone, SyncEngine.Operation.SYNC);
        tv.values.clear(); tv.put("new", 2); run(tv, SyncEngine.Operation.PUSH);
        phone.put("offline", 3); run(phone, SyncEngine.Operation.SYNC);
        assertEquals(1, phone.values.size()); assertTrue(phone.values.containsKey(id("new")));
        assertTrue(phone.backups > 0);
    }
    @Test public void replacementFromAnotherDeviceIsDeferredWhilePlaying() throws Exception {
        tv.put("old", 1); run(tv, SyncEngine.Operation.SYNC); run(phone, SyncEngine.Operation.SYNC);
        tv.values.clear(); tv.put("new", 2); run(tv, SyncEngine.Operation.PUSH);
        phone.playing = true;
        try { run(phone, SyncEngine.Operation.SYNC); fail(); } catch (IOException expected) { assertTrue(expected.getMessage().contains("退出播放")); }
        assertTrue(phone.values.containsKey(id("old")));
        phone.playing = false; run(phone, SyncEngine.Operation.SYNC);
        assertFalse(phone.values.containsKey(id("old"))); assertTrue(phone.values.containsKey(id("new")));
    }
    @Test public void forcePullReplacesOnlyLocalReplicaAndCreatesBackup() throws Exception {
        tv.put("remote", 1); run(tv, SyncEngine.Operation.SYNC); phone.put("local", 2);
        String etag = client.read().etag; run(phone, SyncEngine.Operation.PULL);
        assertEquals(tv.values, phone.values); assertEquals(etag, client.read().etag); assertEquals(1, phone.backups);
    }
    @Test public void clearingKeepsLocalAndPausesOtherDevicesEvenAfterRebuild() throws Exception {
        tv.put("a", 1); run(tv, SyncEngine.Operation.SYNC); run(phone, SyncEngine.Operation.SYNC);
        run(tv, SyncEngine.Operation.CLEAR); assertTrue(tv.replica.paused); assertEquals(1, tv.values.size());
        run(tv, SyncEngine.Operation.REBUILD); assertFalse(tv.replica.paused);
        run(phone, SyncEngine.Operation.SYNC); assertTrue(phone.replica.paused); assertEquals(1, phone.values.size());
    }
    @Test public void acceptResetStartsEmptyAndAutoSyncCanResume() throws Exception {
        tv.put("a", 1); run(tv, SyncEngine.Operation.SYNC); run(phone, SyncEngine.Operation.SYNC);
        run(tv, SyncEngine.Operation.CLEAR); run(phone, SyncEngine.Operation.SYNC);
        run(phone, SyncEngine.Operation.ACCEPT_RESET); assertTrue(phone.values.isEmpty()); assertFalse(phone.replica.paused);
        phone.put("new", 2); run(phone, SyncEngine.Operation.SYNC); assertFalse(phone.replica.paused);
        assertEquals(1, client.read().document.records.size());
        run(tv, SyncEngine.Operation.ACCEPT_RESET); assertTrue(tv.values.containsKey(id("new"))); assertFalse(tv.values.containsKey(id("a")));
    }
    @Test public void missingRemoteAfterPriorSyncPausesInsteadOfUploading() throws Exception {
        tv.put("a", 1); run(tv, SyncEngine.Operation.SYNC); server.clear();
        run(tv, SyncEngine.Operation.SYNC); assertTrue(tv.replica.paused); assertEquals(1, tv.values.size()); assertTrue(files.isEmpty());
    }
    @Test public void overwriteIsBlockedWhilePlaying() throws Exception {
        tv.playing = true;
        try { run(tv, SyncEngine.Operation.PULL); fail(); } catch (IOException expected) { assertTrue(expected.getMessage().contains("退出播放")); }
        assertTrue(files.isEmpty());
    }
    @Test public void malformedRemoteCannotClearLocal() throws Exception {
        tv.put("a", 1); server.put("/fongmi-sync-v1/state.json", "{}".getBytes(java.nio.charset.StandardCharsets.UTF_8));
        try { run(tv, SyncEngine.Operation.PULL); fail(); } catch (IOException expected) { }
        assertEquals(1, tv.values.size()); assertEquals(0, tv.backups);
    }
    @Test public void editsDuringRequestArePreservedForNextUpload() throws Exception {
        tv.put("a", 1); run(tv, SyncEngine.Operation.SYNC);
        phone.duringApply = () -> phone.put("just-edited", 2);
        run(phone, SyncEngine.Operation.SYNC);
        assertTrue(phone.values.containsKey(id("just-edited")));
        run(phone, SyncEngine.Operation.SYNC); run(tv, SyncEngine.Operation.SYNC);
        assertTrue(tv.values.containsKey(id("just-edited")));
    }
    private static String id(String key) { return SyncDocument.identity("test", key); }
    private static class MemoryLocal implements SyncEngine.Local {
        final SyncReplica replica = new SyncReplica(); final String device;
        Map<String, JsonObject> values = new TreeMap<>(); long now = System.currentTimeMillis(); int backups; boolean playing; Runnable duringApply;
        MemoryLocal(String device) { this.device = device; }
        void put(String key, int value) { JsonObject obj = new JsonObject(); obj.addProperty("n", value); values.put(id(key), obj); }
        @Override public SyncReplica replica() { return replica; }
        @Override public boolean isPlaying() { return playing; }
        @Override public void validate(SyncDocument doc) { doc.validate(); }
        @Override public void capture() { Map<String, String> kinds = new TreeMap<>(); values.keySet().forEach(k -> kinds.put(k, "test")); replica.observe(values, kinds, device, ++now); }
        @Override public SyncDocument snapshot() { SyncReplica temp = new SyncReplica(); temp.clock = replica.clock; Map<String, String> kinds = new TreeMap<>(); values.keySet().forEach(k -> kinds.put(k, "test")); temp.observe(values, kinds, device, ++now); return temp.document; }
        @Override public void backup() { backups++; }
        @Override public void install(SyncDocument doc) { values = new TreeMap<>(); doc.records.forEach((k, v) -> { if (!v.deleted) values.put(k, v.value.deepCopy()); }); replica.receive(doc); replica.setObserved(values); }
        @Override public void applyMerged(SyncDocument doc, boolean replacing) {
            if (duringApply != null) { Runnable edit = duringApply; duringApply = null; edit.run(); }
            capture(); SyncDocument latest = replica.document.copy(); latest.epoch = doc.epoch;
            install(replacing ? doc : SyncDocument.merge(latest, doc));
        }
        @Override public void save() { }
        @Override public void pause(String message) { replica.paused = true; }
        @Override public void success(String message) { }
    }
}

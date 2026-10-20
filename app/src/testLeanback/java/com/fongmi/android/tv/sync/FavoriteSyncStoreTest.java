package com.fongmi.android.tv.sync;

import androidx.room.Room;
import com.fongmi.android.tv.App;
import com.fongmi.android.tv.bean.Config;
import com.fongmi.android.tv.bean.Keep;
import com.fongmi.android.tv.db.AppDatabase;
import java.lang.reflect.Field;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import static org.junit.Assert.*;

/** 隔离内存数据库；验证正式收藏字段映射和真实 HTTP 同步链路。 */
@RunWith(RobolectricTestRunner.class)
@org.robolectric.annotation.Config(application = FavoriteSyncStoreTest.TestApp.class, sdk = 28)
public class FavoriteSyncStoreTest {
    public static class TestApp extends App { @Override public void onCreate() {} }
    private AppDatabase first, second;
    private Field instance;
    private TestDavServer server;
    private final SyncStore store = new SyncStore();
    private long clock = System.currentTimeMillis();

    @Before public void setup() throws Exception {
        instance = AppDatabase.class.getDeclaredField("instance"); instance.setAccessible(true);
        first = Room.inMemoryDatabaseBuilder(App.get(), AppDatabase.class).allowMainThreadQueries().build();
        second = Room.inMemoryDatabaseBuilder(App.get(), AppDatabase.class).allowMainThreadQueries().build();
        use(first);
        server = new TestDavServer(); server.start();
    }
    @After public void cleanup() throws Exception {
        server.stop(); first.close(); second.close(); instance.set(null, null);
    }
    private void use(AppDatabase db) throws Exception { instance.set(null, db); }
    private Config source(int id) {
        Config source = new Config(); source.setId(id); source.setUrl("https://example.invalid/source.json");
        source.setType(0); source.setName("测试源"); source.setHome("test");
        AppDatabase.get().getConfigDao().insert(source);
        return source;
    }
    private void favorite(int cid, String vod) {
        Keep keep = new Keep(); keep.setCid(cid); keep.setType(0);
        keep.setKey("site@@@" + vod + "@@@" + cid); keep.setSiteName("测试站");
        keep.setVodName("测试影片" + vod); keep.setVodPic("https://example.invalid/picture.jpg");
        keep.setCreateTime(123456); AppDatabase.get().getKeepDao().insertOrUpdate(keep);
    }
    private void observe(SyncReplica replica, String device) {
        SyncStore.Values values = store.capture();
        replica.observe(values.values, values.kinds, device, ++clock);
    }
    private SyncDocument snapshot() {
        SyncReplica replica = new SyncReplica(); observe(replica, "test"); return replica.document;
    }
    @Test public void roundTripRemapsSourceIdAndPreservesAllFavoriteFields() throws Exception {
        source(41); favorite(41, "one"); SyncDocument document = snapshot();
        use(second); source(87); store.apply(document); store.apply(document);
        Keep restored = second.getKeepDao().getVod().get(0);
        assertEquals(1, second.getKeepDao().getVod().size());
        assertEquals(87, restored.getCid()); assertEquals("site@@@one@@@87", restored.getKey());
        assertEquals("测试影片one", restored.getVodName()); assertEquals("测试站", restored.getSiteName());
        assertEquals("https://example.invalid/picture.jpg", restored.getVodPic()); assertEquals(123456, restored.getCreateTime());
    }
    @Test public void cancelFavoritePropagatesAndOldDeviceCannotResurrectIt() throws Exception {
        source(41); favorite(41, "one"); SyncReplica tv = new SyncReplica(); observe(tv, "tv");
        SyncDocument old = tv.document.copy();
        first.getKeepDao().delete(41, "site@@@one@@@41"); observe(tv, "tv");
        SyncDocument merged = SyncDocument.merge(tv.document, old);
        use(second); store.apply(old); assertEquals(1, second.getKeepDao().getVod().size());
        store.apply(merged); assertTrue(second.getKeepDao().getVod().isEmpty());
        assertTrue(SyncDocument.merge(old, merged).records.values().stream().anyMatch(e -> e.kind.equals("favorite") && e.deleted));
    }
    @Test public void liveFavoriteDoesNotRequireVodSource() throws Exception {
        Keep keep = new Keep(); keep.setKey("测试频道"); keep.setType(1); keep.setVodName("测试频道");
        keep.setCreateTime(123456); first.getKeepDao().insertOrUpdate(keep);
        SyncDocument document = snapshot(); use(second); store.apply(document);
        assertEquals(1, second.getKeepDao().getLive().size());
        assertEquals("测试频道", second.getKeepDao().getLive().get(0).getKey());
    }
    @Test public void twoDatabasesSyncFavoritesAndDeletionThroughRealHttp() throws Exception {
        source(41); favorite(41, "one"); DbLocal a = new DbLocal(first, "tv");
        use(second); source(87); favorite(87, "two"); DbLocal b = new DbLocal(second, "other-tv");
        sync(a); sync(b); sync(a);
        assertEquals(2, first.getKeepDao().getVod().size()); assertEquals(2, second.getKeepDao().getVod().size());
        second.getKeepDao().delete(87, "site@@@one@@@87");
        sync(b); sync(a); sync(b);
        assertEquals(1, first.getKeepDao().getVod().size()); assertEquals(1, second.getKeepDao().getVod().size());
        assertTrue(first.getKeepDao().getVod().get(0).getKey().contains("two"));
    }
    @Test public void playbackAppliesFavoritesWithoutReplacingHistoryOrActiveSource() throws Exception {
        source(41); favorite(41, "one");
        com.fongmi.android.tv.bean.History history = new com.fongmi.android.tv.bean.History();
        history.setKey("site@@@one@@@41"); history.setCid(41); history.setVodName("正在播放");
        history.setPosition(12345); history.setDuration(99999); history.setCreateTime(123456);
        first.getHistoryDao().insertOrUpdate(history);
        com.github.catvod.utils.Prefers.put("config_0", "https://example.invalid/source.json");
        SyncReplica local = new SyncReplica(); observe(local, "tv");
        favorite(41, "two");
        SyncReplica remote = new SyncReplica(); observe(remote, "other-tv");
        String sourceId = SyncStore.sourceId("https://example.invalid/source.json", 0);
        remote.document.records.get(sourceId).value.addProperty("home", "remote-home");
        remote.document.records.values().stream().filter(e -> e.kind.equals("history"))
                .forEach(e -> e.value.addProperty("positionMs", 88888));
        first.getKeepDao().delete(41, "site@@@two@@@41");
        installWhilePlaying(local, remote.document);
        assertEquals(2, first.getKeepDao().getVod().size());
        assertEquals(12345, first.getHistoryDao().find(41, "site@@@one@@@41").getPosition());
        assertEquals("test", first.getConfigDao().findById(41).getHome());
        assertEquals("https://example.invalid/source.json", com.github.catvod.utils.Prefers.getString("config_0"));
        assertEquals("remote-home", local.document.records.get(sourceId).value.get("home").getAsString());
        // 新下载收藏必须更新观测基线，下一次扫描不能把它误判为本机新增。
        String added = SyncDocument.identity("favorite", "vod", sourceId, "site", "two");
        long version = local.document.records.get(added).modified;
        observe(local, "tv");
        assertEquals(version, local.document.records.get(added).modified);
    }

    @Test public void playbackAlsoAppliesFavoriteDeletionImmediately() throws Exception {
        source(41); favorite(41, "one"); SyncReplica local = new SyncReplica(); observe(local, "tv");
        SyncReplica remote = new SyncReplica(); remote.receive(local.document); remote.setObserved(store.capture().values);
        first.getKeepDao().delete(41, "site@@@one@@@41"); observe(remote, "other-tv");
        favorite(41, "one");
        installWhilePlaying(local, remote.document);
        assertTrue(first.getKeepDao().getVod().isEmpty());
    }

    @Test public void playbackImportsRequiredSourceForNewFavoriteWithoutSwitchingSource() throws Exception {
        source(41); favorite(41, "one"); SyncDocument remote = snapshot();
        use(second);
        com.github.catvod.utils.Prefers.put("config_0", "https://example.invalid/current.json");
        store.applyFavoritesDuringPlayback(remote);
        assertEquals(1, second.getKeepDao().getVod().size());
        assertEquals("https://example.invalid/current.json", com.github.catvod.utils.Prefers.getString("config_0"));
    }

    private void installWhilePlaying(SyncReplica local, SyncDocument remote) throws Exception {
        WebDavSync sync = WebDavSync.get();
        for (String name : new String[]{"replica", "scope", "playbackActivities"}) {
            Field field = WebDavSync.class.getDeclaredField(name); field.setAccessible(true);
            field.set(sync, name.equals("replica") ? local : name.equals("scope") ? "favorite-playback-test" : 1);
        }
        var method = WebDavSync.class.getDeclaredMethod("installMerged", SyncDocument.class, boolean.class);
        method.setAccessible(true); method.invoke(sync, remote, false);
    }

    private void sync(DbLocal local) throws Exception {
        use(local.db);
        new SyncEngine(new WebDavClient(server.address(), "test", "test-only"), local).run(SyncEngine.Operation.SYNC);
    }
    private final class DbLocal implements SyncEngine.Local {
        final AppDatabase db; final String device; final SyncReplica replica = new SyncReplica();
        DbLocal(AppDatabase db, String device) { this.db = db; this.device = device; }
        public SyncReplica replica() { return replica; }
        public boolean isPlaying() { return false; }
        public void validate(SyncDocument document) { store.validate(document); }
        public void capture() { observe(replica, device); }
        public SyncDocument snapshot() { return FavoriteSyncStoreTest.this.snapshot(); }
        public void backup() {}
        public void install(SyncDocument document) { store.apply(document); replica.receive(document); replica.setObserved(store.capture().values); }
        public void applyMerged(SyncDocument document, boolean replacing) { install(document); }
        public void save() {}
        public void pause(String message) { replica.paused = true; }
        public void success(String message) {}
    }
}

package com.fongmi.android.tv.sync;

import androidx.room.Room;
import com.fongmi.android.tv.App;
import com.fongmi.android.tv.bean.Config;
import com.fongmi.android.tv.bean.History;
import com.fongmi.android.tv.db.AppDatabase;
import com.google.gson.JsonObject;
import java.lang.reflect.Field;
import org.junit.*;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import static org.junit.Assert.*;

@RunWith(RobolectricTestRunner.class)
@org.robolectric.annotation.Config(application = EpisodeProgressStoreTest.TestApp.class, sdk = 28)
public class EpisodeProgressStoreTest {
    public static class TestApp extends App { @Override public void onCreate() {} }
    private AppDatabase tv, phone;
    private Field instance;
    private final SyncStore store = new SyncStore();
    @Before public void setup() throws Exception {
        instance = AppDatabase.class.getDeclaredField("instance"); instance.setAccessible(true);
        tv = Room.inMemoryDatabaseBuilder(App.get(), AppDatabase.class).allowMainThreadQueries().build();
        phone = Room.inMemoryDatabaseBuilder(App.get(), AppDatabase.class).allowMainThreadQueries().build();
        instance.set(null, tv); source(41);
    }
    @After public void cleanup() throws Exception { tv.close(); phone.close(); instance.set(null, null); }
    private void source(int id) {
        Config c = new Config(); c.setId(id); c.setUrl("https://example.invalid/episodes.json"); c.setType(0); c.setName("测试源"); c.setHome("site");
        AppDatabase.get().getConfigDao().insert(c);
    }
    private History history(int cid, String episode, long position) {
        History h = new History(); h.setCid(cid); h.setKey("site@@@vod@@@" + cid); h.setVodName("同一节目"); h.setVodPic("");
        h.setVodFlag("线路"); h.setVodRemarks(episode); h.setEpisodeUrl("https://example.invalid/" + episode + ".mp4");
        h.setCreateTime(System.currentTimeMillis()); h.setPosition(position); h.setDuration(600000); return h;
    }
    private SyncDocument snapshot() {
        SyncStore.Values values = store.capture(); SyncReplica replica = new SyncReplica();
        replica.observe(values.values, values.kinds, "tv", System.currentTimeMillis()); return replica.document;
    }
    private static void field(Object target, String name, Object value) throws Exception {
        Field field = target.getClass().getDeclaredField(name); field.setAccessible(true); field.set(target,value);
    }
    private static void invoke(Object target, String method, Class<?>[] types, Object... values) throws Exception {
        java.lang.reflect.Method action = target.getClass().getDeclaredMethod(method,types); action.setAccessible(true); action.invoke(target,values);
    }
    private void verifyDeferredProgress(boolean localContinues) throws Exception {
        long base = System.currentTimeMillis()-10000;
        History original = history(41,"第1集",10000); original.setCreateTime(base); original.save();
        SyncStore.Values values = store.capture(); SyncReplica replica = new SyncReplica();
        replica.observe(values.values,values.kinds,"tv",base); replica.acknowledge(replica.localRevision);
        WebDavSync sync = new WebDavSync();
        String scope = SyncDocument.identity(java.util.UUID.randomUUID().toString());
        field(sync,"replica",replica); field(sync,"scope",scope); field(sync,"playbackActivities",1);
        SyncDocument remote = replica.document.copy();
        for (SyncDocument.Entry entry : remote.records.values()) {
            if (!entry.kind.equals("history") && !entry.kind.equals(EpisodeProgress.KIND)) continue;
            entry.value.addProperty("positionMs",90000); entry.value.addProperty("watchedAt",base+1000);
            entry.modified = base+1000; entry.device = "phone";
        }
        invoke(sync,"installMerged",new Class<?>[]{SyncDocument.class,boolean.class},remote,false);
        assertEquals(10000,tv.getHistoryDao().find(41,original.getKey()).getPosition());
        java.io.File deferred = new java.io.File(App.get().getFilesDir(),"webdav-sync/"+scope+".pending");
        assertTrue("播放期间应保留待应用日志",deferred.exists());
        if (localContinues) { original.setPosition(120000); original.setCreateTime(base+2000); original.save(); }
        field(sync,"playbackActivities",0);
        invoke(sync,"applyDeferredIfSafe",new Class<?>[]{});
        assertEquals(localContinues ? 120000 : 90000,tv.getHistoryDao().find(41,original.getKey()).getPosition());
        assertFalse(deferred.exists());
    }
    @Test public void incomingProgressIsDeferredUntilPlaybackEnds() throws Exception { verifyDeferredProgress(false); }
    @Test public void localProgressDuringRequestWinsOverOlderDeferredProgress() throws Exception { verifyDeferredProgress(true); }
    @Test public void pausedOldDeviceDoesNotAcquireNewWatchTimeButRewindDoes() {
        History paused = history(41,"第1集",10000); paused.setCreateTime(100); paused.markSaveScheduled();
        com.fongmi.android.tv.playback.vod.VodHistoryPolicy policy = new com.fongmi.android.tv.playback.vod.VodHistoryPolicy();
        policy.updateProgress(paused,300,10000,600000);
        assertEquals(100,paused.getCreateTime());
        policy.updateProgress(paused,400,5000,600000);
        assertEquals(400,paused.getCreateTime()); assertEquals(5000,paused.getPosition());
    }
    @Test public void switchingEpisodesStoresTwoPositionsAndOnlyOneHomeCard() {
        history(41, "第1集", 10000).save(); history(41, "第2集", 90000).save();
        assertEquals(1, tv.getHistoryDao().findAll().size());
        assertEquals(2, tv.getEpisodeProgressDao().findAll().size());
        History first = history(41,"第1集",0), second=history(41,"第2集",0);
        assertTrue(EpisodeProgressStore.restore(first)); assertEquals(10000,first.getPosition());
        assertTrue(EpisodeProgressStore.restore(second)); assertEquals(90000,second.getPosition());
    }
    @Test public void wireRoundTripRemapsDatabaseIdAndPreservesEachEpisode() throws Exception {
        history(41,"第1集",10000).save(); history(41,"第2集",90000).save();
        SyncDocument wire = SyncDocument.parse(new com.google.gson.Gson().toJson(snapshot()));
        instance.set(null,phone); source(87); store.apply(wire); store.apply(wire);
        assertEquals(1,phone.getHistoryDao().findAll().size()); assertEquals(2,phone.getEpisodeProgressDao().findAll().size());
        History h=history(87,"第1集",0); assertTrue(EpisodeProgressStore.restore(h)); assertEquals(10000,h.getPosition());
        h=history(87,"第2集",0); assertTrue(EpisodeProgressStore.restore(h)); assertEquals(90000,h.getPosition());
        phone.getHistoryDao().delete(87,h.getKey());
        assertTrue(phone.getEpisodeProgressDao().findAll().isEmpty());
        assertFalse(store.capture().kinds.containsValue(EpisodeProgress.KIND));
    }
    @Test public void legacyHistoryIsSeededWithoutResettingKnownEpisode() {
        History h=history(41,"第1集",45000); tv.getHistoryDao().insertOrUpdate(h);
        assertEquals(1,snapshot().records.values().stream().filter(e->e.kind.equals(EpisodeProgress.KIND)).count());
        h.save(); h.setPosition(5000); h.save();
        JsonObject value=store.capture().values.get(EpisodeProgress.id(EpisodeProgressStore.value(h,SyncStore.sourceId("https://example.invalid/episodes.json",0))));
        assertEquals(5000,value.get("positionMs").getAsLong());
    }
    @Test public void sharedGoldenIdentityMatchesIPhoneAndTokensDoNotChangeIt() {
        JsonObject value=new JsonObject(); value.addProperty("source","source"); value.addProperty("site","site"); value.addProperty("vod","vod");
        value.addProperty("line","夸父原1"); value.addProperty("episode","Android名称"); value.addProperty("episodeUrl","{\"sId\":\"share1\",\"fid\":\"fid1\",\"sToken\":\"old\"}");
        String id=EpisodeProgress.id(value);
        assertEquals("a27d2a01d4889587714424a1ee9b937c3876b5ca23140f656f39821fcbeba700",id);
        value.addProperty("line","夸父智1");value.addProperty("episode","iPhone名称");value.addProperty("episodeUrl","{\"sId\":\"share1\",\"fid\":\"fid1\",\"sToken\":\"new\"}");
        assertEquals(id,EpisodeProgress.id(value));
    }
    @Test public void migrationFrom35PreservesHistoryAndRoomValidatesNewSchema() throws Exception {
        String name="episode-migration-test";
        App.get().deleteDatabase(name);
        android.database.sqlite.SQLiteDatabase old=App.get().openOrCreateDatabase(name,0,null);
        java.io.File schema=new java.io.File("schemas/com.fongmi.android.tv.db.AppDatabase/35.json");
        if (!schema.exists()) schema=new java.io.File("app/schemas/com.fongmi.android.tv.db.AppDatabase/35.json");
        JsonObject root=com.google.gson.JsonParser.parseString(java.nio.file.Files.readString(schema.toPath())).getAsJsonObject().getAsJsonObject("database");
        for (com.google.gson.JsonElement entity:root.getAsJsonArray("entities")) {
            JsonObject table=entity.getAsJsonObject();
            old.execSQL(table.get("createSql").getAsString().replace("${TABLE_NAME}",table.get("tableName").getAsString()));
            if (table.has("indices")) for (com.google.gson.JsonElement index:table.getAsJsonArray("indices")) old.execSQL(index.getAsJsonObject().get("createSql").getAsString().replace("${TABLE_NAME}",table.get("tableName").getAsString()));
        }
        for (com.google.gson.JsonElement query:root.getAsJsonArray("setupQueries")) old.execSQL(query.getAsString());
        old.execSQL("INSERT INTO History (`key`, revSort, revPlay, createTime, opening, ending, position, duration, speed, scale, cid) VALUES ('site@@@vod@@@41',0,0,100,0,0,45000,600000,1,-1,41)");
        old.setVersion(35); old.close();
        AppDatabase upgraded=Room.databaseBuilder(App.get(),AppDatabase.class,name).allowMainThreadQueries().addMigrations(com.fongmi.android.tv.db.Migrations.MIGRATION_35_36).build();
        try {
            assertEquals(45000,upgraded.getHistoryDao().find(41,"site@@@vod@@@41").getPosition());
            assertTrue(upgraded.getEpisodeProgressDao().findAll().isEmpty());
        } finally { upgraded.close(); App.get().deleteDatabase(name); }
    }
    @Test public void sharedWireFixtureRestoresTwoEpisodesWithIPhoneRouteNames() throws Exception {
        java.io.File fixture=new java.io.File("../docs/fixtures/episode-progress-v1.json");
        if (!fixture.exists()) fixture=new java.io.File("docs/fixtures/episode-progress-v1.json");
        SyncDocument doc=SyncDocument.parse(java.nio.file.Files.readString(fixture.toPath()));
        instance.set(null,phone); store.apply(doc);
        Config config=phone.getConfigDao().find("https://example.invalid/cross-platform.json",0);
        assertNotNull(config);
        History summary=phone.getHistoryDao().find(config.getId(),"site@@@vod@@@"+config.getId());
        assertEquals(90000,summary.getOpening()); assertEquals(60000,summary.getEnding());
        assertEquals(1,phone.getHistoryDao().findAll().size());
        for (int n=1;n<=2;n++) {
            History h=history(config.getId(),"iPhone名称",0);h.setVodFlag("夸父智1");
            h.setEpisodeUrl("{\"sId\":\"share1\",\"fid\":\"fid"+n+"\",\"sToken\":\"new\"}");
            assertTrue(EpisodeProgressStore.restore(h)); assertEquals(n==1?10000:90000,h.getPosition());
        }
        assertEquals(2,phone.getEpisodeProgressDao().findAll().size());
    }
    @Test public void realPlayerPolicyRestoresEachEpisodeAndDoesNotCarryOtherEpisodePosition() {
        history(41,"第1集",10000).save(); history(41,"第2集",90000).save();
        History current=history(41,"第2集",90000);
        com.fongmi.android.tv.playback.vod.VodHistoryPolicy policy=new com.fongmi.android.tv.playback.vod.VodHistoryPolicy();
        com.fongmi.android.tv.bean.Flag flag=com.fongmi.android.tv.bean.Flag.create("线路");
        policy.updateEpisode(current,flag,com.fongmi.android.tv.bean.Episode.create("第1集","https://example.invalid/第1集.mp4"));
        assertEquals(10000,policy.startPositionMs(current));
        policy.updateEpisode(current,flag,com.fongmi.android.tv.bean.Episode.create("第2集","https://example.invalid/第2集.mp4"));
        assertEquals(90000,policy.startPositionMs(current));
        policy.updateEpisode(current,flag,com.fongmi.android.tv.bean.Episode.create("第3集","https://example.invalid/第3集.mp4"));
        assertEquals(androidx.media3.common.C.TIME_UNSET,current.getPosition());
    }
}

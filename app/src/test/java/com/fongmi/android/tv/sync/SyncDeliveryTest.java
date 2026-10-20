package com.fongmi.android.tv.sync;

import com.google.gson.Gson;
import com.google.gson.JsonObject;
import java.util.Map;
import org.junit.Test;
import static org.junit.Assert.*;

public class SyncDeliveryTest {
    @Test public void queuedChangesAndRetryStateSurviveRestart() {
        SyncReplica replica = new SyncReplica();
        JsonObject value = new JsonObject(); value.addProperty("position", 100);
        String id = SyncDocument.identity("test");
        replica.observe(Map.of(id,value),Map.of(id,"test"),"tv",100);
        long revision = replica.localRevision;
        replica.observe(Map.of(id,value),Map.of(id,"test"),"tv",200);
        assertEquals(revision,replica.localRevision);
        replica.retryNeeded = true;
        SyncReplica loaded = SyncReplica.parse(new Gson().toJson(replica));
        assertTrue(loaded.pendingUpload());
        assertEquals("同步失败，等待重试",loaded.deliveryText(false,true,true,false));
        assertEquals("同步中…",loaded.deliveryText(true,true,true,false));
        loaded.acknowledge(revision);
        assertEquals("已同步",loaded.deliveryText(false,true,true,false));
        assertEquals("已同步，云端进度将在退出播放后应用",loaded.deliveryText(false,true,true,true));
    }
    @Test public void acknowledgingOlderRequestKeepsNewerEditsPending() {
        SyncReplica replica = new SyncReplica();
        replica.localRevision = 2; replica.acknowledge(1);
        assertTrue(replica.pendingUpload());
        assertEquals("待同步（自动同步已关闭）",replica.deliveryText(false,true,false,false));
        replica.acknowledge(2); assertFalse(replica.pendingUpload());
        replica.paused = true;
        assertEquals("同步已暂停",replica.deliveryText(false,true,true,false));
    }
}

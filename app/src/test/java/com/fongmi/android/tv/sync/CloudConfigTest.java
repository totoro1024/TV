package com.fongmi.android.tv.sync;

import com.google.gson.JsonObject;
import org.junit.Test;
import java.util.Base64;
import java.util.Map;
import static org.junit.Assert.*;

/** 只使用合成登录态，不读取或输出用户的 Cookie、Token。 */
public class CloudConfigTest {
    private JsonObject sample(String cookie, String key) {
        return CloudConfig.pack(Map.of("quark_ck", cookie, "hide_appgz_new_key", key), Map.of(),
                Map.of("ali_oauth", new byte[]{0, -1, 2, 3}));
    }
    @Test public void binaryTokensAndPairedKeysSurviveRoundTrip() {
        JsonObject packed = sample("test-cookie-&+中文", "test-key");
        CloudConfig.validate(packed);
        assertEquals("test-cookie-&+中文", packed.getAsJsonObject("prefs").get("quark_ck").getAsString());
        assertEquals("test-key", packed.getAsJsonObject("prefs").get("hide_appgz_new_key").getAsString());
        assertArrayEquals(new byte[]{0,-1,2,3}, Base64.getDecoder().decode(packed.getAsJsonObject("files").get("ali_oauth").getAsString()));
    }
    @Test public void unrelatedDeviceAndApplicationDataAreNotCollected() {
        JsonObject packed = CloudConfig.pack(Map.of("quark_ck", "test", "lastQuarkDownUrl", "private", "libCk", "private"),
                Map.of("quark_ck", "test", "config_0", "private", "password", "private"),
                Map.of("webdav-sync/state.json", new byte[]{1}, "ali_user", new byte[]{2}));
        assertEquals(1, packed.getAsJsonObject("prefs").size());
        assertEquals(1, packed.getAsJsonObject("defaults").size());
        assertEquals(1, packed.getAsJsonObject("files").size());
    }
    @Test public void deviceMaterialAloneDoesNotCreateAnAccount() {
        assertNull(CloudConfig.pack(Map.of("hide_appgz_new_key", "test-key"), Map.of(), Map.of()));
    }
    @Test public void quarkBootstrapFileWithoutCookieIsNotALoggedInAccount() {
        // 来自失败设备的字段结构；内容全部为合成值。
        JsonObject bootstrap = CloudConfig.pack(Map.of(
                "hide_appgz_android_id", "test-device", "hide_appgz_new_key", "test-key",
                "hide_appgz_utdid", "test-id", "hide_appgz_token", "test-bootstrap"),
                Map.of(), Map.of("quark_ut", new byte[]{1, 2, 3}));
        assertNull("仅有夸克配套文件不能覆盖其他设备的有效Cookie", bootstrap);
    }
    private JsonObject legacyBootstrap() {
        JsonObject value = sample("test", "test");
        value.getAsJsonObject("prefs").remove("quark_ck");
        value.getAsJsonObject("files").remove("ali_oauth");
        value.getAsJsonObject("files").addProperty("quark_ut", "AQID");
        return value;
    }
    @Test public void legacyRemoteBootstrapCannotOverwriteARealCookie() {
        SyncReplica remote = new SyncReplica(), local = new SyncReplica();
        remote.document.epoch = local.document.epoch;
        local.observe(Map.of(CloudConfig.ID, sample("real-cookie", "real-key")), Map.of(CloudConfig.ID, CloudConfig.KIND), "logged-in", 100);
        remote.observe(Map.of(CloudConfig.ID, legacyBootstrap()), Map.of(CloudConfig.ID, CloudConfig.KIND), "blank-device", 200);
        SyncDocument parsed = SyncDocument.parse(new com.google.gson.Gson().toJson(remote.document));
        SyncDocument merged = SyncDocument.merge(local.document, parsed);
        assertEquals("real-cookie", merged.records.get(CloudConfig.ID).value.getAsJsonObject("prefs").get("quark_ck").getAsString());
    }
    @Test public void upgradingLegacyBootstrapDoesNotPublishALogout() {
        SyncReplica old = new SyncReplica();
        old.observe(Map.of(CloudConfig.ID, legacyBootstrap()), Map.of(CloudConfig.ID, CloudConfig.KIND), "blank-device", 100);
        CloudConfig.migrate(old);
        old.observe(Map.of(), Map.of(), "blank-device", 200);
        assertFalse(old.document.records.containsKey(CloudConfig.ID));
    }
    @Test public void migrationKeepsRealAccountsAndExplicitLogoutRecords() {
        SyncReplica replica = new SyncReplica();
        replica.observe(Map.of(CloudConfig.ID, sample("test", "test")), Map.of(CloudConfig.ID, CloudConfig.KIND), "device", 100);
        CloudConfig.migrate(replica);
        assertTrue(replica.document.records.containsKey(CloudConfig.ID));
        replica.observe(Map.of(), Map.of(), "device", 200);
        CloudConfig.migrate(replica);
        assertTrue(replica.document.records.get(CloudConfig.ID).deleted);
    }
    @Test public void remotePathsOutsideWhitelistAreRejected() {
        JsonObject value = sample("test", "test");
        value.getAsJsonObject("files").addProperty("../webdav.xml", "AA==");
        assertThrows(IllegalArgumentException.class, () -> CloudConfig.validate(value));
    }
    @Test public void remoteApplicationSettingsAreRejected() {
        JsonObject value = sample("test", "test");
        value.getAsJsonObject("defaults").addProperty("config_0", "test");
        assertThrows(IllegalArgumentException.class, () -> CloudConfig.validate(value));
    }
    @Test public void oversizedAndInvalidBinaryDataAreRejected() {
        assertThrows(IllegalArgumentException.class, () -> CloudConfig.pack(Map.of(), Map.of(), Map.of("ali_oauth", new byte[CloudConfig.MAX_FILE + 1])));
        JsonObject value = sample("test", "test"); value.getAsJsonObject("files").addProperty("ali_oauth", "invalid!");
        assertThrows(IllegalArgumentException.class, () -> CloudConfig.validate(value));
    }
    @Test public void accountsMergeAsAUnitWithoutMixingKeys() {
        SyncReplica left = new SyncReplica(), right = new SyncReplica();
        right.document.epoch = left.document.epoch;
        left.observe(Map.of(CloudConfig.ID, sample("cookie-a", "key-a")), Map.of(CloudConfig.ID, CloudConfig.KIND), "a", 100);
        right.observe(Map.of(CloudConfig.ID, sample("cookie-b", "key-b")), Map.of(CloudConfig.ID, CloudConfig.KIND), "b", 200);
        JsonObject prefs = SyncDocument.merge(left.document, right.document).records.get(CloudConfig.ID).value.getAsJsonObject("prefs");
        assertEquals("cookie-b", prefs.get("quark_ck").getAsString());
        assertEquals("key-b", prefs.get("hide_appgz_new_key").getAsString());
    }
    @Test public void logoutCreatesADeletionRecord() {
        SyncReplica replica = new SyncReplica();
        replica.observe(Map.of(CloudConfig.ID, sample("test", "test")), Map.of(CloudConfig.ID, CloudConfig.KIND), "device", 100);
        replica.observe(Map.of(), Map.of(), "device", 200);
        assertTrue(replica.document.records.get(CloudConfig.ID).deleted);
    }
}

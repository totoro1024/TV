package com.fongmi.android.tv.sync;

import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import java.util.Base64;
import java.util.Map;
import java.util.Set;

/** 源插件网盘登录态的受限便携包，成组处理，避免密文和解码材料来自不同设备。 */
public final class CloudConfig {
    public static final String KIND = "cloudAccount";
    public static final String ADAPTER = "catvod-sp-utils-v1";
    public static final String ID = SyncDocument.identity(KIND, ADAPTER);
    public static final int MAX_FILE = 256 * 1024;
    public static final Set<String> FILES = Set.of("ali_info", "ali_oauth", "ali_user", "quark_ut", "uc_fid", "uc_ut", "mybd_cookie");
    public static final Set<String> PREFS = Set.of("quark_ck", "uc_ck", "quarkSt", "ucSt",
            "hide_appgz_android_id", "hide_appgz_new_key", "hide_appgz_utdid", "hide_appgz_token");
    public static final Set<String> DEFAULT_PREFS = Set.of("quark_ck", "uc_ck", "baidu_cookie");
    private CloudConfig() {}

    public static JsonObject pack(Map<String, String> prefs, Map<String, String> defaults, Map<String, byte[]> files) {
        JsonObject result = new JsonObject(); result.addProperty("adapter", ADAPTER);
        JsonObject p = new JsonObject(), d = new JsonObject(), f = new JsonObject();
        prefs.forEach((key, value) -> { if (PREFS.contains(key) && !value.isEmpty()) p.addProperty(key, value); });
        defaults.forEach((key, value) -> { if (DEFAULT_PREFS.contains(key) && !value.isEmpty()) d.addProperty(key, value); });
        files.forEach((key, value) -> { if (FILES.contains(key) && value.length > 0) f.addProperty(key, Base64.getEncoder().encodeToString(value)); });
        result.add("prefs", p); result.add("defaults", d); result.add("files", f);
        validate(result);
        // 单独的设备派生材料不构成网盘登录配置。
        return hasLogin(result) ? result : null;
    }

    private static boolean hasLogin(JsonObject value) {
        JsonObject p = value.getAsJsonObject("prefs"), d = value.getAsJsonObject("defaults"), f = value.getAsJsonObject("files");
        for (String key : Set.of("quark_ck", "uc_ck"))
            if (p.has(key) && !p.get(key).getAsString().isEmpty()) return true;
        for (String key : DEFAULT_PREFS)
            if (d.has(key) && !d.get(key).getAsString().isEmpty()) return true;
        // quark_ut 是配套材料，设备未登录时也可能存在，不能证明持有 Cookie。
        for (String key : FILES)
            if (!key.equals("quark_ut") && f.has(key) && !f.get(key).getAsString().isEmpty()) return true;
        return false;
    }

    static boolean isBootstrap(JsonObject value) {
        try { validate(value); return !hasLogin(value); }
        catch (RuntimeException e) { return false; } // 无效结构交由原有校验拒绝。
    }

    static void migrate(SyncReplica replica) {
        discardBootstrap(replica.document);
        if (isBootstrap(replica.observed.get(ID))) replica.observed.remove(ID);
    }

    static void discardBootstrap(SyncDocument document) {
        SyncDocument.Entry entry = document.records.get(ID);
        if (entry != null && !entry.deleted && KIND.equals(entry.kind) && isBootstrap(entry.value))
            document.records.remove(ID);
    }

    public static void validate(JsonObject value) {
        if (!ADAPTER.equals(value.get("adapter").getAsString())) throw new IllegalArgumentException("网盘适配格式无效");
        check(value.getAsJsonObject("prefs"), PREFS, false);
        check(value.getAsJsonObject("defaults"), DEFAULT_PREFS, false);
        check(value.getAsJsonObject("files"), FILES, true);
        if (value.toString().length() > 2 * 1024 * 1024) throw new IllegalArgumentException("网盘配置过大");
    }

    private static void check(JsonObject values, Set<String> allowed, boolean binary) {
        if (values == null) throw new IllegalArgumentException("网盘配置缺少字段");
        for (Map.Entry<String, JsonElement> row : values.entrySet()) {
            if (!allowed.contains(row.getKey()) || !row.getValue().isJsonPrimitive() || !row.getValue().getAsJsonPrimitive().isString())
                throw new IllegalArgumentException("网盘配置含不支持的字段");
            String text = row.getValue().getAsString();
            if (text.length() > MAX_FILE * 2 || (binary && Base64.getDecoder().decode(text).length > MAX_FILE))
                throw new IllegalArgumentException("网盘配置字段过大");
        }
    }
}

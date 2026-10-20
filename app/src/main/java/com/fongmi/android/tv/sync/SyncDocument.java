package com.fongmi.android.tv.sync;

import com.google.gson.Gson;
import com.google.gson.JsonObject;
import com.google.gson.JsonElement;
import com.google.gson.JsonArray;
import com.google.gson.JsonNull;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Map;
import java.util.TreeMap;
import java.util.UUID;

/** 跨平台 v1 数据模型，时间与进度单位均为毫秒。 */
public final class SyncDocument {
    public static final int VERSION = 1;
    public int schema = VERSION;
    public String epoch = UUID.randomUUID().toString();
    public String mode = "merge";
    public String reset = "";
    public Map<String, Entry> records = new TreeMap<>();

    public static final class Entry {
        public String kind;
        public long modified;
        public long sequence;
        public String device;
        public boolean deleted;
        public JsonObject value;

        public Entry copy() {
            Entry e = new Entry();
            e.kind = kind;
            e.modified = modified;
            e.sequence = sequence;
            e.device = device;
            e.deleted = deleted;
            e.value = value == null ? null : value.deepCopy();
            return e;
        }
    }

    public static String identity(String... parts) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            for (String part : parts) {
                byte[] utf8 = part.getBytes(StandardCharsets.UTF_8);
                digest.update(java.nio.ByteBuffer.allocate(4).putInt(utf8.length).array());
                digest.update(utf8);
            }
            byte[] bytes = digest.digest();
            StringBuilder out = new StringBuilder();
            for (byte b : bytes) out.append(String.format(java.util.Locale.ROOT, "%02x", b & 255));
            return out.toString();
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    }

    public static SyncDocument parse(String json) {
        SyncDocument d;
        try {
            JsonObject root = canonicalize(new Gson().fromJson(json, JsonObject.class));
            root = readableNullValues(root);
            if (root == null || !root.has("schema") || !root.has("epoch") || !root.has("mode") || !root.has("records"))
                throw new IllegalArgumentException();
            d = new Gson().fromJson(root, SyncDocument.class);
        } catch (RuntimeException e) {
            throw new IllegalArgumentException("同步文件格式无效，未修改本地数据");
        }
        d.validate();
        CloudConfig.discardBootstrap(d);
        return d;
    }

    // Gson 的 JsonObject 字段适配器不接受显式 JsonNull；缺省值仍为 Java null。
    // 只去掉空 value 字段，保留整条删除记录及其版本，避免复活已删除内容。
    static JsonObject readableNullValues(JsonObject root) {
        if (root == null || !root.has("records") || !root.get("records").isJsonObject()) return root;
        JsonObject result = root.deepCopy();
        for (JsonElement element : result.getAsJsonObject("records").asMap().values()) {
            if (!element.isJsonObject()) continue;
            JsonObject entry = element.getAsJsonObject();
            if (entry.has("value") && entry.get("value").isJsonNull()) entry.remove("value");
        }
        return result;
    }

    /** 对照已发布 R8 mapping 的恢复，仅识别完整旧布局，绝不猜测未知版本。 */
    static JsonObject canonicalize(JsonObject root) {
        if (root == null || root.has("schema")) return root;
        if (root.has("epoch") || root.has("mode") || root.has("reset") || root.has("records") ||
                !string(root, "a") || !string(root, "b") || !string(root, "c") || !root.has("d") || !root.get("d").isJsonObject())
            return root;
        String epoch = root.get("a").getAsString();
        if (!UUID.fromString(epoch).toString().equalsIgnoreCase(epoch) ||
                !("merge".equals(root.get("b").getAsString()) || "replace".equals(root.get("b").getAsString()) || "reset".equals(root.get("b").getAsString())))
            throw new IllegalArgumentException("旧版同步格式无效");
        JsonObject result = rename(root, new String[][]{{"a","epoch"},{"b","mode"},{"c","reset"},{"d","records"}});
        result.addProperty("schema", VERSION);
        JsonObject records = new JsonObject();
        for (Map.Entry<String, JsonElement> row : root.getAsJsonObject("d").entrySet()) {
            if (!row.getValue().isJsonObject()) throw new IllegalArgumentException("旧版同步记录无效");
            JsonObject entry = row.getValue().getAsJsonObject();
            if (!string(entry, "a") || !number(entry, "b") || !number(entry, "c") || !string(entry, "d") ||
                    !entry.has("e") || !entry.get("e").isJsonPrimitive() || !entry.get("e").getAsJsonPrimitive().isBoolean())
                throw new IllegalArgumentException("旧版同步记录无效");
            records.add(row.getKey(), rename(entry, new String[][]{{"a","kind"},{"b","modified"},{"c","sequence"},{"d","device"},{"e","deleted"},{"f","value"}}));
        }
        result.add("records", records);
        return result;
    }
    static boolean string(JsonObject root, String key) {
        return root.has(key) && root.get(key).isJsonPrimitive() && root.get(key).getAsJsonPrimitive().isString();
    }
    static boolean number(JsonObject root, String key) {
        return root.has(key) && root.get(key).isJsonPrimitive() && root.get(key).getAsJsonPrimitive().isNumber();
    }
    static JsonObject rename(JsonObject root, String[][] fields) {
        JsonObject result = root.deepCopy();
        for (String[] field : fields) {
            if (result.has(field[1])) throw new IllegalArgumentException("旧版同步字段冲突");
            if (result.has(field[0])) result.add(field[1], result.remove(field[0]));
        }
        return result;
    }

    public void validate() {
        if (schema != VERSION) throw new IllegalArgumentException("同步格式版本不兼容，请更新应用");
        if (reset == null || epoch == null || epoch.isEmpty() || records == null || records.size() > 30000 ||
                !("merge".equals(mode) || "replace".equals(mode) || "reset".equals(mode)))
            throw new IllegalArgumentException("同步文件无效");
        if ("reset".equals(mode) && !records.isEmpty()) throw new IllegalArgumentException("重置标记无效");
        for (Map.Entry<String, Entry> row : records.entrySet()) {
            Entry e = row.getValue();
            if (row.getKey() == null || !row.getKey().matches("[a-f0-9]{64}") || e == null ||
                    e.kind == null || e.device == null || e.device.isEmpty() || e.modified < 0 ||
                    e.modified > System.currentTimeMillis() + 24 * 60 * 60 * 1000L || (!e.deleted && e.value == null))
                throw new IllegalArgumentException("同步记录无效或设备时间相差过大");
        }
    }

    public SyncDocument copy() {
        SyncDocument result = new SyncDocument();
        result.epoch = epoch;
        result.mode = mode;
        result.reset = reset;
        result.schema = schema;
        records.forEach((key, e) -> result.records.put(key, e.copy()));
        return result;
    }

    public static SyncDocument merge(SyncDocument local, SyncDocument remote) {
        if (!local.epoch.equals(remote.epoch)) throw new IllegalArgumentException("同步代次不同");
        SyncDocument result = remote.copy();
        local.records.forEach((key, e) -> {
            Entry old = result.records.get(key);
            if (old == null || compare(e, old) > 0) result.records.put(key, e.copy());
        });
        return result;
    }

    private static int compare(Entry a, Entry b) {
        int time = Long.compare(a.modified, b.modified);
        if (time != 0) return time;
        int device = a.device.compareTo(b.device);
        if (device != 0) return device;
        int sequence = Long.compare(a.sequence, b.sequence);
        if (sequence != 0) return sequence;
        if (a.deleted != b.deleted) return a.deleted ? 1 : -1;
        // 即使出现损坏或重复版本，也采用确定性规则裁决。
        return ordered(a.value).toString().compareTo(ordered(b.value).toString());
    }
    // 对象键按 UTF-16 排序，避免 Android / iOS 编码器的字段顺序改变最终裁决。
    private static JsonElement ordered(JsonElement value) {
        if (value == null) return JsonNull.INSTANCE;
        if (value.isJsonObject()) {
            JsonObject result = new JsonObject();
            new java.util.TreeSet<>(value.getAsJsonObject().keySet()).forEach(key -> result.add(key, ordered(value.getAsJsonObject().get(key))));
            return result;
        }
        if (value.isJsonArray()) {
            JsonArray result = new JsonArray();
            value.getAsJsonArray().forEach(item -> result.add(ordered(item)));
            return result;
        }
        return value;
    }

}

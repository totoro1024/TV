package com.fongmi.android.tv.sync;

import com.google.gson.Gson;
import com.google.gson.JsonObject;

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
            JsonObject root = new Gson().fromJson(json, JsonObject.class);
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
        return String.valueOf(a.value).compareTo(String.valueOf(b.value));
    }
}

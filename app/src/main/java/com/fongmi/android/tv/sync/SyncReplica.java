package com.fongmi.android.tv.sync;

import com.google.gson.JsonObject;

import java.util.Map;
import java.util.TreeMap;

/** 分开保存本机观测值与云端记录，避免把下载结果误判为本机编辑。 */
public final class SyncReplica {
    public SyncDocument document = new SyncDocument();
    public Map<String, JsonObject> observed = new TreeMap<>();
    public String acknowledgedEpoch = "";
    public boolean paused;
    public String acceptedReset = "";

    public boolean needsResetConsent(SyncDocument remote) {
        return remote != null && !remote.reset.isEmpty() && !remote.reset.equals(acceptedReset);
    }
    public long clock;

    public void observe(Map<String, JsonObject> current, Map<String, String> kinds, String device, long now) {
        for (Map.Entry<String, JsonObject> row : current.entrySet()) {
            String key = row.getKey();
            JsonObject previous = observed.get(key);
            if (row.getValue().equals(previous)) continue;
            SyncDocument.Entry entry = new SyncDocument.Entry();
            entry.kind = kinds.get(key);
            entry.modified = next(now);
            entry.sequence = clock;
            // 使用实际观看时间，避免延迟扫描改变观看顺序。
            if ("history".equals(entry.kind) && row.getValue().has("watchedAt")) {
                entry.modified = Math.min(now, row.getValue().get("watchedAt").getAsLong());
            }
            entry.device = device;
            SyncDocument.Entry old = document.records.get(key);
            entry.value = old != null && old.value != null ? old.value.deepCopy() : new JsonObject();
            row.getValue().entrySet().forEach(field -> entry.value.add(field.getKey(), field.getValue().deepCopy()));
            document.records.put(key, entry);
        }
        for (String key : observed.keySet()) {
            if (current.containsKey(key)) continue;
            SyncDocument.Entry old = document.records.get(key);
            if (old == null) continue;
            SyncDocument.Entry deleted = old.copy();
            deleted.deleted = true;
            deleted.value = null;
            deleted.modified = next(now);
            deleted.sequence = clock;
            deleted.device = device;
            document.records.put(key, deleted);
        }
        setObserved(current);
    }

    public void setObserved(Map<String, JsonObject> current) {
        observed = new TreeMap<>();
        current.forEach((k, v) -> observed.put(k, v.deepCopy()));
    }

    public long next(long now) {
        clock = Math.max(clock + 1, now);
        return clock;
    }

    public void receive(SyncDocument value) {
        document = value.copy();
        for (SyncDocument.Entry e : value.records.values()) clock = Math.max(clock, e.modified);
        acknowledgedEpoch = value.epoch;
    }
}

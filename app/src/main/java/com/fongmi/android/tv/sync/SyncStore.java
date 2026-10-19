package com.fongmi.android.tv.sync;

import android.content.SharedPreferences;

import com.fongmi.android.tv.App;
import com.fongmi.android.tv.bean.Config;
import com.fongmi.android.tv.bean.History;
import com.fongmi.android.tv.bean.Keep;
import com.fongmi.android.tv.bean.Site;
import com.fongmi.android.tv.db.AppDatabase;
import com.github.catvod.utils.Prefers;
import com.google.gson.JsonObject;

import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;

/** 显式列出跨平台字段，数据库编号、配置缓存及设备设置留在本机。 */
public final class SyncStore {
    public static final Set<String> KINDS = Set.of("source", "history", "favorite", "site", "preference");
    public static final class Values {
        public final Map<String, JsonObject> values = new TreeMap<>();
        public final Map<String, String> kinds = new TreeMap<>();
        void put(String kind, JsonObject value, String... identity) {
            String key = SyncDocument.identity(identity);
            values.put(key, value);
            kinds.put(key, kind);
        }
    }

    public Values capture() {
        Values result = new Values();
        AppDatabase db = AppDatabase.get();
        db.runInTransaction(() -> {
            Map<Integer, String> sources = new HashMap<>();
            for (Config c : db.getConfigDao().findAll()) {
                if (c.getType() > 1 || c.isEmpty()) continue;
                String id = sourceId(c.getUrl(), c.getType());
                sources.put(c.getId(), id);
                JsonObject v = new JsonObject();
                v.addProperty("url", c.getUrl()); v.addProperty("type", c.getType());
                v.addProperty("name", text(c.getName())); v.addProperty("home", text(c.getHome()));
                result.put("source", v, "source", String.valueOf(c.getType()), c.getUrl());
            }
            for (History h : db.getHistoryDao().findAll()) {
                String source = sources.get(h.getCid());
                String[] key = h.getKey().split(AppDatabase.SYMBOL, -1);
                if (source == null || key.length != 3) continue;
                JsonObject v = new JsonObject();
                v.addProperty("source", source); v.addProperty("site", key[0]); v.addProperty("vod", key[1]);
                v.addProperty("name", text(h.getVodName())); v.addProperty("picture", text(h.getVodPic()));
                v.addProperty("line", text(h.getVodFlag())); v.addProperty("episode", h.getVodRemarks());
                v.addProperty("episodeUrl", h.getEpisodeUrl()); v.addProperty("watchedAt", h.getCreateTime());
                v.addProperty("positionMs", h.getPosition()); v.addProperty("durationMs", h.getDuration());
                v.addProperty("openingMs", h.getOpening()); v.addProperty("endingMs", h.getEnding());
                v.addProperty("reverseSort", h.isRevSort()); v.addProperty("reversePlay", h.isRevPlay());
                result.put("history", v, "history", source, key[0], key[1]);
            }
            for (Keep k : db.getKeepDao().findAll()) {
                JsonObject v = new JsonObject();
                v.addProperty("type", k.getType()); v.addProperty("name", text(k.getVodName()));
                v.addProperty("picture", text(k.getVodPic())); v.addProperty("siteName", text(k.getSiteName()));
                v.addProperty("addedAt", k.getCreateTime());
                if (k.getType() == 0) {
                    String source = sources.get(k.getCid());
                    String[] key = k.getKey().split(AppDatabase.SYMBOL, -1);
                    if (source == null || key.length != 3) continue;
                    v.addProperty("source", source); v.addProperty("site", key[0]); v.addProperty("vod", key[1]);
                    result.put("favorite", v, "favorite", "vod", source, key[0], key[1]);
                } else {
                    v.addProperty("channel", k.getKey());
                    result.put("favorite", v, "favorite", "live", k.getKey());
                }
            }
            // 上游按站点 key 全局保存搜索偏好，没有按 Config.id 分区。
            for (Site site : db.getSiteDao().findAll()) {
                if (!App.gson().toJsonTree(site).getAsJsonObject().has("searchable")) continue;
                JsonObject v = new JsonObject();
                v.addProperty("site", site.getKey()); v.addProperty("searchable", site.getSearchable());
                result.put("site", v, "site", site.getKey());
            }
        });
        for (int type = 0; type <= 1; type++) {
            String url = Prefers.getString("config_" + type);
            if (url.isEmpty()) continue;
            JsonObject v = new JsonObject();
            v.addProperty("name", "activeSource" + type); v.addProperty("type", type);
            v.addProperty("url", url);
            result.put("preference", v, "preference", "activeSource" + type);
        }
        return result;
    }

    public static String sourceId(String url, int type) {
        return SyncDocument.identity("source", String.valueOf(type), url);
    }

    private static String text(String value) { return value == null ? "" : value; }
    private static String str(JsonObject v, String key) { return v.get(key).getAsString(); }

    /** 开始事务或修改偏好前，先校验全部已知记录。 */
    public void validate(SyncDocument doc) {
        doc.validate();
        try {
            for (Map.Entry<String, SyncDocument.Entry> row : doc.records.entrySet()) {
                SyncDocument.Entry e = row.getValue();
                if (e.deleted || !KINDS.contains(e.kind)) continue;
                JsonObject v = e.value;
                String expected;
                switch (e.kind) {
                    case "source": {
                        int type = v.get("type").getAsInt();
                        if (type < 0 || type > 1 || str(v, "url").isEmpty()) throw new IllegalArgumentException();
                        str(v, "name"); str(v, "home");
                        expected = sourceId(str(v, "url"), type);
                        break;
                    }
                    case "history": {
                        requireSource(doc, str(v, "source"));
                        for (String key : new String[]{"name", "picture", "line", "episode", "episodeUrl", "site", "vod"}) str(v, key);
                        for (String key : new String[]{"watchedAt", "positionMs", "durationMs", "openingMs", "endingMs"}) v.get(key).getAsLong();
                        v.get("reverseSort").getAsBoolean(); v.get("reversePlay").getAsBoolean();
                        expected = SyncDocument.identity("history", str(v, "source"), str(v, "site"), str(v, "vod"));
                        break;
                    }
                    case "favorite": {
                        int type = v.get("type").getAsInt();
                        if (type != 0 && type != 1) throw new IllegalArgumentException();
                        str(v, "name"); str(v, "picture"); str(v, "siteName"); v.get("addedAt").getAsLong();
                        if (type == 0) {
                            requireSource(doc, str(v, "source"));
                            expected = SyncDocument.identity("favorite", "vod", str(v, "source"), str(v, "site"), str(v, "vod"));
                        } else expected = SyncDocument.identity("favorite", "live", str(v, "channel"));
                        break;
                    }
                    case "site": {
                        int search = v.get("searchable").getAsInt();
                        if (search < 0 || search > 2) throw new IllegalArgumentException();
                        expected = SyncDocument.identity("site", str(v, "site"));
                        break;
                    }
                    default: {
                        int type = v.get("type").getAsInt();
                        if (type < 0 || type > 1 || !str(v, "name").equals("activeSource" + type)) throw new IllegalArgumentException();
                        str(v, "url");
                        expected = SyncDocument.identity("preference", str(v, "name"));
                    }
                }
                if (!row.getKey().equals(expected)) throw new IllegalArgumentException();
            }
        } catch (RuntimeException e) { throw new IllegalArgumentException("同步记录字段或标识无效，未修改本地数据"); }
    }

    private static void requireSource(SyncDocument d, String id) {
        SyncDocument.Entry source = d.records.get(id);
        if (source == null || !"source".equals(source.kind)) throw new IllegalArgumentException();
        // 源已删除时，应用数据会同时抑制其下的记录。
    }

    public void apply(SyncDocument document) {
        validate(document);
        AppDatabase db = AppDatabase.get();
        db.runInTransaction(() -> {
            Map<String, Integer> ids = new HashMap<>();
            for (Map.Entry<String, SyncDocument.Entry> row : document.records.entrySet()) {
                SyncDocument.Entry e = row.getValue();
                if (e.deleted || !"source".equals(e.kind)) continue;
                JsonObject v = e.value;
                Config c = db.getConfigDao().find(str(v, "url"), v.get("type").getAsInt());
                if (c == null) {
                    c = new Config(); c.setUrl(str(v, "url")); c.setType(v.get("type").getAsInt());
                    c.setId(Math.toIntExact(db.getConfigDao().insert(c)));
                }
                c.setName(str(v, "name")); c.setHome(str(v, "home"));
                db.getConfigDao().insertOrUpdate(c);
                ids.put(row.getKey(), c.getId());
            }
            // 只删除同步范围内的记录，保留设备、轨迹与壁纸数据。
            for (History h : db.getHistoryDao().findAll()) {
                Config c = db.getConfigDao().findById(h.getCid());
                if (c == null || c.getType() > 1) continue;
                String[] k = h.getKey().split(AppDatabase.SYMBOL, -1);
                if (k.length != 3) continue;
                String id = SyncDocument.identity("history", sourceId(c.getUrl(), c.getType()), k[0], k[1]);
                if (!active(document, id) || !ids.containsValue(c.getId())) db.getHistoryDao().delete(h.getCid(), h.getKey());
            }
            for (Keep k : db.getKeepDao().findAll()) {
                String id;
                if (k.getType() == 1) id = SyncDocument.identity("favorite", "live", k.getKey());
                else {
                    Config c = db.getConfigDao().findById(k.getCid());
                    if (c == null || c.getType() > 1) continue;
                    String[] key = k.getKey().split(AppDatabase.SYMBOL, -1);
                    if (key.length != 3) continue;
                    id = SyncDocument.identity("favorite", "vod", sourceId(c.getUrl(), c.getType()), key[0], key[1]);
                }
                if (!active(document, id) || k.getType() == 0 && !ids.containsValue(k.getCid())) {
                    if (k.getType() == 1) db.getKeepDao().delete(k.getKey());
                    else db.getKeepDao().delete(k.getCid(), k.getKey());
                }
            }
            for (SyncDocument.Entry e : document.records.values()) {
                if (e.deleted) continue;
                JsonObject v = e.value;
                if ("history".equals(e.kind) && ids.containsKey(str(v, "source"))) {
                    int cid = ids.get(str(v, "source"));
                    String key = str(v, "site") + AppDatabase.SYMBOL + str(v, "vod") + AppDatabase.SYMBOL + cid;
                    History h = db.getHistoryDao().find(cid, key);
                    if (h == null) h = new History();
                    h.setKey(key); h.setCid(cid); h.setVodName(str(v, "name")); h.setVodPic(str(v, "picture"));
                    h.setVodFlag(str(v, "line")); h.setVodRemarks(str(v, "episode")); h.setEpisodeUrl(str(v, "episodeUrl"));
                    h.setCreateTime(v.get("watchedAt").getAsLong()); h.setPosition(v.get("positionMs").getAsLong());
                    h.setDuration(v.get("durationMs").getAsLong()); h.setOpening(v.get("openingMs").getAsLong());
                    h.setEnding(v.get("endingMs").getAsLong()); h.setRevSort(v.get("reverseSort").getAsBoolean());
                    h.setRevPlay(v.get("reversePlay").getAsBoolean());
                    db.getHistoryDao().insertOrUpdate(h);
                } else if ("favorite".equals(e.kind)) {
                    int type = v.get("type").getAsInt();
                    if (type == 0 && !ids.containsKey(str(v, "source"))) continue;
                    Keep k = new Keep(); k.setType(type); k.setVodName(str(v, "name")); k.setVodPic(str(v, "picture"));
                    k.setSiteName(str(v, "siteName")); k.setCreateTime(v.get("addedAt").getAsLong());
                    if (type == 0) {
                        int cid = ids.get(str(v, "source")); k.setCid(cid);
                        k.setKey(str(v, "site") + AppDatabase.SYMBOL + str(v, "vod") + AppDatabase.SYMBOL + cid);
                    } else k.setKey(str(v, "channel"));
                    db.getKeepDao().insertOrUpdate(k);
                } else if ("site".equals(e.kind)) {
                    Site site = new Site(); site.setKey(str(v, "site"));
                    // 保留独立的本机换源偏好。
                    for (Site existing : db.getSiteDao().findAll()) if (existing.getKey().equals(site.getKey())) site = existing;
                    site.setSearchable(v.get("searchable").getAsInt()); db.getSiteDao().insertOrUpdate(site);
                }
            }
            for (Config c : db.getConfigDao().findAll()) {
                if (c.getType() <= 1 && !c.isEmpty() && !active(document, sourceId(c.getUrl(), c.getType())))
                    db.getConfigDao().delete(c.getUrl(), c.getType());
            }
            for (Site site : db.getSiteDao().findAll()) {
                if (!active(document, SyncDocument.identity("site", site.getKey()))) {
                    // 缺少偏好时，下次载入源使用上游默认值。
                    db.getOpenHelper().getWritableDatabase().execSQL("UPDATE Site SET searchable = NULL WHERE `key` = ?", new Object[]{site.getKey()});
                }
            }
        });
        SharedPreferences.Editor editor = Prefers.getPrefers().edit();
        for (int type = 0; type <= 1; type++) {
            String id = SyncDocument.identity("preference", "activeSource" + type);
            if (!active(document, id)) { editor.remove("config_" + type); continue; }
            String url = str(document.records.get(id).value, "url");
            Config c = db.getConfigDao().find(url, type);
            if (c == null) { editor.remove("config_" + type); continue; }
            if (!url.equals(Prefers.getString("config_" + type))) {
                c.setTime(System.currentTimeMillis()); db.getConfigDao().insertOrUpdate(c);
            }
            editor.putString("config_" + type, url);
        }
        if (!editor.commit()) throw new IllegalStateException("设置保存失败，请重试同步");
    }

    private static boolean active(SyncDocument d, String id) {
        SyncDocument.Entry entry = d.records.get(id);
        return entry != null && !entry.deleted;
    }
}

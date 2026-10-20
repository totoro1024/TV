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
    public static final Set<String> KINDS = Set.of("source", "history", EpisodeProgress.KIND, "favorite", "site", "preference", CloudConfig.KIND);
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
                JsonObject v = EpisodeProgressStore.value(h, source);
                result.put("history", v, "history", source, key[0], key[1]);
            }
            for (com.fongmi.android.tv.bean.EpisodeProgressRecord row : db.getEpisodeProgressDao().findAll()) {
                JsonObject value = com.google.gson.JsonParser.parseString(row.value).getAsJsonObject();
                if (!result.values.containsKey(EpisodeProgress.historyId(value))) continue;
                result.values.put(row.key, value); result.kinds.put(row.key, EpisodeProgress.KIND);
            }
            // 升级前唯一保留的那一集也参与同步，不覆盖已经存在的分集记录。
            for (History h : db.getHistoryDao().findAll()) {
                String source = sources.get(h.getCid());
                if (source == null || !h.canSave()) continue;
                JsonObject value = EpisodeProgressStore.value(h, source);
                String id = EpisodeProgress.id(value);
                if (!result.values.containsKey(id)) { result.values.put(id, value); result.kinds.put(id, EpisodeProgress.KIND); }
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
        JsonObject cloud = new CloudConfigStore().capture();
        if (cloud != null) result.put(CloudConfig.KIND, cloud, CloudConfig.KIND, CloudConfig.ADAPTER);
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
                    case CloudConfig.KIND: {
                        CloudConfig.validate(v);
                        expected = CloudConfig.ID;
                        break;
                    }
                    case "source": {
                        int type = v.get("type").getAsInt();
                        if (type < 0 || type > 1 || str(v, "url").isEmpty()) throw new IllegalArgumentException();
                        str(v, "name"); str(v, "home");
                        expected = sourceId(str(v, "url"), type);
                        break;
                    }
                    case "history":
                    case EpisodeProgress.KIND: {
                        requireSource(doc, str(v, "source"));
                        for (String key : new String[]{"name", "picture", "line", "episode", "episodeUrl", "site", "vod"}) str(v, key);
                        for (String key : new String[]{"watchedAt", "positionMs", "durationMs", "openingMs", "endingMs"}) v.get(key).getAsLong();
                        v.get("reverseSort").getAsBoolean(); v.get("reversePlay").getAsBoolean();
                        expected = EpisodeProgress.KIND.equals(e.kind) ? EpisodeProgress.id(v) : SyncDocument.identity("history", str(v, "source"), str(v, "site"), str(v, "vod"));
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

    /** 播放期间仅应用收藏；已有源、观看进度、插件及偏好不改动。 */
    public void applyFavoritesDuringPlayback(SyncDocument document) {
        validate(document);
        AppDatabase db = AppDatabase.get();
        db.runInTransaction(() -> {
            Map<String, Integer> ids = new HashMap<>();
            for (SyncDocument.Entry e : document.records.values()) {
                if (e.deleted || !"favorite".equals(e.kind) || e.value.get("type").getAsInt() != 0) continue;
                String id = str(e.value, "source");
                SyncDocument.Entry source = document.records.get(id);
                if (source.deleted || ids.containsKey(id)) continue;
                JsonObject v = source.value;
                Config c = db.getConfigDao().find(str(v, "url"), v.get("type").getAsInt());
                if (c == null) {
                    // 为跨源收藏补充必要的源记录，不切换当前使用的源。
                    c = new Config(); c.setUrl(str(v, "url")); c.setType(v.get("type").getAsInt());
                    c.setName(str(v, "name")); c.setHome(str(v, "home"));
                    c.setId(Math.toIntExact(db.getConfigDao().insert(c)));
                }
                ids.put(id, c.getId());
            }
            removeFavorites(document, ids, db);
            for (SyncDocument.Entry e : document.records.values()) {
                if (!e.deleted && "favorite".equals(e.kind)) writeFavorite(e.value, ids, db);
            }
        });
    }

    private void removeFavorites(SyncDocument document, Map<String, Integer> ids, AppDatabase db) {
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
    }

    private void writeFavorite(JsonObject v, Map<String, Integer> ids, AppDatabase db) {
        int type = v.get("type").getAsInt();
        if (type == 0 && !ids.containsKey(str(v, "source"))) return;
        Keep k = new Keep(); k.setType(type); k.setVodName(str(v, "name")); k.setVodPic(str(v, "picture"));
        k.setSiteName(str(v, "siteName")); k.setCreateTime(v.get("addedAt").getAsLong());
        if (type == 0) {
            int cid = ids.get(str(v, "source")); k.setCid(cid);
            k.setKey(str(v, "site") + AppDatabase.SYMBOL + str(v, "vod") + AppDatabase.SYMBOL + cid);
        } else k.setKey(str(v, "channel"));
        db.getKeepDao().insertOrUpdate(k);
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
            removeFavorites(document, ids, db);
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
                    writeFavorite(e.value, ids, db);
                } else if ("site".equals(e.kind)) {
                    Site site = new Site(); site.setKey(str(v, "site"));
                    // 保留独立的本机换源偏好。
                    for (Site existing : db.getSiteDao().findAll()) if (existing.getKey().equals(site.getKey())) site = existing;
                    site.setSearchable(v.get("searchable").getAsInt()); db.getSiteDao().insertOrUpdate(site);
                }
            }
            for (com.fongmi.android.tv.bean.EpisodeProgressRecord row : db.getEpisodeProgressDao().findAll()) {
                if (!active(document, row.key)) db.getEpisodeProgressDao().delete(row.key);
            }
            for (Map.Entry<String, SyncDocument.Entry> row : document.records.entrySet()) {
                SyncDocument.Entry entry = row.getValue();
                if (entry.deleted || !EpisodeProgress.KIND.equals(entry.kind)) continue;
                JsonObject value = entry.value;
                Integer cid = ids.get(str(value, "source"));
                if (cid == null || !active(document, EpisodeProgress.historyId(value))) continue;
                String parent = str(value, "site") + AppDatabase.SYMBOL + str(value, "vod") + AppDatabase.SYMBOL + cid;
                com.fongmi.android.tv.bean.EpisodeProgressRecord progress = new com.fongmi.android.tv.bean.EpisodeProgressRecord();
                progress.key = row.getKey(); progress.historyKey = parent; progress.value = value.toString();
                db.getEpisodeProgressDao().insertOrUpdate(progress);
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
        new CloudConfigStore().apply(document);
    }

    private static boolean active(SyncDocument d, String id) {
        SyncDocument.Entry entry = d.records.get(id);
        return entry != null && !entry.deleted;
    }
}

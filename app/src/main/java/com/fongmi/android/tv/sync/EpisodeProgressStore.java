package com.fongmi.android.tv.sync;

import com.fongmi.android.tv.bean.Config;
import com.fongmi.android.tv.bean.History;
import com.fongmi.android.tv.bean.EpisodeProgressRecord;
import com.fongmi.android.tv.db.AppDatabase;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;

/** 分集进度独立于首页 History 行，外键随节目历史删除。 */
public final class EpisodeProgressStore {
    private static String text(String v) { return v == null ? "" : v; }
    public static JsonObject value(History h, String source) {
        JsonObject v = new JsonObject();
        v.addProperty("source", source); v.addProperty("site", h.getSiteKey()); v.addProperty("vod", h.getVodId());
        v.addProperty("name", text(h.getVodName())); v.addProperty("picture", text(h.getVodPic()));
        v.addProperty("line", text(h.getVodFlag())); v.addProperty("episode", h.getVodRemarks());
        v.addProperty("episodeUrl", h.getEpisodeUrl()); v.addProperty("watchedAt", h.getCreateTime());
        v.addProperty("positionMs", h.getPosition()); v.addProperty("durationMs", h.getDuration());
        v.addProperty("openingMs", h.getOpening()); v.addProperty("endingMs", h.getEnding());
        v.addProperty("reverseSort", h.isRevSort()); v.addProperty("reversePlay", h.isRevPlay());
        return v;
    }
    private static String source(History h) {
        Config c = AppDatabase.get().getConfigDao().findById(h.getCid());
        return c == null || c.getType() > 1 || c.isEmpty() ? null : SyncStore.sourceId(c.getUrl(), c.getType());
    }
    public static void save(History h) {
        if (!h.canSave()) return;
        String source = source(h);
        if (source == null) return;
        JsonObject v = value(h, source);
        EpisodeProgressRecord row = new EpisodeProgressRecord();
        row.key = EpisodeProgress.id(v); row.historyKey = h.getKey(); row.value = v.toString();
        AppDatabase.get().getEpisodeProgressDao().insertOrUpdate(row);
    }
    public static boolean restore(History h) {
        String source = source(h);
        if (source == null) return false;
        EpisodeProgressRecord row = AppDatabase.get().getEpisodeProgressDao().find(EpisodeProgress.id(value(h, source)));
        if (row == null) return false;
        JsonObject v = JsonParser.parseString(row.value).getAsJsonObject();
        h.setPosition(v.get("positionMs").getAsLong()); h.setDuration(v.get("durationMs").getAsLong());
        return true;
    }
}

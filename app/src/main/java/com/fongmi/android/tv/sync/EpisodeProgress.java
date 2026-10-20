package com.fongmi.android.tv.sync;

import com.google.gson.JsonObject;
import com.google.gson.JsonParser;

/** 与 iPhone 共用，不使用会过期的签名或分享令牌作为剧集身份。 */
public final class EpisodeProgress {
    public static final String KIND = "episodeProgress";
    public static String key(String line, String episode, String url) {
        try {
            JsonObject file = JsonParser.parseString(url).getAsJsonObject();
            String share = file.get("sId").getAsString(), fid = file.get("fid").getAsString();
            if (!share.isEmpty() && !fid.isEmpty()) return SyncDocument.identity("quark", share, fid);
        } catch (RuntimeException ignored) { }
        return SyncDocument.identity("episode", line, episode.isEmpty() ? url : episode);
    }
    public static String key(JsonObject value) { return key(value.get("line").getAsString(), value.get("episode").getAsString(), value.get("episodeUrl").getAsString()); }
    public static String id(JsonObject v) { return SyncDocument.identity(KIND, v.get("source").getAsString(), v.get("site").getAsString(), v.get("vod").getAsString(), key(v)); }
    public static String historyId(JsonObject v) { return SyncDocument.identity("history", v.get("source").getAsString(), v.get("site").getAsString(), v.get("vod").getAsString()); }
}

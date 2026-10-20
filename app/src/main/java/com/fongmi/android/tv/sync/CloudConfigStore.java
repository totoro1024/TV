package com.fongmi.android.tv.sync;

import android.content.SharedPreferences;
import android.util.AtomicFile;
import com.fongmi.android.tv.App;
import com.github.catvod.utils.Prefers;
import com.google.gson.JsonObject;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.file.Files;
import java.util.Base64;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;

/** 只访问适配器白名单中的插件配置，不扫描或搬运整个私有目录。 */
public final class CloudConfigStore {
    public static void saveLogin(String key, String cookie) throws IOException {
        if (!Set.of("quark_ck", "uc_ck").contains(key)) throw new IOException("不支持的网盘");
        String encoded = PluginCookieCodec.encode(cookie);
        if (!App.get().getSharedPreferences("spUtils", 0).edit().putString(key, encoded).commit())
            throw new IOException("网盘登录保存失败");
        if (!Prefers.getPrefers().edit().remove(key).commit())
            throw new IOException("网盘登录保存失败，请重试");
    }
    private SharedPreferences prefs() { return App.get().getSharedPreferences("spUtils", 0); }
    private File file(String name) throws IOException {
        if (!CloudConfig.FILES.contains(name)) throw new IOException("不支持的网盘配置文件");
        File root = App.get().getFilesDir().getCanonicalFile();
        File file = new File(root, name);
        if (!file.getCanonicalFile().equals(file)) throw new IOException("网盘配置路径无效");
        return file;
    }
    private Map<String, String> collect(SharedPreferences prefs, Set<String> keys) {
        Map<String, String> result = new HashMap<>();
        Map<String, ?> all = prefs.getAll();
        for (String key : keys) if (all.get(key) instanceof String text) result.put(key, text);
        return result;
    }
    JsonObject capture() {
        try {
            Map<String, byte[]> files = new HashMap<>();
            for (String name : CloudConfig.FILES) {
                File f = file(name);
                if (!f.exists()) continue;
                if (!f.isFile() || f.length() > CloudConfig.MAX_FILE) throw new IOException("网盘配置文件过大或无效");
                files.put(name, Files.readAllBytes(f.toPath()));
            }
            return CloudConfig.pack(collect(prefs(), CloudConfig.PREFS), collect(Prefers.getPrefers(), CloudConfig.DEFAULT_PREFS), files);
        } catch (IOException e) { throw new IllegalStateException("无法读取网盘配置，已停止本次同步"); }
    }
    void apply(SyncDocument document) {
        SyncDocument.Entry entry = document.records.get(CloudConfig.ID);
        // 兼容尚不支持网盘配置的旧快照，缺失记录不能注销本机账号。
        if (entry == null) return;
        JsonObject value = entry.deleted ? null : entry.value;
        if (value != null) {
            CloudConfig.validate(value);
            if (CloudConfig.isBootstrap(value)) return;
        }
        try {
            for (String name : CloudConfig.FILES) {
                AtomicFile target = new AtomicFile(file(name));
                if (value == null || !value.getAsJsonObject("files").has(name)) { target.delete(); continue; }
                byte[] bytes = Base64.getDecoder().decode(value.getAsJsonObject("files").get(name).getAsString());
                FileOutputStream out = null;
                try { out = target.startWrite(); out.write(bytes); target.finishWrite(out); }
                catch (IOException e) { if (out != null) target.failWrite(out); throw e; }
            }
            write(prefs(), CloudConfig.PREFS, value == null ? null : value.getAsJsonObject("prefs"));
            write(Prefers.getPrefers(), CloudConfig.DEFAULT_PREFS, value == null ? null : value.getAsJsonObject("defaults"));
        } catch (IOException e) { throw new IllegalStateException("网盘配置写入失败，请使用本地副本恢复后重试"); }
    }
    private void write(SharedPreferences prefs, Set<String> keys, JsonObject values) throws IOException {
        SharedPreferences.Editor editor = prefs.edit();
        for (String key : keys) {
            if (values != null && values.has(key)) editor.putString(key, values.get(key).getAsString());
            // 注销时保留插件设备派生材料，只移除登录状态。
            else if (values != null || !key.startsWith("hide_appgz_")) editor.remove(key);
        }
        if (!editor.commit()) throw new IOException("网盘配置保存失败");
    }
}

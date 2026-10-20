package com.fongmi.android.tv.sync;

import android.app.Activity;
import android.content.SharedPreferences;
import android.util.AtomicFile;
import android.os.FileObserver;

import androidx.annotation.NonNull;
import androidx.room.InvalidationTracker;

import com.fongmi.android.tv.App;
import com.fongmi.android.tv.api.config.LiveConfig;
import com.fongmi.android.tv.api.config.VodConfig;
import com.fongmi.android.tv.bean.Config;
import com.fongmi.android.tv.db.AppDatabase;
import com.fongmi.android.tv.event.RefreshEvent;
import com.fongmi.android.tv.impl.Callback;
import com.github.catvod.utils.Prefers;
import com.google.gson.Gson;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.Arrays;
import java.util.Date;
import java.util.Locale;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.ScheduledThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.function.Consumer;

/** 用单一串行线程管理同步状态与网络操作，避免在界面及数据库线程联网。 */
public final class WebDavSync {
    public enum Operation { SYNC, PUSH, PULL, MERGE, CLEAR, REBUILD, ACCEPT_RESET, RESTORE }
    private static final WebDavSync INSTANCE = new WebDavSync();
    private final ScheduledThreadPoolExecutor worker = new ScheduledThreadPoolExecutor(1);
    private final Gson gson = new Gson();
    private final SyncStore store = new SyncStore();
    private volatile SyncReplica replica;
    private volatile boolean deferredApply;
    private String scope;
    private WebDavClient cachedClient;
    private String clientIdentity;
    private long lastAttempt;
    private ScheduledFuture<?> pending;
    private volatile boolean applying;
    private volatile boolean busy;
    private volatile int playbackActivities;
    private volatile boolean reloadPending;
    private volatile String status = "尚未同步";
    private SharedPreferences.OnSharedPreferenceChangeListener preferenceListener;
    private FileObserver cloudFilesObserver;

    public static WebDavSync get() { return INSTANCE; }
    public SharedPreferences preferences() { return App.get().getSharedPreferences("webdav", 0); }
    public String status() { return status; }
    public String deliveryStatus() {
        SyncReplica value = replica;
        return value == null ? "正在读取本地同步状态…" : value.deliveryText(busy, configured(), preferences().getBoolean("auto", false), deferredApply);
    }
    private String lastSuccessKey() {
        return "lastSuccess." + SyncDocument.identity(preferences().getString("url", ""), preferences().getString("user", ""));
    }
    public String lastSuccessText() {
        long timestamp = preferences().getLong(lastSuccessKey(), 0);
        return timestamp > 0 ? new SimpleDateFormat("yyyy/MM/dd HH:mm:ss", Locale.SIMPLIFIED_CHINESE).format(new Date(timestamp)) : "尚未成功同步";
    }
    public boolean busy() { return busy; }
    public boolean configured() { return !preferences().getString("url", "").trim().isEmpty(); }
    public boolean paused() { return preferences().getBoolean("paused", false); }

    public void init() {
        if (!com.fongmi.android.tv.BuildConfig.FLAVOR.equals("leanback")) return;
        preferenceListener = (prefs, key) -> {
            if (!applying && ("config_0".equals(key) || "config_1".equals(key) || CloudConfig.PREFS.contains(key == null ? "" : key) || CloudConfig.DEFAULT_PREFS.contains(key == null ? "" : key))) changed(false);
        };
        Prefers.getPrefers().registerOnSharedPreferenceChangeListener(preferenceListener);
        App.get().getSharedPreferences("spUtils", 0).registerOnSharedPreferenceChangeListener(preferenceListener);
        cloudFilesObserver = new FileObserver(App.get().getFilesDir().getAbsolutePath(), FileObserver.CLOSE_WRITE | FileObserver.MOVED_TO | FileObserver.DELETE) {
            @Override public void onEvent(int event, String path) {
                if (!applying && path != null && CloudConfig.FILES.contains(path)) changed(false);
            }
        };
        cloudFilesObserver.startWatching();
        worker.execute(() -> {
            try {
                load();
                AppDatabase.get().getInvalidationTracker().addObserver(new InvalidationTracker.Observer("History", "EpisodeProgressRecord", "Keep", "Config", "Site") {
                    @Override public void onInvalidated(@NonNull Set<String> tables) {
                        if (!applying) changed(tables.stream().allMatch(table -> table.equals("History") || table.equals("EpisodeProgressRecord")));
                    }
                });
                capture();
                autoSync();
            } catch (Exception e) { failed(e); }
        });
        worker.scheduleWithFixedDelay(() -> {
            try { if (configured()) { load(); capture(); autoSync(); } }
            catch (Exception e) { failed(e); }
        }, 60, 60, TimeUnit.SECONDS);
    }

    public void activityCreated(Activity activity) {
        if (isPlayback(activity)) playbackActivities++;
    }
    public void activityDestroyed(Activity activity) {
        if (isPlayback(activity)) { playbackActivities = Math.max(0, playbackActivities - 1); requestAuto(); }
    }
    public void activityResumed(Activity activity) {
        if (!isPlayback(activity)) { reloadIfSafe(); requestAuto(); }
    }
    private boolean isPlayback(Activity activity) {
        return "VideoActivity".equals(activity.getClass().getSimpleName()) || "LiveActivity".equals(activity.getClass().getSimpleName());
    }

    public void changed(boolean historyOnly) {
        if (!configured()) return;
        synchronized (this) {
            if (pending != null) pending.cancel(false);
            pending = worker.schedule(() -> {
                try {
                    load(); capture();
                    if (!historyOnly || System.currentTimeMillis() - lastAttempt >= 60000) autoSync();
                } catch (Exception e) { failed(e); }
            }, 800, TimeUnit.MILLISECONDS);
        }
    }

    /** 播放界面创建前拉取最新进度，避免播放器先读取旧的本地续播位置。 */
    public void beforePlayback(Runnable open) {
        if (!configured() || !preferences().getBoolean("auto", false)) { App.post(open); return; }
        worker.execute(() -> {
            try { load(); applyDeferredIfSafe(); capture(); autoSync(); }
            catch (Exception e) { failed(e); }
            finally { App.post(open); }
        });
    }

    public void requestAuto() {
        if (!configured()) return;
        worker.schedule(() -> {
            try { load(); applyDeferredIfSafe(); capture(); autoSync(); }
            catch (Exception e) { failed(e); }
        }, 1000, TimeUnit.MILLISECONDS);
    }

    private void autoSync() throws Exception {
        if (!configured() || !preferences().getBoolean("auto", false) || replica.paused) return;
        busy = true;
        try { execute(Operation.SYNC); } finally { busy = false; }
    }

    public void saveSettings(String url, String user, String password, boolean auto, Consumer<String> result) {
        saveSettings(url, "", user, password, auto, result);
    }

    public void saveSettings(String serverUrl, String userDirectory, String user, String password, boolean auto, Consumer<String> result) {
        worker.execute(() -> {
            try {
                String url = WebDavClient.directoryAddress(serverUrl, userDirectory);
                new WebDavClient(url, user, password); // 保存前先校验地址。
                if (!preferences().edit().putString("url", url.trim()).putString("user", user)
                        .putString("password", password).putString("serverUrl", serverUrl.trim())
                        .putString("userDirectory", userDirectory.trim()).putBoolean("auto", auto).commit())
                    throw new IOException("配置保存失败");
                load(); capture();
                status = replica.paused ? "同步已暂停，请选择重置后的处理方式" : "配置已保存";
                deliver(result, status);
            } catch (Exception e) { failed(e); deliver(result, status); }
        });
    }

    public void test(Consumer<String> result) {
        worker.execute(() -> {
            busy = true;
            try { client().test(); status = "连接测试成功（读写与并发保护正常）"; }
            catch (Exception e) { failed(e); }
            finally { busy = false; deliver(result, status); }
        });
    }

    /** 用户完成网盘登录后主动同步一次，不受日常自动同步开关或 60 秒节流影响。 */
    public void afterCloudLogin() {
        if (!configured()) {
            com.fongmi.android.tv.utils.Notify.show("登录已保存；尚未配置 WebDAV，请到设置中配置同步。");
            return;
        }
        if (paused()) {
            com.fongmi.android.tv.utils.Notify.show("登录已保存；WebDAV 已暂停，请先在同步设置中处理。");
            return;
        }
        com.fongmi.android.tv.utils.Notify.show("登录已保存，正在同步网盘配置…");
        run(Operation.SYNC, message -> com.fongmi.android.tv.utils.Notify.show("网盘登录同步：" + message));
    }

    public void run(Operation operation, Consumer<String> result) {
        worker.execute(() -> {
            busy = true;
            try { load(); capture(); execute(operation); }
            catch (Exception e) { failed(e); }
            finally { busy = false; deliver(result, status); }
        });
    }

    private WebDavClient client() throws IOException {
        String url = preferences().getString("url", ""), user = preferences().getString("user", ""), password = preferences().getString("password", "");
        String identity = SyncDocument.identity(url, user, password);
        if (cachedClient == null || !identity.equals(clientIdentity)) {
            cachedClient = new WebDavClient(url, user, password); clientIdentity = identity;
        }
        return cachedClient;
    }

    private void execute(Operation operation) throws Exception {
        lastAttempt = System.currentTimeMillis();
        if (operation == Operation.RESTORE) { restore(); return; }
        new SyncEngine(client(), new SyncEngine.Local() {
            @Override public SyncReplica replica() { return replica; }
            @Override public boolean isPlaying() { return playbackActivities > 0; }
            @Override public void validate(SyncDocument doc) { store.validate(doc); }
            @Override public void capture() throws IOException { WebDavSync.this.capture(); }
            @Override public SyncDocument snapshot() { return WebDavSync.this.snapshot(); }
            @Override public void backup() throws IOException { WebDavSync.this.backup(); }
            @Override public void install(SyncDocument doc) throws IOException { WebDavSync.this.install(doc); }
            @Override public void save() throws IOException { WebDavSync.this.save(); }
            @Override public void pause(String message) throws IOException { WebDavSync.this.pause(message); }
            @Override public void success(String message) {
                if (operation != Operation.ACCEPT_RESET)
                    preferences().edit().putLong(lastSuccessKey(), System.currentTimeMillis()).apply();
                WebDavSync.this.success(message);
            }
            @Override public void applyMerged(SyncDocument doc, boolean replacing) throws IOException {
                installMerged(doc, replacing);
            }
        }).run(SyncEngine.Operation.valueOf(operation.name()));
    }

    private SyncDocument snapshot() {
        SyncStore.Values values = store.capture();
        SyncReplica temp = new SyncReplica();
        temp.clock = replica.clock;
        temp.observe(values.values, values.kinds, device(), System.currentTimeMillis());
        replica.clock = temp.clock;
        return temp.document;
    }

    private void install(SyncDocument value) throws IOException {
        installMerged(value, true);
    }

    private void installMerged(SyncDocument value, boolean replacing) throws IOException {
        applying = true;
        try {
            String before = sourceFingerprint();
            AppDatabase.get().runInTransaction(() -> {
                SyncDocument finalValue = value;
                if (!replacing) {
                    SyncStore.Values current = store.capture();
                    replica.observe(current.values, current.kinds, device(), System.currentTimeMillis());
                    SyncDocument latest = replica.document.copy(); latest.epoch = value.epoch;
                    finalValue = SyncDocument.merge(latest, value);
                }
                if (playbackActivities > 0 && !replacing) {
                    // 收藏立即生效，其他云端记录留待安全时机应用。
                    store.validate(finalValue);
                    try { write(pendingFile(scope), gson.toJson(finalValue)); }
                    catch (IOException e) { throw new IllegalStateException(e); }
                    deferredApply = true;
                    store.applyFavoritesDuringPlayback(finalValue);
                    replica.receive(finalValue);
                    replica.setObserved(store.capture().values);
                    return;
                }
                store.validate(finalValue);
                SyncDocument.Entry cloud = finalValue.records.get(CloudConfig.ID);
                if (cloud != null && !java.util.Objects.equals(new CloudConfigStore().capture(), cloud.deleted ? null : cloud.value)) {
                    try { backup(); }
                    catch (IOException e) { throw new IllegalStateException("网盘配置备份失败，已停止应用同步", e); }
                }
                try { write(pendingFile(scope), gson.toJson(finalValue)); }
                catch (IOException e) { throw new IllegalStateException(e); }
                store.apply(finalValue);
                deferredApply = false;
                replica.receive(finalValue);
                replica.setObserved(store.capture().values);
            });
            save();
            if (!deferredApply) new AtomicFile(pendingFile(scope)).delete();
            reloadPending |= !before.equals(sourceFingerprint());
            App.post(() -> { RefreshEvent.history(); RefreshEvent.keep(); reloadIfSafe(); });
        } catch (Exception e) {
            // 下次尝试重新载入持久化状态及待应用日志。
            scope = null;
            if (e instanceof IOException io) throw io;
            throw new IOException("应用同步数据失败，已保留恢复状态，请重试", e);
        } finally { applying = false; }
    }

    private String sourceFingerprint() {
        StringBuilder text = new StringBuilder();
        for (Config c : AppDatabase.get().getConfigDao().findAll()) if (c.getType() <= 1)
            text.append(c.getType()).append(c.getUrl()).append(c.getHome());
        return text.append(Prefers.getString("config_0")).append(Prefers.getString("config_1"))
                .append(gson.toJson(AppDatabase.get().getSiteDao().findAll()))
                .append(SyncDocument.identity(gson.toJson(new CloudConfigStore().capture()))).toString();
    }

    private void reloadIfSafe() {
        if (!reloadPending || playbackActivities > 0 || App.activity() == null) return;
        reloadPending = false;
        Config vod = AppDatabase.get().getConfigDao().find(Prefers.getString("config_0"), 0);
        Config live = AppDatabase.get().getConfigDao().find(Prefers.getString("config_1"), 1);
        VodConfig.load(vod == null ? Config.create(0) : vod, new Callback());
        LiveConfig.load(live == null ? Config.create(1) : live, new Callback());
    }

    private void capture() throws IOException {
        SyncStore.Values values = store.capture();
        replica.observe(values.values, values.kinds, device(), System.currentTimeMillis());
        save();
    }

    private void load() throws IOException {
        String target = SyncDocument.identity(preferences().getString("url", ""), preferences().getString("user", ""));
        if (target.equals(scope)) return;
        File f = stateFile(target);
        SyncReplica value = new SyncReplica();
        if (f.exists() || new File(f.getPath() + ".bak").exists()) {
            try {
                value = SyncReplica.parse(new String(new AtomicFile(f).readFully(), StandardCharsets.UTF_8));
                if (value == null || value.document == null || value.observed == null || value.acknowledgedEpoch == null)
                    throw new IllegalStateException();
                value.document.validate();
            } catch (Exception e) { throw new IOException("本地同步状态损坏，已停止同步以保护数据"); }
        }
        // 升级旧版本的错误观测，不把“配套文件仍存在”生成账号删除标记。
        CloudConfig.migrate(value);
        replica = value; scope = target;
        deferredApply = pendingFile(target).exists() || new File(pendingFile(target).getPath() + ".bak").exists();
        applyDeferredIfSafe();
        preferences().edit().putBoolean("paused", replica.paused).apply();
        status = replica.paused ? "同步已暂停，请选择重置后的处理方式" : preferences().getString("status", "尚未同步");
    }

    private void applyDeferredIfSafe() throws IOException {
        if (!deferredApply || playbackActivities > 0) return;
        SyncDocument staged = SyncDocument.parse(new String(new AtomicFile(pendingFile(scope)).readFully(), StandardCharsets.UTF_8));
        // 强退前已落库但尚未捕获的播放进度也必须参与合并。
        capture();
        boolean replacing = "replace".equals(staged.mode) && !staged.epoch.equals(replica.acknowledgedEpoch);
        installMerged(staged, replacing);
    }

    private String device() {
        String id = preferences().getString("device", "");
        if (!id.isEmpty()) return id;
        id = UUID.randomUUID().toString();
        preferences().edit().putString("device", id).commit();
        return id;
    }

    private File directory() {
        File dir = new File(App.get().getFilesDir(), "webdav-sync");
        if (!dir.exists() && !dir.mkdirs()) throw new IllegalStateException("无法创建本地同步目录");
        return dir;
    }
    private File stateFile(String key) { return new File(directory(), key + ".json"); }
    private File pendingFile(String key) { return new File(directory(), key + ".pending"); }
    private void save() throws IOException {
        write(stateFile(scope), gson.toJson(replica));
        preferences().edit().putBoolean("paused", replica.paused).apply();
    }
    private void write(File file, String data) throws IOException {
        AtomicFile atomic = new AtomicFile(file);
        FileOutputStream out = null;
        try { out = atomic.startWrite(); out.write(data.getBytes(StandardCharsets.UTF_8)); atomic.finishWrite(out); }
        catch (IOException e) { if (out != null) atomic.failWrite(out); throw e; }
    }
    private void backup() throws IOException {
        File dir = new File(directory(), "recovery");
        if (!dir.exists() && !dir.mkdirs()) throw new IOException("无法保存恢复副本，操作已取消");
        write(new File(dir, System.currentTimeMillis() + "-" + UUID.randomUUID() + ".json"), gson.toJson(snapshot()));
        File[] files = dir.listFiles((d, name) -> name.endsWith(".json"));
        if (files == null) return;
        Arrays.sort(files, (a, b) -> Long.compare(b.lastModified(), a.lastModified()));
        for (int i = 5; i < files.length; i++) files[i].delete();
    }
    private void restore() throws Exception {
        if (playbackActivities > 0) throw new IOException("请先退出播放再恢复");
        File[] files = new File(directory(), "recovery").listFiles((d, name) -> name.endsWith(".json"));
        if (files == null || files.length == 0) throw new IOException("没有可恢复的副本");
        Arrays.sort(files, (a, b) -> Long.compare(b.lastModified(), a.lastModified()));
        SyncDocument value = SyncDocument.parse(new String(new AtomicFile(files[0]).readFully(), StandardCharsets.UTF_8));
        backup(); install(value); pause("已恢复最近的本地副本，同步已暂停；可选择用本机重建云端");
    }
    private void pause(String message) throws IOException { replica.paused = true; save(); status = message; persistStatus(); }
    private void success(String message) {
        String time = new SimpleDateFormat("MM-dd HH:mm:ss", Locale.SIMPLIFIED_CHINESE).format(new Date());
        boolean needsFiles = AppDatabase.get().getConfigDao().findAll().stream().anyMatch(c -> c.getType() <= 1 &&
                !c.isEmpty() && !(c.getUrl().startsWith("http://") || c.getUrl().startsWith("https://")));
        status = message + " · " + time + (needsFiles ? " · 存在本地源，请在目标设备补充文件" : "");
        preferences().edit().putLong("lastSuccess", System.currentTimeMillis()).apply();
        persistStatus();
    }
    private void failed(Exception e) {
        if (replica != null) {
            replica.retryNeeded = true;
            if (scope != null) try { save(); } catch (IOException ignored) { }
        }
        // 状态及日志中不包含异常 URL、服务器正文、源内容或登录凭据。
        Throwable root = e;
        while (root.getCause() != null) root = root.getCause();
        String text = root.getMessage();
        status = root instanceof IOException || root instanceof IllegalArgumentException
                ? (text != null && text.matches("[\\p{IsHan}].*") ? text : "连接失败，请检查网络、地址及服务状态")
                : "同步失败，已保留本地数据，请重试";
        persistStatus();
    }
    private void persistStatus() { preferences().edit().putString("status", status).apply(); }
    private void deliver(Consumer<String> result, String message) { if (result != null) App.post(() -> result.accept(message)); }
}

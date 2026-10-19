package com.fongmi.android.tv.sync;

import com.google.gson.Gson;

import java.io.IOException;
import java.util.UUID;
import java.util.concurrent.TimeUnit;

import okhttp3.Credentials;
import okhttp3.HttpUrl;
import okhttp3.MediaType;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;

/** 使用独立网络客户端，隔离源拦截器，避免凭据进入日志或重定向。 */
public final class WebDavClient {
    public static final int MAX_BYTES = 8 * 1024 * 1024;
    private static final MediaType JSON = MediaType.get("application/json; charset=utf-8");
    private static final OkHttpClient HTTP = new OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS).readTimeout(30, TimeUnit.SECONDS)
            .callTimeout(45, TimeUnit.SECONDS).followRedirects(false).followSslRedirects(false).build();
    private final HttpUrl folder;
    private final String authorization;

    public static final class Snapshot {
        public final SyncDocument document;
        public final String etag;
        Snapshot(SyncDocument document, String etag) { this.document = document; this.etag = etag; }
    }

    public static final class Conflict extends IOException {
        Conflict() { super("云端已被其他设备修改，正在重新合并"); }
    }

    public WebDavClient(String address, String user, String password) throws IOException {
        HttpUrl base = HttpUrl.parse(address.trim());
        if (base == null || !base.username().isEmpty() || !base.password().isEmpty()
                || base.query() != null || base.fragment() != null)
            throw new IOException("请填写不含账号、查询参数的 HTTP 或 HTTPS 目录地址");
        folder = base.newBuilder().addPathSegment("fongmi-sync-v1").addPathSegment("").build();
        authorization = Credentials.basic(user, password, java.nio.charset.StandardCharsets.UTF_8);
    }

    private Request.Builder request(String name) {
        return new Request.Builder().url(folder.newBuilder().addPathSegment(name).build())
                .header("Authorization", authorization).header("Cache-Control", "no-cache");
    }

    public void ensureFolder() throws IOException {
        Request req = new Request.Builder().url(folder).header("Authorization", authorization)
                .method("MKCOL", RequestBody.create(new byte[0], null)).build();
        try (Response r = HTTP.newCall(req).execute()) {
            if (!(r.isSuccessful() || r.code() == 405)) fail(r.code());
        }
    }

    public Snapshot read() throws IOException {
        try (Response r = HTTP.newCall(request("state.json").get().build()).execute()) {
            if (r.code() == 404) return new Snapshot(null, null);
            if (!r.isSuccessful()) fail(r.code());
            if (r.body() == null || r.body().contentLength() > MAX_BYTES) throw new IOException("同步文件过大或为空");
            okio.Buffer buffer = new okio.Buffer();
            long read;
            while (buffer.size() <= MAX_BYTES && (read = r.body().source().read(buffer, Math.min(8192, MAX_BYTES + 1L - buffer.size()))) != -1) { }
            byte[] bytes = buffer.readByteArray();
            if (bytes.length > MAX_BYTES) throw new IOException("同步文件超过 8 MB");
            try {
                return new Snapshot(SyncDocument.parse(new String(bytes, java.nio.charset.StandardCharsets.UTF_8)), r.header("ETag"));
            } catch (RuntimeException e) { throw new IOException(e.getMessage()); }
        }
    }

    public void write(SyncDocument document, Snapshot before) throws IOException {
        document.validate();
        String json = new Gson().toJson(document);
        if (json.getBytes(java.nio.charset.StandardCharsets.UTF_8).length > MAX_BYTES) throw new IOException("同步数据超过 8 MB");
        Request.Builder req = request("state.json");
        if (before.document == null) req.header("If-None-Match", "*");
        else {
            if (before.etag == null || before.etag.startsWith("W/"))
                throw new IOException("服务器未提供强 ETag，无法安全处理多设备写入");
            req.header("If-Match", before.etag);
        }
        try (Response r = HTTP.newCall(req.put(RequestBody.create(json, JSON)).build()).execute()) {
            if (r.code() == 412) throw new Conflict();
            if (!r.isSuccessful()) fail(r.code());
        }
    }

    /** 通过临时文件验证实际读写及条件写入，不修改 state.json。 */
    public void test() throws IOException {
        ensureFolder();
        String name = "probe-" + UUID.randomUUID() + ".json";
        try {
            try (Response r = HTTP.newCall(request(name).header("If-None-Match", "*")
                    .put(RequestBody.create("{}", JSON)).build()).execute()) {
                if (!r.isSuccessful()) fail(r.code());
            }
            try (Response r = HTTP.newCall(request(name).get().build()).execute()) {
                if (!r.isSuccessful()) fail(r.code());
                String tag = r.header("ETag");
                if (tag == null || tag.startsWith("W/")) throw new IOException("服务器需要支持强 ETag");
            }
            try (Response r = HTTP.newCall(request(name).header("If-Match", "\"invalid-probe-version\"")
                    .put(RequestBody.create("{}", JSON)).build()).execute()) {
                if (r.code() != 412) throw new IOException("服务器不支持条件写入，无法保证多设备同步安全");
            }
        } finally {
            try (Response ignored = HTTP.newCall(request(name).delete().build()).execute()) { }
        }
    }

    private static void fail(int code) throws IOException {
        if (code == 401 || code == 403) throw new IOException("认证失败或目录没有访问权限（" + code + "）");
        if (code >= 300 && code < 400) throw new IOException("服务器返回重定向，请填写最终目录地址");
        throw new IOException("WebDAV 请求失败（" + code + "）");
    }
}

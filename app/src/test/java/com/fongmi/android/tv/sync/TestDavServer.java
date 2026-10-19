package com.fongmi.android.tv.sync;

import fi.iki.elonen.NanoHTTPD;
import java.io.ByteArrayInputStream;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Map;
import java.util.HashMap;
import java.util.concurrent.ConcurrentHashMap;

/** 使用应用已依赖的服务器实现，兼容 Android 单元测试编译环境。 */
final class TestDavServer extends NanoHTTPD {
    final Map<String, byte[]> files = new ConcurrentHashMap<>();
    private final Map<String, String> tags = new ConcurrentHashMap<>();
    volatile boolean ignoreConditions;
    private int revision;
    TestDavServer() { super("127.0.0.1", 0); }
    String address() { return "http://127.0.0.1:" + getListeningPort() + "/"; }
    void put(String path, byte[] data) { files.put(path, data); tags.put(path, "\"fixture\""); }
    void clear() { files.clear(); tags.clear(); }
    @Override public synchronized Response serve(IHTTPSession session) {
        String path = session.getUri(); byte[] body = new byte[0];
        Response.Status status = Response.Status.OK;
        try {
            switch (session.getMethod()) {
                case MKCOL: status = Response.Status.CREATED; break;
                case GET:
                    if (!files.containsKey(path)) status = Response.Status.NOT_FOUND;
                    else body = files.get(path);
                    break;
                case PUT:
                    Map<String, String> uploaded = new HashMap<>(); session.parseBody(uploaded);
                    String match = session.getHeaders().get("if-match"), none = session.getHeaders().get("if-none-match");
                    if (!ignoreConditions && (match != null && !match.equals(tags.get(path)) || "*".equals(none) && files.containsKey(path)))
                        status = Response.Status.PRECONDITION_FAILED;
                    else {
                        String content = uploaded.get("content");
                        files.put(path, content == null || content.isEmpty() ? new byte[0] : Files.readAllBytes(Paths.get(content)));
                        tags.put(path, "\"" + ++revision + "\""); status = Response.Status.CREATED;
                    }
                    break;
                case DELETE: files.remove(path); tags.remove(path); status = Response.Status.NO_CONTENT; break;
                default: status = Response.Status.METHOD_NOT_ALLOWED;
            }
        } catch (Exception e) { status = Response.Status.INTERNAL_ERROR; }
        Response response = newFixedLengthResponse(status, "application/json", new ByteArrayInputStream(body), body.length);
        if (tags.containsKey(path)) response.addHeader("ETag", tags.get(path));
        return response;
    }
}

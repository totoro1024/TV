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
    volatile boolean ignoreConditions, failWrites, weakFirstRead, alwaysWeak;
    private final java.util.Set<String> unreadWrites = java.util.concurrent.ConcurrentHashMap.newKeySet();
    final java.util.Set<String> directories = new java.util.HashSet<>(java.util.Collections.singleton("/"));
    int notModified, writes;
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
                case MKCOL:
                    String dir = path.endsWith("/") ? path : path + "/";
                    String parent = dir.substring(0, dir.length() - 1);
                    parent = parent.substring(0, parent.lastIndexOf('/') + 1);
                    if (directories.contains(dir)) status = Response.Status.METHOD_NOT_ALLOWED;
                    else if (!directories.contains(parent)) status = Response.Status.CONFLICT;
                    else { directories.add(dir); status = Response.Status.CREATED; }
                    break;
                case GET:
                    if (!files.containsKey(path)) status = Response.Status.NOT_FOUND;
                    else if (tags.get(path).equals(session.getHeaders().get("if-none-match"))) { status = Response.Status.NOT_MODIFIED; notModified++; }
                    else body = files.get(path);
                    break;
                case PUT:
                    Map<String, String> uploaded = new HashMap<>(); session.parseBody(uploaded);
                    if (failWrites) return newFixedLengthResponse(Response.Status.INTERNAL_ERROR, "text/plain", "测试上传失败");
                    String match = session.getHeaders().get("if-match"), none = session.getHeaders().get("if-none-match");
                    if (!ignoreConditions && (match != null && !match.equals(tags.get(path)) || "*".equals(none) && files.containsKey(path)))
                        status = Response.Status.PRECONDITION_FAILED;
                    else {
                        String content = uploaded.get("content");
                        files.put(path, content == null || content.isEmpty() ? new byte[0] : Files.readAllBytes(Paths.get(content)));
                        tags.put(path, "\"" + ++revision + "\""); unreadWrites.add(path); writes++; status = Response.Status.CREATED;
                    }
                    break;
                case DELETE: files.remove(path); tags.remove(path); status = Response.Status.NO_CONTENT; break;
                default: status = Response.Status.METHOD_NOT_ALLOWED;
            }
        } catch (Exception e) { status = Response.Status.INTERNAL_ERROR; }
        Response response = newFixedLengthResponse(status, "application/json", new ByteArrayInputStream(body), body.length);
        if (tags.containsKey(path)) {
            boolean transientWeak = weakFirstRead && session.getMethod() == Method.GET && unreadWrites.remove(path);
            response.addHeader("ETag", (alwaysWeak || transientWeak ? "W/" : "") + tags.get(path));
        }
        return response;
    }
}

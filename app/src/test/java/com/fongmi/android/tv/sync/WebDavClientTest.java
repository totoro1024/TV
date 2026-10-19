package com.fongmi.android.tv.sync;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import static org.junit.Assert.*;

/** 使用隔离的内存 DAV 服务执行真实 HTTP 测试，不连接用户的服务器。 */
public class WebDavClientTest {
    private HttpServer server;
    private final Map<String, byte[]> files = new HashMap<>();
    private final Map<String, String> tags = new HashMap<>();
    private boolean ignoreConditions;
    private int revision;
    private WebDavClient client;
    @Before public void start() throws Exception {
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/", this::handle); server.start();
        client = new WebDavClient("http://127.0.0.1:" + server.getAddress().getPort() + "/", "test", "test-only");
    }
    @After public void stop() { server.stop(0); }
    private synchronized void handle(HttpExchange x) throws java.io.IOException {
        String path = x.getRequestURI().getPath(); String method = x.getRequestMethod(); int code = 200; byte[] body = new byte[0];
        switch (method) {
            case "MKCOL": code = 201; break;
            case "GET":
                if (!files.containsKey(path)) code = 404;
                else { body = files.get(path); x.getResponseHeaders().set("ETag", tags.get(path)); }
                break;
            case "PUT":
                String match = x.getRequestHeaders().getFirst("If-Match"), none = x.getRequestHeaders().getFirst("If-None-Match");
                if (!ignoreConditions && (match != null && !match.equals(tags.get(path)) || "*".equals(none) && files.containsKey(path))) code = 412;
                else { files.put(path, x.getRequestBody().readAllBytes()); tags.put(path, "\"" + ++revision + "\""); code = 201; }
                break;
            case "DELETE": files.remove(path); tags.remove(path); code = 204; break;
            default: code = 405;
        }
        x.sendResponseHeaders(code, body.length == 0 ? -1 : body.length);
        if (body.length > 0) x.getResponseBody().write(body); x.close();
    }
    @Test public void connectionProbeLeavesNoFiles() throws Exception { client.test(); assertTrue(files.isEmpty()); }
    @Test public void roundTripAndStaleWriterProtection() throws Exception {
        client.ensureFolder(); WebDavClient.Snapshot absent = client.read(); assertNull(absent.document);
        SyncDocument first = new SyncDocument(); client.write(first, absent);
        WebDavClient.Snapshot a = client.read(), b = client.read();
        assertEquals(first.epoch, a.document.epoch);
        a.document.mode = "replace"; client.write(a.document, a);
        try { client.write(b.document, b); fail("stale writer must fail"); } catch (WebDavClient.Conflict expected) { }
        try { client.write(first, absent); fail("create must not overwrite"); } catch (WebDavClient.Conflict expected) { }
    }
    @Test public void brokenConditionalServerIsRejected() throws Exception {
        ignoreConditions = true;
        try { client.test(); fail("unsafe server must fail"); } catch (java.io.IOException expected) { assertTrue(expected.getMessage().contains("条件写入")); }
        assertTrue(files.isEmpty());
    }
    @Test public void corruptRemoteDoesNotBecomeAnEmptyDocument() throws Exception {
        files.put("/fongmi-sync-v1/state.json", "{}".getBytes(StandardCharsets.UTF_8)); tags.put("/fongmi-sync-v1/state.json", "\"1\"");
        try { client.read(); fail("invalid data must fail"); } catch (java.io.IOException expected) { assertTrue(expected.getMessage().contains("格式无效")); }
    }
    @Test public void oversizeRemoteIsRejected() throws Exception {
        files.put("/fongmi-sync-v1/state.json", new byte[WebDavClient.MAX_BYTES + 1]); tags.put("/fongmi-sync-v1/state.json", "\"1\"");
        try { client.read(); fail("oversize data must fail"); } catch (java.io.IOException expected) { assertTrue(expected.getMessage().contains("过大")); }
    }
}

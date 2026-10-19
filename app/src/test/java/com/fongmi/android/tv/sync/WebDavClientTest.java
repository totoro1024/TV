package com.fongmi.android.tv.sync;

import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import static org.junit.Assert.*;

/** 使用隔离的内存 DAV 服务执行真实 HTTP 测试，不连接用户的服务器。 */
public class WebDavClientTest {
    private TestDavServer server;
    private Map<String, byte[]> files;
    private WebDavClient client;
    @Before public void start() throws Exception {
        server = new TestDavServer(); server.start(); files = server.files;
        client = new WebDavClient(server.address(), "test", "test-only");
    }
    @After public void stop() { server.stop(); }

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
        server.ignoreConditions = true;
        try { client.test(); fail("unsafe server must fail"); } catch (java.io.IOException expected) { assertTrue(expected.getMessage().contains("条件写入")); }
        assertTrue(files.isEmpty());
    }
    @Test public void corruptRemoteDoesNotBecomeAnEmptyDocument() throws Exception {
        server.put("/fongmi-sync-v1/state.json", "{}".getBytes(StandardCharsets.UTF_8));
        try { client.read(); fail("invalid data must fail"); } catch (java.io.IOException expected) { assertTrue(expected.getMessage().contains("格式无效")); }
    }
    @Test public void oversizeRemoteIsRejected() throws Exception {
        server.put("/fongmi-sync-v1/state.json", new byte[WebDavClient.MAX_BYTES + 1]);
        try { client.read(); fail("oversize data must fail"); } catch (java.io.IOException expected) { assertTrue(expected.getMessage().contains("过大") || expected.getMessage().contains("超过")); }
    }
}

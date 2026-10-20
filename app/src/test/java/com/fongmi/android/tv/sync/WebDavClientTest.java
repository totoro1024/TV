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

    @Test public void userDirectoryIsOptionalAndValidated() throws Exception {
        assertEquals(server.address(), WebDavClient.directoryAddress(server.address(), ""));
        assertEquals(server.address() + "family/long/", WebDavClient.directoryAddress(server.address(), "family/long"));
        for (String bad : new String[]{"../bob", "%2e%2e", "https://other.test", "a?b", "a\\b"}) {
            try { WebDavClient.directoryAddress(server.address(), bad); fail("应拒绝无效目录"); }
            catch (java.io.IOException expected) { }
        }
    }
    @Test public void separateUsersAndMissingParents() throws Exception {
        WebDavClient alice = new WebDavClient(server.address() + "dav/alice/", "test", "test-only");
        WebDavClient bob = new WebDavClient(server.address() + "dav/bob/", "test", "test-only");
        alice.ensureFolder(); bob.ensureFolder(); alice.ensureFolder();
        alice.write(new SyncDocument(), alice.read());
        assertNotNull(alice.read().document);
        assertNull(bob.read().document);
        assertTrue(server.directories.contains("/dav/alice/fongmi-sync-v1/"));
        assertTrue(server.directories.contains("/dav/bob/fongmi-sync-v1/"));
    }
    @Test public void apacheTransientWeakEtagProbeIsRetried() throws Exception {
        server.weakFirstRead = true;
        client.test();
        assertTrue(files.isEmpty());
    }
    @Test public void apacheTransientWeakEtagReadBecomesSafeForConditionalWrite() throws Exception {
        server.weakFirstRead = true;
        client.ensureFolder(); client.write(new SyncDocument(), client.read());
        WebDavClient.Snapshot value = client.read();
        assertFalse(value.etag.startsWith("W/"));
        assertEquals(0, server.notModified);
        value.document.mode = "replace";
        client.write(value.document, value);
        WebDavClient other = new WebDavClient(server.address(), "test", "test-only");
        assertEquals("replace", other.read().document.mode);
        try { client.write(value.document, value); fail("旧版本必须仍被拒绝"); }
        catch (WebDavClient.Conflict expected) { }
    }
    @Test public void permanentlyWeakEtagStillCannotOverwriteData() throws Exception {
        client.ensureFolder(); client.write(new SyncDocument(), client.read());
        server.alwaysWeak = true;
        WebDavClient.Snapshot before = client.read();
        assertTrue(before.etag.startsWith("W/"));
        try { client.write(before.document, before); fail("不能将弱 ETag 当作强 ETag 写入"); }
        catch (java.io.IOException expected) { assertTrue(expected.getMessage().contains("强 ETag")); }
        assertEquals(1, server.writes);
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

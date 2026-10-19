package com.fongmi.android.tv.server;

import com.fongmi.android.tv.server.process.WebDavInput;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import java.util.HashMap;
import java.util.concurrent.atomic.AtomicReference;
import fi.iki.elonen.NanoHTTPD;
import okhttp3.FormBody;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import static org.junit.Assert.*;

/** 使用内存回调与本机 HTTP，验证扫码不会直接写入真实同步设置。 */
public class WebDavInputTest {
    private NanoHTTPD server;
    private String address, token;
    private final OkHttpClient client = new OkHttpClient();
    private final AtomicReference<String> received = new AtomicReference<>();
    @Before public void start() throws Exception {
        server = new NanoHTTPD("127.0.0.1", 0) {
            @Override public Response serve(IHTTPSession session) {
                return WebDavInput.get().doResponse(session, session.getUri(), new HashMap<>());
            }
        };
        server.start();
        address = "http://127.0.0.1:" + server.getListeningPort() + WebDavInput.PATH;
        token = WebDavInput.get().begin(WebDavInput.Field.URL, received::set);
    }
    @After public void stop() { WebDavInput.get().end(token); server.stop(); }
    private okhttp3.Response submit(String target, String url) throws Exception {
        return client.newCall(new Request.Builder().url(address + target).post(new FormBody.Builder()
                .add("text", url).build()).build()).execute();
    }
    @Test public void formIsEmptyAndNeverReturnsCredentials() throws Exception {
        try (Response response = client.newCall(new Request.Builder().url(address + token).build()).execute()) {
            assertEquals(200, response.code());
            assertEquals("no-store", response.header("Cache-Control"));
            String html = response.body().string();
            assertTrue(html.contains("name=\"text\""));
            assertFalse(html.contains("test-only"));
        }
        assertNull(received.get());
    }
    @Test public void submissionIsOneTimeAndPreservesUnicodeAndSymbols() throws Exception {
        try (Response response = submit(token, "http://example.invalid/dav/")) { assertEquals(200, response.code()); }
        assertEquals("http://example.invalid/dav/", received.get());
        try (Response response = submit(token, "http://example.invalid/again/")) { assertEquals(403, response.code()); }
        assertEquals("http://example.invalid/dav/", received.get());
    }
    @Test public void closedAndReplacedWindowsAreRejected() throws Exception {
        String old = token;
        token = WebDavInput.get().begin(WebDavInput.Field.URL, received::set);
        WebDavInput.get().end(old); // 旧弹窗关闭不能使新弹窗失效。
        try (Response response = submit(old, "http://example.invalid/")) { assertEquals(403, response.code()); }
        try (Response response = submit(token, "http://example.invalid/")) { assertEquals(200, response.code()); }
        received.set(null);
        token = WebDavInput.get().begin(WebDavInput.Field.URL, received::set);
        WebDavInput.get().end(token);
        try (Response response = submit(token, "http://example.invalid/")) { assertEquals(403, response.code()); }
        assertNull(received.get());
    }
    @Test public void invalidAddressDoesNotConsumeTheSession() throws Exception {
        try (Response response = submit(token, "file:///tmp/test")) { assertEquals(400, response.code()); }
        assertNull(received.get());
        try (Response response = submit(token, "http://example.invalid/")) { assertEquals(200, response.code()); }
    }
    @Test public void passwordFieldPreservesSymbolsWithoutRequiringAnAddress() throws Exception {
        token = WebDavInput.get().begin(WebDavInput.Field.PASSWORD, received::set);
        try (Response response = submit(token, "test-only-&+密码")) { assertEquals(200, response.code()); }
        assertEquals("test-only-&+密码", received.get());
    }
    @Test public void oversizeInputIsRejected() throws Exception {
        try (Response response = submit(token, "http://example.invalid/" + "a".repeat(17000))) { assertEquals(400, response.code()); }
        assertNull(received.get());
    }
}

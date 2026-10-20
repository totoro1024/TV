package com.fongmi.android.tv.sync;
import org.junit.Test;
import static org.junit.Assert.*;
public class PluginCookieCodecTest {
    @Test public void matchesCurrentPluginAndIOSDecoderFixture() {
        assertEquals("sbaP0PpKcE8T7fZQxofRvvenqSve282z0z4hadT2FRZR", PluginCookieCodec.encode("__pus=synthetic; __puus=test-only"));
    }
    @Test public void refusesEmptyAndInjectedCredentials() {
        for (String cookie : new String[]{"__pus=", "not__pus=test", "__pus=x\r\nHost:evil"}) {
            assertFalse(PluginCookieCodec.valid(cookie));
            try { PluginCookieCodec.encode(cookie); fail(); } catch (IllegalArgumentException expected) { }
        }
    }
}

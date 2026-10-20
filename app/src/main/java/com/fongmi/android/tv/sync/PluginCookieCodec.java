package com.fongmi.android.tv.sync;

import java.nio.charset.StandardCharsets;
import java.util.Base64;

/** 与当前网盘插件的配置字符串编码相同，仅用于兼容，不作为保密加密。 */
public final class PluginCookieCodec {
    private static final byte[] STREAM = Base64.getDecoder().decode("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");
    private PluginCookieCodec() {}
    public static boolean valid(String cookie) {
        if (cookie == null || cookie.length() > 256 * 1024 || cookie.contains("\r") || cookie.contains("\n")) return false;
        for (String entry : cookie.split(";")) {
            String pair = entry.trim();
            if (pair.startsWith("__pus=") && pair.length() > 6) return true;
        }
        return false;
    }
    public static String encode(String cookie) {
        if (!valid(cookie)) throw new IllegalArgumentException("登录 Cookie 无效");
        StringBuilder shifted = new StringBuilder();
        cookie.codePoints().forEach(c -> shifted.appendCodePoint(c + 2));
        byte[] bytes = shifted.toString().getBytes(StandardCharsets.UTF_8);
        if (bytes.length > STREAM.length) throw new IllegalArgumentException("登录 Cookie 超过插件支持长度");
        for (int i = 0; i < bytes.length; i++) bytes[i] = (byte) (bytes[i] ^ STREAM[i] ^ 99);
        return Base64.getEncoder().encodeToString(bytes);
    }
}

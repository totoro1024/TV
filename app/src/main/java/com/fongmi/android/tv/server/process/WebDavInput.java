package com.fongmi.android.tv.server.process;

import com.fongmi.android.tv.server.impl.Process;

import java.util.HashMap;
import java.util.Map;
import java.util.UUID;
import java.util.function.Consumer;

import fi.iki.elonen.NanoHTTPD;
import fi.iki.elonen.NanoHTTPD.IHTTPSession;
import fi.iki.elonen.NanoHTTPD.Response;

/** 局域网一次性输入窗口；不读取已保存的账号密码，不直接保存同步配置。 */
public final class WebDavInput implements Process {
    public static final String PATH = "/webdav-input/";
    private static final WebDavInput INSTANCE = new WebDavInput();
    private static final long TTL_NANOS = 5L * 60 * 1_000_000_000;
    private String token;
    private long expires;
    private Consumer<String> receiver;

    public enum Field {
        URL("服务器目录地址", "url"), USER("账号", "text"), PASSWORD("密码", "password");
        final String title, type;
        Field(String title, String type) { this.title = title; this.type = type; }
    }
    private Field field;

    public static WebDavInput get() { return INSTANCE; }

    public synchronized String begin(Field field, Consumer<String> callback) {
        this.field = field;
        token = UUID.randomUUID().toString();
        expires = System.nanoTime() + TTL_NANOS;
        receiver = callback;
        return token;
    }

    public synchronized void end(String expected) {
        if (token != null && token.equals(expected)) { token = null; receiver = null; }
    }

    @Override public boolean isRequest(IHTTPSession session, String url) { return url.startsWith(PATH); }

    @Override public synchronized Response doResponse(IHTTPSession session, String url, Map<String, String> files) {
        if (token == null || !url.equals(PATH + token) || System.nanoTime() - expires >= 0) {
            if (token != null && System.nanoTime() - expires >= 0) end(token);
            return response(Response.Status.FORBIDDEN, "输入页面已失效，请在电视上重新打开二维码。");
        }
        if (session.getMethod() == NanoHTTPD.Method.GET) return response(Response.Status.OK, PAGE.replace("{{title}}", field.title).replace("{{type}}", field.type));
        if (session.getMethod() != NanoHTTPD.Method.POST) return response(Response.Status.METHOD_NOT_ALLOWED, "不支持的操作");
        String type = session.getHeaders().getOrDefault("content-type", "");
        long length;
        try { length = Long.parseLong(session.getHeaders().getOrDefault("content-length", "0")); }
        catch (NumberFormatException e) { length = 0; }
        if (!type.startsWith("application/x-www-form-urlencoded") || length <= 0 || length > 16384)
            return response(Response.Status.BAD_REQUEST, "输入内容无效或过长。");
        try { session.parseBody(new HashMap<>()); }
        catch (Exception e) { return response(Response.Status.BAD_REQUEST, "无法读取输入，请重试。"); }
        String value = session.getParms().getOrDefault("text", "");
        if (value.length() > 4096 || (field == Field.URL &&
                !(value.trim().startsWith("http://") || value.trim().startsWith("https://"))))
            return response(Response.Status.BAD_REQUEST, "输入无效，请检查服务器地址或字段长度。");
        Consumer<String> callback = receiver;
        end(token);
        callback.accept(value);
        return response(Response.Status.OK, "已发送到电视，请返回电视确认输入，再保存配置。此输入页面已失效。");
    }

    private Response response(Response.Status status, String text) {
        Response response = NanoHTTPD.newFixedLengthResponse(status, "text/html; charset=utf-8", text);
        // 拒绝请求时尚未读取请求体，关闭连接避免影响下一次提交。
        response.addHeader("Connection", "close");
        response.addHeader("Cache-Control", "no-store");
        response.addHeader("Referrer-Policy", "no-referrer");
        response.addHeader("X-Frame-Options", "DENY");
        response.addHeader("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'");
        return response;
    }

    private static final String PAGE = """
            <!doctype html><html lang="zh-CN"><meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <title>WebDAV 配置输入</title>
            <style>body{background:#171b23;color:#fff;font:17px system-ui;margin:32px auto;padding:0 24px;max-width:480px}
            label{display:block;margin:24px 0 8px}input,button{box-sizing:border-box;width:100%;padding:14px;border-radius:8px;border:1px solid #687080;font:inherit}
            input{background:#242b36;color:#fff}button{margin-top:28px;background:#e8edf6;color:#171b23}p{color:#bdc5d3;line-height:1.6}</style>
            <h1>{{title}}</h1><p>填写后发送到电视，确认后再保存配置。页面有效期为 5 分钟。</p>
            <form method="post" autocomplete="off">
            <label for="text">{{title}}</label><input id="text" name="text" type="{{type}}" autocapitalize="none" spellcheck="false" maxlength="4096">
            <button type="submit">发送到电视</button></form>
            <p>手机与电视需连接同一局域网。输入使用局域网 HTTP 传输，请在可信网络操作。</p></html>
            """;
}

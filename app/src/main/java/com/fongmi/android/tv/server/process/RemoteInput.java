package com.fongmi.android.tv.server.process;

import android.text.InputType;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.widget.EditText;
import com.fongmi.android.tv.App;
import com.fongmi.android.tv.server.Server;
import com.github.catvod.utils.Asset;
import org.json.JSONObject;
import java.lang.ref.WeakReference;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;
import fi.iki.elonen.NanoHTTPD;

/** 只接收当前前台窗口的文字；持久入口不返回任何已保存的字段内容。 */
public final class RemoteInput {
    public static final String PATH = "/remote-input/";
    private static final List<WeakReference<Window>> windows = new ArrayList<>();
    private static WeakReference<EditText> lastTarget = new WeakReference<>(null);
    private static String revision = "";
    private RemoteInput() {}

    // 以下窗口和输入框状态只在主线程访问。
    public static void attach(Window window) {
        if (window == null) return;
        windows.removeIf(ref -> ref.get() == null || ref.get() == window);
        windows.add(new WeakReference<>(window));
    }

    private static synchronized String key() {
        var prefs = App.get().getSharedPreferences("remote_input", 0);
        String key = prefs.getString("key", "");
        if (key.isEmpty()) {
            key = UUID.randomUUID().toString() + UUID.randomUUID();
            prefs.edit().putString("key", key).commit();
        }
        return key;
    }

    public static synchronized void reset() {
        App.get().getSharedPreferences("remote_input", 0).edit().remove("key").commit();
    }

    public static String address() {
        Server.get().start();
        return Server.get().getAddress() + PATH + key();
    }

    private static void collect(View view, List<EditText> fields) {
        if (!view.isShown() || !view.isEnabled()) return;
        if (view instanceof EditText edit) fields.add(edit);
        if (view instanceof ViewGroup group)
            for (int i = 0; i < group.getChildCount(); i++) collect(group.getChildAt(i), fields);
    }

    private static EditText target() {
        EditText selected = null;
        windows.removeIf(ref -> ref.get() == null);
        for (int i = windows.size() - 1; i >= 0; i--) {
            Window window = windows.get(i).get();
            if (window == null || !window.getDecorView().hasWindowFocus()) continue;
            List<EditText> fields = new ArrayList<>();
            collect(window.getDecorView(), fields);
            for (EditText field : fields) if (field.hasFocus()) selected = field;
            if (selected == null && fields.size() == 1) selected = fields.get(0);
            break;
        }
        if (selected != lastTarget.get()) {
            lastTarget = new WeakReference<>(selected);
            revision = UUID.randomUUID().toString();
        }
        return selected;
    }

    private static String status() throws Exception {
        EditText field = target();
        JSONObject json = new JSONObject();
        json.put("ready", field != null);
        json.put("revision", revision);
        json.put("title", field == null ? "请在电视上打开要填写的输入框" :
                field.getHint() == null ? "电视当前输入框" : field.getHint().toString());
        int variation = field == null ? 0 : field.getInputType() & InputType.TYPE_MASK_VARIATION;
        int kind = field == null ? 0 : field.getInputType() & InputType.TYPE_MASK_CLASS;
        json.put("password", (kind == InputType.TYPE_CLASS_TEXT &&
                (variation == InputType.TYPE_TEXT_VARIATION_PASSWORD || variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD)) ||
                (kind == InputType.TYPE_CLASS_NUMBER && variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD));
        return json.toString();
    }

    public static NanoHTTPD.Response serve(NanoHTTPD.IHTTPSession session) {
        String base = PATH + key();
        String uri = session.getUri();
        if (!uri.equals(base) && !uri.equals(base + "/state") && !uri.equals(base + "/send"))
            return reply(NanoHTTPD.Response.Status.FORBIDDEN, "连接已失效，请重新扫描电视二维码。", false);
        try {
            if (uri.equals(base) && session.getMethod() == NanoHTTPD.Method.GET)
                return reply(NanoHTTPD.Response.Status.OK, Asset.read("remote-input/index.html"), true);
            if (uri.equals(base + "/state") && session.getMethod() == NanoHTTPD.Method.GET)
                return reply(NanoHTTPD.Response.Status.OK, ui(RemoteInput::status), false);
            if (!uri.equals(base + "/send") || session.getMethod() != NanoHTTPD.Method.POST)
                return reply(NanoHTTPD.Response.Status.METHOD_NOT_ALLOWED, "不支持的操作", false);
            String contentType = session.getHeaders().getOrDefault("content-type", "");
            long size = Long.parseLong(session.getHeaders().getOrDefault("content-length", "0"));
            if (!contentType.startsWith("application/x-www-form-urlencoded") || size <= 0 || size > 131072)
                return reply(NanoHTTPD.Response.Status.BAD_REQUEST, "输入内容无效或过长", false);
            session.parseBody(new HashMap<>());
            String text = session.getParms().getOrDefault("text", "");
            String expected = session.getParms().getOrDefault("revision", "");
            if (text.length() > 16384) return reply(NanoHTTPD.Response.Status.BAD_REQUEST, "最多输入 16384 个字符", false);
            String result = ui(() -> {
                // 排队期间若撤销连接或切换输入目标，拒绝写入。
                if (!uri.equals(PATH + key() + "/send")) return "连接已重置，请重新扫码";
                EditText field = target();
                if (field == null || !revision.equals(expected)) return "电视输入框已改变，请核对目标后重新发送";
                field.setText(text);
                field.setSelection(field.length());
                return "已发送到电视，请在电视上确认或搜索";
            });
            return reply(NanoHTTPD.Response.Status.OK, result, false);
        } catch (Exception e) {
            return reply(NanoHTTPD.Response.Status.BAD_REQUEST, "暂时无法连接电视，请重试", false);
        }
    }

    private static String ui(java.util.concurrent.Callable<String> action) throws Exception {
        FutureTask<String> task = new FutureTask<>(action);
        App.post(task);
        try { return task.get(3, TimeUnit.SECONDS); }
        finally { task.cancel(false); }
    }

    private static NanoHTTPD.Response reply(NanoHTTPD.Response.Status status, String text, boolean html) {
        NanoHTTPD.Response response = NanoHTTPD.newFixedLengthResponse(status,
                html ? "text/html; charset=utf-8" : "text/plain; charset=utf-8", text);
        response.addHeader("Cache-Control", "no-store");
        response.addHeader("Connection", "close");
        response.addHeader("Referrer-Policy", "no-referrer");
        response.addHeader("X-Frame-Options", "DENY");
        response.addHeader("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'");
        return response;
    }
}

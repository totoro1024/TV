package com.fongmi.android.tv.ui.activity;

import android.content.SharedPreferences;
import android.os.Bundle;
import android.text.InputType;
import android.view.View;
import android.view.ViewGroup;
import android.graphics.Color;
import android.view.Gravity;
import android.text.method.PasswordTransformationMethod;

import android.widget.LinearLayout;

import android.widget.TextView;

import androidx.appcompat.app.AlertDialog;
import androidx.viewbinding.ViewBinding;
import com.fongmi.android.tv.databinding.ActivityWebDavBinding;
import com.fongmi.android.tv.databinding.DialogUaBinding;
import com.fongmi.android.tv.ui.base.BaseActivity;
import com.fongmi.android.tv.server.Server;
import com.fongmi.android.tv.server.process.WebDavInput;
import com.fongmi.android.tv.utils.QRCode;
import com.google.android.material.textview.MaterialTextView;

import com.fongmi.android.tv.App;
import com.fongmi.android.tv.R;
import com.fongmi.android.tv.sync.WebDavSync;
import com.google.android.material.dialog.MaterialAlertDialogBuilder;

import java.util.ArrayList;
import java.util.List;

/** 支持方向键操作，并明确标示覆盖和清空的数据流向与范围。 */
public class WebDavActivity extends BaseActivity {
    private final WebDavSync sync = WebDavSync.get();
    private final List<View> controls = new ArrayList<>();
    private LinearLayout content;
    private TextView url, user, password;
    private View auto;
    private boolean automatic;
    private AlertDialog inputDialog;
    private String inputToken;
    private Object inputSession;
    private TextView status;
    private boolean running;
    private final Runnable refresh = new Runnable() {
        @Override public void run() {
            status.setText(sync.status());
            App.post(this, 1000);
        }
    };

    @Override protected ViewBinding getBinding() {
        ActivityWebDavBinding binding = ActivityWebDavBinding.inflate(getLayoutInflater());
        content = binding.content;
        return binding;
    }

    @Override protected void initView(Bundle state) {
        label("WebDAV 跨设备同步", 24);
        if (com.fongmi.android.tv.BuildConfig.PLAYER_COMPAT) label("兼容测试版：支持 MPV 与普通 Exo；Exo 的 libass 和双字幕暂不可用。", 18);
        label("共享观看记录、进度、收藏、影视源、直播源及网盘登录配置。每位用户使用独立目录；应用会在所填地址下创建 fongmi-sync-v1。", 16);
        SharedPreferences prefs = sync.preferences();
        url = field("服务器目录地址", prefs.getString("url", ""), InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        user = field("账号", prefs.getString("user", ""), InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD);
        password = field("密码", prefs.getString("password", ""), InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        automatic = prefs.getBoolean("auto", false);
        auto = row("自动同步", automatic ? "开启" : "关闭");
        auto.setOnClickListener(v -> {
            if (running || sync.busy()) return;
            automatic = !automatic;
            ((TextView) auto.getTag()).setText(automatic ? "开启" : "关闭");
        });
        label("开启后，在启动、数据变更、播放中每 60 秒及暂停/退出时自动同步。", 14);
        label("网盘 Cookie、Token 及配套登录数据随同步保存到你的 WebDAV。同步内容不加密。使用 HTTP 时账号密码也不受传输加密保护。WebDAV 账号和设备设置仅保存在本机。", 16);
        button("保存配置", () -> save(false));
        button("保存并测试连接", () -> save(true));
        status = label(sync.status(), 18);
        button("立即同步（拉取 → 合并 → 上传）", () -> perform(WebDavSync.Operation.SYNC));
        label("高级操作", 22);
        button("拉取合并（不上传）", () -> perform(WebDavSync.Operation.MERGE));
        button("覆盖远端", () -> confirm("覆盖远端", "将本机的观看记录、进度、收藏、源、网盘配置及通用偏好替换到云端。其他设备下次同步会应用此版本。执行前保存本地恢复副本。", WebDavSync.Operation.PUSH));
        button("覆盖本地", () -> confirm("覆盖本地", "云端数据将替换本机同步范围内的数据。设备设置及 WebDAV 账号保留，执行前保存恢复副本。", WebDavSync.Operation.PULL));
        button("清空远端", () -> confirm("清空远端", "只清除本应用的云端同步数据，保留远端重置标记。本机数据保留，各设备检测到重置后暂停同步。", WebDavSync.Operation.CLEAR));
        label("远端重置或本地恢复后", 22);
        button("用本机重新建立云端数据", () -> confirm("重新建立云端", "用当前本机数据建立新版本；其他设备下一次同步会应用此版本。本机自动同步恢复原开关状态。", WebDavSync.Operation.REBUILD));
        button("从云端重新开始", () -> confirm("从云端重新开始", "用当前云端数据替换本机。如果云端仍为空，本机同步范围内的数据也将清空。执行前保存恢复副本。", WebDavSync.Operation.ACCEPT_RESET));
        button("恢复最近的本地副本", () -> confirm("恢复本地副本", "恢复最近一次覆盖前的本机同步数据；恢复后暂停同步，可另行选择用本机重建云端。最多保留 5 份副本。", WebDavSync.Operation.RESTORE));
        label("本地文件、插件及其依赖不会随源地址上传。使用 file/content/clan 或本机路径的源，需要在目标设备补充文件；iPhone 后续客户端还需支持对应的源格式。", 16);
        button("返回", this::finish);
        // 焦点沿设置行上下移动，与现有电视设置页保持一致。
        for (int i = 0; i < controls.size(); i++) {
            View view = controls.get(i); view.setId(View.generateViewId());
        }
        for (int i = 0; i < controls.size(); i++) {
            if (i > 0) controls.get(i).setNextFocusUpId(controls.get(i - 1).getId());
            if (i + 1 < controls.size()) controls.get(i).setNextFocusDownId(controls.get(i + 1).getId());
        }
    }

    private int dp(int n) { return Math.round(n * getResources().getDisplayMetrics().density); }
    private TextView label(String text, int size) {
        TextView view = new TextView(this); view.setText(text); view.setTextSize(size);
        view.setTextColor(Color.WHITE); view.setAlpha(size < 18 ? 0.7f : 1f);
        view.setPadding(0, dp(10), 0, dp(10)); content.addView(view); return view;
    }
    private TextView field(String title, String value, int input) {
        View item = row(title, value);
        TextView text = (TextView) item.getTag();
        if ((input & InputType.TYPE_MASK_VARIATION) == InputType.TYPE_TEXT_VARIATION_PASSWORD)
            text.setTransformationMethod(PasswordTransformationMethod.getInstance());
        item.setOnClickListener(v -> {
            if (running || sync.busy()) return;
            WebDavInput.Field kind = text == url ? WebDavInput.Field.URL : text == user ? WebDavInput.Field.USER : WebDavInput.Field.PASSWORD;
            showInput(title, text, input, kind);
        });
        return text;
    }
    private View row(String title, String value) {
        LinearLayout line = new LinearLayout(this);
        line.setGravity(Gravity.CENTER_VERTICAL);
        TextView name = new MaterialTextView(this);
        name.setText(title); name.setTextSize(18); name.setTextColor(Color.WHITE);
        TextView text = new MaterialTextView(this);
        text.setText(value); text.setTextSize(18); text.setTextColor(Color.WHITE);
        text.setGravity(Gravity.END); text.setSingleLine(true);
        text.setEllipsize(android.text.TextUtils.TruncateAt.MIDDLE);
        line.addView(name, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 0.4f));
        line.addView(text, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 0.6f));
        // 整行承担遥控器焦点，文字与现有设置页使用同一套样式。
        line.setBackgroundResource(R.drawable.selector_item);
        line.setFocusable(true); line.setFocusableInTouchMode(true);
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(56));
        params.topMargin = dp(12); content.addView(line, params); controls.add(line);
        line.setTag(text);
        return line;
    }
    private void button(String title, Runnable action) {
        TextView view = new MaterialTextView(this); view.setText(title); view.setTextSize(18);
        view.setTextColor(Color.WHITE); view.setGravity(Gravity.CENTER_VERTICAL);
        view.setBackgroundResource(R.drawable.selector_item); view.setFocusable(true); view.setFocusableInTouchMode(true);
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(52));
        params.topMargin = dp(12); content.addView(view, params);
        view.setOnClickListener(v -> { if (!running && !sync.busy()) action.run(); }); controls.add(view);
    }
    private void showInput(String title, TextView target, int input, WebDavInput.Field field) {
        Server.get().start();
        DialogUaBinding binding = DialogUaBinding.inflate(getLayoutInflater());
        binding.text.setHint(title);
        binding.text.setInputType(input);
        binding.text.setText(target.getText());
        binding.text.setSelectAllOnFocus(true);
        Object session = new Object();
        inputSession = session;
        inputToken = WebDavInput.get().begin(field, value -> App.post(() -> {
            if (inputSession != session || inputDialog == null || !inputDialog.isShowing() || isFinishing() || isDestroyed()) return;
            binding.text.setText(value);
            binding.text.setSelection(binding.text.length());
            binding.positive.requestFocus();
        }));
        String address = Server.get().getAddress() + WebDavInput.PATH + inputToken;
        binding.code.setImageBitmap(QRCode.getBitmap(address, 200, 0));
        binding.info.setText("手机与电视连接同一网络\n扫码填写，电视确认后生效\n二维码有效期 5 分钟");
        inputDialog = new MaterialAlertDialogBuilder(this).setView(binding.getRoot()).create();
        binding.positive.setOnClickListener(v -> {
            target.setText(binding.text.getText().toString());
            inputDialog.dismiss();
        });
        binding.negative.setOnClickListener(v -> inputDialog.dismiss());
        binding.text.setOnEditorActionListener((v, action, event) -> {
            if (action == android.view.inputmethod.EditorInfo.IME_ACTION_DONE) { binding.positive.performClick(); return true; }
            return false;
        });
        String token = inputToken;
        inputDialog.setOnDismissListener(d -> {
            if (inputSession == session) inputSession = null;
            WebDavInput.get().end(token);
        });
        inputDialog.show();
        inputDialog.getWindow().setLayout((int) (getResources().getDisplayMetrics().widthPixels * 0.55f), ViewGroup.LayoutParams.WRAP_CONTENT);
    }
    private void confirm(String title, String message, WebDavSync.Operation operation) {
        new MaterialAlertDialogBuilder(this).setTitle(title).setMessage(message)
                .setNegativeButton("取消", null).setPositiveButton("确认执行", (d, w) -> perform(operation)).show();
    }
    private void lock() {
        running = true; for (View view : controls) view.setEnabled(false); status.setText("正在处理…");
    }
    private void completed(String message) {
        if (isFinishing() || isDestroyed()) return;
        running = false; for (View view : controls) view.setEnabled(true); status.setText(message);
    }
    private void save(boolean test) {
        lock();
        sync.saveSettings(url.getText().toString(), user.getText().toString(), password.getText().toString(), automatic, message -> {
            if (test && "配置已保存".equals(message)) sync.test(this::completed);
            else completed(message);
        });
    }
    private void perform(WebDavSync.Operation operation) {
        lock(); sync.run(operation, this::completed);
    }
    @Override protected void onStart() { super.onStart(); App.post(refresh); }
    @Override protected void onStop() {
        App.removeCallbacks(refresh);
        if (inputDialog != null) inputDialog.dismiss();
        WebDavInput.get().end(inputToken);
        super.onStop();
    }
}

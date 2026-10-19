package com.fongmi.android.tv.ui.activity;

import android.content.SharedPreferences;
import android.os.Bundle;
import android.text.InputType;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import androidx.appcompat.app.AppCompatActivity;

import com.fongmi.android.tv.App;
import com.fongmi.android.tv.R;
import com.fongmi.android.tv.sync.WebDavSync;
import com.google.android.material.dialog.MaterialAlertDialogBuilder;

import java.util.ArrayList;
import java.util.List;

/** 支持方向键操作，并明确标示覆盖和清空的数据流向与范围。 */
public class WebDavActivity extends AppCompatActivity {
    private final WebDavSync sync = WebDavSync.get();
    private final List<View> controls = new ArrayList<>();
    private LinearLayout content;
    private EditText url, user, password;
    private CheckBox auto;
    private TextView status;
    private boolean running;
    private final Runnable refresh = new Runnable() {
        @Override public void run() {
            status.setText(sync.status());
            App.post(this, 1000);
        }
    };

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(dp(32), dp(24), dp(32), dp(24));
        scroll.addView(content);
        setContentView(scroll);
        label("WebDAV 跨设备同步", 24);
        label("共享观看记录、进度、收藏、影视源和直播源。每位用户使用独立目录；应用会在所填地址下创建 fongmi-sync-v1。", 16);
        SharedPreferences prefs = sync.preferences();
        url = field("服务器目录地址（HTTP / HTTPS）", prefs.getString("url", ""), InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        user = field("账号", prefs.getString("user", ""), InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD);
        password = field("密码", prefs.getString("password", ""), InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        auto = new CheckBox(this);
        auto.setText("自动同步：启动、变更、播放中每 60 秒及暂停/退出播放");
        auto.setChecked(prefs.getBoolean("auto", false));
        content.addView(auto); controls.add(auto);
        label("同步内容不加密。使用 HTTP 时账号密码也不受传输加密保护。WebDAV 账号和设备设置仅保存在本机。", 16);
        button("保存配置", () -> save(false));
        button("保存并测试连接", () -> save(true));
        status = label(sync.status(), 18);
        button("立即同步（拉取 → 合并 → 上传）", () -> perform(WebDavSync.Operation.SYNC));
        label("高级操作", 22);
        button("拉取合并（不上传）", () -> perform(WebDavSync.Operation.MERGE));
        button("覆盖远端", () -> confirm("覆盖远端", "将本机的观看记录、进度、收藏、源及通用偏好替换到云端。其他设备下次同步会应用此版本。执行前保存本地恢复副本。", WebDavSync.Operation.PUSH));
        button("覆盖本地", () -> confirm("覆盖本地", "云端数据将替换本机同步范围内的数据。设备设置及 WebDAV 账号保留，执行前保存恢复副本。", WebDavSync.Operation.PULL));
        button("清空远端", () -> confirm("清空远端", "只清除本应用的云端同步数据，保留远端重置标记。本机数据保留，各设备检测到重置后暂停同步。", WebDavSync.Operation.CLEAR));
        label("远端重置或本地恢复后", 22);
        button("用本机重新建立云端数据", () -> confirm("重新建立云端", "用当前本机数据建立新版本；其他设备下一次同步会应用此版本。本机自动同步恢复原开关状态。", WebDavSync.Operation.REBUILD));
        button("从云端重新开始", () -> confirm("从云端重新开始", "用当前云端数据替换本机。如果云端仍为空，本机同步范围内的数据也将清空。执行前保存恢复副本。", WebDavSync.Operation.ACCEPT_RESET));
        button("恢复最近的本地副本", () -> confirm("恢复本地副本", "恢复最近一次覆盖前的本机同步数据；恢复后暂停同步，可另行选择用本机重建云端。最多保留 5 份副本。", WebDavSync.Operation.RESTORE));
        label("本地文件、插件及其依赖不会随源地址上传。使用 file/content/clan 或本机路径的源，需要在目标设备补充文件；iPhone 后续客户端还需支持对应的源格式。", 16);
        button("返回", this::finish);
        // 显式连接焦点，确保电视遥控器可以离开输入框。
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
        view.setPadding(0, dp(10), 0, dp(10)); content.addView(view); return view;
    }
    private EditText field(String title, String value, int input) {
        label(title, 16);
        EditText view = new EditText(this); view.setSingleLine(true); view.setInputType(input); view.setText(value);
        view.setSelectAllOnFocus(true); view.setTextSize(18);
        content.addView(view, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(56)));
        controls.add(view); return view;
    }
    private void button(String title, Runnable action) {
        Button view = new Button(this); view.setText(title); view.setTextSize(18); view.setAllCaps(false);
        view.setBackgroundResource(R.drawable.selector_item); view.setFocusable(true);
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(56));
        params.topMargin = dp(8); content.addView(view, params);
        view.setOnClickListener(v -> { if (!running && !sync.busy()) action.run(); }); controls.add(view);
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
        sync.saveSettings(url.getText().toString(), user.getText().toString(), password.getText().toString(), auto.isChecked(), message -> {
            if (test && "配置已保存".equals(message)) sync.test(this::completed);
            else completed(message);
        });
    }
    private void perform(WebDavSync.Operation operation) {
        lock(); sync.run(operation, this::completed);
    }
    @Override protected void onStart() { super.onStart(); App.post(refresh); }
    @Override protected void onStop() { App.removeCallbacks(refresh); super.onStop(); }
}

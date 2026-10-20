package com.fongmi.android.tv.ui.dialog;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.DialogInterface;
import android.net.Uri;
import android.view.ViewGroup;
import android.webkit.CookieManager;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.LinearLayout;
import android.widget.TextView;

import androidx.appcompat.app.AlertDialog;

import com.fongmi.android.tv.api.loader.BaseLoader;
import com.fongmi.android.tv.sync.CloudConfigStore;
import com.fongmi.android.tv.sync.PluginCookieCodec;
import com.fongmi.android.tv.utils.Notify;
import com.fongmi.android.tv.utils.ResUtil;
import com.google.android.material.dialog.MaterialAlertDialogBuilder;

/** 网盘登录固定在配置页，不调用源插件的同步登录弹窗。 */
public final class CloudLoginDialog {
    private CloudLoginDialog() {}
    public static void show(Activity activity) {
        new MaterialAlertDialogBuilder(activity).setTitle("网盘扫码登录")
                .setItems(new String[]{"UC 网盘（优汐）扫码登录", "夸克网盘扫码登录"}, (dialog, which) -> {
                    if (which == 0) UcLoginDialog.show(activity);
                    else open(activity, false);
                }).setNegativeButton("取消", null).show();
    }
    @SuppressLint("SetJavaScriptEnabled")
    private static void open(Activity activity, boolean uc) {
        String name = uc ? "UC 网盘" : "夸克网盘";
        String origin = uc ? "https://drive.uc.cn" : "https://pan.quark.cn";
        String address = origin + "/list";
        LinearLayout layout = new LinearLayout(activity);
        layout.setOrientation(LinearLayout.VERTICAL);
        TextView status = new TextView(activity);
        status.setPadding(24, 12, 24, 12);
        status.setText("请在官网登录页选择扫码登录，手机确认后点击“完成登录”。登录信息参与 WebDAV 网盘配置同步。");
        layout.addView(status);
        WebView web;
        try { web = new WebView(activity); }
        catch (RuntimeException error) { Notify.show("系统 WebView 不可用，无法打开网盘登录页"); return; }
        layout.addView(web, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (int)(ResUtil.getScreenHeight() * 0.62f)));
        web.setInitialScale(50);
        WebSettings settings = web.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(false);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        settings.setUseWideViewPort(true);
        settings.setLoadWithOverviewMode(true);
        settings.setSupportZoom(true);
        settings.setBuiltInZoomControls(true);
        settings.setDisplayZoomControls(false);
        settings.setUserAgentString("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36");
        CookieManager.getInstance().setAcceptCookie(true);
        CookieManager.getInstance().setAcceptThirdPartyCookies(web, false);
        web.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                Uri url = request.getUrl();
                // 官网登录可跳转同集团的认证域；不打开外部应用或其他网站。
                String host = url.getHost();
                String suffix = uc ? ".uc.cn" : ".quark.cn";
                return !"https".equals(url.getScheme()) || host == null || !(host.equals(suffix.substring(1)) || host.endsWith(suffix));
            }
        });
        AlertDialog dialog = new MaterialAlertDialogBuilder(activity).setTitle(name + "扫码登录")
                .setView(layout).setPositiveButton("完成登录", null)
                .setNeutralButton("重新加载", null).setNegativeButton("关闭", null).create();
        dialog.setOnDismissListener(d -> { web.stopLoading(); layout.removeView(web); web.destroy(); });
        dialog.setOnShowListener(d -> {
            dialog.getWindow().setLayout((int)(ResUtil.getScreenWidth() * 0.92f), (int)(ResUtil.getScreenHeight() * 0.92f));
            dialog.getButton(DialogInterface.BUTTON_NEUTRAL).setOnClickListener(v -> web.loadUrl(address));
            dialog.getButton(DialogInterface.BUTTON_POSITIVE).setOnClickListener(v -> {
                String cookie = CookieManager.getInstance().getCookie(origin);
                if (!PluginCookieCodec.valid(cookie)) { status.setText("尚未取得登录状态，请完成手机扫码确认后再试。"); return; }
                try {
                    CloudConfigStore.saveLogin(uc ? "uc_ck" : "quark_ck", cookie);
                    CookieManager.getInstance().flush();
                    BaseLoader.get().clear();
                    dialog.dismiss();
                    com.fongmi.android.tv.sync.WebDavSync.get().afterCloudLogin();
                } catch (Exception error) { status.setText("登录信息保存失败，请重试。登录页仍保留。"); }
            });
            web.loadUrl(address);
        });
        dialog.show();
    }
}

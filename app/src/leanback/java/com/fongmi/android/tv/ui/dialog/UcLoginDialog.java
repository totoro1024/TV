package com.fongmi.android.tv.ui.dialog;

import android.app.Activity;
import android.graphics.Color;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import androidx.appcompat.app.AlertDialog;
import com.fongmi.android.tv.App;
import com.fongmi.android.tv.api.loader.BaseLoader;
import com.fongmi.android.tv.sync.CloudConfigStore;
import com.fongmi.android.tv.sync.UcLoginClient;
import com.fongmi.android.tv.utils.Notify;
import com.fongmi.android.tv.utils.QRCode;
import com.fongmi.android.tv.utils.ResUtil;
import com.google.android.material.dialog.MaterialAlertDialogBuilder;
import org.json.JSONObject;
import java.util.concurrent.Executors;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.atomic.AtomicBoolean;

public final class UcLoginDialog {
    public static void show(Activity activity) {
        LinearLayout layout=new LinearLayout(activity);
        layout.setOrientation(LinearLayout.VERTICAL);layout.setGravity(android.view.Gravity.CENTER);
        ImageView code=new ImageView(activity);code.setBackgroundColor(Color.BLACK);
        layout.addView(code,new LinearLayout.LayoutParams(ResUtil.dp2px(260),ResUtil.dp2px(260)));
        TextView status=new TextView(activity);status.setPadding(24,16,24,16);status.setText("正在获取 UC 登录二维码…");layout.addView(status);
        UcLoginClient client=new UcLoginClient();
        ExecutorService worker=Executors.newSingleThreadExecutor();
        AtomicBoolean closed=new AtomicBoolean();
        AlertDialog dialog=new MaterialAlertDialogBuilder(activity).setTitle("UC 网盘扫码登录").setView(layout)
                .setNegativeButton("关闭",null).setNeutralButton("刷新二维码",(d,w)->show(activity)).create();
        dialog.setOnDismissListener(d->{closed.set(true);client.cancel();worker.shutdownNow();});
        dialog.show();
        worker.submit(()->{
            try {
                String token=client.token();
                android.graphics.Bitmap bitmap=QRCode.getBitmap(UcLoginClient.qrURL(token),260,2);
                App.post(()->{if(!closed.get()){code.setImageBitmap(bitmap);status.setText("请用 UC 浏览器扫码并在手机确认，成功后自动保存登录态。");}});
                for(int i=0;i<240 && !closed.get();i++) {
                    Thread.sleep(2000);
                    String ticket=client.poll(token);
                    if(ticket.isEmpty()) continue;
                    JSONObject account=client.account(ticket);
                    if(closed.get()) return;
                    CloudConfigStore.saveLogin("uc_ck","__pus="+account.getString("__pus"));
                    String st=account.optString("serviceTicket");
                    App.get().getSharedPreferences("spUtils",0).edit().putString("ucSt",st).commit();
                    App.post(()->{if(!closed.get()){BaseLoader.get().clear();dialog.dismiss();com.fongmi.android.tv.sync.WebDavSync.get().afterCloudLogin();}});
                    return;
                }
                App.post(()->{if(!closed.get())status.setText("二维码已超时，请刷新后重新扫码。");});
            } catch(Exception error) {
                App.post(()->{if(!closed.get())status.setText("UC 登录接口连接失败，请刷新重试。");});
            }
        });
    }
}

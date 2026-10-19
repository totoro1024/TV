package androidx.media3.ui.danmaku;

import android.net.Uri;
import android.view.ViewGroup;
import android.widget.FrameLayout;

import androidx.media3.ui.PlayerView;

import okhttp3.OkHttpClient;

/** 将公开弹幕控制器接入播放器视图，每次绑定更新播放器并正确释放旧视图。 */
public final class DanmakuPlayerViewController {
    private DanmakuController controller = new DanmakuController();
    private DanmakuView overlay;
    private PlayerView playerView;
    private ViewGroup parent;

    public void bind(PlayerView view) {
        if (playerView != view) {
            detach();
            playerView = view;
            overlay = new DanmakuView(view.getContext());
            parent = view.getOverlayFrameLayout();
            if (parent == null) parent = view;
            parent.addView(overlay, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
            controller.setView(overlay);
        }
        controller.setPlayer(view.getPlayer());
    }
    public void setOkHttpClient(OkHttpClient client) { controller.setOkHttpClient(client); }
    public void setEnabled(boolean enabled) { controller.setEnabled(enabled); }
    public void setConfig(DanmakuConfig config) { controller.setConfig(config); }
    public void setDataSource(Uri uri) {
        if (playerView != null) controller.setPlayer(playerView.getPlayer());
        controller.setDataSource(uri);
    }
    public void sendNow(String text) { controller.sendNow(text); }
    private void detach() {
        controller.setPlayer(null); controller.setView(null);
        if (parent != null && overlay != null) parent.removeView(overlay);
        if (overlay != null) overlay.release();
        playerView = null; parent = null; overlay = null;
    }
    public void close() { detach(); controller.release(); controller = new DanmakuController(); }
}

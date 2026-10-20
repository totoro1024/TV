package com.fongmi.android.tv.ui;

import android.app.Activity;
import android.app.Application;
import android.view.KeyEvent;
import android.view.LayoutInflater;
import android.view.View;
import androidx.core.widget.NestedScrollView;
import androidx.leanback.widget.VerticalGridView;
import com.fongmi.android.tv.R;
import com.fongmi.android.tv.bean.Episode;
import com.fongmi.android.tv.ui.adapter.EpisodeAdapter;
import java.util.ArrayList;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.Robolectric;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;
import org.robolectric.Shadows;
import static org.junit.Assert.*;

/** 真实 Leanback 焦点搜索及 NestedScrollView 组合，不以模拟坐标替代按键。 */
@RunWith(RobolectricTestRunner.class)
@Config(application = Application.class, sdk = 28)
public class EpisodeScrollTest {
    @Test public void leftColumnScrollsBeyondFourthRowAndBack() throws Exception { verifyNavigation(0); }
    @Test public void rightColumnScrollsBeyondFourthRowAndBack() throws Exception { verifyNavigation(1); }

    private void verifyNavigation(int startPosition) throws Exception {
        var controller = Robolectric.buildActivity(Activity.class).setup().visible();
        Activity activity = controller.get();
        activity.setTheme(R.style.Theme_App);
        var xml = activity.getResources().getXml(R.layout.activity_video);
        while (!(xml.getEventType() == 2 && xml.getName().equals("androidx.core.widget.NestedScrollView"))) xml.next();
        NestedScrollView root = new NestedScrollView(activity, android.util.Xml.asAttributeSet(xml));
        root.addView(LayoutInflater.from(activity).inflate(xml, null));
        activity.setContentView(root);
        controller.windowFocusChanged(true);
        VerticalGridView grid = root.findViewById(R.id.episode);
        grid.setVisibility(View.VISIBLE);
        EpisodeAdapter adapter = new EpisodeAdapter(item -> {});
        var episodes = new ArrayList<Episode>();
        for (int i = 0; i < 35; i++) {
            Episode item = new Episode();
            item.setName("第" + (i + 1) + "集");
            episodes.add(item);
        }
        adapter.addAll(episodes);
        grid.setAdapter(adapter);
        layout(root);
        grid.setSelectedPosition(startPosition);
        grid.requestFocus();
        if (grid.getChildCount() > 0) grid.getChildAt(startPosition).requestFocus();
        layout(root);
        assertTrue("选集必须获得焦点", grid.hasFocus());
        for (int i = 0; i < 12; i++) {
            key(root, KeyEvent.KEYCODE_DPAD_DOWN);
            layout(root);
            assertFocusedVisible(grid);
        }
        assertTrue("向下键必须进入可见第四行之后，实际位置=" + grid.getSelectedPosition(), grid.getSelectedPosition() >= 8);
        for (int i = 0; i < 12; i++) {
            key(root, KeyEvent.KEYCODE_DPAD_UP);
            layout(root);
            assertFocusedVisible(grid);
        }
        assertTrue("向上键必须能回到首行", grid.getSelectedPosition() < 2);
        controller.pause().stop().destroy();
        xml.close();
    }
    private void assertFocusedVisible(VerticalGridView grid) {
        View focused = grid.findFocus();
        assertNotNull("焦点应留在选集网格", focused);
        assertTrue("位置=" + grid.getSelectedPosition() + " 应滚入可见区域，top=" + focused.getTop(),
                focused.getTop() >= 0 && focused.getBottom() <= grid.getHeight());
    }

    private void layout(View root) {
        Shadows.shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(300));
        root.measure(View.MeasureSpec.makeMeasureSpec(960, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(260, View.MeasureSpec.EXACTLY));
        root.layout(0, 0, 960, 260);
        Shadows.shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(300));
    }
    private void key(View root, int code) {
        // 无真实 ViewRootImpl 的 JVM 环境中，调用相同的焦点导航路径。
        if (!root.dispatchKeyEvent(new KeyEvent(KeyEvent.ACTION_DOWN, code))) {
            View focused = root.findFocus();
            int direction = code == KeyEvent.KEYCODE_DPAD_DOWN ? View.FOCUS_DOWN : View.FOCUS_UP;
            View next = focused == null ? null : focused.focusSearch(direction);
            if (next != null) next.requestFocus(direction);
        }
        root.dispatchKeyEvent(new KeyEvent(KeyEvent.ACTION_UP, code));
    }
}

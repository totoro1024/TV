package com.fongmi.android.tv.player;

import androidx.media3.extractor.mp4.FragmentedMp4Extractor;
import org.junit.Test;

/** 在 MP4 解析器实际构造入口检查运行时依赖，避免只编译 App 时漏掉 AAR 的传递依赖。 */
public class PlayerDependencyTest {
    @Test public void streamingFactoriesArePackaged() throws Exception {
        ClassLoader loader = getClass().getClassLoader();
        for (String name : new String[]{
                "androidx.media3.exoplayer.hls.HlsMediaSource$Factory",
                "androidx.media3.exoplayer.dash.DashMediaSource$Factory",
                "androidx.media3.exoplayer.rtsp.RtspMediaSource$Factory",
                "androidx.media3.exoplayer.smoothstreaming.SsMediaSource$Factory"}) {
            // 与 DefaultMediaSourceFactory 的按需反射加载入口一致。
            Class.forName(name, false, loader);
        }
    }
    @Test public void mp4ExtractorInitializes() {
        new FragmentedMp4Extractor();
    }
}

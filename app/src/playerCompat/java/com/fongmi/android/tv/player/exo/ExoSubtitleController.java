package com.fongmi.android.tv.player.exo;

import androidx.annotation.Nullable;
import androidx.media3.common.TrackSelectionOverride;
import androidx.media3.ui.PlayerView;

import com.fongmi.android.tv.player.engine.PlayerEngine.SecondarySubtitleState;
import com.fongmi.android.tv.setting.SubtitleSetting;
import com.fongmi.android.tv.utils.Notify;

/** 公开播放器依赖的兼容实现，保留 Exo 普通字幕，显式禁用缺少接口的双字幕。 */
final class ExoSubtitleController {
    @Nullable private PlayerView playerView;
    ExoSubtitleController(ExoPlayerSession session) { }
    void release() { playerView = null; }
    void bindPlayerView(PlayerView view) { playerView = view; applySubtitleStyle(); }
    void applySubtitleStyle() {
        if (playerView != null && playerView.getSubtitleView() != null) SubtitleSetting.applyStyle(playerView.getSubtitleView());
    }
    SecondarySubtitleState getSecondarySubtitleState() { return SecondarySubtitleState.EMPTY; }
    void setSecondarySubtitleSelection(@Nullable TrackSelectionOverride selection) {
        Notify.show("兼容测试版的 Exo 暂不支持双字幕，可切换到 MPV");
    }
}

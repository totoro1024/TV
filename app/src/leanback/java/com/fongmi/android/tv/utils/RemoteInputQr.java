package com.fongmi.android.tv.utils;

import android.widget.ImageView;
import android.widget.TextView;
import com.fongmi.android.tv.server.process.RemoteInput;

/** 统一入口；重置后旧收藏链接立即失效。 */
public final class RemoteInputQr {
    private RemoteInputQr() {}
    public static void bind(ImageView code, TextView info, int size) {
        code.setImageBitmap(QRCode.getBitmap(RemoteInput.address(), size, 0));
        if (info != null) info.setText("手机与电视连接同一网络\n首次扫码，收藏页面后所有输入通用\n发送后在电视上确认；长按二维码重置连接");
        code.setContentDescription("手机统一输入：扫码后收藏页面；长按重置连接");
        code.setFocusable(true);
        code.setOnLongClickListener(v -> {
            RemoteInput.reset();
            bind(code, info, size);
            return true;
        });
    }
}

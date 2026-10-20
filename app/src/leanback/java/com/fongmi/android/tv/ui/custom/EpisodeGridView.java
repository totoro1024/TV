package com.fongmi.android.tv.ui.custom;

import android.content.Context;
import android.util.AttributeSet;
import android.util.TypedValue;
import androidx.leanback.widget.VerticalGridView;

/** 固定两列的电视选集网格，焦点变化时由 Leanback 对齐并滚入可见区域。 */
public class EpisodeGridView extends VerticalGridView {
    public EpisodeGridView(Context context) {
        this(context, null);
    }

    public EpisodeGridView(Context context, AttributeSet attrs) {
        super(context, attrs);
        setNumColumns(2);
        setColumnWidth(0);
        setHorizontalSpacing(dp(8));
        setVerticalSpacing(dp(6));
        // ITEM 模式在外层滚动容器中可使新焦点移到视口之外。
        setFocusScrollStrategy(FOCUS_SCROLL_ALIGNED);
    }

    private int dp(int value) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, getResources().getDisplayMetrics()));
    }
}

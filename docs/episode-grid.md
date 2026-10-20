# 电视选集网格

选集使用 `EpisodeGridView`，两列，最多显示四行，超过八集后在网格内部纵向滚动。排序和集数分组位于网格上方。

compat8 在外层 NestedScrollView 下使用 Leanback 的 `FOCUS_SCROLL_ITEM`。回归场景中，向下进入索引 8（第 9 集）时，焦点条目 top 为 -400，已离开高度 154 的网格视口；仅切换为 `FOCUS_SCROLL_ALIGNED` 后恢复可见。compat9 将对齐配置集中到选集控件，避免页面与测试分别维护配置。

回归测试直接从正式详情页布局载入滚动区域和选集控件，使用真实 EpisodeAdapter 填充 35 集，分别从左右两列连续下移十二次，再上移十二次，每一步均断言焦点在网格可见范围内并最终回到首行。

```sh
bash gradlew :app:testLeanbackDebugUnitTest -PplayerCompat=true --tests com.fongmi.android.tv.ui.EpisodeScrollTest
```

测试使用 Robolectric 的 Android 28 环境；无真实 ViewRootImpl 的 JVM 环境中通过按键派发和 Android 焦点导航路径驱动。该验证不能替代目标电视上的遥控器端到端测试。

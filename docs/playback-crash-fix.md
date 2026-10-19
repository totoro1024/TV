# 兼容版播放崩溃：播放器传递依赖缺失

## 已复现的异常

用户反馈版本 56302 在播放视频时进入崩溃页。在同一 MuMu「Kindle」模拟设备上重新触发，并用本地 HTTP 服务播放公开测试 MP4 缩小复现范围，均捕获到：

```text
java.lang.NoClassDefFoundError: androidx/media3/container/NalUnitUtil
  at androidx.media3.extractor.mp4.FragmentedMp4Extractor.<init>
  at androidx.media3.extractor.DefaultExtractorsFactory.createExtractors
```

新增 PlayerDependencyTest 在真正的 FragmentedMp4Extractor 构造入口复现同一异常，修复前测试失败。原有同步/HTTP/字体测试未触及这一播放入口。

## 原因与修改

本地 fileTree 引入 AAR 不会读取它们原先的 Maven 传递依赖。镜像的 AAR 集合没有包含容器解析模块，编译 App 不会提前链接解析器内部引用的 NalUnitUtil，因此安装和启动成功，但播放 MP4 时崩溃。

兼容构建显式引入与播放器基线匹配的 Google Maven Media3 1.11.0 容器模块。同类检查还发现按需反射加载的 HLS、DASH、RTSP、SmoothStreaming 工厂未提供；新增工厂加载回归测试先观察到 ClassNotFoundException，再补齐对应官方模块。流媒体模块排除已由本地定制 AAR 提供的 Media3 传递模块，避免重复类。

版本更新为 5.6.3-webdav.2-compat，版本号 56303。继续保留完整播放器源码及兼容版的既有限制。

## 可重复验证

```sh
bash gradlew :app:assembleLeanbackDebug :app:testLeanbackDebugUnitTest -PplayerCompat=true
python3 tools/player-dependencies/verify-apk.py app/build/outputs/apk/leanback/debug/app-leanback-arm64-v8a-debug.apk
python3 tools/playback-smoke/repro.py --serial DEVICE --fixture /path/to/sample.mp4
python3 tools/playback-smoke/repro.py --serial DEVICE --fixture /path/to/media_playlist.m3u8 --with-siblings
```

设备测试通过 ADB reverse 仅开放临时本机测试目录，使用 ACTION_SEND 进入应用实际播放链，检查新的应用异常和系统播放状态。结束后关闭临时 HTTP 服务并移除 reverse，不清空应用数据或用户日志。日志输出仅包含错误类别和缺失类，媒体地址及用户配置不输出。

测试素材取自 FongMi/media 固定提交 3c2cbe8ac742c2fe15eff52f03eeb3b1b648848d 的 libraries/test_data/src/test/assets/media/mp4/sample.mp4，以及 media/hls/standalone-webvtt/media_playlist.m3u8 与同目录文件。未将用户的影视源、登录凭据或观看数据加入测试仓库。

## 验证边界

最终兼容版构建成功，Android 工程 36 项测试通过、0 失败、0 跳过；两个架构 APK 的签名、ZIP 对齐和真实 DEX 类定义检查通过。已使用保留数据的覆盖安装更新用户 MuMu，MP4 与 HLS 实际播放测试均通过，UI 也确认显示视频画面。DASH/RTSP/SmoothStreaming 当前仅验证模块打包和工厂加载，不代表流播放已验证。实体电视、全部影视源和长时间播放未作全面验证。

验证过程中另出现 MuMu 自身的设备进程未响应错误 22000；重启单个测试实例后重新连接并完成上述测试。此模拟器故障与原先已复现的 Java 缺类异常分别记录。

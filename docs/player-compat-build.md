# 兼容测试版 APK

用户已确认先交付兼容测试版：保留 MPV、普通 Exo 播放及 WebDAV 同步，暂不支持 Exo 的 libass 和双字幕。完整播放器实现保留在 `app/src/playerFull/java`；兼容实现位于 `app/src/playerCompat/java`，通过构建参数选择。

## 构建

环境为 JDK 21、Android SDK 37、Python 3.10。用 local.properties 配置 sdk.dir，debug 构建不需要额外签名配置。

```sh
python3 tools/player-dependencies/fetch.py
bash gradlew :app:assembleLeanbackDebug :app:testLeanbackDebugUnitTest -PplayerCompat=true
bash gradlew -p tools/sync-tests test
```

输出为 `app/build/outputs/apk/leanback/debug/` 下的 arm64-v8a 与 armeabi-v7a 两个 APK。版本名 `5.6.3-webdav.1-compat`，版本号 56302，包名 `com.fongmi.android.tv.webdav`，最低 Android 7.0，使用本机 Android 调试签名。两个架构选一个安装；原应用的私有数据需手动迁入。

不带 playerCompat 参数仍选择完整实现，完整实现仍需匹配全部新接口的播放器 AAR。

## 依赖来源与适配

21 个 AAR 来自第三方公开镜像 `oinsilos/myfp` 的固定提交 `78268fa2ef9c120b884e67ffdc8707b9e87702e0`。文件大小及 SHA-256 保存在 `tools/player-dependencies/manifest.json`，下载脚本逐个校验。镜像地址为 https://github.com/oinsilos/myfp/tree/78268fa2ef9c120b884e67ffdc8707b9e87702e0/TV-fongmi/app/libs 。源码适配中的 ExoPlayerSession、ExoMediaSourceFactory、ExoUtil 参考该固定提交的对应实现。镜像二进制不等同于作者官方发布产物。

弹幕视图使用公开的 DanmakuController/DanmakuView 接入。字体家族名通过有边界检查的 TTF/OTF/TTC 名称表解析，不依赖缺少的私有 libass 字体接口。MPV 的第二字幕通过公开 MpvSubtitleOptions 的轨道设置接口映射；目前仅验证编译，未验证真实字幕轨道与播放行为。

Exo 普通字幕样式保留，libass 开关在兼容版电视界面隐藏，Exo 的第二字幕候选为空。设置页显示兼容测试版版本，WebDAV 页面说明限制。完整实现未被兼容实现替换。

## 验证结果

- 兼容版 Android APK 构建成功。
- Android 工程单元测试 34 项通过、0 失败、0 跳过。
- 独立 JVM 同步/字体测试同样 34 项通过，属于同一套用例，不累计为 68 项。
- 两个 APK 的 apksigner 校验通过，使用 APK Signature Scheme v2。
- 两个 APK 的 16 KiB ZIP 对齐检查通过。该检查不等于全部原生库运行时兼容性验证。
- 清单确认包名、版本、HTTP 访问声明和 WebDavActivity 入口正确。
- 未连接 Android 真机：界面、实际源播放、字幕、真实 WebDAV 和跨设备续播尚未端到端验证。

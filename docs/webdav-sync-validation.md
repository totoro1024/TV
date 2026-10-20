# WebDAV 同步验证记录

## 当前交付状态

Android 电视端 WebDAV 兼容测试版 APK 已构建并完成签名检查，详见 [兼容版构建](player-compat-build.md)。完整播放器配置仍受缺失的新接口依赖限制；APK 构建和单元测试通过不等于电视 UI 或真机功能验证通过。

## 自动化验证

执行：

```sh
bash gradlew -p tools/sync-tests test
```

该独立 JVM 测试工程复用生产的 SyncDocument、SyncReplica、SyncEngine、WebDavClient 源文件；不依赖上游缺失的播放器 AAR。测试使用隔离的本机 HTTP WebDAV 模拟服务，不连接用户的真实服务，也不读取用户凭据。

本机独立 JVM 测试 34 项通过（30 项同步/HTTP 及 4 项字体解析）；Android 工程另加入 2 项播放器依赖回归，共 36 项通过，均为 0 失败、0 跳过。

覆盖：跨平台 UTF-8 身份向量、最近观看与回看、确定性合并、删除与重新添加、未知字段保留、条件写入冲突、无条件写入服务拒绝、连接探测清理、损坏及超限文件拒绝。两副本操作测试覆盖双向合并、单向拉取不上传、覆盖两端、清空后重建、重置确认、文件意外丢失、播放时覆盖拦截、请求期间编辑保留。

另提供只读权限的 GitHub Actions 工作流示例 `docs/examples/webdav-sync-tests.yml`，可执行同一套协议测试，不构建 APK。当前 GitHub 令牌缺少 workflow 权限，示例未安装到 .github/workflows，尚无云端 CI 结果。

## 完整播放器配置的构建限制

执行：

```sh
bash gradlew :app:assembleLeanbackDebug :app:testLeanbackDebugUnitTest
```

以下为不带 `-PplayerCompat=true` 时的限制；兼容版构建已成功。

本机已具备 JDK 21（Gradle toolchain）、Android SDK 37 和 Python 3.10。构建到 `:app:compileLeanbackDebugJavaWithJavac` 时失败：`androidx.media3.common`、`androidx.media3.ui.danmaku.DanmakuPlayerViewController` 等定制播放器类缺失。上游 README 的构建说明指出 `lib-*.aar` 未纳入 Git，单纯 clone 不包含完整播放器依赖。

已检查作者 FongMi/media 的公开分支 `release-1.11.0-fongmi`；其中有部分播放器源码及原生库，但未找到应用引用的 DanmakuPlayerViewController/libass 等完整接口。未将不匹配的源码替换进应用，也未通过空实现伪造播放器依赖。

继续构建需要与当前 TV 源码匹配的作者配套 AAR（放入 app/libs/），或另行取得完整匹配源码。配齐后需重新执行整个应用编译与测试。

## 尚未验证

- Android 电视上的界面、遥控器焦点、Room 持久化与生命周期的端到端行为。
- 用户实际 HTTP WebDAV 服务是否支持强 ETag 和 If-Match/If-None-Match。
- 两台真实设备上的播放、断网重试、突然断电恢复与源切换。单台 MuMu 的 MP4/HLS 播放已验证，见 [播放修复记录](playback-crash-fix.md)。
- iOS 客户端：本阶段仅完成跨平台格式和固定身份样例，未开发 iOS 应用。

## 使用与构建说明

设置 → WebDAV 跨设备同步，填写目录地址、账号、密码后保存并测试。自动同步默认关闭，用户可在测试连接后开启。高级操作分别显示覆盖范围和确认提示。

此分支应用 ID 为 `com.fongmi.android.tv.webdav`，版本名 `5.6.3-webdav.1`，用于与原版并存；因此不会自动继承原版应用的私有数据。可使用上游备份/恢复手动迁入已有数据。debug 构建使用 Android 默认调试签名；release 构建需自行配置签名。

本机 local.properties、签名与账号密码均不提交。恢复副本和同步状态保存在应用私有目录。HTTP 与明文内容按用户决定支持。

## 同步时间与低流量检查

- Android TV 与 iPhone 显示本机“最近同步成功”时间，按 WebDAV 地址及账号隔离并保留到重启后；连接测试、失败、清空远端和接受重置不刷新此时间。
- 自动同步保持 60 秒周期。开启自动同步后，打开播放前先尝试同步，再读取续播位置；退出播放时保存最新位置并请求同步。网络失败后仍可使用本地进度。
- 同一账号会话保留远端 ETag，后续读取带 `If-None-Match`；服务器返回 304 时复用已经校验的内存副本。切换地址、账号或密码时重新建立客户端，404 清除缓存。
- 合并结果与远端完整文档相同时跳过 PUT；有变化时仍使用强 ETag 条件写入，冲突时重新拉取合并。
- 隔离 HTTP 测试覆盖 304、无变化不写入，以及其他设备更新后可拉取新记录。iOS 同样使用模拟 DAV 验证条件 GET 与跳过重复上传。

## 退出补传与播放冲突保护（webdav.11 / iOS build 17）

- 本地副本保存 `localRevision`、`uploadedRevision` 和 `retryNeeded`；这些字段不写入共享同步文件。上传失败后待同步数据与重试标记保留，开启自动同步时在下次启动、恢复运行或周期检查补传；关闭自动同步时保留并提示手动同步。
- 上传成功只确认请求涵盖的本机版本。上传期间产生的编辑仍显示待同步，拉取合并不把尚未上传的编辑标记为已上传。
- Android TV 播放中仅即时应用收藏，其余下载数据保留到待应用日志；退出后先捕获本机最新记录再合并。iPhone 播放中保持当前进度，持久化暂存云端结果，退出或重启后合并。
- 暂停、退出时位置没有变化，不刷新实际观看时间。两端按实际观看时间合并，不采用“取最大播放位置”；用户主动回看或后退仍可保存较小的新位置。
- 设置页新增“数据状态”：未配置、待同步、同步中、同步失败等待重试、已同步和播放中延后应用提示。“最近同步成功”继续独立显示。
- iPhone 退入后台时申请系统允许的有限执行时间尝试完成同步；若时间耗尽或应用被强退，已保存的进度和待同步状态留待下次运行补传。不能保证强退瞬间尚未落盘的播放时间。
- 保持每 60 秒的自动同步周期，并保留打开/暂停/退出播放触发；沿用 ETag 条件读取、无变化不上传和条件写入冲突重试。

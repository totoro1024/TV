# WebDAV 同步验证记录

## 当前交付状态

Android 电视端 WebDAV 兼容测试版 APK 已构建并完成签名检查，详见 [兼容版构建](player-compat-build.md)。完整播放器配置仍受缺失的新接口依赖限制；APK 构建和单元测试通过不等于电视 UI 或真机功能验证通过。

## 自动化验证

执行：

```sh
bash gradlew -p tools/sync-tests test
```

该独立 JVM 测试工程复用生产的 SyncDocument、SyncReplica、SyncEngine、WebDavClient 源文件；不依赖上游缺失的播放器 AAR。测试使用隔离的本机 HTTP WebDAV 模拟服务，不连接用户的真实服务，也不读取用户凭据。

本机测试结果：34 项通过、0 失败、0 跳过（30 项同步/HTTP 测试及 4 项兼容版字体解析测试）。Android 工程与独立 JVM 工程均执行同一套用例。

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
- 两台真实设备上的播放、断网重试、突然断电恢复与源切换。
- iOS 客户端：本阶段仅完成跨平台格式和固定身份样例，未开发 iOS 应用。

## 使用与构建说明

设置 → WebDAV 跨设备同步，填写目录地址、账号、密码后保存并测试。自动同步默认关闭，用户可在测试连接后开启。高级操作分别显示覆盖范围和确认提示。

此分支应用 ID 为 `com.fongmi.android.tv.webdav`，版本名 `5.6.3-webdav.1`，用于与原版并存；因此不会自动继承原版应用的私有数据。可使用上游备份/恢复手动迁入已有数据。debug 构建使用 Android 默认调试签名；release 构建需自行配置签名。

本机 local.properties、签名与账号密码均不提交。恢复副本和同步状态保存在应用私有目录。HTTP 与明文内容按用户决定支持。

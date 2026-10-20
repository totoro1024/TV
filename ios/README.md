# 影视同步 iPhone 首版

面向自行签名安装的原生 SwiftUI 应用，不接入 App Store、TestFlight、购买或账号服务。最低 iOS 17，界面为简体中文。

## 已实现的首版代码

- 影视源：添加视频直链、M3U 直播、影视 JSON API，以及包含 type=1 HTTP API 站点的电视 JSON 配置。浏览、搜索、分页、详情及选集。
- 播放：自定义 AVPlayerLayer 界面与 MobileVLCKit 3.7.4 原画内核；按原源、站点、影片、线路、剧集续播。每5秒本地保存，暂停/退出请求同步，前台每60秒同步。支持无痕模式。
- WebDAV：HTTP/HTTPS、连接测试、强 ETag 条件写入、412最多4次重试、手动/自动同步、四种高级操作、重置确认、覆盖前5份恢复副本。凭据保存在应用私有目录的 webdav-settings.json，不进入同步文件。
- 同步协议与 Android 共用稳定身份与毫秒时间。保留未知记录/字段、原始数字文本以及不支持的网盘配置包；本机修改保留已知记录里的扩展字段。夸克 Cookie 从 WebDAV 同步配置读取并在内存解码，不额外落盘解码值或写入钥匙串。
- 播放中暂存合并结果；退出播放后合并本地最新进度再应用。网络请求期间的本机编辑保留，不把较大的进度误当较新的观看。

## 兼容范围

原生适配支持茉莉／视界 App99 浏览与播放，以及玩偶 WoGG 首页推荐、分类分页、搜索、详情和夸克选集播放。玩偶从同步 Cookie 读取夸克分享目录，其他网盘尚未适配。其他 Android JAR、Python/JS、XML 和网页解析不能直接运行，记录保持原样。

电视端直播收藏仅含频道名，无法可靠推断原始 M3U 地址，此类收藏提示从对应列表选择；不按片名跨源续播。首次 iPhone 端仍建议先配置 WebDAV 再添加源，不同地址/账号的本地同步状态隔离。

自动同步仅在应用运行时调度。切到后台只尝试同步一次，iOS不保证执行时间；没有后台常驻同步的承诺。

## 工程与构建

`TVWebDAV.xcodeproj` 为已生成的工程，依赖本地 Swift Package `TVCore`。首次构建从 VideoLAN 官方地址下载并校验固定版本 MobileVLCKit（约222 MiB），后续复用 build/Vendor。应用包名为 `com.totoro.tv.ios`，版本0.1.0。

安装完整 Xcode（包含 iPhoneOS SDK）后：

```sh
# 如果 Xcode 不是当前开发目录，可仅对本次命令设置环境变量，无需全局切换。
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash ios/scripts/build-unsigned-ipa.sh
```

产物为 `ios/build/TVWebDAV-0.1.0-unsigned.ipa`，内部为真机 arm64 应用。使用你自己的工具和证书重新签名后安装。脚本不读取开发者账号、不会选择团队、不上传 App Store，不把模拟器产物伪装为 IPA。

编辑 App 内 Swift 文件后运行 `python3 ios/scripts/generate-project.py` 更新工程。工程脚本使用 Python 标准库，不依赖 XcodeGen/CocoaPods。

## 验证

```sh
# CLT 环境可运行，不依赖 XCTest；断言来自同一组 XCTest 合同测试。
python3 ios/scripts/generate-checks.py
swift run --package-path ios TVCoreChecks
python3 ios/scripts/check-http.py

# 完整 Xcode 环境可运行对应 XCTest 测试。
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path ios
```

截至2026-10-19：使用 Xcode 27.1 和 iPhoneOS 27.1 SDK 完成 iPhone 真机 arm64 Release 编译，已生成未签名 IPA，并核对包内平台及签名状态。完整 Xcode 下的 19 项 XCTest 全部通过；隔离本机 HTTP 服务的同步检查也已通过。

仍待验证：模拟器界面及播放、Android↔iPhone真实WebDAV互通、断网/重置/播放期并发操作、自签IPA安装及真机播放。编译和核心测试通过不代表上述端到端功能已经验证。

## 界面风格

复用 Android 电视端绿色壁纸和应用标志，采用白色文字、线条图标、透明深色卡片。首页提供点播、直播、搜索、收藏、推送及设置入口，历史与收藏使用海报卡片；点播和搜索直接使用首页当前站点。布局随手机宽度调整，不缩放电视端的整屏界面。

此界面版本已通过模拟器 Debug 和真机 Release 编译，并在 iPhone Duo 模拟器中检查首页与 WebDAV 设置显示及导航。iPhone 18 Pro Max 所需运行环境仍在下载，尚未完成该机型的界面和播放验证。

设置首页现按电视端入口组织：WebDAV 跨设备同步、点播、直播、壁纸、播放设置、弹幕、无痕、安全 DNS、版本。WebDAV 表单移至二级页面。四张内置壁纸可切换；自动接续开关和默认倍速作用于 AVPlayer。本机界面及播放选项不改变 Android 的播放器配置。弹幕和应用内 DoH 暂未实现，页面明确说明。

设置 v2 验证：已在 iPhone 18 Pro Max / iOS 27.0 模拟器启动，确认完整设置首页、播放设置和 WebDAV 二级页可进入，壁纸 1→2→1 实际切换生效。模拟器 Debug 与真机 Release 编译通过。倍速与接续的实际视频播放、真实 WebDAV 双端同步仍待端到端验证。

## WebDAV 本地配置

按用户要求，WebDAV 地址、账号和密码写入 Application Support/TVWebDAV/webdav-settings.json，原子保存，权限 0600，使用 iOS 文件保护。已有钥匙串配置在首次启动时读取并迁移，文件成功保存后删除旧钥匙串项；不再新增或更新钥匙串。迁移后的读取和保存不依赖钥匙串权限。配置文件保留明文凭据，不加入同步文档。

源配置兼容修复：支持 Android 八字符标记的图片前缀 Base64 封装、UTF-8 BOM、JSON 行/块注释及尾逗号；不修改严格同步 JSON 解析。21 项 XCTest 通过；iPhone 18 Pro Max 实际重试原历史卡片后，已正确识别为 Android 插件站点并显示不兼容提示，不再误报“JSON 数字无效”。该站点尚不能在 iPhone 播放。

## 茉莉／视界原生适配

`csp_App99Guard` 通过原生 Swift 适配执行配置解码、AES-CBC 请求、签名、zlib 响应、影视搜索、详情、多线路及 JSON 播放解析；不运行 Android JAR。保持原 source/site/vod 身份与剧集格式，复用电视历史及观看进度。播放 URL 每次重新解析；播放器应用站点返回的请求头。网页嗅探线路仍不支持，玩偶 WoGGGuard 尚未接入。

参考 jo32/tvbox-silicon 的 App99.js、_fty.js，固定参考提交和 GPL-3.0 许可保存在 `ThirdParty/App99`。包含上游公开 App99 配置的指纹回退，不包含个人 WebDAV 密码、Cookie 或用户 Token。加固配置变化或出现未知编码时会明确报错，不会执行任意 JAR。

验证：24 项 XCTest 通过。iPhone 18 Pro Max / iOS 27.0 模拟器从原视界历史卡片读取《嫁金钗》详情，FF有广线路第01集显示真实变化的视频画面；本地观看进度由15000推进至40000毫秒，总时长2926953毫秒。退出播放后重新打开接续。仅此测试线路完成实播，不保证所有影片和线路；真机自签安装仍待用户验证。测试期间曾出现 WebDAV 网络连接提示，不能据此宣称本轮远端同步成功。

## Android 风格内页与全屏播放

对照 Android leanback 的 `activity_vod.xml`、`activity_video.xml`、`view_control_vod.xml`：影片列表使用海报网格，详情使用海报信息、简介、横向线路和网格选集，支持正倒序。播放页整屏呈现，包含时间进度条、播放暂停、前后10秒、倍速、下一集、选线选集、收藏及全屏/退出全屏。全屏进入请求横屏，退出请求竖屏；设备不允许旋转时仍可进入竖屏整屏视频区域。保持视频比例，不拉伸画面。仍使用 iOS AVPlayer，Android 专属解码器、弹幕、libass 不在此次界面适配范围。

模拟器实测：iPhone 18 Pro Max 的视界原历史可进入新详情并选集播放，全屏隐藏详情，横屏显示视频及底部控制，视频画面和进度持续变化。24项核心测试、Debug与真机Release编译通过。真机自签与全部线路兼容性仍待验证。

本轮列表实机网络检查：茉莉列表/搜索接口出现超时及 HTTP 502，已保留明确错误和重试入口，尚不能宣称本轮真实列表加载通过。海报网格、搜索框与分页已实现；详情、实际播放和横屏全屏已通过模拟器观察。

## 玩偶夸克历史接续

反编译恢复业务 DEX 并定位 WoGG / Cloud_quark / N0 的协议结构；iPhone 使用独立 Swift 实现，不运行 Android JAR 或加固库。反编译存在7处方法错误，未将伪代码当作全部正确。

夸克只消费 WebDAV 的 cloudAccount/catvod-sp-utils-v1：从 prefs/defaults.quark_ck 在内存解码，不另外保存明文 Cookie，不写钥匙串，不回写解码值，不自动验证账号或要求扫码。WebDAV 自身凭据按用户要求保存为本地配置文件。

按原分享 ID、文件 fid 刷新授权及分享目录，在夸克“影视同步-iPhone”目录保存副本，并复用已保存的同一文件。不会清理用户文件。原画获取签名下载地址，验证 PNG 签名及偏移8处的 MKV 签名；回环随机路径按净视频 Range 转发，2 MiB 分段并预读下一段，内存保持有界。Cookie 仅向官方夸克域名发送；VLC 仅接触本地地址。普通视频使用服务端转码流。

2026-10-19 验证：iPhone 18 Pro Max / iOS 27.0，原第二张玩偶《嫁金钗》历史使用已同步 Cookie 实播，清晰画面与进度从04:01推进至04:34；暂停后本地和 WebDAV 远端均为282542毫秒，再次打开接续到04:55，后续持续播放。38项 XCTest 通过。服务器偶发缺少强 ETag 提示时保留本地数据，不降低并发保护要求；不将一次成功解释为所有网络请求均成功。

最新全屏布局：视频铺满整个屏幕，悬浮控制3秒自动隐藏；默认按比例裁切铺满，可切换适应保留完整画面。点按视频可唤出控制。设置页、源列表和首页对照 Android Config.getDesc：名称优先，没有名称则显示网址，长网址从中间省略。

真机 IPA 只保留 arm64；自签工具需要同时签名应用和嵌入的 MobileVLCKit.framework。真机安装及其他影片、网盘和线路仍待验证。

## 原生片单与直接 AirPlay

- DouDou / DouDouGuard：使用与插件相同的豆瓣热榜接口读取片单，过滤广告及集合占位条目；海报按图片域名设置公开 Referer。豆豆没有独立播放地址，点影片后在同一配置的 App99 / JSON API 站点内按片名搜索。
- 首页切换站点会清空旧推荐，请求返回时核对选择和请求标识，避免旧结果覆盖；点播及搜索使用当前首页站点。尚未适配的站点会显示具体名称和原因。
- 玩偶图片头 MKV：点击 AirPlay 后，在 iPhone 内通过 MobileVLCKit 已导出的 libavformat 重新封装为 HLS，切换到 AVPlayer 后再次点击系统 AirPlay 按钮选择电视。不是屏幕镜像；只复制 H.264 / HEVC 与 AAC 编码包，不做解码转码。其他原画编码明确提示不支持。
- 从当前播放位置附近的关键帧生成 HLS，保留原影片时间轴和观看进度。按播放位置预读约三分钟，临时缓存最多 2 GiB，剩余空间低于 128 MiB 停止；退出播放取消下载并清理缓存。暂只支持跳转已生成片段，无法保证未适配编码或更大影片的完整播放。
- iPhone 和电视需在同一局域网并允许本地网络访问。仅发布随机能力地址下的 `.m3u8` 和 `.ts`，不向电视发送夸克 Cookie、签名原画地址或任意本地文件。
- 已在 iPhone 18 Pro Max 模拟器以真实玩偶原画验证 HLS 出画面、音视频时间轴与接续；未连接真实 AirPlay 接收设备，电视出画面仍待自签真机测试。
- WebDAV 密码输入改为明文，不使用 SecureField；仍保存于应用私有目录的配置文件。


## 玩偶 WoGG 完整浏览与夸克选集

- 原生读取 WoGG HTML，CSS 选择器和 URL 路径对照恢复的 Android 插件；支持首页推荐、电影/剧集/臻彩/短漫剧/动漫/综艺/纪录片/音乐分类、分页及中文搜索。优先使用 ext.siteUrl，否则使用插件内置镜像；公开站点请求不携带任何账号凭据。
- 从详情提取官方夸克分享链接，按线路展开目录和子目录、自然排序视频文件，保留 sId/fid/pdir_fid/pg/sToken 等原 Android 播放字段。分享读取及播放只使用 WebDAV 同步 Cookie，不额外登录；其他网盘明确报不支持。
- 新影片从推荐、点播和搜索均进入完整选集页；历史中具有有效站内影片 ID 的记录也会尝试加载全部选集，站点不可用时保留原剧集接续。原画播放及直接 AirPlay 沿用既有链路。
- 目录有深度、分页和总条目限制，超过限制明确报错；失效的个别分享线路不阻止其余可用线路，并在简介注明。
- 新增 HTML 卡片/详情解析、分享域名过滤、中文搜索与分页参数、目录递归及 Android 播放字段测试。公开接口实测：首页120条、剧集前两页各70条、嫁金钗搜索2条、详情2条夸克线路；动态站点结果数量可能变化。

选集布局：详情页及播放页的剧集按钮固定两列，按钮至少 56 点高，长文件名不限制行数，自动换行并随内容增高；详情已读取的线路直接传给播放器，避免播放时重复展开网盘目录。

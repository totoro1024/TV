# WebDAV 同步协议 v1

Android 与未来 iOS 客户端共用本协议。WebDAV 目录由用户提供，客户端仅管理其下的 `fongmi-sync-v1/state.json` 和临时连接探测文件。账号、密码及设备设置不写入此文件；内容按用户选择以明文 JSON 保存。

## 文档

- `schema`：整数 `1`，不兼容版本应拒绝读写。
- `epoch`：UUID 字符串，覆盖远端和清空远端时生成新值。
- `mode`：`merge`、`replace` 或 `reset`。`replace` 的新代次表示以云端替换本机同步范围；已确认同代次的设备后续继续正常合并。
- `reset`：最近一次清空远端的 UUID，初始为空；重建云端仍保留此值。设备必须单独确认新的 reset 值，即使另一台设备已重建云端，也不能自动上传旧数据。
- `records`：以稳定身份哈希为键的对象。每条记录包含 `kind`、`modified`、`sequence`、`device`、`deleted`、`value`。

时间与进度单位均为毫秒。`modified` 为变更时间；观看记录使用实际 `watchedAt`，避免延迟扫描把旧观看误判为新观看。`sequence` 为本设备递增逻辑序号。删除记录保留身份、版本及 `deleted=true`，不携带 value。首版不回收删除标记，以支持长期离线设备。

同身份记录按 `(modified, device, sequence, deleted, value)` 确定胜出者：数值或字符串较大者优先，删除在相同版本下优先。value 仅为损坏或重复版本的最终确定性裁决；正常客户端每次变更应更新版本。比较不取最大播放进度，允许回看。

## 稳定身份

依次对每个身份分量进行 UTF-8 编码，前置该分量字节长度的 4 字节无符号大端整数；将所有分量的长度与内容串联后做 SHA-256，输出小写十六进制。不做 Unicode 或 URL 归一化。此规则不依赖 Android/iOS 各自 JSON 编码器的转义方式。

- 源：`["source", "0或1", "原始源URL"]`，0 为影视，1 为直播。URL 不作大小写、参数或尾斜杠归一化。
- 观看记录：`["history", "源身份哈希", "站点key", "影片id"]`。
- 影视收藏：`["favorite", "vod", "源身份哈希", "站点key", "影片id"]`。
- 直播收藏：`["favorite", "live", "频道key"]`，延续上游以频道名称为收藏 key 的语义。
- 站点搜索偏好：`["site", "站点key"]`，延续上游按站点 key 全局存储的语义。
- 当前源：`["preference", "activeSource0或1"]`。

Android 的 Config.id 不出现在协议内。导入时先创建/定位源，再转换本机 cid 与组合 key。不同源或不同影片 id 不按片名匹配。

跨平台样例：`["source", "0", "https://example.test/影视?a=1&b=2"]` 的身份为 `9039481f690907dc08356d94c53835454fa5adc0e402964c9108e00c86a653d0`。测试中固定此向量。

## value 字段

| kind | 字段 |
| --- | --- |
| source | url、type、name、home |
| history | source、site、vod、name、picture、line、episode、episodeUrl、watchedAt、positionMs、durationMs、openingMs、endingMs、reverseSort、reversePlay |
| favorite | type、name、picture、siteName、addedAt；影视另含 source/site/vod，直播另含 channel |
| site | site、searchable（0 不可搜索，1 开启，2 关闭） |
| preference | name、type、url，仅 activeSource0/activeSource1 |

源只传地址及偏好，不传缓存 JSON、本地文件或插件。播放器、字幕样式、界面、网络、WebDAV 凭据与无痕开关不在白名单中。未知 kind 和已知记录 value 内的未知字段在普通合并写回时保留；本地显式覆盖远端会按本机支持的同步范围重建。

## 读写与并发

1. `MKCOL` 创建应用专属子目录，405 表示目录已存在。
2. `GET state.json` 读取文档及强 ETag；404 表示没有同步文件，其他错误不视为“空云端”。
3. 校验全部已知记录后合并。
4. 创建使用 `PUT` + `If-None-Match: *`；更新使用 `PUT` + `If-Match: <ETag>`。
5. 412 时重新拉取合并，最多重试 4 次，持续冲突则保留本地数据并提示稍后重试。

连接测试使用随机 probe 文件，验证读写、强 ETag 及失效 If-Match 返回 412，最后删除 probe。拒绝重定向，用户应填写最终目录地址。服务器需要正确支持条件写入；不支持时明确报错，不能静默退化成覆盖上传。同步文件最大 8 MiB、最多 30000 条记录。

## 操作语义

- 立即/自动同步：拉取、合并、上传、应用到本地。请求期间发生的本地变更再次捕获，保留待后续上传。
- 拉取合并：合并到本地，不上传；之后的自动同步可能上传合并结果。
- 覆盖远端：本机快照作为新 replace 代次。
- 覆盖本地：用云端替换本机同步范围；其他设备设置与 WebDAV 凭据保留。
- 清空远端：写入空 reset 文档，清除同步数据并保留重置标记；本机保留数据并暂停。
- 重建云端：用户明确选择本机作为新 replace 代次，确认 reset 标记。
- 从云端重新开始：用户明确确认 reset 标记并应用当前云端数据；如果仍为空，则清空本机同步范围。

覆盖本地、接收新 replace 代次及恢复前保存本地恢复副本，最多保留 5 份；恢复副本后暂停同步，避免立即被云端覆盖。播放中不切换源、不对播放器调用 seek；正常合并先保存在同步状态中，退出播放后应用到业务数据，合并进度供后续打开影片使用。远端出现新的覆盖代次时，播放中暂缓应用并提示退出播放后同步。应用数据前以本地待应用日志保存目标文档，发生中断后重试完成应用。无痕观看不写观看记录和进度，已有历史不因进入无痕而删除。


## 网盘登录配置扩展（webdav.5）

新增 `cloudAccount` kind，identity 为 `["cloudAccount", "catvod-sp-utils-v1"]`。
value 包含 `adapter`、`prefs`、`defaults`、`files`，其中 files 的值为标准 Base64 编码原始字节，Base64 不是加密。
适配器只接入明确列出的存储项：

- `spUtils`：`quark_ck`、`uc_ck`、`quarkSt`、`ucSt`，以及插件解码配套材料 `hide_appgz_android_id`、`hide_appgz_new_key`、`hide_appgz_utdid`、`hide_appgz_token`。
- 默认偏好：`quark_ck`、`uc_ck`、`baidu_cookie`。
- 私有 files 根目录：`ali_info`、`ali_oauth`、`ali_user`、`quark_ut`、`uc_fid`、`uc_ut`、`mybd_cookie`。

配置作为一个记录整体合并，防止 Cookie 与配套材料分别选中不同设备的版本。单文件上限256KiB，整组JSON上限2MiB。未知文件名、偏好键、非字符串值、非法Base64均拒绝，不允许远端指定任意本地路径。文件写入使用 AtomicFile。旧快照中完全没有此记录时保留本机登录；显式删除标记清除网盘登录状态，保留本机设备派生材料。网盘配置变更使用原有同步调度；接收端在非播放状态重新加载源。覆盖前的本地副本包含此配置。

这些字段来自源插件，不代表所有源都使用相同存储方式。当前设备确认了spUtils与quark_ut落点；阿里/UC等其余命名参考公开源插件适配代码，尚未用真实账号验证跨设备复用。加固插件可能缓存密钥，接收后仍可能需要彻底退出并重新打开应用。iPhone客户端应保留未知kind及本记录，只有实现对应解码/登录适配后才能消费它，不能将Android插件密文直接当作通用Cookie。

网盘登录凭据随用户选择的不加密WebDAV同步保存；不把用户实际值写入日志、测试、文档或Git仓库。该适配仅同步配置，不传插件、网盘文件或缓存目录。
参考： https://github.com/QQ169876/LiuguangZhezhou/blob/main/app/src/main/java/com/fongmi/android/tv/utils/SpiderVault.java


### webdav.6 夸克空账号兼容修复

失败设备的字段结构显示：只存在quark_ut及插件设备派生材料时，webdav.5仍生成cloudAccount，可能以较新的时间覆盖完整Cookie。新增回归测试先失败，修复后通过：quark_ut与quarkSt等配套材料单独存在不再构成已登录账号；读取旧远端时忽略此类空账号；迁移旧本地observed时移除错误观测而不生成注销标记；保留完整账号与显式删除标记。所有测试使用合成字段值。

该修复证明了合并路径的缺陷与修复，尚不证明源插件的跨设备Cookie可解码或账号可用。该阶段两台模拟器调试连接无响应，尚未完成真实双设备复测；当时没有修改设备内的登录配置或还原用户备份。后续在用户重新登录后完成的实测见下一节。


### webdav.6 双模拟器实测进展（2026-10-19）

Kindle重新扫码后，确认quark_ck与quarkSt持久化，远端state.json的Cookie与Kindle逐值一致（只输出布尔比较结果）。vmq读取同一WebDAV后，Cookie及配套密钥与Kindle一致。接收端冷启动后，源插件的“登录自己网盘”面板显示绿色“我的夸父－已登录”，没有在接收端再次扫码。面板另有独立的启用开关；接收端启用并冷启动后，出现“夸父”分类。接收端“夸父”分类成功加载真实网盘目录，确认登录态可用于网盘API访问。以上不包含阿里/UC验证，也不等同所有网盘视频播放已验证。

双模拟器存在MuMu自身22000无响应问题，重启单个故障实例后继续；双同名进程的界面控制暂通过关闭已保存的发送端实例、单独查看接收端解决，验证后恢复发送端。

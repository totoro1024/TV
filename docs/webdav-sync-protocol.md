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

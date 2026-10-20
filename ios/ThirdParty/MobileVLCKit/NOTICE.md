# MobileVLCKit 3.7.4

本应用动态链接 VideoLAN 官方 MobileVLCKit，遵循 LGPL-2.1-or-later。完整许可证位于 COPYING.txt，随 IPA 打包。应用未修改 VLC 源代码。自签用户可以替换 Frameworks/MobileVLCKit.framework，并重新签名整个应用及嵌入框架。

- 上游源码：https://code.videolan.org/videolan/VLCKit
- 官方镜像：https://github.com/videolan/vlckit
- 对应官方二进制（源码修订标识 20260922-1512）：https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-3.0-20260922-1512.tar.xz
- CocoaPods 版本清单：https://github.com/CocoaPods/Specs/blob/master/Specs/b/f/7/MobileVLCKit/3.7.4/MobileVLCKit.podspec.json
- SHA-256：c649c4c47bd065b3a5511746361b5a9066a34033f2df9cbc9454409c0f363b52

复现构建前执行 scripts/prepare-vlc.sh；两个构建脚本也会自动执行。下载与解压到被 Git 排除的 build/Vendor，不提交第三方二进制。

# iPhone内置Python运行时

AI短漫剧适配器使用Python官方3.15.0 iOS XCFramework，在应用内执行随包附带的插件；不下载或执行远端Python代码。

- 下载来源：https://www.python.org/ftp/python/3.15.0/python-3.15.0-iOS-XCframework.tar.gz
- 官方嵌入说明：https://docs.python.org/3/using/ios.html
- 下载归档SHA256：68e98ab35cc0643ba3a227a8c7768da45c2a5e67dbe1bc26598537e96680fd19
- Python许可证随标准库打包于应用python/lib/python3.15/LICENSE.txt。
- 网络组件固定版本：requests 2.32.5、urllib3 2.6.3、certifi 2026.10.18、charset-normalizer 3.5.2、idna 3.20。各组件许可证随包内dist-info目录保留。
- CommonCrypto通过本地C扩展提供AES-CBC/CTR解密；运行时启动执行标准AES测试向量。

须使用scripts/build-simulator.sh或scripts/build-unsigned-ipa.sh，完成标准库、扩展框架及许可证打包；只在Xcode中执行默认Build不会自动完成此步骤。

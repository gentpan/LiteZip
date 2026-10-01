# 构建与发布

[返回项目介绍](../README.md)

以下命令均在仓库根目录执行。

## 构建与测试

需要完整 Xcode 26 或更新版本（Swift 6+）和 XcodeGen。App 图标使用 Icon Composer 格式，Xcode 同时生成新版 macOS 图标与旧系统兼容图标：

```sh
brew install xcodegen
swift test
Scripts/build.sh
open build/LiteZip.app
```

可直接打开提交的 `LiteZip.xcodeproj`。核心是独立的 `LiteZipCore` Swift Package。内置引擎已随源代码提供，最终用户无需 Homebrew。

```sh
LITEZIP_LARGE_TESTS=1 swift test  # 包括真实 1 GiB 文件的流式往返，需可用磁盘空间
LITEZIP_RAR_TEST_ENGINE='/absolute/path/to/rar' swift test  # 可选官方 RAR 集成测试
```

## 签名与公证

发布的 **0.5.0 已完成 Developer ID 签名与 Apple 公证**，ZIP 内的 App 已附上公证凭据。重新解包后，签名、公证凭据和 Gatekeeper 检查均通过。公证用于从 GitHub 等渠道分发，不代表上架 Mac App Store。

本机发布只需构建后执行签名脚本；它会自动提交公证、附上凭据、验证并打包：

```sh
Scripts/build.sh
Scripts/sign.sh
```

本机只有一个有效的 Developer ID Application 签名身份时自动选择；多个身份时需明确指定。公证默认复用维护者现有的 `GiantAccel` Keychain 配置。其他开发者需设置自己的证书和已保存的公证配置：

```sh
export LITEZIP_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export LITEZIP_NOTARY_PROFILE='your-saved-keychain-profile'
Scripts/sign.sh
```

签名脚本依次签名内置引擎、Finder 扩展和 App，启用 Hardened Runtime 和安全时间戳。只有 Apple 返回 `Accepted`、公证凭据验证成功、完整签名与 Gatekeeper 检查通过后，才替换 `dist` 中的最终 ZIP 与 SHA-256 校验值。版本号从 App 读取；可用 `LITEZIP_DIST_DIR` 指定输出目录。证书、私钥和账号授权只从本机 Keychain 调用，不进入仓库。

两个脚本都可以指定 App 路径；已有有效 Developer ID 签名的 App 可以直接公证。公证在私有副本上进行，最终 ZIP 包含附上凭据的 App。提交编号、Apple 检查日志和副本保留在输出目录的 `.notarize-*` 目录，失败不会替换已有下载包：

```sh
Scripts/notarize.sh /absolute/path/to/LiteZip.app
```

公证需要 Apple Developer Program 账号授权；已有有效配置可以复用，不需为每个 App 单独注册公证。首次配置参考 [Apple 公证工作流](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)，使用 `notarytool store-credentials` 保存到 Keychain，不把密码写入脚本。

GitHub Actions 的构建产物为未签名开发构建，Release 下载包为签名及公证后的版本。

# LiteZip

轻量、原生、免费开源的 macOS 压缩与解压工具。SwiftUI 界面，文件完全在本机处理，无账号、广告或遥测。

**0.1.0 开发预览版 · macOS 13+ · Apple Silicon / Intel 通用构建**

![LiteZip](docs/screenshots/light.png)

[深色预览](docs/screenshots/dark.png)

## 已实现

- ZIP / 7Z / TAR / TAR.GZ 压缩与解压；GZIP / BZIP2 / XZ / ZSTD 单文件压缩与解压。
- RAR / RAR5 解压，不创建 RAR。
- ZIP AES-256 加密、7Z AES 加密及文件名加密；密码仅在内存中使用，通过引擎标准输入传递。
- 文件与文件夹拖放、Dock 拖放与文件打开、混合选择的操作确认。
- 最多两个并行任务、排队、进度、估算速度与剩余时间、取消和重新选择重试。
- 压缩包目录浏览、搜索、完整性校验。
- Finder 扩展：快速压缩、压缩设置、解压到独立文件夹。
- 跟随系统／浅色／深色主题、键盘快捷键、标准文件选择和保存对话框。
- 独立解压文件夹、同名自动编号、原子发布、失败与取消清理。
- 越界路径／重复路径／链接／特殊文件拒绝、磁盘容量预检、展开大小限制。
- 崩溃临时目录的本地登记与后续启动清理：超过一天且所属进程已退出的目录才会清理。

## 使用

打开 LiteZip，把文件拖到窗口，选择格式后点击“压缩…”；拖入压缩包则选择解压位置。双击由 LiteZip 打开的压缩包会直接解压到同级的独立文件夹。

应用不会主动改变默认文件关联。可以在 Finder 的“显示简介 → 打开方式”中选择 LiteZip。

Finder 右键菜单需要在系统设置的扩展中启用 **LiteZip Finder**。扩展监视用户主目录和 `/Volumes`。系统设置入口随 macOS 版本不同，可搜索“Finder 扩展”。

ZIP 加密密码当前支持 **1–99 个 ASCII 字符**。中文、Emoji 和更长密码请使用 7Z。AES ZIP 需要兼容 AES 的解压工具，macOS 系统归档工具不一定能打开。

## 构建与测试

需要完整 Xcode（Swift 6+）和 XcodeGen：

```sh
brew install xcodegen
swift test
Scripts/build.sh
open build/LiteZip.app
```

可直接打开提交的 `LiteZip.xcodeproj`。核心是独立的 `LiteZipCore` Swift Package。内置引擎已随源代码提供，最终用户无需 Homebrew。

```sh
LITEZIP_LARGE_TESTS=1 swift test  # 包括真实 1 GiB 文件的流式往返，需可用磁盘空间
```

## 签名与公证

开发预览构建可以使用自己的 Developer ID 证书：

```sh
export LITEZIP_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
Scripts/sign.sh
```

签名脚本依次签名内置引擎、Finder 扩展和 App，启用 Hardened Runtime 和安全时间戳，验证后生成 ZIP 与 SHA-256 校验值。证书与私钥不进入仓库。

**本次本地构建已完成 Developer ID 签名，尚未完成 Apple 公证。** 从网络下载后可能被 Gatekeeper 拦截；这不是已通过全部发布门禁的 v1.0。正式分发前需使用自己的公证凭据完成：

```sh
export LITEZIP_NOTARY_PROFILE='your-saved-keychain-profile'
Scripts/notarize.sh
```

GitHub Actions 的构建产物为未签名开发构建。

## 实现与边界

解压由内置 7-Zip 输出文件字节流，由 LiteZip 在私有临时目录内写入普通文件。引擎不能指定任意落盘路径。每个文件使用独占创建与 `O_NOFOLLOW`，成功后采用不覆盖的原子重命名。

这版优先验证安全性。逐文件解压对包含很多文件或采用 Solid 压缩的 7Z 速度较慢，尚未完成 10–100 GB 或 10 万文件性能验收。7-Zip 文本目录不能安全表达的换行文件名或多行元数据会被拒绝。BZIP2 等无法提前获取展开大小的格式会在实际写入时限额，进度为不定进度。

主应用是 Developer ID 分发版本，**未启用 App Sandbox**；Finder 扩展启用 Sandbox。尚未实现 Mac App Store 的完整 security-scoped bookmark 权限流程。

macOS 资源分叉、扩展属性、权限和时间戳的完整保留尚未保证。符号链接与硬链接暂时拒绝。解压总是建立独立文件夹；不提供原地覆盖或删除源文件。

详见 [技术决策与路线图](docs/DEVELOPMENT.md) 和 [验证记录](docs/VALIDATION.md)。

## License

LiteZip 自有代码为 MIT。内置 7-Zip 按 LGPL 和 unRAR 限制分发，Zstandard 使用 BSD 许可；测试用 RAR 样本来自 libarchive。对应许可、版本、来源和构建说明见 [Vendor](Vendor/README.md) 与 [ThirdPartyNotices](Resources/ThirdPartyNotices.txt)。

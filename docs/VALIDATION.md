# 0.1.0 验证记录

## 自动测试

`LITEZIP_LARGE_TESTS=1 swift test`：15 组测试全部通过，包括参数化格式与安全案例。

- ZIP、7Z、TAR、TAR.GZ、GZIP、BZIP2、XZ、ZSTD 往返与引擎完整性校验。
- 多级目录、中文与 Emoji 文件名、隐藏文件、零字节文件、空 ZIP、标准 TAR 的 `./` 路径。
- ZIP ASCII 密码与 7Z 中文／Emoji／长密码；错误密码不发布结果，Unicode ZIP 密码给出明确错误。
- `@`、`*`、`-` 开头等特殊文件名的字面量处理。
- 越界路径、绝对路径、反斜杠、大小写重名、换行名称、符号链接、硬链接、FIFO 拒绝。
- 展开限制、损坏／截断、取消与临时文件清理、重复输出自动编号。
- libarchive 上游 RAR4 和 RAR5 压缩样本的真实解压与校验。
- 1 GiB 零字节填充的稀疏源文件，流式压缩与解压并校验展开文件尺寸。数据高度可压缩，不代表随机数据吞吐性能。

应用和核心使用 Swift 6 编译；Release 配置无应用源码编译警告。Xcode 对无 AppIntents 依赖的目标产生元数据跳过提示，未使用此框架。

## 构建与签名

- App、Finder 扩展、7zz、zstd 均为 arm64 + x86_64 universal Mach-O。
- Apple Silicon 原生实测；7zz 的 x86_64 slice 已通过 Rosetta 启动检查；Intel 真机未验收。
- Developer ID 签名含 Hardened Runtime 与时间戳；`codesign --verify --deep --strict` 通过。
- 证书只从本机 Keychain 调用，仓库不包含证书、私钥或公证凭据。
- **未公证**：`spctl` 返回 `Unnotarized Developer ID`。尚未满足正式发布 Gatekeeper 门禁。
- Finder 扩展的 `NSExtensionPointIdentifier` 和应用版本由构建脚本校验，扩展可由 `pluginkit` 注册。

## 原生界面实测

- 主窗口浅色／深色显示、⌘O、文件选择面板、选择后自动进入压缩。
- 保存压缩包，任务显示完成，生成文件经引擎校验通过。
- 使用文件打开事件自动解压，解压内容与原文件一致。
- 压缩包浏览器读取真实目录、显示尺寸、运行完整性校验并显示成功。
- 设置中切换深色与跟随系统主题，恢复跟随系统默认值。
- 标准面板作为 sheet 显示并保留到操作结束，修复早期面板生命周期问题。
- Finder 扩展真实右键菜单、快速压缩、解压到独立文件夹，结果内容一致。
- 修复扩展所需的 `NSExtensionAttributes` 元数据，以及 Sandbox 中真实用户主目录的定位。

## 尚未验收

10–100 GB 数据、10 万小文件、峰值内存基线、冷启动目标、真实低磁盘与权限拒绝、资源分叉／扩展属性、最低系统版本真机、全键盘与 VoiceOver、完整本地化、App Store Sandbox、Apple 公证。

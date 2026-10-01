# LiteZip 文件图标

15 种 Finder 文稿图标，使用与 App 相同的蓝色角色、奶油白文件和睁眼表情。角色压紧文件的动作保持一致，底部的大写名称区分格式。

`Sources/` 保存内置图像生成工具逐张生成的透明 PNG 原稿；`Document-*.png` 是 1024 像素导出；`../DocumentTypes/` 是包含 16–1024 像素表示的 ICNS。`formats.json` 是格式清单；完整提示词见 `generation-prompts.md`。菜单改用 `ArchiveFormatIcons.swift` 原生绘制的彩色格式名称徽章，不再缩小角色文稿图。

重新导出：`swift Scripts/export-document-icons.swift`。导出后运行 `Scripts/build.sh`，Xcode 会把 Finder 图标装入 App，并从 `project.yml` 生成各格式的文稿声明。徽章直接由 App 的矢量绘图生成，每种格式使用不同的背景色、白色文字，统一为 70 × 22 点。

Finder 依据文件的内容类型及默认打开应用选择图标。项目使用 Alternate 处理程序优先级，安装不会覆盖用户现有的默认打开应用。将某类压缩文件设置为用 LiteZip 默认打开后，Finder 才会选用对应的文稿图标。`.tar.gz` 等复合后缀可能由系统识别为外层 GZIP；TGZ/TBZ2/TXZ/TZST 有独立类型和图标。ZIPX 图标仅表示解压支持，不添加 ZIPX 压缩能力。

macOS 26 及以上的工具栏使用原生 `glassEffect(.regular.interactive(), in: Capsule())`；macOS 13–15 使用标准半透明材质回退。每个控件只有一层与内容尺寸一致的材质，没有额外外圈阴影。

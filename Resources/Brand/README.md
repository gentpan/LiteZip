# LiteZip 品牌图标

采用选定的蓝色角色：双手压紧文件，睁眼注视文件。

- `litezip-logo-source.png`：保留透明背景的原始生成图。
- `litezip-logo.png`：1024 × 1024 透明 PNG，官网 Logo 与 App 图标的共同母版。
- `litezip-mac-icon-source.png`：生成的蓝色铺满画布图稿。
- `litezip-mac-icon.png`：1024 × 1024 不透明 Mac 图标母版。蓝色角色直接延伸到画布边缘，圆角由系统处理。
- `../AppIcon.icon/`：Icon Composer 图标，Xcode 编译为现代图标资源与旧系统兼容图标。
- `../AppIcon.icns`：从实际构建包导出的兼容图标。

运行 `Scripts/build.sh`，由 Xcode 编译 `AppIcon.icon`，并将实际 App 包里的兼容 `.icns` 同步到 `Resources/AppIcon.icns`。现代 macOS 使用 `Assets.car` 中的图标栈，避免透明 Logo 被系统缩进灰白底板。

`Scripts/export-brand.py` 额外导出编译后的 iconset、官网 PNG/WebP 和真实界面截图，运行需要 Pillow。`Scripts/make-icon.swift` 仅用于导出原始画布的多尺寸 PNG，不参与 App 构建。

图标保持现有配色、角色轮廓、文件堆和睁眼表情，只移除原图的外部浅色背景，并保留边缘与接触阴影。

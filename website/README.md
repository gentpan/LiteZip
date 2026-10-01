# LiteZip 官网

静态中文官网，发布文件位于 `dist/`。无需安装前端依赖。

生成反馈页、更新日志与站点地图：

```sh
python3 scripts/build-pages.py
```

更新日志读取仓库根目录的 `CHANGELOG.md`，页面导航和页脚复用首页。每次部署会自动重新生成。修改反馈内容请编辑 `templates/feedback.html`，生成后的页面无需手工修改。

本地预览：

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory dist
```

打开 http://127.0.0.1:4173/。

- `dist/index.html`：页面内容、FAQ 与下载链接。
- `dist/styles.css`：桌面与手机布局。
- `dist/site.js`：真实界面主题预览、压缩与解压格式切换。
- `templates/feedback.html`：反馈表单与 GitHub Issues 入口，生成到 `dist/feedback/index.html`。
- `dist/changelog/index.html`：从 `CHANGELOG.md` 生成的版本记录与发布说明链接。
- `scripts/build-pages.py`：生成两个子页面及 `sitemap.xml`。
- `dist/assets/`：透明 Logo 与真实 App 截图。
- `.openai/hosting.json`：已有 Sites 项目绑定；当前官网使用下述服务器部署。

反馈表单会将标题、描述、复现步骤和版本信息编码到 GitHub 新建 Issue 的链接中，由用户登录 GitHub 后确认发布；无需 GitHub Token 或反馈后端。较长内容提供复制正文入口，避免超出 URL 长度限制。关闭 JavaScript 时仍可通过页面入口直接在 GitHub 反馈。

当前下载入口指向 GitHub 的 0.5.0 开发预览版。官网格式说明、更新日志与下载入口同步到该版本。

官网域名：`https://litezip.app/`，服务器：`51.38.126.148`。服务器使用 Caddy，站点配置为 `/etc/caddy/sites/litezip.app.caddy`，文件使用 `/var/www/litezip.app/releases/` 和 `current` 链接进行原子切换。HTTPS 证书由 Caddy 自动申请和续期，`www` 跳转到主域名。

重新部署：`bash deploy/deploy-server.sh`。默认使用桌面的 `gentpan.pem` 和 SSH 22 端口；可以用 `LITEZIP_DEPLOY_KEY`、`LITEZIP_DEPLOY_HOST`、`LITEZIP_DEPLOY_PORT` 覆盖。私钥不进入代码仓库或上传到服务器。配置验证或重载失败时脚本会恢复旧配置与站点链接。

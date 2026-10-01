const screenshot = document.getElementById('app-screenshot');
document.querySelectorAll('[data-preview-theme]').forEach(button => {
  button.addEventListener('click', () => {
    const dark = button.dataset.previewTheme === 'dark';
    screenshot.src = `assets/app-${dark ? 'dark' : 'light'}.webp`;
    screenshot.alt = `LiteZip ${dark ? '深色' : '浅色'}界面的真实截图`;
    document.querySelectorAll('[data-preview-theme]').forEach(item => item.setAttribute('aria-pressed', String(item === button)));
  });
});
const formatDescriptions = {
  compress: {ZIP:'日常打包，支持 AES 加密与分卷。', '7Z':'支持加密文件名、中文密码与分卷。', RAR:'创建需要连接本机官方 RAR 引擎。', DMG:'制作只读磁盘映像，支持 AES-256 加密。', TAR:'支持 TAR.GZ、TAR.BZ2、TAR.XZ、TAR.ZST。', STREAM:'适合单个文件，轻松压缩与解压。', ISO:'制作 ISO9660 / Joliet / UDF 映像，支持 Finder 挂载。', AAR:'使用 Mac 原生 Apple Archive 打包文件与文件夹。', WIM:'制作 Windows Imaging 归档，支持目录预览与解压。', LZIP:'单文件压缩，保留源文件，支持校验与解压。', LZ4:'适合快速处理的单文件压缩格式。', BROTLI:'单文件 Brotli 压缩，生成 .br 文件。', LRZIP:'处理单个文件，适合重复内容较多的数据。', SNAPPY:'快速单文件压缩，使用标准 framed 格式。'},
  extract: {ZIP:'解压、预览与校验，支持 AES 加密包及分卷。', '7Z':'解压、预览与校验，支持加密包与分卷。', RAR:'RAR / RAR5 解压已内置，无需安装额外引擎。', DMG:'只读预览、内容搜索、校验与 Finder 挂载。', TAR:'预览与解压 TAR 及常用压缩 TAR 格式。', STREAM:'解压 GZIP、BZIP2、XZ 与 Zstandard 文件。', ISO:'预览、校验与解压，也可以在 Finder 挂载。', AAR:'原生读取 Apple Archive，支持预览、校验与解压。', WIM:'预览、校验与解压 WIM 归档中的文件。', LZIP:'预览、校验与解压 .lz / .lzip 文件。', LZ4:'预览、校验与解压标准 LZ4 文件。', BROTLI:'通过 .br / .brotli 扩展名识别并解压。', LRZIP:'预览、校验与解压 .lrz / .lrzip 文件。', SNAPPY:'预览、校验与解压 Snappy framed 文件。', ZIPX:'支持解压、内容预览与完整性校验。'}
};
document.querySelectorAll('[data-format-mode]').forEach(button => {
  button.addEventListener('click', () => {
    const mode = button.dataset.formatMode;
    document.querySelectorAll('[data-format-mode]').forEach(item => item.setAttribute('aria-pressed', String(item === button)));
    document.querySelectorAll('[data-format]').forEach(card => {
      const description = formatDescriptions[mode][card.dataset.format];
      card.hidden = !description;
      if (description) card.querySelector('p').textContent = description;
    });
    document.getElementById('format-note').textContent = mode === 'compress' ? 'RAR 解压已内置；创建 RAR 需单独安装并连接官方引擎。' : 'DMG 通过系统只读挂载预览；ZIPX 支持情况取决于内置引擎支持的压缩方法。';
  });
});

const feedbackForm = document.getElementById('feedback-form');
if (feedbackForm) {
  const type = feedbackForm.elements.type;
  const title = feedbackForm.elements.title;
  const description = feedbackForm.elements.description;
  const result = document.getElementById('feedback-result');
  const status = document.getElementById('feedback-status');
  const copyArea = document.getElementById('feedback-copy');
  const bodyField = document.getElementById('feedback-body');
  const submitLink = document.getElementById('github-submit');
  const kinds = {
    bug: {name: '问题反馈', heading: '问题描述', placeholder: '发生了什么？你原本期望的结果是什么？'},
    feature: {name: '功能建议', heading: '建议内容', placeholder: '你希望增加或改进什么？它会帮助你解决什么问题？'},
    question: {name: '使用咨询', heading: '咨询内容', placeholder: '你想了解哪个功能？已经尝试了哪些操作？'}
  };
  feedbackForm.hidden = false;
  type.addEventListener('change', () => {
    document.getElementById('description-label').firstChild.textContent = `${kinds[type.value].heading} `;
    description.placeholder = kinds[type.value].placeholder;
    document.getElementById('steps-field').hidden = type.value !== 'bug';
  });
  feedbackForm.addEventListener('input', () => {
    title.setCustomValidity('');
    description.setCustomValidity('');
    result.hidden = true;
  });
  feedbackForm.addEventListener('submit', event => {
    event.preventDefault();
    title.setCustomValidity(title.value.trim() ? '' : '请填写反馈标题。');
    description.setCustomValidity(description.value.trim() ? '' : '请填写反馈内容。');
    if (!feedbackForm.reportValidity()) return;
    const kind = kinds[type.value];
    const value = name => feedbackForm.elements[name].value.trim() || '未填写';
    const parts = [`## ${kind.heading}`, description.value.trim()];
    if (type.value === 'bug') parts.push('## 复现步骤', value('steps'));
    parts.push('## 使用环境', `- LiteZip 版本：${value('version')}\n- macOS 版本：${value('macos')}`, '---\n通过 LiteZip 官网反馈页整理。');
    const body = parts.join('\n\n');
    const url = new URL('https://github.com/gentpan/LiteZip/issues/new');
    url.searchParams.set('title', `[${kind.name}] ${title.value.trim()}`);
    url.searchParams.set('body', body);
    // Keep large reports out of URL length limits; preserve the full text for copying.
    const needsCopy = url.href.length > 7000;
    if (needsCopy) url.searchParams.delete('body');
    submitLink.href = url.href;
    bodyField.value = body;
    copyArea.hidden = !needsCopy;
    document.getElementById('copy-status').textContent = '';
    status.textContent = needsCopy
      ? '内容较长，请先复制下方正文，再前往 GitHub 粘贴并提交；标题会自动填入。'
      : '标题和内容会自动填入 GitHub。登录后，你可以补充截图并确认提交。';
    result.hidden = false;
    (needsCopy ? document.getElementById('copy-feedback') : submitLink).focus();
  });
  document.getElementById('copy-feedback').addEventListener('click', async () => {
    const copyStatus = document.getElementById('copy-status');
    try {
      await navigator.clipboard.writeText(bodyField.value);
      copyStatus.textContent = '已复制，可以前往 GitHub 粘贴。';
    } catch {
      bodyField.focus();
      bodyField.select();
      copyStatus.textContent = '请按 ⌘C（Windows 使用 Ctrl+C）复制选中的正文。';
    }
  });
}

#!/usr/bin/env python3
"""Generate static pages from the homepage shell and the repository changelog."""
from html import escape
from pathlib import Path
import re

SITE = Path(__file__).resolve().parents[1]
DIST = SITE / "dist"
REPO_URL = "https://github.com/gentpan/LiteZip"
homepage = (DIST / "index.html").read_text()
header = re.search(r'<header\b.*?</header>', homepage, re.S).group()
footer = re.search(r'<footer\b.*?</footer>', homepage, re.S).group()


def write_page(slug, title, description, content):
    head = re.search(r'<head>.*?</head>', homepage, re.S).group()
    head = re.sub(r'<title>.*?</title>', f'<title>{escape(title)} — LiteZip</title>', head)
    head = re.sub(r'(<meta (?:name="description"|property="og:description") content=")[^"]*',
                  lambda m: m[1] + escape(description, quote=True), head)
    head = re.sub(r'(<meta property="og:title" content=")[^"]*',
                  lambda m: m[1] + escape(title + " — LiteZip", quote=True), head)
    head = head.replace('https://litezip.app/"', f'https://litezip.app/{slug}/"')
    shell = header.replace(f'href="/{slug}/"', f'href="/{slug}/" aria-current="page"')
    page = f'<!doctype html>\n<html lang="zh-CN">\n{head}\n<body>\n'
    page += f'  <a class="skip-link" href="#main">跳到正文</a>\n{shell}\n'
    page += f'  <main id="main">\n{content}\n  </main>\n{footer}\n</body>\n</html>\n'
    page = page.replace('="assets/', '="/assets/').replace('="styles.css"', '="/styles.css"').replace('="site.js"', '="/site.js"')
    target = DIST / slug / "index.html"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(page)


def render_notes(lines):
    """The changelog uses plain paragraphs and bullet lists; escape all source text."""
    result, bullets, paragraph = [], [], []

    def inline(text):
        return re.sub(r'`([^`]+)`', r'<code>\1</code>', escape(text))

    def flush():
        if bullets:
            result.append('<ul>' + ''.join(f'<li>{inline(item)}</li>' for item in bullets) + '</ul>')
            bullets.clear()
        if paragraph:
            result.append('<p class="release-note">' + inline(' '.join(paragraph)) + '</p>')
            paragraph.clear()

    for line in lines:
        if line.startswith('- '):
            if paragraph:
                flush()
            bullets.append(line[2:])
        elif not line.strip():
            flush()
        else:
            if bullets:
                flush()
            paragraph.append(line)
    flush()
    return '\n'.join(result)


def changelog_content():
    source = (SITE.parent / "CHANGELOG.md").read_text()
    sections = re.split(r'^## (.+)\n', source, flags=re.M)
    releases, navigation = [], []
    for index in range(1, len(sections), 2):
        heading = sections[index]
        version = re.match(r'(\d+\.\d+\.\d+)', heading)
        if not version:
            raise ValueError(f"Expected a version heading: {heading}")
        version = version[1]
        channel = escape(heading[len(version):].strip() or '版本更新')
        anchor = 'v' + version.replace('.', '-')
        navigation.append(f'<a href="#{anchor}"><span>{escape(version)}</span><span>{channel}</span></a>')
        latest = '<span class="release-badge">最新记录</span>' if index == 1 else ''
        releases.append(f'''<article class="release" id="{anchor}" aria-labelledby="{anchor}-title">
          <div class="release-heading"><div><p class="release-channel">{channel}</p><h2 id="{anchor}-title">{escape(version)} {latest}</h2></div><a class="text-link" href="{REPO_URL}/releases/tag/v{version}" target="_blank" rel="noopener">GitHub 发布说明 ↗</a></div>
          {render_notes(sections[index + 1].strip().splitlines())}
        </article>''')
    if not releases:
        raise ValueError("No releases found in CHANGELOG.md")
    return f'''<section class="page-intro wrap" aria-labelledby="page-title">
      <p class="eyebrow">每一次改进，都留个记录。</p>
      <h1 id="page-title">小步向前，<br><span>越来越顺手。</span></h1>
      <p class="page-description">LiteZip 的新功能、体验改进与问题修复。<br>从最初的版本开始，每一步都在这里。</p>
      <a class="text-link" href="{REPO_URL}/releases" target="_blank" rel="noopener">查看全部 GitHub Releases ↗</a>
    </section>
    <div class="changelog-layout wrap">
      <aside class="release-sidebar"><nav aria-label="版本导航"><p class="feature-number">版本记录</p>{''.join(navigation)}</nav><p>发现问题，或有新的想法？<br><a class="text-link" href="/feedback/">告诉我们 →</a></p></aside>
      <section class="release-list" aria-label="更新日志">{''.join(releases)}</section>
    </div>'''


write_page("feedback", "用户反馈", "向 LiteZip 反馈问题、提出功能建议或咨询使用问题，通过 GitHub Issues 跟进处理进展。", (SITE / "templates/feedback.html").read_text())
write_page("changelog", "更新日志", "查看 LiteZip 的版本更新记录、新功能、体验改进和问题修复，以及 GitHub 发布说明。", changelog_content())
urls = '\n'.join(f'  <url><loc>https://litezip.app/{slug}</loc></url>' for slug in ('', 'feedback/', 'changelog/'))
(DIST / "sitemap.xml").write_text(f'<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n{urls}\n</urlset>\n')
print("Generated feedback, changelog and sitemap.")

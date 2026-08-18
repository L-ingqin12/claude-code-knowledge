#!/usr/bin/env bash
# ============================================================
# fetch-wechat-article.sh — 微信公众号文章抓取与归档工具 v2
# ============================================================
# 用法:
#   ./fetch-wechat-article.sh <url>                      输出 markdown 到 stdout
#   ./fetch-wechat-article.sh <url> --save <dir>         保存原始 .md 到指定目录
#   ./fetch-wechat-article.sh <url> --json               输出 JSON 格式（含元数据+正文）
#
# 依赖: python3
# ============================================================

set -euo pipefail

URL="${1:-}"
OUTPUT_MODE="${2:-stdout}"
SAVE_DIR="${3:-.}"

usage() {
    cat <<'EOF'
用法: fetch-wechat-article.sh <url> [--save <dir> | --json]

  url             微信公众号文章链接 (mp.weixin.qq.com)
  --save <dir>    保存原始 markdown 到指定目录
  --json          输出 JSON 格式 (含 title/author/date/body)
  --help          显示此帮助

示例:
  fetch-wechat-article.sh "https://mp.weixin.qq.com/s/xxxxx"
  fetch-wechat-article.sh "https://mp.weixin.qq.com/s/xxxxx" --save ./articles/
  fetch-wechat-article.sh "https://mp.weixin.qq.com/s/xxxxx" --json
EOF
    exit 0
}

[[ -z "$URL" || "$URL" == "--help" || "$URL" == "-h" ]] && usage

case "${2:-}" in
    --save)  OUTPUT_MODE="save"; SAVE_DIR="${3:-.}" ;;
    --json)  OUTPUT_MODE="json" ;;
esac

export FETCH_URL="$URL"
export FETCH_MODE="$OUTPUT_MODE"
export FETCH_SAVE_DIR="$SAVE_DIR"

# ---- 抓取+解析一体化（Python urllib，绕过微信反爬） ----
python3 <<'PYEOF'
import urllib.request, ssl, re, html as html_mod, json, os
from datetime import datetime, date

url         = os.environ.get('FETCH_URL', '')
output_mode = os.environ.get('FETCH_MODE', 'stdout')
save_dir    = os.environ.get('FETCH_SAVE_DIR', '.')

# ---- 抓取 ----
UA = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/[IP已脱敏] Mobile Safari/537.36"
req = urllib.request.Request(url, headers={
    "User-Agent": UA,
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
})
ctx = ssl.create_default_context()
try:
    resp = urllib.request.urlopen(req, context=ctx, timeout=15)
    content = resp.read().decode('utf-8', errors='replace')
except Exception as e:
    print(f'{{"error": "fetch failed: {e}"}}', file=sys.stderr)
    sys.exit(1)

# ---- 元数据提取（多级回退） ----
def extract_var(name, default=""):
    m = re.search(rf'var\s+{name}\s*=\s*"(.*?)"', content)
    return html_mod.unescape(m.group(1)) if m else default

# 标题：优先 rich_media_title → msg_title → title 变量
title = ""
m = re.search(r'rich_media_title[^>]*>(.*?)</h', content, re.DOTALL)
if m:
    title = html_mod.unescape(re.sub(r'<[^>]+>', '', m.group(1))).strip()
if not title:
    title = extract_var('msg_title')
if not title:
    title = extract_var('title')
if not title:
    m = re.search(r'<title>(.*?)</title>', content, re.DOTALL)
    if m: title = html_mod.unescape(m.group(1)).strip()

# 作者：多模式回退
nickname = extract_var('nickname')
if not nickname:
    nickname = extract_var('nick_name')
if not nickname:
    m = re.search(r'data-nickname="(.*?)"', content)
    if m: nickname = html_mod.unescape(m.group(1))
if not nickname:
    m = re.search(r'<meta\s+name="author"\s+content="(.*?)"', content)
    if m: nickname = html_mod.unescape(m.group(1))
if not nickname:
    m = re.search(r'profile_nickname\s*=\s*"(.*?)"', content)
    if m: nickname = html_mod.unescape(m.group(1))
if not nickname:
    # 宽松匹配：脚本中 nickname="xxx" 或 nickname = "xxx"
    m = re.search(r'nickname["\']?\s*[:=]\s*["\']([^"\']{1,30})["\']', content)
    if m: nickname = html_mod.unescape(m.group(1))

ct = extract_var('ct', '')
date_str = ""
if ct:
    try:
        date_str = datetime.fromtimestamp(int(ct)).strftime('%Y-%m-%d')
    except:
        pass

# ---- 正文提取 ----
# 先找 js_content
body_m = re.search(r'id="js_content"[^>]*>(.*?)</div>\s*<script', content, re.DOTALL)
if not body_m:
    body_m = re.search(r'id="js_content"[^>]*>(.*?)</div>', content, re.DOTALL)

body = ""
if body_m:
    body = body_m.group(1)
    # 先转换块级元素为换行
    body = re.sub(r'<br\s*/?>', '\n', body, flags=re.IGNORECASE)
    body = re.sub(r'</p>', '\n\n', body, flags=re.IGNORECASE)
    body = re.sub(r'</div>', '\n', body, flags=re.IGNORECASE)
    body = re.sub(r'</h[1-6]>', '\n\n', body, flags=re.IGNORECASE)
    body = re.sub(r'</li>', '\n', body, flags=re.IGNORECASE)
    body = re.sub(r'</tr>', '\n', body, flags=re.IGNORECASE)
    body = re.sub(r'</section>', '\n', body, flags=re.IGNORECASE)
    # 移除 script/style
    body = re.sub(r'<script[^>]*>.*?</script>', '', body, flags=re.DOTALL)
    body = re.sub(r'<style[^>]*>.*?</style>', '', body, flags=re.DOTALL)
    # 移除剩余 HTML 标签
    body = re.sub(r'<[^>]+>', '', body)
    # 解码实体
    body = html_mod.unescape(body)
    body = body.replace('\xa0', ' ')
    body = body.replace('​', '')
    # 压缩多余空行
    body = re.sub(r'[ \t]+\n', '\n', body)
    body = re.sub(r'\n{3,}', '\n\n', body)
    body = body.strip()

if not body:
    print('{"error": "no article content found in page"}', file=sys.stderr)
    sys.exit(1)

# ---- 输出 ----
if output_mode == 'json':
    out = {
        'title': title,
        'author': nickname,
        'date': date_str,
        'url': url,
        'body': body,
        'char_count': len(body)
    }
    print(json.dumps(out, ensure_ascii=False, indent=2))
    sys.exit(0)

# 生成文件名：优先用中文原标题，限制长度
def make_slug(t):
    # 保留中英文数字，其余转连字符
    s = re.sub(r'[^\w一-鿿　-〿＀-￯-]', '', t)
    s = re.sub(r'[-\s]+', '-', s)
    return s.strip('-')[:50] or 'wechat-article'

slug = make_slug(title)
filename = f"{slug}.md"

# 生成 markdown
fetched = date.today().isoformat()
md = f"""---
title: "{title}"
source: "微信公众号"
source_url: "{url}"
author: "{nickname}"
date: "{date_str}"
fetched_at: "{fetched}"
---

# {title}

> 来源: {nickname} · {date_str}
> 原文: {url}

{body}
"""

if output_mode == 'save':
    os.makedirs(save_dir, exist_ok=True)
    filepath = os.path.join(save_dir, filename)
    with open(filepath, 'w', encoding='utf-8') as f:
        f.write(md)
    print(f"Saved: {filepath}")
    print(f"Title: {title}")
    print(f"Author: {nickname}")
    print(f"Date: {date_str}")
    print(f"Chars: {len(body)}")
else:
    print(md)
PYEOF

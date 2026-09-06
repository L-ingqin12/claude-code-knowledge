#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sanitize-session.py — 剪除触发 DeepSeek 400 内容审核的会话敏感 token。

只做整行原始文本的子串脱敏：**绝不删行、不改 uuid / tool_use↔tool_result 配对**，
因此 JSON 结构天然不坏；改后逐行校验 + 结构指纹前后对比，任一不一致即回滚。

触发词来源运行时现读（自动维护，新节点自动进表）：
  - node-pool.txt / proxy-nodes.json  节点 host（本脚本同目录）
  - sanitize-extra.txt                 话题词（--mode aggressive 才启用）

用法:
  python sanitize-session.py                 # 脱敏当前目录最近会话（safe，自动备份）
  python sanitize-session.py --check         # 只读扫描，只报命中行数（不输出内容）
  python sanitize-session.py --session <id>  # 指定会话 id（支持前缀）
  python sanitize-session.py --mode aggressive   # 额外套话题词 + scheme:// 链接清洗
  python sanitize-session.py --replace-str '<占位>'  # 自定义占位符

依赖: 全局解释器 D:\\ProgramData\\miniconda3\\python.exe（Py 3.13）
"""

import argparse
import json
import os
import re
import shutil
import sys
import time

# Windows 控制台中文输出（避免 GBK 乱码）
try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

PLACEHOLDER = "[节点已脱敏]"
LINK_PLACEHOLDER = "[链接已脱敏]"
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


# ---------------------------------------------------------------------------
# 触发词来源
# ---------------------------------------------------------------------------

def load_host_tokens():
    """从 node-pool.txt + proxy-nodes.json 提取 host token（长→短，去重）。"""
    tokens = set()

    pool = os.path.join(SCRIPT_DIR, "node-pool.txt")
    if os.path.exists(pool):
        for line in open(pool, encoding="utf-8"):
            line = line.strip().lower()
            if not line or line.startswith("#"):
                continue
            host = line.split(":")[0].strip()
            if host:
                tokens.add(host)

    pn = os.path.join(SCRIPT_DIR, "proxy-nodes.json")
    if os.path.exists(pn):
        try:
            data = json.load(open(pn, encoding="utf-8"))

            def add_host(s):
                if not isinstance(s, str):
                    return
                s = s.strip().lower()
                if not s:
                    return
                if "://" in s:
                    s = s.split("://", 1)[1]
                s = s.split("/", 1)[0].split(":", 1)[0].split("@", 1)[-1]
                if s:
                    tokens.add(s)

            def walk(obj):
                if isinstance(obj, dict):
                    for k, v in obj.items():
                        if k in ("address", "host", "sni", "domain", "server"):
                            add_host(v)
                        else:
                            walk(v)
                elif isinstance(obj, list):
                    for v in obj:
                        walk(v)
                elif isinstance(obj, str):
                    add_host(obj)

            walk(data)
        except Exception:
            pass

    # 过滤：长度 >=4 且含字母，避免误伤纯数字/短词
    out = set()
    for t in tokens:
        if len(t) >= 4 and any(c.isalpha() for c in t):
            out.add(t)
    return sorted(out, key=len, reverse=True)


def load_topic_words():
    f = os.path.join(SCRIPT_DIR, "sanitize-extra.txt")
    if not os.path.exists(f):
        return []
    return [l.strip() for l in open(f, encoding="utf-8")
            if l.strip() and not l.lstrip().startswith("#")]


def host_pattern(token):
    return re.compile(
        r"(?<![A-Za-z0-9])" + re.escape(token) + r"(?::\d{1,5})?(?![A-Za-z0-9])",
        re.IGNORECASE,
    )


def sanitize_line(line, host_pats, topic_pats, placeholder, scrub_urls):
    hits = 0
    new = line
    for p in host_pats:
        new, n = p.subn(placeholder, new)
        hits += n
    for p in topic_pats:
        new, n = p.subn(placeholder, new)
        hits += n
    if scrub_urls:
        new, n = re.subn(r"\S+://\S+", LINK_PLACEHOLDER, new)
        hits += n
    return new, hits


# ---------------------------------------------------------------------------
# 会话定位
# ---------------------------------------------------------------------------

def encode_dir(path):
    return re.sub(r"[^A-Za-z0-9]", "-", os.path.abspath(path))


def resolve_session(session_id, cwd):
    base = os.path.join(os.path.expanduser("~"), ".claude", "projects")
    if session_id:
        for root, _dirs, files in os.walk(base):
            for fn in files:
                if fn.startswith(session_id) and fn.endswith(".jsonl"):
                    return os.path.join(root, fn)
        return None
    proj = os.path.join(base, encode_dir(cwd))
    if not os.path.isdir(proj):
        return None
    js = [os.path.join(proj, f) for f in os.listdir(proj)
          if f.endswith(".jsonl") and not f.startswith(".")]
    return max(js, key=os.path.getmtime) if js else None


# ---------------------------------------------------------------------------
# 结构指纹（保 tool_use↔tool_result 配对）
# ---------------------------------------------------------------------------

def struct_fingerprint(lines):
    types = {}
    tool_ids = set()
    result_ids = set()
    for line in lines:
        try:
            d = json.loads(line)
        except Exception:
            continue
        t = d.get("type", "?")
        types[t] = types.get(t, 0) + 1
        msg = d.get("message") or {}
        content = msg.get("content")
        if isinstance(content, list):
            for blk in content:
                if isinstance(blk, dict) and blk.get("type") == "tool_use" and blk.get("id"):
                    tool_ids.add(blk["id"])
                if isinstance(blk, dict) and blk.get("type") == "tool_result" and blk.get("tool_use_id"):
                    result_ids.add(blk["tool_use_id"])
        tur = d.get("toolUseResult")
        if isinstance(tur, dict) and tur.get("toolUseId"):
            result_ids.add(tur["toolUseId"])
    return (len(lines), types, tool_ids, result_ids)


def _is_valid_json(line):
    try:
        json.loads(line)
        return True
    except Exception:
        return False


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

def run(args):
    cwd = args.dir or os.getcwd()
    target = resolve_session(args.session, cwd)
    if not target:
        print("✗ 未找到会话 jsonl（用 --session <id> 或 --dir <目录> 指定）")
        return 1

    host_pats = [host_pattern(t) for t in load_host_tokens()]
    topic_pats = ([re.compile(re.escape(w), re.IGNORECASE) for w in load_topic_words()]
                  if args.mode == "aggressive" else [])
    aggressive = args.mode == "aggressive"
    placeholder = args.replace_str or PLACEHOLDER

    lines = open(target, encoding="utf-8").read().splitlines()

    # 只读扫描
    if args.check:
        hit_lines = 0
        hit_total = 0
        for line in lines:
            _, n = sanitize_line(line, host_pats, topic_pats, placeholder, aggressive)
            if n:
                hit_lines += 1
                hit_total += n
        print(f"[check] {target}")
        print(f"  命中行 {hit_lines}/{len(lines)}，命中 token 总数 {hit_total}（不输出内容）")
        return 0

    # 锁探针：会话未退出则文件被占用
    try:
        probe = target + ".probe"
        with open(probe, "w", encoding="utf-8"):
            pass
        os.remove(probe)
    except PermissionError:
        print("✗ 会话文件被占用（Claude Code 仍打开该会话），请先退出再运行")
        return 1

    fp_before = struct_fingerprint(lines)

    changed = 0
    total_hits = 0
    for i, line in enumerate(lines):
        new, n = sanitize_line(line, host_pats, topic_pats, placeholder, aggressive)
        if not n:
            continue
        if _is_valid_json(line) and not _is_valid_json(new):
            print(f"  ⚠ 第 {i + 1} 行脱敏后 JSON 校验失败，跳过")
            continue
        lines[i] = new
        changed += 1
        total_hits += n

    if struct_fingerprint(lines) != fp_before:
        print("✗ 结构指纹变化，中止（未写文件）。请人工检查。")
        return 2

    if total_hits == 0:
        print(f"✓ 无命中，无需改动：{target}")
        return 0

    backup = f"{target}.pre-sanitize-{int(time.time())}"
    shutil.copy2(target, backup)
    tmp = target + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        f.write("\n".join(lines) + ("\n" if lines else ""))
    os.replace(tmp, target)

    print(f"✓ 已脱敏 {changed} 行 / {total_hits} 处 → {target}")
    print(f"  备份: {os.path.basename(backup)}")
    print(f"  恢复: 会话原目录执行 claude --continue（用不涉敏措辞续聊）")
    return 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="剪除触发 DeepSeek 400 内容审核的会话敏感 token")
    ap.add_argument("--session", help="会话 id（支持前缀）")
    ap.add_argument("--dir", help="工作目录（默认当前目录）")
    ap.add_argument("--mode", choices=["safe", "aggressive"], default="safe")
    ap.add_argument("--replace-str", help="自定义占位符")
    ap.add_argument("--check", action="store_true", help="只读扫描，只报命中行数")
    sys.exit(run(ap.parse_args()))

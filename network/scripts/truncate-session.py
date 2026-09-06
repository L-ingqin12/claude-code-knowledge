#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""truncate-session.py — 手动截断 Claude Code 会话 JSONL，修复“上下文超限 400”死锁。

适用场景：
  会话 transcript 超过模型 max context（如 DeepSeek 1M），且 /compact 自身也报 400
  （因为 compact 请求仍携带全量历史，同样超限）。此时唯一出路是直接裁剪 transcript。

做法：
  1) 自动备份到 <file>.bak.<timestamp>
  2) 计算尾部安全切割点（只在 type=="user" 行前切，绝不切断一轮对话/tool 往返）
  3) 生成一行 type=="summary" 占位摘要（诚实说明旧历史被截断、未做自动摘要）
  4) 写回：summary 行 + 尾部（内容行 + 交错 meta 行原样保留）

用法：
  python truncate-session.py <session.jsonl> [--keep-tokens 400000] [--dry-run]

会话文件位置：
  ~/.claude/projects/<项目slug>/<session-id>.jsonl
"""
import argparse
import json
import os
import shutil
import sys
import time
import uuid as _uuid

# 不进入 API messages 的 harness 状态行
META = {
    "mode", "permission-mode", "atis-latch", "ai-title", "last-prompt",
    "queue-operation", "cost-state", "file-history-snapshot", "file-history-delta",
}
# DeepSeek 中英混合实测 字符/token 比（用于估算尾部 token 数）
CHARS_PER_TOKEN = 5.88


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("session", help="Claude Code 会话 .jsonl 路径")
    ap.add_argument("--keep-tokens", type=int, default=400000,
                    help="尾部保留目标 token 数（默认 40 万，远低于 1M 上限）")
    ap.add_argument("--dry-run", action="store_true", help="只分析不写入")
    args = ap.parse_args()

    p = os.path.abspath(args.session)
    if not os.path.exists(p):
        print(f"文件不存在: {p}", file=sys.stderr)
        sys.exit(1)

    rows = []  # (lineno, raw, obj)
    with open(p, encoding="utf-8") as f:
        for i, line in enumerate(f):
            raw = line.rstrip("\n")
            if not raw.strip():
                continue
            try:
                obj = json.loads(raw)
            except Exception:
                obj = None
            rows.append((i + 1, raw, obj))

    # 内容行 = 真正进 API messages 的行；按尾部累计字符找 user 边界切割点
    content = [(n, obj.get("type"), len(raw)) for n, raw, obj in rows
               if obj and obj.get("type") not in META]
    cum = 0
    candidates = []  # (lineno, tail_chars_before_line)，从尾向前
    for n, t, _l in reversed(content):
        if t == "user":
            candidates.append((n, cum))
        cum += _l
    total_chars = cum
    target_chars = int(args.keep_tokens * CHARS_PER_TOKEN)

    cut = None
    for n, c in candidates:
        if c >= target_chars:
            cut = n
            break
    if cut is None:
        print(f"目标 {args.keep_tokens} tokens 大于现有历史总量，无需截断。", file=sys.stderr)
        sys.exit(1)

    # leafUuid = 被丢弃的最后一条真实消息的 uuid
    leaf = None
    for n, _raw, obj in rows:
        if n < cut and obj and obj.get("type") in ("user", "assistant") and obj.get("uuid"):
            leaf = obj

    # 摘要行信封：拷贝最后一条带完整信封的行，避免缺字段
    envelope = None
    for _n, _raw, obj in reversed(rows):
        if obj and obj.get("sessionId") and obj.get("uuid"):
            envelope = obj
            break

    summary_text = (
        "[会话历史已手动截断] 原会话过长（约 %.0f 万 tokens），已删除第 1 行至第 %d 行的旧历史"
        "以适配上下文窗口；被删段落未做自动摘要，早期细节已不可见。若早期上下文仍重要，"
        "请向用户复述关键信息后再继续。"
        % (total_chars / CHARS_PER_TOKEN / 10000, cut - 1)
    )

    s = dict(envelope) if envelope else {}
    for k in ("content", "subtype", "level", "message"):
        s.pop(k, None)
    s["type"] = "summary"
    s["summary"] = summary_text
    s["leafUuid"] = leaf.get("uuid") if leaf else None
    s["uuid"] = _uuid.uuid4().hex
    s["parentUuid"] = None
    s["isMeta"] = False
    s["timestamp"] = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())

    tail_raw = [raw for n, raw, obj in rows if n >= cut]
    new_lines = [json.dumps(s, ensure_ascii=False)] + tail_raw
    new_chars = sum(len(l) for l in new_lines)

    print(f"原文件: {p}")
    print(f"  内容行 {len(content)} 行 / 内容字符 {total_chars} "
          f"(~{total_chars / CHARS_PER_TOKEN / 10000:.0f} 万 tokens)")
    print(f"  切割点: 第 {cut} 行（type=user 边界）")
    print(f"  保留尾部 ~{new_chars / CHARS_PER_TOKEN / 10000:.1f} 万 tokens")
    if args.dry_run:
        print("[dry-run] 未写入")
        return

    bak = p + f".bak.{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(p, bak)
    tmp = p + ".trim.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for l in new_lines:
            f.write(l + "\n")
    os.replace(tmp, p)
    print(f"  备份: {bak}")
    print(f"  已写回 {len(new_lines)} 行，新大小 {os.path.getsize(p)} 字节")
    print("  恢复：claude --resume <session-id>  或  claude --continue")


if __name__ == "__main__":
    main()

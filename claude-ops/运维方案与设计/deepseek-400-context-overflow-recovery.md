# DeepSeek 400（上下文超限）修复与预防

> 第三类 DeepSeek 400：**上下文超限**。前两类见 [[deepseek-400-mitigation-design]]（内容审核 + thinking）。
> 本文解决：会话 transcript 超过模型 max context，且 `/compact` 自身也 400 的死锁。

## 现象

```
API Error: 400 This model's maximum context length is 1048576 tokens.
However, you requested 1048877 tokens (1016877 in the messages, 32000 in the completion).
Please reduce the length of the messages or completion.
```

随后 `/compact` 也报同样 400：

```
Error during compaction: API Error: 400 ... requested 1050177 tokens ...
```

**关键特征**：`/compact` 失败 = 死锁。compact 请求本身携带全量历史，历史已超限 → compact 也超限。

## 根因

1. 会话从建立到卡死**从未被压缩过**（transcript 里没有 `type=="summary"` 行）。
2. 模型 max context = 1,048,576（DeepSeek 1M），completion 预留 32,000 → messages 硬上限 ≈ 1,016,576。
3. 自动压缩阈值若配置不当（或 harness 上报的窗口值偏大），会在触达压缩点**之前**就超过上限。

## 修复（手动截断 transcript）

> 直接改写 Claude Code 的会话 transcript（`~/.claude/projects/<slug>/<session-id>.jsonl`），
> 会被 auto-mode 分类器标记为 `Session Transcript Tampering` 拦截。需用户明确确认后放行。

脚本：`network/scripts/truncate-session.py`（与 `sanitize-session.py` 同目录）。

```bash
# 干跑（只分析，不写入）
python truncate-session.py ~/.claude/projects/<slug>/<session-id>.jsonl --dry-run

# 实跑：备份 + 摘要行 + 保留尾部 40 万 tokens
python truncate-session.py ~/.claude/projects/<slug>/<session-id>.jsonl --keep-tokens 400000
```

原理（脚本内部）：
1. 备份 `<file>.bak.<ts>`。
2. 只认「内容行」= 真正进 API messages 的类型（user/assistant/attachment/system），
   meta 行（mode/permission-mode/atis-latch/ai-title/last-prompt/queue-operation/
   cost-state/file-history-*）不占上下文、不参与计数。
3. 从尾部向前累计字符，**只在 `type=="user"` 行边界切**——绝不切断一轮对话/tool 往返。
4. 生成一行 `type=="summary"` 占位摘要（诚实说明「旧历史被截断、未做自动摘要」），
   信封字段从原 transcript 最后一行拷贝，`leafUuid` 指向被丢弃的最后一条真实消息。
5. 写回：`summary` 行 + 尾部（含交错 meta 行，原样保留）。

恢复：`claude --resume <session-id>` 或 `claude --continue`。

实测基准（本次事故）：
- 卡死会话 6.98 MB / 2874 行，其中内容行 1856 行 ≈ 5.98M 字符 ≈ **1,017k tokens**。
- 字符/token ≈ **5.88**（中英混合实测）。
- 切割点取「保留尾部 ≈ 2.36M 字符 ≈ 400k tokens」，留出 ~60 万 tokens 余量继续工作。

## 预防

1. **提前压缩，别等超限**：长会话在 ~60–70% 上限时主动 `/compact`（此时 compact 请求仍能发出去）。
2. **监控 `/context`**：观察当前 tokens，逼近 700–800k 就压缩。
3. **避免往单会话倒大文件**：超大文件内容用文件路径引用，让模型读文件而非粘贴全文。
4. **缩短自动压缩阈值**：若 harness/中继上报的窗口值偏大导致压缩过晚，调低 auto-compact 触发点。
5. **会话卫生**：一个长任务拆成多个会话，用 memory / 知识库承接跨会话上下文，
   而非无限续命同一个 transcript（[[deepseek-400-mitigation-design]] 的思路一致）。

## 关联

- `network/scripts/truncate-session.py` — 本文的修复脚本
- `network/scripts/sanitize-session.py` — 内容审核 400 的剪除脚本（另一类 400）
- [[deepseek-400-mitigation-design]] — 内容审核 + thinking 双类 400 的规避设计
- [[deepseek-400-mitigation-usage]] — 使用说明

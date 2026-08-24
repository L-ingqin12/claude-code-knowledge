---
title: Claude Code 语境连续性方案
aliases: []
tags: [ai/ops, ai/agent]
created: 2026-07-01
updated: 2026-08-25
status: review
---

# Claude Code 语境连续性方案

See also: [[Claude-Ops-KB-Home]] · [[claude-interruption-resilience-guide]] · [[claude-unattended-methodology]]

> 解决中断后的终极问题：不只是「做到哪了」，而是「在想什么」「为什么这样想」「已经知道了什么」
> 目标：恢复后思路不跑偏、决策不倒回、零冗余分析

---

## 一、问题升级：从「进度丢失」到「思维丢失」

### 1.1 三种丢失，严重程度不同

```
中断后你丢失了什么？
├── 🟡 进度丢失: 「我做到第几步了」
│    └── 解决: task-state.json / progress.log (已在上一个方案中解决)
│
├── 🟠 分析丢失: 「我已经读过哪些文件、发现了什么问题」
│    └── 影响: 恢复后重读文件、重跑分析 → 浪费 tokens
│    └── 解决: Findings Cache (本文)
│
└── 🔴 思维丢失: 「我为什么选择方案A而非B」「我认为这个模块的职责是X」
     └── 影响: 恢复后做出不同决策、与之前的修改矛盾、方向跑偏
     └── 解决: Decision Anchors + Mental Model Snapshot (本文核心)
```

### 1.2 一个真实例子

```
任务: gomoku 的 AI 模块需要支持难度选择

中断前 (Claude 的上下文):
  "我读了 ai.py, game.py, config.json。AI 当前用 minimax+αβ剪枝。
   难度可以通过限制搜索深度实现 (easy=2, medium=4, hard=6)。
   但是 config.json 里已经有了 max_depth 参数，应该复用而非新增。
   还要注意 game.py:142 处硬编码了 depth=4，需要改成读取配置。
   方案B(多套评估函数)太复杂，方案C(限制时间)不确定性强，
   决定用方案A(限制深度)。"

中断后 (如果只恢复了 task-state.json):
  "当前步骤: 修改 ai.py 增加难度参数。
   让我重新分析一下... (重读 ai.py, game.py, config.json)
   嗯，我可以限制搜索深度，或者用多套评估函数...
   (可能选择方案B，因为看起来更高级)
   那我把 evaluate() 拆成三个版本..."

问题: 思路跑偏了！选择了之前已经分析过并否定的方案B。
     而且没有意识到 config.json 已经有 max_depth，可能创建冗余参数。
     前面积累的对代码结构的理解全部丢失。
```

---

## 二、核心方案：外部大脑 (External Brain)

### 2.1 原理

```
正常流程:
  Claude 上下文 (内存)
    ├── 文件内容缓存
    ├── 代码结构理解
    ├── 决策及理由
    └── 待验证假设
  → 中断 → 全部丢失

加外部大脑:
  Claude 上下文 (内存)          磁盘
    ├── 文件内容缓存 ─────────→ context-dump.md
    ├── 代码结构理解 ─────────→   (外部大脑)
    ├── 决策及理由 ─────────→
    └── 待验证假设 ─────────→
  → 中断 → 上下文丢失 → 但磁盘上还有完整的大脑快照
```

### 2.2 关键设计原则

**原则1: 存决策不存数据**
```
❌ 存: "ai.py 第30-80行是 Minimax 类，有 min_value, max_value, alpha_beta 三个方法..."
   → 这是数据，恢复后可以重读文件获得

✅ 存: "ai.py 的 Minimax 类，alpha_beta() 是核心搜索方法，当前硬编码 depth=4"
   → 这是理解，告诉你文件的本质而非内容
```

**原则2: 存 WHY 不重复 WHAT**
```
❌ 存: "需要做三件事: 1.修改 ai.py 2.修改 config.json 3.写测试"
   → 这是 task-state.json 的职责

✅ 存: "选择在 config.json 复用 max_depth 而非新增 difficulty 参数，
   因为避免参数碎片化，同时向后兼容已有配置"
   → 这是决策理由，task-state.json 不记录这个
```

**原则3: 存关系不存细节**
```
❌ 存: "game.py 导入了 ai.py 的 AIMinimax, AINaive; 第142行调用 ai.get_move(board)"
   → 代码里本来就有

✅ 存: "game.py:142 是唯一调用 AI 的地方，修改 AI 接口时必须同步改这里"
   → 这是关键依赖关系，揭示了修改的影响范围
```

**原则4: 锚定到具体位置**
```
❌ 存: "需要修改配置相关代码"
   → 太模糊，恢复后还是要搜索

✅ 存: "config.json:8 (max_depth), game.py:142 (硬编码 depth=4), ai.py:35 (读配置处)"
   → 精确锚点，恢复后直接定位
```

### 2.3 核心文件：context-dump.md（外部大脑）

这就是中断恢复时 Claude 第一个读的文件。它重新建立 Claude 的"思维状态"。

```markdown
# 🧠 Context Dump — gomoku 难度选择功能
> 快照时间: 2026-06-11 10:15 +08:00
> 对应步骤: task-state.json 的 step 2 "修改 ai.py"

## Mental Model（对代码的理解——不是文件目录，是架构认知）

- ai.py: Minimax + αβ 剪枝，核心在 alpha_beta() 方法，每次搜索固定 depth=4
- game.py:142 是唯一调用 AI 的地方: `move = ai.get_move(board)` — 需要传 depth 参数
- config.json:8 已有 `max_depth: 4` 但 ai.py 没读它，是死配置
- 数据流: web → game.py → ai.py，config.json 在 game.py 中加载但不传给 AI
- 测试: tests/test_ai.py 有 12 个用例，都需要 patch Minimax 构造参数

## Decisions（决策及理由——恢复后不能推翻）

| # | 决定 | 理由 | 被否定的方案及原因 |
|---|------|------|-------------------|
| 1 | 复用 config.json 的 max_depth，不新建 difficulty 参数 | 避免参数碎片化；已有配置向后兼容 | ❌ 新增 difficulty: 增加配置复杂度，与 max_depth 语义重复 |
| 2 | 难度映射: easy=2, medium=4, hard=6 | 与当前默认 depth=4 对齐，medium=默认 | ❌ easy=1: 太弱，AI 随机下棋 |
| 3 | 在 game.py 中读取 max_depth 并传入 ai.get_move() | 保持 AI 无状态，配置由调用方传入 | ❌ 在 AI 内部读 config: 破坏 AI 的纯计算语义，测试时难 mock |

## Key Findings（费了力才发现的——不能白费）

- ❗ game.py:142 硬编码 `depth=4` → 这是唯一的深度入口，改这里就能控制全局
- ❗ config.json 在 game.py:15 加载为 dict，但 key 是 `max_depth` 不是 `depth` → 容易写错
- ❗ test_ai.py 的 TestMinimax 类用 `@patch('ai.Minimax.__init__')` → 改构造参数签名会破坏 3 个测试
- ❗ ai.py:78 `time.time()` 用于超时控制 → 不能简单用 depth 替换，需要保留 timeout 逻辑

## Assumptions（还没验证的——注意）

- ⚠ 假设 depth 增加一定会让 AI 更强（实际上 αβ 剪枝在深度增大时可能反而剪掉好着法）
- ⚠ 假设用户愿意等待 depth=6 的计算时间（未测试耗时）
- ⚠ 假设 easy/medium/hard 三档足够（可能需要更细粒度）

## Next: 修改 ai.py — 让 alpha_beta() 接受动态 depth
> Intent: 这是难度控制的核心。改完这步后 AI 就能按不同深度搜索了。
> 之后 step 3 再改 game.py:142 传入配置的 depth 值。
```

### 2.4 为什么这个格式有效

| 要素 | 解决的问题 | 如果不存会怎样 |
|------|-----------|---------------|
| Mental Model | 恢复后直接理解架构，不用重新读 5 个文件建立心智模型 | 重读全部文件 (~3000 tokens) 再归纳 |
| Decisions 表 | 防止思路跑偏，重新选择已被否定的方案 | 可能推翻之前的决策，产生不一致的修改 |
| Key Findings | 节省 grep/分析的时间 | 重新发现 `game.py:142 硬编码`，浪费分析 |
| Assumptions | 提醒哪些结论还不确定 | 把假设当事实，继续在错误前提上构建 |
| Next + Intent | 不仅知道做什么，还记得为什么这样做是对的 | 可能跳到错误顺序的下一步 |

---

## 三、何时写入：检查点策略

### 3.1 不要在每一步都写——在"思维跃迁点"写

```
哪些时刻必须写 context-dump.md？
├── 🔴 完成分析阶段、准备进入修改阶段时（最重要！）
├── 🔴 做出了一个非平凡的技术决策时
├── 🟠 发现了一个影响后续步骤的关键信息时
├── 🟠 推翻了之前的一个假设时
└── 🟡 一个关键步骤完成、下一个步骤开始前
```

### 3.2 写入时机决策树

```
当前发生了什么？
├── 刚刚读完并理解了一个新文件
│   └── 更新 Mental Model (一句话描述该文件的角色和关键点)
│
├── 刚刚做了技术选型（方案A vs B vs C）
│   └── 必写！更新 Decisions 表
│
├── 刚刚 grep/搜索发现了一个重要事实
│   └── 追加到 Key Findings（一行）
│
├── 刚刚意识到之前某个假设是错的
│   └── 更新 Assumptions，标记已验证/已推翻
│
├── 改完了一个文件
│   └── 更新 Next + Intent，确认下一步
│
└── 刚刚完成了一个不涉及决策的机械任务
    └── 不写（task-state.json 记录进度就够了）
```

### 3.3 写入开销控制

```
写入频率: 每 2-5 个步骤写一次
单次写入开销: ≤200 tokens (只写增量)；累计写入开销 ≤500 tokens
总开销: < 任务总 tokens 的 3%

对比恢复时省下的:
  恢复时重分析: ~2000-5000 tokens
  决策失误修复: ~1000-3000 tokens
  净节省: 90%+
```

---

## 四、恢复 Prompt 工程

### 4.1 恢复 Prompt 模板

这是最关键的部分。恢复 prompt 必须经过精细设计，确保 Claude 以正确的"思维姿态"醒来。

```markdown
⚠️ 会话因网络中断恢复。你不是在开始一个新任务——你在接续一个正在进行的任务。

## 恢复流程（严格按顺序）

### 第一步：加载外部大脑
读取 /root/.claude/context-dump.md。
这将告诉你:
- 你对这个代码库的理解（Mental Model）
- 你已经做出的决策及理由（Decisions）— 不要推翻这些
- 你费力发现的要点（Key Findings）— 不要在已经发现的东西上重新分析
- 尚待验证的假设（Assumptions）

### 第二步：加载任务状态
读取 /root/.claude/task-state.json。
确认当前步骤和待完成步骤。只做未完成的。

### 第三步：验证当前状态
快速检查 Key Findings 中提到的文件锚点（如 "game.py:142"）是否仍然正确。
如果文件已经被修改（你自己改的），确认当前内容符合预期。

### 第四步：继续执行
从 task-state.json 的第一个 pending 步骤继续。
严格遵循 context-dump.md 中的 Decisions——不要重新决策。
利用 Mental Model 中的理解，不要重新分析整个代码库。

## 关键规则
1. **禁止推翻 Decisions 表中的任何决策**。除非你发现新信息明确证明其错误。
2. **禁止重读 Key Findings 中已覆盖的文件内容**。信任之前分析的结果。
3. **如果 Assumptions 中有未验证的条目**，在执行依赖它们的步骤前先验证。
4. **每完成一个步骤**，同时更新 task-state.json 和 context-dump.md。
```

### 4.2 为什么这个 Prompt 有效

| Prompt 特征 | 解决的问题 |
|-------------|-----------|
| "你不是在开始新任务" | 防止 Claude 重新理解需求、重新制定计划 |
| "不要推翻 Decisions" | 防止思路跑偏，选择已被否定的方案 |
| "不要重读已覆盖的文件" | 防止浪费 tokens 重新分析 |
| "快速检查锚点" | 低成本验证状态一致性 |
| "利用 Mental Model" | 直接继承之前的理解，不停滞 |

### 4.3 自动恢复脚本（注入恢复 Prompt）

```bash
#!/bin/bash
# /root/claude-smart-resume.sh
# 智能恢复：检测中断→组装恢复 Prompt→启动 Claude

CONTEXT_DUMP="/root/.claude/context-dump.md"
TASK_STATE="/root/.claude/task-state.json"
RECOVERY_PROMPT="/root/.claude/recovery-prompt.txt"

# 组装恢复 prompt
cat > "$RECOVERY_PROMPT" << 'PROMPT_HEADER'
⚠️ 会话因网络中断恢复。你不是在开始一个新任务——你在接续一个正在进行的任务。

## 恢复流程（严格按顺序）

### 第一步：加载外部大脑
读取 /root/.claude/context-dump.md。
这将告诉你: 你对这个代码库的理解、已做出的决策及理由、费力发现的要点、尚待验证的假设。

### 第二步：加载任务状态
读取 /root/.claude/task-state.json。
确认当前步骤和待完成步骤。只做未完成的。

### 第三步：验证当前状态
快速检查 Key Findings 中提到的文件锚点是否仍然正确。

### 第四步：继续执行
从 task-state.json 的第一个 pending 步骤继续。
严格遵循 context-dump.md 中的 Decisions——不要重新决策。

## 关键规则
1. 禁止推翻 Decisions 表中的任何决策（除非发现新信息明确证明其错误）
2. 禁止重读 Key Findings 中已覆盖的文件内容——信任之前的分析结果
3. 如果 Assumptions 中有未验证的条目，在执行依赖它们的步骤前先验证
4. 每完成一个步骤，同时更新 task-state.json 和 context-dump.md

PROMPT_HEADER

# 如果有精确的最后一行进度，追加到 prompt
if [ -f "$TASK_STATE" ]; then
    echo "" >> "$RECOVERY_PROMPT"
    python3 -c "
import json
s = json.load(open('$TASK_STATE'))
print(f'## 当前任务快照')
print(f'任务: {s[\"task_name\"]}')
print(f'进度: {len(s[\"completed\"])}/{s[\"total_steps\"]}')
print(f'下一个: {s[\"pending\"][0][\"description\"] if s[\"pending\"] else \"完成\"}')
" >> "$RECOVERY_PROMPT" 2>/dev/null
fi

# 启动 Claude
claude --permission-mode accept-edits -p "$(cat $RECOVERY_PROMPT)"
```

---

## 五、最小可行方案：一行 Prompt 注入

如果上面的一切都太复杂，这是**最小开销的立即可用方案**。

在任务 prompt 前追加这一段：

```
## 中断恢复 ⚠️ 此任务可能随时中断

你必须维护一个外部大脑文件 /root/.claude/context-dump.md，包含:
1. Mental Model: 你对代码库的当前理解（每个关键文件的一句话角色描述）
2. Decisions: 每个非平凡决策 + 理由 + 被否定的方案
3. Key Findings: 费力发现的信息（带文件:行号锚点）

规则:
- 完成分析→进入修改前必写
- 做技术选型时必写
- 发现关键信息时必写
- 恢复时先读 context-dump.md，禁止推翻已有的 Decisions
- 写入开销控制在单次 ≤200 tokens、累计 ≤500 tokens
```

把这个加到 `resume-prompt-header.txt` 中（上一个方案创建的），两步合一。

---

## 六、效果量化

### 6.1 中断恢复的 Token 开销对比

以 gomoku 难度选择任务为例（5 步，涉及 4 个文件）：

| 方案 | 恢复时重读 | 恢复时重分析 | 决策一致性 | 总恢复开销 |
|------|-----------|-------------|-----------|-----------|
| 无任何措施 | 重读 4 个文件 (~3000 tok) | 重新理解架构 (~2000 tok) | ❓ 可能跑偏 | ~5000 tok |
| 仅 task-state.json | 重读 4 个文件 (~3000 tok) | 重新理解架构 (~2000 tok) | ❓ 可能跑偏 | ~5000 tok |
| + progress.log | 重读 4 个文件 (~3000 tok) | 部分分析 (~1000 tok) | ❓ 方向明确但决策可推翻 | ~4000 tok |
| **+ context-dump.md** | **读 1 个文件 (~300 tok)** | **0** | **✅ 锚定** | **~300 tok** |

### 6.2 累积节省（多任务场景）

```
单个 5 步任务，中断 1 次:
  无措施: 5000 tok (恢复) + 5000 ok (原任务) = 10000 tok
  有措施: 300 tok (恢复)  + 5000 tok (原任务) + 200*3 tok (3次dump写入) = 5900 tok
  节省: 41%

单个 10 步任务，中断 3 次:
  无措施: 15000 tok (3次恢复) + 10000 tok (原任务) = 25000 tok
  有措施: 900 tok (3次恢复)   + 10000 tok (原任务) + 600 tok (dump写入) = 11500 tok
  节省: 54%

每周运行 5 个任务，平均中断 2 次/任务:
  无措施: 5 × 2 × 5000 = 50000 tok (纯恢复开销!)
  有措施: 5 × 2 × 300  = 3000 tok
  周节省: 47000 tok（恢复开销从 50000 降至 3000 tok，约 16.7 倍；具体金额按后端实际单价折算——原 Sonnet/Opus 报价无依据，已删除）
```

---

## 七、整合：完整的中断韧性栈

```
┌─────────────────────────────────────────────────────────────┐
│  守护层    claude-guardian.sh 检测崩溃→自动拉起→注入恢复Prompt │
├─────────────────────────────────────────────────────────────┤
│  语境层    context-dump.md 保存 Mental Model + Decisions     │
│            + Key Findings + Assumptions                      │
│            → 恢复后思路不跑偏、不重分析                        │
├─────────────────────────────────────────────────────────────┤
│  任务层    task-state.json 记录 WHAT (步骤/进度)              │
│            progress.log 记录 WHEN (时间线)                    │
│            → 恢复后知道做到哪了                               │
├─────────────────────────────────────────────────────────────┤
│  文件层    .bak 备份 → 任何步骤可安全回滚                     │
├─────────────────────────────────────────────────────────────┤
│  会话层    claude --resume → shell 环境恢复                   │
└─────────────────────────────────────────────────────────────┘
```

### 7.1 最终 Prompt 头（合并所有层）

```markdown
## ⚠️ 中断恢复协议 (v2 — 含语境连续性)

此任务运行在不稳定网络环境（Android/移动网络），随时可能中断。
你必须遵守以下规则以确保中断后可精确恢复：

### A. 任务进度 (WHAT)
- 开始前读 /root/.claude/task-state.json 了解进度
- 每完成一个步骤，立即更新 task-state.json
- 每步追加一行到 progress.log: `[时间] ✅/❌ 步骤 N: 结果`

### B. 外部大脑 (WHY — 最关键的!)
维护 /root/.claude/context-dump.md，包含:
1. **Mental Model**: 你对代码库的理解（每文件一句话角色描述）
2. **Decisions**: 每个非平凡决策 + 理由 + 被否定的方案（表格格式）
3. **Key Findings**: 费力发现的信息（带 file:line 锚点）
4. **Assumptions**: 尚待验证的假设

写入时机:
- ✅ 完成分析阶段、准备进入修改阶段时 (必写!)
- ✅ 做了一个非平凡的技术决策时 (必写!)
- ✅ 发现影响后续步骤的关键信息时 (必写!)
- ❌ 纯粹机械任务时 (不写，task-state 已够)

格式要求: 紧凑、锚定到具体代码位置、只存理解不存数据

### C. 决策锚定 (防止跑偏)
- 每个 Decisions 条目必须包含"被否定的方案及原因"
- 恢复后读取 context-dump.md 时，禁止推翻已有 Decisions
- 除非发现新信息明确证明原决策错误

### D. 文件安全
- 修改文件前 cp 到同名 .bak
- 在 Key Findings 中记录关键锚点 (file:line)

### E. 恢复时
第一步读 context-dump.md → 第二步读 task-state.json → 验证锚点 → 继续
```

---

## 八、与已有方案的衔接

| 已有文件 | 本文新增 | 关系 |
|----------|---------|------|
| `task-state.json` | `context-dump.md` | task-state = WHAT, context-dump = WHY |
| `progress.log` | Mental Model 段 | progress = 时间线, Mental Model = 空间理解 |
| `resume-prompt-header.txt` | Decisions 表 | 旧的只管进度，新的管思维状态 |
| `claude-guardian.sh` | 恢复 Prompt 模板 | 守护自动拉起，新 Prompt 恢复更精准 |
| `claude-interruption-resilience-guide.md` | 本文 | 本文是上层建筑（语境连续性），前文是基础设施（进度跟踪） |

---

## 九、立即实施

```bash
# 1. 升级 resume-prompt-header.txt（合并语境连续性）
cat > /root/.claude/resume-prompt-header.txt << 'HEADER'
## ⚠️ 中断恢复协议

### A. 任务进度
- 开始前读 /root/.claude/task-state.json
- 每完成一步立即更新
- 每步追加 progress.log

### B. 外部大脑 (关键!)
维护 /root/.claude/context-dump.md:
1. Mental Model: 代码库理解（每文件一句话）
2. Decisions: 决策+理由+被否定的方案（表格）
3. Key Findings: 重要发现（带 file:line 锚点）
4. Assumptions: 未验证假设

写入时机: 分析完成后、技术决策时、发现关键信息时
格式: 紧凑、锚定、只存理解不存数据

### C. 恢复规则
1. 禁止推翻 context-dump.md 中的 Decisions
2. 禁止重读 Key Findings 已覆盖的文件
3. 先读 context-dump.md → 再读 task-state.json → 验证锚点 → 继续

HEADER

# 2. 使用
task="你的实际任务描述"
claude -p "$(cat /root/.claude/resume-prompt-header.txt)

$task" --permission-mode accept-edits
```

---

## 十、总结

```
之前你问的: 「如何让 Claude 在中断后继续执行任务」
  答案: task-state.json + progress.log

现在你问的: 「如何让 Claude 中断恢复后思路一致、不跑偏、不开销」
  答案: context-dump.md (外部大脑)

区别:
  task-state.json  = 任务的书签 → 知道翻到哪一页
  context-dump.md  = 读书笔记   → 知道前面讲了什么、为什么重要
                    + 决策记录   → 不会翻回去重新评价已排除的选项
                    + 发现缓存   → 不需要重新翻前面的章节
```

**核心原则就一句话**：中断后 Claude 不应该重新"想"，它应该读自己之前写下的"想好的结果"，然后直接继续做。

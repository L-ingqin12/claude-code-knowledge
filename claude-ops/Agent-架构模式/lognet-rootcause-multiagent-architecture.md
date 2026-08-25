---
title: 基于日志网络的根因分析多Agent架构方案
aliases: [日志网络架构, LogNet根因分析, 多类型日志根因定位方案]
tags: [ai/ops, ai/agent]
created: 2026-08-25
updated: 2026-08-26
status: review
---

# 基于日志网络的根因分析多Agent架构方案

> [!abstract] 概述
> 面向"每次输入都是全新日志包、可能多包并发"的设备级问题分析场景（cppcrash / tombstone / hilog / kmsg / isp / trace / sleeplog / sensorhub 等多类型日志），给出**四层架构**：数据层把日志包离线转化为可查询的**日志网络（LogNet）**——图结构 + 时间线 + 全文索引，纯代码无 LLM；分析层由多 Agent 从问题节点出发**渐进展开**定位根因；控制层复用实时交互看门狗与质量门控；服务层对外提供双形态 API。附机制分工规划（tools/hooks/plugin/MCP/skills）、符号化工具链设计（addr2line 等）、容量估算与分阶段可行性验证路线。

See also: [[log-analysis-agent-windows-architecture]] · [[fan-out-subagent-pattern]] · [[state-machine-quality-gate-loop]] · [[main-subagent-realtime-interaction]] · [[opencode-pi-base-development-analysis]] · [[参考-OpenCode-技术调研报告]] · [[Claude-Ops-KB-Home]]

## 一、场景与需求定义

| 项 | 内容 |
|----|------|
| 输入 | ① 问题图片/描述中的关键字（错误码、模块名、进程名）；② **全新**日志包：cppcrash、tombstone、hilog、kmsg、isp、trace、sleeplog、sensorhub.log 等，体量从几百 MB 到数 GB |
| 输出 | 根因结论 + 证据链（节点引用可回溯）+ 跨日志时间线叙事 + 置信度 |
| 特性约束 | 每包冷启动（无历史积累）；**多 session/多日志包并发分析**；重负载下 TTFT 与吞吐优先；分析过程只读（不得改动原始日志） |
| 与既有方案的关系 | 本文档是 [[log-analysis-agent-windows-architecture]] 的**分析内核升级版**：原方案回答"如何把 Agent 跑成服务"，本文回答"Agent 内部如何组织成根因分析系统" |

## 二、总体架构（四层）

```
┌─ 服务层   双形态API(交互SSE/非交互RPC) + Router关键字短路 ────────────┐
├─ 编排层   Orchestrator主Agent                                        │
│            ├─ 会话池粘性调度（一包一workspace，cache亲和）              │
│            └─ 全局看门狗[[main-subagent-realtime-interaction]]        │
├─ 分析层   Locator(前沿扩展) ⇄ 类型专家Agents(hilog/crash/kernel/…)    │
│            ⇄ Synthesizer(证据链综合) ⇄ QA门控[[state-machine-quality-gate-loop]]
├─ 数据层   解析索引Sidecar（纯代码，无LLM）                             │
│            类型识别→切分→解析→符号化→LogNet构建→FTS5/btree索引         │
│            工具面: query_logs / get_subgraph / symbolicate …          │
└──────────────────────────────────────────────────────────────────────┘
```

核心思想：**LLM 不直接面对海量日志原文**。数据层把 GB 级文本压缩为结构化的图与索引，Agent 通过查询工具按需取"局部子图 + 少量原文片段"，上下文始终有界。

## 三、数据层之一：日志类型矩阵与解析器注册表

| 日志类型 | 内容 | 关键信号 | 解析要点 |
|----------|------|---------|---------|
| cppcrash | C++ 崩溃：signal/fault addr/backtrace/寄存器 | 故障栈帧、abort message | 提取裸栈（so!offset），送符号化 |
| tombstone | native crash 落盘记录 | pid/tid/backtrace/maps | 同上；maps 表用于地址归属判定 |
| hilog | 应用域日志（domain/tag/level/pid/tid/ts） | error/fault 关键字、tag 聚类 | 海量高频 → level 过滤 + tag 倒排 |
| kmsg | 内核环形缓冲 | oops/panic/driver error | 单调时钟域，需与其他日志换算对齐 |
| isp | 相机 ISP 固件日志 | 帧号、sensor 时序异常 | 私有格式 → 解析器可插拔，先正则兜底 |
| trace | hiTrace/systrace 类调用链 | span 起点/终点/耗时 | 时间线对齐的主骨架 |
| sleeplog | 休眠/唤醒记录 | suspend/resume、wakeup source | 冻结期标记（时间轴上的"黑障区"） |
| sensorhub.log | 传感器 hub 固件 | 数据断流、flush 异常 | 设备侧时钟独立 → 需锚点校准 |

**解析器注册表**（配置驱动，新增类型不改核心）：`{name, filename_pattern, magic/heuristic, parser_plugin, clock_domain, priority}`；无法识别的文件进入"未知桶"，由 Agent 在交互中引导补充规则。

## 四、数据层之二：LogNet 日志网络

### 4.1 图模型

| 节点类型 | 属性（摘要） |
|----------|-------------|
| EventNode | ts(归一时钟)、source_log、pid/tid、tag、level、payload_hash、raw_offset（回溯指针） |
| EntityNode | 进程/线程/模块/设备（跨日志聚合身份） |
| SignalNode | 错误码/关键字命中/异常模式/崩溃帧（符号化后） |

| 边类型 | 含义 |
|--------|------|
| temporal_next | 同源日志时序相邻 |
| same_entity | pid/tid/模块归属（跨日志同实体合并） |
| causal_hint | 显式因果线索（panic ← 前序 driver error；watchdog 超时 ← 冻结区） |
| co_occurrence | 时间窗内共现（弱信号，评分加权用） |

### 4.2 存储选型（可行性关键决策）

> [!tip] SQLite(+FTS5) 单文件库，不上重型图数据库
> - 每日志包一个 `<pkg>/lognet.db`：nodes/edges 表 + FTS5 倒排（关键词）+ b-tree（ts 范围）+ `(build_id, addr)` 符号缓存表；
> - 图遍历用 SQL 递归 CTE（深度 ≤5 完全够用）或加载局部到内存 networkx；
> - 理由：① 冷启动场景零运维；② 千万行级单机性能足够（见 §九 容量估算）；③ 多 session 并发 = 多 db 文件天然隔离；④ 包分析完即弃或归档，无需长期图服务。
- **时间线化**：所有 EventNode 换算到统一时钟域（kmsg 单调钟为锚，hilog wall-clock 用开机时刻偏移校准，sensorhub 用双日志共现锚点回归）；每个 Entity 生成一条时间轴视图，sleeplog 的冻结期渲染为"黑障区"避免误判不连续。
- **去重压缩**：日志重复率极高，payload_hash 相同的连续行折叠为 `{count, first_ts, last_ts}`，入库量常见降一个数量级。

## 五、数据层之三：符号化工具链设计（addr2line 等）

### 5.1 设计原则

> [!warning] 符号化不让 LLM 碰命令行
> addr2line 单次调用秒级且参数易错，让模型在 bash 里反复试错既烧 token 又不稳定。正确姿势：Sidecar 提供 `symbolicate` 工具，内部做批量、并行、缓存与版本匹配，LLM 只见到最终函数名栈。

### 5.2 符号库匹配与获取（核心难点）

1. **以 build-id 为准，不以文件名为准**：解析 so 的 `.note.gnu.build-id`（readelf -n），在符号源按 build-id 索引检索 unstripped 库；文件名+版本号只作次级匹配并标注低置信；
2. 日志包 manifest 里通常带版本/commit → 作为检索第二键；
3. **符号制品获取接内部工具 artget**（见 5.2.1）；本地目录/共享盘作为备选后端；
4. 匹配失败降级：保留 `libxxx.so!0x12345` 形态 + 标记 `unsymbolicated`，报告里显式列出"缺哪些 so"，支持用户补传后增量重跑（只重算该 build-id 相关帧）。

#### 5.2.1 artget（内部制品拉取工具）接入设计

> 定位：`SymbolResolver` 后端之一 —— 按版本号/build-id 从构建服务器批量拉取 unstripped so 等符号制品。LLM 永远不直接调用 artget。

| 设计项 | 方案 |
|--------|------|
| 适配层 | Sidecar 定义 `SymbolSource` 统一接口 `{fetch(module, build_id) -> local_path}`；实现三后端：**ArtGetBackend**（封装内部 artget CLI）、**LocalDirBackend**（本地符号库目录）、**CacheBackend**（build-id 寻址的本地缓存，恒为第一跳） |
| 批量预取 | crash/tombstone 解析阶段即收集 `(module, build_id)` 去重清单 → **一次批量调用 artget 预取** → 完成后才启动该 build-id 的 symbolizer 进程；避免逐帧触发零散拉取 |
| 缓存 | `symbol-cache/<build_id>/<lib>.so` 落盘寻址存储；命中即跳过网络；跨 session/跨日志包复用（命中率随使用单调上升） |
| 并发与限速 | artget 调用进独立下载池（与解析池隔离，防互相拖垮）；对制品服务器限速 + 指数退避重试；大文件流式落盘不进内存 |
| 失败语义 | 单个制品失败只降级该 build-id 相关帧（unsymbolicated 标注），**不阻塞整包分析**；缺失清单汇总进报告供人工补传 |
| 凭据安全 | artget 认证凭据走环境变量/DPAPI 注入 Sidecar，**永不进入 Agent 上下文、日志脱敏**；符号文件只读挂载 |
| 可观测性 | 每次拉取记录 `(build_id, module, 耗时, 字节数, 来源)` 结构化日志，用于评估符号覆盖率（PoC 假设 4） |

流水线位置更新：`crash/tombstone 解析 → 收集 build-id 清单 → [Cache→ArtGet] 批量预取 → symbolizer 批量符号化 → SignalNode(fault_frame) 入网`。

### 5.3 工具面与实现要点

| 工具/手段 | 用途 | 要点 |
|-----------|------|------|
| `llvm-symbolizer --batch` | 批量地址→源码行（首选，单进程高吞吐，支持 inline `-i` 与 demangle `-C`） | 一个 build-id 一个常驻进程，stdin/stdout 流式喂地址 |
| `addr2line -f -C -i -e <so>` | 兼容后备（binutils 环境） | 同样走批处理模式 |
| `readelf -n` / `objdump` | 提取 build-id、确认架构 | 入库时一次性执行 |
| minidump 栈回溯器（如涉 .dmp） | 断裂栈的寄存器续栈 | 可选组件 |
| 缓存 | `(build_id, addr) → frame` SQLite 表 | 跨 session 复用，命中率随使用攀升 |

流水线位置：crash/tombstone 解析器输出裸栈 → **符号化 worker 池**（每 build-id 一个 symbolizer 进程，多包并行）→ 带函数名/源码行的 SignalNode(fault_frame) 写入 LogNet。安全约束：符号库只读挂载、按项目隔离（含 IP，禁止入上下文全文，仅函数名+行号出）。

## 六、分析层：从问题节点向前渐进展开

### 6.1 角色分工

| 角色 | mode/权限 | 职责 |
|------|-----------|------|
| Orchestrator | primary / 只读+委派 | 信号识别、任务分解、预算控制、汇总交付 |
| Locator | subagent / 只读 | 维护 frontier 前沿队列，逐跳调用 get_subgraph 向前扩展 |
| 类型专家 ×N（crash/hilog/kernel/isp…） | subagent / 只读 | 对局部子图做领域判读（各自 SKILL.md 注入解读知识），可发起定向查询 |
| Synthesizer | subagent / 只读 | 证据链合成时间线叙事与根因假设（多假设并列+置信度） |
| QA 门控 | hook+状态机 | 六门检查（syntax/completeness/consistency/no_hallucination/specificity/actionable），RETRY≤3，总轮次≤10，超限 ESCALATE（[[state-machine-quality-gate-loop]]） |

专家之间满足 Fan-Out 条件（不同文件不同维度、全部只读）→ 并行分发（[[fan-out-subagent-pattern]]）；OpenCode 无原生异步后台 → 经 Server/SDK 自建会话池（[[参考-OpenCode-技术调研报告]] §7），Pi 则进程内多 AgentSession（[[pi-agent-framework-knowledge]]）。

### 6.2 渐进展开算法

```
frontier = {问题节点集}                     # 来自用户信号 + crash 帧
visited = ∅
while frontier 且预算未耗尽:
    n = argmax score(n)                    # 取最优前沿节点
    subgraph = get_subgraph(n, depth=2,
                 time_window=±Δ, budget≈8k tokens)
    verdict = 专家判读(subgraph)            # 并行分派给对应类型专家
    if verdict.new_signals:
        frontier += signals                # 新信号入队
    if verdict.hypothesis_ready:
        送 Synthesizer/QA 门控
    visited += n
```

**frontier 评分**（可配置权重）：`score = w1·信号强度(错误码/关键字等级) + w2·时间邻近度(exp(-|Δt|/τ)) + w3·实体关联度(同pid/模块) + w4·边类型权重(causal_hint > temporal > co_occurrence) − 已访问惩罚`。

**有界性三保险**：每跳子图 ≤8k tokens；单 session 总预算（如 ≤400k tokens / ≤60 跳）；防环 visited 集 + 时间单调向前约束（根因在问题之前，默认禁止向未来扩展超过容差窗）。这与"逐步展开定位"的需求严格对应：**每一次展开都有据可查（节点引用），每一步都可中断恢复（checkpoint，见 §八）**。

## 七、机制分工规划（开发工作落在哪）

> [!tip] 分配原则：确定性逻辑→纯代码 Sidecar；横切关注→hook；角色知识→配置与 skills；控制面→plugin event Bus + 外置 watchdog

| 开发项 | 承载机制 | 理由 |
|--------|---------|------|
| query_logs(ts/tag/pid/keyword, limit) | MCP 工具（Sidecar 暴露） | 结构化检索返回"命中计数+TopN 摘要+引用指针"，杜绝大段原文进上下文 |
| get_subgraph(node_id, depth, window) | MCP 工具 | 图检索原语，返回子图 JSON 摘要 |
| symbolicate(frames, build_id) | MCP 工具 | §五 全部复杂度封装在此；内部经 SymbolSource 接口走 Cache/artget 后端 |
| 心跳/进度落盘 | plugin `tool.execute.after` hook 自动写 | 零模型自觉（[[main-subagent-realtime-interaction]] 反模式#1） |
| inbox 未读注入 / 预输入信号注入 | plugin `tool.execute.before` / `chat.message` hook | 控制信息走结构通道 |
| 分析 agent 全只读 | permission 配置(edit/bash deny) + `permission.ask` hook 兜底 | headless 下 ask 会挂起 → 必须预置 allow/deny（调研报告 §7.1） |
| crash/hilog/… 判读知识 | 各专家 `SKILL.md`（渐进披露） | 领域知识不撑 system prompt |
| 角色矩阵 | `agent/*.md` frontmatter（tools 白名单/权限/model） | 配置驱动、git 管理 |
| 会话编排/watchdog | plugin event Bus(`session.idle`/`message.part.updated`) + 外置看门狗经 Server SDK abort | 双保险冗余 |
| 已知故障码直答 | 服务层 Router 关键词短路 | 0 token、TTFT 最小（[[opencode-pi-base-development-analysis]] §4.3） |
| 案例/错误码词典/判读 SKILL 的沉淀与检索 | 外部知识库 + `kb_lookup`/`kb_search` 工具 | 知识出提示词进版本化文件库，治理策略见 [[agent-memory-context-knowledge-design]] |
| 解析/切分/建图/索引/符号化 | 独立 Sidecar 服务 | 重负载纯代码，语言不限，可独立压测扩容 |

## 八、冷启动效率与并行/串行化设计

### 8.1 单日志包处理流水线

```
接收包 → [P0 类型识别+清单] 秒级
      → [P1 并行切分解析] 按文件×chunk 分片，worker池=N核
      → [P2 符号化] 每build-id一个symbolizer进程，与P1重叠
      → [P3 建图+索引] 单写者串行merge（SQLite单写锁）
      → [P4 就绪] manifest+时间线首帧返回
```

- 并行段：P1/P2 天然按文件/chunk/build-id 切开，无共享状态；
- 串行点只有 P3 merge（单写者），用 batch insert + WAL 把它压到分钟级以内；
- P4 即刻返回目录树/时间线概览（TTFT 秒级），深挖留给 Agent 渐进查询——与基座方案的"manifest 先行"同一思想。

### 8.2 多 session 并发

| 机制 | 做法 |
|------|------|
| 隔离单元 | 一包一目录（workspace + lognet.db + 符号缓存），互不可见 |
| 调度 | 会话池一致性哈希粘住 worker（prompt-cache 亲和）；双优先级队列（交互>批量） |
| 资源闸 | 全局解析 worker 总量 + provider token bucket；超水位排队/429 |
| 看门狗 | 每活跃分析会话一套心跳表 + T0..T3 升级阶梯；批量任务超 SLA 直接 T2 interrupt + checkpoint 恢复 |
| 恢复 | 展开进度（frontier/visited/假设树）即 checkpoint 文件，worker 崩溃换机续跑 |

## 九、可行性与容量估算

### 9.1 技术可行性：环节→现有组件映射

| 环节 | 现成组件 | 缺口 |
|------|---------|------|
| 基座会话/工具/权限 | OpenCode server+SDK+plugin+MCP（调研报告确认生产消费者 GitLab orbit/Onyx 存在） | 无原生异步后台 → 自建会话池（已设计） |
| 解析/索引 | SQLite FTS5、llvm-symbolizer、readelf | 各私有日志格式的解析器插件（逐个补） |
| 图查询 | SQL 递归 CTE / networkx | 无 |
| 编排模式 | 本库 fan-out/质量门控/看门狗三件套 | 组装工作 |

### 9.2 性能估算（数量级验证）

- 解析吞吐：SQLite 批量插入 10⁵ 行/秒量级；1GB hilog ≈ 2–5M 行，折叠去重后更少 → N 核并行下 **P1–P3 合计 1–3 分钟**（无 LLM 参与）；
- Token 账：每跳 ≤8k tokens 子图摘要，典型根因分析 20–60 跳 + 专家往返 ≈ **0.2–0.5M tokens/包**；配合 cache 亲和与前缀复用可省 50%+；
- TTFT：P0+P4 秒级首帧；完整根因报告分钟级——对比"人肉翻日志小时级"收益明确。

### 9.3 待验证假设（PoC 清单）

1. FTS5 在 5M 行上关键词查询 P95 <100ms（决定交互体验）；
2. 8k token 子图摘要足以支撑专家判读（抽样 20 个真实案例盲测）；
3. 跨日志 tid/entity 合并准确率 ≥90%（决定 causal_hint 边质量）；
4. build-id 符号库覆盖率（历史包实测，决定 unsymbolicated 比例）；
5. 时钟域对齐误差 <50ms（trace 锚点法实测）。

### 9.4 风险登记

| 风险 | 对策 |
|------|------|
| 私有格式（isp/sensorhub）解析不稳定 | 注册表可插拔 + 正则兜底 + 未知桶人工反馈回路 |
| 符号库缺失/错配 | build-id 强校验 + 低置信标注 + 报告明示缺失清单 |
| 多包时钟漂移 | 锚点回归 + 黑障区标注，不确定窗口显式呈现 |
| 展开爆炸（环/风暴） | 三保险预算 + QA 门控 RETRY/ESCALATE 上限 |
| headless 权限挂起 | 全预置 allow/deny + permission.ask 程序化作答 |

## 十、分阶段实施路线

| 阶段 | 目标 | 验收口径 |
|------|------|---------|
| M0（1-2周） | 数据层 MVP：hilog+kmsg 解析→LogNet.db→query_logs/get_subgraph 工具 ✅ **PoC 已落地**（2026-08-26，`scripts/lognet-poc/`，27 测试全绿 + FTS 基准 P95=348ms@29 万折叠行；5M 行规模验收仍待真实包） | PoC 假设 1/3 通过；500MB 包 3 分钟就绪 |
| M1（2周） | crash 链路：cppcrash/tombstone 解析 + build-id 符号化 + fault_frame 入网 | 假设 4 实测；真实 crash 案例栈帧全符号化率达标 |
| M2（2-3周） | 多 Agent 展开：Locator+2 类专家+Synthesizer+QA 门控跑通单包端到端 | 假设 2 盲测通过；10 个历史案例根因命中率评估 |
| M3（2周） | 服务化：会话池+看门狗+双形态 API+多包并发压测 | 目标并发 P95 达标；kill 恢复演练通过 |
| M4（持续） | 类型扩展（isp/trace/sleeplog/sensorhub）+ 时钟对齐精化 | 假设 5 达标；新类型接入 ≤3 人日（注册表验证） |

## Related

- [[main-subagent-realtime-interaction]] — 看门狗/邮箱/checkpoint 协议（本架构控制面）
- [[state-machine-quality-gate-loop]] — QA 门控与 RETRY/ESCALATE 回环
- [[fan-out-subagent-pattern]] — 专家并行分发条件与防冲突
- [[agent-memory-context-knowledge-design]] — 案例库/错误码词典的知识库化治理（本架构 L3 记忆层）
- [[log-analysis-agent-windows-architecture]] · [[agent-async-isolation-pattern]] — 服务化外壳与超时模板
- [[opencode-pi-base-development-analysis]] — 基座选型、会话池调度与跨平台矩阵
- [[参考-OpenCode-技术调研报告]] — Server/SDK/plugin/MCP 能力依据

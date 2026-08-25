---
title: SESSION-ARCHIVE-2026-08-25
aliases: [2026-08-25 会话归档]
tags: [meta]
created: 2026-08-25
updated: 2026-08-26
status: review
---

# 会话归档 — 2026-08-25 全库审计与 AI 大模型专题建设

> 本会话完成三件事：①[[AI大模型开发]] 主文件补全与勘误；②按西瓜老师课程大纲新建 `ai-dev/` 子库（13 篇实战文档 + MOC + 9 张 Excalidraw 图）；③五路子库审计修复（ai-links / network / claude-ops×3 / 根目录）。规范变更见 [[AGENTS]]。

## 一、主文件：AI大模型开发.md

| 类别 | 内容 |
|---|---|
| 勘误 | GPT 表格版本对应关系、Causal Decoder 拼写、标题层级；√d_k 方差论证标注；Multi-Head 各头独立 Wq/Wk/Wv 展开 |
| 补全 | Word2Vec+梯度下降完整 PyTorch Demo；Completion vs Chat API 完整章节（roles/base_url/curl/参数表/流式/陷阱）；`## 课程知识地图`（38 讲课程 → 文档映射） |
| 图表 | 过时 mermaid 引用替换为 Excalidraw 指针；删除重复空标题 |
| 入口 | `> 入口 MOC: [[AI-Dev-KB-Home]]` |

## 二、ai-dev/ 子库新建（13 篇 + MOC）

全部文档：frontmatter 规范、零 mermaid、≥3 出链（必含 [[AI大模型开发]] 与 [[AI-Dev-KB-Home]]）、参考资料 URL 节、web_search 交叉验证。

| 文档 | 要点 | 配图 |
|---|---|---|
| [[Prompt-Engineering入门与Demo]] | CoT/Few-shot/LtM，9 轮检索验证 | Prompt-Engineering-LtM-Flow |
| [[Function-Calling工具调用实战]] | tools schema/tool_calls/执行器循环 | Function-Calling-Sequence |
| [[RAG检索增强生成实战]] | Naive→Advanced 演进 + FAISS Demo | RAG-Pipeline |
| [[GraphRAG知识图谱增强实战]] | Leiden 社区/Local vs Global Search | GraphRAG-Flow |
| [[LLM-Agent开发基础]] | 手写 ReAct 循环 + 失效模式表 | ReAct-Agent-Loop |
| [[MCP协议开发实战]] | FastMCP Server/Client 双向 Demo | MCP-Architecture |
| [[A2A多智能体协作协议]] | Agent Card/Task 生命周期 | — |
| [[LangChain-LangGraph框架实战]] | LCEL/LangGraph State·Checkpointer·Supervisor | Multi-Agent-Supervisor |
| [[LLM推理部署与量化]] | Ollama/vLLM/Ray 三路线，16 次检索验证（QLoRA 65B 勘误） | Training-vs-Inference（复用） |
| [[LoRA参数高效微调实战]] | 低秩旁路原理 + Llama-Factory 实操 | LoRA-Principle |
| [[强化学习对齐-RLHF到GRPO]] | PPO/DPO/GRPO 谱系 | RLHF-GRPO-Pipeline |
| [[微调数据工程与模型蒸馏]] | SFT/COT/偏好数据 + R1 式蒸馏 | Training-vs-Inference（复用） |
| [[Agent-Skills技能开发实战]] | 课程第13章补齐：SKILL.md 规范/渐进式披露/最小技能 Demo | — |
| [[多模态Agent平台实战]] | 课程第21章补齐：四层架构/延迟预算/TEN·Dify 选型/VLM Demo | — |

入口：[[AI-Dev-KB-Home]]（文档地图/学习路径/项目地图/图表索引/标签索引）。

## 三、diagrams/ 新增 9 张 Excalidraw

`Function-Calling-Sequence`(21el)、`ReAct-Agent-Loop`(18)、`Prompt-Engineering-LtM-Flow`(23)、`RAG-Pipeline`(44)、`GraphRAG-Flow`(36)、`MCP-Architecture`(22)、`Multi-Agent-Supervisor`(28)、`LoRA-Principle`(30)、`RLHF-GRPO-Pipeline`(20)。
验证方式：pwsh 提取 ```json 块 ConvertFrom-Json 全部通过；箭头 start/endBinding 与矩形 boundElements 双向互引核对。格式遵循 [[ARROW-CHECKLIST]] 与 [[AGENTS]] 第十一节。

## 四、审计与修复（五路执行代理）

| 子库 | 执行摘要 | 修改点 |
|---|---|---|
| ai-links/ | source_url→source_urls 批量、PatchSAE 577→576+1、Kimi-K3 数字、幽灵链接清理、自链修正 | 20 文件 / 53 处 |
| network/ | 延迟基准统一 541→113(-79%)、TX Power 14vs18 勘误、8 处脚本路径补 scripts\、Mux 致障勘误 callout、uci 不可用警告、信号 82/86/88 口径注、MOC 地图补 2 行 | 14 文件 / 73 处 |
| 根目录 参考-* | VPN 三组数字矛盾统一、Ark「重度3天」首日超限修正、小米 login 移出 stok 表、树莓派复盘 ping 口径/danger 备份注、See also 全部移至 H1 后、SESSION-ARCHIVE-2026-08-18 出入链修复 | 14 文件 / 约 70 处 |
| claude-ops/事故复盘+Agent-架构模式 | hermes 80min→~110min 时间线、ping 口径澄清、opencode Python→TypeScript(+Go TUI)、nginx select 1024/单 worker、逃生通道级别统一、状态机补 ESCALATE 终态（附待确认 callout）、cron hosts 追加缺陷修正、HTTP/2 根因叙述纠正、死链按 MEMORY-INDEX 重定向修复 | 11 文件 / 28 处 |
| claude-ops/运维方案与设计 | 锚点工具 9/10 统一、sysctl PRoot 不可用 warning、fail-open 超时语义、claude-haiku-4-5→deepseek-chat 映射注、reusePort 正确实现、cache-proxy-evaluation 转 deprecated | 19 文件 / 76 处 |

死链专项：Plans 内 `hermes-parallel-task-communication` 等历史死链全部改为真实文件名或加失效注记。

## 五、规范演进（AGENTS.md）

- ⛔ **全局铁律**：一切委派必须使用 ox-alpha 模型，禁止路由 deepseek 系列其他模型（文首 danger 块 + 行为约束第 9 条）
- **Python 环境**：全局解释器固定 `D:\ProgramData\miniconda3\python.exe`（行为约束第 10 条）
- Mermaid 矛盾澄清（"禁止"为准，MOC 关系图用文字树/表格）；目录树重写；统计口径 170+/500+；注册 #ai/tools、#network/moc 等

## 六、终检结果

| 检查项 | 结果 |
|---|---|
| 全库 wikilink 解析（含 .excalidraw 嵌入） | ✅ 0 死链 |
| 全库 ```mermaid 代码块 | ✅ 0 处 |
| 新建文档 frontmatter（title/tags/created/updated/status） | ✅ 全合规 |
| Excalidraw JSON 解析 | ✅ 9/9 通过 |
| Python Demo 语法（py_compile 批量） | ✅ 45/45 通过 |

## 七、遗留事项（未解决）

1. **Demo 运行级验证未做**：全局 miniconda 未装 torch/faiss/networkx/sentence-transformers；语法已验证（45/45），装依赖后建议跑一遍（解释器路径见 [[AGENTS]] 行为约束第 10 条）
2. ~~vllm bench serve 版本、ZeRO 倍数~~ ✅ 已按公开资料核实补充（PR #13993/#18566；ZeRO 论文 400B 实测口径）
3. ~~CVE-2020-14100 待核~~ ✅ NVD 描述确认 <1.0.66 受影响，修复版本即 1.0.66
4. **课 29 Janus 统一多模态** ✅ 已补全独立章节（解耦视觉编码 + GenEval/MMBench 成绩）
5. 主文件 `> 入口 MOC:` 与 `## Related` 间约 10 个空行（Obsidian 渲染无影响）
6. 沙箱限制备忘：pwsh 无法修改既有库文件（Access Denied），一律用 read/edit 工具；新文件创建可用 pwsh
7. 仍待验证（课程专属/需实机，公开资料无法覆盖）：labeler 与 llamabooster 产品形态、中文 token 压缩比官方口径、TYPORA 全新机器端到端
8. **推送待执行**：本地已领先 origin/main 三个提交（4edd7ef / ce7c593 / 本归档提交），沙箱内凭据管理器被拦无法认证。请在你的终端执行：
   ```powershell
   cd D:\Document\local\knowledge
   git -c http.proxy=http://[IP已脱敏]:10808 push origin main
   ```
   （直连可达时可省 proxy 参数）

## 十、同日追加会话：OpenCode/Pi 基座研究与日志分析多Agent架构设计

> 第二会话（同日晚）。主题：OpenCode 扩展机制知识补全、主↔子 agent 实时交互方案、基座开发七维度选型、日志网络根因分析多Agent架构。

### 产出（6 新文档）

| 文档 | 要点 |
|---|---|
| [[参考-OpenCode-技术调研报告]] | Agent双mode/task委派与四大缺口(异步#5887/嵌套#9280/并行#29638/resume#6584)、plugin五hook+event Bus、自定义tool(zod)、SKILL渐进披露、MCP local/remote、opencode.json permission last-match、**serve REST+/event SSE+abort**（GitLab orbit/Onyx 生产佐证）、v1.18.23/MIT |
| [[参考-Pi-Agent-技术调研报告]] | badlogic→Earendil 迁移史、库优先 createAgentSession 三层API、**steer()/followUp() 双队列**、AbortSignal/interrupt、树状JSONL、无内核MCP、默认无权限、Windows坑、0.x破坏性变更+npm作用域迁移风险 |
| [[main-subagent-realtime-interaction]] | 实时交互四原语（感知/邮箱/打断/恢复）、四层活性金字塔与判定矩阵、T0..T3升级阶梯（Pi steer=T1.5当轮注入）、mailbox协议、checkpoint模板 |
| [[opencode-pi-base-development-analysis]] | 双层基座推荐（OpenCode交互基座+Sidecar外挂，Pi嵌入备选）；manifest入上下文+secure_read明文治理；关键字短路两级；会话池/cache亲和/背压；跨平台矩阵；Phase 0-4路线图；ADR D1-D6 |
| [[lognet-rootcause-multiagent-architecture]] | LogNet图模型(SQLite+FTS5)+时钟域对齐；从问题节点frontier评分渐进展开；符号化工具链(addr2line/llvm-symbolizer批处理+build-id匹配+**artget适配器**)；多包并发流水线；容量估算与PoC假设清单；M0-M4路线 |
| [[agent-memory-context-knowledge-design]] | 记忆三级模型(L1窗口/L2checkpoint/L3知识库)；上下文五源装配+前缀稳定排序(缓存亲和)；外部知识库化四形态(规则/事实/方法论/案例)+写入三闸门与混合检索；直接复用本库 AGENTS 协议为产品内知识库规范 |

### 关联修改

- MOC 挂载：[[AI-Links-KB-Home]] 文档地图 +2 调研报告行；[[Claude-Ops-KB-Home]] ARCH 表 +4 行（review ×4）；[[MEMORY-INDEX]] 新增节 4 条
- 反向链接补齐：opencode-multi-agent-architecture / fan-out-subagent-pattern / state-machine-quality-gate-loop / pi-agent-framework-knowledge / log-analysis-agent-windows-architecture 的 See also
- 调研方式：两路后台子代理多轮 web_search 交叉验证（ox-alpha 继承，未传 model 覆盖）

### 本会话遗留

1. 两份调研报告各含 6-8 处「待确认」（org 归属、explore agent、MCP 分隔符、allowed-tools 执行、zod 细节等），后续可实机核验
2. artget 为内部工具，接入设计按"制品拉取"口径完成（用户确认），实际 CLI 参数待对齐
3. Doc C/D 的 Phase/M 路线图为设计稿，未启动实施

> 相关：[[Network-KB-Home]] · [[Claude-Ops-KB-Home]] · [[AI-Links-KB-Home]] · [[TYPORA-KB-Home]]

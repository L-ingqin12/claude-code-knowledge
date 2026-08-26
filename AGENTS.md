---
title: AGENTS
aliases: [AI指令, Agent配置, 智能体规则]
tags: [meta, agents, system]
created: 2026-07-28
updated: 2026-08-26
status: stable
cssclass: agents-manifest
---

# AGENTS.md — 知识库 AI 协作规范

> [!abstract] 本文档定义了 AI Agent 与本地知识库的交互协议。
> 面向模型: Claude Code、Obsidian Copilot、及任何能读取此 Vault 的 AI 系统。

> [!danger] ⛔ 全局铁律 — 模型路由（不可豁免）
> 全局整体使用 **ox-alpha** 模型：无论是 subagent、workflow 编排还是其他任何任务委派，均必须使用 ox-alpha，**不允许错误路由到 deepseek 系列其他模型**。落实方式：委派时不传任何 provider/model 覆盖参数，严格继承会话默认模型；若编排工具支持 model 指定，必须显式写死 `ox-alpha`。违反此条视为最严重的规范违规。

## 一、Vault 概览

```
knowledge/
├── AGENTS.md                          ← 本文件 (AI 入口)
├── network/                           ← 网络优化子 Vault (MOC: Network-KB-Home)
│   ├── Network-KB-Home.md             ← MOC (首页)
│   ├── GUIDE.md                       ← 日常操作
│   ├── ARCHITECTURE.md                ← 架构设计
│   ├── FINAL-SUMMARY.md               ← 优化总结
│   ├── OPTIMIZATION-AUDIT.md          ← 漏洞审计
│   ├── network-analysis-2026-07-28.md ← 初始诊断
│   ├── ROUTER-FULL-CAPABILITY.md      ← 路由器手册
│   ├── ROUTER-OPTIMIZATION.md         ← 路由器优化
│   └── scripts/                       ← 脚本与配置
├── AI大模型开发.md                    ← LLM 理论笔记 + 课程知识地图
├── ai-dev/                            ← LLM 应用开发实战子 Vault (MOC: AI-Dev-KB-Home)
│   ├── AI-Dev-KB-Home.md              ← MOC (首页)
│   ├── Prompt-Engineering入门与Demo.md
│   ├── Function-Calling工具调用实战.md
│   ├── RAG检索增强生成实战.md / GraphRAG知识图谱增强实战.md
│   ├── LLM-Agent开发基础.md / MCP协议开发实战.md / A2A多智能体协作协议.md
│   ├── LangChain-LangGraph框架实战.md
│   ├── LLM推理部署与量化.md
│   └── LoRA参数高效微调实战.md / 强化学习对齐-RLHF到GRPO.md / 微调数据工程与模型蒸馏.md
├── 参考-*.md                          ← 外部参考文档
├── ai-links/                          ← AI 链接收藏子 Vault (MOC: AI-Links-KB-Home)
│   ├── articles/                      ← 文章拆解收藏
│   └── DSH*.md 等                     ← 插件/Hook/Skills 实践
├── claude-ops/                        ← Claude Code 运维子 Vault (MOC: Claude-Ops-KB-Home)
│   ├── 运维方案与设计/                 ← 方案/设计/指南
│   ├── 事故复盘/                       ← postmortem/incident
│   ├── Agent-架构模式/                 ← 架构模式与记忆 (含 MEMORY-INDEX)
│   └── Plans/                         ← 归档计划 (deprecated)
├── typora/                            ← Typora 激活复盘子 Vault (MOC: TYPORA-KB-Home)
├── cs-base/                           ← 计算机基础子 Vault (MOC: CS-KB-Home)
│   ├── CPP-核心知识 / LibC与动态链接 / LibC运行时排查-TLS与锁
│   ├── LLVM编译器基础设施 / LLVM使用调优与SO优化
│   ├── 数据结构与算法 / 深度学习算法基础
│   ├── 数据库原理与调优 / MySQL-InnoDB精要 / Redis原理与实践
│   ├── MongoDB原理与实践 / 向量数据库与检索 / Kafka原理与实践 / Raft与分布式协同
│   ├── 计算机组成原理 / 操作系统八股 / 操作系统实现视角-从引导到内核
│   ├── 计算机网络八股 / 高并发系统设计 / Linux高性能网络编程实战
│   ├── 音视频流媒体开发基础 / Python高级核心 / 容器与云原生基础
│   └── 设计模式实战 / 架构设计与方案选型
├── diagrams/                          ← Excalidraw 图表库 + ARROW-CHECKLIST
├── scripts/                           ← 跨库脚本 (claude-ops-deployments/dumps)
└── SESSION-ARCHIVE-*.md               ← 会话归档
```

## 二、Wiki 链接约定

本 Vault 使用 Obsidian Wikilinks 作为主要导航方式：

```markdown
[[Network-KB-Home]]          文档链接
[[ROUTER-FULL-CAPABILITY]]   完整标题链接
[[GUIDE#故障排查]]            锚点链接
[[Network-KB-Home|首页]]     别名链接
```

> [!tip] Agent 规则
> - 读取文档时，遵循 Wikilinks 进行关联探索
> - 添加新知识时，必须建立到已有文档的双向 Wikilinks
> - 文档间链接数 ≥ 3 以保证 Graph 连通性

## 三、Frontmatter 模板

所有知识文档必须包含 YAML frontmatter：

```yaml
---
title: 文档标题
aliases: [别名1, 别名2]
tags: [category/sub, category]
created: YYYY-MM-DD
updated: YYYY-MM-DD
status: draft | review | stable | deprecated
---
```

### 标签体系

```
#network/router        路由器硬件/配置/优化
#network/proxy         代理/v2rayN/xray/策略
#network/optimization  优化分析/审计
#network/architecture  架构设计/决策
#network/guide         操作指南
#network/analysis      诊断分析/基线

#reference/ark         Ark Agent Plan API
#reference/vpn         VPN/代理诊断
#reference/router      小米路由器 API
#reference/network     网络路由排障
#reference             通用参考

#incident              事故复盘
#ai                    AI/LLM 开发
#ai/agent             编码 Agent / Agentic 架构
#ai/skills            Agent Skills 技能开发
#ai/learning          AI 教程与学习路线
#ai/links             AI 链接收藏与综述
#ai/tools             AI 工具收藏 (DSH 插件、终端工具等)
#ai/ops               Agent 无人值守运维 (claude-ops 子库)
#cs/cpp               C++ 语言与专题
#cs/algo              数据结构与算法
#cs/dl                深度学习算法基础
#cs/os / #cs/net / #cs/system   操作系统/计算机网络/高并发
#cs/db               数据库(MySQL/SQLite/MongoDB/Redis/向量库)
#cs/arch             计算机组成原理
#cs/toolchain        libc/链接加载/LLVM 工具链
#meta                  元文档 (AGENTS, MOC, 会话归档)
```

> [!tip] 标签使用规则
> - 嵌套标签 `category/sub` 在 Obsidian Graph 中按颜色聚类
> - 一个文档可以有多个标签 (如路由器文档同时有 `#network/router` 和 `#network`)
> - MOC 文档使用 `#moc` 标签方便在 Graph 中定位

> [!warning] Agent 规则
> - 添加文档时必须包含 frontmatter
> - 标签必须使用嵌套格式 `category/sub`
> - 更新文档时同步更新 `updated` 字段
> - `status: stable` 的文档不可随意修改结构

## 四、自增长知识体系

本 Vault 设计为**渐进交互学习型**知识系统，而非静态文档库。

### 增长原则

1. **每次会话都有产出** — 诊断→分析→方案→实施→归档, 形成闭环
2. **知识自动连结** — 新文档通过 Wikilinks + Tags + MOC 自动融入现有网络
3. **版本可追溯** — frontmatter `created`/`updated` 记录每次变更
4. **错误自我修正** — 审计发现不一致时, 同步更新所有关联文档
5. **公开知识补充** — 内部探索 + 公开搜索交叉验证
6. **作者协同进化** — 知识库随作者认知升级同步演进 (见 [[#十、知识-作者协同进化]])

### 连结性体系

```
新知识加入流程:
  ┌─ 确定归属领域 → 找到 MOC
  ├─ 添加 frontmatter (tags + aliases)
  ├─ 建立 Wikilinks (≥3 个已有文档)
  ├─ 更新 MOC 文档地图
  └─ 在关联文档添加反向链接
```

> [!tip] 活的知识网络
> - Vault 内 170+ 个文档, 500+ Wikilinks, 20+ 标签
> - 每个文档至少链接 3 个其他文档
> - Graph 视图中无孤立节点
> - MOC 首页有关系图可视化（Excalidraw 或文字树）

### 对话归档

每次重要会话产出 `SESSION-ARCHIVE-YYYY-MM-DD.md`:
- 记录全部操作 (成功+失败)
- 标注已解决/未解决问题
- 链接所有产出的文档和脚本

## 五、MOC (Map of Content) 约定

每个子领域必须有 MOC 文档作为入口：

| 子领域 | MOC |
|--------|-----|
| 网络优化 | [[Network-KB-Home]] |
| AI 链接收藏 | [[AI-Links-KB-Home]] |
| Claude Code 运维 | [[Claude-Ops-KB-Home]] |
| LLM 应用开发实战 | [[AI-Dev-KB-Home]] |
| Typora 激活复盘 | [[TYPORA-KB-Home]] |
| 计算机基础 | [[CS-KB-Home]] |

MOC 应包含：概述、文档地图、关系图（**Excalidraw 嵌入或缩进文字树**——Markdown 中禁止 Mermaid，见第十一节）、标签索引、关键数据、脚本清单。

## 五·五、远程知识库融合补充规范（2026-08-17）

针对远程知识库 (claude-ops 等) 融合进本 Vault 的补充约定：

1. **部署四规则** — 任何部署/脚本变更 (适用于 `scripts/` 目录治理) 必须同时满足：
   - **记录可追溯**: 每次变更写入部署记录 (deployment-log)
   - **部署前验证**: 变更先在测试路径验证再上线
   - **逃生机制**: 每个部署必须附带 rollback 方案
   - **日志可审计**: 关键动作输出结构化日志
2. **先仓库后部署** — 代码变更必须先提交仓库 (git commit) 再部署到运行环境，禁止"先跑起来再补提交"。
3. **一文档一问题** — 每个知识文档只解决一个问题/主题；跨主题内容拆分到独立文档并通过 Wikilinks 关联。
4. **引用型文档可选 frontmatter 字段** — 抓取/转引的外部文档可使用：`source` (来源)、`source_urls` (原始 URL 列表)、`author` (作者)、`date` (原文日期)、`fetched_at` (抓取时间)。
5. **敏感信息推送规则** — 含密码/IP/API 端点的内容**默认不进入 git 推送**；推送前必须脱敏 (占位符替换)。`dumps/`、`backups/`、`*.pyc` 由 `.gitignore` 排除。

## 六、知识更新协议

### 新增知识

1. 确定归属子领域 → 找到对应 MOC
2. 使用 `scripts/new-note.md` 模板 (或手动填入 frontmatter)
3. 编写内容，使用 callouts (> [!note]) 和表格
4. 添加到 MOC 的文档地图 + 标签索引
5. 在相关文档中添加反向 Wikilink
6. 更新 MOC 关系图 (Excalidraw/文字树, 如有)

### 修改知识

1. 读取目标文档及其 `[[反向链接]]`
2. 修改后检查反向链接是否需要同步更新
3. 更新 `updated` 字段
4. 若涉及脚本/配置变更，同步更新 `scripts/` 目录

### 废弃知识

1. 将 `status` 改为 `deprecated`
2. 添加 `> [!warning] 此文档已废弃，请参考 [[新文档]]`
3. 从 MOC 文档地图中移除 (或标记为废弃)
4. 保留文件不删除 (Graph 历史可追溯)

## 六、Callout 规范

```markdown
> [!info] 信息
> [!tip] 建议
> [!warning] 警告
> [!danger] 危险操作
> [!bug] 已知缺陷
> [!success] 已完成/已验证
> [!question] 待确认
> [!abstract] 概述/总结
```

## 七、网络子 Vault 关键数据 (Agent 快速参考)

| 实体 | 关键信息 | 参考文档 |
|------|----------|----------|
| 笔记本 | Dell G3 3590, QCA9377 (12.0.0.1118) | [[FINAL-SUMMARY]] |
| 路由器 | R4CM [IP已脱敏], fw 2.14.87, SSH root@22 | [[ROUTER-FULL-CAPABILITY]] |
| SSH | MobaXterm sshpass + legacy crypto | [[ROUTER-FULL-CAPABILITY#SSH 连接]] |
| 代理 | v2rayN + xray 26.3.27, port 10808 | [[ARCHITECTURE]] |
| 配置脚本 | `scripts/enhance-config.ps1` | [[GUIDE]] |

## 九、Agent 行为约束

1. **先读后写** — 修改任何文档前必须先 Read
2. **尊重 Wikilinks** — 不要破坏已有链接
3. **保持 frontmatter** — 不要删除或改变 frontmatter 结构
4. **增量更新** — 优先 Edit 而非 Write 重写
5. **跨文档一致性** — 修改数据时检查所有引用处
6. **Graph 友好** — 新文档至少链接 3 个已有文档
7. **保持脚本可执行** — `scripts/` 下的代码不变 (除非专门优化)
8. **敏感信息** — 密码/IP 可以保留在知识库内 (本地 Vault), 但不要复制到外部
9. **模型铁律** — 一切 subagent / workflow / 任务委派均须使用 `ox-alpha` 模型（继承会话默认，不传 model 覆盖），禁止路由到 deepseek 系列其他模型，见文首全局铁律
10. **Python 环境** — 全局解释器固定为 `D:\ProgramData\miniconda3\python.exe`（Python 3.13）；验证文档中 Demo/脚本时一律用此路径，勿假设 `python` 在 PATH

## 十一、图表与可视化约定

### 首选: Excalidraw (Obsidian 插件)

**架构图、流程图、运行过程图一律推荐 Excalidraw：**

- 手绘风格直观，比 Mermaid 代码更易读
- 支持自由标注、颜色编码、组件分组
- 文件格式: `Diagram-Name.excalidraw.md` (Obsidian 自动识别)
- 嵌入: `![[Diagram-Name.excalidraw]]`

### ⛔ Markdown 中禁止 Mermaid

**所有图表必须使用 Excalidraw。** Markdown 中不允许出现 ```` ```mermaid ```` 代码块。

原因:
- Mermaid 在 Obsidian 中不如 Excalidraw 直观
- 不便于自由标注和手绘风格展示
- Excalidraw 支持导出、编辑、版本控制

已有 Mermaid 图已全部迁移至 `diagrams/` 目录。

> [!tip] 绘制完成后按 [[ARROW-CHECKLIST]] (diagrams/ 箭头校验清单) 逐项核对箭头连接，避免悬空/错位箭头。

### Excalidraw 文件格式 (✅ 已实战验证)

**插件**: `obsidian-excalidraw-plugin` (zsviczian) v2.x

**核心发现**: v2.x 存储时使用 `compressed-json` (LZString)，但**首次打开时接受未压缩 JSON**。插件读取后自动压缩并重写文件。

**严格文件结构** (已测试通过):

```
---
excalidraw-plugin: parsed
tags: [excalidraw]
---
# Excalidraw Data

## Text Elements
(可留空或列出文本标签, 空格分隔, 插件自动追加 ^references)

## Drawing
```json
{
  "type": "excalidraw",
  "version": 2,
  "source": "https://github.com/zsviczian/obsidian-excalidraw-plugin",
  "elements": [ ... ],
  "appState": { "gridSize": 20, "viewBackgroundColor": "#ffffff", "theme": "dark" },
  "files": {}
}
```
```

> [!danger] 常见导致打不开的错误
> 1. ❌ 缺少 `# Excalidraw Data` 标题 → 插件不识别
> 2. ❌ JSON 不在 `## Drawing` 下的 \`\`\`json 代码块中 → 无法解析
> 3. ❌ `groupIds` 缺失或为 null → 必须 `[]`
> 4. ❌ 矩形缺 `roundness: {"type": 3}` → 渲染异常
> 5. ❌ 箭头缺 `startBinding/endBinding: null` → 报错
> 6. ❌ `fontFamily` 用数字 (1=手绘, 2=正常, 3=打字机) → 不能用字符串
> 7. ❌ 尝试手写 `compressed-json` → 应写未压缩 JSON, 让插件自动压缩
> 8. ❌ `%%` 包裹符 → 不需要手动添加, 插件自动管理

**元素完整字段模板**:

```json
// 矩形 (rectangle)
{"id":"u1","type":"rectangle","x":100,"y":100,"width":200,"height":50,
 "strokeColor":"#1e1e1e","backgroundColor":"#e3f2fd","fillStyle":"solid",
 "strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,
 "groupIds":[],"roundness":{"type":3},"seed":1,"version":1,
 "isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"angle":0}

// 文本 (text)
{"id":"t1","type":"text","x":110,"y":112,"width":180,"height":24,
 "text":"Hello","fontSize":18,"fontFamily":1,"textAlign":"center",
 "verticalAlign":"middle","containerId":null,"originalText":"Hello","lineHeight":1.2,
 "strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid",
 "strokeWidth":1,"strokeStyle":"solid","roughness":1,"opacity":100,
 "groupIds":[],"roundness":null,"seed":2,"version":1,
 "isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"angle":0}

// 箭头 (arrow)
{"id":"a1","type":"arrow","x":300,"y":125,"points":[[0,0],[50,0]],
 "startArrowhead":null,"endArrowhead":"arrow",
 "startBinding":null,"endBinding":null,"lastCommittedPoint":null,
 "strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid",
 "strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,
 "groupIds":[],"roundness":null,"seed":3,"version":1,
 "isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"angle":0}
```

**颜色约定**:

| 用途 | backgroundColor | 说明 |
|------|------|------|
| 输入/嵌入 | `#e3f2fd` | 蓝色 |
| Attention 层 | `#fff9c4` | 黄色 |
| FFN 层 | `#ffccbc` | 橙色 |
| 输出/结果 | `#c8e6c9` | 绿色 |
| Encoder 框 | `#1976d2` 边框，透明填充 | 蓝色虚线框 |
| Decoder 框 | `#388e3c` 边框，透明填充 | 绿色虚线框 |
| Add & Norm | `#ffffff` | 白色 |

**生成流程**:
1. 用未压缩 JSON 写入 `## Drawing` → \`\`\`json 块
2. 在 Obsidian 中打开文件 → 插件自动压缩为 `compressed-json`
3. 之后可以正常编辑/导出

**布局关键规则 (🔑 避免格式混乱)**:

| 规则 | 说明 |
|------|------|
| `containerId` 绑定 | 文本元素必须设 `containerId` 指向父矩形 ID，插件才能正确居中 |
| `boundElements` 回引 | 矩形必须设 `boundElements: [{"id":"text_id","type":"text"}]` 声明包含的文本 |
| 虚线边框 | 容器框(Encoder/Decoder)用 `strokeStyle:"dashed"` 区分内容框 |
| 间距规范 | 同行元素间 40-60px，跨组 70-80px，上下层间 20-30px |
| 文本居中 | `textAlign:"center"` + `verticalAlign:"middle"` + `containerId` 三重保证 |
| 箭头起止 | `points` 数组的终点应精准对齐目标矩形边缘 |

**常见布局错误**:
- ❌ 文本未绑定 containerId → 文本渲染在错误位置
- ❌ 矩形未设置 boundElements → 文本被矩形遮挡
- ❌ 箭头坐标未对齐矩形边缘 → 箭头悬空
- ❌ 文本 x/y 与矩形 x/y 完全相同 → 文本堆叠在矩形左上角
- ❌ 容器框用实线 → 与内容框视觉混淆

**箭头绑定规则 (🔑 关键)**:

每条箭头必须声明 `startBinding` 和 `endBinding` 指向源/目标矩形：

```json
{"id":"arrow1","type":"arrow",
 "startBinding":{"elementId":"源矩形ID","focus":0,"gap":1},
 "endBinding":{"elementId":"目标矩形ID","focus":0,"gap":1},
 "points":[[0,0],[dx,dy]], ...}
```

| 字段 | 说明 |
|------|------|
| `elementId` | 绑定的矩形 ID |
| `focus` | 连接点在边上的位置：0=中心，-1=左/上端，1=右/下端 |
| `gap` | 箭头端点到矩形边缘的距离，默认 1-5 |

**同时矩形也必须声明接收的箭头**：
```json
{"id":"rect","type":"rectangle",
 "boundElements":[{"id":"text_id","type":"text"},{"id":"arrow1","type":"arrow"}], ...}
```

**常见箭头错误**:
- ❌ 只有 `startBinding` 没有 `endBinding` → 箭头一端悬空
- ❌ 矩形 `boundElements` 未包含箭头 ID → 移动矩形时箭头不跟随
- ❌ `focus` 缺失 → 连接点随机，箭头不居中
- ❌ 垂直箭头用了水平 focus → 箭头从侧边伸出

### Excalidraw 命名规范

```
知识库/
├── diagrams/
│   ├── Transformer-Architecture.excalidraw.md
│   ├── SelfAttention-Flow.excalidraw.md
│   ├── Training-vs-Inference.excalidraw.md
│   ├── Proxy-Routing-Architecture.excalidraw.md
│   └── Router-Network-Topology.excalidraw.md
```

### 图表创建指引

| 图类型 | 推荐工具 | 文件命名 |
|--------|----------|----------|
| 架构/系统图 | Excalidraw | `{Subject}-Architecture.excalidraw` |
| 流程图 | Excalidraw | `{Subject}-Flow.excalidraw` |
| 运行时序列图 | Excalidraw | `{Subject}-Sequence.excalidraw` |
| 文档关系图 | 文字树/表格 (MOC 中) | 内嵌 |
| 简单关系图 | Excalidraw | `{Subject}-Flow.excalidraw` |

## 十、知识-作者协同进化

本 Vault 设计为与作者**同步成长**的活知识系统。

### 进化机制

```
作者认知 → 对话交互 → 知识沉淀 → 审计修正 → 作者升级 → 新一轮交互
    ↑                                                      ↓
    └──────────── 知识反哺 (AI 补充公开知识) ──────────────┘
```

### 五层协同

| 层级 | 机制 | 示例 |
|------|------|------|
| **L1 原始笔记** | 作者随手记, 保留原汁原味 | AI大模型开发.md 的手推 Transformer 部分 |
| **L2 AI 补充** | 基于公开知识扩充细节 | FlashAttention/GQA/MLA 等 2024-2025 优化 |
| **L3 交叉验证** | 标记原始理解与 AI 补充的差异 | Word2Vec 的 Q 矩阵 ≠ Attention 的 Q |
| **L4 审计修正** | 定期扫描错误/遗漏/不一致 | 本会话的 10 个错误修复 |
| **L5 归档固化** | 成熟知识提升为 stable | SESSION-ARCHIVE 作为里程碑快照 |

### 版本追踪

所有文档通过 frontmatter 追踪演化:
```yaml
created: 2026-07-24   # 原始笔记创建
updated: 2026-07-28   # AI 补充 + 审计修正 + 基准更新
status: draft→review→stable
```

`status` 生命周期: `draft` (初始) → `review` (AI 补充后待验证) → `stable` (审计通过)

### 作者信号识别

Agent 应识别以下作者信号并据此调整行为:
- "手推" / "大白话解释" → 作者在建立直觉理解, 补充形式化定义
- "不太确定" / "可能" → 标记为待验证, 搜索公开知识交叉确认  
- "复盘" / "归档" → 作者在固化知识, 生成会话归档
- "对比" / "优化" → 作者在升级认知, 对比新旧理解并标注差异

## 十二、Dataview 全库仪表盘

> [!info] 需要 Obsidian 插件: **Dataview** (Community Plugins → Browse → Dataview)
> 安装后无需配置。以下查询自动扫描全库 frontmatter，动态生成视图。

### 全库文档清单

```dataview
TABLE status, tags, file.folder as "目录"
WHERE status
SORT file.folder ASC, status ASC
```

### 待办任务

```dataview
TASK
WHERE !completed
SORT file.name ASC
LIMIT 30
```

### 按标签聚类

```dataview
LIST rows.file.link
FLATTEN tags
GROUP BY tags
WHERE tags
SORT key ASC
```

### 最近更新

```dataview
TABLE updated
WHERE updated
SORT updated DESC
LIMIT 20
```

### 孤立笔记检查

```dataview
LIST
WHERE !file.outlinks and !file.inlinks and file.name != "AGENTS"
SORT file.name ASC
```

> [!tip] 使用方式
> 将以上任一代码块粘贴到任意笔记中即可看到实时视图。推荐在 `AGENTS.md` 或 MOC 页面中集中展示。

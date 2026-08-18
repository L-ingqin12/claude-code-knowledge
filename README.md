# Claude Code 无人值守知识库

> Claude Code 运维知识体系：从现象→根因→方案→部署的完整推导与产出。
> 所有文档均可独立阅读，彼此正交但交叉引用。

---

## 方案产出（按阅读顺序）

### 核心方案（解决具体问题）

| # | 文档 | 回答的问题 |
|---|------|-----------|
| 1 | [claude-socket-error-elimination-guide.md](./claude-socket-error-elimination-guide.md) | Socket 错误为什么会发生？如何从根源消除？ |
| 2 | [claude-network-resilience-v2.md](./claude-network-resilience-v2.md) | 网络中断时如何做到用户无感？为什么不需要守护进程？ |
| 3 | [claude-network-stability-gate.md](./claude-network-stability-gate.md) | 如何防止网络抖动时发出注定失败的请求？门控机制如何设计？ |
| 4 | [claude-interruption-resilience-guide.md](./claude-interruption-resilience-guide.md) | 中断后如何以最小开销恢复？三层恢复架构是什么？ |
| 5 | [claude-context-continuity-guide.md](./claude-context-continuity-guide.md) | 中断恢复后如何保证思路不跑偏？外部大脑如何设计？ |
| 6 | [claude-unattended-operation-plan.md](./claude-unattended-operation-plan.md) | 当前 Android/Termux/PRoot 环境如何配置无人值守？ |
| 7 | [claude-unattended-cross-platform-guide.md](./claude-unattended-cross-platform-guide.md) | 其他平台（Linux/macOS/Windows/Docker/CI）怎么做？ |

### 方法论

| # | 文档 | 回答的问题 |
|---|------|-----------|
| 8 | [claude-unattended-methodology.md](./claude-unattended-methodology.md) | 这些方案是怎么推导出来的？分析方法论是什么？ |

### 可部署组件

| 状态 | 文件 | 说明 |
|------|------|------|
| ✅ 当前 | [claude-resilience-proxy.py](./claude-resilience-proxy.py) | 网络韧性代理 v2（L0门控+L1预检+L2连接池+L3重试，四道防线） |
| ✅ 当前 | [claude-resilience-deploy.sh](./claude-resilience-deploy.sh) | 一键部署脚本（TCP调优+启动代理+创建恢复模板） |
| 🚨 当前 | [claude-rollback.sh](./claude-rollback.sh) | 逃生通道：一键回滚到部署前状态 |
| 📋 当前 | [claude-deployment-record.md](./claude-deployment-record.md) | 部署记录：完整修改清单 + 使用手册 + 日志示例 |

### 归档备用（暂不部署，保留供后续参考）

| 文件 | 说明 | 归档原因 |
|------|------|----------|
| [claude-full-guardian.sh](./claude-full-guardian.sh) | 完整守护脚本（进程崩溃检测 + --resume + 自动恢复） | Claude 不崩溃，不需要 |
| [claude-network-guardian.sh](./claude-network-guardian.sh) | 网络中断守护脚本（等网络恢复 + 自动拉起） | 代理门控已覆盖，不需要 |
| [claude-interruption-resilience-guide.md](./claude-interruption-resilience-guide.md) | 中断恢复完整方案（三层架构含守护） | L2/L3 层暂不部署，归档备用 |
| [claude-context-continuity-guide.md](./claude-context-continuity-guide.md) | 语境连续性（context-dump.md 外部大脑） | 格式已定义，待实际任务中启用 |

---

## 架构全貌（六层防御）

```
Layer 0  网络门控     ─ 不稳不发，等稳定后再发 
Layer 1  HEAD 预检    ─ 发请求前确认服务器可达
Layer 2  连接池+心跳   ─ 复用连接，45s 保活防 NAT 超时
Layer 3  透明重试     ─ socket 错误自动重试（3次, 1/3/8s backoff）
Layer 4  外部大脑     ─ context-dump.md 保存思维状态
Layer 5  中断恢复     ─ task-state.json + progress.log 保存任务进度

部署方式: bash claude-resilience-deploy.sh start
使用方式: ANTHROPIC_BASE_URL=http://[IP已脱敏]:8787/anthropic claude
```

## 推导链路（现象→根因→方案）

```
现象1: 弹窗要求确认 → 根因: 权限模型 → 方案: settings.json allow/deny
现象2: 终端关了Claude就没了 → 根因: 前台进程 → 方案: daemon模式
现象3: 不知何时触发任务 → 根因: 缺调度 → 方案: cron + CronCreate
现象4: 做完不知道结果 → 根因: 缺通知 → 方案: PushNotification/webhook
现象5: 网络中断任务白做 → 根因: 状态只在内存 → 方案: task-state.json
现象6: 恢复后思路跑偏 → 根因: 决策丢失 → 方案: context-dump.md
现象7: Socket错误频繁 → 根因: NAT超时+无keepalive → 方案: 代理+门控+重试
```

## 环境上下文

原始运行环境：
```
Android (aarch64) → Termux → PRoot → Ubuntu 24.04 → Claude Code v2.1.172
API 端点: https://api.deepseek.com/anthropic (DeepSeek Anthropic 兼容层)
```

约束：无 systemd、无 tmux、无 cron daemon、移动网络 NAT 超时 30-120s

## AI/ML 论文精读

| # | 文档 | 论文 | 答的问题 |
|---|------|------|----------|
| 1 | [SAE 视觉特征单义性](articles/SAE-视觉特征单义性-NeurIPS2025.md) | NeurIPS 2025 | SAE 拆 CLIP 视觉特征→单义特征，改一个神经元控制 LLaVA 输出 |
| 2 | [PatchSAE 概念重映射](articles/PatchSAE-概念重映射-ICLR2025.md) | ICLR 2025 | Adaptation 不学新概念，只选择性重映射旧概念 |
| 3 | [Claude Code 记忆机制源码拆解](articles/Claude-Code记忆机制源码拆解.md) | 小林coding | 两层架构×六层级×四类型——不用向量数据库的记忆系统 |
| 4 | [Claude Code 实用 Skills 参考](articles/Claude-Code实用Skills参考.md) | 小金AI | Superpowers/TDD/Code Review/Web Access 等 10 个 Skills 清单 |
| 5 | [上下文工程：注意力预算与四层解法](articles/上下文工程-注意力预算与四层解法.md) | 吴师兄学大模型 | 为什么窗口越大模型越蠢——注意力稀释×Lost in the Middle×Context Rot 与四层解法 |
| 6 | [上下文工程落地实践：从理论到实现](articles/上下文工程落地实践-从理论到Claude-Code实现.md) | 多篇融合 | 四层解法×Claude Code 源码对应×自建 Agent 可抄代码——含三条铁律+十条原则 |
| 7 | [Skill 规模化管理：从渐进式披露到检索式发现](articles/Skill规模化管理-从渐进式披露到检索式发现.md) | 系统设计推演 | 当 1000 个 Skill 挤爆 system prompt——三层架构×四阶段迁移路径 |
| 8 | [Agent 驱动 Skill 迁移设计](articles/Agent驱动Skill迁移设计.md) | 系统设计 | 旧系统→新系统的自主迁移方案：五阶段×审计 trace 到单决策粒度×规模分档×依赖感知审批 |
| 9 | [日志检索分析系统 Skill 管理 Demo](articles/日志检索分析系统-Skill管理Demo设计.md) | 系统设计 | 25 skill × 5 namespaces × 15 依赖——框架在真实场景下的落点验证 |
| 10 | [Loop Engineering 深度拆解](articles/Loop-Engineering-深度拆解-从产品功能集到方法论包装.md) | 方法论拆解 | Loop 从产品功能集是怎么被包装成方法论的 |
| 11 | [给 LLM 做「脑扫描」：可解释性技术全景](articles/给LLM做脑扫描-可解释性技术全景.md) | 对话沉淀 | CT/核磁/三维扫描类比映射到 LLM 可解释性——四层技术栈×上手路径 |

> 📑 完整分组索引见 [articles/README.md](articles/README.md)（按可解释性 / 上下文工程 / Skill 系统 / 机制拆解四类归档，含阅读线索）。

## Demo 脚本（可运行）

| 脚本 | 运行方式 | 产出 |
|------|---------|------|
| [skill-registry.py](scripts/skill-registry.py) | `python3 scripts/skill-registry.py` | SkillRegistry 核心引擎：依赖链级联 + 条件过滤 + 检索索引，5 项单测 |
| [demo-skills.json](scripts/demo-skills.json) | 数据文件 | 19 个 skills × 4 namespaces 测试数据集（37% 声明依赖） |
| [skill-dependency-viz.py](scripts/skill-dependency-viz.py) | `python3 scripts/skill-dependency-viz.py` | ASCII 依赖树 + Token 对比表（全量 247→顶层 171→search_skills 15，节省 94%） |
| [demo-e2e-test.py](scripts/demo-e2e-test.py) | `python3 scripts/demo-e2e-test.py` | 3 个真实场景端到端：前端开发 88.5% / 数据管道 85.2% / 全栈 63.8% token 节省 |
| [restructure-claude-md-demo.sh](scripts/restructure-claude-md-demo.sh) | `bash scripts/restructure-claude-md-demo.sh` | CLAUDE.md 从单体 795 token → @include 模块化 477-647 token |
| [Skill 迁移 Demo](scripts/migration/) | `bash scripts/migration/run_demo.sh` | Agent 驱动 5 阶段迁移（发现→分类→审核→执行→验证），12 旧 skill → 6 namespace，审计 trace 到单决策，token 节省 73% |
| [日志系统 Skill Demo](scripts/logsystem/) | `bash scripts/logsystem/run_demo.sh` | 25 skill × 5 namespace 插件式管理，3 场景（OOM/审计/RCA），token 节省 83% |
| [components/](scripts/components/) | `from components import audit, classifier` | 可复用基础层：AuditTrail（session/快照/报告）+ SkillClassifier（规则分类/依赖推断/规模分档） |

## 关键设计决策

| 决策 | 理由 | 日期 |
|------|------|------|
| 代理而非修改 Claude 源码 | 对 Claude 透明，对所有 API 兼容 | 2026-06-11 |
| 门控等待而非盲目重试 | 避免 thinking 进行中被中断 | 2026-06-11 |
| 新会话注入恢复 Prompt 而非 --resume | --resume 不恢复对话上下文 | 2026-06-11 |
| 代理缓冲而非流式转发 | 部分响应不转发给 Claude，避免不一致 | 2026-06-11 |
| context-dump.md 存 WHY 而非 WHAT | 决策理由比重做步骤更贵 | 2026-06-11 |

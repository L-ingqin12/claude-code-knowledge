---
name: opencode-multi-agent-architecture
description: OpenCode 两层智能体架构的设计原理与自规划调度机制
metadata: 
  node_type: memory
  type: reference
  originSessionId: 833ec90b-fd64-4736-8eda-362e765d3f55
---

# OpenCode 多智能体协作架构

## 仓库
https://github.com/L-ingqin12/opencode-multi-agent-system

## 核心架构

### 两层模型
- **Primary Agent** (`mode: primary`): 唯一入口，用户通过 Tab 切换。不能被子智能体调用。
- **Subagent** (`mode: subagent`): 被调用，不在 Tab 显示。每次调用创建隔离会话。

### 子智能体调用机制
格式: `{子智能体名称}, {任务描述}`
OpenCode 运行时识别子智能体名称并自动创建隔离会话。

### 自规划算法
```
用户请求 → 意图分析(关键词匹配) → 子智能体匹配 → 依赖判断 → 并行/串行
```
- 简单操作（读文件、搜索）→ 自己处理
- 单一专业任务 → 委托对应子智能体
- 复合任务 → 分解后按依赖关系并行/串行

### Fan-Out 扇出模式
一次分解 N 个子任务并行分发。OpenCode 原生不支持，需插件：
- opencode-agent-intercom: `spawn()` 非阻塞创建（最成熟方案）
- swarm-control: `/swarm_spawn` 文件级分解 + 文件锁
- Ephemeral Team (提案中): 原生 `team()` API with DAG

### 权限设计
- 审查/审计类只读（防幻觉破坏性修改）
- task 工具仅 orchestrator 开启（防递归嵌套，社区有 612 层嵌套的惨案）

## 与本项目的关联
这是针对 OpenCode 而非 Claude Code 的架构设计。两个系统的 Agent 模式有相似之处但实现不同。

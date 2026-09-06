---
title: Claude Code 缓存命中率下降 — 排查复盘报告
aliases: []
tags: [ai/ops, incident]
created: 2026-06-12
updated: 2026-08-25
status: stable
---

# Claude Code 缓存命中率下降 — 排查复盘报告

See also: [[Claude-Ops-KB-Home]] · [[cc-cache-hitrate-35pct-postmortem]] · [[claude-cache-strategy]]

> 日期: 2026-06-12 ~ 2026-06-13 | 版本: v2.1.150 → v2.1.174

---

## 一、问题概述

CC 版本升级后（v2.1.150 → v2.1.172+），DeepSeek API 后台显示缓存命中率显著下降：

| 模型 | 升级前 | 升级后 | 降幅 |
|------|--------|--------|------|
| Pro | 99.2%-99.7% | 90%-96% | ~3-7% |
| Flash | ~90%+ | 50% 或更低 | ~40%+ |

**影响**: token 消耗大幅增加，成本上升。

---

## 二、排查过程

### 2.1 环境确认

```
CC v2.1.174 → Permafrost :8788 (缓存对齐) → Proxy :8787 (韧性) → DeepSeek Anthropic
```

- 所有请求通过双层代理
- permafrost 负责缓存优化（去 cache_control、工具排序、env 冻结、规范序列化）
- proxy 负责网络韧性（重试、keepalive）

### 2.2 排除假阳性

最初怀疑 permafrost 不生效，但通过对比测试确认：
- DeepSeek Anthropic 端点**确实支持前缀缓存**（字节级前缀匹配，≥64 tokens 最小单元，异步写入 ~6-60s）
- permafrost 侧显示 97%+ 命中率，但 DeepSeek 后台低得多

### 2.3 发现绕过流量

关键发现：**shell rc 文件和 settings.local.json 指向不同端口**。

```
settings.local.json → http://127.0.0.1:8788  (permafrost ✅)
.zshrc              → http://127.0.0.1:8787  (proxy 直连 ❌)
.bashrc             → http://127.0.0.1:8787  (proxy 直连 ❌)
```

两个旧 CC session 绕过了 permafrost，请求未经缓存优化直发 DeepSeek → 0% 命中率。

**修复**: 统一 shell rc 指向 `:8788`。

### 2.4 请求体捕获分析

在 permafrost 中启用 `DUMP_DIR`，捕获 30+ 个真实 CC 请求体，逐对对比分析。

**主流 session (Pro 模型)**: 29 个请求
- system block: 2 个，跨请求完全稳定 ✅
- tools: 10 个，按 name 排序，跨请求稳定 ✅
- messages: 394→581 条，逐对相邻对比，前缀匹配率 25/27 = 92.6%
- 发现 **2 个断点**：

```
断点1 (req-001→002): msg[0] 从 1828→9085 bytes
  └─ 差异: currentDate 从 2026/06/12 → 2026/06/13 (跨天)
  └─ 影响: 前缀从第 0 字节全部失效

断点2 (req-027→029): msg[0] 从 9085→1828 bytes
  └─ 原因: compaction/loop 重写消息
  └─ 影响: 前缀从第 0 字节全部失效
```

### 2.5 根因定位

CC 将 `system-reminder`（含 `currentDate`）注入到 **`messages[0]`** — 对话的第一条消息。这是 DeepSeek 前缀缓存的起点。

```
请求结构: [msg0(currentDate)] [msg1] [msg2] ... [msgN]
                ↑
         跨天时日期变化 → 字节级前缀破坏 → 全量 cache miss
         compaction 重写 → 字节级前缀破坏 → 全量 cache miss
```

这与微信公众号文章的核心原则「**稳定在前，易变在后**」直接违背 — `currentDate` 这个最易变的内容被放在了缓存前缀的起点位置。

### 2.6 v2.1.150 对比验证

在隔离环境安装 v2.1.150，通过 permafrost dump 捕获请求，对比分析：

| 检查项 | v2.1.150 | v2.1.174 |
|--------|----------|----------|
| `currentDate` 在 `msg[0]` | ✅ 是 | ✅ 是 |
| system block 稳定性 | ✅ | ✅ |
| tools 稳定性 | ✅ | ✅ |
| 结构差异 | system block[0] 措辞不同 | — |

**结论**: 两个版本结构相同，v2.1.150 没有先天缓存优势。升级后命中率下降的主因是：
1. 旧 session 绕过 permafrost（shell rc 指向错误，已修复）
2. v2.1.172+ 的 compaction 触发更频繁（嵌套子 agent、`/loop` 特性）
3. 跨天 `currentDate` 变化导致缓存全部失效

---

## 三、解决方案

### 3.1 应急方案 B：Permafrost 直连 DeepSeek

部署 permafrost v0.3.0 作为缓存对齐代理，绕过尚未稳定的 Node.js proxy。

```
CC → Permafrost :8788 → DeepSeek
```

命中率: 85%→97%（取决于 session 生命周期）

### 3.2 目标方案 C：双层代理

Proxy 稳定后，串联部署：

```
CC → Permafrost :8788 → Proxy :8787 → DeepSeek
      (缓存对齐)          (韧性重试)
```

### 3.3 Shell RC 修复

统一所有 CC 入口指向 permafrost `:8788`，消除绕过流量。

### 3.4 currentDate 稳定化补丁

在 permafrost `align_request()` 流水线中新增 `stabilize_current_date()` 函数：

```python
_RE_CURRENT_DATE = re.compile(r"(Today's date is )\d{4}[-/]\d{2}[-/]\d{2}")

def stabilize_current_date(body, report):
    """将 currentDate 替换为固定值，防止跨天/compaction 缓存失效"""
    # 遍历 messages, 替换日期为 "2000-01-01"
```

原理与 permafrost 已有的 billing nonce 稳定化一致。已验证生产环境生效（`date_stabilized: 1`）。

### 3.5 四级逃生通道

| 级别 | 命令 | 场景 |
|------|------|------|
| L1 | `permafrost-rollback.sh` | C→B (proxy 故障) |
| L2 | `permafrost-rollback.sh full` | C/B→直连 DeepSeek |
| L3 | `permafrost-rollback.sh disable-auto` | auto-deploy 死循环 |
| L4 | `permafrost-rollback.sh nuke` | 完全清零 |

> [!note] 级数勘误 (2026-08-25): 本节是 06-13 时的四级（结构级 L1-L4）定义。06-17 补丁事故后通道扩充为七级 — 新增补丁级 L0m（关 model 路由）/L0a（关 tools 重排）/L0b（关全部补丁），权威定义见 `scripts/claude-ops-deployments/root-scripts/claude-permafrost-rollback.sh`。

### 3.6 版本快速切换器

```bash
bash /root/claude-version-switch.sh 2.1.150  # 秒级切换
bash /root/claude-version-switch.sh rollback  # 回退
```

支持 v2.1.150/172/173/174/177 五版本共存，自动处理 glibc/musl 平台选择。

### 3.7 缓存监控守护

每 60s 检查命中率、prefix_changes、miss_ratio：
- 命中率 < 70% → 自动触发诊断 dump
- prefix_changes > 0 → 自动触发 dump
- 异常时自动捕获 permafrost 快照 + 请求体 + proxy 日志

---

## 四、架构总览

```
                    ┌─────────────────────────────┐
                    │   claude-cache-monitor.sh   │  监控守护 (60s)
                    │   命中率 < 70% → 自动dump   │
                    └──────────────┬──────────────┘
                                   │ 轮询 stats
                                   ▼
Claude Code ────▶ Permafrost :8788 ────▶ Proxy :8787 ────▶ DeepSeek
  (v2.1.174)      │ 缓存对齐层             │ 韧性层            │
                  │ ├─ currentDate→固定    │ ├─ 重试3次       │
                  │ ├─ cache_control剥离    │ ├─ keepalive 60s │
                  │ ├─ 工具排序            │ └─ 透明转发      │
                  │ ├─ env冻结+增量        │                  │
                  │ ├─ 冷锚点合并          │                  │
                  │ └─ DUMP_DIR持续捕获     │                  │
                  │                        │                  │
                  └── /permafrost/stats ──▶ 监控              │
                  └── /permafrost/doctor ▶ 诊断              │
                  └── /permafrost/dumps/ ▶ 请求体归档        │
```

逃生路径: `C → B → 直连DeepSeek` (四级)

版本切换: `claude-version-switch.sh` (秒级)

---

## 五、文件清单

```
生产脚本 (/root/)
├── claude-permafrost-deploy.sh      方案 B↔C 切换
├── claude-permafrost-rollback.sh    四级逃生通道
├── claude-version-switch.sh         版本快速切换
├── claude-cache-monitor.sh          缓存监控守护
├── claude-resilience-proxy.js       Node.js 韧性代理
├── claude-resilience-deploy.sh      proxy 启停 (历史兼容)
└── claude-rollback.sh              完全回滚到直连

配置
└── ~/.claude/settings.local.json     CC 环境变量 (ANTHROPIC_BASE_URL 等)

运行时数据
├── ~/.permafrost/dumps/             请求体归档 (持续积累)
├── ~/.permafrost/monitor/           监控状态 + dump 历史
└── ~/.permafrost/proxy.log          permafrost 日志

补丁
└── ~/.claude/plugins/cache/permafrost/.../permafrost_align.py  ← currentDate 稳定化
```

GitHub: `L-ingqin12/claude-code-knowledge`

---

## 六、经验教训

1. **升级前先抓请求体**: 如果有 v2.1.150 的 dump 数据，对比分析只需几分钟
2. **配置一致性校验**: shell rc / settings / env 多处配置容易出现不一致
3. **permafrost .pyc 缓存陷阱**: 修改 Python 源码后必须清 `__pycache__/`，否则旧字节码继续生效
4. **prod 操作先验证再执行**: 每次 kill permafrost 都导致 session 中断，需要在隔离环境先测试通过
5. **DeepSeek 缓存 TTL 远长于 Claude**: 数小时到数天 vs 5分钟 — 这意味着 compaction 的破坏更持久
6. **监控先于排查**: 如果一开始就有 cache-monitor，异常时自动 dump 可省去大量手动工作

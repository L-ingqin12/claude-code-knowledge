# Claude Code × DeepSeek 缓存命中率优化方案

> 部署日期: 2026-06-12 | 当前版本: 方案 B (应急) → 目标: 方案 C (双层)

---

## 一、问题根因

### 1.1 双重不兼容

| 层级 | 问题 | 表现 |
|------|------|------|
| **请求层** | CC 发送 Anthropic `cache_control` 断点 → DeepSeek 不识别此标记，位置漂移破坏前缀逐字节匹配 | `cache_creation_input_tokens` 始终为 0 |
| **响应层** | DeepSeek 原生 API 用 `prompt_cache_hit_tokens`/`prompt_cache_miss_tokens`，Anthropic 兼容端点回 `cache_read_input_tokens`/`cache_creation_input_tokens`，但均返回 0 | CC 观测命中率为 0% |

### 1.2 两种缓存体系

| 维度 | Anthropic (Claude 原生) | DeepSeek (当前后端) |
|------|------------------------|---------------------|
| 缓存类型 | **显式** — `cache_control` 标记断点 | **自动** — 前缀字节精确匹配 |
| 匹配方式 | 前缀到断点，断点后可变化 | 从第 0 字节起**完全一致**才命中 |
| 最小单元 | token 级别 | 64 token 存储单元 |
| 命中价格 | 原价 10% | 原价 ~2%（约 50 倍价差） |
| 写入方式 | 同步 | **异步**（约 6-60s） |

### 1.3 实测验证

```json
// 第一次请求（字节级完全相同的两个请求）
{"usage": {"cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}}

// 60s 后第二次请求（相同内容）
{"usage": {"cache_read_input_tokens": 128, "cache_creation_input_tokens": 0}}
//  ↑ 缓存命中！
```

结论：DeepSeek 的 Anthropic 兼容端点**确实支持前缀缓存**，但有两个前提：
1. 前缀 ≥ 64 tokens（DeepSeek 缓存最小单元）
2. 异步缓存写入需等待 6-60s

### 1.4 三类前缀破坏因素

| # | 破坏因素 | 根因 | 影响 |
|---|---------|------|------|
| 1 | `cache_control` 标记位置漂移 | CC 每轮断点位置不同 | 前缀字节变化 |
| 2 | 工具定义顺序不固定 | MCP 服务器重连时可能重排 | 前缀第 0 字节变化 |
| 3 | 动态 system 内容 | cwd、日期、git status 写入 env 块 | 前缀每轮变化 |

---

## 二、Hermes 前缀缓存三原则

参考微信公众号文章的核心设计原则：

| 原则 | 含义 | 在 permafrost 中的实现 |
|------|------|----------------------|
| **① 稳定在前，易变在后** | 最稳定的内容（身份、工具指引）放最前，时间戳等放最后 | aggressive 模式：env 块冻结 + 仅传增量 |
| **② 记忆冻结快照** | 会话开始时的记忆快照，中途不变 | CC 的 CLAUDE.md 在会话期间不变时自动受益 |
| **③ 字符上限强制周转** | 有限容量，满了淘汰旧的 | 前缀稳定 = 缓存命中 ≈ 低成本 |

---

## 三、架构方案

### 3.1 方案 B（当前应急）

```
Claude Code ──▶ Permafrost :8788 ──▶ api.deepseek.com/anthropic
                  │
                  ├─ 去 cache_control
                  ├─ 工具按 name 排序
                  ├─ env 块冻结 + 增量传输
                  └─ 规范 JSON 序列化
```

**适用场景**：proxy 不可用时的应急方案

### 3.2 方案 C（目标）

```
Claude Code ──▶ Permafrost :8788 ──▶ Proxy :8787 ──▶ api.deepseek.com/anthropic
                  │                       │
                  ├─ 缓存对齐              ├─ TCP keepalive (60s)
                  ├─ 冷锚点合并            ├─ socket 错误重试 (3次)
                  └─ 空闲保活              └─ 透明转发
```

**适用场景**：正常生产环境，缓存 + 韧性双层保障

---

## 四、部署与运维

### 4.1 文件清单

```
部署脚本 (2 个)
├── /root/claude-permafrost-deploy.sh     ← 方案 B↔C 切换
└── /root/claude-permafrost-rollback.sh   ← 独立 C→B 逃生

底层代理
├── /root/claude-resilience-proxy.js      ← Node.js 韧性代理 (:8787)
├── /root/claude-resilience-deploy.sh     ← proxy 启停（历史兼容）
└── /root/claude-rollback.sh              ← 完全回滚到直连

缓存代理
└── ~/.claude/plugins/cache/permafrost/   ← permafrost v0.3.0 插件

配置
└── ~/.claude/settings.local.json         ← CC 环境变量 (ANTHROPIC_BASE_URL 等)
```

### 4.2 日常运维

```bash
# 查看当前状态和链路
bash /root/claude-permafrost-deploy.sh status

# 部署方案 C (permafrost → proxy → DeepSeek)
bash /root/claude-permafrost-deploy.sh start

# 逃生 C→B (proxy 出问题时绕过)
bash /root/claude-permafrost-deploy.sh rollback
# 或独立逃生脚本
bash /root/claude-permafrost-rollback.sh

# 完全回滚到直连 DeepSeek (绕过所有代理)
bash /root/claude-rollback.sh
```

### 4.3 监控缓存命中率

```bash
# 实时统计
curl -s http://[IP已脱敏]:8788/permafrost/stats | python3 -m json.tool

# 诊断前缀变化
curl -s http://[IP已脱敏]:8788/permafrost/doctor | python3 -m json.tool

# CC 内 slash 命令
/permafrost:status
/permafrost:doctor
/permafrost:benchmark
```

### 4.4 逃生通道层级

```
C→B:  permafrost 绕过 proxy, 直连 DeepSeek (2s 切换, CC 无感)
      脚本: bash /root/claude-permafrost-rollback.sh

B→直连: 完全绕过所有代理, CC 直连 DeepSeek
      脚本: bash /root/claude-rollback.sh
      注意: 此操作会丢失缓存命中率优化
```

---

## 五、实测数据

### 5.1 缓存命中率

| Session | 请求数 | 命中率 | 缓存命中 tokens |
|---------|--------|--------|----------------|
| 4c43... | 8 | 87.1% | 702,848 |
| 9b34... | 28 | 83.6% | 1,093,120 |
| 9bbb... | 15 | 86.7% | 2,774,784 |
| **总体** | **58** | **85.98%** | **4,571,008** |

成本节省：83.1%（$0.75 → $0.13）

### 5.2 方案 C 链路测试（2026-06-12）

```
L1  proxy (:8787) 独立转发           ✅ PASS
L2  permafrost→proxy 串联转发         ✅ PASS
L3  串联链路缓存命中 (128 tokens)      ✅ PASS
```

---

## 六、已知限制

| 限制 | 影响 | 缓解 |
|------|------|------|
| DeepSeek 异步缓存写入 (~6-60s) | 首轮请求无法命中 | 冷锚点合并 (permafrost coalesce) |
| 新会话需要先"预热"缓存 | 前几轮全价 | 后续命中可摊平 |
| 前缀变化导致缓存全量失效 | 工具变化/模型切换/CLaUDE.md 变更 | aggressive 模式 env 冻结 |
| 无 systemd 自启 | permafrost/proxy 异常退出需手动恢复 | session_start hook 自动拉起 |
| PRoot 环境无 sysctl | 内核 TCP 不可调 | 应用层 socket.setKeepAlive(60s) |

---

## 七、后续计划

- [x] 根因诊断 (2026-06-12)
- [x] 方案 B 应急部署 (2026-06-12)
- [x] 方案 C 脚本 + 逃生通道就绪 (2026-06-12)
- [ ] 方案 C 生产切换（待用户确认）
- [x] Proxy 内建缓存优化 → 评估废弃，permafrost 已全覆盖 (详见 [claude-cache-proxy-evaluation.md](claude-cache-proxy-evaluation.md))
- [ ] 长时间运行后评估 permafrost keepalive 是否需要开启

## 八、后续调研（2026-06-12）

### 8.1 Keepalive 评估

DeepSeek 缓存 TTL 为「数小时到数天」（LRU 淘汰，无固定值），远长于 Claude 的 5 分钟。当前 97.47% 命中率说明缓存淘汰不是瓶颈。`PERMAFROST_KEEPALIVE_S` 开启会发出计费请求（命中价 ~$0.00003/次），**建议先不开启**，等长期运行数据出来再评估。

### 8.2 监控增强

- Statusline 集成：permafrost 已有 `scripts/statusline.sh`，可在终端显示缓存命中率
- 降级告警：命中率骤降时通知
- 成本日报：每日 token 汇总

### 8.3 Proxy 增强

现有 proxy 已足够（透明转发+重试+keepalive）。连接池复用、响应头注入等功能 ROI 低，已被 permafrost 覆盖。

### 8.4 CC 升级兼容性

版本 v2.1.173。升级前应在隔离端口运行 permafrost doctor，确认新版本的请求结构未引入新的前缀破坏因素。

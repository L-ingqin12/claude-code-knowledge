---
title: 缓存优化事故复盘
aliases: []
tags: [ai/ops, incident]
created: 2026-06-16
updated: 2026-08-25
status: stable
---

# 缓存优化事故复盘

See also: [[Claude-Ops-KB-Home]] · [[claude-cache-postmortem-2026-06-13]] · [[claude-cache-optimization]]

> 日期: 2026-06-16 | 影响: 多次会话中断 | 根因: permafrost 代码补丁 + 反复重启 + 竞态条件

---

## 一、时间线

| 时间 | 事件 |
|------|------|
| 06-13 | 方案 B 应急部署，permafrost 原版运行，命中率 85%-97% |
| 06-16 | CC 自动升级 v2.1.177，新增 WebSearch/WebFetch 工具，锚点分裂 |
| 06-16 | 切入 v2.1.177 后命中率降至 70%（Pro）44%（Flash） |
|  | 开始尝试 permafrost 代码补丁修复 |
|  | → currentDate 稳定化补丁（第一次重启） |
|  | → normalize_tools 工具集重排补丁（第二次重启） |
|  | → normalize_tools 反复调整（第三、四次重启） |
|  | 每次重启 permafrost 导致会话中断 |
|  | 补丁加载后引入 Python .pyc 缓存问题 |
|  | 部署脚本端口竞态条件导致 L1 逃生失败 |
|  | 用户手动回滚至直连 DeepSeek |
| 06-16 | 最终回退：clean permafrost + v2.1.174 + 直连 DeepSeek |

## 二、根因分析

### 直接原因

1. **反复重启 permafrost** — 每次 `kill` + 重新启动导致 2-5s 停机窗口，CC 连接中断
2. **Python .pyc 缓存** — 修改 `.py` 源文件后未清除 `__pycache__/`，旧字节码继续运行
3. **部署脚本端口竞态** — `kill` 后立即 `bind` 同一端口，`Address already in use`

### 深层原因

4. **测试与生产未隔离** — 补丁直接在生产的 `permafrost_align.py` 上修改，无独立测试环境
5. **缺少回滚门禁** — 每次改动前未先保存工作版本的完整快照
6. **反复修改同一文件** — 多次编辑导致文件状态混乱，最终无法确定哪个版本在运行

## 三、影响评估

| 维度 | 影响 |
|------|------|
| 会话可用性 | 多次中断（每次 permafrost 重启），用户需手动恢复 |
| 缓存命中率 | 从 97% → 70% → 恢复到 95%（补丁曾奏效） |
| 运维复杂度 | 配置被多次改写，hook 膨胀，需手动清理 |
| 用户时间 | ~3 小时排查 + 回退 |

## 四、哪些改动保留了，哪些回退了

### 保留

| 项目 | 说明 |
|------|------|
| 方案 C 架构 | permafrost → proxy → DeepSeek ✅ |
| 四级逃生通道 | L1-L4 rollback 脚本 ✅（06-17 后扩充补丁级 L0m/L0a/L0b，完整梯队七级）|
| 版本切换器 | `claude-version-switch.sh` ✅ |
| 缓存监控 | `claude-cache-monitor.sh` ✅ |
| 部署脚本端口修复 | deploy.sh 端口等待改为轮询 ✅ |

### 回退

| 项目 | 说明 |
|------|------|
| currentDate 稳定化补丁 | `stabilize_current_date()` — 已删除 |
| 工具集重排补丁 | `normalize_tools()` / `_ANCHOR_TOOLS` — 已删除 |
| permafrost_align.py | 重新从 npm 安装原版 |
| 所有自定义 hook | settings.local.json 恢复最简 |

## 五、经验教训

1. **永远不要在 permafrost 源码上直接改** — 用补丁目录 + 隔离测试，通过后再部署
2. **改配置不动代码** — 90% 的问题可以通过 URL/ENV/version 配置解决，不应触及源码
3. **重启前先验证** — 修改后先在隔离端口（:8789）测试，通过后切换上游
4. **保存工作快照** — 每次改动前 `cp` 备份原文件
5. **Python 修改后必清 .pyc** — 新增 `rm -rf __pycache__/` 到部署脚本
6. **生产操作需确认** — 涉及进程 kill 的操作先确认，不自动执行
7. **尊重"如果没坏就别修"原则** — 97% 命中率已经足够好，追加优化收益递减

## 六、改进措施

1. permafrost 补丁 → 独立测试端口 :8789 验证 → 确认后切换上游（不重启）
2. 部署脚本已加入端口等待轮询（修复竞态）
3. 源码备份到 `patches/` 目录
4. CC 版本锁定 + 自动更新禁用

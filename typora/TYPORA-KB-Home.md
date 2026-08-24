---
title: TYPORA-KB-Home
aliases: [Typora 知识库, Typora MOC, Typora 技能]
tags: [moc, software/typora]
created: 2026-08-10
updated: 2026-08-25
status: stable
---
# Typora 知识库 — MOC

See also: [[AGENTS]] | [[AI大模型开发]] | [[v2rayn-balancer-复盘-2026-08-09]]

## 概述

本子 vault 沉淀 Typora 1.13.2 的破解逆向与**无补丁激活流程**：最近文件 bug 的根因（4 字节 jsc 补丁）、激活机制（publicDecrypt / renew 流程）、完整性校验机制，以及可复用的"官方安装器 + 运行时 hook"激活方案。核心产出 = 一套不依赖第三方 patcher 的脚本与验证清单。

> [!success] 状态
> 方案已在本机多次重启验证（最近文件可打开、0 崩溃、无徽章）。全新机器端到端为 [待验证]。

## 文档地图

| 文档 | 内容 |
|---|---|
| [[2026-08-10-Typora无补丁激活复盘与手册]] | ★ 主文档：复盘 + 可复用流程 + 验证清单 + 故障排查 |
| [[TYPORA-KB-Home]] | 本页（入口） |

```text
TYPORA-KB-Home（本页）
└── 2026-08-10-Typora无补丁激活复盘与手册
    ├── scripts/ （17 个脚本）
    ├── ~/.claude/skills/typora-activation
    └── [[AI大模型开发]]
```

## 关键数据

| 项 | 值 |
|---|---|
| 官方 jsc md5 | 59b3b4b58a177b4fe57d9d9d801038f3 |
| 破解 v2 jsc md5（勿用） | 89eb571dbc6988ccb40156cb423aaca6 |
| 官方 app.asar md5 | ba3e6931129e4e0a073b2899ef482706 |
| renew 端点 | `https://dian.typora.com.cn/api/client/renew` |
| 完整性校验文件 | 4 个（package.json / launch.dist.js / license.html / LicenseIndex...js）→ 经 fs-hook 重定向到 `resources\app.bak\` |
| 注册表 | `HKCU\Software\Typora` SLicense = `code#type#MM/DD/YYYY`（hook 每次启动重写 `QUFBQQ==#0#<today>`） |

## 脚本清单（`typora/scripts/`）

| 脚本 | 用途 |
|---|---|
| `fix_rebuild_asar.py` | ★ 重打包 app.asar（--mode probe/activate、--jsc；保留 header integrity；自动备份源） |
| `fix_hook_block.js` | ★ hook 模板（L1 注册表引导 / L2 publicDecrypt 伪造 / L3 renew 拦截 / L4 弹窗抑制 + 全日志） |
| `extract_asar.py` | 从 asar 提取 jsc / launch.dist.js / package.json |
| `diff_jsc.py` `revert_patch.py` | jsc 字节对比 / 4 字节回退验证 |
| `dump_strpool.py` | jsc 字符串池分析 |
| `fix_cdp_badge2.js` | 状态探测（hasLicense / 徽章） |
| `fix_cdp_recent.js` | 程序化点击"最近文件"菜单 |
| `fix_cdp_menulic.js` `fix_cdp_drive2.js` `fix_cdp_activate.js` | license 菜单 / 离线激活驱动 |
| `fix_cdp_menulist.js` `fix_cdp_curfile.js` `fix_cdp_cmp.js` `fix_cdp_fileapi.js` `fix_cdp_openfile.js` `fix_cdp_traceopen.js` `fix_cdp_badge.js` | 菜单枚举 / 文件状态 / 打开追踪等辅助 |

## 标签索引

- `#software/typora` — 本文档组
- `#incident` — 事故复盘（主文档）
- `#reverse-engineering` — 逆向方法（诊断过程、字符串池、jsc 格式）
- `#moc` — 本页

## 另见

- CLI 技能 `typora-activation`（`~/.claude/skills/typora-activation/SKILL.md`）—— 把主文档的流程做成可直接调用的技能，含 scripts 副本。
- 本 vault 其他复盘：[[v2rayn-balancer-复盘-2026-08-09]]、[[2026-07-21-树莓派网络故障与路由器破解完整复盘]]。

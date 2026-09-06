---
title: SESSION-ARCHIVE-2026-08-28
aliases: [会话归档20260828, Explorer优化归档]
tags: [meta, incident]
created: 2026-08-28
updated: 2026-08-31
status: stable
---

# SESSION-ARCHIVE-2026-08-28

> [!abstract] 会话 `fix-explorer-cpu`（`cc2a3123`，2026-08-28 开，08-30~31 归档续写）：**诊断并修复 Windows Explorer 100% 单核空转 → 文件夹打开卡顿**。完整复盘见 [[explorer-cpu-spin-postmortem-2026-08-28]]。期间用户永久放宽子代理 ox-alpha 确认规则（见 [[fan-out-subagent-pattern]]）。

## 一、任务

"协助优化 Windows explorer 的加载速度，文件夹打开加载过慢"。澄清：C: SSD + D: HDD 均慢；可禁壳扩展为 WPS/IDM/云盘/AutoCAD 钩子；范围=全量优化（UAC 提权）。

## 二、关键过程与坑

| 类别 | 内容 |
|------|------|
| 根因 | ShellIconOverlayIdentifiers 宿主进程死亡后轮询线程空转（坚果云/QQ/IDM）+ 云盘 CMH/命名空间/SyncRootManager 多路加载 |
| 关键反转 | **DISABLED_ 键名重命名阻止不了加载**——Explorer 按键值加载，真禁用=清空 (Default) 值；47/47 overlay 键清空后空转终止 |
| 方法改进 | 先停 explorer 再改注册表（消除 contention，12s 完成 8 键）；PS provider 通配符 `*` 挂死 → 全部改 reg.exe |
| 对抗注入 | QPCore NOT_STOPPABLE（FAILED 1052）→ 改名 QBShellIcon1341ee.dll；IDMan 优雅关闭 + force-stop |
| 工具坑 | MSYS bash 吞 `$_`（改用 .ps1）、`/f`→`F:/`（MSYS_NO_PATHCONV=1）、reg 搜索 `{` 报错（省略花括号） |

## 三、成果

- explorer CPU **100% 单核 → 2%**（0.20s/10s）；残留仅 Stardock（用户保留）
- 47 条 overlay 值清空、约 60 处 CMH/CLSID/SyncRootManager 禁用/清理，全部备份
- 产物：`D:\SoftWare\ExplorerOptimize\`（脚本+备份+双日志+命令文件）
- D: 盘并行调查（fan-out）：defrag 0%、SMART Healthy → 排除磁盘因素

## 四、归档链接

| 文档 | 说明 |
|------|------|
| [[explorer-cpu-spin-postmortem-2026-08-28]] | 完整事故复盘（根因/时间线/方法论/回滚） |
| [[Claude-Ops-KB-Home]] | MOC 事故复盘区新增条目 |
| [[fan-out-subagent-pattern]] | 本会话使用的并行调查模式 |

> [!warning] 遗留建议
> QPCore 服务仍 RUNNING（NOT_STOPPABLE）——建议禁用其 StartType 并重启以彻底阻断 QQ 浏览器注入复发；IDM 重开/WPS 更新/坚果云重开均为已知复发源（详见复盘第八节）。

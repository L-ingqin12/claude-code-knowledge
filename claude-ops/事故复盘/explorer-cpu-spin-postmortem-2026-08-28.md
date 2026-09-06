---
title: Explorer 100% CPU 空转事故复盘
aliases: [explorer cpu spin, 文件夹打开慢, ShellIconOverlayIdentifiers 空转, 壳扩展优化]
tags: [incident, windows/explorer]
created: 2026-08-28
updated: 2026-08-31
status: stable
---

# Explorer 100% CPU 空转事故复盘

See also: [[Claude-Ops-KB-Home]] · [[AGENTS]] · [[fan-out-subagent-pattern]] · [[SESSION-ARCHIVE-2026-08-28]]

> 日期: 2026-08-28 00:11 ~ 02:26 (主会话 `cc2a3123`，08-30~31 归档) | 影响: 文件夹打开卡顿，explorer 恒定 100% 单核空转 | 结果: 2% 稳态，根因修复

---

## 一、事故现象

- 用户反馈「文件夹打开加载过慢」，C:（NVMe SSD）与 D:（5400rpm HDD）均受影响
- 实测 explorer.exe 进程 **10690s CPU 时间 / 约 1.2 天**，即恒定 100% 单核空转
- 重启 explorer 后症状消失，但 **30-45 秒后空转复现**（桌面图标/云盘根初始化触发）

## 二、完整时间线（2026-08-28，日志时间）

| 时间 | 事件 | 阶段 |
|------|------|------|
| 00:11:30 | `fix_admin.ps1` v1 启动，**挂死在 PS 注册表通配符路径**（`HKLM:\...\Classes\*\shellex`，`*` 被当通配符全量枚举） | 初诊 |
| 00:22:59 | `fix_admin2.ps1`（reg.exe 版重写）: duba_64bit CMH ×5、nsemenu HKLM ×16（8 键 × 2 视图）、overlay MEGA×3 + NutstoreExt×5 + IDM×1 → DISABLED_；AutoCAD Approved 3 项放行；D: defrag 分析 **0% 碎片**、SMART 双盘 Healthy | 分层禁用 v1 |
| 00:23:55 | `fix_user2.ps1`: HKCU "Open With qingshellext" ×4、HKCU CLSID ×2、`FolderContentsInfoTip=0`、清 iconcache/thumbcache、重启 explorer | 分层禁用 v1 |
| 00:35:29 | `fix_user3.ps1`: HKCU nsemenu ×8 → DISABLED_ | 分层禁用 v2 |
| 00:56:31 | phase1: HKLM NutstoreExt CMH ×2 + NutstoreShellCopyHook；定位 QB overlay CLSID | 补漏 |
| 01:49:42 | phase2: HKCU Nutstore 命名空间 CLSID ×3 删除（ns_/nsicon 两处） | 补漏 |
| 02:06:17 | phase3b（关键方法变更）: **先停 explorer 再改注册表**，8 个 HKLM CLSID body（AcSignIcon {36A21736} + Nutstore {5D652B62-67}×6 + {CA799F4D}）12 秒完成，消除 registry contention | 深度清理 |
| 02:13:45 | phase4: wpscloudsvr=Stopped/Manual 确认；phase4 脚本挂起 → 杀 PID 1064 | 排障 |
| 02:18:23 | phase4b: 删除 16 个 DISABLED_nsemenu + 5 个 DISABLED_duba + duba CLSID {DDEA5705} + qingnse CLSID ×12（6 键 × 2 视图）+ SyncRootManager Nutstore ×3 | 深度清理 |
| 02:23:32 | test1: `sc stop QPCore` → **FAILED 1052 (NOT_STOPPABLE)**，QQProtect 服务无法停止 | 对抗注入 |
| 02:23:34 | test1: IDMan CloseMainWindow + force-stop，重启 explorer | 对抗注入 |
| 02:25:29 | `gen_phase5.ps1`: 枚举到 **51 个 overlay 键**，47 个待清空（保留 EldosIconOverlay-cbfs6 / EnhancedStorageShell / Optane 系列） | 最终清空 |
| 02:25:53 | phase5: **47/47 条 overlay 键值清空**（`reg add ... /ve /d "" /f`），重启 explorer | 最终清空 |
| 02:26:16 | PHASE5_DONE；后续 monitor/check_now 验证 | 验证 |

## 三、根因分析

> [!bug] 直接根因
> **ShellIconOverlayIdentifiers（覆盖图标处理器）的宿主进程死亡后，explorer 内残留的轮询线程持续空转**：坚果云/QQ/IDM 等 overlay handler 的 DLL 被加载进 explorer 后，其宿主进程已退出或未运行，轮询"云盘状态"的循环永不退出 → 恒定 100% 单核。

叠加因素（多层壳扩展同时加载）：

| 层 | 内容 | 来源 |
|----|------|------|
| 覆盖图标 | MEGA ×3、NutstoreExt ×5、IDM、OneDrive ×7、DingSync ×3、WorkspaceExt、AccExtIco、AutoCAD 签名图标、QBOverlayIcon 等共 47 项 | 云盘/下载器/办公套件 |
| 右键菜单 CMH | duba_64bit ×5（WPS 毒霸）、nsemenu ×16×2 视图（坚果云）、qingshellext ×4（QQ 浏览器） | WPS/坚果云/QQ |
| CopyHook | NutstoreShellCopyHook | 坚果云 |
| 命名空间 CLSID | Nutstore ns ×3 组 + qingnse ×12 + duba CLSID {DDEA5705} + AcSignIcon | 云盘/QQ/WPS |
| SyncRootManager | Nutstore 3 条（HKLM+HKCU 隐藏加载点） | 坚果云 |
| 运行时注入 | IDMan.exe 注入 IDMShellExt64/IDMNetMon64；QQProtect(QPCore) 注入 QBShellIcon1341ee | IDM/QQ 浏览器 |

> [!note] 空转的 30-45 秒延迟特征
> 重启 explorer 后前 15 秒 CPU≈0%（桌面刚起），**t+45s 左右达到峰值 124% 核心**，随后衰减。这是云盘壳扩展的延迟初始化模式——桌面图标/云盘根枚举完成时才加载 handler 并开始轮询，是区分"壳扩展空转"与"开机瞬时负载"的特征信号。

## 四、排查方法论（可复用）

1. **CPU 采样基线**：`check_now.ps1`（10s 采样 CPU delta + suspect DLL 列表）量化空转，0.20s/10s = 2% 为最终验收标准
2. **时间线采样**：`monitor.ps1` 重启 explorer 后 t+15/45/90/150s 各采样 6s，捕捉延迟加载曲线（发现 30-45s 特征的关键手段）
3. **模块列表取证**：explorer 进程的 DLL 清单 → 识别全部第三方 shell 扩展 → 分层禁用（HKLM→HKCU→注入型）
4. **二分排除**：先停宿主进程（IDMan）验证注入 DLL 是否加载；对 NOT_STOPPABLE 的 QPCore 用改名 DLL 阻断注入
5. **D: 盘并行调查**：fan-out 子代理只读分析（defrag 0%、SMART Healthy）→ 排除机械盘碎片因素，锁定纯壳扩展问题（见 [[fan-out-subagent-pattern]]）

## 五、修复过程（分层）

> [!danger] 操作约束
> 所有提权脚本必须：先 `Stop-Process explorer` 再改注册表（消除 registry contention，12s 完成 8 键 vs 挂死）；禁用一律用 **reg.exe**（PS 注册表 provider 的 `*` 通配符会全量枚举挂死）；命令文件预生成（非提权脚本生成 `phase5_commands.txt`，提权脚本只执行）。

| Phase | 内容 | 结果 |
|-------|------|------|
| 1-3 | CMH/CopyHook/CLSID 全部 DISABLED_ 重命名（reg copy+delete） | 部分生效，overlay 未清空仍空转 |
| 3b-4b | 深度清理：命名空间 CLSID、CLSID body、SyncRootManager、DISABLED_ 残留键 | 显著改善 |
| 5 | **overlay 47 键值全部清空**（DISABLED_ 改名无效 → 必须清 `(Default)` 值） | 空转终止 |

## 六、验证结果

| 指标 | 修复前 | 修复后 |
|------|--------|--------|
| CPU 采样 | 100% 单核恒定（10690s/1.2天） | **0.20s/10s = 2%** |
| 残留模块 | 云盘/QQ/IDM/WPS 全家桶 | 仅 Stardock 5 个 DLL（Fences/DesktopDock，用户保留） |
| monitor 曲线 | t+45s 峰值后不回落 | t+150s 后降至 10% 以下，稳态 2% |
| D: 盘 | defrag 0%、SMART Healthy | 无需操作（瓶颈非磁盘） |

> [!success] 最终稳态
> 47/47 overlay 清空 + 分层禁用 + DLL 改名后，explorer 稳态 2% CPU，文件夹打开恢复正常。Stardock（Fences/DesktopDock）按用户意愿保留，其延迟加载峰值正常回落。

## 七、关键结论（可复用知识）

> [!tip] DISABLED_ 前缀重命名 **阻止不了加载**
> Explorer 按键值（CLSID）加载覆盖图标/CMH，**键名无关紧要**。`DISABLED_` 改名只是"看不见"，DLL 照样加载。真禁用 = **清空 `(Default)` 值**（`reg add ... /ve /d "" /f`）或删除键。

- **云盘 DLL 的隐藏加载点**：SyncRootManager（HKLM+HKCU 两条腿）、CLSID\DefaultIcon（64/32 位双视图 WOW6432Node）、命名空间 CLSID——查壳扩展不能只看 ShellIconOverlayIdentifiers
- **注入型 DLL 处理顺序**：先优雅关闭宿主（CloseMainWindow）→ force-stop → 仍加载则改名 DLL（AppData 可写，Program Files 需提权）
- **QPCore (QQProtect) NOT_STOPPABLE**：只能改 StartType + 重启，无法运行中停止；对抗注入的唯一手段 = 改名 QBShellIcon1341ee.dll
- **先停 explorer 再改注册表**：消除 registry contention，批操作从"挂死"变"12 秒完成"
- **PS 注册表 provider 的 `*` 通配符**：`HKLM:\...\Classes\*\shellex` 触发全库枚举挂死 → 用 reg.exe 或硬编码路径
- **MSYS bash 坑**：内联 PowerShell 的 `$_` 被吞（改用 .ps1 文件）；reg.exe 的 `/f` 被 MSYS 转成 `F:/`（`MSYS_NO_PATHCONV=1`）

## 八、复发风险与排查顺序

> [!warning] 已知复发源（按概率排序）
> 1. **QQ 浏览器重建 QBShellIcon DLL**（QPCore 仍 RUNNING）——QQ 浏览器下次启动时可能重新释放；根治需禁 QPCore 服务 StartType 并重启
> 2. **IDM 重新运行** → 重新注入 IDMShellExt64/IDMNetMon64
> 3. **WPS 更新** → 重注册 duba_64bit/nsemenu
> 4. **坚果云重开** → 重注册 SyncRootManager/overlay

**复发排查顺序**：`check_now.ps1` 看 explorer 模块列表 → 按上表对症处理（清 overlay 键值 / 改名 DLL / DISABLED_ 清空）。

## 九、回滚与恢复

- **全部原始值已备份**：`D:\SoftWare\ExplorerOptimize\backup-20260828\`（60+ 个 .reg 导出 + `overlay_values_before.txt` + 双日志）
- 回滚方式：双击对应 .reg 导入，或按 `overlay_values_before.txt` 恢复 47 条 overlay 值
- 已改名 DLL：`QBShellIcon1341ee.dll.bak`（改回 .dll 即恢复注入）
- 脚本与命令文件均在 `D:\SoftWare\ExplorerOptimize\`（可重跑 gen_phase5 + phase5_admin 复现清空流程）

## 十、相关文件

| 位置 | 内容 |
|------|------|
| `D:\SoftWare\ExplorerOptimize\` | 全部修复脚本（fix_*/phase*/test1_*/monitor/check_now/verify/gen_phase5） |
| `D:\SoftWare\ExplorerOptimize\backup-20260828\` | .reg 备份 ×60+、overlay_values_before.txt、log_admin.txt、log_user.txt、DONE 标记 |
| `C:\Users\28064\AppData\Local\Tencent\QQBrowser\User Data\QBShellIcon\` | QBShellIcon1341ee.dll → .bak |
| 本会话 | [[SESSION-ARCHIVE-2026-08-28]]（对话归档） |

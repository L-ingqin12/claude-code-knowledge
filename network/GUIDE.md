---
title: 日常使用指南
aliases: [使用指南, 操作手册]
tags: [network/guide, network]
created: 2026-07-27
updated: 2026-08-09
---

# 日常使用指南

> [!tip] 从这里开始
> 日常无需操作。增强的多节点代理 + 路由器优化已自动运行。

## 代理操作

### 订阅更新后

```powershell
powershell -File "scripts/enhance-config.ps1" -DryRun   # 预览
powershell -File "scripts/enhance-config.ps1" -Apply    # 应用
```

### 速度变慢 / 视频卡顿

```powershell
powershell -File "scripts/enhance-config.ps1" -Status
```

若显示 `Proxy outbounds: 1`，重新 `-Apply`。

### 应急回滚

```powershell
copy "scripts/config.json.bak-20260728" "v2rayN路径/binConfigs/config.json"
```

> [!note] 代理架构
> 主节点 p1d2 处理所有流量，多节点仅故障 fallback。DNS 走 p1d2。Mux 全关（VLESS Vision 兼容）。详见 [[ARCHITECTURE]]。

## 路由器操作

```bash
bash scripts/router_ssh.sh "command"   # SSH
```

已执行优化: AP 隔离关闭、OTA 禁用、遥测禁用、DNS 缓存 2000、UPnP 禁用。详见 [[ROUTER-OPTIMIZATION]] 和 [[ROUTER-FULL-CAPABILITY]]。

## 故障排查

| 现象 | 原因 | 参考 |
|------|------|------|
| 代理不可用 | xray 未运行 | 重启 v2rayN 核心 |
| Google/YouTube 打不开但其他正常 | v2rayN 生成 balancer 无效规则（outboundTag） | [[v2rayn-balancer-复盘-2026-08-09]]（watcher 已自动修复） |
| 视频卡顿 | WiFi 延迟尖峰 | [[FINAL-SUMMARY]] |
| 路由器连不上 | dropbear 挂掉 | [[ROUTER-FULL-CAPABILITY#SSH 连接]] |

## 相关知识

- [[Network-KB-Home]] — 知识库首页
- [[FINAL-SUMMARY]] — 完整优化总结
- [[ARCHITECTURE]] — 架构设计文档
- [[OPTIMIZATION-AUDIT]] — 优化审计清单

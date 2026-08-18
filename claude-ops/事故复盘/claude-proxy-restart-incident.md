---
title: Proxy 重启事故复盘
aliases: []
tags: [ai/ops, incident]
created: 2026-06-17
updated: 2026-08-17
status: stable
---

# Proxy 重启事故复盘

See also: [[Claude-Ops-KB-Home]] · [[claude-port-rebind-solution]] · [[proxy-cancelretry-hook-incident]]

> 日期: 2026-06-17 ~ 2026-07-02 | 影响: 多次会话中断

---

## 一、问题

在缓存优化排查过程中，多次通过 `pkill` / `kill` 重启 proxy 和 permafrost，导致当前会话中断。

## 二、为什么重启无效

proxy 重启后，permafrost 持有的旧连接状态未清理，新 proxy 端口虽已监听但 permafrost 端的连接池可能指向旧 socket。**必须关闭 Termux 完全重建连接才能恢复**。

## 三、正确做法

1. **永远不手动 kill proxy 或 permafrost**
2. 代码修改后保存到磁盘，等下次 session 自然重启时加载
3. 需要立即生效时，由用户确认后执行 `deploy.sh rollback && deploy.sh start`
4. SessionStart hook 已处理自动恢复，无需手动干预

## 四、proxy abort 修复

proxy 代码已修改（`abort` 加入 retryable 列表），磁盘生效，下次重启加载：

```diff
- const retryable = ['socket', 'econnreset', 'etimedout', 'closed', 'eof', 'broken pipe', 'read econnreset']
+ const retryable = ['socket', 'econnreset', 'etimedout', 'closed', 'eof', 'broken pipe', 'read econnreset', 'abort']
```

## 五、规则

**禁止操作**（除非用户明确授权）：
- `kill` / `pkill` 任何 Claude 相关进程
- 手动重启 proxy 或 permafrost
- 修改生产配置文件后不验证就重启服务

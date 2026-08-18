---
title: Permafrost 补丁丢失事故复盘
aliases: []
tags: [ai/ops, incident]
created: 2026-06-17
updated: 2026-08-17
status: stable
---

# Permafrost 补丁丢失事故复盘

See also: [[Claude-Ops-KB-Home]] · [[PERMAFROST_MODIFICATIONS]] · [[claude-cache-incident-postmortem]]

> 日期: 2026-06-17 | 影响: permafrost 重启后补丁丢失，缓存优化失效

---

## 一、事故经过

1. 在 permafrost 源码上通过 Python 字符串替换打补丁
2. 多次替换导致缩进错误 → 语法错误
3. 执行 `cp .orig → permafrost_align.py` 恢复 → **.orig 是干净原版，补丁全部清零**
4. 后续 re-apply 补丁成功，但 .orig 未更新
5. Session 重启 → permafrost 加载了某次恢复操作后的原版代码
6. 生产 permafrost doctor 显示所有补丁字段缺失

## 二、根因

```
直接原因: .orig 备份是原版，恢复操作等于撤销补丁
深层原因: 
  - 字符串替换打补丁不可靠（缩进/转义容易出错）
  - 补丁权威版本未集中管理（磁盘、repo、内存三处不一致）
  - deploy.sh 不验证补丁是否生效
  - .orig 没有在补丁成功后更新
```

## 三、修复措施

| 措施 | 说明 |
|------|------|
| .orig 更新 | 补丁生效后 `cp patched → .orig` |
| deploy.sh 自检 | 启动时自动检测补丁，缺失则从 repo 恢复 |
| repo patches/ | 权威补丁文件，单一真相来源 |
| 记录文档 | PERMAFROST_MODIFICATIONS.md 完整记录每处修改 |

## 四、教训

1. **不要用字符串替换打补丁** — 用完整文件备份替代
2. **每次修改后更新 .orig** — 确保恢复操作指向最新工作版本
3. **部署前验证磁盘状态** — 不仅看运行中的 permafrost，也看磁盘文件
4. **单点真相来源** — repo patches/ 是唯一权威版本

## 五、当前状态（2026-06-17）

- 磁盘补丁 ✅ currentDate + tools 重排
- 生产运行 ✅ 96%+ 命中率
- deploy.sh 自检 ✅ 自动恢复
- .orig 备份 ✅ 已更新为补丁版本
- 逃生通道 ✅ L0a→L3 五级

---
title: Raft与分布式协同
aliases: [raft, 分布式共识, etcd]
tags: [cs/system, cs, cs/db]
created: 2026-08-26
updated: 2026-08-26
status: review
source: Raft 论文(raft.github.io) 与 etcd 文档口径；工程实现差异处标待确认
fetched_at: 2026-08-26
---

# Raft 与分布式协同

> [!abstract] 定位
> 共识算法的"可理解版"全机制：领导者选举的任期时钟、日志复制的提交规则、安全性五约束、成员变更与脑裂边界；etcd/Raft 在本库各存储分册中的落点回连。选型方法论见 [[架构设计与方案选型]]。

See also: [[CS-KB-Home]] · [[Kafka原理与实践]] · [[容器与云原生基础]] · [[MongoDB原理与实践]]

## 一、问题定义：复制状态机为什么需要共识

```
多副本执行同一命令序列 → 状态一致。难点: 谁定顺序(主从)? 主挂了谁接? 分区时听谁的?
共识 = 让 N 个节点在【存在宕机/网络分区/消息乱序】下对"命令序列"达成一致
```

- 容错模型：**崩溃容错**(crash-stop，Raft/Paxos/ZooKeeper ZAB) vs 拜占庭(恶意节点，PBFT/区块链族)——内网基础设施默认前者
- 多数派(quorum=⌊N/2⌋+1) 是一切安全性的根：任意两个多数集必相交 → 承诺不会互相矛盾

## 二、领导者选举：任期是逻辑时钟

```
节点三态: Follower / Candidate / Leader
触发: follower 在随机超时(150-300ms 抖动)内没听到心跳 → term++ 自荐拉票
当选: 收到多数派选票(每人在一个 term 只投一票, 且候选日志不落后于自己)
心跳: leader 周期 AppendEntries(空日志即心跳) 镇压其他候选人
```

**随机化超时为什么必须**：固定超时→瓜分选票死循环；抖动使先醒者大概率收齐票。

**选举限制(日志完整性投票规则)**：投票前比较 `lastLogTerm > mine || (== && lastIndex ≥ mine)` ——保证当选者**拥有全部已提交日志**（安全性核心，比 Paxos 易读的关键设计）。

## 三、日志复制与提交

```
leader 收到写: 追加本地日志(未提交) → 并行发给 followers
   → 多数派落盘应答 → leader commit(应用状态机) → 下次心跳捎带 commitIndex 让 followers 提交
冲突处理: follower 日志与 leader 不一致 → leader 回退 nextIndex 重发覆盖(follower 无条件服从)
```

- **提交规则铁律**：只直接提交**当前任期**的条目；旧任期条目靠后续新条目间接提交（图 8 问题——防止已被复制的旧条目被新 leader 覆盖）
- ReadIndex/Lease Read：线性一致读不必走日志——leader 确认自己仍是 leader(ReadIndex) 后读状态机，省一次落盘；etcd 串行读=可能读到旧值，线性一致读=确认后读（API 参数级选择）

## 四、安全性五约束速查表

| # | 约束 | 防的事故 |
|---|------|---------|
| 1 | 选举安全：单 term 至多一 leader | 双主双写 |
| 2 | 只有日志最新的候选者可当选 | 新 leader 缺已提交数据 |
| 3 | leader 只追加不覆盖自身日志 | 已复制数据被改 |
| 4 | 日志一致性检查( prevLogIndex/Term ) | 复制流错位 |
| 5 | 当前 term 条目才可直接提交 | 图8 的幽灵提交 |

## 五、脑裂与成员变更的边界诚实

- **少数派分区不会双主**（选不出 quorum），但会**不可用**——CAP 里 Raft 选 C 弃 A：`min.insync` 类似语义，拒绝服务优于不一致
- 成员变更单步法(joint consensus 简化版)：每次只增删一节点，新旧配置各自 quorum 约束天然不相交出两套决定——运维上 etcd 的 member add/remove 必须逐台串行
- 快照+日志压缩：日志无限增长治理；安装快照也是落后过多 follower 的追平手段

## 六、本库各分册的 Raft 落点回连

| 系统 | 共识用法 | 差异点 |
|------|---------|--------|
| etcd | 原生 Raft + MVCC(B+ 类 btree) | K8s 的事实配置库；watch 机制 |
| MongoDB 副本集 | Raft 衍生(带 catchup/优先级) | [[MongoDB原理与实践]] §五选举 |
| Redis Cluster | **非 Raft**：gossip+异步复制故障转移 | 可能丢最近写入——与 Raft 族本质差异 |
| TiKV/Kafka(KRaft) | Raft per region/per 元数据日志 | multi-raft 分片化 |

## 七、待确认项

> ① 各生产实现(etcd/tikv)对 PreVote(防扰动 term 暴涨)的默认开关；② witness/learner 角色在三节点变两节点的运维窗口实践；③ FlexiRaft 类变体在云厂商托管的落地情况。

## Related

[[CS-KB-Home]] · [[Kafka原理与实践]] · [[容器与云原生基础]] · [[MongoDB原理与实践]] · [[Redis原理与实践]] · [[架构设计与方案选型]]

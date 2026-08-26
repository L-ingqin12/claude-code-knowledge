---
title: Kafka原理与实践
aliases: [kafka, 消息队列, mq]
tags: [cs/db, cs/system, cs]
created: 2026-08-26
updated: 2026-08-26
status: review
source: Apache Kafka 官方文档与设计文档口径；KRaft/新消费者语义版本敏感处标待确认
fetched_at: 2026-08-26
---

# Kafka 原理与实践

> [!abstract] 定位
> 补齐消息队列方向：为什么"日志"是消息队列的正确数据结构、分区/副本/ISR 的可靠性与顺序保证边界、消费组再平衡的真实代价、精确一次的实现链。选型对照 [[Redis原理与实践]](轻量流) 与 [[数据库原理与调优]](LSM 同源思想)。

See also: [[CS-KB-Home]] · [[高并发系统设计]] · [[MySQL-InnoDB精要]] · [[LLM推理部署与量化]]

## 一、核心抽象：日志即一切

```
topic → partition(有序追加日志) → segment 文件(1GB 滚动) + 稀疏索引(offset→position)
消费 = 消费者自己维护 offset 游标(存在 __consumer_offsets 内部 topic)
```

**为什么用追加日志而不是 B+ 树队列**：
① 顺序写磁盘 ≈ 内存写速度（[[数据库原理与调优]] §一 LSM 同源论证）
② 读随机性由 OS page cache 兜底，热数据天然在内存——Kafka 不自己管缓存，把内存管理还给内核（对比 Redis 自管、MySQL buffer pool 自管的三种哲学）
③ 零拷贝 sendfile 直接页缓存→网卡（[[操作系统八股]] §六零拷贝三方案），这是 Kafka 吞吐神话的物理来源
④ 保留策略按时间/大小删旧 segment 而非逐条删——免碎片

## 二、分区与副本：可靠性参数的真实含义

```
replication.factor=N; 每个 partition 一个 leader 多个 follower
ISR(in-sync replicas): 落后 ≤ replica.lag.time.max.ms 的副本集合
acks=0   不等确认      — 可能丢, 最快(日志类)
acks=1   leader 落盘即答 — leader 挂且未同步则丢
acks=all + min.insync.replicas=2 — ISR 至少2份才答, 不满足抛错(拒绝服务优于丢数据)
unclean.leader.election=false — 禁止非 ISR 副本当 leader(一致性优先于可用性)
```

**顺序保证的精确边界**：仅保证**单分区内**有序。要业务有序必须按 key 路由（同 key 进同分区）——但 key 分区在扩容(reassign)后会变，全局有序与水平扩展不可兼得，这是架构层硬约束。

## 三、消费组：再平衡的代价与治理

- 消费组内每分区只归一个消费者 → 并行度上限=分区数（**分区数规划先于消费者数量**）
- 再平衡触发：成员增减/订阅变更/心跳超时(session.timeout vs max.poll.interval 两套超时——处理逻辑太慢被踢是最常见误配)
- 代价：rebalance 期间整组停摆(stop-the-world)；世代号(generation)防僵尸消费者写旧游标
- **位移提交语义**：先处理后提交(at-least-once, 可能重) vs 先提交后处理(at-most-once, 可能丢)——幂等消费端是生产标配（去重表/Redis setnx 业务键）
- CooperativeStickyAssignor 增量再平衡减少停摆面（**待确认**各客户端版本支持差异）

## 四、精确一次的实现链

```
producer 幂等: PID + 序列号 per partition → broker 去重(只治单会话单分区重试)
事务: transactional.id 跨分区原子写 + 消费-转换-生产回环(read_process_write) 的 exactly-once
isolation.level=read_committed: 消费者只读已提交
```

**边界诚实**：exactly-once 只覆盖 Kafka 流内闭环；对接外部系统(DB 写入)仍需业务侧幂等或两阶段——没有免费午餐。

## 五、实践速查

| 问题 | 处置 |
|------|------|
| 消费积压 | 加消费者至分区数上限→仍不够=加分区(注意 key 有序破坏)+批量拉取调优 |
| 频繁 rebalance | max.poll.interval ≥ 最大批处理耗时×安全系数；心跳线程独立 |
| 消息乱序 | 检查是否多分区写入；retry 场景开启幂等(序列号保序) |
| 延迟毛刺 | GC 停顿/页缓存争抢；`kafka-run-class` 性能工具+`perf`(对照 [[计算机组成原理]] TMA) |
| 数据丢失排查 | 先定 acks 配置与 ISR 历史(`getOffset`/under-replicated 告警) |

## 六、待确认项

> ① KRaft 模式替代 ZooKeeper 后的元数据故障恢复实测；② tiered storage 各发行版成熟度；③ Kafka Streams 与 Flink 在 Exactly-once 语义上的最新口径。

## Related

[[CS-KB-Home]] · [[Redis原理与实践]] · [[数据库原理与调优]] · [[操作系统八股]] · [[高并发系统设计]] · [[Raft与分布式协同]]

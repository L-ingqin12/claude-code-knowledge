---
title: Redis原理与实践
aliases: [redis八股, Redis进阶]
tags: [cs/db, cs]
created: 2026-08-26
updated: 2026-08-26
status: review
source: Redis 官方文档与源码结构共识（7.x 口径）；行为细节随版本核对处标待确认
fetched_at: 2026-08-26
---

# Redis 原理与实践

> [!abstract] 定位
> 内存数据库纵深：底层数据结构与类型编码映射、单线程模型边界、持久化两路线、过期淘汰、复制分片高可用，以及分布式锁争议。缓存三连问在 [[高并发系统设计]] §三不重复。

See also: [[CS-KB-Home]] · [[MySQL-InnoDB精要]] · [[高并发系统设计]] · [[操作系统八股]]

## 一、底层数据结构 → 类型编码

| 结构 | 要点 | 服务对象 |
|------|------|---------|
| SDS 动态字符串 | 头存 len/alloc：O(1) 长度、二进制安全、预分配减 realloc | 所有 string |
| dict 哈希 | 双表**渐进式 rehash**（迁移摊到每次操作，防长尾阻塞） | hash/set 主干 |
| ziplist→listpack(7.0) | 连续内存紧凑编码，小规模省指针 | 小 hash/zset/list |
| quicklist | listpack 节点组成的双向链表折中 | list |
| **跳表** | 多层索引均 O(logn)，span 字段直接算 rank——为什么 zset 不用红黑树：实现简单+范围操作友好+rank 免费 | zset |
| intset | 有序整数数组紧凑编码 | 全 int 小 set |

编码自动升降级（`OBJECT ENCODING` 查看）：small→listpack→skiplist/dict，阈值配置化。

## 二、执行模型

- 命令执行**单线程**（无锁免切换）；6.0 起 IO 读写/协议解析多线程，命令逻辑仍串行——语义不变吞吐升
- 快的根源排序：纯内存 + epoll 事件驱动 + 高效结构 + 无锁；**慢查询多来自大 key/O(n) 命令**（KEYS/HGETALL 大集合/误用 SMEMBERS）
- Pipeline 攒包省 RTT；MULTI/EXEC 事务只保证隔离入队不回滚；原子复杂操作上 Lua 脚本

## 三、持久化双路线

| 方案 | 机制 | 权衡 |
|------|------|------|
| RDB | fork 子进程 + COW 全量快照 | 恢复快/间隔期数据丢失窗口大；fork 瞬间页表拷贝与大实例抖动 |
| AOF | 写命令追加 + `appendfsync always/everysec/no` | everysec 折衷最多丢 1s；重写(bgrewriteaof) fork 压缩体积 |
| 混合(4.0+) | 重写后 RDB 头+AOF 尾 | 兼得恢复速度与低丢失，默认推荐 |

## 四、过期与内存淘汰

- 过期双策略：惰性(访问时判) + 定期随机抽样清理——两者叠加保证近似及时
- 淘汰八策略：noeviction(默认) / volatile-* 只作用于带 TTL 键 / allkeys-* / LRU 近似(抽样) / LFU(Morris 对数计数器+衰减因子)
- 生产必设 maxmemory+策略并监控命中率——命中率骤降=雪崩前兆（呼应 [[高并发系统设计]]）

## 五、高可用三形态

| 形态 | 机制 | 边界 |
|------|------|------|
| 主从 | psync 增量(replid+offset)+backlog 环形缓冲 | 手动切换 |
| Sentinel | 探测主观/客观下线(quorum)+Raft 式选 leader 迁移 | 只管主从，无数据分片 |
| **Cluster** | 16384 slot 按键 CRC16 分片；gossip 协议；MOVED/ASK 重定向 | 多键操作需 hash tag `{}` 同槽；mget 跨槽退化 |

## 六、分布式锁与 Redlock 争议（诚实版）

- 单实例正确姿势：`SET lock val NX PX ttl` + 唯一值 + Lua 比较删除（防误删他人锁）+ 看门狗续期
- **Redlock 多实例多数派**算法存在著名争论（Kleppmann 批评：时钟跳变/GC 停顿下安全性不成立，建议 fencing token 下游校验）——结论：强正确性场景改用 ZooKeeper/etcd 共识租约，Redis 锁定位为"效率型互斥"

## 七、运维速查

- 大 key：`--bigkeys` 扫描/拆分(hash 分桶)/压缩；热 key：本地缓存副本+key 打散
- 内存碎片：activedeflate(4.0+ `activedefrag`)
- 监控四件套：命中率/内存碎片率/阻塞客户端数/主从偏移 lag

## 八、待确认项

> ① 7.2 Function 替代 EVAL 的生产迁移度；② Multi-part AOF(7.0) 在大重写风暴下的表现实测；③ Cluster proxy 类网关对跨槽 mget 的性能损耗口径。

## Related

[[CS-KB-Home]] · [[MySQL-InnoDB精要]] · [[向量数据库与检索]] · [[MongoDB原理与实践]] · [[数据库原理与调优]]

---
title: MongoDB原理与实践
aliases: [mongo八股, MongoDB进阶]
tags: [cs/db, cs]
created: 2026-08-26
updated: 2026-08-26
status: review
source: MongoDB 官方手册（6.x/7.x 口径）；版本相关行为标待确认
fetched_at: 2026-08-26
---

# MongoDB 原理与实践

> [!abstract] 定位
> 文档型数据库纵深：BSON/文档模型取舍、WiredTiger 存储引擎(MVCC+COW B 树)、索引体系(ESR 法则)、聚合管道、副本集与分片。与关系型的边界判断放在最后——选型不是站队。

See also: [[CS-KB-Home]] · [[MySQL-InnoDB精要]] · [[Redis原理与实践]] · [[向量数据库与检索]]

## 一、文档模型

- BSON 二进制 JSON：额外类型（ObjectId/Date/Decimal128/二进制）；单文档硬上限 **16MB**
- ObjectId 12 字节 = 4B 时间戳+5B 随机(进程级)+3B 自增计数 → 天然大致有序可做粗排序
- 嵌入 vs 引用决策：**一起访问+有界增长→嵌入**；无限增长或多方共享→引用+$lookup；反范式冗余要写侧同步策略配套
- Schema 校验(`$jsonSchema`)：灵活≠无纪律，关键字段仍应约束

## 二、WiredTiger 引擎机制

| 机制 | 内容 | 与 InnoDB 差异 |
|------|------|----------------|
| MVCC | 快照隔离，写不就地改页而是**COW 新页**，checkpoint 时压实 | InnoDB 原地更新+undo 链；WT 无 undo 段概念 |
| Journal | 压缩 WAL(snappy)，checkpoint(默认 60s) 落稳定版 | 双"l"语义靠 journal+checkpoint 组合 |
| 压缩 | 块压缩 snappy/zstd + 索引前缀压缩 | 空间友好是 Mongo 实测优势项 |

- 缓存：WT Cache 默认 ~(RAM-1GB)/2，**与 OS page cache 分工**——容量规划双池并看

## 三、索引体系

- 复合索引 **ESR 法则**：Equality → Sort → Range 排列字段序；违反则内存排序
- 特殊族：multikey(数组自动展开)/TTL(过期删除后台任务)/partial(条件子集)/wildcard(异构文档)/text/2dsphere
- `explain("executionStats")` 判读：COLLSCAN 全扫告警 / IXSCAN / totalDocsExamined vs nReturned 比值≈扫描效率；`$indexStats` 找僵尸索引

## 四、聚合管道要点

- `$match/$sort` 尽量前置吃索引；`$group` 内存上限 100MB 需 `allowDiskUse`
- `$lookup` 即左外连接——大集合互 join 性能差，属建模失败信号而非调优对象
- `$facet` 单次多分支输出仪表盘场景利器

## 四·补、ESR 与 explain 走读（代码级）

### ESR 组装实例
查询：`db.orders.find({user_id: u, status: "paid"}).sort({created_at: -1})`

```
E(quality) → S(sort) → R(range) 的顺序推演:
  user_id 等值 → 放最前(E)
  created_at 排序 → 第二(S): 等值字段之后紧跟排序字段,
                    索引天然按 user_id 内的 created_at 有序 → 免内存排序
  status 过滤 → 最后(R): 若放第二, 则 created_at 在索引里不再连续, sort 需内存 TOP-K
最终: { user_id: 1, created_at: -1, status: 1 }
     (status 挪到末尾仍可被 ISCAN 过滤; 若 status 基数极低可考虑部分索引 partialFilter)
```

**反面教材**：`{status:1, user_id:1, created_at:-1}`——status 只有 3 个取值，索引前缀区分度≈无，等于全索引扫。

### explain("executionStats") 判读模板
```
winningPlan: FETCH←IXSCAN{user_id,created_at}   ✓ 走了目标索引
totalKeysExamined: 42   totalDocsExamined: 42   nReturned: 42
                       ↑ 三数相等=完美比率; keys/docs 远大于 returned = 扫描浪费
executionTimeMillis + stage 里出现 SORT(内存排序) / COLLSCAN = 立刻加索引或改查询
```
健康线：`keysExamined ≈ docsExamined ≈ nReturned`（1:1:1）；分页场景配合范围查询避免 skip 深翻页（与 [[数据库原理与调优]] §七 keyset 思想同源）。

## 五、副本集与分片

- oplog(capped) 增量同步；选举协议 Raft 衍生(v1)：多数派 term+priority；**write concern=majority + read concern majority** 才有跨故障切换的读己之写承诺；retryable writes 幂等重试
- 因果一致性会话(causal consistency)：带 cluster time 的会话内单调读
- 分片键三要素：高基数/低频率递增避免单调热点(自增时间戳键=永远写最后一片)；range vs hashed 权衡范围查与均匀散；chunk 迁移由 balancer 后台搬，jumbo chunk 无法迁移需拆分治理

## 六、事务边界演进（诚实版）

- 单文档原子性原生免费——建模把原子单元放进一个文档是最优解
- 多文档事务 4.0(副本集)/4.2(分片) 可用但非强项：锁持有与 oplog 压力使其适合短小补偿型操作，长事务回关系型

## 七、选型对照（何时不用 Mongo）

| 场景 | 更合适 |
|------|--------|
| 强一致多实体转账/库存扣减 | 关系型(MySQL/PG) |
| 复杂多表 ad-hoc join 分析 | 数仓/ClickHouse |
| 日志事件流海量写 | LSM 族/Cassandra 或对象存储+检索层 |
| 半结构化内容管理/用户画像/物联网元数据/快速迭代业务主存储 | ✅ Mongo 舒适区 |

## 八、待确认项

> ① Query Engine(SIBE) 与列存分析能力的 GA 进度；② 分片 meta 一致性在 balancer 中断下的恢复细节；③ zstd 各 level 对 WT 写放大的实测矩阵。

## Related

[[CS-KB-Home]] · [[数据库原理与调优]] · [[Redis原理与实践]] · [[向量数据库与检索]] · [[高并发系统设计]]

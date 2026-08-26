---
title: MySQL-InnoDB精要
aliases: [InnoDB, MySQL调优, mysql-innodb]
tags: [cs/db, cs]
created: 2026-08-26
updated: 2026-08-26
status: review
source: MySQL 8.x Reference Manual / InnoDB 引擎章节口径；参数默认值随版本核对，存疑标待确认
fetched_at: 2026-08-26
---

# MySQL InnoDB 精要

> [!abstract] 定位
> [[数据库原理与调优]] 的 MySQL 分册：Buffer Pool 内部、redo/binlog 两阶段、锁体系全貌、在线 DDL 与复制，以及可直接上手的参数与 EXPLAIN 实战。通用理论不重复，只讲 InnoDB 特有实现。

See also: [[CS-KB-Home]] · [[数据库原理与调优]] · [[Redis原理与实践]] · [[高并发系统设计]]

## 一、Buffer Pool 内部（不是普通 LRU）

- **中点插入变体**：新页插入 old 子链头部（5/8 处），驻留 `innodb_old_blocks_ms`(默认 1000ms) 后再次访问才晋升 young——防全表扫描把热页冲光
- **Change Buffer**：二级索引页不在池中时先缓存变更，后续读入合并——写多读少二级索引受益；唯一索引不可用（必须校验）
- **Doublewrite Buffer**：先顺序写系统表空间副本再写真位——防部分写失效(torn page)；掉电恢复靠它+redo
- 自适应哈希索引(AHI)：热点等值查询路径自动建哈希，争用时可关

## 二、日志体系与两阶段提交

```
事务提交:
  redo prepare(disk flush 按 innodb_flush_log_at_trx_commit)
    → 写 binlog(sync_binlog)
      → redo commit 打标记   ← 崩溃时以此仲裁回滚/提交(XA 内部协议)
```

| 参数 | 值 | 权衡 |
|------|-----|------|
| `innodb_flush_log_at_trx_commit` | 1 | 每次 fsync，完整持久（默认） |
| | 2 | 只写 OS cache，宕库不丢/宕机丢 1s |
| `sync_binlog` | 1 | 双 1 配置=金融口径，吞吐换安全 |

- binlog 三格式：statement(小但不确定函数危险)/row(大而确定，默认)/mixed；GTID 使从库定位免文件名偏移
- 主从延迟治理：并行复制 LOGICAL_CLOCK、semi-sync 半同步折衷

## 三、锁体系全貌

| 锁粒度 | 名称 | 说明 |
|--------|------|------|
| 表级 | IS/IX 意向锁 | 行锁前置声明，使表锁判断 O(1) |
| 行级 | record | 唯一项精确命中 |
| 行级 | gap | 锁开区间防插入 |
| 行级 | next-key | record+gap，RR 当前读防幻读主力 |
| 插入 | insert intention | gap 锁间兼容的等待意图 |

- 死锁：wait-for 图主动检测，回滚 undo 量小者；热点行高并发下检测本身成瓶颈（`innodb_deadlock_detect` 可关改超时兜底）
- 实践：**小事务+一致锁序+索引精准命中**（无索引更新会升级扫描范围放大锁面）

## 四、在线 DDL 与表维护

- ALGORITHM=COPY / INPLACE / **INSTANT**(8.0 加列秒级元数据变更) 三档；INSTANT 不适用时退 INPLACE 仍允许并发 DML（建二级索引等）
- 大表变更流程：pt-osc/gh-ost 影子表+触发器/ binlog 回放，限速切换
- 维护信号：history list length(长事务)、脏页比例、碎片率(`DATA_FREE`)

## 五、EXPLAIN 实战判读（列级）

| 列 | 关注点 |
|----|--------|
| type | const>eq_ref>ref>range>index>ALL；出现 ALL 先问为什么没走索引 |
| key/rows/filtered | 估算扫描行×选择率——rows 巨大即计划劣化 |
| Extra | Using index(覆盖✓) / Using filesort / Using temporary / Using join buffer(buffer=join 无索引) |

优化器干预：`ANALYZE TABLE` 刷统计；hint(USE/FORCE INDEX) 最后手段并注释原因。

## 六、参数基线（起步模板，非万能值）

```
innodb_buffer_pool_size = 物理内存 50–70%
innodb_redo_log_capacity(8.0.30+) ≈ 1h 写放量
max_connections 按连接池×实例数反推，勿拍脑袋万级
tmp_table_size/heap 到顶转磁盘临时表 → 看 Created_tmp_disk_tables
慢参组合验证法: 一次一个变量 + sysbench 回归
```

## 七、待确认项

> ① 8.4 起默认值变动清单（如 redo capacity 自适应）；② Group Replication vs 半同步在跨机房 RTT 下的选型阈值；③ Instant DDL 各操作支持矩阵版本差异。

## Related

[[CS-KB-Home]] · [[数据库原理与调优]] · [[Redis原理与实践]] · [[MongoDB原理与实践]] · [[操作系统八股]]

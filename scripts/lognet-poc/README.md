# LogNet PoC — M0 数据层原型

设计来源: vault 文档 [[lognet-rootcause-multiagent-architecture]]（§三 解析器注册表 / §四 LogNet 图模型与存储选型 / §六 渐进展开 / §七 工具面 / §十 M0 验收）。

## 组成

```
lognet_poc/
  registry.py   解析器注册表（配置驱动，未知文件进"未知桶"统计）
  parsers/      hilog / kmsg 容错正则解析器
  clocksync.py  时钟域统一（kmsg 单调钟经 manifest boot_offset 锚定；hilog 墙钟按 UTC-naive 约定）
  dedup.py      连续重复折叠 {count, first_ts, last_ts}
  builder.py    SQLite(+FTS5) 单文件 lognet.db 构建（WAL、批量 executemany、synchronous=NORMAL）
  graph.py      temporal_next / same_entity(线性链) / causal_hint(R1) / co_occurrence(R2)
  query.py      query_logs：关键词(FTS MATCH)+结构化过滤 → 总数+TopN+引用指针
  subgraph.py   get_subgraph：BFS+时间窗剪枝+token 预算闸+环防护
  __main__.py   CLI: build / query / subgraph
tests/          合成故障链生成器(synth_gen) + 5 个测试模块 + FTS P95 bench
run_tests.ps1   一键验证（unittest + CLI smoke + bench）
```

## 用法

```powershell
# 全量验证
powershell -File run_tests.ps1

# 手动流程
D:\ProgramData\miniconda3\python.exe tests\synth_gen.py D:\tmp\synth-pkg
D:\ProgramData\miniconda3\python.exe -m lognet_poc build D:\tmp\synth-pkg --db D:\tmp\lognet.db
D:\ProgramData\miniconda3\python.exe -m lognet_poc query --db D:\tmp\lognet.db --keyword ext4_io_error --limit 20
D:\ProgramData\miniconda3\python.exe -m lognet_poc subgraph --db D:\tmp\lognet.db --node <id> --depth 2 --window 5
```

## 性能设计与已知边界

已实现：
- 折叠降量（连续重复行合并，合成包 ~300k 行 → ~23k 行）
- WAL + synchronous=NORMAL（派生库可随时重建 = 天然逃生机制）+ 单事务批量落盘
- 图构建 keyset 分页（每页 50k 行）+ 读写游标分离，峰值内存有界
- same_entity 相邻链（O(n) 边）；causal 回溯 bisect 二分
- get_subgraph 增量预算计数 + visited 环防护

明确未声称（M0 真实验收项，见设计文档 §九.3）：
- FTS P95<100ms 的目标是 **5M 行**规模；本仓库 bench 仅验证机制（~2 万折叠行，CI 闸 500ms）
- R2 burst 滑窗在 E/F 极稠密日志下的退化行为待真实数据校准

## 与架构文档的差距（诚实清单）

| 设计 | 本 PoC | 缺口 |
|------|--------|------|
| MCP 工具面 (query_logs/get_subgraph) | Python API + CLI | M3 服务化时包 MCP server |
| crash/tombstone + addr2line 符号化 (M1) | 未实现 | 见设计文档 §五 |
| 多 Agent 渐进展开 (M2) | 仅 get_subgraph 原语 | Locator/Synthesizer 未接 |
| 多 session 并发会话池 (M3) | 不适用（一包一 db 天然隔离） | 调度/看门狗未做 |

## 约定与偏差声明

1. hilog 墙钟按 **UTC-naive** 解释（timegm），生产版需读设备时区元数据 —— 合成包与解析器同约定，测试自洽。
2. kmsg PRI→level 映射：0-2→F, 3→E, 4-5→W, 6→I, 7→D。
3. 原始日志严格只读；db 输出路径由调用方指定（勿指向包目录内）。

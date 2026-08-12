---
name: log-analysis
description: 日志分析专家技能 — 错误识别、性能分析、安全检测、异常发现
version: "1.0"
tags: [log-analysis, debugging, security, performance]
---

# 日志分析技能

## 触发条件

当用户上传日志内容或要求分析日志时激活。

## 分析流程

### Phase 1: 快速扫描 (单次 bash)

```bash
# 统计日志基本信息
wc -l <logfile>
head -5 <logfile>
tail -5 <logfile>
grep -c -E 'ERROR|FATAL|PANIC|CRASH' <logfile>
grep -c -E 'WARN|WARNING' <logfile>
```

### Phase 2: 多维度并行分析

利用 Pi Agent 的 `toolExecution: "parallel"` 同时启动 4 个维度:

**维度 A — 错误模式识别 (ERROR_PATTERN)**
- 搜索关键词: error, fatal, panic, exception, crash, fail, abort, refused, unhandled
- 对每个错误类型: 提取错误消息、出现频率、首次/末次时间戳
- 识别模式:
  - 级联失败: A 错误导致 B 错误导致 C 错误
  - 周期性爆发: 每 N 分钟/小时重复出现的错误
  - 突发尖峰: 短时间内大量同类错误
- 输出: 错误类型列表 + 频率分布 + 根因推断

**维度 B — 性能瓶颈分析 (PERFORMANCE)**
- 搜索关键词: timeout, slow, duration, latency, ms, queue, wait, throttle, delay, blocked
- 识别:
  - 慢操作: 耗时超过阈值 (如 >1000ms) 的操作
  - 超时: 连接超时、读超时、锁等待超时
  - 资源竞争: 连接池耗尽、线程池满、队列堆积
- 计算 (如有结构化时间戳): P50/P95/P99 延迟
- 输出: 慢操作列表 + 延迟分布 + 瓶颈推断

**维度 C — 安全威胁检测 (SECURITY)**
- 搜索关键词: unauthorized, forbidden, injection, bypass, exploit, brute, suspicious, blocked, denied
- 识别:
  - 暴力破解: 同一 IP/用户的高频失败认证 (>10次/分钟)
  - 路径遍历: ../../ 或 /etc/passwd 等模式
  - SQL注入: SELECT/UNION/DROP 在输入参数中
  - 异常 User-Agent: 非浏览器 UA、扫描器 UA
  - 可疑 IP: 已知恶意 IP 段、异常地理位置
- 注意: 即使不确定，也标注 "suspicious" + 低置信度
- 输出: 威胁列表 + 风险等级 + 建议处置

**维度 D — 时序异常检测 (ANOMALY)**
- 分析时间维度:
  - 错误风暴: 某时段错误密度远高于基线 (>3σ)
  - 渐进式恶化: 错误率/延迟随时间递增
  - 周期性模式: 每天/每周某时段错误增多
  - 日志断层: 长时间无日志 (可能服务挂起)
  - 异常安静: 特定服务的日志突然停止
- 输出: 时序异常列表 + 严重程度 + 时间窗口

### Phase 3: 汇总与交叉验证

合并 4 个维度结果:
1. **去重**: 同一行日志被多个维度标记 → 合并为一个 issue
2. **交叉验证**: 同一问题被多个维度从不同角度发现 → 置信度 +0.15/dimension
3. **优先级排序**: critical > error > warn > info
4. **生成建议**: 每个 issue 附带可执行的具体修复建议

### Phase 4: 输出

严格按 JSON 格式输出 (参见系统提示词中的 Output Format)。
如无问题，返回空 issues 数组，绝不编造。

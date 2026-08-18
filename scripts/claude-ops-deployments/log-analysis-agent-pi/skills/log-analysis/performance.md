# 性能分析指南

## 性能指标等级

| 操作类型 | 正常 | 慢 | 严重 |
|---------|:----:|:---:|:----:|
| HTTP 请求 | <100ms | 100-1000ms | >1s |
| 数据库查询 | <10ms | 10-100ms | >100ms |
| 缓存读取 | <1ms | 1-5ms | >5ms |
| RPC 调用 | <50ms | 50-500ms | >500ms |
| 文件 I/O | <5ms | 5-50ms | >50ms |
| 锁等待 | <1ms | 1-10ms | >10ms |
| 队列等待 | <10ms | 10-100ms | >100ms |

## 常见瓶颈

### 1. 数据库瓶颈

**症状**:
- 查询耗时 >100ms
- 大量 `Slow query` 日志
- 连接池耗尽 (`Too many connections`)

**识别**:
```bash
# 慢查询统计
grep "duration_ms" | awk -F 'duration_ms' '{print $2}' | awk '{print $1}' | sort -n | awk '
  { a[i++]=$1 }
  END { print "P50:", a[int(NR*0.5)], "P95:", a[int(NR*0.95)], "P99:", a[int(NR*0.99)] }'

# 连接池状态
grep -E "pool|connection" | grep -E "full|exhausted|timeout|wait"
```

### 2. 网络瓶颈

**症状**:
- 连接超时 (>3s)
- 高重试率
- 数据传输慢

**识别**:
```bash
# 超时统计
grep -E "timeout|timed out" | wc -l

# 重试率
grep "retry\|retrying" | wc -l
```

### 3. CPU 瓶颈

**症状**:
- 请求排队时间增加
- GC 停顿日志
- 线程池满

**识别**:
```bash
# GC 日志
grep -E "GC|gc|garbage" | grep -E "pause|stop|full"

# 线程池状态
grep -E "thread.pool|ThreadPool" | grep -E "full|reject|busy"
```

### 4. 内存瓶颈

**症状**:
- OOM Killer 日志
- Swap 使用
- 频繁 GC

**识别**:
```bash
# OOM 事件
grep -E "Out of memory|OOM|oom-killer"

# 内存使用趋势
grep "memory\|mem_usage" | awk '{print $TIMESTAMP, $MEM_USAGE}'
```

## 延迟分析方法

### 百分位计算

```
P50 (中位数): 50% 的请求快于此值
P95:          95% 的请求快于此值 (常用 SLA 指标)
P99:          99% 的请求快于此值 (长尾检测)
```

### 长尾分析

如果 P99 >> P50:
- 检查是否有间歇性资源竞争
- 检查 GC 暂停
- 检查网络抖动
- 检查锁争用

如果 P50 也高:
- 整体性能问题，可能是代码效率或资源不足

## 关联分析

### 时间关联
```
时间轴: ──────────────────────────────
延迟:    ▁▁▁▁▁██████████▁▁▁▁▁▁▁▁▁
错误:    ▁▁▁▁▁▁▁▁▁▁▁▁████▁▁▁▁▁▁▁
        ←── 延迟尖峰出现在错误尖峰之前 → 因果关系!
```

### 服务关联
```
Svc A 延迟 ←─ Svc B 延迟 ←─ DB 慢查询
(时间上 B 先于 A → B → A 的级联延迟)
```

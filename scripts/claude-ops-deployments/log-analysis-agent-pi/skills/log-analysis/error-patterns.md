# 错误模式识别参考

## 常见错误类型

### 1. 连接错误

| 错误消息 | 根因 | 修复建议 |
|---------|------|---------|
| `Connection refused` | 目标服务未启动或端口错误 | 检查目标服务状态和端口配置 |
| `Connection timeout` | 网络不可达或防火墙阻断 | 检查网络连通性和防火墙规则 |
| `Connection reset by peer` | 对端主动断开连接 | 检查对端服务日志，可能是负载过高 |
| `No route to host` | 路由不可达 | 检查路由表和 DNS 解析 |
| `Too many connections` | 连接池耗尽 | 增大连接池大小或检查连接泄漏 |

### 2. 资源错误

| 错误消息 | 根因 | 修复建议 |
|---------|------|---------|
| `Out of memory` / `OOM` | 内存不足 | 增加内存或排查内存泄漏 |
| `Disk full` / `No space left` | 磁盘满 | 清理日志/临时文件或扩容 |
| `Too many open files` | 文件描述符耗尽 | 增大 ulimit 或修复 fd 泄漏 |
| `Cannot allocate memory` | 系统内存不足 | 检查进程内存使用和 swap |
| `CPU throttling` | CPU 配额耗尽 | 优化代码或增加 CPU 配额 |

### 3. 应用错误

| 错误消息 | 根因 | 修复建议 |
|---------|------|---------|
| `NullPointerException` / `undefined` | 空值引用 | 添加空值检查 |
| `Stack overflow` | 递归过深 | 检查递归终止条件 |
| `Segmentation fault` | 内存访问越界 | 使用 ASAN 调试 |
| `Deadlock detected` | 锁顺序不一致 | 统一锁获取顺序 |
| `Assertion failed` | 不变量被破坏 | 检查触发条件和数据完整性 |

### 4. 级联失败模式

```
A 服务超时
  → B 服务等待 A 的响应 (线程阻塞)
    → B 的线程池耗尽
      → B 无法响应 C 的请求
        → C 也超时
          → 整个调用链崩溃
```

**检测信号**:
- 多个服务几乎同时报错
- 错误从底层向上层传播
- 首个错误是 timeout/resource exhausted

### 5. 周期性爆发

```
时间线: ｜█████░░░░░█████░░░░░█████｜
        每次间隔相同 (如 5 分钟)
```

**常见原因**:
- Cron job 触发批量操作
- 缓存过期后的缓存雪崩
- 健康检查失败导致的反复重启

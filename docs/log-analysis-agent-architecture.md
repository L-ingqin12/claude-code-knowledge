# 日志分析 Agent — Windows 高并发架构参考

> 版本: 1.0 | 日期: 2026-07-09 | 状态: 设计完成
> 用途: 架构决策记录 (ADR) + 后续升级基线

---

## 一、问题域

### 输入

- 客户端通过 HTTP API 上传日志内容
- 后端 Agent (opencode / Pi Agent) 完成语义分析
- 分析结果通过 API 返回

### 约束

- 运行环境: Windows 操作系统 (非 Linux，无 fork / epoll)
- Agent 框架: opencode 或 Pi Agent，其调用接口为同步阻塞
- 分析任务: 耗时不可预测 (秒级到分钟级)
- 并发要求: 需要承载数百并发 API 请求

### 挑战映射

| 挑战 | 根因 | 对策 |
|------|------|------|
| 单进程并发瓶颈 | Python GIL + 单 Tornado 进程 | 手动多进程 + Nginx upstream |
| 事件循环阻塞 | Agent 同步调用 | ThreadPoolExecutor 隔离 |
| 请求超时雪崩 | 无超时控制 | 三层超时 (Nginx→Tornado→Agent) |
| Windows fork 不可用 | OS 限制 | 手动启动多进程绑定不同端口 |
| TIME_WAIT 堆积 | 短连接高并发 | TCP 参数调优 + keepalive |
| 进程崩溃丢失 | 无守护 | NSSM Windows Service |

---

## 二、架构决策

### ADR-1: 为什么选 Tornado 而非 Flask/FastAPI?

**决策**: Tornado

**理由**:
- Tornado 原生异步 (IOLoop)，与 Agent 的线程池隔离模型天然匹配
- Flask/FastAPI 依赖 WSGI/ASGI server (Gunicorn)，Gunicorn 在 Windows 上不支持
- Tornado 自带 HTTPServer，无需额外 server 层

**代价**:
- 生态小于 FastAPI
- 异步编程模型有学习成本

### ADR-2: 为什么手动多进程而非容器编排?

**决策**: 手动启动多个 Python 进程，绑定不同端口

**理由**:
- Windows 没有 fork，Tornado 的 `fork_processes` 在 Windows 上不可用
- Docker Desktop on Windows 性能损耗大，增加复杂度
- 手动多进程 + NSSM 服务化是最小可行方案

**代价**:
- 需要手动管理进程生命周期
- Nginx upstream 需要显式配置每个端口

**备选方案 (未采用)**:
- `multiprocessing` spawn 模式 → 子进程管理复杂，信号处理不可靠
- Docker Compose → Windows 性能损耗，网络层多一层 NAT
- IIS + HttpPlatformHandler → 配置复杂，不如 Nginx 灵活

### ADR-3: 为什么 ThreadPoolExecutor 而非 celery/asyncio subprocess?

**决策**: `concurrent.futures.ThreadPoolExecutor` 在线程池中执行同步 Agent 调用

**理由**:
- Agent 调用是同步的 Python 函数调用 (或 subprocess)，不需要分布式任务队列
- 线程池隔离足够解决"不阻塞事件循环"的需求
- 零外部依赖 (celery 需要 broker)

**代价**:
- 线程池大小固定，任务堆积时无法弹性扩容
- 线程无法真正取消 (asyncio.wait_for 超时后线程仍在后台运行)

**缓解**:
- Agent 内部设置超时作为兜底
- 通过增加 worker 进程数 (而非线程数) 水平扩容

### ADR-4: 为什么 Nginx 而非 IIS/ARR?

**决策**: Nginx for Windows

**理由**:
- 配置简洁，upstream 定义清晰
- keepalive 连接池到后端，减少 TCP 握手
- 文档丰富，社区案例多
- 与未来 Linux 迁移兼容

**代价**:
- Windows 版 Nginx 不支持 epoll，select 连接数上限 64/worker
- 无动态 upstream (开源版)

**缓解**:
- 增大 worker_connections 到 8192
- 多个 worker 进程分散连接
- 如需要动态 upstream，后续可升级 nginx-plus 或用 OpenResty

---

## 三、Fan-Out 并行分析 (进阶模式)

### 场景

单个日志文件可能包含多维度信息，单一 Agent 调用视角有限。可以利用 Fan-Out 模式同时启动多个分析维度:

```
POST /api/analyze
    │
    ▼
Tornado Handler
    │
    ├─ Fan-Out (ThreadPoolExecutor 并行)
    │   ├─ subagent-1: 错误模式识别
    │   ├─ subagent-2: 性能瓶颈分析
    │   ├─ subagent-3: 安全威胁检测
    │   └─ subagent-4: 时序异常检测
    │
    ▼
汇总 → 去重 → 交叉验证 → 返回综合结果
```

### 与现有架构的集成

```python
# FanOutLogAnalyzer — 并行分发到多个子智能体
class FanOutLogAnalyzer:
    def __init__(self, executor: ThreadPoolExecutor):
        self.executor = executor

    async def analyze(self, log_content: str, context: dict) -> dict:
        """并行执行多维度分析"""
        loop = asyncio.get_event_loop()

        # 定义分析维度
        dimensions = [
            ("error_pattern", "识别错误模式与根因"),
            ("performance", "分析性能瓶颈与慢查询"),
            ("security", "检测安全威胁与异常访问"),
            ("anomaly", "发现时序异常与离群点"),
        ]

        # Fan-Out: 并行提交所有维度
        futures = {}
        for dim_name, dim_desc in dimensions:
            future = loop.run_in_executor(
                self.executor,
                self._run_dimension,
                dim_name, dim_desc, log_content, context,
            )
            futures[dim_name] = future

        # Fan-In: 收集所有结果
        results = {}
        for dim_name, future in futures.items():
            try:
                results[dim_name] = await asyncio.wait_for(
                    future, timeout=60
                )
            except asyncio.TimeoutError:
                results[dim_name] = {"error": "timeout", "issues": []}

        # 汇总 (交叉验证: 同一问题被多个维度发现 → 提升优先级)
        return self._merge_results(results)

    def _run_dimension(self, dim_name, dim_desc, log_content, context):
        """在线程池中执行单个维度分析"""
        agent = AgentClient(timeout=60)
        prompt = f"任务: {dim_desc}\n\n日志内容:\n{log_content}"
        return agent.analyze_log(prompt, context)

    def _merge_results(self, results: dict) -> dict:
        """汇总多维度结果, 交叉验证去重"""
        # 实现去重 + 置信度加权
        ...
```

### Fan-Out 防冲突

参照 [[fan-out-subagent-pattern]] 的原则:
- 各维度只读分析 → 可以任意并行
- 汇总阶段交叉验证 → 提高置信度
- 无写操作 → 无冲突风险

---

## 四、与现有知识体系的关联

```
log-analysis-agent-windows-plan
    │
    ├─[[fan-out-subagent-pattern]]
    │   └─ 日志分析多维度 Fan-Out (错误 + 性能 + 安全 + 异常)
    │
    ├─[[opencode-multi-agent-architecture]]
    │   └─ Primary/Subagent 两层模型 → 日志分析主智能体 + 维度子智能体
    │
    ├─[[hermes-parallel-task-communication]]
    │   └─ delegate_task (短分析) vs Kanban (长分析, 需审计)
    │
    ├─[[claude-unattended-cross-platform-guide]]
    │   └─ 跨平台部署: Windows 特殊处理 (fork/epoll 不可用)
    │
    ├─[[claude-interruption-resilience]]
    │   └─ task-state.json 外部化 → 分析任务中断后可续
    │
    ├─[[state-machine-quality-gate-loop]]
    │   └─ VERIFY 门 → 分析结果质量校验
    │
    └─[[deploy-workflow-write-to-repo-first]]
        └─ ⚠️ 所有代码变更先在此仓库编写，确认后再部署
```

---

## 五、配置常量速查

```bash
# ── Nginx ──
MAX_BODY_SIZE=50m            # 最大日志上传
PROXY_READ_TIMEOUT=120s      # 等待 Agent 分析完成
PROXY_CONNECT_TIMEOUT=3s     # 后端连接
KEEPALIVE_POOL=32            # 到后端的长连接数
UPSTREAM_FAIL_TIMEOUT=30s    # 后端标记 down 后的重试间隔
MAX_FAILS=3                  # 连续失败次数

# ── Tornado ──
AGENT_TIMEOUT=60s            # Agent 调用超时
THREAD_POOL_WORKERS=8        # 每进程最大并发分析数
MAX_LOG_SIZE_MB=50           # 日志大小上限

# ── Windows TCP ──
DYNAMIC_PORT_START=10000     # 临时端口范围起始
TcpTimedWaitDelay=30s        # TIME_WAIT 持续时间
MaxUserPort=65534            # 最大用户端口

# ── Service ──
RESTART_DELAY=5000ms         # 崩溃后重启延迟
```

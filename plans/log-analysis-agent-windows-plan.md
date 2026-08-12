# 日志分析 Agent 服务 — Windows 高并发部署方案

> 日期: 2026-07-09 | 版本: 1.0 | 状态: 设计完成，待实施
> 目标: 在 Windows 上基于 opencode/Pi Agent + Tornado + Nginx 搭建生产级日志分析服务

---

## 一、架构总览

```
                        Internet
                           │
                           ▼
                  ┌─────────────────┐
                  │   Nginx (80)     │  ← 反向代理 + 负载均衡 + 连接池
                  │   Windows 版     │
                  └───────┬─────────┘
                          │ upstream: least_conn / ip_hash
                          │ keepalive: 32
                          │
            ┌─────────────┼─────────────┬─────────────┐
            ▼             ▼             ▼             ▼
      ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐
      │Tornado   │ │Tornado   │ │Tornado   │ │Tornado   │
      │:8801     │ │:8802     │ │:8803     │ │:8804     │
      │ Worker 1 │ │ Worker 2 │ │ Worker 3 │ │ Worker N │
      └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘
           │            │            │            │
           │   ThreadPoolExecutor    │            │  ← 异步隔离层
           │   (max_workers=N)       │            │
           │            │            │            │
           └────────────┼────────────┴────────────┘
                        │
                        ▼
              ┌─────────────────┐
              │  opencode /     │  ← Agent 分析引擎
              │  Pi Agent       │     (同步调用，线程池执行)
              └─────────────────┘
```

### 核心设计决策

| 决策点 | 选择 | 理由 |
|--------|------|------|
| Web 框架 | Tornado | 原生异步、轻量、与 Agent 调用模型匹配 |
| 反向代理 | Nginx (Windows) | 成熟稳定、连接复用、负载均衡 |
| 进程模型 | 手动多进程 (不同端口) | Windows 不支持 fork，Tornado 的 fork_processes 不可用 |
| Agent 调用隔离 | ThreadPoolExecutor | 防止同步阻塞调用卡死事件循环 |
| 超时控制 | 三层超时 (Nginx → Tornado → Agent) | 逐层兜底，防止超时雪崩 |
| 进程管理 | Windows Service / NSSM | 崩溃自动拉起，开机自启 |

---

## 二、Phase 1: 环境准备与基础验证

**目标**: 确认所有组件在 Windows 上可用，跑通最简链路

### 1.1 组件清单

| 组件 | 版本要求 | Windows 验证命令 |
|------|---------|-----------------|
| Python | ≥ 3.8 | `python --version` |
| Tornado | ≥ 6.2 | `python -c "import tornado; print(tornado.version)"` |
| Nginx | ≥ 1.24 (Windows build) | `nginx -v` |
| opencode / Pi Agent | 任意版本 | 取决于实际部署 |
| NSSM | ≥ 2.24 | `nssm version` |

### 1.2 最小可行验证

```bash
# 1. 启动单个 Tornado 进程
python app.py --port 8801

# 2. 验证本地可达
curl http://127.0.0.1:8801/api/health

# 3. 配置 Nginx 反向代理到 8801
nginx -c conf/nginx.conf

# 4. 验证通过 Nginx 可达
curl http://127.0.0.1/api/health
```

### 1.3 验证标准

| 检查项 | 方法 | 期望结果 |
|--------|------|---------|
| Tornado 正常启动 | `python app.py --port 8801` | 监听 8801，无报错 |
| Health endpoint | `curl http://127.0.0.1:8801/api/health` | 200 + `{"status":"ok"}` |
| Nginx 反向代理 | 通过 Nginx 访问 health | 200 + 同上 |
| Agent 调用链路 | POST 一条示例日志 | 返回分析结果 |

---

## Phase 2: Nginx 反向代理 + 负载均衡

**依赖**: Phase 1 完成
**目标**: Nginx 前端接收连接，分发给多个 Tornado 后端

### 2.1 Nginx 配置 (Windows)

```nginx
# nginx.conf — Windows 版
worker_processes auto;
worker_rlimit_nofile 65535;

events {
    worker_connections 8192;
    # Windows 不支持 epoll，使用默认 select
    # 但 worker_connections 足够大即可
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    # ── 日志格式 (含分析耗时) ──
    log_format timed '$remote_addr - $remote_user [$time_local] '
                     '"$request" $status $body_bytes_sent '
                     '"$http_referer" "$http_user_agent" '
                     'rt=$request_time uct="$upstream_connect_time" '
                     'uht="$upstream_header_time" urt="$upstream_response_time"';

    access_log logs/access.log timed;
    error_log  logs/error.log warn;

    # ── TCP 优化 ──
    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    keepalive_timeout  65;
    keepalive_requests 1000;

    # ── 代理缓冲 ──
    proxy_buffer_size       4k;
    proxy_buffers           8 4k;
    proxy_busy_buffers_size 8k;
    proxy_temp_file_write_size 8k;

    # ── 上游定义 ──
    upstream tornado_backend {
        # 最少连接算法 — 日志分析任务耗时不一，避免堆积
        least_conn;
        # 备用: ip_hash 用于需要会话亲和性的场景
        # ip_hash;

        server 127.0.0.1:8801 weight=1 max_fails=3 fail_timeout=30s;
        server 127.0.0.1:8802 weight=1 max_fails=3 fail_timeout=30s;
        server 127.0.0.1:8803 weight=1 max_fails=3 fail_timeout=30s;
        server 127.0.0.1:8804 weight=1 max_fails=3 fail_timeout=30s;

        # 到后端的空闲长连接数
        keepalive 32;
    }

    # ── 虚拟主机 ──
    server {
        listen 80;
        server_name localhost;

        # 最大请求体 (日志上传)
        client_max_body_size 50m;
        client_body_timeout 60s;
        client_header_timeout 10s;

        # ── API 路由 ──
        location /api/ {
            proxy_pass http://tornado_backend;
            proxy_http_version 1.1;

            # 关键: 启用后端 keepalive
            proxy_set_header Connection "";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            # 超时 — 日志分析可能耗时较长
            proxy_read_timeout 120s;
            proxy_connect_timeout 3s;
            proxy_send_timeout 30s;

            # 缓冲
            proxy_buffering on;
        }

        # ── 健康检查 (Nginx 商业版支持 active health check) ──
        # 开源版使用 passive: max_fails + fail_timeout
    }
}
```

### 2.2 Nginx 启动与管理 (Windows)

```powershell
# 启动
Start-Process nginx.exe -WorkingDirectory "C:\nginx"

# 重载配置 (无中断)
nginx -s reload

# 停止
nginx -s stop

# 验证配置
nginx -t
```

### 2.3 验证

| 检查项 | 方法 |
|--------|------|
| 配置语法 | `nginx -t` |
| 启动监听 | `netstat -ano | findstr ":80"` |
| 分发到多后端 | 连续请求 `curl http://127.0.0.1/api/health`，检查各 Tornado 日志 |
| fail_timeout 生效 | 停止 8801，请求仍正常 (分发到其他端口) |
| 日志文件正常 | `logs/access.log` 含 rt/urt 字段 |

---

## Phase 3: Tornado 多进程 + 异步包装

**依赖**: Phase 2 Nginx 就绪
**目标**: 启动多个 Tornado 进程，每个内部异步调用 Agent

### 3.1 核心应用代码

```python
#!/usr/bin/env python3
"""
app.py — 日志分析 Agent 服务 (Windows 多进程版)

启动方式 (每个进程绑定不同端口):
    python app.py --port 8801
    python app.py --port 8802
    python app.py --port 8803
    python app.py --port 8804
"""

import argparse
import asyncio
import concurrent.futures
import json
import logging
import os
import signal
import time
import uuid
from typing import Optional

import tornado.ioloop
import tornado.web
import tornado.httpserver
from tornado.concurrent import run_on_executor
from tornado.gen import coroutine

# ── Agent 客户端 (opencode / Pi Agent 接口) ──
# 实际替换为对应的 Agent SDK 调用
class AgentClient:
    """封装对 opencode/Pi Agent 的同步调用"""

    def __init__(self, timeout: int = 60):
        self.timeout = timeout

    def analyze_log(self, log_content: str, context: dict = None) -> dict:
        """
        同步调用 Agent 进行日志分析。

        ⚠️ 此方法是同步阻塞的 — 必须在 ThreadPoolExecutor 中执行
        """
        # ── 实际调用 opencode/Pi Agent ──
        # 示例: 通过 subprocess / SDK / HTTP 调用 Agent
        #
        # import subprocess
        # result = subprocess.run(
        #     ["opencode", "analyze", "--input", log_content],
        #     capture_output=True, text=True, timeout=self.timeout
        # )
        # return json.loads(result.stdout)
        #
        # 或:
        # from pi_agent import Agent
        # agent = Agent()
        # return agent.run(log_content, **context)

        # 占位实现
        time.sleep(2)  # 模拟分析耗时
        return {
            "summary": "分析完成",
            "issues": [],
            "recommendations": [],
            "processing_time_ms": 2000,
        }


# ── Tornado Handler ──
class LogAnalyzeHandler(tornado.web.RequestHandler):
    """日志分析 API — 异步非阻塞"""

    # 类级别线程池 (所有 handler 实例共享)
    _executor = concurrent.futures.ThreadPoolExecutor(
        max_workers=8,
        thread_name_prefix="agent-worker"
    )

    def initialize(self, agent_client: AgentClient, app_config: dict):
        self.agent_client = agent_client
        self.app_config = app_config

    async def post(self):
        """POST /api/analyze — 上传日志进行分析"""
        request_id = str(uuid.uuid4())[:8]

        # ── 解析请求 ──
        try:
            body = json.loads(self.request.body)
        except json.JSONDecodeError:
            self.set_status(400)
            self.write({"error": "invalid JSON"})
            return

        log_content = body.get("log_content", "")
        context = body.get("context", {})

        if not log_content:
            self.set_status(400)
            self.write({"error": "log_content is required"})
            return

        # 大小限制
        max_size = self.app_config.get("max_log_size_mb", 50) * 1024 * 1024
        if len(log_content.encode("utf-8")) > max_size:
            self.set_status(413)
            self.write({"error": f"log exceeds max size {max_size} bytes"})
            return

        # ── 异步执行 Agent 调用 ──
        try:
            result = await self._run_agent_with_timeout(
                log_content, context, request_id
            )
            self.set_status(200)
            self.write({
                "request_id": request_id,
                "status": "ok",
                "result": result,
            })
        except asyncio.TimeoutError:
            logging.warning(f"[{request_id}] Agent 调用超时")
            self.set_status(504)
            self.write({
                "request_id": request_id,
                "status": "timeout",
                "error": "log analysis timed out",
            })
        except Exception as e:
            logging.error(f"[{request_id}] Agent 调用失败: {e}")
            self.set_status(500)
            self.write({
                "request_id": request_id,
                "status": "error",
                "error": str(e),
            })

    async def _run_agent_with_timeout(
        self, log_content: str, context: dict, request_id: str
    ) -> dict:
        """
        在线程池中运行 Agent 分析，并设置超时。

        使用 asyncio.wait_for 在事件循环层面控制超时，
        ThreadPoolExecutor 内部也设置了超时作为兜底。
        """
        loop = asyncio.get_event_loop()
        timeout = self.app_config.get("agent_timeout_seconds", 60)

        logging.info(f"[{request_id}] 开始分析, size={len(log_content)} bytes")

        # 将同步阻塞调用放入线程池
        future = loop.run_in_executor(
            self._executor,
            self.agent_client.analyze_log,
            log_content,
            context,
        )

        try:
            result = await asyncio.wait_for(future, timeout=timeout)
            logging.info(f"[{request_id}] 分析完成")
            return result
        except asyncio.TimeoutError:
            # future 仍在后台运行，但不再等待
            # 实际场景中应考虑取消机制
            raise


class HealthHandler(tornado.web.RequestHandler):
    """健康检查"""

    def initialize(self, start_time: float, port: int):
        self.start_time = start_time
        self.port = port

    async def get(self):
        self.write({
            "status": "ok",
            "port": self.port,
            "uptime_seconds": round(time.time() - self.start_time, 1),
            "active_threads": LogAnalyzeHandler._executor._work_queue.qsize(),
        })


class StatusHandler(tornado.web.RequestHandler):
    """状态页 — 连接指标"""

    def initialize(self, agent_client: AgentClient, app_config: dict):
        self.agent_client = agent_client
        self.app_config = app_config

    async def get(self):
        pool = LogAnalyzeHandler._executor
        self.write({
            "config": {
                "port": self.app_config.get("port"),
                "agent_timeout_s": self.app_config.get("agent_timeout_seconds", 60),
                "max_log_size_mb": self.app_config.get("max_log_size_mb", 50),
            },
            "thread_pool": {
                "max_workers": pool._max_workers,
                "pending_tasks": pool._work_queue.qsize(),
            },
        })


# ── 应用工厂 ──
def make_app(port: int, agent_timeout: int = 60, max_log_size_mb: int = 50):
    """创建 Tornado Application"""
    start_time = time.time()
    agent_client = AgentClient(timeout=agent_timeout)
    app_config = {
        "port": port,
        "agent_timeout_seconds": agent_timeout,
        "max_log_size_mb": max_log_size_mb,
    }

    return tornado.web.Application(
        [
            (r"/api/analyze", LogAnalyzeHandler,
             {"agent_client": agent_client, "app_config": app_config}),
            (r"/api/health", HealthHandler,
             {"start_time": start_time, "port": port}),
            (r"/api/status", StatusHandler,
             {"agent_client": agent_client, "app_config": app_config}),
        ],
        # 全局配置
        max_buffer_size=100 * 1024 * 1024,  # 100MB
        autoreload=False,  # 生产环境关闭
    )


def main():
    parser = argparse.ArgumentParser(description="日志分析 Agent 服务")
    parser.add_argument("--port", type=int, required=True, help="监听端口")
    parser.add_argument("--agent-timeout", type=int, default=60,
                        help="Agent 调用超时 (秒)")
    parser.add_argument("--max-log-size-mb", type=int, default=50,
                        help="最大日志大小 (MB)")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format=f"%(asctime)s [:{args.port}] %(levelname)s %(message)s",
    )

    app = make_app(
        port=args.port,
        agent_timeout=args.agent_timeout,
        max_log_size_mb=args.max_log_size_mb,
    )

    server = tornado.httpserver.HTTPServer(app)
    server.listen(args.port)
    logging.info(f"Tornado worker 启动于 0.0.0.0:{args.port}")

    # 优雅关闭
    def shutdown_handler(sig, frame):
        logging.info(f"收到信号 {sig}，优雅关闭...")
        LogAnalyzeHandler._executor.shutdown(wait=True, cancel_futures=False)
        tornado.ioloop.IOLoop.current().stop()

    signal.signal(signal.SIGTERM, shutdown_handler)
    signal.signal(signal.SIGINT, shutdown_handler)

    tornado.ioloop.IOLoop.current().start()


if __name__ == "__main__":
    main()
```

### 3.2 进程管理脚本 (PowerShell)

```powershell
# start-workers.ps1 — 启动所有 Tornado Worker 进程
param(
    [int]$PortStart = 8801,
    [int]$WorkerCount = 4,
    [int]$AgentTimeout = 60,
    [int]$MaxLogSizeMB = 50
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "启动 $WorkerCount 个 Tornado Worker..." -ForegroundColor Green

$processes = @()

for ($i = 0; $i -lt $WorkerCount; $i++) {
    $port = $PortStart + $i
    Write-Host "  启动 worker-$i 于端口 $port"

    $proc = Start-Process python -ArgumentList @(
        "app.py",
        "--port", $port,
        "--agent-timeout", $AgentTimeout,
        "--max-log-size-mb", $MaxLogSizeMB
    ) -PassThru -WindowStyle Hidden

    $processes += @{
        Id = $proc.Id
        Port = $port
        Process = $proc
    }

    Start-Sleep -Milliseconds 500
}

# 输出进程信息
Write-Host "`nWorker 进程信息:" -ForegroundColor Green
foreach ($p in $processes) {
    Write-Host "  PID $($p.Id) -> 端口 $($p.Port)"
}

# 保存 PID 文件供 stop 脚本使用
$processes | ForEach-Object { $_.Id } | Out-File -FilePath "$scriptDir\worker-pids.txt"
Write-Host "`nPID 已保存到 worker-pids.txt" -ForegroundColor Yellow
```

```powershell
# stop-workers.ps1 — 停止所有 Worker 进程
param(
    [string]$PidFile = "worker-pids.txt"
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pidPath = Join-Path $scriptDir $PidFile

if (-not (Test-Path $pidPath)) {
    Write-Host "PID 文件不存在，尝试通过端口查找进程..." -ForegroundColor Yellow
    Get-NetTCPConnection -LocalPort 8801,8802,8803,8804 -ErrorAction SilentlyContinue |
        ForEach-Object {
            Write-Host "  终止 PID $($_.OwningProcess) (端口 $($_.LocalPort))"
            Stop-Process -Id $_.OwningProcess -Force
        }
    exit 0
}

$pids = Get-Content $pidPath
foreach ($pidLine in $pids) {
    $pid = [int]$pidLine.Trim()
    if ($pid -and $pid -gt 0) {
        try {
            $proc = Get-Process -Id $pid -ErrorAction Stop
            Write-Host "  终止 PID $pid ($($proc.ProcessName))"
            $proc.CloseMainWindow()
            Start-Sleep -Seconds 2
            if (-not $proc.HasExited) {
                $proc.Kill()
            }
        } catch {
            Write-Host "  PID $pid 已不存在" -ForegroundColor Gray
        }
    }
}

Remove-Item $pidPath -ErrorAction SilentlyContinue
Write-Host "所有 worker 已停止" -ForegroundColor Green
```

### 3.3 验证

| 检查项 | 方法 |
|--------|------|
| 多进程启动 | `netstat -ano | findstr "8801 8802 8803 8804"` |
| 健康检查 | `curl http://127.0.0.1:8801/api/health` → 200 |
| 分析请求 | `curl -X POST http://127.0.0.1:8801/api/analyze -H "Content-Type: application/json" -d '{"log_content":"ERROR: connection timeout"}'` |
| 并发请求 | Apache Bench / wrk 压测 |
| 超时返回 | 传入超大日志 + 短超时 → 504 |

---

## Phase 4: Windows TCP/IP 调优

**依赖**: 无 (可独立于其他 Phase 执行)
**目标**: 扩大临时端口范围、缩短 TIME_WAIT、减少连接开销

### 4.1 注册表调优

```powershell
# win-tcp-tuning.ps1 — Windows TCP/IP 参数优化 (需管理员权限)
# 运行: powershell -ExecutionPolicy Bypass -File win-tcp-tuning.ps1

Write-Host "=== Windows TCP/IP 调优 ===" -ForegroundColor Green

# ── 1. 临时端口范围 (默认 ~16K, 增大到 ~64K) ──
#    避免高并发时端口耗尽
Write-Host "[1/4] 扩大临时端口范围..."
netsh int ipv4 set dynamicport tcp start=10000 num=55535
Write-Host "  TCP 动态端口: 10000-65535 (55535 个端口)"

# ── 2. TIME_WAIT 缩短 (默认 120s → 30s) ──
#    Windows Server 默认 120s，高并发下 TIME_WAIT 堆积严重
Write-Host "[2/4] 缩短 TIME_WAIT..."
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" `
    -Name "TcpTimedWaitDelay" -Value 30 -Type DWord -Force
Write-Host "  TcpTimedWaitDelay: 120s → 30s"

# ── 3. 端口复用 (允许 TIME_WAIT 端口被新连接复用) ──
Write-Host "[3/4] 配置 MaxUserPort + 连接参数..."
$tcpParams = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"

# 最大用户端口 (覆盖默认 5000)
Set-ItemProperty -Path $tcpParams -Name "MaxUserPort" -Value 65534 -Type DWord -Force

# 启用 TCP 窗口缩放 (默认已启用，确认)
Set-ItemProperty -Path $tcpParams -Name "Tcp1323Opts" -Value 3 -Type DWord -Force

# 快速释放连接
# (需同时设置 TcpTimedWaitDelay)
Write-Host "  MaxUserPort: 65534"

# ── 4. TCP 连接卸载 (Chimney Offload / RSS) ──
Write-Host "[4/4] 网络适配器高级参数..."
# 启用 RSS (Receive Side Scaling) — 多核分发网络中断
# 启用 Chimney Offload — 硬件卸载 TCP 连接处理
# 注意: 某些网卡驱动不稳定时可关闭
netsh int tcp set global rss=enabled
netsh int tcp set global chimney=enabled
netsh int tcp set global netdma=enabled

Write-Host "  已启用 RSS / Chimney / NetDMA"

Write-Host "`n应用这些更改需要重启系统。" -ForegroundColor Yellow
Write-Host "重启后验证: netsh int tcp show global" -ForegroundColor Yellow
```

### 4.2 调优参数汇总

| 参数 | 默认值 | 推荐值 | 位置 | 作用 |
|------|--------|--------|------|------|
| 动态端口范围 | 49152-65535 | 10000-65535 | `netsh int ipv4` | 增大可用出站端口 |
| TcpTimedWaitDelay | 120s | 30s | Registry | 缩短 TIME_WAIT 持续时间 |
| MaxUserPort | 5000 | 65534 | Registry | 最大用户端口 |
| Tcp1323Opts | — | 3 | Registry | 窗口缩放 + 时间戳 |
| RSS | varies | enabled | `netsh int tcp` | 多核接收 |
| Chimney | varies | enabled | `netsh int tcp` | TCP 卸载 |
| KeepAliveTime | 2h | 300000ms | Registry | TCP keepalive 间隔 |

### 4.3 验证

```powershell
# 查看当前 TCP 设置
netsh int tcp show global

# 查看端口范围
netsh int ipv4 show dynamicport tcp

# 查看 TIME_WAIT 连接数
netstat -ano | findstr "TIME_WAIT" | Measure-Object | Select-Object -ExpandProperty Count

# 验证注册表
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" `
    | Select-Object TcpTimedWaitDelay, MaxUserPort, Tcp1323Opts
```

---

## Phase 5: 服务化与自愈 (Windows Service)

**依赖**: Phase 2 + Phase 3 完成
**目标**: 确保 Nginx 和 Tornado workers 随系统启动，崩溃自动拉起

### 5.1 使用 NSSM (Non-Sucking Service Manager)

```powershell
# install-services.ps1 — 安装 Windows 服务

$NSSM = "C:\nssm\nssm.exe"
$APP_DIR = "C:\log-agent"

# ── Nginx 服务 ──
& $NSSM install "LogAgent-Nginx" "C:\nginx\nginx.exe" -p "C:\nginx"
& $NSSM set "LogAgent-Nginx" AppDirectory "C:\nginx"
& $NSSM set "LogAgent-Nginx" DisplayName "Log Analysis Agent - Nginx"
& $NSSM set "LogAgent-Nginx" Description "日志分析服务的 Nginx 反向代理"
& $NSSM set "LogAgent-Nginx" Start SERVICE_AUTO_START
# 崩溃重启: 5秒内最多重启3次，超过则60秒后重试
& $NSSM set "LogAgent-Nginx" AppExit Default Restart
& $NSSM set "LogAgent-Nginx" AppRestartDelay 5000
& $NSSM set "LogAgent-Nginx" AppThrottle 30000

# ── Tornado Worker 1:8801 ──
& $NSSM install "LogAgent-Tornado-8801" python "app.py --port 8801"
& $NSSM set "LogAgent-Tornado-8801" AppDirectory "$APP_DIR"
& $NSSM set "LogAgent-Tornado-8801" DisplayName "Log Analysis Agent - Tornado :8801"
& $NSSM set "LogAgent-Tornado-8801" AppExit Default Restart
& $NSSM set "LogAgent-Tornado-8801" AppRestartDelay 3000

# ── Tornado Worker 2:8802 ──
& $NSSM install "LogAgent-Tornado-8802" python "app.py --port 8802"
& $NSSM set "LogAgent-Tornado-8802" AppDirectory "$APP_DIR"
& $NSSM set "LogAgent-Tornado-8802" AppExit Default Restart
& $NSSM set "LogAgent-Tornado-8802" AppRestartDelay 3000

# ── Tornado Worker 3:8803 ──
& $NSSM install "LogAgent-Tornado-8803" python "app.py --port 8803"
& $NSSM set "LogAgent-Tornado-8803" AppDirectory "$APP_DIR"
& $NSSM set "LogAgent-Tornado-8803" AppExit Default Restart
& $NSSM set "LogAgent-Tornado-8803" AppRestartDelay 3000

# ── Tornado Worker 4:8804 ──
& $NSSM install "LogAgent-Tornado-8804" python "app.py --port 8804"
& $NSSM set "LogAgent-Tornado-8804" AppDirectory "$APP_DIR"
& $NSSM set "LogAgent-Tornado-8804" AppExit Default Restart
& $NSSM set "LogAgent-Tornado-8804" AppRestartDelay 3000

Write-Host "所有服务已安装" -ForegroundColor Green
Write-Host "启动: nssm start LogAgent-Nginx; nssm start LogAgent-Tornado-*" -ForegroundColor Yellow
```

### 5.2 服务依赖与启动顺序

```powershell
# 设置依赖: Tornado 依赖 Nginx? 不 — 反过来 Nginx 依赖 Tornado
# 但最简单的方式是设置启动延迟:
& $NSSM set "LogAgent-Nginx" Start SERVICE_DELAYED_AUTO_START

# 或者用一个主控制器:
# master-start.ps1 依次启动 -> Tornados -> Nginx
```

### 5.3 健康监控脚本

```powershell
# health-monitor.ps1 — 定期健康检查，异常时重启服务
# 配合 Windows 任务计划程序 (Task Scheduler) 每分钟执行

$Ports = @(8801, 8802, 8803, 8804)
$Timeout = 2000  # ms

foreach ($port in $Ports) {
    try {
        $req = [System.Net.WebRequest]::Create("http://127.0.0.1:$port/api/health")
        $req.Timeout = $Timeout
        $resp = $req.GetResponse()
        $resp.Close()
    } catch {
        $svcName = "LogAgent-Tornado-$port"
        Write-Warning "$(Get-Date) 端口 $port 无响应，重启服务 $svcName..."
        Restart-Service $svcName -Force
    }
}

# 检查 Nginx 健康
try {
    $req = [System.Net.WebRequest]::Create("http://127.0.0.1/api/health")
    $req.Timeout = $Timeout
    $resp = $req.GetResponse()
    $resp.Close()
} catch {
    Write-Warning "$(Get-Date) Nginx 无响应，重启服务..."
    Restart-Service "LogAgent-Nginx" -Force
}
```

---

## Phase 6: 压测与容量规划

**依赖**: Phase 1-5 全部完成
**目标**: 验证并发能力，找出瓶颈，确定容量上限

### 6.1 压测工具

```powershell
# 使用 Apache Bench (ab) 或 wrk
#
# 安装 ab: 随 Apache24 或 Nginx 发行版附带
# 安装 wrk: choco install wrk  (或手动编译)

# 基线压测 — 单 worker
ab -n 10000 -c 100 -p sample_log.json -T "application/json" `
   http://127.0.0.1:8801/api/analyze

# 通过 Nginx 压测 — 4 workers
ab -n 50000 -c 500 -p sample_log.json -T "application/json" `
   http://127.0.0.1/api/analyze

# 长连接压测
wrk -t 12 -c 1000 -d 60s `
    -s post.lua `
    http://127.0.0.1/api/analyze
```

### 6.2 监控指标

| 指标 | 工具 | 目标 |
|------|------|------|
| QPS | ab/wrk 输出 | ≥ 500 (4 workers) |
| P99 延迟 | wrk latency | < 10s (含分析时间) |
| TIME_WAIT 堆积 | `netstat -ano \| findstr "TIME_WAIT"` | < 1000 |
| CPU 使用率 | Task Manager / PerfMon | < 80% 单核 |
| 内存使用 | Task Manager | < 2GB per worker |
| 错误率 | ab output | < 1% Non-2xx |

### 6.3 容量规划

| 场景 | Workers | Nginx workers | 预期 QPS |
|------|---------|---------------|----------|
| 开发测试 | 2 | 2 | ~100 |
| 轻量生产 | 4 | 4 | ~500 |
| 中等负载 | 8 | 4 | ~1000 |
| 高负载 | 16 | 8 | ~2000 |

---

## 三、三层超时体系

```
客户端 ──── Nginx ──── Tornado ──── Agent
  │            │           │           │
  │  120s      │  120s     │   60s     │   60s
  │  (HTTP     │  (proxy_  │  (wait_   │  (Agent
  │   client)  │   read)   │   for)    │   timeout)
  │            │           │           │
  └────────────┴───────────┴───────────┘
           逐层兜底，外层 > 内层
```

| 层级 | 参数 | 推荐值 | 配置位置 |
|------|------|--------|---------|
| Nginx → 客户端 | client_body_timeout | 60s | nginx.conf |
| Nginx → 客户端 | proxy_read_timeout | 120s | nginx.conf |
| Nginx → 后端 | proxy_connect_timeout | 3s | nginx.conf |
| Tornado → Agent | asyncio.wait_for | 60s | app.py |
| Agent 内部 | AgentClient.timeout | 60s | app.py |

---

## 四、故障模式与恢复

| 故障 | 症状 | 检测 | 自动恢复 |
|------|------|------|---------|
| 单个 Tornado 进程崩溃 | Nginx 分发到该端口失败 | max_fails=3 | Nginx 标记 down，30s 后重试；NSSM 自动重启进程 |
| Nginx 崩溃 | 所有请求 502/无响应 | health-monitor.ps1 | NSSM 自动重启 |
| Agent 同步调用卡死 | 线程池耗尽 | pending_tasks 递增 | wait_for 超时抛出 TimeoutError |
| 线程池耗尽 | 请求排队 / 503 | ThreadPoolExecutor 队列满 | 增大 max_workers 或增加 worker 进程 |
| 端口耗尽 | 新连接失败 | TIME_WAIT > 1000 | TcpTimedWaitDelay 缩短 + 端口范围扩大 |
| 内存泄漏 | Tornado 进程内存持续增长 | PerfMon / Task Manager | NSSM 定期重启 (AppRestartDelay + 条件) |
| 单点磁盘满 | 写日志失败 | 磁盘监控 | 日志轮转 + 告警 |

---

## 五、文件清单

```
deployments/log-analysis-agent/
├── configs/
│   ├── nginx.conf              # Nginx 完整配置
│   └── nginx.conf.minimal      # Nginx 最小配置 (仅反向代理)
├── scripts/
│   ├── app.py                  # Tornado 应用 (核心)
│   ├── start-workers.ps1       # 启动多进程 PowerShell
│   ├── stop-workers.ps1        # 停止所有 Worker
│   ├── install-services.ps1    # NSSM 服务安装
│   ├── win-tcp-tuning.ps1      # Windows TCP/IP 调优
│   └── health-monitor.ps1      # 健康监控 (配合 Task Scheduler)
├── deploy.sh / deploy.ps1      # 一键部署脚本
└── README.md                   # 部署说明
```

---

## 六、安全注意事项

| 关注点 | 措施 |
|--------|------|
| 日志内容泄露 | Nginx 日志脱敏，access_log 不记录 request body |
| 带宽耗尽 | Nginx client_max_body_size 限制上传大小 |
| SSRF | Agent 不应访问内网资源，必要时网络隔离 |
| 进程以最小权限运行 | 使用专用 Windows 服务账户，非 SYSTEM |
| 日志注入 | 日志分析结果输出前做内容转义 |

---

## 七、相关文档

- [[claude-code-preflight-checklist]] — 行动前强制检查清单
- [[claude-unattended-cross-platform-guide]] — 跨平台无人值守指南
- [[claude-interruption-resilience]] — 中断恢复方案
- [[opencode-multi-agent-architecture]] — OpenCode 多智能体架构
- [[hermes-parallel-task-communication]] — 并行任务通信机制
- [[fan-out-subagent-pattern]] — Fan-Out 子智能体分发
- [[deploy-workflow-write-to-repo-first]] — ⚠️ 代码变更先归档仓库后部署

---

## 八、实施优先级

| 优先级 | Phase | 工作量 | 可独立部署 |
|--------|-------|--------|-----------|
| P0 | Phase 1: 环境验证 | 2h | ✅ |
| P0 | Phase 2: Nginx 配置 | 3h | ✅ (先单后端) |
| P1 | Phase 3: Tornado 多进程 + 异步 | 4h | ✅ |
| P1 | Phase 4: TCP/IP 调优 | 1h | ✅ |
| P2 | Phase 5: 服务化 | 2h | 需 Phase 2+3 |
| P2 | Phase 6: 压测 | 3h | 需 Phase 1-5 |

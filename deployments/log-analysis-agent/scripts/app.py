#!/usr/bin/env python3
"""
app.py — 日志分析 Agent 服务 (Windows 多进程版)

基于 Tornado 的异步 HTTP 服务，封装对 opencode/Pi Agent 的同步调用。
每个进程绑定独立端口，通过 Nginx upstream 实现负载均衡。

启动方式 (每进程一个端口):
    python app.py --port 8801
    python app.py --port 8802
    python app.py --port 8803
    python app.py --port 8804

架构关键:
    - Tornado 事件循环永不阻塞 (Agent 调用全部在线程池中执行)
    - 三层超时: asyncio.wait_for → ThreadPoolExecutor → Agent 自身超时
    - 线程池大小可配置，与 worker 进程数配合决定总并发容量

参考:
    - plans/log-analysis-agent-windows-plan.md (完整方案)
    - [[fan-out-subagent-pattern]] (Fan-Out 并行分发)
    - [[opencode-multi-agent-architecture]] (OpenCode Agent 架构)
"""

import argparse
import asyncio
import concurrent.futures
import json
import logging
import os
import signal
import sys
import time
import traceback
import uuid
from datetime import datetime
from typing import Optional, Dict, Any

import tornado.ioloop
import tornado.web
import tornado.httpserver

# ============================================================
# Agent 客户端 — 封装 opencode / Pi Agent 的同步调用
# ============================================================

class AgentClient:
    """
    封装对 opencode/Pi Agent 的同步阻塞调用。

    ⚠️ 关键设计:
        analyze_log() 是同步方法，必须在 ThreadPoolExecutor 中执行，
        绝不能直接放在 Tornado 事件循环中调用。

    实际部署时替换 _call_agent() 方法为真实 Agent SDK 调用。
    """

    def __init__(self, timeout: int = 60):
        self.timeout = timeout

    def analyze_log(self, log_content: str, context: dict = None) -> dict:
        """
        同步分析日志 (在线程池中执行)。

        Args:
            log_content: 日志原文
            context: 可选上下文 (来源、格式提示等)

        Returns:
            {
                "summary": str,
                "issues": [{"severity": "error|warn|info", "message": str, "line": int}],
                "recommendations": [str],
                "processing_time_ms": int,
                "model_used": str,
            }

        Raises:
            TimeoutError: Agent 调用超时
            RuntimeError: Agent 调用失败
        """
        return self._call_agent(log_content, context or {})

    def _call_agent(self, log_content: str, context: dict) -> dict:
        """
        实际调用 opencode / Pi Agent 的接口。

        ──── 实现方式 (按实际环境选择) ────

        方式 A: subprocess 调用 opencode CLI
            import subprocess
            result = subprocess.run(
                ["opencode", "analyze", "--format", "json"],
                input=log_content,
                capture_output=True, text=True,
                timeout=self.timeout
            )
            return json.loads(result.stdout)

        方式 B: Pi Agent Python SDK
            from pi_agent import Agent
            agent = Agent(model="claude-sonnet-5")
            response = agent.run(
                f"分析以下日志:\n{log_content}",
                system="你是日志分析专家...",
                timeout=self.timeout,
            )
            return self._parse_agent_response(response)

        方式 C: HTTP 调用 Agent 网关
            import requests
            resp = requests.post(
                "http://127.0.0.1:9000/agent/run",
                json={"task": "log_analysis", "input": log_content},
                timeout=self.timeout,
            )
            return resp.json()

        方式 D: Fan-Out 并行子智能体 (多维度分析) ← 最推荐
            参见 [[fan-out-subagent-pattern]]
            利用 opencode-agent-intercom spawn() 并行分发:
              - subagent-1: 错误模式识别
              - subagent-2: 性能瓶颈分析
              - subagent-3: 安全威胁检测
              - subagent-4: 时序异常检测
            主智能体汇总各维度结果。

        ──── 占位实现 ────
        """
        # 占位: 模拟分析耗时
        time.sleep(2)

        return {
            "summary": f"分析了 {len(log_content)} 字符的日志，发现 2 个潜在问题",
            "issues": [
                {
                    "severity": "error",
                    "message": "连接超时: database connection timeout after 30s",
                    "line": 142,
                },
                {
                    "severity": "warn",
                    "message": "内存使用率超过阈值: 85.2%",
                    "line": 287,
                },
            ],
            "recommendations": [
                "检查数据库连接池配置，考虑增大 max_connections",
                "考虑增加应用内存限制或横向扩展",
            ],
            "processing_time_ms": 2000,
            "model_used": "claude-sonnet-5",
        }

    @staticmethod
    def _parse_agent_response(response: str) -> dict:
        """解析 Agent 原始响应为结构化结果"""
        # 实际实现根据 Agent 输出格式解析
        try:
            return json.loads(response)
        except json.JSONDecodeError:
            return {
                "summary": response[:500],
                "issues": [],
                "recommendations": [],
                "processing_time_ms": 0,
                "model_used": "unknown",
            }


# ============================================================
# Tornado Request Handlers
# ============================================================

class BaseHandler(tornado.web.RequestHandler):
    """基础 Handler — 提供通用工具方法"""

    def write_error(self, status_code: int, **kwargs) -> None:
        exc_info = kwargs.get("exc_info")
        self.set_header("Content-Type", "application/json")
        self.finish(json.dumps({
            "error": self._reason,
            "status_code": status_code,
            "detail": str(exc_info[1]) if exc_info and len(exc_info) > 1 else None,
        }))

    def get_request_id(self) -> str:
        return self.request.headers.get("X-Request-ID", str(uuid.uuid4())[:8])


class LogAnalyzeHandler(BaseHandler):
    """
    POST /api/analyze — 日志分析接口

    请求体:
        {
            "log_content": "<日志原文>",        // 必填
            "context": {                        // 可选
                "source": "nginx",
                "format": "json",
                "hint": "关注超时相关错误"
            }
        }

    响应:
        {
            "request_id": "abc123",
            "status": "ok",
            "result": {
                "summary": "...",
                "issues": [...],
                "recommendations": [...],
                "processing_time_ms": 2000,
                "model_used": "claude-sonnet-5"
            }
        }
    """

    # ── 类级别线程池 (所有 handler 实例共享) ──
    # max_workers 决定单个 Tornado 进程的最大并发分析数
    # 总并发 = max_workers × worker 进程数
    _executor = concurrent.futures.ThreadPoolExecutor(
        max_workers=8,
        thread_name_prefix="agent-analyze"
    )

    def initialize(self, agent_client: AgentClient, app_config: dict):
        self.agent_client = agent_client
        self.app_config = app_config

    async def post(self):
        request_id = self.get_request_id()
        start_time = time.monotonic()

        # ── Step 1: 解析请求 ──
        try:
            body = json.loads(self.request.body.decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            self.set_status(400)
            self.write({"error": "invalid JSON body"})
            return

        log_content = body.get("log_content", "")
        context = body.get("context", {})

        # 校验
        if not log_content or not isinstance(log_content, str):
            self.set_status(400)
            self.write({"error": "log_content is required and must be a string"})
            return

        # 大小限制
        max_size = self.app_config.get("max_log_size_bytes", 50 * 1024 * 1024)
        content_bytes = len(log_content.encode("utf-8"))
        if content_bytes > max_size:
            self.set_status(413)
            self.write({
                "error": f"log content too large",
                "size_bytes": content_bytes,
                "max_size_bytes": max_size,
            })
            return

        # ── Step 2: 异步执行 Agent 分析 ──
        try:
            logging.info(
                f"[{request_id}] 开始分析, size={content_bytes}B, "
                f"source={context.get('source', 'unknown')}"
            )

            result = await self._run_agent_with_timeout(
                log_content, context, request_id
            )

            elapsed_ms = int((time.monotonic() - start_time) * 1000)
            logging.info(f"[{request_id}] 分析完成, wall_time={elapsed_ms}ms")

            self.set_status(200)
            self.write({
                "request_id": request_id,
                "status": "ok",
                "result": result,
                "wall_time_ms": elapsed_ms,
            })

        except asyncio.TimeoutError:
            elapsed_ms = int((time.monotonic() - start_time) * 1000)
            logging.warning(
                f"[{request_id}] Agent 调用超时, "
                f"timeout={self.app_config.get('agent_timeout_seconds')}s, "
                f"wall_time={elapsed_ms}ms"
            )
            self.set_status(504)
            self.write({
                "request_id": request_id,
                "status": "timeout",
                "error": "log analysis timed out — the log may be too large or complex",
                "wall_time_ms": elapsed_ms,
            })

        except Exception as e:
            elapsed_ms = int((time.monotonic() - start_time) * 1000)
            logging.error(
                f"[{request_id}] Agent 调用失败: {e}\n{traceback.format_exc()}"
            )
            self.set_status(500)
            self.write({
                "request_id": request_id,
                "status": "error",
                "error": str(e),
                "wall_time_ms": elapsed_ms,
            })

    async def _run_agent_with_timeout(
        self, log_content: str, context: dict, request_id: str
    ) -> dict:
        """
        在线程池中执行 Agent 分析，并设置超时。

        两层保护:
            1. asyncio.wait_for 在事件循环层面控制超时
            2. AgentClient 内部 timeout 在线程层面控制超时
        """
        loop = asyncio.get_event_loop()
        timeout = self.app_config.get("agent_timeout_seconds", 60)

        # 将同步阻塞调用放入线程池
        future = loop.run_in_executor(
            self._executor,
            self.agent_client.analyze_log,
            log_content,
            context,
        )

        try:
            return await asyncio.wait_for(future, timeout=timeout)
        except asyncio.TimeoutError:
            # future 仍在后台运行但不再等待
            # 注意: ThreadPoolExecutor 的 future 无法真正取消
            # 对于长时间运行的 Agent 调用，需依赖 AgentClient 内部超时
            raise


class HealthHandler(BaseHandler):
    """GET /api/health — 健康检查"""

    def initialize(self, start_time: float, port: int, agent_client: AgentClient):
        self.start_time = start_time
        self.port = port
        self.agent_client = agent_client

    async def get(self):
        pool = LogAnalyzeHandler._executor
        self.write({
            "status": "ok",
            "port": self.port,
            "uptime_seconds": round(time.monotonic() - self.start_time, 1),
            "server_time": datetime.now().isoformat(),
            "python_version": sys.version,
            "thread_pool": {
                "pending_tasks": pool._work_queue.qsize(),
                "max_workers": pool._max_workers,
            },
        })


class StatusHandler(BaseHandler):
    """GET /api/status — 运行时状态与配置"""

    def initialize(self, agent_client: AgentClient, app_config: dict):
        self.agent_client = agent_client
        self.app_config = app_config

    async def get(self):
        pool = LogAnalyzeHandler._executor
        self.write({
            "config": self.app_config,
            "thread_pool": {
                "max_workers": pool._max_workers,
                "pending_tasks": pool._work_queue.qsize(),
                "active_threads": getattr(pool, "_threads", None) is not None,
            },
            "agent_timeout_s": self.agent_client.timeout,
        })


# ============================================================
# 应用工厂
# ============================================================

def make_app(port: int, agent_timeout: int = 60, max_log_size_mb: int = 50):
    """
    创建 Tornado Application 实例。

    Args:
        port: 监听端口 (用于日志标识)
        agent_timeout: Agent 调用超时 (秒)
        max_log_size_mb: 最大日志大小 (MB)
    """
    agent_client = AgentClient(timeout=agent_timeout)
    start_time = time.monotonic()

    app_config = {
        "port": port,
        "agent_timeout_seconds": agent_timeout,
        "max_log_size_bytes": max_log_size_mb * 1024 * 1024,
        "max_log_size_mb": max_log_size_mb,
        "version": "1.0",
    }

    return tornado.web.Application(
        [
            (r"/api/analyze", LogAnalyzeHandler, {
                "agent_client": agent_client,
                "app_config": app_config,
            }),
            (r"/api/health", HealthHandler, {
                "start_time": start_time,
                "port": port,
                "agent_client": agent_client,
            }),
            (r"/api/status", StatusHandler, {
                "agent_client": agent_client,
                "app_config": app_config,
            }),
        ],
        # 全局配置
        max_buffer_size=100 * 1024 * 1024,   # 100MB
        autoreload=False,                     # 生产环境必须关闭
        debug=False,
        serve_traceback=False,                # 不返回调用栈给客户端
    )


# ============================================================
# 主入口
# ============================================================

def main():
    parser = argparse.ArgumentParser(
        description="日志分析 Agent 服务 — Tornado Worker (Windows 多进程版)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  python app.py --port 8801
  python app.py --port 8801 --agent-timeout 120 --max-log-size-mb 100
        """,
    )
    parser.add_argument("--port", type=int, required=True,
                        help="监听端口 (如 8801)")
    parser.add_argument("--agent-timeout", type=int, default=60,
                        help="Agent 调用超时秒数 (默认 60)")
    parser.add_argument("--max-log-size-mb", type=int, default=50,
                        help="最大日志大小 MB (默认 50)")
    args = parser.parse_args()

    # ── 日志配置 ──
    logging.basicConfig(
        level=logging.INFO,
        format=f"%(asctime)s [worker:{args.port}] %(levelname)s %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    logging.info(f"启动 Tornado worker, 端口={args.port}, "
                 f"agent_timeout={args.agent_timeout}s, "
                 f"max_log_size={args.max_log_size_mb}MB")

    app = make_app(
        port=args.port,
        agent_timeout=args.agent_timeout,
        max_log_size_mb=args.max_log_size_mb,
    )

    server = tornado.httpserver.HTTPServer(
        app,
        max_buffer_size=100 * 1024 * 1024,
    )
    server.listen(args.port)
    logging.info(f"Worker 就绪: http://127.0.0.1:{args.port}/api/health")

    # ── 优雅关闭 ──
    def shutdown_handler(sig, frame):
        logging.info(f"收到信号 {sig}，开始优雅关闭...")
        # 关闭线程池 (等待正在执行的任务完成)
        LogAnalyzeHandler._executor.shutdown(wait=True, cancel_futures=False)
        tornado.ioloop.IOLoop.current().stop()
        logging.info("Worker 已关闭")

    signal.signal(signal.SIGTERM, shutdown_handler)
    signal.signal(signal.SIGINT, shutdown_handler)

    # ── 启动事件循环 ──
    tornado.ioloop.IOLoop.current().start()


if __name__ == "__main__":
    main()

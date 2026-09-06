#!/usr/bin/env python3
"""
Claude API Resilience Proxy v2
==============================
监听 localhost:8787，转发到上游 Anthropic API (兼容 DeepSeek/Anthropic)

四道防线（按执行顺序）：
  L0: 稳定性门控 — 网络抖时不发，等稳定了再发
  L1: HEAD 预检 — 发请求前确认服务器可达
  L2: 连接池 + 心跳 — 复用连接, 45s heartbeat 防 NAT 超时
  L3: 透明重试 — socket 错误自动重试 (3次, backoff 1/3/8s)

用法:
  # 默认转发到 DeepSeek
  python3 /root/claude-resilience-proxy.py &

  # 指定其他上游
  PROXY_TARGET=https://api.anthropic.com PROXY_PORT=8787 python3 /root/claude-resilience-proxy.py &

  # Claude 侧
  ANTHROPIC_BASE_URL=http://127.0.0.1:8787/anthropic claude --permission-mode accept-edits
"""

import http.server
import http.client
import urllib.request
import urllib.error
import json
import time
import threading
import socket
import ssl
import os
import select
from collections import deque
from urllib.parse import urlparse

# ── 配置 ──

TARGET_BASE = os.environ.get("PROXY_TARGET", "https://api.deepseek.com/anthropic")
LISTEN_PORT = int(os.environ.get("PROXY_PORT", "8787"))
MAX_RETRIES = int(os.environ.get("PROXY_RETRIES", "3"))
RETRY_BACKOFF = [1.0, 3.0, 8.0]          # 重试间隔 (秒)
HEARTBEAT_INTERVAL = 45                   # 连接保活间隔
IDLE_CONNECTION_TTL = 120                 # 连接最大空闲时间
UPSTREAM_TIMEOUT = 180                    # 上游请求超时

# 门控参数
STABILITY_WINDOW = 60                     # 滑动窗口 (秒)
STABILITY_THRESHOLD_NORMAL = 0.8          # 普通请求的稳定性阈值
STABILITY_THRESHOLD_THINKING = 0.9        # thinking 请求的稳定性阈值
STABILITY_STREAK_NORMAL = 3               # 普通请求需连续成功次数
STABILITY_STREAK_THINKING = 5             # thinking 请求需连续成功次数
MAX_HOLD_SECONDS = 90                     # 最大挂起时间
PROBE_INTERVAL = 5                        # 探测间隔
STABILITY_CONFIRM_DELAY = 2               # 连续探测确认延迟

# ── 网络稳定性追踪器 ──

class StabilityTracker:
    """滑动窗口追踪上游连接质量，为门控决策提供数据"""

    def __init__(self, window_seconds=STABILITY_WINDOW):
        self._window = window_seconds
        self._history = deque()
        self._lock = threading.Lock()

    def record_success(self, latency_ms: float = 0.0):
        with self._lock:
            self._history.append((time.time(), 'success', latency_ms))
            self._prune()

    def record_failure(self):
        with self._lock:
            self._history.append((time.time(), 'failure', 0))
            self._prune()

    def _prune(self):
        cutoff = time.time() - self._window
        while self._history and self._history[0][0] < cutoff:
            self._history.popleft()

    def score(self):
        """0.0 ~ 1.0, 无数据时返回 1.0 (首次不阻塞)"""
        with self._lock:
            self._prune()
            if not self._history:
                return 1.0
            total = len(self._history)
            successes = sum(1 for _, s, _ in self._history if s == 'success')
            return successes / total if total > 0 else 1.0

    def recent_streak(self, n=3):
        """最近 n 次是否全部成功"""
        with self._lock:
            self._prune()
            recent = list(self._history)[-n:]
            return len(recent) >= n and all(s == 'success' for _, s, _ in recent)

    def consecutive_failures(self):
        """连续失败次数"""
        with self._lock:
            self._prune()
            count = 0
            for _, status, _ in reversed(self._history):
                if status == 'failure':
                    count += 1
                else:
                    break
            return count

    def is_thinking_request(self, body: bytes) -> bool:
        """检测请求是否包含 thinking 参数"""
        try:
            data = json.loads(body)
            # Anthropic API: thinking 在顶层
            if data.get('thinking'):
                return True
            # messages 数组中嵌套的情况
            for msg in data.get('messages', []):
                if isinstance(msg, dict) and msg.get('thinking'):
                    return True
            return False
        except (json.JSONDecodeError, UnicodeDecodeError):
            return False

    def should_gate(self, body: bytes) -> bool:
        """判断是否需要门控（挂起等待）"""
        is_thinking = self.is_thinking_request(body)
        threshold = STABILITY_THRESHOLD_THINKING if is_thinking else STABILITY_THRESHOLD_NORMAL
        streak_n = STABILITY_STREAK_THINKING if is_thinking else STABILITY_STREAK_NORMAL

        score = self.score()
        streak_ok = self.recent_streak(streak_n)
        total = len(self._history)

        # 无历史数据 → 首次启动 → 不门控（假设网络正常）
        if total == 0:
            return False

        # 数据不足但无失败 → 给个机会（冷启动宽容期）
        if total < streak_n and self.consecutive_failures() == 0:
            return False

        if score >= threshold and streak_ok:
            return False  # 稳定，立刻放行
        return True       # 不稳定，需要门控


# 全局单例
_stability = StabilityTracker()

# ── 连接池 ──

class ConnectionPool:
    """维护到上游的健康连接，定期心跳保活"""

    def __init__(self):
        self._conn = None
        self._last_used = 0.0
        self._lock = threading.Lock()
        self._hostname = None
        self._port = None

        parsed = urlparse(TARGET_BASE)
        self._hostname = parsed.hostname
        self._port = parsed.port or 443

        self._heartbeat_thread = threading.Thread(target=self._heartbeat_loop, daemon=True)
        self._heartbeat_thread.start()

    def get_connection(self):
        with self._lock:
            now = time.time()
            if self._conn and (now - self._last_used) > IDLE_CONNECTION_TTL:
                self._close_locked()
            if self._conn is None:
                self._open_locked()
            self._last_used = now
            return self._conn

    def invalidate(self):
        with self._lock:
            self._close_locked()

    def _open_locked(self):
        try:
            sock = socket.create_connection((self._hostname, self._port), timeout=10)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            if hasattr(socket, 'TCP_KEEPIDLE'):
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 60)
            if hasattr(socket, 'TCP_KEEPINTVL'):
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 10)
            if hasattr(socket, 'TCP_KEEPCNT'):
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 3)

            ctx = ssl.create_default_context()
            ctx.minimum_version = ssl.TLSVersion.TLSv1_2
            self._conn = ctx.wrap_socket(sock, server_hostname=self._hostname)
        except Exception as e:
            print(f"[proxy] Connection failed: {e}")
            self._conn = None
            raise

    def _close_locked(self):
        if self._conn:
            try:
                self._conn.close()
            except Exception:
                pass
            self._conn = None

    def _heartbeat_loop(self):
        while True:
            time.sleep(HEARTBEAT_INTERVAL)
            with self._lock:
                if self._conn and (time.time() - self._last_used) > HEARTBEAT_INTERVAL:
                    try:
                        _, _, x = select.select([], [self._conn], [self._conn], 0)
                        if x:
                            self._close_locked()
                    except Exception:
                        self._close_locked()


_pool = ConnectionPool()

# ── 网络探测 ──

def quick_probe() -> bool:
    """发 HEAD 请求快速检测目标 API 是否可达（几乎零开销）"""
    try:
        parsed = urlparse(TARGET_BASE)
        host = parsed.hostname
        port = parsed.port or 443
        sock = socket.create_connection((host, port), timeout=5)
        ctx = ssl.create_default_context()
        with ctx.wrap_socket(sock, server_hostname=host) as ssock:
            # 发送最小 HTTP/1.1 HEAD 请求
            request = (
                f"HEAD {parsed.path or '/'} HTTP/1.1\r\n"
                f"Host: {host}\r\n"
                f"Connection: close\r\n"
                f"\r\n"
            ).encode()
            ssock.sendall(request)
            response = ssock.recv(1024)
            return b'HTTP' in response
    except Exception:
        return False

# ── 门控等待 ──

def wait_for_stability(threshold, streak_n, max_wait=MAX_HOLD_SECONDS):
    """挂起等待网络稳定，超时后无论如何都放行"""
    deadline = time.time() + max_wait
    waited = 0

    while time.time() < deadline:
        score = _stability.score()
        streak_ok = _stability.recent_streak(streak_n)

        if score >= threshold and streak_ok:
            # 稳定性确认：等待确认延迟后再检查一次
            time.sleep(STABILITY_CONFIRM_DELAY)
            score2 = _stability.score()
            streak_ok2 = _stability.recent_streak(streak_n)
            if score2 >= threshold and streak_ok2:
                print(f"[proxy] Gate passed after {waited:.0f}s (score={score2:.2f})")
                return True

        remaining = deadline - time.time()
        if remaining <= 0:
            break

        # 发探测包测量网络
        probe_ok = quick_probe()
        if probe_ok:
            _stability.record_success()
        else:
            _stability.record_failure()

        sleep_time = min(PROBE_INTERVAL, max(remaining, 1))
        time.sleep(sleep_time)
        waited += sleep_time

    # 超时，放行
    print(f"[proxy] Gate timeout after {waited:.0f}s, releasing anyway")
    return True

# ── HTTP 代理 ──

class ProxyHandler(http.server.BaseHTTPRequestHandler):

    def log_message(self, format, *args):
        return  # 静默默认日志

    def do_POST(self):
        self._handle("POST")

    def do_GET(self):
        self._handle("GET")

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.end_headers()

    def _handle(self, method):
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length) if content_length > 0 else b''
        target_url = TARGET_BASE + self.path

        forward_headers = {}
        for key in ('content-type', 'authorization', 'x-api-key',
                     'anthropic-version', 'anthropic-beta'):
            val = self.headers.get(key)
            if val:
                forward_headers[key] = val

        # ── L0: 稳定性门控 ──
        is_thinking = _stability.is_thinking_request(body)
        threshold = STABILITY_THRESHOLD_THINKING if is_thinking else STABILITY_THRESHOLD_NORMAL
        streak_n = STABILITY_STREAK_THINKING if is_thinking else STABILITY_STREAK_NORMAL

        if _stability.should_gate(body):
            tag = "thinking" if is_thinking else "normal"
            print(f"[proxy] Gating {tag} request (score={_stability.score():.2f}), holding...")

            if not wait_for_stability(threshold, streak_n):
                self.send_response(503)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    "error": {
                        "type": "gate_timeout",
                        "message": f"Network unstable for {MAX_HOLD_SECONDS}s, "
                                   "request not sent to preserve tokens. Retry later."
                    }
                }).encode())
                return

        # ── L1: HEAD 预检 ──
        if not quick_probe():
            _stability.record_failure()
            print("[proxy] HEAD probe failed, network may be down")

        # ── L2+L3: 发送 + 重试 ──
        last_error = None
        for attempt in range(MAX_RETRIES):
            try:
                req = urllib.request.Request(target_url, data=body,
                                             headers=forward_headers, method=method)
                start = time.time()

                with urllib.request.urlopen(req, timeout=UPSTREAM_TIMEOUT) as resp:
                    self.send_response(resp.status)
                    for key, val in resp.headers.items():
                        kl = key.lower()
                        if kl not in ('transfer-encoding', 'connection',
                                       'keep-alive', 'proxy-authenticate',
                                       'proxy-authorization', 'te', 'trailer', 'upgrade'):
                            self.send_header(key, val)
                    self.end_headers()

                    total = 0
                    while True:
                        chunk = resp.read(65536)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        self.wfile.flush()
                        total += len(chunk)

                    latency = (time.time() - start) * 1000
                    _stability.record_success(latency)

                    retry_tag = f" [retry #{attempt+1}]" if attempt > 0 else ""
                    gate_tag = " [gated-thinking]" if is_thinking else ""
                    print(f"[proxy] {method} {self.path} → {resp.status} "
                          f"({total}B, {latency:.0f}ms){retry_tag}{gate_tag}")
                    return

            except (urllib.error.URLError, ConnectionResetError,
                    BrokenPipeError, TimeoutError, OSError,
                    http.client.RemoteDisconnected, ssl.SSLError) as e:

                last_error = e
                _stability.record_failure()

                error_str = str(e).lower()
                is_socket_error = any(kw in error_str for kw in (
                    'socket', 'connection', 'reset', 'broken pipe',
                    'timeout', 'eof', 'closed', 'unexpectedly',
                    'remote disconnect', 'ssl', 'tls'
                ))

                if not is_socket_error or attempt == MAX_RETRIES - 1:
                    break

                wait = RETRY_BACKOFF[min(attempt, len(RETRY_BACKOFF) - 1)]
                print(f"[proxy] Socket error, retry {attempt+1}/{MAX_RETRIES} "
                      f"in {wait}s: {e}")
                _pool.invalidate()
                time.sleep(wait)

        # 所有重试耗尽
        error_msg = str(last_error)[:300]
        print(f"[proxy] {method} {self.path} → 502 "
              f"after {MAX_RETRIES} retries: {error_msg}")

        self.send_response(502)
        self.send_header('Content-Type', 'application/json')
        self.send_header('X-Proxy-Error', error_msg[:200])
        self.end_headers()
        self.wfile.write(json.dumps({
            "error": {
                "type": "proxy_unreachable",
                "message": f"Upstream unreachable after {MAX_RETRIES} retries",
                "detail": error_msg,
                "action": "The proxy could not reach the API. "
                          "Save your task state and retry."
            }
        }).encode())

# ── 主入口 ──

if __name__ == '__main__':
    server = http.server.HTTPServer(('127.0.0.1', LISTEN_PORT), ProxyHandler)
    server.socket.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)

    print(f"╔══════════════════════════════════════════════════════╗")
    print(f"║  Claude API Resilience Proxy v2                      ║")
    print(f"╠══════════════════════════════════════════════════════╣")
    print(f"║  Listen:      127.0.0.1:{LISTEN_PORT}                            ║")
    print(f"║  Target:      {TARGET_BASE}")
    print(f"║                                                     ║")
    print(f"║  L0 Gate:     thinking≥{STABILITY_THRESHOLD_THINKING} normal≥{STABILITY_THRESHOLD_NORMAL}     ║")
    print(f"║  L1 Probe:    HEAD pre-check                        ║")
    print(f"║  L2 Pool:     heartbeat {HEARTBEAT_INTERVAL}s, TTL {IDLE_CONNECTION_TTL}s              ║")
    print(f"║  L3 Retry:    {MAX_RETRIES} attempts, backoff {RETRY_BACKOFF}              ║")
    print(f"╚══════════════════════════════════════════════════════╝")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[proxy] Shutting down")
        server.shutdown()

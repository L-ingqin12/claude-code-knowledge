---
title: 网络稳定性门控 — 不稳定时延迟发送，稳定后再发送
aliases: []
tags: [ai/ops, ai/agent]
created: 2026-07-01
updated: 2026-08-25
status: review
---

# 网络稳定性门控 — 不稳定时延迟发送，稳定后再发送

See also: [[Claude-Ops-KB-Home]] · [[claude-network-resilience-v2]] · [[claude-resilience-architecture]]

> 核心思路：在代理层增加一个"网络稳定性门控"。
> 网络抖时不发请求 → 等稳定了再发 → 避免 thinking 进行中被中断。
> 这是对思考中 token 浪费的唯一有效缓解。

---

## 一、原理

```
之前（盲目发送）:
  Claude 发请求 → 代理直接转发 → 网络不稳定 → socket 中途断开
  → thinking 中断 → 重试 → 再次 thinking → 两次计费

之后（门控发送）:
  Claude 发请求 → 代理先检查网络是否稳定
    ├── 不稳定: 挂起请求, 定期探测, 等网络稳定后再转发
    └── 稳定:   立即转发
  → 请求在网络稳定时发出 → thinking 不会中途被打断
  → 一次计费
```

## 二、稳定性度量

### 2.1 用滑动窗口评估网络质量

```
代理维护一个 60 秒滑动窗口的统计:

  成功: 请求完整返回（收到了完整响应）
  失败: socket 错误（连接中断、超时、reset）
  延迟: 最近 N 次请求的 RTT

稳定性分数 = 成功次数 / (成功次数 + 失败次数)

阈值:
  稳定:   分数 ≥ 0.8, 且最近 3 次请求全部成功
  抖动:   分数 < 0.8, 或最近 3 次中有失败
  灾难:   连续 3 次失败（网络完全不通）
```

### 2.2 不只是"通不通"，是"稳不稳"

```
场景 A: 网络刚恢复
  最近统计: 1 成功, 4 失败 → 分数 0.2 → 抖动
  → 虽然现在能通，但不稳定 → 不发

场景 B: 网络持续稳定
  最近统计: 10 成功, 0 失败 → 分数 1.0 → 稳定
  → 安全发送

场景 C: 思考中的请求尤其谨慎
  思考请求: 阈值提高到 0.9, 并要求最近 5 次全成功
  普通请求: 阈值 0.8, 最近 3 次全成功
```

## 三、挂起机制

### 3.1 代理如何"挂起"而不让 Claude 超时

```
Claude 发 POST 请求 → 代理收到 → 网络不稳定 → 代理不转发
                                                 ↓
                                       每 5s 发 HEAD 探测
                                       探测成功 → 等 2s 再测一次
                                       两次都成功 → 网络真的稳了
                                                 ↓
                                       代理转发 Claude 的请求到上游
                                       响应返回 → 转发给 Claude

关键: Claude 的 HTTP 连接一直保持着（没断，没超时）
     代理把响应延迟了 N 秒后返回
     Claude 视角: 这次 API 调用比平时慢了 N 秒，但成功了
     Claude 不会报错、不会中断
```

### 3.2 时间预算

```
Claude Code 的上游超时: 通常 120-180 秒
代理最大挂起时间: 90 秒（留 30-90 秒给实际的 API 调用）
探测间隔: 5 秒
稳定确认延迟: 额外 2 秒（连续两次探测成功才算稳）

最坏情况:
  代理挂起 90 秒 + API 调用 10 秒 = 100 秒 → Claude 等到结果 → 成功
  代理挂起 90 秒 + 网络未恢复 → wait_for_stability 超时也返回 True (fail-open，与代码一致) → 请求照发，不阻塞主流程
```

## 四、实现

### 4.1 稳定性追踪器

```python
import time
import threading
from collections import deque

class StabilityTracker:
    """滑动窗口追踪上游连接质量"""
    
    def __init__(self, window_seconds=60):
        self._window = window_seconds
        self._history = deque()  # [(timestamp, 'success'|'failure', latency_ms)]
        self._lock = threading.Lock()
    
    def record_success(self, latency_ms=0):
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
        """返回 0.0 ~ 1.0 的稳定性分数"""
        with self._lock:
            self._prune()
            if not self._history:
                return 1.0  # 没有数据 = 假设稳定（首次请求不阻塞）
            
            total = len(self._history)
            successes = sum(1 for _, status, _ in self._history if status == 'success')
            return successes / total
    
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

# 全局单例
tracker = StabilityTracker(window_seconds=60)
```

### 4.2 请求门控

```python
import urllib.request

STABILITY_THRESHOLD = 0.8       # 普通请求
STABILITY_THRESHOLD_THINKING = 0.9  # 思考请求（更谨慎）
PROBE_INTERVAL = 5              # 探测间隔(秒)
MAX_HOLD_SECONDS = 90           # 最大挂起时间
STABILITY_CONFIRM_DELAY = 2     # 连续两次探测确认稳定

def is_thinking_request(body: bytes) -> bool:
    """检测请求是否启用了 thinking"""
    try:
        data = json.loads(body)
        # Anthropic API: thinking 在请求体中
        return bool(data.get('thinking'))
    except:
        return False

def wait_for_stability(threshold, max_wait, target_url, headers):
    """
    挂起当前请求，等待网络稳定。
    返回 True 表示现在可以发送，False 表示超时。
    """
    deadline = time.time() + max_wait
    
    while time.time() < deadline:
        score = tracker.score()
        streak_ok = tracker.recent_streak(n=(5 if threshold > 0.85 else 3))
        
        if score >= threshold and streak_ok:
            # 稳定性确认：等 2 秒再测一次
            time.sleep(STABILITY_CONFIRM_DELAY)
            score2 = tracker.score()
            streak_ok2 = tracker.recent_streak(n=(5 if threshold > 0.85 else 3))
            
            if score2 >= threshold and streak_ok2:
                return True  # 真的稳了
        
        # 网络还不行 → 发探测包测试
        remaining = deadline - time.time()
        if remaining <= 0:
            break
        
        # 快速 HEAD 探测
        probe_ok = _quick_head_probe(target_url, headers)
        if probe_ok:
            tracker.record_success(latency_ms=0)
        else:
            tracker.record_failure()
        
        time.sleep(min(PROBE_INTERVAL, remaining))
    
    # 超时 → 不等了，无论如何都发（比完全失败强）
    return True
```

### 4.3 集成到代理处理器中

```python
def _handle(self, method):
    content_length = int(self.headers.get('Content-Length', 0))
    body = self.rfile.read(content_length) if content_length > 0 else b''
    target_url = TARGET_BASE + self.path
    
    # ... headers ...
    
    # ── 门控决策 ──
    is_thinking = is_thinking_request(body)
    threshold = STABILITY_THRESHOLD_THINKING if is_thinking else STABILITY_THRESHOLD
    
    # streak 阈值随模式配置: 普通3/thinking5
    # 注: 实现暂统一为 3（thinking 的 5 连胜阈值待参数化后生效）
    if tracker.score() < threshold or not tracker.recent_streak(3):
        if is_thinking:
            print(f"[proxy] Thinking request gated — network unstable "
                  f"(score={tracker.score():.2f}), holding...")
        
        ok = wait_for_stability(
            threshold=threshold,
            max_wait=MAX_HOLD_SECONDS,
            target_url=target_url,
            headers=forward_headers
        )
        
        if not ok:
            # 防御性分支: 当前 wait_for_stability 超时也返回 True (fail-open)，
            # 此分支不可达；保留以备未来改为 fail-closed 语义
            self._send_gate_timeout()
            return
    
    # ── 网络稳定，正常发送 ──
    for attempt in range(MAX_RETRIES):
        try:
            req = urllib.request.Request(target_url, data=body, ...)
            start = time.time()
            with urllib.request.urlopen(req, timeout=UPSTREAM_TIMEOUT) as resp:
                # ... 转发响应 ...
                latency = (time.time() - start) * 1000
                tracker.record_success(latency)
            return
        except (...) as e:
            tracker.record_failure()
            # ... 重试逻辑 ...
```

## 五、效果

### 5.1 场景分析

```
场景: 手机 WiFi 断开，自动切换到蜂窝网络

不加门控:
  T+0s   网络切换开始（WiFi 断, 蜂窝正在连接）
  T+1s   代理发送思考请求 → 走 WiFi 接口 → socket 断
  T+2s   代理重试 (1s backoff) → 还是断
  T+5s   代理二次重试 (3s backoff) → 仍断；此时网络切换完成
  T≈13s  代理三次重试 (8s backoff) → 成功（1/3/8s backoff）
  浪费: 前两次请求的 input tokens + 可能的部分 thinking tokens

加门控:
  T+0s    网络切换开始
  T+1s    代理检查稳定性: score 下降 → 挂起请求
  T+2s    代理 HEAD 探测: 失败 → 记录失败, 继续等
  T+5s    网络切换完成
  T+6s    代理 HEAD 探测: 成功
  T+8s    第二次探测: 成功 → 网络确认稳定
  T+8s    代理转发请求 → 成功
  浪费: 零！（请求只在网络稳定后才发出）
```

### 5.2 量化

| 场景 | 无门控浪费 | 有门控浪费 | 额外延迟 |
|------|----------|----------|---------|
| WiFi→蜂窝切换 | 1-2次请求 | 0 | 5-15s |
| 瞬时抖动(2s) | 1次请求 | 0 | 3-8s |
| 长断网(>2min) | 2-3次请求 | 0 | 最多90s然后发(接受风险) |
| 网络持续稳定 | 0 | 0 | 0(直接放行) |

## 六、取舍

```
收益:
  ✅ 思考中 token 浪费从"偶尔发生,每次几千 tokens"→"基本杜绝"
  ✅ 每次能省 X input tokens + 部分 thinking tokens
  ✅ 网络切换场景（移动端最常见！）完全覆盖

代价:
  ⚠️ 网络切换后额外 3-15s 延迟
  ⚠️ 极端情况（长断网）可能多等 90s
  ⚠️ HEAD 探测本身极小开销（TCP+TLS 握手, ~1KB）

判断: 对于移动网络环境, 收益远大于代价。
      等待 5-15 秒换来省几千 tokens, 非常划算。
```

## 七、与现有组件的集成

```
更新 claude-resilience-proxy.py：
  + StabilityTracker 类
  + is_thinking_request() 检测
  + wait_for_stability() 门控
  + HEAD 探测逻辑

现有逻辑不变：
  重试机制保留（门控之后仍然有重试）
  TCP keepalive 保留（减少门控触发概率）
  连接池保留

效果:
  第 1 道防线: TCP keepalive → 让连接不容易断
  第 2 道防线: 门控 → 不稳时不发, 稳了再发  
  第 3 道防线: 重试 → 万一还是断了, 自动重试
  第 4 道防线: context-dump → 万一全失败了, 手动能恢复
```

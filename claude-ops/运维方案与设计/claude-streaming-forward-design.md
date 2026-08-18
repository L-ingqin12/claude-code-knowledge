---
title: Proxy 流式转发 + Model Router 协同方案
aliases: []
tags: [ai/ops, ai/agent]
created: 2026-06-17
updated: 2026-08-17
status: review
---

# Proxy 流式转发 + Model Router 协同方案

See also: [[Claude-Ops-KB-Home]] · [[claude-flash-primary-analysis]] · [[PERMAFROST_MODIFICATIONS]]

> 日期: 2026-06-17 | 状态: 方案设计，待落实

---

## 一、现状

```
CC → permafrost(:8788) → proxy(:8787) → DeepSeek
       ✅ 已流式(chunked)         ❌ 全量缓冲
       嗅探head 256KB                  ↓
       嗅探tail 64KB              先收完再发给 CC
       model_router 反馈挂载点       (瓶颈: 25s 平均延迟)
```

**只需改 proxy 一处**。permafrost 已经是流式的。

---

## 二、Proxy 改动: 缓冲 → pipe

### 当前代码 (缓冲模式)

```javascript
// doRequest() — 第28-34行
res.on('data', c => data.push(c));
res.on('end', () => resolve({
    status: res.statusCode,
    headers: res.headers,
    body: Buffer.concat(data),
}));

// createServer — 第94行
clientRes.writeHead(result.status, resHeaders);
clientRes.end(result.body);  // 一次性发送
```

### 目标代码 (流式模式)

```javascript
// doRequest() — 改为直接返回 upstream response
function doRequest(opts, body, retries) {
    return new Promise((resolve, reject) => {
        const req = https.request({
            hostname: TARGET_URL.hostname, port: 443,
            path: TARGET_URL.pathname + opts.path,
            method: opts.method,
            headers: { ...opts.headers, host: TARGET_URL.hostname },
            timeout: 180000,
        }, (res) => {
            // 直接返回 response stream, 不缓冲
            resolve({ status: res.statusCode, headers: res.headers, stream: res });
        });
        req.on('error', reject);
        if (body) req.write(body);
        req.end();
    });
}

// createServer — 改为 pipe
clientRes.writeHead(result.status, resHeaders);
result.stream.pipe(clientRes);  // 边收边发
```

### 重试兼容

流式模式下已开始写响应头，不能重试。改为只在连接建立阶段重试：

```javascript
req.on('error', (err) => {
    // 只重试连接错误（响应头还没写）
    if (!clientRes.headersSent && isRetryable(err) && retries > 0) {
        setTimeout(() => doRequest(opts, body, retries - 1).then(...), delay);
    } else {
        // 已经开始写响应了 → 记录错误, 客户端会看到断开
        console.error(`[proxy] stream error: ${err.message}`);
        if (!clientRes.headersSent) {
            clientRes.writeHead(502, { 'Content-Type': 'application/json' });
            clientRes.end(JSON.stringify({ error: 'upstream_error' }));
        }
    }
});
```

---

## 三、Model Router 质量反馈

### 当前: 读 permafrost 已嗅探的 head

permafrost_proxy.py `_forward()` 中已有：

```python
head = bytearray()   # 前 256KB (第一个 chunk 通常是完整响应)
tail = bytearray()   # 后 64KB

# 每收一个 chunk:
head.extend(chunk[: _SNIFF_HEAD - len(head)])
tail.extend(chunk)
if len(tail) > _SNIFF_TAIL: del tail[:-_SNIFF_TAIL]

# 转发后, 已有的调用:
u_head = _sniff_usage(bytes(head).decode(...))
u_tail = _sniff_usage(bytes(tail).decode(...))
# → 这里已经有完整的响应文本
```

### Model router 复用这个 head:

```python
# 在现有 STATS.record_usage 之后
if os.environ.get("PERMAFROST_MODEL_ROUTING") == "1":
    resp_text = bytes(head).decode("utf-8", "replace")
    from model_router import feedback_flash_response
    feedback_flash_response(session, resp_text)
```

**已实现，无需改动。**

---

## 四、改动清单

| 文件 | 改动 | 行数 |
|------|------|------|
| `claude-resilience-proxy.js` | 缓冲→pipe, 重试逻辑适配 | ~30行 |
| permafrost: 无改动 | 已经是流式 | 0 |
| model_router: 无改动 | 已复用 head 嗅探 | 0 |

---

## 五、质量反馈兼容性分析

permafrost 的流式嗅探机制天然兼容质量反馈：

```
DeepSeek 响应 → permafrost 收 chunk
                  ├─ head buffer (前256KB) → 质量反馈: 长度/拒绝/空回复
                  ├─ tail buffer (后64KB)  → token 统计: hit/miss
                  └─ _write_chunk() → 立即发给 CC (流式)
```

| 质量信号 | 覆盖范围 | 说明 |
|---------|---------|------|
| 回复过短 (<50 chars) | head ✅ | 前几个 chunk 就能判断 |
| 模型拒绝 ("I cannot") | head ✅ | 拒绝语在回复开头 |
| 显式退出/错误 | head ✅ | 异常回复通常很短 |
| 工具调用结果 | head ✅ | tool_use block 在 256KB 内 |
| 只有 >256KB 的超长回复 | tail ⚠️ | 极少，且本身说明是复杂任务 |

**flash 简单回复 100% 落在 256KB head 内，质量反馈完全不受影响。**

## 六、预期效果

| 指标 | 当前 | 优化后 |
|------|------|--------|
| CC 收到首字节延迟 | 平均 25s (等完整响应) | ~2-3s (第一个chunk) |
| 感知延迟 | 76s (最坏) | ~3-5s (流式首字节) |
| 重试能力 | 全量重试 | 连接阶段重试 |
| 内存占用 | 缓冲全量 (~1MB) | 流式 (~16KB) |

---

## 附2: Proxy 层工具归一化 (预研, 待落地)

### 方案
proxy.js 第73行后插入 ~15行, 读取 `~/.claude/tool-anchor.json` 配置,
剥离非锚点工具后转发。version-hook.sh 自动维护配置。

### 状态
- 代码已就绪，待隔离测试(:8789)
- 逃生: 删除配置文件 → 恢复全量工具; L0a关闭permafrost补丁
- 风险: 极低(解析失败原样转发, 仅影响POST /v1/messages)

### 落地条件
1. 隔离测试通过
2. 逃生通道验证
3. 当前 permafrost 补丁稳定运行 ≥1周

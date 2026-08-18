/**
 * server.ts — Express HTTP 服务 (Pi Agent 版)
 *
 * 日志分析 API 服务入口。
 * 支持单进程启动 (配合 cluster 或 Nginx upstream 水平扩展)。
 *
 * 启动:
 *   npx tsx src/server.ts
 *   PORT=8801 npx tsx src/server.ts
 */

import express from "express";
import type { Request, Response } from "express";
import { analyzeLog, TimeoutError, AnalysisError } from "./agent-service.js";

// ============================================================
// 配置
// ============================================================

const PORT = parseInt(process.env.PORT || "8801", 10);
const WORKER_ID = process.env.WORKER_ID || "0";
const MAX_LOG_SIZE_MB = parseInt(process.env.MAX_LOG_SIZE_MB || "50", 10);
const AGENT_TIMEOUT_S = parseInt(process.env.AGENT_TIMEOUT_S || "60", 10);

// ============================================================
// Express 应用
// ============================================================

const app = express();

// ── 中间件 ──
app.use(express.json({ limit: `${MAX_LOG_SIZE_MB + 10}mb` }));

// 请求日志
app.use((req, _res, next) => {
  console.log(`${new Date().toISOString()} [worker:${WORKER_ID}] ${req.method} ${req.path}`);
  next();
});

// ============================================================
// API 路由
// ============================================================

/**
 * GET /api/health — 健康检查
 */
app.get("/api/health", (_req: Request, res: Response) => {
  res.json({
    status: "ok",
    worker_id: WORKER_ID,
    port: PORT,
    uptime_seconds: Math.round(process.uptime()),
    engine: "pi-agent",
    version: "1.0.0",
    node_version: process.version,
    memory_mb: Math.round(process.memoryUsage().rss / 1024 / 1024),
  });
});

/**
 * GET /api/status — 运行时状态
 */
app.get("/api/status", (_req: Request, res: Response) => {
  res.json({
    config: {
      port: PORT,
      worker_id: WORKER_ID,
      agent_timeout_s: AGENT_TIMEOUT_S,
      max_log_size_mb: MAX_LOG_SIZE_MB,
    },
    process: {
      pid: process.pid,
      uptime: process.uptime(),
      memory: {
        rss_mb: Math.round(process.memoryUsage().rss / 1024 / 1024),
        heap_mb: Math.round(process.memoryUsage().heapUsed / 1024 / 1024),
      },
    },
  });
});

/**
 * POST /api/analyze — 日志分析
 *
 * 请求体:
 *   {
 *     "log_content": "<日志原文>",
 *     "context": {
 *       "source": "nginx",        // 可选
 *       "format": "json",         // 可选
 *       "hint": "关注超时错误",     // 可选
 *       "timeout": 60,            // 可选, 覆盖默认超时(秒)
 *       "fanout": true            // 可选, 启用 Fan-Out 多维度并行 (默认 true)
 *     }
 *   }
 *
 * 响应:
 *   {
 *     "request_id": "abc123",
 *     "status": "ok",
 *     "result": {
 *       "summary": "...",
 *       "severity": "error",
 *       "issues": [...],
 *       "stats": {...},
 *       "confidence": 0.85
 *     },
 *     "metadata": {
 *       "wall_time_ms": 3500,
 *       "turns_used": 3,
 *       "tools_called": ["bash", "read", "bash", "write"],
 *       "fanout_dimensions": 4
 *     }
 *   }
 */
app.post("/api/analyze", async (req: Request, res: Response) => {
  const requestId = Math.random().toString(36).slice(2, 10);
  const startTime = Date.now();

  try {
    const { log_content, context } = req.body;

    // ── 参数校验 ──
    if (!log_content || typeof log_content !== "string") {
      return res.status(400).json({
        error: "log_content is required and must be a string",
        request_id: requestId,
      });
    }

    const contentBytes = Buffer.byteLength(log_content, "utf8");
    const maxSize = MAX_LOG_SIZE_MB * 1024 * 1024;
    if (contentBytes > maxSize) {
      return res.status(413).json({
        error: `log too large: ${contentBytes} bytes (max ${maxSize})`,
        request_id: requestId,
        size_bytes: contentBytes,
        max_size_bytes: maxSize,
      });
    }

    console.log(
      `[${requestId}] 开始分析, ` +
      `worker=${WORKER_ID}, ` +
      `size=${contentBytes}B, ` +
      `source=${context?.source || "unknown"}, ` +
      `fanout=${context?.fanout !== false}`
    );

    // ── 流式进度 (SSE 支持) ──
    const acceptSSE = req.headers.accept?.includes("text/event-stream");

    if (acceptSSE) {
      // SSE 流式响应
      res.writeHead(200, {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-cache",
        Connection: "keep-alive",
        "X-Request-Id": requestId,
      });

      const sendSSE = (event: string, data: any) => {
        res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
      };

      try {
        const result = await analyzeLog({
          logContent: log_content,
          context,
          onProgress: (evt) => {
            sendSSE("progress", { type: evt.type, data: evt.data });
          },
        });

        const elapsed = Date.now() - startTime;
        sendSSE("result", {
          request_id: requestId,
          status: "ok",
          result: result.analysis,
          metadata: { ...result.metadata, wall_time_ms: elapsed },
        });
        res.end();
      } catch (err) {
        sendSSE("error", { request_id: requestId, error: (err as Error).message });
        res.end();
      }
      return;
    }

    // ── 标准 JSON 响应 ──
    const result = await analyzeLog({
      logContent: log_content,
      context,
      onProgress: undefined, // 非 SSE 模式不推送进度
    });

    const elapsed = Date.now() - startTime;

    console.log(
      `[${requestId}] 分析完成, ` +
      `worker=${WORKER_ID}, ` +
      `elapsed=${elapsed}ms, ` +
      `issues=${result.analysis.issues.length}, ` +
      `confidence=${result.analysis.confidence}`
    );

    res.json({
      request_id: requestId,
      status: "ok",
      result: result.analysis,
      metadata: {
        ...result.metadata,
        wall_time_ms: elapsed,
      },
    });

  } catch (err: any) {
    const elapsed = Date.now() - startTime;

    if (err instanceof TimeoutError) {
      console.warn(`[${requestId}] 分析超时, elapsed=${elapsed}ms`);
      return res.status(504).json({
        request_id: requestId,
        status: "timeout",
        error: `log analysis timed out after ${AGENT_TIMEOUT_S}s`,
        wall_time_ms: elapsed,
      });
    }

    if (err instanceof AnalysisError) {
      console.error(`[${requestId}] 分析失败: ${err.message}`);
      return res.status(500).json({
        request_id: requestId,
        status: "error",
        error: err.message,
        wall_time_ms: elapsed,
      });
    }

    console.error(`[${requestId}] 未知错误:`, err);
    res.status(500).json({
      request_id: requestId,
      status: "error",
      error: "internal server error",
      wall_time_ms: elapsed,
    });
  }
});

/**
 * POST /api/analyze/fanout — Fan-Out 多维度并行分析
 *
 * 显式代码级 Fan-Out: 将日志分析拆分为 4 个维度并行执行。
 * 每个维度使用独立 Agent 实例 → 完全隔离。
 *
 * 与默认 /api/analyze 的区别:
 *   - /api/analyze: 依赖 LLM 自主并行工具调用 (灵活但不可控)
 *   - /api/analyze/fanout: 代码级 Fan-Out (4 个 Agent 实例并行, 结果可控)
 */
app.post("/api/analyze/fanout", async (req: Request, res: Response) => {
  const requestId = Math.random().toString(36).slice(2, 10);
  const startTime = Date.now();

  try {
    const { log_content, context } = req.body;

    if (!log_content || typeof log_content !== "string") {
      return res.status(400).json({ error: "log_content is required" });
    }

    console.log(`[${requestId}] Fan-Out 模式: 启动 4 维度并行分析`);

    // ── 动态导入 Fan-Out 模块 ──
    const { fanoutAnalyze } = await import("./fanout-service.js");

    const result = await fanoutAnalyze({
      logContent: log_content,
      context,
      onProgress: (dim, evt) => {
        console.log(`[${requestId}] [${dim}] ${evt.type}: ${evt.data}`);
      },
    });

    const elapsed = Date.now() - startTime;

    console.log(
      `[${requestId}] Fan-Out 完成, ` +
      `elapsed=${elapsed}ms, ` +
      `dimensions=${result.dimensionResults.length}`
    );

    res.json({
      request_id: requestId,
      status: "ok",
      result: result.merged,
      dimensions: result.dimensionResults.map((d) => ({
        name: d.dimension,
        issues: d.analysis.issues.length,
        confidence: d.analysis.confidence,
        elapsed_ms: d.elapsedMs,
      })),
      metadata: {
        wall_time_ms: elapsed,
        fanout_dimensions: result.dimensionResults.length,
        mode: "fanout",
      },
    });

  } catch (err: any) {
    const elapsed = Date.now() - startTime;
    console.error(`[${requestId}] Fan-Out 失败:`, err);
    res.status(500).json({
      request_id: requestId,
      status: "error",
      error: err.message,
      wall_time_ms: elapsed,
    });
  }
});

// ============================================================
// 404 处理
// ============================================================

app.use((_req: Request, res: Response) => {
  res.status(404).json({ error: "not found" });
});

// ============================================================
// 启动
// ============================================================

app.listen(PORT, () => {
  console.log([
    `╔══════════════════════════════════════════╗`,
    `║  日志分析 Agent — Pi Agent Worker        ║`,
    `╠══════════════════════════════════════════╣`,
    `║  Worker ID : ${WORKER_ID.padEnd(30)}║`,
    `║  Port      : ${String(PORT).padEnd(30)}║`,
    `║  Engine    : Pi Agent (TypeScript SDK)   ║`,
    `║  Timeout   : ${String(AGENT_TIMEOUT_S + "s").padEnd(30)}║`,
    `║  Max Log   : ${String(MAX_LOG_SIZE_MB + "MB").padEnd(30)}║`,
    `╚══════════════════════════════════════════╝`,
  ].join("\n"));
});

// ── 优雅关闭 ──
process.on("SIGTERM", () => {
  console.log(`[worker:${WORKER_ID}] 收到 SIGTERM，优雅关闭...`);
  process.exit(0);
});

process.on("SIGINT", () => {
  console.log(`[worker:${WORKER_ID}] 收到 SIGINT，优雅关闭...`);
  process.exit(0);
});

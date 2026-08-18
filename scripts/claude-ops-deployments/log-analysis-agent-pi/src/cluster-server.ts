/**
 * cluster-server.ts — Node.js Cluster 多进程管理
 *
 * Windows 上不支持 cluster 的 round-robin 调度 (使用 OS 默认行为)。
 * 每个 Worker 监听独立端口，配合 Nginx upstream 实现负载均衡。
 *
 * 启动:
 *   node dist/cluster-server.js
 *   WORKERS=8 PORT_START=9000 node dist/cluster-server.js
 *
 * 与 opencode 版对比:
 *   opencode 版: Python 手动多进程 (启动多个 python app.py --port N)
 *   Pi Agent 版: Node.js cluster (Primary 管理 Worker 生命周期)
 *
 * 参考:
 *   - plans/pi-agent-log-analysis-plan.md
 *   - [[log-analysis-agent-windows-architecture]] (opencode 版对比)
 */

import cluster from "node:cluster";
import { availableParallelism } from "node:os";

// ============================================================
// 配置
// ============================================================

const WORKER_COUNT = parseInt(process.env.WORKERS || "4", 10);
const PORT_START = parseInt(process.env.PORT_START || "8801", 10);
const AGENT_TIMEOUT = process.env.AGENT_TIMEOUT_S || "60";
const MAX_LOG_SIZE = process.env.MAX_LOG_SIZE_MB || "50";

// ============================================================
// Primary 进程
// ============================================================

if (cluster.isPrimary) {
  console.log([
    `╔══════════════════════════════════════════╗`,
    `║  日志分析 Agent — Pi Cluster Manager      ║`,
    `╠══════════════════════════════════════════╣`,
    `║  PID       : ${String(process.pid).padEnd(30)}║`,
    `║  Workers   : ${String(WORKER_COUNT).padEnd(30)}║`,
    `║  Port Range: ${String(`${PORT_START}-${PORT_START + WORKER_COUNT - 1}`).padEnd(30)}║`,
    `║  Platform  : ${String(process.platform).padEnd(30)}║`,
    `║  CPUs      : ${String(availableParallelism()).padEnd(30)}║`,
    `╚══════════════════════════════════════════╝`,
  ].join("\n"));

  // 记录 Worker 状态
  const workerMap = new Map<number, { pid: number; port: number; startTime: number }>();

  // ── 启动所有 Worker ──
  for (let i = 0; i < WORKER_COUNT; i++) {
    const port = PORT_START + i;
    const worker = cluster.fork({
      PORT: String(port),
      WORKER_ID: String(i),
      AGENT_TIMEOUT_S: AGENT_TIMEOUT,
      MAX_LOG_SIZE_MB: MAX_LOG_SIZE,
    });

    workerMap.set(worker.id, {
      pid: worker.process.pid!,
      port,
      startTime: Date.now(),
    });

    console.log(`  Worker ${i} → PID ${worker.process.pid}, 端口 ${port}`);
  }

  // ── 崩溃重启 ──
  cluster.on("exit", (worker, code, signal) => {
    const info = workerMap.get(worker.id);
    const uptime = info ? Math.round((Date.now() - info.startTime) / 1000) : "?";

    console.error(
      `[Primary] Worker ${worker.id} (PID ${worker.process.pid}, ` +
      `端口 ${info?.port}, 运行 ${uptime}s) 退出 ` +
      `(${signal || code}), 重新启动...`
    );

    // 保留下线 Worker 的端口
    const port = info?.port || PORT_START;

    // 延迟重启 (防止快速循环崩溃)
    setTimeout(() => {
      const newWorker = cluster.fork({
        PORT: String(port),
        WORKER_ID: `restarted-${worker.id}`,
        AGENT_TIMEOUT_S: AGENT_TIMEOUT,
        MAX_LOG_SIZE_MB: MAX_LOG_SIZE,
      });

      workerMap.set(newWorker.id, {
        pid: newWorker.process.pid!,
        port,
        startTime: Date.now(),
      });

      console.log(`  ↳ 新 Worker → PID ${newWorker.process.pid}, 端口 ${port}`);
    }, 2000);
  });

  // ── 优雅关闭 ──
  process.on("SIGTERM", () => {
    console.log("[Primary] 收到 SIGTERM，通知所有 Worker 退出...");
    for (const id of Object.keys(cluster.workers!)) {
      cluster.workers![id]!.kill("SIGTERM");
    }
  });

  process.on("SIGINT", () => {
    console.log("[Primary] 收到 SIGINT...");
    process.exit(0);
  });

} else {
  // ============================================================
  // Worker 进程
  // ============================================================

  // 动态导入 server.ts (ESM 兼容)
  import("./server.js").catch((err) => {
    console.error(`[Worker] 启动失败:`, err);
    process.exit(1);
  });
}

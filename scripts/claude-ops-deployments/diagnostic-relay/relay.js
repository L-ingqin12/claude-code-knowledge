#!/usr/bin/env node
/**
 * Diagnostic Relay — 透明 TCP 中继 (permafrost ↔ proxy)
 * ======================================================
 * 零侵入: 不解析/不修改任何字节, 纯管道转发
 * 目的:   检测 CC cancelRetry() 导致的提前断连
 *
 * 架构:
 *   permafrost :8788 → relay :8789 → proxy :8787 → DeepSeek
 *
 * 证据模式:
 *   [relay] #N CONNECT              ← 新请求到达
 *   [relay] #N CLIENT-CLOSED 95s    ← CC 提前断开! (cancelRetry)
 *   [relay] #N END 150s CLIENT-GONE ← 代理成功但无人接收
 *
 * 部署: bash /root/claude-diagnostic-relay/deploy.sh
 * 逃生: bash /root/claude-diagnostic-relay/rollback.sh
 */

const net = require('net');

const LISTEN_PORT = parseInt(process.env.RELAY_PORT || '8789');
const LISTEN_HOST = process.env.RELAY_HOST || '127.0.0.1';
const UPSTREAM_PORT = parseInt(process.env.RELAY_UPSTREAM_PORT || '8787');
const UPSTREAM_HOST = process.env.RELAY_UPSTREAM_HOST || '127.0.0.1';

let connId = 0;

const server = net.createServer((clientSock) => {
  const id = ++connId;
  const t0 = Date.now();
  let clientClosed = false;
  let upstreamClosed = false;

  console.error(`[relay] #${id} CONNECT ${clientSock.remoteAddress}:${clientSock.remotePort}`);

  // 连接到上游 (proxy)
  const upstreamSock = new net.Socket();
  upstreamSock.connect(UPSTREAM_PORT, UPSTREAM_HOST);

  upstreamSock.on('connect', () => {
    // 双向管道: client → upstream, upstream → client
    clientSock.pipe(upstreamSock);
    upstreamSock.pipe(clientSock);
  });

  // 客户端关闭 (CC 断开)
  clientSock.on('close', () => {
    if (!clientClosed) {
      clientClosed = true;
      clientCloseTime = Date.now();
      const elapsed = ((Date.now() - t0) / 1000).toFixed(1);
      console.error(`[relay] #${id} CLIENT-CLOSED ${elapsed}s`);
    }
  });

  // 上游关闭 (proxy 完成)
  upstreamSock.on('close', () => {
    if (!upstreamClosed) {
      upstreamClosed = true;
      const elapsed = ((Date.now() - t0) / 1000).toFixed(1);
      // 只有当客户端先关闭 且 时间差 > 5s 才是真正的 cancelRetry 证据
      // (≤5s 是正常 TCP 关闭竞态)
      if (clientClosed) {
        const gap = Date.now() - clientCloseTime;
        if (gap > 5000) {
          console.error(`[relay] #${id} END ${elapsed}s [CC-GONE-${(gap/1000).toFixed(0)}s — cancelRetry 证据!]`);
        } else {
          console.error(`[relay] #${id} END ${elapsed}s (正常)`);
        }
      } else {
        console.error(`[relay] #${id} END ${elapsed}s`);
      }
    }
  });

  // 错误处理 (不崩溃, 只记录)
  clientSock.on('error', (err) => {
    console.error(`[relay] #${id} CLIENT-ERROR: ${err.message}`);
  });
  upstreamSock.on('error', (err) => {
    console.error(`[relay] #${id} UPSTREAM-ERROR: ${err.message}`);
  });
});

server.on('error', (err) => {
  console.error(`[relay] SERVER-ERROR: ${err.message}`);
  process.exit(1);
});

// 连接级 keep-alive (与 proxy.js 一致)
server.on('connection', (sock) => sock.setKeepAlive(true, 60000));

// SO_REUSEPORT 支持零中断重启 (与 proxy.js 一致, PRoot 需要)
server.listen({ port: LISTEN_PORT, host: LISTEN_HOST, reusePort: true }, () => {
  console.error(`[relay] Listening ${LISTEN_HOST}:${LISTEN_PORT} → ${UPSTREAM_HOST}:${UPSTREAM_PORT}`);
  console.error(`[relay] 模式: 透明 TCP 中继 (零侵入, 纯管道)`);
});

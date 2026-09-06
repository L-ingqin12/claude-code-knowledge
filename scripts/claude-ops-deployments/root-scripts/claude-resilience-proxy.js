#!/usr/bin/env node
/**
 * Claude API Resilience Proxy (Node.js) — Minimal
 * ===============================================
 * 只做两件事: 透明转发 + socket 错误自动重试
 *
 * ⚠️  DO NOT ADD DIAGNOSTIC CODE HERE
 *     诊断/监控 → diagnostic-relay/relay.js (独立 TCP 中继)
 *     生产控制流 → 仅本文件, 不得混入诊断分支
 *     修改前 → git commit → deploy.sh → 部署后 curl 验证
 */

const http = require('http');
const https = require('https');
const { URL } = require('url');

const PORT = parseInt(process.env.PROXY_PORT || '8787');
const TARGET = process.env.PROXY_TARGET || 'https://api.deepseek.com/anthropic';
const TARGET_URL = new URL(TARGET);
const RETRIES = parseInt(process.env.PROXY_RETRIES || "1");
const BACKOFF = (process.env.PROXY_BACKOFF_MS || "1000").split(",").map(Number);

function doRequest(opts, body, retries) {
  return new Promise((resolve, reject) => {
    const req = https.request({
      hostname: TARGET_URL.hostname,
      port: 443,
      path: TARGET_URL.pathname + opts.path,
      method: opts.method,
      headers: { ...opts.headers, host: TARGET_URL.hostname },
      timeout: parseInt(process.env.PROXY_TIMEOUT_MS || "90000"),
    }, (res) => {
      let data = [];
      res.on('data', c => data.push(c));
      res.on('end', () => resolve({
        status: res.statusCode,
        headers: res.headers,
        body: Buffer.concat(data),
      }));
      res.on('error', reject);
    });

    req.on('error', (err) => {
      const msg = err.message.toLowerCase();
      const retryable = ['socket', 'econnreset', 'etimedout', 'closed',
                          'eof', 'broken pipe', 'read econnreset', 'abort'].some(k => msg.includes(k));
      if (retryable && retries > 0) {
        const delay = BACKOFF[BACKOFF.length - retries] || 8000;
        console.error(`[proxy] Retry in ${delay}ms (${retries} left): ${err.message}`);
        setTimeout(() => doRequest(opts, body, retries - 1).then(resolve).catch(reject), delay);
      } else {
        reject(err);
      }
    });

    req.on('timeout', () => {
      req.destroy();
      if (retries > 0) {
        const delay = BACKOFF[BACKOFF.length - retries] || 8000;
        console.error(`[proxy] Timeout, retry in ${delay}ms (${retries} left)`);
        setTimeout(() => doRequest(opts, body, retries - 1).then(resolve).catch(reject), delay);
      } else {
        reject(new Error('upstream timeout'));
      }
    });

    if (body) req.write(body);
    req.end();
  });
}

const server = http.createServer((clientReq, clientRes) => {
  const start = Date.now();
  let bodyChunks = [];

  clientReq.on('data', c => bodyChunks.push(c));
  clientReq.on('end', async () => {
    const body = Buffer.concat(bodyChunks);

    const fwdHeaders = {};
    for (const [k, v] of Object.entries(clientReq.headers)) {
      if (!['host','connection','keep-alive','transfer-encoding'].includes(k.toLowerCase())) {
        fwdHeaders[k] = v;
      }
    }

    try {
      const result = await doRequest({
        method: clientReq.method,
        path: clientReq.url,
        headers: fwdHeaders,
      }, body, RETRIES);

      const resHeaders = { ...result.headers };
      delete resHeaders['transfer-encoding'];
      delete resHeaders['connection'];
      delete resHeaders['keep-alive'];

      clientRes.writeHead(result.status, resHeaders);
      clientRes.end(result.body);

      console.error(`[proxy] ${clientReq.method} ${clientReq.url} → ${result.status} (${Date.now() - start}ms)`);
    } catch (err) {
      console.error(`[proxy] ${clientReq.method} ${clientReq.url} → 502: ${err.message}`);
      if (!clientRes.headersSent) {
        clientRes.writeHead(502, { 'Content-Type': 'application/json' });
        clientRes.end(JSON.stringify({
          error: { type: 'proxy_error', message: err.message }
        }));
      }
    }
  });

  clientReq.on('error', (err) => {
    console.error(`[proxy] Client error: ${err.message}`);
  });
});

server.on('connection', (sock) => sock.setKeepAlive(true, 60000));
// SO_REUSEPORT enables zero-downtime restart (PRoot requires both flags)
server.listen({ port: PORT, host: '127.0.0.1', reusePort: true }, () => {
  console.error(`[proxy] Listening 127.0.0.1:${PORT} → ${TARGET}`);
  console.error(`[proxy] Retries: ${RETRIES}, backoff: ${BACKOFF.map(b=>b/1000+'s').join('/')}`);
});

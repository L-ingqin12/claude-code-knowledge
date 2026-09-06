#!/usr/bin/env node
/**
 * 通用多源缓存对齐中继（cache-relay）
 *
 * 自动识别来源 provider 类型，选对应的缓存对齐策略，透传转发到上游。
 * 泛化了 permafrost 的 align_request：DeepSeek/GLM 隐式前缀 → 去 cache_control +
 * 工具排序 + currentDate 稳定化；Anthropic 显式断点 → 保留断点只排序/稳定；
 * OpenRouter/通用 → 仅排序 + 确定性 JSON。密钥不落地（透传头）。
 *
 * 用法:
 *   node cache-relay.mjs start        前台启动（:8790）
 *   node cache-relay.mjs daemon       后台（写 pid）
 *   node cache-relay.mjs stop         停（读 pid）
 *   node cache-relay.mjs doctor [baseUrl] [model]   判源自测
 *
 * 环境变量:
 *   RELAY_PORT              监听端口（默认 8790）
 *   RELAY_DEFAULT_UPSTREAM  默认上游 baseUrl（请求头 X-Relay-Upstream 可覆盖）
 *   RELAY_FORCE_PROVIDER    强制策略：passthrough|deepseek|anthropic|glm|openrouter|generic
 *   RELAY_DISABLED=1        软回滚开关（等价 touch ~/.cache-relay/.disabled）
 */
import http from 'node:http'
import https from 'node:https'
import { readFileSync, existsSync, writeFileSync, mkdirSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const RELAY_PORT = Number(process.env.RELAY_PORT ?? 8790)
const DEFAULT_UPSTREAM = process.env.RELAY_DEFAULT_UPSTREAM ?? ''
const FORCE = process.env.RELAY_FORCE_PROVIDER ?? ''
const STATE_DIR = join(homedir(), '.cache-relay')
const PID_FILE = join(STATE_DIR, 'relay.pid')
const DISABLED_FILE = join(STATE_DIR, '.disabled')

// ---------------------------------------------------------------------------
// 判源（detectProvider）
// ---------------------------------------------------------------------------

/** 依据 baseUrl host + model + 协议路径 判 provider。 */
function detectProvider(baseUrl = '', model = '', path = '') {
  if (FORCE) return FORCE // 逃生阀：强制策略优先
  const host = safeHost(baseUrl)
  const bm = (baseUrl + model).toLowerCase()
  if (/anthropic\.com/.test(host) || /\/v1\/messages$/.test(path) || /claude/i.test(model)) return 'anthropic'
  if (/deepseek\.com/.test(host)) return 'deepseek'
  if (/bigmodel\.cn|zhipu/.test(bm)) return 'glm'
  if (/openrouter\.ai/.test(host)) return 'openrouter'
  if (/minimaxi\.com/.test(host)) return 'deepseek' // 隐式前缀，同 DeepSeek 策略
  if (/moonshot\.cn|siliconflow/.test(host)) return 'generic'
  return 'generic'
}

function safeHost(url) {
  try { return new URL(url).host } catch { return url }
}

// ---------------------------------------------------------------------------
// 对齐动作（align）
// ---------------------------------------------------------------------------

function toolName(t) { return t?.function?.name ?? t?.name ?? '' }

/** 工具按 name 排序（OpenAI function.name / Anthropic name 兼容）。 */
function sortTools(body) {
  if (Array.isArray(body?.tools) && body.tools.length > 1) {
    body.tools = [...body.tools].sort((a, b) => toolName(a).localeCompare(toolName(b)))
  }
  return body
}

const DATE_RE = /(Today's date is |Today is |currentDate[: ]*|今天(是)?日期?[:： ]*)\d{4}[-/.]\d{1,2}[-/.]\d{1,2}/g
function fixDate(s) { return s.replace(DATE_RE, (m, p) => `${p}2000-01-01`) }

/** 递归替换 system/messages 里的日期为固定值（跨天不破坏前缀）。 */
function stabilizeDates(body) {
  const fix = (v) => typeof v === 'string' ? fixDate(v) : v
  if (typeof body?.system === 'string') body.system = fixDate(body.system)
  else if (Array.isArray(body?.system)) body.system = body.system.map(b => (b?.type === 'text' ? { ...b, text: fixDate(b.text) } : b))
  if (Array.isArray(body?.messages)) {
    body.messages = body.messages.map(m => {
      if (typeof m?.content === 'string') return { ...m, content: fixDate(m.content) }
      if (Array.isArray(m?.content)) return { ...m, content: m.content.map(p => (p?.type === 'text' ? { ...p, text: fixDate(p.text) } : p)) }
      return m
    })
  }
  return body
}

/** 递归剥离 cache_control（DeepSeek/GLM 不识别，位置漂移破坏隐式前缀）。 */
function stripCacheControl(node) {
  if (Array.isArray(node)) { node.forEach(stripCacheControl); return node }
  if (node && typeof node === 'object') {
    for (const k of Object.keys(node)) {
      if (k === 'cache_control') delete node[k]
      else stripCacheControl(node[k])
    }
  }
  return node
}

/** 按 provider 分派对齐。passthrough = 零改动透传（逃生）。 */
function alignRequest(body, provider) {
  switch (provider) {
    case 'deepseek':
    case 'glm':
      stripCacheControl(body)
      sortTools(body)
      stabilizeDates(body)
      break
    case 'anthropic':
      sortTools(body)          // 保留 cache_control 断点，只排序 + 稳定
      stabilizeDates(body)
      break
    case 'openrouter':
    case 'generic':
    default:
      sortTools(body)          // 最小干预：仅确定性排序
  }
  return body
}

// ---------------------------------------------------------------------------
// 转发（透传头，不落地密钥）
// ---------------------------------------------------------------------------

const DROP_HEADERS = new Set(['host', 'content-length', 'connection', 'transfer-encoding'])

function forward(req, body, upstream, path) {
  return new Promise((resolve) => {
    const target = new URL(upstream + path)
    const lib = target.protocol === 'https:' ? https : http
    const headers = {}
    for (const [k, v] of Object.entries(req.headers)) {
      if (!DROP_HEADERS.has(k.toLowerCase())) headers[k] = v
    }
    headers['host'] = target.host
    headers['content-length'] = Buffer.byteLength(body)
    const out = lib.request({
      host: target.hostname, port: target.port || (target.protocol === 'https:' ? 443 : 80),
      path: target.pathname + target.search, method: req.method, headers,
    }, (upRes) => {
      resolve({ status: upRes.statusCode, headers: upRes.headers, stream: upRes })
    })
    out.on('error', () => resolve({ status: 502, headers: {}, stream: null }))
    out.end(body)
  })
}

// ---------------------------------------------------------------------------
// 中继服务器
// ---------------------------------------------------------------------------

function serve() {
  const server = http.createServer(async (req, res) => {
    let chunks = []
    for await (const c of req) chunks.push(c)
    let body = Buffer.concat(chunks).toString('utf8')

    const upstream = String(req.headers['x-relay-upstream'] ?? DEFAULT_UPSTREAM ?? '')
    const path = new URL(req.url, 'http://x').pathname + (new URL(req.url, 'http://x').search || '')
    if (!upstream) { res.writeHead(502, { 'content-type': 'application/json' }); res.end(JSON.stringify({ error: 'no upstream: set RELAY_DEFAULT_UPSTREAM or X-Relay-Upstream' })); return }

    const provider = detectProvider(upstream, '', path)
    try {
      const parsed = JSON.parse(body)
      alignRequest(parsed, provider)
      body = JSON.stringify(parsed)
    } catch { /* 非 JSON 透传 */ }

    const fwd = await forward(req, body, upstream, path)
    if (!fwd.stream) { res.writeHead(fwd.status); res.end(); return }
    res.writeHead(fwd.status, fwd.headers)
    fwd.stream.pipe(res)
  })
  server.listen(RELAY_PORT, '127.0.0.1', () => console.log(`[cache-relay] ${providerBanner()} listening on 127.0.0.1:${RELAY_PORT}`))
  return server
}

function providerBanner() {
  return FORCE ? `FORCED=${FORCE}` : 'auto-detect'
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

const cmd = process.argv[2] ?? 'start'
const disabled = process.env.RELAY_DISABLED === '1' || existsSync(DISABLED_FILE)

switch (cmd) {
  case 'doctor': {
    const baseUrl = process.argv[3] ?? ''
    const model = process.argv[4] ?? ''
    const p = detectProvider(baseUrl, model, baseUrl.includes('/v1/messages') ? '/v1/messages' : '')
    const sample = { tools: [{ function: { name: 'bash' } }, { function: { name: 'read' } }], messages: [{ role: 'system', content: "Today's date is 2026-09-06" }], cache_control: { type: 'ephemeral' } }
    alignRequest(sample, p)
    console.log(`baseUrl="${baseUrl || '(empty)'}" model="${model}"`)
    console.log(`→ provider = ${p}`)
    console.log(`→ tools sorted = ${sample.tools.map(t => t.function.name).join(',')}`)
    console.log(`→ date stabilized = ${JSON.stringify(sample.messages[0].content)}`)
    console.log(`→ cache_control stripped = ${sample.cache_control === undefined}`)
    break
  }
  case 'stop': {
    if (existsSync(PID_FILE)) {
      const pid = readFileSync(PID_FILE, 'utf8').trim()
      try { process.kill(Number(pid)); console.log(`已停止 cache-relay (PID ${pid})`) } catch { console.log('cache-relay 未运行（pid 过期）') }
      try { require('node:fs').unlinkSync(PID_FILE) } catch {}
    } else console.log('无 pid 文件（未启动）')
    break
  }
  case 'daemon': {
    if (disabled) { console.log('⛔ 软回滚开关已启用（RELAY_DISABLED=1 或 .disabled），静默退出'); process.exit(0) }
    mkdirSync(STATE_DIR, { recursive: true })
    const { spawn } = await import('node:child_process')
    const child = spawn(process.execPath, [process.argv[1], 'start'], { detached: true, stdio: 'ignore' })
    child.unref()
    writeFileSync(PID_FILE, String(child.pid))
    console.log(`cache-relay 守护已启动 (PID ${child.pid}) · 停止 node cache-relay.mjs stop`)
    break
  }
  case 'start':
  default: {
    if (disabled) { console.log('⛔ 软回滚开关已启用（RELAY_DISABLED=1 或 ~/.cache-relay/.disabled），静默退出'); process.exit(0) }
    serve()
    break
  }
}

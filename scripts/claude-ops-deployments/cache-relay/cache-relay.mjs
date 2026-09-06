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
import { readFileSync, existsSync, writeFileSync, mkdirSync, unlinkSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { createHash } from 'node:crypto'

const RELAY_PORT = Number(process.env.RELAY_PORT ?? 8790)
const DEFAULT_UPSTREAM = process.env.RELAY_DEFAULT_UPSTREAM ?? ''
const FORCE = process.env.RELAY_FORCE_PROVIDER ?? ''
const STATE_DIR = process.env.RELAY_STATE_DIR || join(homedir(), '.cache-relay')
const PID_FILE = join(STATE_DIR, 'relay.pid')
const DISABLED_FILE = join(STATE_DIR, '.disabled')
const CONFIG_FILE = join(STATE_DIR, 'config.json')

/** 热配置：~/.cache-relay/config.json（可热改，重启中继生效；只存上游/策略，不落地密钥）。 */
function readConfig() {
  try { return JSON.parse(readFileSync(CONFIG_FILE, 'utf8')) } catch { return {} }
}

// ---------------------------------------------------------------------------
// 判源（detectProvider）
// ---------------------------------------------------------------------------

/** 依据 baseUrl host + model + 协议路径 判 provider。 */
function detectProvider(baseUrl = '', model = '', path = '') {
  const force = readConfig().forceProvider ?? FORCE
  if (force) return force // 逃生阀：强制策略优先
  const host = safeHost(baseUrl)
  const bm = (baseUrl + model).toLowerCase()
  // host 优先：deepseek.com 即使走 Anthropic 协议(/v1/messages)也是隐式前缀，必须按 deepseek 处理
  // （否则会把「剥离 cache_control」错判成「保留」——DeepSeek 不识别 cache_control，位置漂移打穿前缀）
  if (/deepseek\.com/.test(host)) return 'deepseek'
  if (/bigmodel\.cn|zhipu/.test(bm)) return 'glm'
  if (/minimaxi\.com/.test(host)) return 'deepseek' // 隐式前缀，同 DeepSeek 策略
  if (/openrouter\.ai/.test(host)) return 'openrouter'
  if (/moonshot\.cn|siliconflow/.test(host)) return 'generic'
  // 协议/模型兜底（放最后）：显式 Anthropic 端点，或 /v1/messages 且无已知 host
  if (/anthropic\.com/.test(host) || /\/v1\/messages$/.test(path) || /claude/i.test(model)) return 'anthropic'
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

// ---------------------------------------------------------------------------
// permafrost aggressive 移植：billing nonce 钉桩 / 工具集归一 / env 块搬迁
// ---------------------------------------------------------------------------

const ANCHOR_TOOLS = new Set(['Agent', 'AskUserQuestion', 'Bash', 'Edit', 'Read', 'Skill', 'ToolSearch', 'Workflow', 'Write', 'WebSearch', 'WebFetch'])
const ENV_MARKERS = ['<env>', 'Working directory', 'Is directory a git repo', "Today's date", 'Current branch', 'Recent commits', 'gitStatus', 'Platform:', 'OS Version']
const VOLATILE_RES = [
  /\b\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2})?/,
  /\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b/,
  /\b[0-9a-fA-F]{32,64}\b/,
  /\b[0-9a-f]{7,40}\b/,
]
const looksLikeEnv = (text) => ENV_MARKERS.some((m) => text.includes(m))
const countVolatile = (text) => VOLATILE_RES.reduce((n, re) => n + (re.test(text) ? 1 : 0), 0)

/** 钉桩每请求 billing nonce（cch=xxx → cch=permafrost），防止前缀头部逐请求漂移。 */
function stabilizeMetadata(body) {
  const system = body?.system
  if (!Array.isArray(system)) return
  for (const b of system) {
    if (b && typeof b.text === 'string' && b.text.includes('x-anthropic-billing-header')) {
      b.text = b.text.replace(/(cch=)[^;\s]*/g, '$1permafrost')
    }
  }
}

/** 归一工具集：锚点工具保留 + 描述钉桩 + 按需保留非锚点（子代理无锚点则整体不动）。
 *  可配置：config.anchorTools 全量覆盖锚点集；config.keepToolPrefixes 前缀命中的工具一律保留（如 "mcp__"）。 */
function normalizeTools(body) {
  const tools = body?.tools
  if (!Array.isArray(tools) || tools.length < 2) return
  const cfg = readConfig()
  const anchorSet = Array.isArray(cfg.anchorTools) ? new Set(cfg.anchorTools) : ANCHOR_TOOLS
  const prefixes = Array.isArray(cfg.keepToolPrefixes) ? cfg.keepToolPrefixes : []
  for (const t of tools) {
    if (t && typeof t.description === 'string' && t.description.length > 10) t.description = 'See tool schema.'
  }
  if (!tools.some((t) => t && anchorSet.has(t.name))) return // 子代理（缩减工具集）不动
  const last = body?.messages?.[body.messages.length - 1]
  const text = (typeof last?.content === 'string' ? last.content
    : Array.isArray(last?.content) ? last.content.map((c) => c?.text ?? '').join(' ') : '').toLowerCase()
  const wanted = new Set()
  const KW = { search: 'WebSearch', 搜索: 'WebSearch', fetch: 'WebFetch', 抓取: 'WebFetch', grep: 'Grep', monitor: 'Monitor', 监控: 'Monitor' }
  for (const [kw, tool] of Object.entries(KW)) if (text.includes(kw)) wanted.add(tool)
  const kept = tools.filter((t) => {
    const name = t?.name ?? ''
    if (anchorSet.has(name)) return true
    if (prefixes.some((p) => name.startsWith(p))) return true
    return wanted.has(name)
  })
  body.tools = kept.sort((a, b) => (a.name ?? '').localeCompare(b.name ?? ''))
}

/** 把 system 里含易变内容（日期/uuid/hash/SHA）的 env 块搬迁到末尾消息（内容保留，只移出前缀）。 */
function relocateVolatile(body) {
  const system = body?.system
  if (!Array.isArray(system)) return
  const keep = []
  const moved = []
  for (const b of system) {
    const text = b && typeof b.text === 'string' ? b.text : ''
    if (countVolatile(text) > 0 && looksLikeEnv(text)) moved.push(b)
    else keep.push(b)
  }
  if (moved.length === 0) return
  body.system = keep
  const msgs = body?.messages
  if (!Array.isArray(msgs) || msgs.length === 0) { body.system = [...keep, ...moved]; return }
  const last = msgs[msgs.length - 1]
  const blocks = typeof last.content === 'string' ? [{ type: 'text', text: last.content }]
    : Array.isArray(last.content) ? last.content : []
  last.content = [...blocks,
    { type: 'text', text: '<relay:relocated-context>\nMoved out of the cache prefix so it can change without resetting the cache.\n</relay:relocated-context>' },
    ...moved,
  ]
  msgs[msgs.length - 1] = last
}

/** 按 provider 分派对齐。passthrough = 零改动透传（逃生）。 */
function alignRequest(body, provider) {
  switch (provider) {
    case 'deepseek':
    case 'glm':
      stripCacheControl(body)
      stabilizeMetadata(body)
      stabilizeDates(body)
      sortTools(body)
      // normalizeTools 默认关：会剥掉 MCP 等非锚点工具（行为级变化），需 config.json 显式 normalizeTools=true 开启
      if (readConfig().normalizeTools === true) normalizeTools(body)
      relocateVolatile(body)
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
// P5 冷启动合并（coalescer）：并发同锚点请求，首请求领跑，跟随者等首字节+settle 后转发，
// 读 DeepSeek 刚写入的热缓存（异步写 ~6-60s）。仅对同锚点并发有用；不同锚点互不影响。
// config.coalesce=true 开启（默认关，零额外状态除非开启）。
// ---------------------------------------------------------------------------

const COALESCE_SETTLE_MS = Number(process.env.RELAY_COALESCE_SETTLE ?? 2500)
const inFlight = new Map() // fingerprint -> { ready: Promise, resolve: () => void, count: number }

/** 锚点指纹 = tools + system（对齐后）的 sha256，标识「同一可缓存前缀」。 */
function anchorFingerprint(body) {
  const anchor = JSON.stringify({ tools: body?.tools, system: body?.system })
  return createHash('sha256').update(anchor).digest('hex')
}

/** 领跑/跟随：首请求直接转发，同锚点后续请求等首字节+settle 后转发（读热缓存）。 */
function coalesceForward(fingerprint, forwardFn) {
  const existing = inFlight.get(fingerprint)
  if (existing) {
    existing.count++
    return existing.ready.then(() => forwardFn())
  }
  let resolve
  const ready = new Promise((r) => { resolve = r })
  const entry = { ready, resolve, count: 1 }
  inFlight.set(fingerprint, entry)
  return forwardFn().then((result) => {
    let settled = false
    const settle = () => {
      if (settled) return
      settled = true
      if (inFlight.get(fingerprint) === entry) inFlight.delete(fingerprint)
      resolve()
    }
    if (result.stream) {
      // 首字节后等 settle（给 DeepSeek 异步写缓存留时间）；error 立即释放
      result.stream.once('data', () => setTimeout(settle, COALESCE_SETTLE_MS))
      result.stream.once('error', settle)
      // 兜底：上游空响应/无 data 时强制释放，避免 follower 死等
      setTimeout(settle, COALESCE_SETTLE_MS + 5000).unref?.()
    } else {
      settle()
    }
    return result
  })
}

// ---------------------------------------------------------------------------
// 转发（透传头，不落地密钥）
// ---------------------------------------------------------------------------

const DROP_HEADERS = new Set(['host', 'content-length', 'connection', 'transfer-encoding'])

function forward(req, body, upstream, path, overrideHeaders = {}) {
  return new Promise((resolve) => {
    const target = new URL(upstream + path)
    const lib = target.protocol === 'https:' ? https : http
    const headers = {}
    for (const [k, v] of Object.entries(req.headers)) {
      if (!DROP_HEADERS.has(k.toLowerCase())) headers[k] = v
    }
    for (const [k, v] of Object.entries(overrideHeaders)) headers[k.toLowerCase()] = v
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

/** 收集小体积错误响应体（仅 400 类 JSON 错误，避免打断正常 SSE 流）。 */
function readBody(stream) {
  return new Promise((resolve) => {
    const chunks = []
    stream.on('data', (c) => chunks.push(c))
    stream.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
    stream.on('error', () => resolve(''))
  })
}

/** 内容审核 400 兜底配置（本地 ~/.cache-relay/config.json，不落地到仓库）。
 *  authToken 优先取 config；否则按 authTokenSource 指向的文件读 env.ANTHROPIC_AUTH_TOKEN。 */
function fallbackConfig() {
  const f = readConfig().fallback
  if (!f || !f.upstream) return null
  if (f.authToken) return f
  const src = f.authTokenSource
  if (src) {
    try {
      const p = src.replace(/^~/, homedir())
      const d = JSON.parse(readFileSync(p, 'utf8'))
      const tok = d?.env?.ANTHROPIC_AUTH_TOKEN
      if (tok) return { ...f, authToken: tok }
    } catch { /* 读取失败则禁用兜底 */ }
  }
  return null
}

/** 判定错误体是否为内容审核 400（Content Exists Risk）。 */
function isRisk400(errBody, keywords) {
  const keys = keywords && keywords.length ? keywords : ['content exists risk', '内容存在风险']
  const b = String(errBody).toLowerCase()
  return keys.some((k) => b.includes(String(k).toLowerCase()))
}

// ---------------------------------------------------------------------------
// 中继服务器
// ---------------------------------------------------------------------------

function serve() {
  const server = http.createServer(async (req, res) => {
    // 热软回滚：每请求检查 .disabled/RELAY_DISABLED，undeploy 后立即生效（无需重启）
    if (process.env.RELAY_DISABLED === '1' || existsSync(DISABLED_FILE)) {
      res.writeHead(503, { 'content-type': 'application/json' })
      res.end(JSON.stringify({ error: 'relay disabled (soft rollback)' }))
      return
    }
    let chunks = []
    for await (const c of req) chunks.push(c)
    let body = Buffer.concat(chunks).toString('utf8')

    const cfg = readConfig()
    // 优先级：请求头 > env(RELAY_DEFAULT_UPSTREAM) > config.json(defaultUpstream)
    const upstream = String(req.headers['x-relay-upstream'] || DEFAULT_UPSTREAM || cfg.defaultUpstream || '')
    const path = new URL(req.url, 'http://x').pathname + (new URL(req.url, 'http://x').search || '')
    if (!upstream) { res.writeHead(502, { 'content-type': 'application/json' }); res.end(JSON.stringify({ error: 'no upstream: set RELAY_DEFAULT_UPSTREAM or X-Relay-Upstream' })); return }

    const provider = detectProvider(upstream, '', path)
    let parsed = null
    try {
      parsed = JSON.parse(body)
      alignRequest(parsed, provider)
      body = JSON.stringify(parsed)
    } catch { /* 非 JSON 透传 */ }

    const fallback = fallbackConfig()
    // P5 coalescer：同锚点并发合并（config.coalesce=true 开启，默认关）
    const fp = cfg.coalesce === true && parsed ? anchorFingerprint(parsed) : null
    const fwd = fp
      ? await coalesceForward(fp, () => forward(req, body, upstream, path))
      : await forward(req, body, upstream, path)
    // 内容审核 400 → 改投备用上游（OpenRouter GLM），不阻断会话
    if (fwd.status === 400 && fallback && fwd.stream) {
      const errBody = await readBody(fwd.stream)
      if (isRisk400(errBody, fallback.riskKeywords)) {
        let fbBody = body
        try {
          const p = JSON.parse(body)
          const map = fallback.modelMap || {}
          p.model = map[p.model] || map['*'] || p.model
          fbBody = JSON.stringify(p)
        } catch { /* 非 JSON 原样转发 */ }
        const fb = await forward(req, fbBody, fallback.upstream, path, { authorization: 'Bearer ' + fallback.authToken })
        console.log(`[cache-relay] 400 risk → fallback ${fallback.upstream} status=${fb.status}`)
        if (fb.stream) { res.writeHead(fb.status, fb.headers); fb.stream.pipe(res); return }
        // 兜底也失败：回传原始 400（信息最准）
        res.writeHead(fwd.status, fwd.headers)
        res.end(errBody)
        return
      }
      // 非内容审核 400：原样回传
      res.writeHead(fwd.status, fwd.headers)
      res.end(errBody)
      return
    }
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
      try { unlinkSync(PID_FILE) } catch {}
    } else console.log('无 pid 文件（未启动）')
    break
  }
  case 'deploy': {
    // 热部署：清 .disabled 标记 + 启动守护（不重启 Claude Code）
    mkdirSync(STATE_DIR, { recursive: true })
    try { unlinkSync(DISABLED_FILE) } catch {}
    const { spawn } = await import('node:child_process')
    const child = spawn(process.execPath, [process.argv[1], 'daemon'], { detached: true, stdio: 'ignore' })
    child.unref()
    console.log(`cache-relay 已热部署（监听 :${RELAY_PORT}）· 停止 node cache-relay.mjs stop`)
    break
  }
  case 'undeploy': {
    // 软回滚：写 .disabled 标记 + 停守护（不删文件，随时 re-deploy）
    mkdirSync(STATE_DIR, { recursive: true })
    writeFileSync(DISABLED_FILE, '')
    if (existsSync(PID_FILE)) {
      try { process.kill(Number(readFileSync(PID_FILE, 'utf8').trim())) } catch {}
    }
    console.log('cache-relay 已软回滚（.disabled 已写，守护已停）· 恢复 node cache-relay.mjs deploy')
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

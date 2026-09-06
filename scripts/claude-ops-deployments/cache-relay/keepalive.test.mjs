/**
 * cache-relay keepalive 保温器 — 隔离测试（不触碰运行中 8790 实例 / 真实 config.json）
 *
 * 每个场景：独立临时 RELAY_STATE_DIR（config.json 现场写）+ 独立 mock 上游 + 独立端口
 * 子进程方式启动 relay（node cache-relay.mjs start），模拟真实主会话请求。
 *
 *   a) keepalive 默认关（config {}）→ 无重放（mock 只收到 1 个真实请求）
 *   b) keepalive enabled + 超过 idleMs → 重放（mock 收到 max_tokens:1、同 model/messages/path/auth）
 *   c) 重放不干扰正常请求；新真实请求会重置空闲计时（idle 内不再重放）
 *
 * 用法: node keepalive.test.mjs   （退出码 0=全过，非 0=有 FAIL）
 */
import http from 'node:http'
import net from 'node:net'
import { spawn } from 'node:child_process'
import { mkdirSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const RELAY_SRC = fileURLToPath(new URL('./cache-relay.mjs', import.meta.url))
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
let failures = 0
const check = (name, ok, extra = '') => {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}${extra ? '  | ' + extra : ''}`)
  if (!ok) failures++
}

// ---- helpers -------------------------------------------------------------

function freePort() {
  return new Promise((resolve) => {
    const s = net.createServer()
    s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => resolve(p)) })
  })
}

/** mock 上游：记录每个请求（method/url/headers/body），回 200 JSON。 */
function startMock() {
  const requests = []
  const server = http.createServer((req, res) => {
    const c = []
    req.on('data', (d) => c.push(d))
    req.on('end', () => {
      requests.push({ method: req.method, url: req.url, headers: req.headers, body: Buffer.concat(c).toString('utf8') })
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end(JSON.stringify({ ok: true }))
    })
  })
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      resolve({ requests, url: `http://127.0.0.1:${server.address().port}`, close: () => new Promise((r) => server.close(r)) })
    })
  })
}

function spawnRelay(stateDir, port, upstream) {
  const child = spawn(process.execPath, [RELAY_SRC, 'start'], {
    env: { ...process.env, RELAY_PORT: String(port), RELAY_STATE_DIR: stateDir, RELAY_DEFAULT_UPSTREAM: upstream },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  let log = ''
  child.stdout.on('data', (d) => { log += d })
  child.stderr.on('data', (d) => { log += d })
  return { child, getLog: () => log }
}

/** 主会话体：非分类器（无 tools 且 system 无 security monitor/autonomous）。 */
const mainBody = () => ({
  model: 'deepseek-chat',
  max_tokens: 64,
  stream: false,
  system: [{ type: 'text', text: 'You are a helpful assistant.' }],
  messages: [{ role: 'user', content: 'hello keepalive probe' }],
})

async function postRetry(relayPort, path, bodyObj, { retries = 40 } = {}) {
  let lastErr
  for (let i = 0; i < retries; i++) {
    try {
      const resp = await fetch(`http://127.0.0.1:${relayPort}${path}`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', authorization: '[已脱敏] keepalive-test' },
        body: JSON.stringify(bodyObj),
      })
      return { status: resp.status, text: await resp.text() }
    } catch (e) { lastErr = e; await sleep(100) }
  }
  throw lastErr
}

async function waitUntil(cond, timeoutMs, step = 100) {
  const t0 = Date.now()
  while (Date.now() - t0 < timeoutMs) {
    if (cond()) return true
    await sleep(step)
  }
  return cond()
}

/** 造一个临时 state dir + config，返回绝对路径。 */
function makeStateDir(config) {
  const dir = join(tmpdir(), `relay-keepalive-${Date.now()}-${Math.floor(Math.random() * 1e6)}`)
  mkdirSync(dir, { recursive: true })
  writeFileSync(join(dir, 'config.json'), JSON.stringify(config))
  return dir
}

async function shutdown(child, mock, dir) {
  try { child.kill() } catch {}
  await sleep(300)
  try { await mock.close() } catch {}
  try { rmSync(dir, { recursive: true, force: true }) } catch {}
}

async function boot(config) {
  const dir = makeStateDir(config)
  const mock = await startMock()
  const relayPort = await freePort()
  const { child, getLog } = spawnRelay(dir, relayPort, mock.url)
  return { dir, mock, relayPort, child, getLog }
}

// ---- scenario (a): keepalive 默认关 → 无重放 ---------------------------------

async function scenarioDefaultOff() {
  console.log('\n=== (a) keepalive 默认关 → 无重放 ===')
  const { dir, mock, relayPort, child } = await boot({}) // config 无 keepalive 键
  try {
    const a = await postRetry(relayPort, '/v1/messages', mainBody())
    check('(a) 真实请求 200', a.status === 200, `status=${a.status}`)
    await sleep(1500) // 若误开定时器(400ms级)此窗口足够触发
    check('(a) 无重放：mock 仅收 1 个真实请求', mock.requests.length === 1, `count=${mock.requests.length}`)
  } finally { await shutdown(child, mock, dir) }
}

// ---- scenario (b): enabled + 空闲超过 idleMs → 重放 max_tokens:1 ------------

async function scenarioReplayOnIdle() {
  console.log('\n=== (b) enabled + 空闲超 idleMs → 重放 max_tokens:1 ===')
  const { dir, mock, relayPort, child, getLog } = await boot({ keepalive: { enabled: true, idleMs: 400 } })
  try {
    const a = await postRetry(relayPort, '/v1/messages', mainBody())
    check('(b) 真实请求 200', a.status === 200, `status=${a.status}`)
    check('(b) 启动日志出现 keepalive enabled', /keepalive enabled/.test(getLog()), getLog().slice(0, 120))
    const replayed = await waitUntil(() => mock.requests.length >= 2, 4000)
    check('(b) 空闲后收到重放', replayed, `count=${mock.requests.length}`)

    if (mock.requests.length >= 2) {
      const real = JSON.parse(mock.requests[0].body)
      const replay = JSON.parse(mock.requests[1].body)
      const sameMsgs = JSON.stringify(real.messages) === JSON.stringify(replay.messages)
      check('(b) 重放 max_tokens=1（真实为 64）', replay.max_tokens === 1 && real.max_tokens === 64, `real=${real.max_tokens} replay=${replay.max_tokens}`)
      check('(b) 重放同 model', replay.model === real.model, `${replay.model}`)
      check('(b) 重放同 messages', sameMsgs)
      check('(b) 重放同 path /v1/messages', mock.requests[1].url === '/v1/messages', mock.requests[1].url)
      check('(b) 重放带同鉴权头', mock.requests[1].headers.authorization === 'Bearer keepalive-test', mock.requests[1].headers.authorization)
    }
  } finally { await shutdown(child, mock, dir) }
}

// ---- scenario (c): 重放不干扰正常请求；新真实请求重置空闲 -------------------

async function scenarioNoInterference() {
  console.log('\n=== (c) 重放不干扰正常请求 / 新请求重置空闲 ===')
  const { dir, mock, relayPort, child } = await boot({ keepalive: { enabled: true, idleMs: 400 } })
  try {
    const a = await postRetry(relayPort, '/v1/messages', mainBody())
    check('(c) 真实请求 A 200', a.status === 200)
    const r1 = await waitUntil(() => mock.requests.length >= 2, 4000)
    check('(c) A 后出现首次重放', r1, `count=${mock.requests.length}`)

    const t0 = Date.now()
    const b = await postRetry(relayPort, '/v1/messages', mainBody())
    const elapsed = Date.now() - t0
    check('(c) 重放期间真实请求 B 正常 200', b.status === 200, `status=${b.status}`)
    check('(c) B 响应及时（<1500ms）', elapsed < 1500, `${elapsed}ms`)
    check('(c) B 到达后 mock 计数 +1', mock.requests.length === 3, `count=${mock.requests.length}`)

    await sleep(300) // < idleMs(400)：B 已刷新 lastMain.t
    check('(c) idle 内不重放（B 重置了空闲计时）', mock.requests.length === 3, `count=${mock.requests.length}`)

    const r2 = await waitUntil(() => mock.requests.length >= 4, 2000)
    check('(c) B 再次空闲后周期保温（每 idleMs 一次，非连发）', r2, `count=${mock.requests.length}`)
  } finally { await shutdown(child, mock, dir) }
}

// ---- run ----------------------------------------------------------------

await scenarioDefaultOff()
await scenarioReplayOnIdle()
await scenarioNoInterference()

console.log(failures === 0 ? '\nALL PASS' : `\n${failures} FAILED`)
process.exit(failures === 0 ? 0 : 1)

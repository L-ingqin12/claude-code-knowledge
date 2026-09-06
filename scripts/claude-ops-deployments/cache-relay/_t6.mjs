import http from 'node:http'
import { spawn } from 'node:child_process'
import { mkdirSync, writeFileSync, rmSync } from 'node:fs'

const RELAY_PATH = new URL('./cache-relay.mjs', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')
const TMP = process.env.TEMP + '/relay-cls-' + Date.now()
mkdirSync(TMP, { recursive: true })
// main=3400(DeepSeek), classifier/flash=3401(GLM)
writeFileSync(TMP + '/config.json', JSON.stringify({
  defaultUpstream: 'http://127.0.0.1:3400',
  fallback: { upstream: 'http://127.0.0.1:3401', authToken: '[已脱敏]', modelMap: { '*': 'z-ai/glm-5.3-flash' } },
  classifier: { enabled: true },
}))

const hits = { main: 0, cls: 0, clsBody: null, mainBody: null }
const makeMock = (port, tag) => http.createServer((req, res) => {
  const c = []
  req.on('data', d => c.push(d))
  req.on('end', () => {
    hits[tag]++
    const body = Buffer.concat(c).toString('utf8')
    if (tag === 'cls') hits.clsBody = body
    else hits.mainBody = body
    const fail = (req.url || '').includes('fail') && tag === 'cls'  // 模拟分类器上游 500
    res.writeHead(fail ? 500 : 200, { 'content-type': 'application/json' })
    res.end('{"ok":true}')
  })
})
await new Promise(r => makeMock(3400, 'main').listen(3400, r))
await new Promise(r => makeMock(3401, 'cls').listen(3401, r))

const relay = spawn(process.execPath, [RELAY_PATH, 'start'], {
  env: { ...process.env, RELAY_PORT: '8896', RELAY_STATE_DIR: TMP, RELAY_FORCE_PROVIDER: 'deepseek' },
  stdio: 'ignore',
})
await new Promise(r => setTimeout(r, 900))

const post = (path, body) => fetch('http://127.0.0.1:8896' + path, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) })

// 1. 分类器请求（0 tools + security monitor + autonomous）→ 应投 3401(flash)
await post('/v1/messages', {
  model: 'deepseek-v4-pro', tools: [],
  system: [{ type: 'text', text: 'You are a security monitor for autonomous AI coding agents.' }],
  messages: [{ role: 'user', content: 'classify this' }],
})
await new Promise(r => setTimeout(r, 200))
console.log('1) 分类器请求 → classifier mock 命中 =', hits.cls, '(应=1)', '| 投去的 model =', hits.clsBody ? JSON.parse(hits.clsBody).model : 'n/a')

// 2. 正常请求（有 tools）→ 应投 3400(main)
await post('/v1/messages', {
  model: 'deepseek-v4-pro', tools: [{ name: 'Bash' }, { name: 'Read' }],
  system: [{ type: 'text', text: 'You are Claude Code.' }],
  messages: [{ role: 'user', content: 'hello' }],
})
await new Promise(r => setTimeout(r, 200))
console.log('2) 正常请求 → main mock 命中 =', hits.main, '(应=1)')

// 3. 软降级：分类器上游 500 → 应回落到 3400(main)
await post('/v1/messages?fail=1', {
  model: 'deepseek-v4-pro', tools: [],
  system: [{ type: 'text', text: 'You are a security monitor for autonomous AI coding agents.' }],
  messages: [{ role: 'user', content: 'classify this' }],
})
await new Promise(r => setTimeout(r, 200))
console.log('3) 软降级后 → main mock 命中 =', hits.main, '(应=2，因分类器500回落到main)')

relay.kill(); process.exit(0)

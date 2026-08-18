// fix_cdp_activate.js — drive the offline activation from the (hidden) license.html renderer
// via inspector 9229 (opened by the hook). Mirrors the front-end path: the real UI strips
// the leading "+" / trailing "#", then calls window.Setting.invokeWithCallback("offlineActivation", code).
// Usage: node fix_cdp_activate.js [code]   (default code = "AAAA", i.e. user typed "+AAAAA#")
const http = require('http');
const CODE = process.argv[2] || 'AAAA';

function getList() {
  return new Promise((res, rej) => {
    http.get('http://[IP已脱敏]:9229/json/list', r => {
      let b = '';
      r.on('data', d => b += d);
      r.on('end', () => res(JSON.parse(b)));
    }).on('error', rej);
  });
}

(async () => {
  const list = await getList();
  const main = list.find(t => t.type === 'node') || list[0];
  if (!main) { console.log('no inspector target — is Typora running?'); process.exit(1); }
  const ws = new WebSocket(main.webSocketDebuggerUrl);
  let id = 0; const pending = {};
  const send = (method, params = {}) => new Promise(res => {
    const mid = ++id; pending[mid] = res;
    ws.send(JSON.stringify({ id: mid, method, params }));
  });
  ws.onmessage = ev => {
    const m = JSON.parse(ev.data);
    if (m.id && pending[m.id]) { pending[m.id](m); delete pending[m.id]; }
  };
  ws.onerror = e => console.log('[ws err]', e.message || e);

  ws.onopen = async () => {
    await send('Runtime.enable');
    await send('Runtime.runIfWaitingForDebugger');
    const ATTACH = `(function(){
      const _el = process.getBuiltinModule('module')._load('electron');
      const {BrowserWindow} = _el;
      const wins = BrowserWindow.getAllWindows();
      let w = null;
      for (const x of wins) {
        const u = ((x.webContents && x.webContents.getURL()) || '').toLowerCase();
        if (u.indexOf('license.html') >= 0) { w = x; break; }
      }
      if (!w) return 'NO_LICENSE_WINDOW; windows: ' + wins.map(x => (x.webContents && x.webContents.getURL()) || '?').join(' | ');
      w.webContents.debugger.attach('1.3');
      return 'attached: ' + w.webContents.getURL();
    })()`;
    const att = await send('Runtime.evaluate', { expression: ATTACH, returnByValue: true });
    console.log('[attach]', (att.result && att.result.result && att.result.result.value) || JSON.stringify(att).slice(0, 300));

    const CMD = `(async function(){
      const _el = process.getBuiltinModule('module')._load('electron');
      const {BrowserWindow} = _el;
      const wins = BrowserWindow.getAllWindows();
      let w = null;
      for (const x of wins) {
        const u = ((x.webContents && x.webContents.getURL()) || '').toLowerCase();
        if (u.indexOf('license.html') >= 0) { w = x; break; }
      }
      if (!w) return 'NO_LICENSE_WINDOW';
      const d = w.webContents.debugger;
      if (!d) return 'NO_DEBUGGER';
      const E = async (expr) => {
        const r = await d.sendCommand('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
        const v = r && r.result;
        if (v && v.exceptionDetails) return 'EXC ' + ((v.exceptionDetails.exception && v.exceptionDetails.exception.description) || v.exceptionDetails.text).slice(0, 200);
        if (v && v.result && v.result.value !== undefined) return String(v.result.value).slice(0, 600);
        return JSON.stringify(r).slice(0, 300);
      };
      const out = [];
      out.push('machineCode: ' + await E('window.Setting.invokeWithCallback("license.machineCode")'));
      out.push('hasLicense: ' + await E('window.Setting.invokeWithCallback("license.hasLicense")'));
      out.push('offlineActivation: ' + await E('window.Setting.invokeWithCallback("offlineActivation", ${JSON.stringify(CODE)})'));
      return out.join('\\n');
    })()`;
    const c = await send('Runtime.evaluate', { expression: CMD, returnByValue: true, awaitPromise: true });
    const cv = c.result && c.result.result ? c.result.result.value : JSON.stringify(c.result).slice(0, 400);
    console.log(cv);
    console.log('--- now check fshook.log for [ipc] / [act] / [json] / [net] lines ---');
    process.exit(0);
  };
})();

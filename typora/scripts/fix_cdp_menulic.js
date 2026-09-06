// fix_cdp_menulic.js — open the license window via the app's own menu (correct webPreferences/preload),
// then drive offlineActivation through it. Usage: node fix_cdp_menulic.js [code]
const http = require('http');
const CODE = process.argv[2] || 'AAAAA';

function getList() {
  return new Promise((res, rej) => {
    http.get('http://127.0.0.1:9229/json/list', r => {
      let b = '';
      r.on('data', d => b += d);
      r.on('end', () => res(JSON.parse(b)));
    }).on('error', rej);
  });
}

(async () => {
  const list = await getList();
  const main = list.find(t => t.type === 'node') || list[0];
  if (!main) { console.log('no inspector target'); process.exit(1); }
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
    const ev = async (expr) => {
      const r = await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
      const v = r.result && r.result.result;
      if (v && v.value !== undefined) return v.value;
      return JSON.stringify(r.result).slice(0, 300);
    };
    // 1) find a menu item matching license-ish labels
    const FIND = `(function(){
      const _el = process.getBuiltinModule('module')._load('electron');
      const m = _el.Menu.getApplicationMenu();
      if (!m) return 'NO_APP_MENU';
      const hits = [];
      (function walk(menu, path){
        for (const it of menu.items || []) {
          const p = path + ' / ' + it.label;
          if (it.submenu) walk(it.submenu, p);
          else if (/license|licence|激活|许可证|注册|renew/i.test(String(it.label||''))) hits.push({ p, label: it.label, id: it.id, clickable: typeof it.click === 'function' });
        }
      })(m, '');
      return JSON.stringify(hits);
    })()`;
    const hits = await ev(FIND);
    console.log('[menu hits]', hits);
    // 2) click the first hit
    const CLICK = `(function(){
      const _el = process.getBuiltinModule('module')._load('electron');
      const m = _el.Menu.getApplicationMenu();
      let clicked = null;
      (function walk(menu, path){
        for (const it of menu.items || []) {
          if (clicked) return;
          const p = path + ' / ' + it.label;
          if (it.submenu) walk(it.submenu, p);
          else if (/license|licence|激活|许可证|注册/i.test(String(it.label||'')) && typeof it.click === 'function') {
            clicked = { p, label: it.label };
            try { it.click(); } catch (e) { clicked.err = String(e && e.message || e); }
          }
        }
      })(m, '');
      return JSON.stringify(clicked);
    })()`;
    console.log('[click]', await ev(CLICK));
    await new Promise(r => setTimeout(r, 2500));
    // 3) now find the license window and drive offlineActivation
    const DRIVE = `(async function(){
      const _el = process.getBuiltinModule('module')._load('electron');
      const wins = _el.BrowserWindow.getAllWindows();
      let w = null;
      for (const x of wins) {
        const u = ((x.webContents && x.webContents.getURL()) || '').toLowerCase();
        if (u.indexOf('license.html') >= 0) { w = x; break; }
      }
      if (!w) return 'NO_LICENSE_WINDOW; windows: ' + wins.map(x => (x.webContents && x.webContents.getURL()) || '?').join(' | ');
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
    console.log('[drive]', await ev(DRIVE));
    process.exit(0);
  };
})();

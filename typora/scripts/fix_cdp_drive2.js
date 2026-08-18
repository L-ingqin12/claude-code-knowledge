// fix_cdp_drive2.js — re-drive offlineActivation on the (now existing, hidden) license window.
// Usage: node fix_cdp_drive2.js [code]
const http = require('http');
const CODE = process.argv[2] || 'AAAAA';

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
      const res = r.result || {};
      if (res.exceptionDetails) return 'EXC: ' + JSON.stringify(res.exceptionDetails).slice(0, 500);
      const v = res.result;
      if (v && v.value !== undefined) return String(v.value).slice(0, 2000);
      return 'RAW: ' + JSON.stringify(r).slice(0, 500);
    };
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
      try { d.attach('1.3'); } catch (e) { /* already attached or attach failed */ }
      const E = async (expr) => {
        let r;
        try { r = await d.sendCommand('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true }); }
        catch (e) { return 'CMDERR ' + (e && e.message || e); }
        const v = r && r.result;
        if (v && v.exceptionDetails) return 'EXC ' + ((v.exceptionDetails.exception && v.exceptionDetails.exception.description) || v.exceptionDetails.text).slice(0, 200);
        if (v && v.result && v.result.value !== undefined) return String(v.result.value).slice(0, 600);
        return 'RAW ' + JSON.stringify(r).slice(0, 300);
      };
      const out = [];
      out.push('url: ' + w.webContents.getURL());
      out.push('machineCode: ' + await E('typeof window.Setting; window.Setting && window.Setting.invokeWithCallback("license.machineCode")'));
      out.push('hasLicense: ' + await E('window.Setting && window.Setting.invokeWithCallback("license.hasLicense")'));
      out.push('offlineActivation: ' + await E('window.Setting && window.Setting.invokeWithCallback("offlineActivation", ${JSON.stringify(CODE)})'));
      return out.join('\\n');
    })()`;
    console.log(await ev(DRIVE));
    process.exit(0);
  };
})();

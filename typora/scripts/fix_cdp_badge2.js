// fix_cdp_badge2.js — inspect main window badge/license state via main-process webContents debugger.
const http = require('http');

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
      if (res.exceptionDetails) return 'EXC ' + JSON.stringify(res.exceptionDetails).slice(0, 300);
      const v = res.result;
      if (v && v.value !== undefined) return String(v.value).slice(0, 900);
      return 'RAW ' + JSON.stringify(r).slice(0, 300);
    };
    const PROBE = `(async function(){
      const _el = process.getBuiltinModule('module')._load('electron');
      const wins = _el.BrowserWindow.getAllWindows();
      const out = ['windows: ' + wins.map(x => (x.webContents && x.webContents.getURL()) || '?').join(' | ')];
      for (const w of wins) {
        const u = ((w.webContents && w.webContents.getURL()) || '');
        if (u.indexOf('window.html') < 0) continue;
        const d = w.webContents.debugger;
        try { d.attach('1.3'); } catch (e) { /* attached already */ }
        const E = async (expr) => {
          const r = await d.sendCommand('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
          const v = r && r.result;
          if (v && v.exceptionDetails) return 'EXC ' + ((v.exceptionDetails.exception && v.exceptionDetails.exception.description) || v.exceptionDetails.text).slice(0, 200);
          if (v && v.result && v.result.value !== undefined) return String(v.result.value).slice(0, 600);
          return 'RAW ' + JSON.stringify(r).slice(0, 300);
        };
        out.push('--- main window ---');
        out.push('badges: ' + await E('(function(){var r=[];document.querySelectorAll("div").forEach(function(d){var t=d.textContent||"";if(/UNREGISTERED/i.test(t)&&d.children.length===0)r.push(t.trim().slice(0,40))});return JSON.stringify(r)})()'));
        out.push('bodyChildren: ' + await E('(function(){var r=[];for(var c of document.body.children)r.push(c.tagName+"."+String(c.className||"").slice(0,30));return JSON.stringify(r.slice(-8))})()'));
        out.push('File.option: ' + await E('typeof File!=="undefined"&&File.option?JSON.stringify({hasLicense:File.option.hasLicense}):"NO_FILE"'));
        out.push('hasLicense: ' + await E('typeof File!=="undefined"&&File.option?String(File.option.hasLicense):"NO_FILE"'));
      }
      return out.join('\\n');
    })()`;
    console.log(await ev(PROBE));
    process.exit(0);
  };
})();

// fix_cdp_badge.js — inspect the main window for the "UNREGISTERED x" badge and license state.
const http = require('http');

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
  console.log('targets:', list.map(t => `${t.type} ${(t.url || '').slice(0, 60)}`).join('\n  '));
  const page = list.find(t => t.type === 'page' && t.url.indexOf('window.html') >= 0);
  if (!page) { console.log('NO MAIN WINDOW TARGET'); process.exit(1); }
  const ws = new WebSocket(page.webSocketDebuggerUrl);
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
      if (v && v.value !== undefined) return String(v.value).slice(0, 800);
      return 'RAW ' + JSON.stringify(r).slice(0, 300);
    };
    const probe = `(function(){
      const out = [];
      // badge elements: any fixed div whose text contains UNREGISTERED
      const badged = [];
      document.querySelectorAll('div').forEach(d => {
        const t = (d.textContent || '');
        if (/UNREGISTERED/i.test(t) && d.children.length === 0) badged.push(t.trim().slice(0, 40));
      });
      out.push('badges: ' + JSON.stringify(badged));
      out.push('body child count: ' + document.body.children.length);
      const all = [];
      for (const c of document.body.children) all.push(c.tagName + (c.className ? '.' + String(c.className).slice(0, 40) : '') + ':' + (c.textContent || '').trim().slice(0, 30));
      out.push('children: ' + JSON.stringify(all.slice(-6)));
      out.push('typeof File: ' + typeof File);
      out.push('File.option: ' + JSON.stringify(typeof File !== 'undefined' && File.option ? { hasLicense: File.option.hasLicense } : null));
      return out.join('\\n');
    })()`;
    console.log(await ev(probe));
    process.exit(0);
  };
})();

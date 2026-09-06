// fix_cdp_recent.js — find Open Recent submenu, click the item at given index (same handler as user click).
// Usage: node fix_cdp_recent.js [index]   (default: 0 = first recent file)
const http = require('http');
const CLICK_IDX = parseInt(process.argv[2] || '0', 10);

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
    const r2 = await send('Runtime.evaluate', {
      expression: `(function(){
        const _el = process.getBuiltinModule('module')._load('electron');
        const m = _el.Menu.getApplicationMenu();
        if (!m) return 'NO_APP_MENU';
        let recent = null, path = '';
        (function walk(menu, p) {
          if (recent) return;
          for (const it of menu.items || []) {
            if (recent) return;
            const np = p + '/' + (it.label || it.type);
            if (/open recent/i.test(String(it.label || ''))) { recent = { it, path: np }; return; }
            if (it.submenu) walk(it.submenu, np);
          }
        })(m, '');
        if (!recent) return 'NO_OPEN_RECENT';
        const items = (recent.it.submenu ? recent.it.submenu.items : []);
        const summary = items.map((x, i) => ({ i, label: x.label, enabled: x.enabled, type: x.type }));
        if (${CLICK_IDX} >= items.length) return 'INDEX OOB len=' + items.length + ' items=' + JSON.stringify(summary);
        const target = items[${CLICK_IDX}];
        if (!target || !target.enabled) return 'TARGET NOT CLICKABLE ' + JSON.stringify(summary);
        if (typeof target.click === 'function') {
          try { target.click(); return 'CLICKED ' + target.label + ' | all=' + JSON.stringify(summary); }
          catch (e) { return 'CLICK EXC ' + (e && e.stack || e).slice(0, 400) + ' items=' + JSON.stringify(summary); }
        }
        return 'NO CLICK HANDLER items=' + JSON.stringify(summary);
      })()`,
      returnByValue: true
    });
    const v = r2.result && r2.result.result;
    console.log(v && v.value !== undefined ? String(v.value).slice(0, 2000) : JSON.stringify(r2).slice(0, 500));
    process.exit(0);
  };
})();

// fix_cdp_menulist.js — dump the full application menu structure.
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
  const main = list.find(t => t.type === 'node') || list[0];
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
  ws.onopen = async () => {
    await send('Runtime.enable');
    await send('Runtime.runIfWaitingForDebugger');
    const r2 = await send('Runtime.evaluate', {
      expression: `(function(){
        const _el = process.getBuiltinModule('module')._load('electron');
        const m = _el.Menu.getApplicationMenu();
        const out = [];
        (function walk(menu, p) {
          for (const it of menu.items || []) {
            const np = p + '/' + (it.label || it.type);
            if (it.submenu) walk(it.submenu, np);
            else out.push(np + ' [' + it.type + ']');
          }
        })(m, '');
        return out.join('\\n');
      })()`,
      returnByValue: true
    });
    console.log(r2.result && r2.result.result && r2.result.result.value || JSON.stringify(r2).slice(0, 500));
    process.exit(0);
  };
})();

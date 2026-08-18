// fix_cdp_traceopen.js — patch executeJavaScript / shell.open* / webContents.send in the live main
// process, then click a recent-file menu item and dump what the handler actually does.
// Usage: node fix_cdp_traceopen.js [menuIndex]  (default 2 = first recent file)
const http = require('http');
const IDX = process.argv[2] || '2';

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
        const { shell, BrowserWindow } = _el;
        const log = [];
        globalThis.__traceLog = log;
        const t0 = Date.now();
        const now = () => '+' + (Date.now() - t0) + 'ms';
        // patch webContents.executeJavaScript on all windows (existing + future)
        const patchWC = (wc, tag) => {
          if (wc.__traced) return;
          wc.__traced = 1;
          const o = wc.executeJavaScript.bind(wc);
          wc.executeJavaScript = function (code) {
            log.push(now() + ' [xjs] ' + tag + ' ' + String(code).slice(0, 120));
            return o.apply(null, arguments);
          };
        };
        BrowserWindow.getAllWindows().forEach(w => patchWC(w.webContents, w.webContents.getURL().slice(0, 50)));
        const _origAdd = BrowserWindow.addWindow ? null : null;
        // patch shell open functions
        ['openPath', 'openItem', 'openExternal', 'showItemInFolder'].forEach(fn => {
          if (typeof shell[fn] !== 'function') return;
          const o = shell[fn].bind(shell);
          shell[fn] = function () {
            log.push(now() + ' [shell.' + fn + '] ' + JSON.stringify(Array.from(arguments)).slice(0, 200));
            return o.apply(null, arguments);
          };
        });
        // patch webContents.send on all windows
        BrowserWindow.getAllWindows().forEach(w => {
          const wc = w.webContents;
          if (wc.__sendTraced) return;
          wc.__sendTraced = 1;
          const o = wc.send.bind(wc);
          wc.send = function (ch) {
            const args = Array.from(arguments).slice(1).map(a => typeof a === 'string' ? a.slice(0, 80) : (a && a.path ? 'path=' + a.path : JSON.stringify(a).slice(0, 80)));
            log.push(now() + ' [send] ' + ch + ' ' + JSON.stringify(args).slice(0, 200));
            return o.apply(null, arguments);
          };
        });
        // patch app.openFile / openURL style APIs if present
        if (_el.app) {
          ['openFile', 'openUrl'].forEach(fn => {
            if (typeof _el.app[fn] !== 'function') return;
            const o = _el.app[fn].bind(_el.app);
            _el.app[fn] = function () {
              log.push(now() + ' [app.' + fn + '] ' + JSON.stringify(Array.from(arguments)).slice(0, 200));
              return o.apply(null, arguments);
            };
          });
        }
        return 'patched; will click index ' + ${IDX};
      })()`,
      returnByValue: true
    });
    const v = r2.result && r2.result.result;
    console.log(v && v.value !== undefined ? v.value : JSON.stringify(r2).slice(0, 300));

    // small wait for patch to settle, then click
    await new Promise(r => setTimeout(r, 500));
    const r3 = await send('Runtime.evaluate', {
      expression: `(function(){
        const _el = process.getBuiltinModule('module')._load('electron');
        const m = _el.Menu.getApplicationMenu();
        let recent = null;
        (function walk(menu) {
          if (recent) return;
          for (const it of menu.items || []) {
            if (/open recent/i.test(String(it.label || ''))) { recent = it; return; }
            if (it.submenu) walk(it.submenu);
          }
        })(m);
        if (!recent || !recent.submenu) return 'NO_RECENT';
        const items = recent.submenu.items;
        const t = items[${IDX}];
        if (!t) return 'NO_ITEM len=' + items.length;
        try { t.click(); return 'clicked ' + (t.label || ''); }
        catch (e) { return 'EXC ' + (e && e.message || e); }
      })()`,
      returnByValue: true
    });
    const v3 = r3.result && r3.result.result;
    console.log(v3 && v3.value !== undefined ? v3.value : JSON.stringify(r3).slice(0, 300));
    await new Promise(r => setTimeout(r, 6000));
    // dump the collected log from globalThis stash
    const r4 = await send('Runtime.evaluate', {
      expression: `(function(){
        const l = globalThis.__traceLog;
        if (!l) return 'NO STASH';
        return l.join('\\n') || '(empty)';
      })()`,
      returnByValue: true
    });
    const v4 = r4.result && r4.result.result;
    console.log(v4 && v4.value !== undefined ? v4.value : JSON.stringify(r4).slice(0, 500));
    process.exit(0);
  };
})();

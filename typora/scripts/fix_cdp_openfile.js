// fix_cdp_openfile.js — inspect app.openFile and try opening a file through it.
// Usage: node fix_cdp_openfile.js "<path>"
const http = require('http');
const PATH = process.argv[2] || 'D:\\Document\\local\\knowledge\\AI大模型开发.md';

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
    const ev = async (expr) => {
      const r = await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
      const res = r.result || {};
      if (res.exceptionDetails) return 'EXC ' + JSON.stringify(res.exceptionDetails).slice(0, 400);
      const v = res.result;
      if (v && v.value !== undefined) return String(v.value).slice(0, 2000);
      return 'RAW ' + JSON.stringify(r).slice(0, 400);
    };
    console.log('--- app.openFile probe ---');
    console.log(await ev(`(function(){
      const _el = process.getBuiltinModule('module')._load('electron');
      const src = _el.app && _el.app.openFile ? String(_el.app.openFile).slice(0, 800) : 'NO openFile on app';
      return src;
    })()`));
    console.log('--- app.openFile.call try ---');
    console.log(await ev(`(async function(){
      const _el = process.getBuiltinModule('module')._load('electron');
      if (!_el.app.openFile) return 'NO openFile';
      try {
        const r = await _el.app.openFile(${JSON.stringify(PATH)});
        return 'openFile returned: ' + JSON.stringify(r);
      } catch (e) { return 'openFile EXC: ' + (e && e.stack || e).slice(0, 400); }
    })()`));
    await new Promise(r => setTimeout(r, 5000));
    console.log('--- main window state after openFile ---');
    console.log(await ev(`(async function(){
      const _el = process.getBuiltinModule('module')._load('electron');
      const wins = _el.BrowserWindow.getAllWindows();
      const out = ['windows: ' + wins.map(w => (w.webContents && w.webContents.getURL() || '?').slice(0, 60)).join(' | ')];
      for (const w of wins) {
        const u = (w.webContents && w.webContents.getURL()) || '';
        if (u.indexOf('window.html') < 0) continue;
        const d = w.webContents.debugger;
        try { d.attach('1.3'); } catch (e) {}
        const E = async (expr) => {
          const r = await d.sendCommand('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
          const v = r && r.result;
          if (v && v.exceptionDetails) return 'EXC ' + ((v.exceptionDetails.exception && v.exceptionDetails.exception.description) || v.exceptionDetails.text).slice(0, 150);
          if (v && v.result && v.result.value !== undefined) return String(v.result.value).slice(0, 300);
          return 'RAW ' + JSON.stringify(r).slice(0, 150);
        };
        out.push('title: ' + await E('document.title'));
        out.push('File.option.path: ' + await E('typeof File!=="undefined"&&File.option?String(File.option.path||File.option.filePath||""):"NO_FILE"'));
        out.push('editor: ' + await E('document.querySelector(".CodeMirror")?"HAS_EDITOR":"NO_EDITOR"'));
      }
      return out.join('\\n');
    })()`));
    process.exit(0);
  };
})();

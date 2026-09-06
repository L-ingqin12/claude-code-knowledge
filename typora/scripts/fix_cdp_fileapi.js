// fix_cdp_fileapi.js — enumerate renderer File API and try File.open(path).
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
    const r2 = await send('Runtime.evaluate', {
      expression: `(async function(){
        const _el = process.getBuiltinModule('module')._load('electron');
        const wins = _el.BrowserWindow.getAllWindows();
        const w = wins.find(x => (x.webContents.getURL() || '').indexOf('window.html') >= 0);
        if (!w) return 'NO_WIN';
        const d = w.webContents.debugger;
        try { d.attach('1.3'); } catch (e) {}
        const E = async (exp) => {
          const r = await d.sendCommand('Runtime.evaluate', { expression: exp, returnByValue: true, awaitPromise: true });
          const v = r && r.result;
          if (v && v.exceptionDetails) return 'EXC ' + ((v.exceptionDetails.exception && v.exceptionDetails.exception.description) || v.exceptionDetails.text).slice(0, 200);
          if (v && v.result && v.result.value !== undefined) return String(v.result.value).slice(0, 2500);
          return 'RAW ' + JSON.stringify(r).slice(0, 250);
        };
        const out = [];
        out.push('File keys: ' + await E('typeof File !== "undefined" ? Object.keys(File).join(",") : "NO_FILE"'));
        out.push('File.option keys: ' + await E('typeof File !== "undefined" && File.option ? Object.keys(File.option).slice(0,50).join(",") : "NO"'));
        out.push('typeof File.open: ' + await E('typeof File !== "undefined" ? String(typeof File.open) + " / " + String(typeof File.openFile) : "NO_FILE"'));
        if (typeof File !== 'undefined') {
          out.push('try File.open: ' + await E('(function(){ try { File.open(${JSON.stringify(PATH)}); return "called File.open"; } catch(e) { return "File.open EXC " + (e && e.message || e); } })()'));
          out.push('try File.openFile: ' + await E('(function(){ try { File.openFile(${JSON.stringify(PATH)}); return "called File.openFile"; } catch(e) { return "File.openFile EXC " + (e && e.message || e); } })()'));
        }
        return out.join('\\n');
      })()`,
      returnByValue: true,
      awaitPromise: true
    });
    const v = r2.result && r2.result.result;
    console.log(v && v.value !== undefined ? v.value : JSON.stringify(r2).slice(0, 600));
    process.exit(0);
  };
})();

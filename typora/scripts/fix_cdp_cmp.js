// fix_cdp_cmp.js — compare editor content with the file on disk.
const http = require('http');
const fs = require('fs');
const PATH = 'D:\\Document\\local\\knowledge\\AI大模型开发.md';

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
  let disk = null;
  try { disk = fs.readFileSync(PATH, 'utf8'); } catch (e) { disk = 'READ_ERR ' + e.message; }
  console.log('DISK len:', typeof disk === 'string' ? disk.length : disk);
  console.log('DISK first 150:', JSON.stringify(typeof disk === 'string' ? disk.slice(0, 150) : disk));

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
        const r = await d.sendCommand('Runtime.evaluate', {
          expression: '(function(){var cm=document.querySelector(".CodeMirror");if(!cm)return "NO_EDITOR";var t=cm.textContent;var idx=t.indexOf("AI 大模型");return "LEN="+t.length+" HIT_AI="+idx+" HEAD="+JSON.stringify(t.slice(0,60))+" TAIL="+JSON.stringify(t.slice(-100));})()',
          returnByValue: true
        });
        const v = r && r.result;
        return v && v.result && v.result.value !== undefined ? v.result.value : JSON.stringify(r).slice(0, 300);
      })()`,
      returnByValue: true,
      awaitPromise: true
    });
    const v = r2.result && r2.result.result;
    const editor = v && v.value !== undefined ? String(v.value) : 'EVAL_FAIL';
    console.log('EDITOR len:', editor.length);
    console.log('EDITOR first 150:', JSON.stringify(editor.slice(0, 150)));
    console.log('MATCH head:', typeof disk === 'string' && disk.slice(0, 100) === editor.slice(0, 100) ? 'YES' : 'NO');
    process.exit(0);
  };
})();

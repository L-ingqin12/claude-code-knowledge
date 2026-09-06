// fix_cdp_curfile.js — read the currently open file path from the main window renderer.
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
      expression: `(async function(){
        const _el = process.getBuiltinModule('module')._load('electron');
        const wins = _el.BrowserWindow.getAllWindows();
        for (const w of wins) {
          const u = ((w.webContents && w.webContents.getURL()) || '');
          if (u.indexOf('window.html') < 0) continue;
          const d = w.webContents.debugger;
          try { d.attach('1.3'); } catch (e) {}
          const E = async (expr) => {
            const r = await d.sendCommand('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
            const v = r && r.result;
            if (v && v.exceptionDetails) return 'EXC ' + ((v.exceptionDetails.exception && v.exceptionDetails.exception.description) || v.exceptionDetails.text).slice(0, 200);
            if (v && v.result && v.result.value !== undefined) return String(v.result.value).slice(0, 400);
            return 'RAW ' + JSON.stringify(r).slice(0, 200);
          };
          const out = [];
          out.push('title: ' + await E('document.title'));
          out.push('File.option.path: ' + await E('typeof File!=="undefined"&&File.option?String(File.option.path||File.option.filePath||""):"NO_FILE"'));
          out.push('currentFile: ' + await E('typeof File!=="undefined"&&File.currentFile?String(File.currentFile.path||File.currentFile.filePath||JSON.stringify(File.currentFile).slice(0,150)):"NO_CUR"'));
          out.push('editor text: ' + await E('(document.querySelector(".CodeMirror")?document.querySelector(".CodeMirror").textContent.slice(0,80):"NO_EDITOR")'));
          return out.join('\\n');
        }
        return 'NO_MAIN_WINDOW';
      })()`,
      returnByValue: true,
      awaitPromise: true
    });
    const v = r2.result && r2.result.result;
    console.log(v && v.value !== undefined ? String(v.value).slice(0, 1500) : JSON.stringify(r2).slice(0, 500));
    process.exit(0);
  };
})();

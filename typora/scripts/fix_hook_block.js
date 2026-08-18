// fix_hook_block.js — Typora 1.13.2 activation-bypass hook (52pojie article, ported)
// Injected by fix_rebuild_asar.py BEFORE ,require("./atom.compiled.dist.jsc")
// Placeholders replaced by the python script: __LOG_PATH__, __MODE__ (probe|activate)
// Runs in launch.dist.js module scope => require/fs/path/__dirname/process/Buffer all available.
(function(){
var __lp="__LOG_PATH__";
var __mode="__MODE__";
var __log=function(m){try{fs.appendFileSync(__lp,new Date().toISOString()+" "+m+"\r\n")}catch(e){}};
__log("hook loaded dir="+__dirname+" mode="+__mode);
// ---- registry license bootstrap: ensure SLicense has a NON-EMPTY code BEFORE the app's
// license manager reads it. The renew flow strips the code after each startup; with an empty
// code the app skips the decrypt path and shows "UNREGISTERED". Code content is irrelevant:
// publicDecrypt is faked below, so any non-empty code yields a valid license.
try{
  var __d=new Date(),__today=("0"+(__d.getMonth()+1)).slice(-2)+"/"+("0"+__d.getDate()).slice(-2)+"/"+__d.getFullYear();
  require("child_process").execFileSync(process.env.SystemRoot+"\\System32\\reg.exe",["add","HKCU\\Software\\Typora","/v","SLicense","/t","REG_SZ","/d","QUFBQQ==#0#"+__today,"/f"],{stdio:"ignore"});
  __log("[hook] SLicense registry ensured "+__today);
}catch(e){__log("[hook] registry set fail "+(e&&e.message||e))}
// ---- inspector (wait=false, unchanged) ----
try{require("inspector").open(9229,"[IP已脱敏]",false);__log("[hook] inspector open 9229")}catch(e){__log("[hook] inspector fail "+(e&&e.message))}
// ---- fs redirect app.asar -> app.bak (unchanged) ----
var __appDir=__dirname,__resDir=path.dirname(__appDir),__bakDir=path.join(__resDir,"app.bak"),__pageDir=path.join(__resDir,"page-dist")+path.sep;
function __redir(p){if(typeof p!=="string")return p;try{var a=path.resolve(p),l=a.toLowerCase(),pk=path.join(__appDir,"package.json").toLowerCase(),ld=path.join(__appDir,"launch.dist.js").toLowerCase(),as=path.join(__resDir,"app.asar").toLowerCase();if(l===pk||l===ld||l===as+path.sep+"package.json"||l===as+path.sep+"launch.dist.js")return path.join(__bakDir,path.basename(a));if(l.indexOf(__pageDir.toLowerCase())===0)return path.join(__bakDir,"page-dist",a.slice(__pageDir.length));}catch(e){}return p;}
function __h(p){return (typeof p==="string")?p:((p&&typeof p.href==="string")?p.href:null);}
["readFileSync","readFile","statSync","stat","open","openSync"].forEach(function(f){var o=fs[f];fs[f]=function(){var a=Array.prototype.slice.call(arguments);var h=__h(a[0]);if(h){var r=__redir(h);if(r!==h){a[0]=r;__log("[fs] "+f+" -> "+r);}}return o.apply(this,a);};});
["readFile","open","stat"].forEach(function(f){var o=fs.promises[f];fs.promises[f]=function(){var a=Array.prototype.slice.call(arguments);var h=__h(a[0]);if(h){var r=__redir(h);if(r!==h){a[0]=r;__log("[prom] "+f+" -> "+r);}else if(h.toLowerCase().indexOf("resources")>=0||h.toLowerCase().indexOf("jsc")>=0)__log("[prom] "+f+" pass "+h);}return o.apply(this,a);};});
process.on("uncaughtException",function(e){__log("[exc] "+(e&&e.message||e)+" @ "+(e&&e.stack||"no stack"))});
process.on("unhandledRejection",function(e){__log("[rej] "+(e&&e.message||e))});
// ---- electron wraps (unchanged; TY_FORCE_SHOW_LIC=1 env makes license window visible for manual testing) ----
var __el=null;
try{__log("[hook] node="+process.version+" v8="+process.versions.v8+" electron="+(process.versions.electron||"?"));__el=require("electron");
var __nf=__el.net&&__el.net.fetch;
if(__nf)__el.net.fetch=function(){var a=Array.prototype.slice.call(arguments),h=__h(a[0]);if(h&&h.toLowerCase().indexOf("file://")===0)__log("[net] fetch "+h);return __nf.apply(this,a)};
var __BW=__el.BrowserWindow;
if(__BW&&__BW.prototype){var __lu=__BW.prototype.loadURL;if(__lu)__BW.prototype.loadURL=function(){var a=Array.prototype.slice.call(arguments),h=__h(a[0]);if(h){this.__lpUrl=h;__log("[bw] loadURL "+h)}return __lu.apply(this,a)};
function __isLic(w){try{var u=(w.__lpUrl||(w.webContents&&w.webContents.getURL&&w.webContents.getURL())||"").toLowerCase();return u.indexOf("license.html")>=0}catch(e){return false}}
function __forceShow(){return typeof process!=="undefined"&&process.env&&process.env.TY_FORCE_SHOW_LIC==="1"}
var __sh=__BW.prototype.show;if(__sh)__BW.prototype.show=function(){if(__isLic(this)&&!__forceShow()){__log("[bw] show->skip");return}return __sh.apply(this,arguments)};
var __si=__BW.prototype.showInactive;if(__si)__BW.prototype.showInactive=function(){if(__isLic(this)&&!__forceShow()){__log("[bw] showInactive->skip");return}return __si.apply(this,arguments)};
var __cl=__BW.prototype.close;if(__cl)__BW.prototype.close=function(){if(__isLic(this)&&!__forceShow()){this.hide();__log("[bw] close->hide");return}return __cl.apply(this,arguments)}}
}catch(e){__log("[hook] electron wrap fail "+(e&&e.message))}
// ============ activation bypass (52pojie 1.12.4 -> ported to 1.13.2) ============
try{
var __crypto=require("crypto");
var __pd=__crypto.publicDecrypt;
// Fake plaintext, fields must match this machine's real machine code (CHECKPOINT):
// machineCode={"v":"win|1.13.2","i":"t6aaDrYAHd","l":"ZEROJEAN | 28064 | Windows"}
var __fakePlain=Buffer.from(JSON.stringify({
  deviceId:"ZEROJEAN | 28064 | Windows",
  fingerprint:"t6aaDrYAHd",
  email:"zerojean@mail.local",
  license:"Cracked_By_ZEROJEAN",
  version:"win|1.13.2",
  date:(function(){var d=new Date();return ("0"+(d.getMonth()+1)).slice(-2)+"/"+("0"+d.getDate()).slice(-2)+"/"+d.getFullYear();})(),
  type:"ZEROJEAN"
}));
__crypto.publicDecrypt=function(){
  var a=Array.prototype.slice.call(arguments),key=a[0],buf=a[1];
  try{var ki="";if(key&&typeof key==="object"){ki=key.asymmetricKeyType+" "+key.modulusLength+"b";try{ki+=" spki="+__crypto.createHash("sha1").update(key.export({type:"spki",format:"der"})).digest("hex").slice(0,16)}catch(e2){}}else if(typeof key==="string")ki=key.slice(0,64);
  __log("[act] publicDecrypt key="+ki+" buf="+(buf&&buf.length?buf.toString("hex").slice(0,160)+".."+buf.length+"B":"?"));}catch(e){__log("[act] publicDecrypt log fail "+(e&&e.message))}
  if(__mode==="activate"){__log("[act] publicDecrypt -> FAKE plaintext");return __fakePlain}
  return __pd.apply(this,a);
};
// ---- ipcMain.handle wrap: log channel + payload + result (both modes; probe=primary use) ----
if(__el&&__el.ipcMain&&__el.ipcMain.handle&&!__el.ipcMain.__fshooked){__el.ipcMain.__fshooked=1;
  var __ih=__el.ipcMain.handle;
  __el.ipcMain.handle=function(ch,t){
    return __ih.call(this,ch,async function(){
      var a=Array.prototype.slice.call(arguments,1);
      try{__log("[ipc] handle \""+ch+"\" args="+JSON.stringify(a).slice(0,600))}catch(e){}
      var r=await t.apply(this,arguments);
      try{__log("[ipc] handle \""+ch+"\" => "+JSON.stringify(r).slice(0,600))}catch(e){}
      return r;
    });
  };
}
// ---- JSON.parse proxy: log field reads from license/renew JSON (any parsed object) ----
var __jp=JSON.parse;
var __jkeys=/^(success|license|code|msg|message|data|error|errorCode|renewed|type|v|u|deviceId|fingerprint|email|date|version|lastRetry|expiry|expires|activeTime|activateTime|regCode|sn|update|activate)$/;
JSON.parse=function(){
  var t=arguments[0],o=__jp.apply(this,arguments);
  try{if(o&&typeof o==="object"&&typeof t==="string"){var seen={};
    return new Proxy(o,{get:function(tr,p,rc){if(typeof p==="string"&&!seen[p]&&__jkeys.test(p)){seen[p]=1;__log("[json] ."+p)}return Reflect.get(tr,p,rc)}});
  }}catch(e){}
  return o;
};
// ---- https protocol handler: log all, fake ONLY the renew URL (activate) ----
if(__el&&__el.app&&__el.app.whenReady){
  __el.app.whenReady().then(function(){
    try{
      __el.protocol.handle("https",async function(req){
        var u=(req&&req.url)||"";
        try{__log("[net] "+req.method+" "+u);var rb=req.clone();var t=await rb.text();if(t)__log("[net] body "+t.slice(0,500))}catch(e){__log("[net] req log fail "+(e&&e.message))}
        if(__mode==="activate"&&/\/api\/client\/renew/.test(u)){
          // 1.13.2 unfills the stored license then refills from the renew response;
          // the response must carry the license string (code#type#MM/DD/YYYY).
          // code content is irrelevant: startup decrypt is faked by this hook anyway.
          var __d=new Date(),__lic="QUFBQQ==#0#"+("0"+(__d.getMonth()+1)).slice(-2)+"/"+("0"+__d.getDate()).slice(-2)+"/"+__d.getFullYear();
          var body=JSON.stringify({success:true,license:__lic});
          __log("[net] RENEW intercepted -> "+body);
          try{if(typeof Response!=="undefined")return new Response(body,{status:200,headers:{"content-type":"application/json","access-control-allow-origin":"*"}});}catch(e){}
          return __el.net.fetch("data:application/json,"+encodeURIComponent(body));
        }
        try{
          var res=await __el.net.fetch(req,{bypassCustomProtocolHandlers:true});
          try{var rc=res.clone();rc.text().then(function(t){__log("[net] resp "+res.status+" "+u+" "+(t||"").slice(0,200))}).catch(function(){})}catch(e){}
          return res;
        }catch(e){__log("[net] fwd fail "+u+" "+(e&&e.message));throw e}
      });
      __log("[hook] protocol.handle('https') registered");
    }catch(e){__log("[hook] protocol fail "+(e&&e.message))}
  });
}
}catch(e){__log("[hook] activation hook fail "+(e&&e.message))}
})()

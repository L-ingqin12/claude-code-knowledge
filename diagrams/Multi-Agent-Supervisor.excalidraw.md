---
excalidraw-plugin: parsed
tags: [excalidraw]
---
# Excalidraw Data

## Text Elements
用户任务

Supervisor 主管\n路由与汇总

研究员 Agent

程序员 Agent

审稿 Agent

最终答案

分派

分派

分派

结果

结果

结果

finish

worker 只与 Supervisor 通信，互不直连

## Drawing
```json
{
  "type": "excalidraw",
  "version": 2,
  "source": "https://github.com/zsviczian/obsidian-excalidraw-plugin",
  "elements": [
    {"id":"user","type":"rectangle","x":70,"y":140,"width":150,"height":60,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"#e3f2fd","fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":{"type":3},"seed":1,"version":1,"isDeleted":false,"boundElements":[{"id":"tuser","type":"text"},{"id":"a0","type":"arrow"}],"updated":1,"link":null,"locked":false},
    {"id":"sup","type":"rectangle","x":340,"y":130,"width":190,"height":80,"angle":0,"strokeColor":"#388e3c","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":2,"strokeStyle":"dashed","roughness":1,"opacity":100,"groupIds":[],"roundness":{"type":3},"seed":2,"version":1,"isDeleted":false,"boundElements":[{"id":"tsup","type":"text"},{"id":"a0","type":"arrow"},{"id":"d1","type":"arrow"},{"id":"d2","type":"arrow"},{"id":"d3","type":"arrow"},{"id":"r1","type":"arrow"},{"id":"r2","type":"arrow"},{"id":"r3","type":"arrow"},{"id":"fin","type":"arrow"}],"updated":1,"link":null,"locked":false},
    {"id":"w1","type":"rectangle","x":700,"y":40,"width":180,"height":56,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"#fff9c4","fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":{"type":3},"seed":3,"version":1,"isDeleted":false,"boundElements":[{"id":"tw1","type":"text"},{"id":"d1","type":"arrow"},{"id":"r1","type":"arrow"}],"updated":1,"link":null,"locked":false},
    {"id":"w2","type":"rectangle","x":700,"y":160,"width":180,"height":56,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"#fff9c4","fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":{"type":3},"seed":4,"version":1,"isDeleted":false,"boundElements":[{"id":"tw2","type":"text"},{"id":"d2","type":"arrow"},{"id":"r2","type":"arrow"}],"updated":1,"link":null,"locked":false},
    {"id":"w3","type":"rectangle","x":700,"y":280,"width":180,"height":56,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"#fff9c4","fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":{"type":3},"seed":5,"version":1,"isDeleted":false,"boundElements":[{"id":"tw3","type":"text"},{"id":"d3","type":"arrow"},{"id":"r3","type":"arrow"}],"updated":1,"link":null,"locked":false},
    {"id":"ans","type":"rectangle","x":340,"y":420,"width":190,"height":60,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"#c8e6c9","fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":{"type":3},"seed":6,"version":1,"isDeleted":false,"boundElements":[{"id":"tans","type":"text"},{"id":"fin","type":"arrow"}],"updated":1,"link":null,"locked":false},
    {"id":"a0","type":"arrow","x":224,"y":170,"points":[[0,0],[112,0]],"lastCommittedPoint":null,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":21,"version":1,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"startArrowhead":null,"endArrowhead":"arrow","startBinding":{"elementId":"user","focus":0,"gap":4},"endBinding":{"elementId":"sup","focus":0,"gap":4}},
    {"id":"d1","type":"arrow","x":534,"y":148,"points":[[0,0],[162,-80]],"lastCommittedPoint":null,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":22,"version":1,"isDeleted":false,"boundElements":[{"id":"la1","type":"text"}],"updated":1,"link":null,"locked":false,"startArrowhead":null,"endArrowhead":"arrow","startBinding":{"elementId":"sup","focus":-0.55,"gap":4},"endBinding":{"elementId":"w1","focus":0,"gap":4}},
    {"id":"d2","type":"arrow","x":534,"y":170,"points":[[0,0],[162,18]],"lastCommittedPoint":null,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":23,"version":1,"isDeleted":false,"boundElements":[{"id":"la2","type":"text"}],"updated":1,"link":null,"locked":false,"startArrowhead":null,"endArrowhead":"arrow","startBinding":{"elementId":"sup","focus":0,"gap":4},"endBinding":{"elementId":"w2","focus":0,"gap":4}},
    {"id":"d3","type":"arrow","x":534,"y":192,"points":[[0,0],[162,116]],"lastCommittedPoint":null,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":24,"version":1,"isDeleted":false,"boundElements":[{"id":"la3","type":"text"}],"updated":1,"link":null,"locked":false,"startArrowhead":null,"endArrowhead":"arrow","startBinding":{"elementId":"sup","focus":0.55,"gap":4},"endBinding":{"elementId":"w3","focus":0,"gap":4}},
    {"id":"r1","type":"arrow","x":696,"y":78,"points":[[0,0],[-162,78]],"lastCommittedPoint":null,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":25,"version":1,"isDeleted":false,"boundElements":[{"id":"lr1","type":"text"}],"updated":1,"link":null,"locked":false,"startArrowhead":null,"endArrowhead":"arrow","startBinding":{"elementId":"w1","focus":0.36,"gap":4},"endBinding":{"elementId":"sup","focus":-0.35,"gap":4}},
    {"id":"r2","type":"arrow","x":696,"y":196,"points":[[0,0],[-162,-22]],"lastCommittedPoint":null,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":26,"version":1,"isDeleted":false,"boundElements":[{"id":"lr2","type":"text"}],"updated":1,"link":null,"locked":false,"startArrowhead":null,"endArrowhead":"arrow","startBinding":{"elementId":"w2","focus":0.29,"gap":4},"endBinding":{"elementId":"sup","focus":0.1,"gap":4}},
    {"id":"r3","type":"arrow","x":696,"y":290,"points":[[0,0],[-162,-110]],"lastCommittedPoint":null,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":27,"version":1,"isDeleted":false,"boundElements":[{"id":"lr3","type":"text"}],"updated":1,"link":null,"locked":false,"startArrowhead":null,"endArrowhead":"arrow","startBinding":{"elementId":"w3","focus":-0.64,"gap":4},"endBinding":{"elementId":"sup","focus":0.25,"gap":4}},
    {"id":"fin","type":"arrow","x":435,"y":214,"points":[[0,0],[0,202]],"lastCommittedPoint":null,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":28,"version":1,"isDeleted":false,"boundElements":[{"id":"lfin","type":"text"}],"updated":1,"link":null,"locked":false,"startArrowhead":null,"endArrowhead":"arrow","startBinding":{"elementId":"sup","focus":0,"gap":4},"endBinding":{"elementId":"ans","focus":0,"gap":4}},
    {"id":"tuser","type":"text","x":70,"y":140,"width":150,"height":60,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":1,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":41,"version":1,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"text":"用户任务","fontSize":16,"fontFamily":1,"textAlign":"center","verticalAlign":"middle","containerId":"user","originalText":"用户任务","lineHeight":1.25},
    {"id":"tsup","type":"text","x":340,"y":130,"width":190,"height":80,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":1,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":42,"version":1,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"text":"Supervisor 主管\n路由与汇总","fontSize":16,"fontFamily":1,"textAlign":"center","verticalAlign":"middle","containerId":"sup","originalText":"Supervisor 主管\n路由与汇总","lineHeight":1.25},
    {"id":"tw1","type":"text","x":700,"y":40,"width":180,"height":56,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":1,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":43,"version":1,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"text":"研究员 Agent","fontSize":16,"fontFamily":1,"textAlign":"center","verticalAlign":"middle","containerId":"w1","originalText":"研究员 Agent","lineHeight":1.25},
    {"id":"tw2","type":"text","x":700,"y":160,"width":180,"height":56,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":1,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":44,"version":1,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"text":"程序员 Agent","fontSize":16,"fontFamily":1,"textAlign":"center","verticalAlign":"middle","containerId":"w2","originalText":"程序员 Agent","lineHeight":1.25},
    {"id":"tw3","type":"text","x":700,"y":280,"width":180,"height":56,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":1,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":45,"version":1,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"text":"审稿 Agent","fontSize":16,"fontFamily":1,"textAlign":"center","verticalAlign":"middle","containerId":"w3","originalText":"审稿 Agent","lineHeight":1.25},
    {"id":"tans","type":"text","x":340,"y":420,"width":190,"height":60,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":1,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":46,"version":1,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"text":"最终答案","fontSize":16,"fontFamily":1,"textAlign":"center","verticalAlign":"middle","containerId":"ans","originalText":"最终答案","lineHeight":1.25},
    {"id":"la1","type":"text","x":595,"y":96,"width":40,"height":20,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":1,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":47,"version":1,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"text":"分派","fontSize":14,"fontFamily":1,"textAlign":"center","verticalAlign":"middle","containerId":"d1","originalText":"分派","lineHeight":1.25},
    {"id":"la2","type":"text","x":580,"y":167,"width":40,"height":20,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":1,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":48,"version":1,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"text":"分派","fontSize":14,"fontFamily":1,"textAlign":"center","verticalAlign":"middle","containerId":"d2","originalText":"分派","lineHeight":1.25},
    {"id":"la3","type":"text","x":595,"y":236,"width":40,"height":20,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":1,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":49,"version":1,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"text":"分派","fontSize":14,"fontFamily":1,"textAlign":"center","verticalAlign":"middle","containerId":"d3","originalText":"分派","lineHeight":1.25},
    {"id":"lr1","type":"text","x":595,"y":120,"width":40,"height":20,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":1,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":50,"version":1,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"text":"结果","fontSize":14,"fontFamily":1,"textAlign":"center","verticalAlign":"middle","containerId":"r1","originalText":"结果","lineHeight":1.25},
    {"id":"lr2","type":"text","x":640,"y":192,"width":40,"height":20,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":1,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":51,"version":1,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"text":"结果","fontSize":14,"fontFamily":1,"textAlign":"center","verticalAlign":"middle","containerId":"r2","originalText":"结果","lineHeight":1.25},
    {"id":"lr3","type":"text","x":595,"y":212,"width":40,"height":20,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":1,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":52,"version":1,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"text":"结果","fontSize":14,"fontFamily":1,"textAlign":"center","verticalAlign":"middle","containerId":"r3","originalText":"结果","lineHeight":1.25},
    {"id":"lfin","type":"text","x":440,"y":305,"width":60,"height":20,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":1,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":53,"version":1,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"text":"finish","fontSize":14,"fontFamily":1,"textAlign":"center","verticalAlign":"middle","containerId":"fin","originalText":"finish","lineHeight":1.25},
    {"id":"note","type":"text","x":600,"y":380,"width":360,"height":25,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":1,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":54,"version":1,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"text":"worker 只与 Supervisor 通信，互不直连","fontSize":16,"fontFamily":1,"textAlign":"center","verticalAlign":"middle","containerId":null,"originalText":"worker 只与 Supervisor 通信，互不直连","lineHeight":1.25}
  ],
  "appState": {"gridSize": 20, "viewBackgroundColor": "#ffffff", "theme": "dark"},
  "files": {}
}
```

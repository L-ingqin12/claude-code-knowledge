---
excalidraw-plugin: parsed
tags: [excalidraw]
---
# Excalidraw Data

## Text Elements
预训练基座\nPretrained

SFT 指令微调

奖励模型 RM 训练\n偏好对排序

RL 对齐

PPO ·actor+critic\n+ref+RM 四模型

GRPO ·组采样 G 个回答\n组相对优势 免 critic

对齐后模型\nAligned

GRPO: advantage=(rᵢ−mean)/std，DeepSeek-R1 同款

## Drawing
```json
{
  "type": "excalidraw",
  "version": 2,
  "source": "https://github.com/zsviczian/obsidian-excalidraw-plugin",
  "elements": [
    {"id":"base","type":"rectangle","x":70,"y":110,"width":170,"height":64,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"#e3f2fd","fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":{"type":3},"seed":1,"version":1,"isDeleted":false,"boundElements":[{"id":"tbase","type":"text"},{"id":"ab","type":"arrow"}],"updated":1,"link":null,"locked":false},
    {"id":"sft","type":"rectangle","x":285,"y":110,"width":170,"height":64,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"#fff9c4","fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":{"type":3},"seed":2,"version":1,"isDeleted":false,"boundElements":[{"id":"tsft","type":"text"},{"id":"ab","type":"arrow"},{"id":"as","type":"arrow"}],"updated":1,"link":null,"locked":false},
    {"id":"rm","type":"rectangle","x":500,"y":110,"width":170,"height":64,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"#ffccbc","fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":{"type":3},"seed":3,"version":1,"isDeleted":false,"boundElements":[{"id":"trm","type":"text"},{"id":"as","type":"arrow"},{"id":"ar","type":"arrow"}],"updated":1,"link":null,"locked":false},
    {"id":"rl","type":"rectangle","x":715,"y":70,"width":210,"height":250,"angle":0,"strokeColor":"#1976d2","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":2,"strokeStyle":"dashed","roughness":1,"opacity":100,"groupIds":[],"roundness":{"type":3},"seed":4,"version":1,"isDeleted":false,"boundElements":[{"id":"ar","type":"arrow"}],"updated":1,"link":null,"locked":false},
    {"id":"ppo","type":"rectangle","x":735,"y":105,"width":170,"height":76,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"#ffffff","fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":{"type":3},"seed":5,"version":1,"isDeleted":false,"boundElements":[{"id":"tppo","type":"text"},{"id":"ap","type":"arrow"}],"updated":1,"link":null,"locked":false},
    {"id":"grpo","type":"rectangle","x":735,"y":215,"width":170,"height":76,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"#ffffff","fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":{"type":3},"seed":6,"version":1,"isDeleted":false,"boundElements":[{"id":"tgrpo","type":"text"},{"id":"ag","type":"arrow"}],"updated":1,"link":null,"locked":false},
    {"id":"al","type":"rectangle","x":955,"y":110,"width":170,"height":64,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"#c8e6c9","fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":{"type":3},"seed":7,"version":1,"isDeleted":false,"boundElements":[{"id":"tal","type":"text"},{"id":"ap","type":"arrow"},{"id":"ag","type":"arrow"}],"updated":1,"link":null,"locked":false},
    {"id":"ab","type":"arrow","x":244,"y":142,"points":[[0,0],[37,0]],"lastCommittedPoint":null,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":21,"version":1,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"startArrowhead":null,"endArrowhead":"arrow","startBinding":{"elementId":"base","focus":0,"gap":4},"endBinding":{"elementId":"sft","focus":0,"gap":4}},
    {"id":"as","type":"arrow","x":459,"y":142,"points":[[0,0],[37,0]],"lastCommittedPoint":null,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":22,"version":1,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"startArrowhead":null,"endArrowhead":"arrow","startBinding":{"elementId":"sft","focus":0,"gap":4},"endBinding":{"elementId":"rm","focus":0,"gap":4}},
    {"id":"ar","type":"arrow","x":674,"y":142,"points":[[0,0],[37,0]],"lastCommittedPoint":null,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":23,"version":1,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"startArrowhead":null,"endArrowhead":"arrow","startBinding":{"elementId":"rm","focus":0,"gap":4},"endBinding":{"elementId":"rl","focus":-0.42,"gap":4}},
    {"id":"ap","type":"arrow","x":909,"y":143,"points":[[0,0],[42,0]],"lastCommittedPoint":null,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":24,"version":1,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"startArrowhead":null,"endArrowhead":"arrow","startBinding":{"elementId":"ppo","focus":0,"gap":4},"endBinding":{"elementId":"al","focus":0,"gap":4}},
    {"id":"ag","type":"arrow","x":909,"y":253,"points":[[0,0],[42,0]],"lastCommittedPoint":null,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":2,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":25,"version":1,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"startArrowhead":null,"endArrowhead":"arrow","startBinding":{"elementId":"grpo","focus":0,"gap":4},"endBinding":{"elementId":"al","focus":0,"gap":4}},
    {"id":"tbase","type":"text","x":70,"y":110,"width":170,"height":64,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":1,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":41,"version":1,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"text":"预训练基座\nPretrained","fontSize":16,"fontFamily":1,"textAlign":"center","verticalAlign":"middle","containerId":"base","originalText":"预训练基座\nPretrained","lineHeight":1.25},
    {"id":"tsft","type":"text","x":285,"y":110,"width":170,"height":64,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":1,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":42,"version":1,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"text":"SFT 指令微调","fontSize":16,"fontFamily":1,"textAlign":"center","verticalAlign":"middle","containerId":"sft","originalText":"SFT 指令微调","lineHeight":1.25},
    {"id":"trm","type":"text","x":500,"y":110,"width":170,"height":64,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":1,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":43,"version":1,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"text":"奖励模型 RM 训练\n偏好对排序","fontSize":16,"fontFamily":1,"textAlign":"center","verticalAlign":"middle","containerId":"rm","originalText":"奖励模型 RM 训练\n偏好对排序","lineHeight":1.25},
    {"id":"trl","type":"text","x":715,"y":78,"width":210,"height":22,"angle":0,"strokeColor":"#1976d2","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":1,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":44,"version":1,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"text":"RL 对齐","fontSize":14,"fontFamily":1,"textAlign":"center","verticalAlign":"middle","containerId":null,"originalText":"RL 对齐","lineHeight":1.25},
    {"id":"tppo","type":"text","x":735,"y":105,"width":170,"height":76,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":1,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":45,"version":1,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"text":"PPO ·actor+critic\n+ref+RM 四模型","fontSize":14,"fontFamily":1,"textAlign":"center","verticalAlign":"middle","containerId":"ppo","originalText":"PPO ·actor+critic\n+ref+RM 四模型","lineHeight":1.25},
    {"id":"tgrpo","type":"text","x":735,"y":215,"width":170,"height":76,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":1,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":46,"version":1,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"text":"GRPO ·组采样 G 个回答\n组相对优势 免 critic","fontSize":14,"fontFamily":1,"textAlign":"center","verticalAlign":"middle","containerId":"grpo","originalText":"GRPO ·组采样 G 个回答\n组相对优势 免 critic","lineHeight":1.25},
    {"id":"tal","type":"text","x":955,"y":110,"width":170,"height":64,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":1,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":47,"version":1,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"text":"对齐后模型\nAligned","fontSize":16,"fontFamily":1,"textAlign":"center","verticalAlign":"middle","containerId":"al","originalText":"对齐后模型\nAligned","lineHeight":1.25},
    {"id":"note","type":"text","x":70,"y":345,"width":480,"height":25,"angle":0,"strokeColor":"#1e1e1e","backgroundColor":"transparent","fillStyle":"solid","strokeWidth":1,"strokeStyle":"solid","roughness":1,"opacity":100,"groupIds":[],"roundness":null,"seed":48,"version":1,"isDeleted":false,"boundElements":null,"updated":1,"link":null,"locked":false,"text":"GRPO: advantage=(rᵢ−mean)/std，DeepSeek-R1 同款","fontSize":16,"fontFamily":1,"textAlign":"center","verticalAlign":"middle","containerId":null,"originalText":"GRPO: advantage=(rᵢ−mean)/std，DeepSeek-R1 同款","lineHeight":1.25}
  ],
  "appState": {"gridSize": 20, "viewBackgroundColor": "#ffffff", "theme": "dark"},
  "files": {}
}
```

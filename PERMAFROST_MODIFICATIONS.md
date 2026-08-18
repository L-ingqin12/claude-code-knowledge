# Permafrost 本地修改记录

> 基准版本: permafrost v0.3.0 (npm: @anthropic-ai/claude-code plugin)
> 最后更新: 2026-06-17

---

## 修改文件清单

```
~/.claude/plugins/cache/permafrost/permafrost/0.3.0/proxy/
├── permafrost_align.py    ← 核心补丁 (3处修改)
├── permafrost_proxy.py    ← 注入点 (2处修改)
└── model_router.py        ← 新增文件
```

---

## 补丁1: permafrost_align.py

### 1.1 新增 import os
```diff
-import hashlib\nimport json\nimport re
+import hashlib\nimport json\nimport os\nimport re
```

### 1.2 新增 _RE_CURRENT_DATE 正则
位置: `_RE_CCH` 之后
```python
_RE_CURRENT_DATE = re.compile(r"(Today's date is )\d{4}[-/]\d{2}[-/]\d{2}")
```

### 1.3 AlignReport 新增字段
```python
date_stabilized: int = 0       # currentDate 稳定化计数
tools_normalized: int = 0      # 工具重排计数
```

### 1.4 as_dict() 新增字段
```python
"date_stabilized": self.date_stabilized,
"tools_normalized": self.tools_normalized,
```

### 1.5 stabilize_current_date() 函数
位置: `stabilize_metadata()` 之后, `strip_cache_control()` 之前
功能: 将 msg[0] 中 `Today's date is YYYY/MM/DD` 替换为 `Today's date is 2000-01-01`
原理: 跨天时日期变化破坏消息前缀缓存

### 1.6 _ANCHOR_TOOLS + normalize_tools() 函数
位置: `_coerce_blocks()` 之前
功能: 9个锚点工具固定排序在前, 变数工具(ScheduleWakeup/WebSearch等)排末尾
配置: os.environ.get("PERMAFROST_NORMALIZE_TOOLS", "1") == "1"

### 1.7 align_request() 调用顺序
```python
stabilize_metadata(body, report)
stabilize_current_date(body, report)   # ← 新增
report.tools_sorted = sort_tools(body)
if os.environ.get("PERMAFROST_NORMALIZE_TOOLS", "1") == "1":
    report.tools_normalized = normalize_tools(body)  # ← 新增
```

---

## 补丁2: permafrost_proxy.py

### 2.1 请求前: model_router 调用
位置: `_forward()` 中 `align_request()` 之前 (~line 689)
```python
if os.environ.get("PERMAFROST_MODEL_ROUTING") == "1":
    from model_router import route_model
    route_model(body, session)
```

### 2.2 响应后: quality feedback
位置: `STATS.record_usage()` 之后 (~line 813)
```python
if os.environ.get("PERMAFROST_MODEL_ROUTING") == "1" and report is not None:
    resp_text = bytes(head).decode("utf-8", "replace")
    from model_router import feedback_flash_response
    feedback_flash_response(session, resp_text)
```

---

## 补丁3: model_router.py (新增文件)

功能: 自适应模型路由
- 简单请求 → deepseek-v4-flash (省钱)
- 复杂请求 → 保持 pro (保质量)
- 质量反馈 → flash 回复<50字时自动升级

配置: PERMAFROST_MODEL_ROUTING=1 (默认关闭)

---

## 部署检查清单

### permafrost 更新后重新应用
```bash
# 1. 更新 permafrost 插件
claude plugin update permafrost@permafrost

# 2. 检查文件是否被覆盖
diff ~/.claude/plugins/cache/permafrost/permafrost/0.3.0/proxy/permafrost_align.py \
     /root/workspace/claude-code-knowledge/patches/permafrost_align.py

# 3. 如被覆盖, 从备份恢复
cp /root/workspace/claude-code-knowledge/patches/permafrost_align.py \
   ~/.claude/plugins/cache/permafrost/permafrost/0.3.0/proxy/permafrost_align.py
cp /root/workspace/claude-code-knowledge/patches/model_router.py \
   ~/.claude/plugins/cache/permafrost/permafrost/0.3.0/proxy/model_router.py

# 4. 手动检查 permafrost_proxy.py 的两个注入点

# 5. 清缓存 + 重启
rm -rf ~/.claude/plugins/cache/permafrost/permafrost/0.3.0/proxy/__pycache__/
bash /root/claude-permafrost-deploy.sh rollback && bash /root/claude-permafrost-deploy.sh start

# 6. 验证
curl -s http://[IP已脱敏]:8788/permafrost/doctor | python3 -c "
import sys,json; last=json.load(sys.stdin)['last_request']
print('date_stabilized:', 'date_stabilized' in last)
print('tools_normalized:', 'tools_normalized' in last)
"
```

### 备份位置
```
/root/workspace/claude-code-knowledge/patches/
├── permafrost_align.py     ← 完整 patched 文件
├── model_router.py         ← 独立模块
└── README.md               ← 补丁说明（当前文件的部分内容）
```

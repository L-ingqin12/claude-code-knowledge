# Permafrost 补丁

## currentDate 稳定化 (2026-06-13)

**问题**: CC 在 msg[0] 中注入 `Today's date is YYYY/MM/DD`，跨天时日期变化破坏消息前缀缓存。

**修复**: `permafrost_align.py` 新增 `stabilize_current_date()` 函数，
将日期值替换为固定值 `2000-01-01`。原理与已有的 `stabilize_metadata()` 一致。

**改动文件**: `permafrost_align.py`
- 新增 `_RE_CURRENT_DATE` 正则
- 新增 `stabilize_current_date()` 函数
- `AlignReport` 新增 `date_stabilized` 字段
- `align_request()` 中调用 `stabilize_current_date()`

**部署注意**: 修改后必须清除 `__pycache__/` 否则 Python 加载旧字节码。
```bash
rm -rf ~/.claude/plugins/cache/permafrost/permafrost/0.3.0/proxy/__pycache__/
```

"""LogNet PoC — M0 data layer for the log-network root-cause multi-agent architecture.

Implements the design in vault doc:
  claude-ops/Agent-架构模式/lognet-rootcause-multiagent-architecture.md
  (sections 三 解析器注册表 / 四 LogNet 图模型与存储选型 / 七 机制分工 / M0 验收)

Pure stdlib. Raw input logs are treated as strictly READ-ONLY.
"""

__version__ = "0.1.0"

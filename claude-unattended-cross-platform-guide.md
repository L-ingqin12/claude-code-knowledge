# Claude Code 无人值守 — 跨平台架构指南

> 覆盖 Linux Server / macOS / Windows+WSL / Docker / CI/CD / 云 VM 六大环境
> 核心原理相同，实现手段因平台而异

---

## 一、问题本质：无人值守的四个层次

```
┌──────────────────────────────────────────────────┐
│  Layer 4: 通知 — 用户如何知道发生了什么            │
│  Layer 3: 调度 — 何时触发任务                      │
│  Layer 2: 持久化 — 终端关了进程还在                 │
│  Layer 1: 权限 — 不弹确认框                        │
└──────────────────────────────────────────────────┘
```

这四个层次是**正交的**——每个层次在不同平台上有不同的解法，但都可以独立决策和组合。下面先讲通用原理，再分平台给出具体配置。

---

## 二、Layer 1（权限）— 所有平台通用的根基

无论什么平台，**消除权限弹窗**是无人值守的前置条件。

### 2.1 三层权限控制模型

```
第一层：启动参数          第二层：settings.json       第三层：Hook 脚本
--permission-mode         allow/deny 规则            before/after 钩子
     │                        │                          │
     ├─ default               ├─ "Bash(git:*): allow"    ├─ 任务前自动检查环境
     ├─ accept-edits          ├─ "Bash(rm -rf /): deny"  ├─ 任务后自动通知
     └─ bypass                └─ "WebSearch: allow"      └─ 异常时自动回滚
```

### 2.2 权限策略矩阵

| 风险级别 | permission-mode | allowlist | 适用任务 |
|----------|-----------------|-----------|----------|
| 🟢 低 | `default` + 细粒度 allow | 常规命令 | 交互式开发 |
| 🟡 中 | `accept-edits` + 通用 allow | 读写+git+npm | 代码修改、测试修复 |
| 🟠 较高 | `bypass` + deny 清单 | 仅 deny | CI 环境、可信脚本 |
| 🔴 高 | `bypass` 无限制 | 无 | **永远不推荐** |

### 2.3 通用 allow 规则模板

```json
{
  "permissions": {
    "allow": [
      "Bash(git:*)",
      "Bash(npm:*)",
      "Bash(node:*)",
      "Bash(python:*)",
      "Bash(python3:*)",
      "Bash(curl:*)",
      "Bash(wget:*)",
      "Bash(ls:*)",
      "Bash(cat:*)",
      "Bash(find:*)",
      "Bash(grep:*)",
      "Bash(mkdir:*)",
      "Bash(cp:*)",
      "Bash(mv:*)",
      "Bash(rm:*)",
      "Bash(tar:*)",
      "Bash(cd:*)",
      "Bash(echo:*)",
      "Bash(which:*)",
      "Bash(ps:*)",
      "Bash(kill:*)",
      "Bash(type:*)",
      "Bash(source:*)",
      "Bash(test:*)",
      "Bash(env:*)",
      "Bash(export:*)",
      "Bash(unset:*)",
      "Bash(nproc:*)",
      "Bash(df:*)",
      "Bash(du:*)",
      "Bash(wc:*)",
      "Bash(sort:*)",
      "Bash(uniq:*)",
      "Bash(head:*)",
      "Bash(tail:*)",
      "Bash(awk:*)",
      "Bash(sed:*)",
      "Bash(xargs:*)",
      "Read(**/*)",
      "Write(**/*)",
      "Edit(**/*)",
      "WebSearch",
      "WebFetch",
      "WebFetch(domain:github.com)",
      "WebFetch(domain:*.github.com)"
    ],
    "deny": [
      "Bash(rm -rf /)",
      "Bash(rm -rf /*)",
      "Bash(rm -rf ~)",
      "Bash(rm -rf .)",
      "Bash(>: /dev/sda*)",
      "Bash(dd if=*)",
      "Bash(git push --force:*)",
      "Bash(git push -f:*)",
      "Bash(curl * | sh:*)",
      "Bash(curl * | bash:*)",
      "Bash(wget * -O - | sh:*)",
      "Bash(:(){ :|:& };::*)",
      "Bash(chmod 777 /*)",
      "Bash(chmod -R 777 /*)",
      "Bash(shutdown:*)",
      "Bash(reboot:*)",
      "Bash(mkfs.*:*)"
    ]
  }
}
```

**关键设计原则**：
- allow 用**命令前缀匹配**（如 `Bash(git:*)`），不绑定具体参数
- deny 覆盖**危险模式**（管道到 shell、强制推送、破坏性 IO）
- 两条都要有——allow 打开大门，deny 锁住后门

### 2.4 settings 文件作用域

| 文件 | 作用域 | 适用 |
|------|--------|------|
| `~/.claude/settings.json` | 全局（所有项目） | 通用命令 allow |
| `<project>/.claude/settings.json` | 当前项目 | 项目特定 allow/deny |
| `~/.claude/settings.local.json` | 全局本地覆盖 | deny 清单（不会被 git 追踪） |

**最佳实践**：项目级 `.claude/settings.json` 提交到 git，团队共享；deny 放 `settings.local.json`。

---

## 三、Layer 2（持久化）— 分平台进程托管

核心目标：让 Claude 在用户登出、终端关闭、SSH 断开后仍然运行。

### 3.1 Linux Server (systemd) — 最推荐方案

```ini
# /etc/systemd/system/claude-daemon.service
[Unit]
Description=Claude Code Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=deploy
Group=deploy
WorkingDirectory=/home/deploy/project
Environment="HOME=/home/deploy"
Environment="PATH=/home/deploy/.local/bin:/usr/local/bin:/usr/bin:/bin"
Environment="NODE_ENV=production"

# Claude daemon 自身管理子进程，所以用 forking
ExecStart=/bin/bash -c 'claude daemon start 2>&1'
ExecStop=/bin/bash -c 'claude daemon stop 2>&1'
ExecReload=/bin/bash -c 'claude daemon restart 2>&1'

# 自动恢复
Restart=on-failure
RestartSec=10

# 资源限制
MemoryMax=4G
CPUQuota=200%

# 日志
StandardOutput=journal
StandardError=journal
SyslogIdentifier=claude-daemon

[Install]
WantedBy=multi-user.target
```

```bash
# 部署
sudo systemctl daemon-reload
sudo systemctl enable --now claude-daemon
sudo systemctl status claude-daemon

# 查看日志
journalctl -u claude-daemon -f
```

**为什么用 systemd 而不是 tmux/screen？**
- tmux 仍然绑在用户 session 上，用户登出后可能被清理
- systemd 是 PID 1 直接管理的，不受用户 session 生命周期影响
- systemd 提供自动重启、资源限制、日志集成

**tmux 方案（轻量备选）**：
```bash
# 仅当 systemd 不可用时使用
tmux new-session -d -s claude-session
tmux send-keys -t claude-session 'claude --permission-mode accept-edits' Enter
# detach: Ctrl+B, D
# reattach: tmux attach -t claude-session
```

### 3.2 macOS (launchd)

```xml
<!-- ~/Library/LaunchAgents/com.user.claude-daemon.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.claude-daemon</string>

    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/claude</string>
        <string>daemon</string>
        <string>start</string>
    </array>

    <key>WorkingDirectory</key>
    <string>/Users/deploy/project</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
        <key>HOME</key>
        <string>/Users/deploy</string>
        <key>ANTHROPIC_API_KEY</key>
        <string>{{ YOUR_API_KEY }}</string>
    </dict>

    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/Users/deploy/.claude/daemon.stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/deploy/.claude/daemon.stderr.log</string>

    <!-- 资源限制 -->
    <key>SoftResourceLimits</key>
    <dict>
        <key>NumberOfFiles</key>
        <integer>4096</integer>
    </dict>
</dict>
</plist>
```

```bash
# 部署
launchctl load ~/Library/LaunchAgents/com.user.claude-daemon.plist
launchctl start com.user.claude-daemon

# 查看状态
launchctl list | grep claude

# 卸载
launchctl unload ~/Library/LaunchAgents/com.user.claude-daemon.plist
```

**macOS 特殊注意事项**：
- `LaunchAgent` (~/Library) vs `LaunchDaemon` (/Library) — Agent 在用户登录后启动，Daemon 在系统启动时
- macOS 的 `cron` 已弃用，用 `launchd` 替代
- brew 安装的 node/claude 路径用 `/opt/homebrew/bin`（Apple Silicon）或 `/usr/local/bin`（Intel）

### 3.3 Windows (WSL2 + Task Scheduler)

Windows 是**唯一不能直接运行 Claude daemon 的平台**（没有原生 Linux 支持），必须通过 WSL2。

```
Windows
  ├── Task Scheduler (调度层)
  └── WSL2 Ubuntu
       └── Claude Code (执行层)
```

**方案A — WSL 内独立运行**：
```powershell
# PowerShell: 在 WSL 中启动 Claude daemon 并保持运行
wsl -d Ubuntu -u deploy -- bash -c '
  nohup claude daemon start > /home/deploy/.claude/daemon-nohup.log 2>&1 &
  echo $! > /home/deploy/.claude/daemon.pid
'
```

**方案B — Windows Task Scheduler 触发**：
```xml
<!-- 通过 Task Scheduler 导入或 PowerShell 创建 -->
<!-- 触发器: 系统启动时 / 用户登录时 / 定时 -->
<!-- 操作: 启动程序 wsl.exe -->
<!-- 参数: -d Ubuntu -u deploy -- bash -c 'claude -p "任务" --permission-mode accept-edits' -->
```

```powershell
# PowerShell: 创建定时任务
$Action = New-ScheduledTaskAction -Execute 'wsl.exe' `
  -Argument '-d Ubuntu -u deploy -- bash -c ''claude -p "检查项目状态并生成报告" --permission-mode accept-edits'''
$Trigger = New-ScheduledTaskTrigger -Daily -At 9am
$Principal = New-ScheduledTaskPrincipal -UserId "deploy" -LogonType ServiceAccount
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName "ClaudeCodeDailyCheck" `
  -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings
```

**方案C — NSSM 将 WSL 进程注册为 Windows Service**（不推荐，权限模型复杂）

**Windows 特殊注意事项**：
- WSL2 默认会在空闲 8 秒后关闭——需在 `.wslconfig` 中配置：
  ```ini
  # %USERPROFILE%\.wslconfig
  [wsl2]
  kernelCommandLine = vsyscall=emulate
  memory=4GB
  # 不让 WSL 自动关闭
  ```
- 如果笔记本合盖休眠，WSL 也会挂起——用 `DontStopIfGoingOnBatteries`

### 3.4 Docker / 容器

```dockerfile
# Dockerfile
FROM node:20-slim

# 安装 Claude Code
RUN npm install -g @anthropic-ai/claude-code

# 创建非 root 用户
RUN useradd -m -s /bin/bash claude
USER claude
WORKDIR /workspace

# 预设 settings（消除权限弹窗）
RUN mkdir -p /home/claude/.claude
COPY settings.json /home/claude/.claude/settings.json
COPY settings.local.json /home/claude/.claude/settings.local.json

ENTRYPOINT ["claude"]
```

```yaml
# docker-compose.yml
services:
  claude-daemon:
    build: .
    container_name: claude-daemon
    restart: unless-stopped           # ← 自动恢复
    environment:
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
    volumes:
      - ./workspace:/workspace        # 项目代码
      - ./claude-config:/home/claude/.claude  # settings + history + sessions
    command: daemon start
    healthcheck:                      # ← 健康自检
      test: ["CMD", "claude", "--version"]
      interval: 60s
      timeout: 10s
      retries: 3

  claude-cron:                        # ← 调度容器（独立进程）
    image: alpine
    restart: unless-stopped
    volumes:
      - ./cron-scripts:/scripts:ro
    entrypoint: |
      /bin/sh -c "
      echo '7 */2 * * * cd /workspace && claude -p \"检查状态\" --permission-mode accept-edits' > /etc/crontabs/root
      crond -f -l 2
      "
```

```bash
# 启动
ANTHROPIC_API_KEY=[已脱敏] docker-compose up -d

# 查看日志
docker-compose logs -f claude-daemon

# 触发一次性任务
docker-compose exec claude-daemon claude -p "你的任务" --permission-mode accept-edits
```

**Docker 注意事项**：
- `restart: unless-stopped` 是容器级自动恢复，等价于 systemd 的 `Restart=on-failure`
- `healthcheck` 可以检测 Claude 是否还活着，如果挂了 Docker 会重启容器
- 用 volume 挂载 settings 和 workspace，不要写入容器层
- API key 通过环境变量或 Docker secrets 注入，不要打在镜像里

### 3.5 Kubernetes（云原生扩展）

```yaml
# k8s/statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: claude-code
spec:
  serviceName: claude-code
  replicas: 1
  selector:
    matchLabels:
      app: claude-code
  template:
    metadata:
      labels:
        app: claude-code
    spec:
      containers:
      - name: claude
        image: your-registry/claude-code:latest
        env:
        - name: ANTHROPIC_API_KEY
          valueFrom:
            secretKeyRef:
              name: claude-secrets
              key: api-key
        volumeMounts:
        - name: workspace
          mountPath: /workspace
        - name: claude-config
          mountPath: /home/claude/.claude
        livenessProbe:
          exec:
            command: ["claude", "--version"]
          initialDelaySeconds: 30
          periodSeconds: 60
        resources:
          requests:
            memory: "512Mi"
            cpu: "500m"
          limits:
            memory: "4Gi"
            cpu: "2"
  volumeClaimTemplates:
  - metadata:
      name: workspace
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 10Gi
```

---

## 四、Layer 3（调度）— 分平台任务触发

### 4.1 调度方式对比

| 方式 | 原理 | 可靠性 | 复杂度 | 适用 |
|------|------|--------|--------|------|
| **CronCreate** (Claude 内置) | 会话内定时器 | 低（会话停=任务停） | 低 | 临时周期性任务 |
| **/loop** (Claude 内置) | 会话内自适应循环 | 低 | 低 | 探索性任务 |
| **系统 cron** | OS 级定时器 | 高 | 中 | 固定时间点的稳定任务 |
| **systemd timer** | systemd 定时器单元 | 高 | 中 | Linux 上 cron 的现代替代 |
| **launchd** | macOS 系统调度 | 高 | 中 | macOS 唯一推荐方式 |
| **Task Scheduler** | Windows 系统调度 | 高 | 高 | Windows 原生调度 |
| **CI/CD schedule** | GitHub Actions / GitLab CI | 极高 | 低 | 代码仓库相关任务 |
| **外部事件触发** | webhook / MQ / DB trigger | 极高 | 高 | 事件驱动任务 |

### 4.2 组合策略

**不建议**只用一种方式，推荐组合：

```
固定周期任务（报告、检查）    →  系统 cron / systemd timer
变化响应任务（CI失败、新PR）  →  CI/CD schedule + webhook
自适应任务（调试、探索）      →  /loop (交互式)
一次性任务（手动触发）         →  claude -p
```

### 4.3 各平台 cron 示例

**Linux cron** ：
```bash
# crontab -e
# 每天早上 9 点 — 拉取所有仓库并运行测试
0 9 * * * cd /home/deploy/project && claude -p "git pull --rebase && 运行测试，如果失败自动修复" --permission-mode accept-edits >> /var/log/claude-cron.log 2>&1

# 每 2 小时 — 检查 CI
7 */2 * * * cd /home/deploy/project && claude -p "检查 CI 状态" --permission-mode bypass >> /var/log/claude-ci-check.log 2>&1

# 每天晚上 — 清理旧日志
0 23 * * * find /var/log/claude-*.log -mtime +7 -delete
```

**systemd timer**（比 cron 更现代的选择）：
```ini
# /etc/systemd/system/claude-daily-check.timer
[Unit]
Description=Daily Claude Code check
Requires=claude-daemon.service

[Timer]
OnCalendar=daily
Persistent=true          # 如果错过时间点（机器关了），启动后补上
RandomizedDelaySec=300   # 随机延迟避免峰值

[Install]
WantedBy=timers.target
```

```ini
# /etc/systemd/system/claude-daily-check.service
[Unit]
Description=Claude Code Daily Check

[Service]
Type=oneshot
User=deploy
WorkingDirectory=/home/deploy/project
ExecStart=/usr/local/bin/claude -p "每日检查：git pull && 测试 && 生成日报" --permission-mode accept-edits
```

**macOS launchd 定时**：
```xml
<!-- ~/Library/LaunchAgents/com.user.claude-daily.plist -->
<key>StartCalendarInterval</key>
<dict>
    <key>Hour</key><integer>9</integer>
    <key>Minute</key><integer>7</integer>
</dict>
```

**GitHub Actions 定时**：
```yaml
# .github/workflows/claude-automation.yml
name: Claude Automation
on:
  schedule:
    - cron: '7 */2 * * *'   # 每 2 小时
  workflow_dispatch:         # 手动触发

jobs:
  claude-auto-fix:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: anthropics/claude-code-action@v1
        with:
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
          permission-mode: 'bypass'
          prompt: |
            检查最近一次 CI 运行的结果。
            如果有失败的测试，分析原因并尝试修复。
            如果修复成功，提交并推送。
            如果无法修复，在 issue 中记录详细分析。
```

---

## 五、Layer 4（通知）— 多渠道触达

### 5.1 通知渠道矩阵

| 渠道 | 实时性 | 可靠性 | 平台 | 配置难度 |
|------|--------|--------|------|----------|
| Claude PushNotification | 即时 | 中（需 daemon 在线） | 全平台 | 极低 |
| 企业微信/Slack/Discord Webhook | 即时 | 高 | 全平台 | 低 |
| 邮件 (sendmail/msmtp) | 近即时 | 高 | Linux/macOS | 中 |
| ntfy.sh / Gotify | 即时 | 极高 | 全平台（自建） | 中 |
| 系统通知 (notify-send / osascript) | 即时 | 低（需桌面登录） | Linux/macOS | 极低 |
| SMS / 电话 (Twilio) | 即时 | 极高 | 全平台 | 高 |
| Telegram Bot | 即时 | 高 | 全平台 | 低 |
| 云监控 (CloudWatch/PagerDuty) | 即时 | 极高 | 云环境 | 高 |

### 5.2 通知实现示例

**方案A — Claude PushNotification（零配置）**：
```
# 在 prompt 中直接指示
帮我重构 gomoku 的 AI 模块。完成后用 PushNotification 通知我结果。
如果过程中遇到无法自动解决的问题，立即 PushNotification 通知我。
```

**方案B — Webhook 通知（推荐用于生产）**：
```bash
# 包装函数，放在 ~/.bashrc 或独立脚本
claude-with-notify() {
    local task="$1"
    local webhook_url="https://hooks.slack.com/services/xxx"

    # 任务开始通知
    curl -s -X POST "$webhook_url" \
        -H 'Content-Type: application/json' \
        -d "{\"text\":\"🤖 Claude 开始执行: $task\"}"

    # 执行任务
    local logfile="/tmp/claude-task-$(date +%s).log"
    if claude -p "$task" --permission-mode accept-edits > "$logfile" 2>&1; then
        local summary=$(tail -20 "$logfile")
        curl -s -X POST "$webhook_url" \
            -H 'Content-Type: application/json' \
            -d "{\"text\":\"✅ Claude 任务完成: $task\n\n\`\`\`$summary\`\`\`\"}"
    else
        curl -s -X POST "$webhook_url" \
            -H 'Content-Type: application/json' \
            -d "{\"text\":\"❌ Claude 任务失败: $task\n查看日志: $logfile\"}"
    fi
}

# 使用
claude-with-notify "检查所有仓库，修复失败的测试"
```

**方案C — ntfy.sh（极简自建通知）**：
```bash
# 一次配置，全平台使用
# 在手机上装 ntfy app，订阅 topic

claude-notify() {
    curl -s -H "Title: Claude Task" \
         -H "Priority: high" \
         -H "Tags: robot" \
         -d "$1" \
         ntfy.sh/your-private-topic
}

# Claude 任务中调用
claude -p "检查 CI。如果发现问题，执行: curl -s -H 'Title: CI Failure' -d '需要人工介入' ntfy.sh/my-topic" \
    --permission-mode accept-edits
```

**方案D — Telegram Bot**：
```bash
# 前提：创建 Telegram Bot 并获取 chat_id
BOT_TOKEN="xxx"
CHAT_ID="xxx"

tg-notify() {
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -H 'Content-Type: application/json' \
        -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"$1\",\"parse_mode\":\"Markdown\"}"
}
```

### 5.3 通知分级策略

```
🔴 Critical  → 多渠道同时发（Slack + SMS + Telegram）
   条件: 生产环境故障、API key 失效、daemon 崩溃
   
🟠 Warning  → Webhook + PushNotification
   条件: 测试失败、构建中断、依赖有安全漏洞
   
🟡 Info     → Claude 会话内记录
   条件: 任务完成、定期报告

🟢 Debug    → 仅写日志文件
   条件: 每次执行的详细输出
```

---

## 六、六大平台完整配置清单

### 6.1 标准 Linux Server

```bash
# 1) 安装 Claude Code
npm install -g @anthropic-ai/claude-code

# 2) 配置权限
cat > ~/.claude/settings.local.json << 'EOF'
{
  "permissions": {
    "allow": [
      "Bash(git:*)","Bash(npm:*)","Bash(python:*)","Bash(node:*)",
      "Bash(curl:*)","Bash(ls:*)","Bash(cat:*)","Bash(find:*)",
      "Bash(grep:*)","Bash(mkdir:*)","Bash(cp:*)","Bash(mv:*)",
      "Bash(rm:*)","Bash(tar:*)","Bash(echo:*)","Bash(ps:*)",
      "Bash(kill:*)","Bash(which:*)",
      "Read(**/*)","Write(**/*)","Edit(**/*)",
      "WebSearch","WebFetch"
    ],
    "deny": [
      "Bash(rm -rf /:*)","Bash(rm -rf /*:*)",
      "Bash(git push --force:*)","Bash(shutdown:*)","Bash(reboot:*)",
      "Bash(dd if=*:*)","Bash(curl * | sh:*)","Bash(curl * | bash:*)"
    ]
  }
}
EOF

# 3) 创建 systemd 服务
sudo tee /etc/systemd/system/claude-daemon.service << 'EOF'
[Unit]
Description=Claude Code Daemon
After=network-online.target

[Service]
Type=forking
User=deploy
WorkingDirectory=/home/deploy/project
Environment="HOME=/home/deploy"
Environment="PATH=/home/deploy/.local/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=/bin/bash -c 'claude daemon start'
ExecStop=/bin/bash -c 'claude daemon stop'
Restart=on-failure
RestartSec=15
MemoryMax=4G

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now claude-daemon

# 4) 设置 cron
(crontab -l 2>/dev/null; echo '7 */2 * * * cd /home/deploy/project && claude -p "检查状态并修复" --permission-mode accept-edits >> /var/log/claude-cron.log 2>&1') | crontab -

# 5) 验证
ps aux | grep claude
systemctl status claude-daemon
claude -p "回复: ok" --model claude-haiku-4-5
```

### 6.2 macOS

```bash
# 1) 安装
brew install node
npm install -g @anthropic-ai/claude-code

# 2) 配置权限（同上，略）

# 3) 创建 LaunchAgent
cat > ~/Library/LaunchAgents/com.user.claude-daemon.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.claude-daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/claude</string>
        <string>daemon</string>
        <string>start</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>WorkingDirectory</key>
    <string>/Users/deploy/project</string>
    <key>StandardOutPath</key>
    <string>/Users/deploy/.claude/daemon.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/deploy/.claude/daemon.err</string>
</dict>
</plist>
EOF

launchctl load ~/Library/LaunchAgents/com.user.claude-daemon.plist

# 4) 用 launchd 做定时（每2小时）
# 再创建一个 StartCalendarInterval 的 plist，指向 shell 脚本调用 claude -p

# 5) 验证
launchctl list | grep claude
```

### 6.3 Windows + WSL2

```powershell
# === PowerShell 管理员 ===

# 1) WSL 中安装 Claude Code
wsl -d Ubuntu -- bash -c 'npm install -g @anthropic-ai/claude-code'

# 2) WSL 中配置 settings（同上，在 WSL 内操作）

# 3) 配置 WSL 不自动休眠
@"
[wsl2]
memory=4GB
"@ | Out-File -FilePath "$env:USERPROFILE\.wslconfig" -Encoding utf8

# 4) 创建计划任务
$action = New-ScheduledTaskAction -Execute 'wsl.exe' -Argument @'
-d Ubuntu -u root -- bash -c "claude -p '检查项目状态' --permission-mode accept-edits >> /var/log/claude-scheduled.log 2>&1"
'@
$trigger = New-ScheduledTaskTrigger -Daily -At 9am
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName "ClaudeCodeDaily" -Action $action -Trigger $trigger -Settings $settings

# 5) 启动 WSL 内 daemon
wsl -d Ubuntu -- bash -c 'nohup claude daemon start > /root/.claude/daemon.log 2>&1 &'
```

### 6.4 Docker

```bash
# docker-compose.yml（完整内容见第三章 3.4）
# 启动
ANTHROPIC_API_KEY=[已脱敏] docker-compose up -d

# 触发一次性任务
docker-compose exec claude-daemon claude -p "运行完整测试" --permission-mode accept-edits

# 查看日志
docker logs -f claude-daemon
```

### 6.5 CI/CD (GitHub Actions)

```yaml
# .github/workflows/claude-auto-maintain.yml
name: Claude Auto Maintain
on:
  schedule:
    - cron: '0 9 * * *'  # 每天早上
  issues:
    types: [opened, labeled]  # 新 issue 或贴 "claude-fix" 标签时触发

jobs:
  claude:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Claude Auto Fix
        uses: anthropics/claude-code-action@v1
        with:
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
          permission-mode: 'bypass'
          prompt: |
            ${{ github.event_name == 'schedule' && '每日检查：运行测试，修复失败。' || '' }}
            ${{ github.event_name == 'issues' && '检查新 issue，尝试自动修复并回复。' || '' }}
```

### 6.6 云 VM

```
本质上和「标准 Linux Server」相同。
增量：使用云厂商的通知/监控服务。
  - AWS: CloudWatch Logs + SNS
  - GCP: Cloud Logging + Pub/Sub
  - 阿里云: 日志服务 + 短信/钉钉通知
```

---

## 七、架构模式总结

### 7.1 四种核心模式

```
Pattern 1: Daemon + Cron
┌──────────────────────────────────────┐
│  systemd / launchd / Docker          │ ← 进程托管
│    └── claude daemon                 │ ← 始终保持在线
│         ├── session-1 (/loop ...)    │ ← 自适应任务
│         └── session-2 (CronCreate)   │ ← 定时任务
│                                       │
│  cron / systemd timer / Task Sched  │ ← 外部触发器
│    └── claude -p "..."               │ ← 一次性任务
└──────────────────────────────────────┘
适用: 最完整的方案，兼顾持久化和定时

Pattern 2: CI/CD Pipeline
┌──────────────────────────────────────┐
│  GitHub Actions schedule              │
│    └── checkout repo                  │
│         └── claude -p "..." --bypass  │ ← 每次都是全新环境
│              └── commit + push        │
└──────────────────────────────────────┘
适用: 代码仓库相关任务，零运维负担

Pattern 3: Event-Driven
┌──────────────────────────────────────┐
│  Webhook / MQ / DB change event       │
│    └── trigger script                 │
│         └── claude -p "..." --bypass  │
│              └── notification         │
└──────────────────────────────────────┘
适用: 响应式任务，CI失败→自动修复

Pattern 4: Container Orchestration
┌──────────────────────────────────────┐
│  K8s CronJob                          │
│    └── Pod: claude image              │
│         └── claude -p "..." --bypass  │
│              └── push result          │
└──────────────────────────────────────┘
适用: 云原生环境，弹性伸缩
```

### 7.2 选型决策树

```
需要做什么?
├── 代码修改+提交推送 → CI/CD Pipeline (GitHub Actions)
├── 持续监控+响应     → Daemon + Cron 模式
├── 定时报告+检查     → Cron / systemd timer + claude -p
├── 响应外部事件      → Event-Driven (webhook)
└── 探索性自适应任务 → /loop (交互式, 不可持久化)
```

---

## 八、可靠性检查清单

无论哪个平台，部署后逐项验证：

- [ ] `claude -p "回复 ok" --permission-mode accept-edits` 能无交互执行
- [ ] 进程托管方式（systemd/launchd/Docker）重启后 daemon 自动拉起
- [ ] deny 规则覆盖了 `rm -rf /`、`git push --force` 等危险操作
- [ ] 日志有轮转策略（不会无限膨胀）
- [ ] 至少有一个通知渠道能在故障时触达用户
- [ ] API key 不在 git 历史或公开配置中
- [ ] 有销毁开关（kill daemon / stop container）
- [ ] 恢复流程文档化（daemon 挂了怎么救）

---

## 附录：平台能力速查

| 能力 | Linux | macOS | Windows | Docker | CI/CD |
|------|-------|-------|---------|--------|-------|
| 进程托管 | systemd | launchd | NSSM/Task Sched | restart policy | N/A (ephemeral) |
| 定时调度 | cron/systemd timer | launchd | Task Scheduler | cron container | schedule trigger |
| 终端复用 | tmux/screen | tmux/screen | WSL tmux | N/A | N/A |
| 桌面通知 | notify-send | osascript | toast | N/A | Slack/email |
| 自动恢复 | Restart=on-failure | KeepAlive | Restart on failure | restart: always | N/A |
| 开机自启 | systemd enable | RunAtLoad | Boot trigger | restart: always | N/A |
| 日志管理 | journald | 文件 | 事件查看器 | stdout/stderr | Actions log |
| 资源限制 | cgroup | launchd limits | Job limits | docker limits | runner limits |

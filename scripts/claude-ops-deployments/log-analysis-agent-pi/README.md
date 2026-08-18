# 日志分析 Agent 服务 — Pi Agent 版部署指南

> 引擎: Pi Agent (TypeScript SDK) | 平台: Windows
> 方案: `plans/pi-agent-log-analysis-plan.md`
> 对比: `deployments/log-analysis-agent/` (opencode 版)

---

## 与 opencode 版的关键差异

| 维度 | Pi Agent 版 (本目录) | opencode 版 |
|------|:---:|:---:|
| 语言 | TypeScript (Node.js) | Python |
| Agent 集成 | SDK in-process | subprocess |
| 多进程 | Node.js cluster | 手动多端口 |
| 服务注册 | 1 个 Primary 服务 | 4 个独立 Worker 服务 |
| 启动命令 | `node dist/cluster-server.js` | `python app.py --port N` |

## 目录结构

```
deployments/log-analysis-agent-pi/
├── README.md
├── package.json
├── tsconfig.json
├── src/
│   ├── server.ts              # Express HTTP 服务
│   ├── cluster-server.ts      # Cluster 多进程管理
│   ├── agent-service.ts       # Pi Agent SDK 封装
│   ├── fanout-service.ts      # Fan-Out 多维度并行 (可选)
│   └── analysis/
│       ├── prompt.ts           # 系统提示词 (≤800 tokens)
│       └── result-parser.ts   # JSON 结果解析
├── skills/log-analysis/       # Pi Skills (渐进式加载)
│   ├── SKILL.md
│   ├── error-patterns.md
│   ├── security-threats.md
│   └── performance.md
├── configs/
│   └── nginx.conf
└── scripts/
    ├── start-workers.ps1
    ├── stop-workers.ps1
    ├── install-services.ps1
    └── health-monitor.ps1
```

## 快速开始

### 1. 环境准备

```powershell
# Node.js ≥18
node --version

# 安装依赖
cd deployments/log-analysis-agent-pi
npm install

# 编译 TypeScript
npm run build

# 安装 NSSM (可选, 服务化)
choco install nssm

# Nginx for Windows
# 下载并解压到 C:\nginx
```

### 2. 配置 Pi Agent 认证

```powershell
# Pi Agent 使用 ~/.pi/agent/ 目录存储认证信息
# 首次运行 pi CLI 完成认证配置，或手动创建:
mkdir ~/.pi/agent
```

### 3. TCP/IP 调优 (管理员, 仅一次)

```powershell
# 使用 opencode 版同款脚本
powershell -ExecutionPolicy Bypass -File ..\log-analysis-agent\scripts\win-tcp-tuning.ps1
# 重启系统
```

### 4. 启动

```powershell
# 生产模式
.\scripts\start-workers.ps1 -WorkerCount 4

# 开发模式 (tsx 热加载)
.\scripts\start-workers.ps1 -DevMode
```

### 5. 配置 Nginx

```powershell
copy configs\nginx.conf C:\nginx\conf\nginx.conf
C:\nginx\nginx -t
C:\nginx\nginx
```

### 6. 验证

```powershell
# Worker 健康检查
curl http://[IP已脱敏]:8801/api/health
curl http://[IP已脱敏]:8802/api/health

# 通过 Nginx
curl http://[IP已脱敏]/api/health

# 提交分析
curl -X POST http://[IP已脱敏]/api/analyze `
  -H "Content-Type: application/json" `
  -d '{"log_content":"ERROR: connection timeout after 30s"}'
```

### 7. 安装为 Windows 服务 (可选)

```powershell
.\scripts\install-services.ps1 -Install
.\scripts\install-services.ps1 -Start
.\scripts\install-services.ps1 -Status
```

## 运维命令

| 操作 | 命令 |
|------|------|
| 编译 | `npm run build` |
| 启动 (生产) | `.\scripts\start-workers.ps1` |
| 启动 (开发) | `.\scripts\start-workers.ps1 -DevMode` |
| 停止 | `.\scripts\stop-workers.ps1` |
| 重载 Nginx | `C:\nginx\nginx -s reload` |
| 查看端口 | `netstat -ano \| findstr "8801 8802 8803 8804"` |
| 查看日志 | `Get-Content C:\nginx\logs\access.log -Tail 50` |

## 健康监控

```powershell
# 配合 Task Scheduler 每分钟执行
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -File C:\path\to\scripts\health-monitor.ps1"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName "LogAgent-Pi-Monitor" `
    -Action $action -Trigger $trigger -RunLevel Highest
```

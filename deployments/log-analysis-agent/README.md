# 日志分析 Agent 服务 — 部署指南

> 部署路径: `deployments/log-analysis-agent/`
> 相关方案: `plans/log-analysis-agent-windows-plan.md`

---

## 目录结构

```
deployments/log-analysis-agent/
├── README.md                    ← 本文件
├── configs/
│   └── nginx.conf               ← Nginx 完整配置
└── scripts/
    ├── app.py                   ← Tornado 应用 (核心)
    ├── start-workers.ps1        ← 启动多 Worker PowerShell
    ├── stop-workers.ps1         ← 停止所有 Worker
    ├── win-tcp-tuning.ps1       ← Windows TCP/IP 调优 (需管理员)
    ├── install-services.ps1     ← NSSM 服务安装/管理
    └── health-monitor.ps1       ← 健康监控 + 自动重启
```

## 快速开始

### 1. 环境准备

```powershell
# 安装 Python 依赖
pip install tornado

# 安装 NSSM (Windows Service 管理)
choco install nssm

# 下载 Nginx for Windows
# https://nginx.org/en/download.html
# 解压到 C:\nginx
```

### 2. TCP/IP 调优 (管理员, 仅一次)

```powershell
# 以管理员身份运行 PowerShell
powershell -ExecutionPolicy Bypass -File scripts\win-tcp-tuning.ps1
# 重启系统使参数生效
```

### 3. 启动 Workers

```powershell
# 启动 4 个 Tornado Worker (端口 8801-8804)
.\scripts\start-workers.ps1 -WorkerCount 4 -AgentTimeout 60
```

### 4. 配置并启动 Nginx

```powershell
# 复制配置
copy configs\nginx.conf C:\nginx\conf\nginx.conf

# 验证配置
C:\nginx\nginx -t

# 启动
C:\nginx\nginx
```

### 5. 验证

```powershell
# 健康检查
curl http://127.0.0.1/api/health

# 提交分析
curl -X POST http://127.0.0.1/api/analyze `
  -H "Content-Type: application/json" `
  -d '{"log_content":"ERROR: connection timeout after 30s"}'
```

### 6. 安装为 Windows 服务 (可选)

```powershell
.\scripts\install-services.ps1 -Install
.\scripts\install-services.ps1 -Start
.\scripts\install-services.ps1 -Status
```

### 7. 设置健康监控 (可选)

```powershell
# 配合 Windows Task Scheduler 每分钟执行
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -File C:\path\to\scripts\health-monitor.ps1"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName "LogAgent-Health-Monitor" `
    -Action $action -Trigger $trigger -RunLevel Highest
```

## 运维命令速查

| 操作 | 命令 |
|------|------|
| 启动所有 Worker | `.\scripts\start-workers.ps1` |
| 停止所有 Worker | `.\scripts\stop-workers.ps1` |
| 重载 Nginx 配置 | `C:\nginx\nginx -s reload` |
| 查看服务状态 | `.\scripts\install-services.ps1 -Status` |
| 手动健康检查 | `.\scripts\health-monitor.ps1 -NoRestart` |
| 查看 Nginx 访问日志 | `Get-Content C:\nginx\logs\access.log -Tail 50` |
| 查看端口占用 | `netstat -ano \| findstr "8801 8802 8803 8804"` |
| 查看 TIME_WAIT 数 | `netstat -ano \| findstr "TIME_WAIT" \| Measure-Object` |

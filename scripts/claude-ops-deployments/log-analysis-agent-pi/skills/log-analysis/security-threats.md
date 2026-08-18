# 安全威胁知识库

## 威胁分类

### 1. 认证攻击

| 模式 | 特征 | 风险 |
|------|------|------|
| 暴力破解 | 同一账户高频失败 (>10次/分钟) | 🔴 high |
| 凭据填充 | 多个不同账户从同一 IP 尝试 | 🔴 high |
| 会话劫持 | 同一 token 从不同 IP 使用 | 🔴 critical |
| JWT 伪造 | 无效签名、过期 token 大量出现 | 🟡 medium |

**检测方法**:
```bash
# 高频失败认证
grep "login failed\|auth failed\|unauthorized" | awk '{print $IP}' | sort | uniq -c | sort -rn | head -20

# 多账户同 IP
grep "login" | awk '{print $IP, $USER}' | sort -u | awk '{print $1}' | uniq -c | awk '$1 > 5'
```

### 2. 注入攻击

| 模式 | 特征 | 日志证据 |
|------|------|---------|
| SQL 注入 | `' OR '1'='1`, `UNION SELECT`, `DROP TABLE` | 请求参数中包含 SQL 关键字 |
| 命令注入 | `; rm -rf`, `| cat /etc/passwd`, `$(whoami)` | 输入中出现 shell 控制字符 |
| XSS | `<script>`, `javascript:`, `onerror=` | HTML/JS 在输入参数中 |
| 路径遍历 | `../../../etc/passwd`, `..%2f..%2f` | 路径中包含 `../` |
| LDAP 注入 | `*)(uid=*))`, `(|(uid=*` | LDAP 过滤语法在输入中 |
| 模板注入 | `{{7*7}}`, `${{7*7}}`, `<%= 7*7 %>` | 模板引擎语法在输入中 |

### 3. 扫描与探测

| 模式 | 特征 |
|------|------|
| 端口扫描 | 同一 IP 短时间内访问多个端口 |
| 目录枚举 | 大量 404 响应，路径为常见字典 |
| 漏洞扫描 | User-Agent 包含 `nmap`, `nikto`, `nessus`, `sqlmap` |
| API 探测 | 尝试常见 API 路径 `/admin`, `/api/v1`, `/swagger`, `/.env` |

**检测方法**:
```bash
# 扫描器 User-Agent
grep -E "nmap|nikto|nessus|sqlmap|burp|zap|acunetix" access.log

# 目录枚举 (大量 404)
awk '$9 == 404 {print $7}' access.log | sort | uniq -c | sort -rn | head -20

# 同一 IP 访问大量不同路径
awk '{print $1, $7}' access.log | sort -u | awk '{print $1}' | uniq -c | awk '$1 > 50'
```

### 4. 数据泄露

| 模式 | 特征 |
|------|------|
| 异常数据量 | 响应体积远大于正常值 (>3σ) |
| 批量导出 | 短时间内大量 GET 请求返回 200 |
| 脱库痕迹 | `SELECT * FROM users` 或全表扫描日志 |

### 5. 异常 IP 与地理位置

| 标记条件 | 风险 |
|---------|------|
| 已知恶意 IP 段 | 🔴 high |
| 异常地理位置 (如内部服务从未访问的国家) | 🟡 medium |
| Tor 出口节点 | 🟡 medium |
| 代理/VPN IP | 🟡 medium |
| 云服务商 IP (非正常业务来源) | 🟡 medium |

### 6. 误报风险提醒

以下情况可能是正常的，不要标记为安全威胁:
- 健康检查探针 (kube-probe, ELB health check)
- 内部监控系统的定时请求
- 爬虫 (Googlebot, Bingbot) 的正常抓取
- CDN 回源请求
- Webhook 回调 (Stripe, GitHub, Slack)

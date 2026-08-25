---
title: 基座开发需求分析与选型：OpenCode vs Pi Agent
aliases: [Agent基座选型, 基座开发分析, OpenCode Pi Agent 选型]
tags: [ai/ops, ai/agent]
created: 2026-08-25
updated: 2026-08-26
status: review
---

# 基座开发需求分析与选型：OpenCode vs Pi Agent

> [!abstract] 概述
> 以七个维度（基座选型、预处理能力、触发与路由、并行性能、复杂格式、团队协作、**对外服务化**）分析在 OpenCode 与 Pi Agent 两个框架基座上做二次开发的可行路径。核心结论：采用**双层基座**——OpenCode 作"交互基座"（配置驱动、团队共享、升级友好），预处理与重负载逻辑作"外挂服务"（独立进程，经 MCP/HTTP 暴露），Pi Agent 作为"嵌入式推理引擎"备选；对外提供**双形态服务**（用户交互式 SSE 流式 + 服务器端非交互工具化 RPC），以会话池 + 流水排布 + 背压支撑高并发。

See also: [[pi-agent-framework-knowledge]] · [[pi-agent-constraints-reference]] · [[opencode-multi-agent-architecture]] · [[log-analysis-agent-windows-architecture]] · [[main-subagent-realtime-interaction]] · [[Claude-Ops-KB-Home]]

## 一、需求清单（七维度）

| # | 维度 | 具体需求 |
|---|------|---------|
| 1 | 基座选型 | 长期可持续（社区活跃、升级友好）、深度定制（业务逻辑层灵活扩展）、团队易上手共享协作（**配置驱动优于代码钩子**） |
| 2 | 预处理能力 | 文件解压（ZIP/RAR 等）+ 数据解密（多算法）；**解压出的目录结构进上下文供推理，解密明文不进上下文（按需取用）** |
| 3 | 触发与路由 | 预处理对指定 Agent 生效（非全局）；关键字检测直接触发外部服务，**短路 LLM** |
| 4 | 并行与性能 | 解压(取结构)∥解密(取数据)并行；超大文件 >500MB 防 OOM；极致 TTFT 与吞吐 |
| 5 | 复杂格式 | 嵌套加密压缩包（加密包内还有加密文件）；**运行环境跨平台**：Windows 先发（业务现场），Linux 服务端生产部署为目标，兼顾 macOS 开发机 |
| 6 | 团队协作 | 新人上手快（配置优先）；底层逻辑封装为独立服务（胶水代码原则）；易维护可测试 |
| 7 | 对外服务化 | 双形态：普通用户**交互服务** + 服务器端**非交互工具化 Agent**（外部系统检测到问题→调用取结论）；整体重负载；提高对外并发与**系统级多会话流水排布** |

## 二、选型结论（先说答案）

> [!tip] 推荐：双层基座，而非二选一
>
> ```
> 用户 / 外部系统
>   │ HTTP(SSE) / RPC
> ┌─▼────────────────────────────────────────────┐
> │ 服务网关层  Nginx + Router（鉴权/限流/关键字短路）│ ← 维度3·7
> ├──────────────────────────────────────────────┤
> │ 交互基座    OpenCode（headless/server 或 CLI）   │ ← 维度1·3·6
> │   agent/*.md + opencode.json + skills 入 git    │
> ├──────────────────────────────────────────────┤
> │ 外挂服务    预处理 Sidecar（解压/解密/manifest）   │ ← 维度2·4·5
> │   独立进程，经 MCP tool / HTTP 暴露给基座          │
> ├──────────────────────────────────────────────┤
> │ 推理引擎    provider 池 + token bucket + 缓存亲和 │ ← 维度7
> └──────────────────────────────────────────────┘
> 备选：Pi Agent SDK 进程内嵌入，替换"交互基座+外挂服务"
> 之间的边界（取舍依据见 §二判断项；风险见 §七风险登记簿）
> ```

| 判断项 | OpenCode | Pi Agent | 结论 |
|--------|----------|----------|------|
| 社区/可持续 | 活跃社区、发布节奏快、文档全 | 单人主导（badlogic），monorepo 小而稳 | OpenCode ✓ |
| 配置驱动定制 | `opencode.json` + `agent/*.md` + skills 全文件化 | 定制=写 TypeScript extension | OpenCode ✓（维度1/6 决定性） |
| 深度定制上限 | JS 插件 hook 面 + MCP sidecar | 进程内全控制、事件系统 25+ | Pi 上限高但成本高 |
| 服务端无头运行 | server 模式 + SDK 客户端 | SDK 天然 in-process，无头即默认 | Pi ✓（纯后端场景） |
| 权限/审批 | 内置 permission 体系 | 无内置（靠容器） | OpenCode ✓ |

**风险对冲**：业务逻辑全部放外挂服务与配置层，**禁止 fork 平台内核**——两基座都可随上游升级（对照 [[deploy-workflow-write-to-repo-first]] 先仓库后部署纪律）。

## 三、维度 2·4·5：预处理管线设计

### 3.1 总体数据流（结构入上下文，明文不进上下文）

```
输入文件(可能嵌套加密封包)
  │
  ▼
[预处理 Sidecar] ──双通道并行──┬─ 结构通道(快): 解压遍历目录树 → manifest.json
  │                           │   {path,size,mtime,sha256前缀,is_encrypted,alg,keyRef}
  │                           └─ 数据通道(慢): 解密校验 → 加密暂存区(明文不落盘)
  │                                  (或解密到受保护临时区, LRU 缓存)
  ▼
manifest 注入 Agent 上下文（几百~几千 token 的树形摘要）
  │
  ▼
Agent 经 secure_read(path, range?) 工具按需取片段：
  Sidecar 现场解密 → 只返回请求窗口 → 明文片段才进入上下文
```

三条铁律：

1. **manifest 是唯一进上下文的预处理产物**——树形 JSON 控制在预算内（对照 [[pi-agent-constraints-reference]] 的渐进式披露哲学：结构先给，内容按需）；
2. **明文只在两个地方存在**：Sidecar 内存窗口、受保护的临时区（NTFS 加密盘 + 任务结束 shred）；`read` 类通用工具对明文区禁读（白名单路由到 secure_read）；
3. **keyRef 解耦**——manifest 里只存密钥引用不存密钥，密钥管理走 DPAPI/KMS，审计日志记录每次解密访问。

### 3.2 格式与算法矩阵（Windows）

| 环节 | 方案 | 要点 |
|------|------|------|
| ZIP | .NET `ZipArchive` / Python `zipfile` 流式逐 entry | 逐条目流式拷贝，恒定内存；支持 ZipCrypto/AES-ZIP 检测 |
| RAR | `unrar.exe` / `7z.exe` 子进程落盘 | RAR 无法真流式 → 解到临时区再流式读；unrar 许可证只允许解压不允许重建压缩包 |
| 对称解密 | AES-GCM（有认证标签，分块需整体缓冲）/ AES-CTR（真流式，配合 HMAC） | 大文件优先 CTR+HMAC 或分段 GCM |
| 非对称 | RSA/ECIES 信封加密：RSA 包 AES 会话钥，数据走 AES | 混合体系是嵌套包的标配 |
| 国密可选 | SM4/SM2 | 若合规需要，接口层抽象 cipher provider |
| 密钥存储 | Windows DPAPI / KMS / Vault | 密钥永不进 manifest 与上下文 |

### 3.3 >500MB 防 OOM 与三闸门

- **恒定缓冲**：所有解压/解密路径均为流式（64KB–1MB chunk），禁用"整个文件读进内存"API；
- **背压**：数据通道消费慢时阻塞生产者，临时区配额超限即暂停；
- **zip-bomb 三闸门**（嵌套包必需）：单包压缩比 ≤ 阈值（如 500×）、递归深度 ≤5、全局解压总量预算（如 ≤20GB/任务），任一越界立即熔断并上报；
- **AV 干扰**：预处理临时目录加入 Defender 排除列表，否则实时扫描会让大文件吞吐掉一个数量级（实测常见坑）。

### 3.4 TTFT 优化序列

1. 收到请求 → **立刻回执任务 ID + 结构通道完成后先推 manifest 树**（首字 = 目录树，秒级）；
2. 数据通道后台继续预热高频文件的解密缓存；
3. Sidecar 常驻进程池（避免每次冷启动 JIT/加载密钥）；
4. 结果缓存：`(input_hash, path, range)` → 明文窗口 LRU。

## 四、维度 1·3·6：基座扩展机制映射

### 4.1 需求 → OpenCode 扩展面

| 需求 | OpenCode 落点 | 性质 |
|------|--------------|------|
| 预处理对指定 Agent 生效 | `agent/*.md` 中 tools 白名单：仅预处理编排 agent 开启 `secure_*` 工具族，其他 agent 不可见 | 配置 ✓ |
| 关键字短路 LLM | 两级：(a) 服务网关 Router 层关键词表命中→直调外部服务→直接返回（零 token）；(b) 会话内插件 `chat.message` hook 改写注入 | 配置表 + 少量胶水 |
| 业务逻辑扩展 | MCP server 暴露预处理能力（工具以 `<server>_<tool>` 前缀暴露；二进制取证无 `mcp__` 分隔符，见 [[参考-OpenCode-技术调研报告]] §11.2），Sidecar 语言不限（Python/C# 均可） | 独立服务 ✓ |
| 权限治理 | `permission` 配置（edit/bash/网络按 family，last-match）限制基座自身写权限 | 配置 ✓ |
| 团队共享 | 以上全部是 git 内文件，新人 clone 即得 | 配置 ✓ |

### 4.2 需求 → Pi Agent 扩展面

| 需求 | Pi Agent 落点 |
|------|--------------|
| 自定义工具 | extension `defineTool<TParams extends TSchema>` 注册自定义工具（**TypeBox JSON Schema 契约，非 zod**——0.84.3 源码核验，见 [[参考-Pi-Agent-技术调研报告]] §11），secure_read 即一个自定义工具 |
| 按 agent 生效 | extension 在 binding 阶段按 session/agent 注入不同工具集 |
| 关键字短路 | extension 拦截用户输入事件，命中即改写为确定性结果消息（25+ 事件类型支持转换用户输入） |
| 服务端嵌入 | `createAgentSession({sessionManager})` 直接活在你的 Node 服务里，无头天然 |
| 系统提示词 | ~800 token 预算 → manifest 注入必须走工具返回而非 system prompt |

### 4.3 关键字短路的工程细节

```
请求 ──→ [Router 关键词表(正则, git 管理)]
           ├─ 命中"确定性意图" → 直调外部服务 → 组装响应（TTFT ≈ 服务 RT，0 token）
           └─ 未命中 → 正常进基座 LLM 循环
                         └─（第二道）chat.message hook 再查一次表兜底
```

> [!warning] 短路的边界
> 只短路**输出可枚举**的意图（状态查询、固定报表、已知故障码解释）。模糊语义强行关键词匹配会造成错误路由——宁可多花一次 LLM 调用。规则表必须有灰度开关与命中统计，防止规则腐化。

### 4.4 团队协作落地清单

- 配置资产入 git：`opencode.json` / `agent/*.md` / `skills/` / Router 关键词表 / Sidecar 的 `preprocess.yaml`；
- Sidecar 独立仓库 + 语义化版本 + OpenAPI 契约；基座侧只认契约不认实现（胶水原则）；
- 测试金字塔：manifest schema 契约测试、解密向量测试（NIST 用例）、zip-bomb 熔断测试、Router 关键词回归表；
- 遵循部署四规则（记录/验证/回滚/审计，见 [[Claude-Ops-KB-Home]] tip 区）。

## 五、维度 7：对外服务化与多会话流水排布

### 5.1 双形态 API

| 形态 | 协议 | 特征 | 关键设计 |
|------|------|------|---------|
| 交互式（人） | HTTPS + SSE/WebSocket 流式 | 会话长连接、多轮上下文、中途打断 | 会话粘性（sticky）、心跳保活、权限门（写操作审批） |
| 非交互式（机器） | POST `/v1/conclusion` 同步 RPC | 一问一答、结构化 JSON 出、幂等 | 输入哈希缓存、严格 SLA 超时、重试幂等键 |

非交互形态的典型调用方就是"检测系统发现问题 → 取结论"的工具化 Agent：请求体带问题上下文 + 引用资料（日志/文件），响应只回结论与证据索引——本质是把 Agent 当成一个**慢函数**暴露，必须用缓存与排队把它包装成可靠的函数。

### 5.2 并发分层模型（跨平台）

```
L0 边缘    Nginx/Caddy: TLS 终结 / least_conn upstream / 限流 / 120s 读超时
L1 Web层   多进程 worker 池
             Linux: fork/cluster 或容器多副本；Windows: 手动多端口复制 :8801-880N
L2 会话池  Session Workers × N（每个 worker = 一个基座会话载体）
             Pi 版: 进程内 AgentSession 池；opencode 版: headless 会话池/CLI 子进程池
             会话内串行、会话间并行；worker 借出/归还/健康检查
L3 引擎    provider token bucket（全局限速）+ prompt-cache 亲和
```

继承 [[agent-async-isolation-pattern]] 的三层超时（外层 > 中层 > 内层）与 [[log-analysis-agent-windows-architecture]] 的 32 槽位经验，新增两条重负载法则：

1. **prompt-cache 亲和**：同一会话尽量粘住同一 worker/同一模型路由，前缀缓存命中可省 75-90% 输入费用并大幅降 TTFT（库内缓存事故教训见 [[cc-cache-hitrate-35pct-postmortem]]）——调度器把"会话→worker"做成一致性哈希而非随机分配；
2. **背压优先于降质**：队列深度超水位先返回 `429 + Retry-After`（让调用方感知），不要悄悄缩小上下文或换弱模型导致结论质量塌方。

### 5.3 系统级多会话流水排布

把每个请求建模为跨阶段状态机，阶段之间**重叠执行**：

```
queued → preprocessing → active(LLM) → streaming → recycle
            │                 │
            └── 请求N的解压解密 ∥ 请求N-1的LLM推理（流水重叠）
                manifest 就绪即推进 active，数据通道继续后台预热
```

| 调度机制 | 说明 |
|---------|------|
| 双优先级队列 | 交互式 > 非交互式；同优先级内公平轮转防饿死 |
| 准入控制 | 会话池占用 ≥ 高水位 → 新会话排队；≥ 满水位 → 拒绝 |
| 会话生命周期回收 | streaming 完成后 worker 不销毁：清上下文、保留缓存亲和、归还池 |
| 全局看门狗 | 每个活跃会话挂载 [[main-subagent-realtime-interaction]] 的心跳表 + T0..T3 升级阶梯；非交互任务超 SLA 直接 T2 interrupt + checkpoint 恢复 |
| 弹性扩缩 | Windows 服务化用 NSSM/sc 注册多实例；水平扩容 = 加进程绑新端口 + Nginx upstream 追加 |

### 5.4 重负载下的容量账（估算框架）

```
单会话占用 ≈ worker 进程内存 + 上下文 token 成本 + Sidecar 解密窗口
对外并发 QPS ≈ min( 会话池大小 / 平均会话时长 , provider TPM ÷ 平均每请求 token )
```

先压测定参（平均会话时长、每请求 token、缓存命中率），再定会话池大小；**provider 限速是第一瓶颈**，会话池大于引擎吞吐只会堆队列不会提吞吐。

### 5.5 跨平台适配矩阵

| 关注点 | Windows（业务现场先发） | Linux（服务端生产目标） | macOS（开发机） |
|--------|------------------------|------------------------|----------------|
| 进程模型 | 无 fork → 手动多端口多进程 / NSSM 托管 | fork/Node cluster / 容器多副本 | 同 Linux（开发用途） |
| 服务管理 | NSSM 或 `sc.exe` 注册服务 | systemd unit（Restart=always） | launchd（可选） |
| 文件系统差异 | NTFS 大小写不敏感；长路径需 `\\?\` 前缀 | 大小写敏感，路径即真相 | APFS 大小写不敏感默认 |
| 明文保护 | NTFS EFS 加密目录 + shred | tmpfs/LUKS + `shred`/密钥即焚 | FileVault（仅开发） |
| 实时扫描干扰 | Defender 排除目录（否则吞吐掉档） | 无 AV（用 SELinux/AppArmor 补边界） | Gatekeeper 影响小 |
| Shell 基座工具 | bash 类工具需 Git Bash/WSL shim 或映射 PowerShell（选 Pi 时须专项实测 shellPath 与含空格路径，官方有一等 Windows 文档但历史坑多） | 原生 bash ✓ | 原生 zsh/bash ✓ |
| 解压二进制分发 | 7z.exe/unrar.exe 随包分发 | p7zip/unrar 各发行版包管理 | brew 安装 |
| 密钥访问 | DPAPI | KMS/Vault + 文件权限 600 | Keychain（开发） |
| 容器化 | Docker Desktop/WSL2 后端（可行但重） | **首选**：原生容器化部署 | 同 Linux |
| Pi Agent 权限缺失补偿 | 容器或受限账户 | 容器化是官方推荐路径（Docker/Gondolin） | 开发环境可放宽 |

> [!tip] 跨平台工程纪律
> 把平台差异**收敛到 Sidecar 与部署脚本层**：基座配置（agent/*.md、skills、Router 表）与业务代码零 `#ifdef`；路径统一用库层抽象（pathlib/Path），禁止手拼分隔符；CI 矩阵至少跑 Win+Linux 两组契约测试。

## 六、推荐方案与分阶段实施路线图

每个阶段给出**推荐方案、可行步骤、验收标准、回滚点**，可直接当迭代计划用。

### Phase 0 — 基座 PoC 与版本锁定（约 1 周）

| 项 | 内容 |
|----|------|
| 推荐方案 | OpenCode headless/server 模式起本地基座 + 最小 agent 定义 + 空壳 MCP Sidecar，跑通"请求→结论"最小闭环 |
| 步骤 | ① 固定基座版本号写入仓库（`engines`/lockfile）；② 建 `.opencode/agent/preproc.md` 最小编排 agent（只读权限）；③ Sidecar 骨架暴露一个 echo 工具经 MCP 注册；④ 用 SDK/curl 打通非交互 RPC 一问一答 |
| 验收 | 外部脚本调用 `/v1/conclusion` 拿到确定性回显；agent 工具白名单生效（其他 agent 看不到 secure_* 工具） |
| 回滚 | 纯增量目录，删除即可 |

### Phase 1 — 预处理 Sidecar MVP（2-3 周）

| 项 | 内容 |
|----|------|
| 推荐方案 | 先做 **ZIP + AES 信封加密**单层链路（覆盖 80% 样本），RAR 与嵌套递归放 Phase 4；结构通道与数据通道双队列并行 |
| 步骤 | ① manifest schema 定稿并写契约测试；② 流式解压（恒定缓冲）+ 三闸门熔断；③ AES-CTR+HMAC 分块解密到受保护临时区；④ `secure_read(path, range)` 工具上线并接入 agent 白名单；⑤ Defender/AV 排除项写入部署文档 |
| 验收 | 500MB 加密 ZIP 处理内存峰值 < 256MB；manifest 注入后 LLM 能正确回答"包里有什么"；上下文中 grep 不到明文内容；熔断测试全绿 |
| 回滚 | Sidecar 特性开关逐个关闭退回 Phase 0 |

### Phase 2 — 触发路由与治理（1-2 周）

| 项 | 内容 |
|----|------|
| 推荐方案 | Router 关键词表短路先行（零 token 收益最大），会话内 hook 兜底后置；permission 白名单同步收紧 |
| 步骤 | ① 关键词正则表进 git + 命中统计埋点；② Router 直调外部服务组装响应；③ permission 配置限制基座写/网权限（last-match 规则）；④ 灰度开关 + 回归用例表 |
| 验收 | 命中意图 TTFT < 200ms 且 0 token；未命中正常走 LLM；误路由率统计可见 |
| 回滚 | 关灰度开关恢复全量 LLM 路径 |

### Phase 3 — 服务化与并发（2-3 周）

| 项 | 内容 |
|----|------|
| 推荐方案 | 双形态 API + 会话池 + 全局看门狗；Linux 上先用裸进程池压测，再考虑容器化 |
| 步骤 | ① SSE 流式通道 + 会话粘性一致性哈希；② 会话池借还与健康检查；③ 三层超时模板落地（外>中>内）；④ 心跳表 + T0..T3 升级阶梯接入（复用 [[main-subagent-realtime-interaction]]）；⑤ 压测定容（会话时长/token 分布/缓存命中率三参数） |
| 验收 | 目标并发下 P95 TTFT 达标；kill -9 单 worker 不影响整体服务；看门狗能在 T_hard 内发现人为挂死的会话并自动恢复 |
| 回滚 | upstream 摘除新实例，老实例承接 |

### Phase 4 — 复杂格式与跨平台交付（2 周 + 持续）

| 项 | 内容 |
|----|------|
| 推荐方案 | 嵌套加密包递归 worker（深度≤5、总量预算）；Linux 生产部署容器化优先 |
| 步骤 | ① 递归 worker + onion manifest 树（节点带 enc 元数据）；② RAR/7z 二进制按平台分发清单；③ systemd unit + 容器镜像双交付物；④ CI 平台矩阵（Win+Linux）契约测试；⑤ 部署四规则归档（deployment-log） |
| 验收 | 三层嵌套加密样本端到端通过且明文零落盘泄露；同一镜像在 Win(Docker Desktop) 与 Linux 行为一致 |
| 回滚 | 嵌套特性独立开关；部署物均带 rollback 脚本 |

## 七、风险登记簿

| 风险 | 影响 | 对策 |
|------|------|------|
| OpenCode 插件 API 含 experimental 面，版本间变动 | 胶水失效 | 锁定基座版本；hook 薄封装集中在一处；升级跑契约测试 |
| RAR 解压依赖 unrar.exe 许可证 | 法务 | 仅解压用途合规；商用评估 7-Zip 路线覆盖范围 |
| 明文临时区泄露 | 安全/合规 | NTFS 加密盘 + 任务结束 shred + 访问审计 + 密钥不出 KMS |
| 嵌套包炸弹 | 资源耗尽 | 三闸门熔断（§3.3）+ 配额按调用方计费 |
| 跨平台行为差异（路径/shell/服务管理/AV） | 同代码不同表现 | 差异收敛到 Sidecar+部署层；CI 双平台矩阵测试（§5.5） |
| Pi 0.x API 破坏性变更（queueMessage→steer/followUp 先例）+ npm 作用域整体迁移（@mariozechner→@earendil-works）+ 商业收购治理不确定 | 选 Pi 为基座时的最大长期风险 | 锁版本+私有镜像；SDK 调用收拢到薄适配层；详见 [[参考-Pi-Agent-技术调研报告]] §9 |
| Windows AV/索引器干扰 | 吞吐骤降 | 排除目录 + 进程优先级管理（参照 [[subagent-resource-architecture-2026-07-03]]） |
| 关键词规则腐化 | 误路由 | 命中统计 + 灰度 + 定期评审（§4.3） |

## 八、决策摘要（ADR 式）

| 决策 | 选择 | 理由 |
|------|------|------|
| D1 基座形态 | OpenCode 交互基座 + Sidecar 外挂；Pi 为纯后端嵌入备选 | 配置驱动/社区/权限体系满足维度1·6；Sidecar 保升级友好 |
| D2 明文治理 | manifest 入上下文 + secure_read 按需窗口 | 满足维度2 的上下文预算与最小暴露 |
| D3 短路位置 | 网关 Router 为主 + hook 兜底 | 零 token、TTFT 最小、可配置可审计 |
| D4 并发骨架 | 会话池 + 双优先级队列 + cache 亲和 + 背压 | 维度7 重负载三件套；进程模型按平台适配矩阵选择（§5.5） |
| D5 控制面 | 全局看门狗接入实时交互方案 | 卡死治理复用 [[main-subagent-realtime-interaction]]，不自造 |
| D6 平台策略 | Windows 先发、Linux 容器化为生产目标、差异收敛部署层 | 满足跨平台要求且不污染业务代码 |

## Related

- [[main-subagent-realtime-interaction]] — 服务化看门狗的控制面协议
- [[pi-agent-constraints-reference]] · [[pi-agent-framework-knowledge]] — Pi 侧约束基线
- [[参考-OpenCode-技术调研报告]] · [[参考-Pi-Agent-技术调研报告]] — 选型判断的完整事实依据
- [[lognet-rootcause-multiagent-architecture]] — 本架构在日志根因分析领域的落地实例
- [[agent-memory-context-knowledge-design]] — 基座的记忆分层与知识库化策略
- [[log-analysis-agent-windows-architecture]] · [[agent-async-isolation-pattern]] — Windows/跨平台服务化先例与超时模板
- [[cc-cache-hitrate-35pct-postmortem]] — 缓存亲和的成本依据

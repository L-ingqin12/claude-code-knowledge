---
title: LLM推理部署与量化
aliases: [LLM推理部署, LLM量化, vLLM部署, Ollama部署, 推理加速]
tags: [ai, ai/learning]
created: 2026-08-25
updated: 2026-08-25
status: review
---

# LLM推理部署与量化

一句话定位：从"能不能用"到"怎么省卡省钱"，本笔记把课程第 4/5/6 章的私有化部署知识串成一条线——**Ollama 快速起步 → vLLM 生产化 → Ray 分布式扩展**，并附 GPTQ/AWQ/GGUF/FP8 量化选型表。

> [!abstract] 摘要
> 本文档覆盖大语言模型（Large Language Model, LLM）私有化部署全链路：第 4 章以数据安全、成本、延迟三个维度对比云 API、Ollama、vLLM 三条路线；第 5 章详解 Ollama（llama.cpp GGUF 量化内核）的参数配置与 API 实践，以及 vLLM 的 PagedAttention 分页显存、Continuous Batching 连续批处理两大核心机制；第 6 章给出 Ray 集群多机多卡分布式推理的完整落地清单。原理部分用 [[Training-vs-Inference.excalidraw]] 对比训练并行与推理并行，Demo 覆盖 Ollama 命令行/REST、vLLM OpenAI 兼容服务、Ray 集群启动三套可直接复制的脚本。

## 核心概念

### 术语速查表

| 术语 | 英文 | 一句话解释 |
|------|------|-----------|
| 推理 | Inference | 模型加载权重后做前向计算逐 token 生成，只读不更新权重 |
| 量化 | Quantization | 把权重从 FP16/BF16 压到 4bit/8bit，显存减半以上、精度略降 |
| GGUF | GPT-Generated Unified Format | llama.cpp 生态的统一模型文件格式，一个文件装下权重+配置，Ollama 直接使用 |
| KV Cache | Key-Value Cache | 缓存历史 token 的 K/V 向量避免重复计算，序列越长占用越大 |
| PagedAttention | 分页注意力 | vLLM 把 KV Cache 按"页"管理，消除碎片化浪费（类比操作系统虚拟内存） |
| Continuous Batching | 连续批处理 | 请求随到随加入批次、生成完即释放槽位，不等同批最慢请求 |
| TTFT | Time To First Token | 首 token 延迟，决定用户"体感快慢"，越低越好 |
| TPOT | Time Per Output Token | 每输出 token 耗时（token 间延迟），决定打字机效果流畅度 |
| 张量并行 | Tensor Parallel, TP | 把一层权重矩阵按列切开分给多卡，每卡算一部分再汇总 |
| 流水线并行 | Pipeline Parallel, PP | 把网络按层切段，不同卡负责不同层，像工厂流水线 |
| Ray | Ray 分布式框架 | vLLM 的多机编排底座，负责集群管理与任务调度 |

### Ollama 是什么

Ollama 是本地大模型"一键管理器"，内核是 **llama.cpp**——一个 C/C++ 实现的量化推理引擎，支持 GGUF 模型格式与 CPU/GPU 混合推理。Ollama 把模型拉取、运行、API 服务打包成一条命令（`ollama run`），默认在本机 `http://localhost:11434` 起 REST 服务，并附带 OpenAI 兼容端点 `/v1`，是个人开发与边缘部署的最短路径。

### 企业级部署三维决策表

| 维度 | 云 API（如 OpenAI/DeepSeek） | Ollama | vLLM |
|------|------------------------------|--------|------|
| 数据安全 | ❌ 数据出域，受合规约束 | ✅ 全本地，零出域 | ✅ 全本地，零出域 |
| 成本 | 按 token 付费，起步零成本；量大后线性增长 | 一台普通机器即可，消费级显卡友好 | 需较好的 GPU（建议 ≥24G 显存），硬件投入高 |
| 延迟 | 受公网与排队影响，波动大 | 低并发下够用；吞吐一般 | 吞吐最高（高数倍到数十倍），TTFT 可控 |
| 部署难度 | 零门槛 | 一条命令 | 中高（Python 环境 + GPU 驱动） |
| 典型场景 | 原型验证、非敏感业务 | 个人开发、边缘设备、快速体验 | 企业生产、高并发在线服务 |

> [!tip] 选型口诀
> 数据敏感选本地，要吞吐选 vLLM，图省事选 Ollama，起步验证选云 API。

### 量化方案对比表

| 方案 | 全称 | 位宽 | 精度损失 | 推理速度 | 适用场景 |
|------|------|------|----------|----------|----------|
| GPTQ | 生成式预训练 Transformer 的训练后量化（Post-Training Quantization） | 4bit | 小（大模型上通常可忽略） | GPU 快，依赖专用反量化 kernel | 显存受限的 GPU 生产环境 |
| AWQ | 激活感知权重量化（Activation-aware Weight Quantization） | 4bit | 更小（按激活统计保护显著权重通道） | GPU 快，vLLM 原生支持 | vLLM 生产首选，普适性最好 |
| GGUF | llama.cpp 统一格式（含 K-quants 多档） | 2-8bit | K-quants 档位下很小 | CPU/GPU 混合，Apple Silicon 友好 | 本地/端侧、Ollama/llama.cpp 生态 |
| FP8 | 8 位浮点（Float Point 8，E4M3） | 8bit | 几乎无损（相对 BF16） | 快，需 H100/H200 等新硬件 | 高性能集群、精度敏感场景 |

> [!info] 量化选择心法
> 先问"跑在哪"：Ollama/llama.cpp 生态 → GGUF；vLLM 生产 → AWQ 优先、GPTQ 次之；新卡（H100+）且追求精度 → FP8。

## 原理剖析

### 训练并行 vs 推理并行

![[Training-vs-Inference.excalidraw]]

上图对比了训练与推理两条完全不同的"并行账本"：

- **训练并行（图左）**：目标是把梯度算完并把权重更新同步到每一份副本。数据并行（Data Parallel, DP）每卡一份完整模型、各算各的梯度再 AllReduce 汇总；张量并行（TP）与流水线并行（PP）把单步前向/反向切开，但**反向传播的梯度通信是训练独有成本**——TP 每层前向后向都要跨卡通信，PP 需要微批次（micro-batch）填充流水线气泡（bubble）。所以训练讲究"通信/计算比"，高带宽 NVLink/InfiniBand 是刚需。
- **推理并行（图右）**：只有前向，没有反向，也没有优化器状态，显存大头是**权重 + KV Cache**。同一时刻只服务一批请求，因此：TP 在推理中按请求粒度"多卡合力算一个请求"（低延迟但卡间带宽敏感）；PP 在推理中多用于单卡放不下的超长序列；而 vLLM 的主力优化——PagedAttention 与 Continuous Batching——本质是在**单卡显存内做碎片化管理和请求级动态调度**，与并行维度正交叠加。

> [!info] 一句话记忆
> 训练并行追求"算得快、传得快"（梯度同步），推理并行追求"放得下、排得满"（权重/KV 显存 + 请求调度）。推理的 TP 跨节点走网卡时，带宽（NVLink > InfiniBand > 以太网）直接决定 TTFT 上限。

### vLLM 两大引擎级优化

1. **PagedAttention（显存分页管理）**：传统推理给每个请求预分配 `max_seq_len` 长度的连续 KV Cache，浪费可达 60%-80%。vLLM 借鉴操作系统虚拟内存，把 KV Cache 切成固定大小的"块"（block），按需分配、允许不连续存储，浪费压到 4% 以下，同显存可容纳更多并发序列。
2. **Continuous Batching（连续批处理）**：静态批处理要等一批中所有请求都生成完才整批退出，慢请求拖累全批。连续批处理在每步迭代时动态增删请求——新请求到达立刻入队，生成完的立刻让出槽位，GPU 几乎不空转，吞吐比 HuggingFace transformers 高数倍到数十倍。

### 单机放不下怎么办：Ray 集群 + 跨节点张量并行

当模型权重 + KV Cache 超过单机显存（如 72B 模型全精度需要 4×80G 卡，而单机只有 2 卡），就把张量并行（TP）铺到多台机器上：vLLM 通过 **Ray** 编排多机 worker，`tensor_parallel_size=2` 让两台机器各持半份权重，`pipeline_parallel_size=2` 再把网络按层切两段，形成 2 机 × 1 卡（TP=2）× 2 段（PP=2）的拓扑。代价是 KV Cache 与激活要跨节点传输，因此多机方案必须配套高带宽网络（万兆起，IB 更佳），详细启动清单见 [[#Demo 3：Ray 多机多卡分布式推理启动清单]]。

## 最小可运行 Demo

> [!note] 环境约定
> 以下 Demo 在 Linux + NVIDIA GPU（≥8G 显存可跑 7B 级模型）环境验证思路；Windows 用户可用 WSL2。Ollama 一键安装：`curl -fsSL https://ollama.com/install.sh | sh`。vLLM 安装：`pip install vllm`（要求 CUDA 12.x + Python 3.9-3.12）。

### Demo 1：Ollama 命令行 + REST 两种调用

```bash
# ============ ① 命令行调用 ============
ollama pull qwen2.5:7b            # 拉取 Qwen2.5-7B（自动使用 GGUF 量化版）
ollama run qwen2.5:7b             # 进入交互式对话
# >>> 你好，用一句话介绍你自己
# /bye                            # 退出对话

# 非交互式一次性提问
ollama run qwen2.5:7b "用一句话解释什么是PagedAttention"
```

```bash
# ============ ② REST API 调用（服务默认监听 http://localhost:11434）============
# 2.1 /api/generate：补全式接口，prompt 为单段文本
curl http://localhost:11434/api/generate -d '{
  "model": "qwen2.5:7b",
  "prompt": "为什么天空是蓝色的？",
  "stream": false
}'
# 返回 JSON：{"response": "...", "total_duration": ..., "eval_count": ...}

# 2.2 /api/chat：对话式接口，携带多轮 messages，风格接近 OpenAI
curl http://localhost:11434/api/chat -d '{
  "model": "qwen2.5:7b",
  "messages": [
    {"role": "system", "content": "你是一名严谨的物理老师"},
    {"role": "user", "content": "用三句话解释瑞利散射"}
  ],
  "stream": false
}'

# 2.3 OpenAI 兼容端点：/v1/chat/completions，可直接替换 OpenAI SDK 的 base_url
curl http://localhost:11434/v1/chat/completions -d '{
  "model": "qwen2.5:7b",
  "messages": [{"role": "user", "content": "你好"}]
}'
```

### Demo 2：vLLM 在线推理 + OpenAI SDK 对话脚本

```bash
# 一条命令起服务（参数说明见下方注释块）：
vllm serve Qwen/Qwen2.5-7B-Instruct \
  --port 8000 \
  --tensor-parallel-size 2 \
  --max-model-len 8192 \
  --quantization awq \
  --enable-prefix-caching \
  --api-key sk-local-demo
# 参数含义：
#   --tensor-parallel-size 2   → 2 卡张量并行
#   --max-model-len 8192       → 最大上下文长度（越小越省显存）
#   --quantization awq         → 加载 AWQ 量化权重（需先准备 AWQ 版模型）
#   --enable-prefix-caching    → 前缀缓存：相同 system prompt 直接复用 KV
#   --api-key sk-local-demo    → 服务端鉴权 token
```

```python
# vllm_chat.py —— 用 OpenAI SDK 指向本地 8000 端口的对话脚本
# 运行前安装：pip install openai
from openai import OpenAI

# base_url 指向 vLLM 的 OpenAI 兼容端点
client = OpenAI(
    base_url="http://localhost:8000/v1",   # 本地 vLLM 服务
    api_key="[已脱敏]",               # 与 --api-key 保持一致
)

resp = client.chat.completions.create(
    model="Qwen/Qwen2.5-7B-Instruct",      # 默认即所 serve 的模型名
    messages=[
        {"role": "system", "content": "你是简洁的中文技术助手"},
        {"role": "user", "content": "vLLM 为什么比 transformers 快？"},
    ],
    temperature=0.7,   # 采样温度：越高越发散
    top_p=0.8,         # 核采样：累积概率阈值
    max_tokens=256,    # 最大生成 token 数
)

print(resp.choices[0].message.content)
print("usage:", resp.usage)   # 含 prompt/completion tokens，TTFT 最小验证

# 压测命令（新版 vLLM 自带 benchmark，快速测 TTFT/TPOT/吞吐）：
# `vllm bench` CLI 由 PR #13993 引入，`bench serve` 在 PR #18566 迭代完善；
# 旧脚本 benchmarks/benchmark_serving.py 已在后续版本正式移除（commit 6fb2788）：
# vllm bench serve --backend openai-chat \
#   --model Qwen/Qwen2.5-7B-Instruct \
#   --base-url http://localhost:8000/v1 --num-prompts 100
```

### Demo 3：Ray 多机多卡分布式推理启动清单

```bash
# ============ 前提：2 台 8 卡 GPU 服务器，主机规划 ============
# node01 ([IP已脱敏])  → 主节点 (Ray head)
# node02 ([IP已脱敏])  → 从节点 (Ray worker)
# 网络：万兆以太网或 InfiniBand（TP 跨节点带宽敏感）

# ============ ① 两机都配置 /etc/hosts ============
echo "[IP已脱敏] node01" | sudo tee -a /etc/hosts
echo "[IP已脱敏] node02" | sudo tee -a /etc/hosts

# ============ ② SSH 免密（Ray 与 pdsh 都依赖）============
ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa   # 主节点生成密钥
ssh-copy-id node02                                  # 公钥拷到从节点

# ============ ③ conda 环境同步（两机 Python/依赖版本一致）============
conda env export -n vllm-env > vllm-env.yml              # 主节点导出
scp vllm-env.yml node02:/tmp/
ssh node02 "conda env create -f /tmp/vllm-env.yml"       # 从节点重建

# ============ ④ 共享目录：NFS 挂载同一份模型权重（免两机各存一份）============
# 主节点 /data/models 作为 NFS 服务端（/etc/exports 配置略）
sudo mkdir -p /data/models
# 从节点挂载
ssh node02 "sudo mkdir -p /data/models && \
  sudo mount -t nfs node01:/data/models /data/models"

# ============ ⑤ pdsh 批量执行（免密后一条命令跑两机）============
echo "node01,node02" > ~/hosts.txt   # 主机列表文件
# 批量检查 GPU 与依赖版本（提前 pip install "ray[default]" vllm）
pdsh -w ^~/hosts.txt \
  "nvidia-smi --query-gpu=name,memory.total --format=csv && \
   python -c 'import ray, vllm; print(ray.__version__, vllm.__version__)'"

# ============ ⑥ Ray 集群启动 ============
# 主节点：启动 head
ray start --head --port=6379 --dashboard-host [IP已脱敏]
# 从节点：加入集群（--address 指向主节点）
ssh node02 "ray start --address='node01:6379'"
# 校验：应显示 2 节点 16 卡
ray status

# ============ ⑦ vLLM 分布式推理测试 ============
# 在 head 节点设置 Ray 地址（新版 vLLM 读 RAY_ADDRESS；旧版需在脚本里 ray.init(address="auto")）
export RAY_ADDRESS='auto'
# 无 InfiniBand 时必须关闭 NCCL 的 IB 探测，否则跨节点通信初始化卡死
export NCCL_IB_DISABLE=1
# 张量并行跨 2 节点（每节点 1 卡各持半份权重）+ 流水线并行 2 段（按层切两段）
vllm serve /data/models/Qwen2.5-72B-Instruct-AWQ \
  --tensor-parallel-size 2 \
  --pipeline-parallel-size 2 \
  --quantization awq \
  --port 8000

# 验证：curl http://localhost:8000/v1/models 应返回模型列表
```

## 进阶实践与常见坑

### Ollama 核心参数配置

Ollama 的参数有两个入口：Modelfile（存进模型，全局生效）与 API 请求体的 `options` 字段（单次覆盖）。

```text
# Modelfile 示例：ollama create mybot -f Modelfile
FROM qwen2.5:7b
PARAMETER temperature 0.7      # 采样温度
PARAMETER num_ctx 4096        # 上下文窗口大小（KV Cache 上限）
PARAMETER num_gpu 33          # 卸载到 GPU 的层数；超过总层数=全部卸载
PARAMETER num_predict 512     # 单次最大生成 token 数
PARAMETER top_k 40            # Top-K 采样
PARAMETER top_p 0.9           # Top-P 采样
PARAMETER keep_alive 10m      # 模型驻留显存时长：0=立即卸载，-1=常驻
SYSTEM "你是本地部署的技术助手"
```

| 参数 | 默认值 | 作用 |
|------|--------|------|
| `num_gpu` | 自动（能放多少放多少） | GPU 分层卸载层数；设大数（如 99）强制全卸载 |
| `num_ctx` | 4096 | 上下文窗口；越长 KV Cache 显存占用越大 |
| `keep_alive` | 5m | 空闲多久后从显存卸载模型；线上服务建议 `-1` |
| `temperature` | 0.8 | 采样温度，越低越确定 |
| `OLLAMA_NUM_PARALLEL` | 1 | 环境变量：并行请求数（服务化必须调大） |
| `OLLAMA_SCHED_SPREAD` | 0 | 环境变量：=1 时调度器把请求分散到多卡，实现跨卡负载均衡 |
| `OLLAMA_FLASH_ATTENTION` | 0 | 环境变量：=1 开启 Flash Attention 省显存 |

> [!tip] 多卡 GPU 负载均衡的正确姿势
> Ollama 默认**单个模型只跑在一张卡上**，多卡要靠组合拳：① `OLLAMA_SCHED_SPREAD=1` 让调度器把并发请求轮流分发到多卡；② 多实例——用 `CUDA_VISIBLE_DEVICES` 分别起两个 ollama serve 进程各自独占一张卡，再在 nginx 层做负载均衡；③ `num_gpu=层数` 做分层卸载，把模型层铺到单卡显存装不下的机器上。真正的"一个模型铺满 N 卡"请上 vLLM 的 tensor-parallel。

### vLLM 离线推理核心参数

```python
from vllm import LLM, SamplingParams

llm = LLM(
    model="Qwen/Qwen2.5-7B-Instruct",
    tensor_parallel_size=2,       # 张量并行卡数
    gpu_memory_utilization=0.9,   # 最多占用单卡 90% 显存（留 10% 给 KV/碎片）
    max_model_len=8192,           # 上下文上限：显存不够时先砍它
    swap_space=4,                 # 每卡预留 4GB CPU 内存做 KV 换页（swap）
    quantization="awq",           # 量化后端：awq / gptq / fp8 等
)
params = SamplingParams(temperature=0.7, top_p=0.8, max_tokens=256)
outputs = llm.generate(["你好，介绍一下vLLM"], params)
print(outputs[0].outputs[0].text)
```

### vLLM 在线生产三讲要点

| 生产主题 | 关键动作 |
|----------|----------|
| 压测与容量 | 先定 SLA：TTFT 与 TPOT 分开压测；并发数↑时 TTFT 上升、吞吐先升后平台化——用 `vllm bench serve` 画"并发-吞吐/TTFT"曲线找拐点定容量 |
| 鉴权与反代 | `--api-key` 服务端校验；生产前置 nginx 反代做 TLS、限流、上游健康检查 |
| 监控 Dashboard | vLLM 原生暴露 `/metrics`（Prometheus 格式，如 `vllm:num_requests_running`、`vllm:prompt_tokens_total`、`vllm:gpu_cache_usage_perc`），接 Grafana 出面板 |

| 指标 | 英文 | 含义与健康判据 |
|------|------|----------------|
| 首 token 延迟 | TTFT | 用户等待感；SLA 常定 200-500ms 内 |
| 每 token 耗时 | TPOT | 生成流畅度；高并发下劣化说明批队列积压 |
| 吞吐 | Throughput (tokens/s) | 整体产能；观察随并发上升的拐点 |
| KV 缓存占用 | GPU Cache Usage | 占用接近 100% 且请求排队 → 扩卡或换量化 |

### 推理类模型（Reasoning Model）支持

vLLM 通过 `--reasoning-parser deepseek_r1` 支持 DeepSeek-R1 这类"先想后答"的模型，把思维链（chain-of-thought）从正文中拆出来单独返回：

```bash
vllm serve deepseek-ai/DeepSeek-R1-Distill-Qwen-7B \
  --reasoning-parser deepseek_r1 \
  --port 8000
```

```python
# 返回结构多出 reasoning_content 字段（思维链），content 为最终答案
resp = client.chat.completions.create(
    model="deepseek-ai/DeepSeek-R1-Distill-Qwen-7B",
    messages=[{"role": "user", "content": "9.11 和 9.9 哪个大？"}],
)
msg = resp.choices[0].message
print("思维链:", getattr(msg, "reasoning_content", None))  # 模型内部推理过程
print("答案:", msg.content)                                 # 最终输出
```

### 常见坑清单

> [!warning] Ollama 坑
> - `keep_alive` 默认 5 分钟卸载模型：服务空闲一段时间后第一个请求触发重新加载，TTFT 突然飙到几十秒——线上设 `-1` 常驻。
> - `/api/generate` 与 `/api/chat` 的采样参数必须放在 `options` 字段（如 `"options": {"temperature": 0.7}`），直接放顶层会被忽略。
> - 默认 `stream: true`：不想要 SSE 流式输出必须显式 `"stream": false`。

> [!warning] vLLM 坑
> - OOM 先砍 `--max-model-len` 和 `--gpu-memory-utilization`，别急着上量化；`swap_space` 默认 4GB，长序列换页会拖慢 TPOT。
> - 跨节点张量并行且无 InfiniBand 时，必须 `export NCCL_IB_DISABLE=1`，否则 NCCL 初始化卡死。
> - 前缀缓存只对共享前缀（同 system prompt、few-shot 样例）生效，长尾请求开了反而占显存。

> [!danger] Ray 集群坑
> - 各节点 vllm/ray/transformers 版本必须完全一致，否则 worker 起不来或静默跑错——用 conda env 同步而非逐包 pip。
> - 忘了 SSH 免密：Ray 靠 SSH 拉 worker 进程，node02 上的 ray start 会无限重试。
> - `/dev/shm` 太小（容器默认 64M）会让 PyTorch 多进程通信报错，需挂载大 tmpfs。

## 相关文档

- [[AI大模型开发]] — 上游的 Transformer/模型结构基础
- [[AI-Dev-KB-Home]] — ai-dev 子库首页（MOC）
- [[LoRA参数高效微调实战]] — 部署的上一环：把模型调成业务形状
- [[RAG检索增强生成实战]] — 部署后的应用层：外挂知识库
- [[微调数据工程与模型蒸馏]] — 蒸馏产出的"小模型"正是本笔记部署与量化的对象

## 参考资料

- [vLLM 官方文档 — Reasoning Outputs](https://docs.vllm.ai/en/latest/features/reasoning_outputs.html)：`--reasoning-parser deepseek_r1` 与返回 `reasoning_content` 字段
- [vLLM 官方文档 — Automatic Prefix Caching](https://docs.vllm.ai/en/latest/design/automatic_prefix_caching.html)：`--enable-prefix-caching` 前缀缓存机制
- [vLLM 官方文档 — Engine Arguments](https://docs.vllm.ai/en/latest/models/engine_args.html)：`gpu_memory_utilization`（默认 0.9）、`swap_space`（默认 4GiB）、`max_model_len` 等参数默认值
- [vLLM 多节点服务示例（Ray + TP/PP）](https://docs.vllm.com.cn/en/latest/examples/online_serving/multi-node-serving.html)：分布式推理的 Ray 集群形态
- [PagedAttention 论文（SOSP 2023, arXiv:2309.06180）](https://arxiv.org/abs/2309.06180)：KV Cache 浪费 60%-80% 压至 4% 以下、吞吐提升 2-4× 的原始出处
- [PagedAttention in vLLM: KV Cache Paging for 24x Throughput](https://tildalice.io/pagedattention-vllm-kv-cache-throughput/)：vLLM 官方博客口径"相对 HuggingFace Transformers 最高 24× 吞吐"
- [Ollama Modelfile 官方文档](https://docs.ollama.com/modelfile)：`num_gpu`/`num_ctx`（默认 4096）/`keep_alive`（默认 5m）/`temperature`（默认 0.8）等参数与默认值
- [Ollama keep_alive 运维说明](https://github.com/geeks-accelerator/ollama-herd/blob/main/docs/troubleshooting.md)：空闲 5 分钟自动卸载模型的现象与规避
- [Ollama 多卡并发调度讨论（Issue #7253）](https://github.com/ollama/ollama/issues/7253)：Ollama 单模型默认单卡、多卡调度（`OLLAMA_SCHED_SPREAD`）的官方讨论
- [OLLAMA_NUM_PARALLEL 参数解读](http://theneuralbase.com/ollama/learn/intermediate/ollama-num-parallel-parallel-requests/)：并行请求数环境变量
- [vLLM `bench` CLI 引入（PR #13993）](https://github.com/vllm-project/vllm/pull/13993) 与 [`bench serve` 迭代（PR #18566）](https://github.com/vllm-project/vllm/pull/18566)：压测命令来源与用法；[旧脚本移除记录](https://github.com/vllm-project/vllm/commit/6fb27881634d89c2e70e9e5fbad1b918c0d916cf)
- [Ray CLI 参考（ray start --head/--address）](https://docs.ray.io/en/latest/ray-core/starting-ray.html)：Demo 3 集群启动命令出处

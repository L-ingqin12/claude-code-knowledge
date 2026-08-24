---
title: 强化学习对齐-RLHF到GRPO
aliases: [RLHF到GRPO, RLHF, GRPO, RL对齐, 强化学习对齐]
tags: [ai, ai/learning]
created: 2026-08-25
updated: 2026-08-25
status: review
---

# 强化学习对齐-RLHF到GRPO

本文沿"强化学习 → PPO → RLHF → DPO → GRPO"的主线，讲清大模型对齐（Alignment）技术的演进逻辑与数学形式：先补强化学习基础，再逐层剖析三条核心目标函数，最后给出 DPO 训练与 GRPO 组内优势计算的极简 Demo、PPO/DPO/GRPO 选型总表，以及金融领域的落地流水线。

> [!abstract] 定位与目标
> 本文服务《第 34 章 强化学习与对齐》与《第 38 章 奖励模型部分》课程骨架。核心问题链：什么是强化学习（状态/动作/奖励/策略，与监督学习的本质区别）→ 什么是 PPO（Actor-Critic + 裁剪目标函数，4 个模型的显存开销）→ 什么是 RLHF（SFT → 奖励模型 → PPO 三阶段）→ 什么是 DPO（闭式偏好损失，跳过 RM 与在线采样）→ 什么是 GRPO（组内相对优势，省掉 Critic）。读完可获得：① 三条核心公式的直觉解读；② 可运行的 DPOTrainer 伪代码；③ numpy 版 GRPO 组内优势函数；④ 含 RewardBench 选型与金融案例的落地路径。

## 核心概念

### 强化学习四要素

| 要素 | 英文 | 含义 | LLM 场景举例 |
|------|------|------|-------------|
| 状态 | State（s） | 智能体所处环境的全部信息 | 用户输入的 prompt 与对话历史 |
| 动作 | Action（a） | 智能体在状态 s 下可做的选择 | 生成的下一个 token 或整条回答 |
| 奖励 | Reward（r） | 环境对动作好坏打出的标量分 | 奖励模型打分、规则校验得分 |
| 策略 | Policy（π） | 状态到动作概率分布的映射 π(a\|s) | LLM 自身：给定 prompt 输出 token 分布 |

### 强化学习与监督学习的本质区别

| 维度 | 监督学习（Supervised Learning） | 强化学习（Reinforcement Learning） |
|------|-------------------------------|-----------------------------------|
| 监督信号 | 固定标签 y，数据自带标准答案 | 延迟的标量奖励 r，靠打分函数给出 |
| 数据来源 | 预先收集的静态数据集 | 训练中与模型自身交互产生（在线采样） |
| 反馈时机 | 每个样本即时反馈 | 整条动作序列完成后才打分（信用分配 Credit Assignment 问题） |
| 优化目标 | 最小化经验损失 | 最大化期望累计奖励 |
| 训练稳定性 | 相对稳定 | 易发散、易"奖励黑客"（Reward Hacking） |

一句话总结：**监督学习是"对着标准答案抄"，强化学习是"试错后按分数调整"，两者的数据分布、优化目标与工程复杂度都完全不同。**

### 对齐算法术语表

| 术语 | 全称 | 一句话解释 |
|------|------|-----------|
| RLHF | Reinforcement Learning from Human Feedback（基于人类反馈的强化学习） | SFT → 奖励模型 → PPO 的三阶段对齐范式，InstructGPT 奠定 |
| PPO | Proximal Policy Optimization（近端策略优化） | 用裁剪目标函数限制策略更新步长的策略梯度算法 |
| RM | Reward Model（奖励模型） | 给"prompt+回答"打分的模型，替代人工打分 |
| BT 模型 | Bradley-Terry 模型 | 把"两两比较偏好"建模成胜率函数的统计模型 |
| DPO | Direct Preference Optimization（直接偏好优化） | 跳过 RM 与在线采样，直接对偏好对做闭式优化的对齐算法 |
| GRPO | Group Relative Policy Optimization（组相对策略优化） | 同一 prompt 采样一组回答，用组内均值/标准差作基线省掉 Critic |
| Critic | 价值网络（Value Network） | 估计"状态能带来多少累计回报"的网络，PPO 中与 Actor 成对出现 |
| 优势函数 | Advantage（Â） | 某动作比平均水平好多少：A = Q − V，或组内标准化 |
| KL 散度 | Kullback-Leibler Divergence | 衡量新旧策略分布差异，对齐中用作"别跑太远"的罚项 |
| 参考模型 | Reference Model（π_ref） | 冻结的原始模型，KL 罚项的锚点 |

## 原理剖析

### 1. 强化学习的基本循环

LLM 对齐语境下，RL 循环只有四步：① 从数据分布采样 prompt q；② 当前策略 π_θ 生成一条回答 o；③ 奖励模型（或规则）给出标量奖励 r；④ 用策略梯度类算法更新 π_θ，使高奖励回答的概率上升、低奖励回答的概率下降。其中第 ④ 步的更新幅度控制是全部工程难点所在——更新太猛，策略崩溃；更新太慢，训练白烧卡。

### 2. PPO：用裁剪目标函数锁住更新步长

PPO（Schulman et al., 2017）是主流的策略梯度算法，核心创新是**裁剪替代目标函数**（Clipped Surrogate Objective）。设概率比率 r_t(θ) = π_θ(a_t|s_t) / π_θold(a_t|s_t)（新策略与旧策略对同一动作的概率比值），PPO 的损失为：

$$\mathcal{L}^{CLIP}(\theta)=\mathbb{E}_t\Big[\min\big(r_t(\theta)\hat{A}_t,\ \text{clip}(r_t(\theta),1-\varepsilon,1+\varepsilon)\,\hat{A}_t\big)\Big]$$

解读：当优势 Â_t > 0（这一步做得好），裁剪上限 1+ε 阻止 r_t 无限放大；当 Â_t < 0（做得差），裁剪下限 1−ε 阻止 r_t 无限缩小。ε 通常取 0.2，即**一次更新的策略变化最多被限制在 ±20%**。这就是"Proximal（近端）"的含义：新策略必须待在旧策略附近，防止一步更新把好策略带崩。

> [!info] Actor-Critic 与 4 个模型
> PPO 采用 Actor-Critic（演员-评论家）结构：Actor 即策略模型负责生成回答，Critic 价值网络负责估计基线（Baseline）以降低梯度方差。搬到 LLM-RLHF 里，一次训练要同时驻留 **4 个模型**：actor（训练中）、critic（训练中）、ref 参考模型（冻结，算 KL）、reward 奖励模型（冻结，打分）。这也是 PPO 对齐显存开销大的根本原因——以 7B 模型为例，4 个模型的权重、梯度与优化器状态轻松吃掉数百 GB 显存，通常需要多卡 + DeepSpeed ZeRO 才能跑起来。

### 3. RLHF 三阶段：SFT → RM → PPO

RLHF（InstructGPT, OpenAI 2022）把"让模型符合人类偏好"拆成三步：

1. **SFT（Supervised Fine-Tuning，监督微调）**：用高质量"指令→回答"数据把预训练模型教成会聊天的助手，得到策略初始点 π_SFT；
2. **奖励模型训练**：人工对同一 prompt 的两条回答排序，构造偏好对 (x, y_w, y_l)。RM 用 Bradley-Terry 模型建模偏好——P(y_w ≻ y_l | x) = σ(r(x,y_w) − r(x,y_l))，训练损失为：

$$\mathcal{L}_{RM}=-\mathbb{E}_{(x,y_w,y_l)}\Big[\log\sigma\big(r(x,y_w)-r(x,y_l)\big)\Big]$$

即"让好回答的分数尽量高于差回答"，把难以量化的偏好变成一道可优化的二分类排序题；
3. **PPO 强化**：以 π_SFT 为起点、RM 为奖励源，跑上一节的 PPO；KL 罚项防止策略偏离 SFT 太远导致语言能力退化。

这一范式效果显著但代价高昂：RM 需要几万到几十万条人工偏好标注，PPO 在线采样又慢又吃显存，因此催生了 DPO 与 GRPO 两条降本路线。

### 4. DPO：把 RL 目标闭式化成一道分类题

DPO（Rafailov et al., 2023）的关键洞察：**带 KL 约束的 RLHF 最优策略存在闭式解**，最优策略满足 r(x,y) = β·log(π*(y|x)/π_ref(y|x)) + 常数。把这个关系代回 Bradley-Terry 偏好模型，奖励模型被代数消掉，直接得到只依赖 (chosen, rejected) 偏好对的损失：

$$\mathcal{L}_{DPO}=-\mathbb{E}_{(x,y_w,y_l)}\Big[\log\sigma\Big(\beta\log\frac{\pi_\theta(y_w|x)}{\pi_{ref}(y_w|x)}-\beta\log\frac{\pi_\theta(y_l|x)}{\pi_{ref}(y_l|x)}\Big)\Big]$$

直觉解读：**提高好回答相对差回答的"对数概率比"，同时用 π_ref 做锚防止整体概率崩塌**。β 越小，模型越敢偏离参考模型；β 越大越保守。

DPO 的代价与收益同样明显：

| 维度 | PPO | DPO |
|------|-----|-----|
| 需要 RM | ✅ 需要先训 RM | ❌ 不需要 |
| 采样方式 | 在线采样（训练中生成） | 离线偏好对（一次性备好） |
| 训练模型数 | 4 个（actor/critic/ref/reward） | 2 个（策略 + 冻结 ref） |
| 成本 | 高 | 大降（单卡可训 7B 级模型） |
| 探索性 | 强（在线探索新回答） | 弱（学不到数据集之外的分布） |

### 5. GRPO：一组回答互为标尺，砍掉 Critic

GRPO（DeepSeekMath, Shao et al., 2024）针对 PPO 的 Critic 下手。观察：Critic 的价值估计往往有偏差，且白占一整份模型的显存。GRPO 的做法是——**同一 prompt 采样 G 条回答（一组），用组内均值和标准差直接构造优势**，组内互为基线，不再需要 Critic 网络：

$$\hat{A}_i=\frac{r_i-\text{mean}(r)}{\text{std}(r)}$$

目标函数与 PPO 同构，仍是"裁剪比率 × 优势 + KL 罚"：

$$\mathcal{J}_{GRPO}(\theta)=\mathbb{E}\Big[\frac{1}{G}\sum_{i=1}^{G}\min\big(\rho_i\hat{A}_i,\ \text{clip}(\rho_i,1-\varepsilon,1+\varepsilon)\,\hat{A}_i\big)-\beta\,\mathbb{D}_{KL}(\pi_\theta\|\pi_{ref})\Big]$$

其中 ρ_i = π_θ(o_i|q)/π_θold(o_i|q) 是第 i 条回答的新旧策略概率比。工程实现中 KL 散度常用无偏估计量（DeepSeekMath 采用 k3 估计：π_ref/π_θ − log(π_ref/π_θ) − 1）。

GRPO 的收益：**省掉 Critic 网络后，训练时模型从 4 个降到 3 个，显存需求近乎减半**，同样的卡能训更大的模型。DeepSeekMath 与 DeepSeek-R1 均采用 GRPO——R1-Zero 甚至在无 SFT 的情况下直接从基座模型做 GRPO，验证了纯 RL 可以自发涌现推理行为（Aha Moment）。GRPO 已成为社区大规模 RL 训练的主流选择。

### 6. 全景流程：一条流水线看清四种算法

![[RLHF-GRPO-Pipeline.excalidraw]]

> [!note] 图解说（图由主会话稍后创建，先嵌入占位）
> 图从左到右依次为：预训练基座 → SFT 指令微调 → 奖励模型训练 → RL 对齐（此处分支对比 PPO 与 GRPO 两条路线）→ 对齐后模型。读图重点：① DPO 从 SFT 直接跳步到对齐，不走 RM 与在线采样；② PPO 路线在 RL 阶段需要 actor/critic/ref/reward 四个模型；③ GRPO 路线把 critic 删掉，用"同 prompt 一组回答"的组内相对分数替代；④ 无论哪条路线，终点都是同一个"对齐后模型"，只是成本与效果上限不同。

### 7. 为什么 GRPO 必须配合奖励模型微调

GRPO 只是优化器，**奖励信号的质量决定对齐效果的上限**。GRPO 的组内优势把"绝对好坏"压缩成"组内相对好坏"——如果 RM 把坏回答打高分（例如只看长度、不看事实），模型就会朝错误方向优化，且这种偏差会随在线训练自我强化（奖励黑客）。因此生产实践中 GRPO 前的 RM 训练不是可选项而是必选项：RM 要在目标领域数据上精调、要与最终应用的评价口径一致，必要时叠加规则奖励（格式校验、合规红线、拒答检测）组成复合奖励函数。

## 最小可运行 Demo

### Demo 1：DPO 最小可运行实现（TRL DPOTrainer）

```python
# pip install trl transformers datasets accelerate
from datasets import Dataset
from transformers import AutoModelForCausalLM, AutoTokenizer
from trl import DPOTrainer, DPOConfig

model_name = "Qwen/Qwen2.5-0.5B-Instruct"          # 任意 SFT 后的因果模型
model = AutoModelForCausalLM.from_pretrained(model_name)
tokenizer = AutoTokenizer.from_pretrained(model_name)

# 1) 偏好数据：每条含 prompt / chosen(好回答) / rejected(差回答)
train_data = Dataset.from_list([
    {"prompt": "解释什么是复利。",
     "chosen": "复利是把每期产生的利息加入本金，下一期按更大本金计息，收益随期数指数增长。",
     "rejected": "复利就是利息。"},
    {"prompt": "写一个判断质数的 Python 函数。",
     "chosen": "def is_prime(n):\n    if n < 2: return False\n    for i in range(2, int(n**0.5)+1):\n        if n % i == 0: return False\n    return True",
     "rejected": "def is_prime(n): return True"},
])

# 2) DPO 关键参数
args = DPOConfig(
    output_dir="./dpo-output",
    per_device_train_batch_size=2,
    learning_rate=5e-6,      # DPO 学习率要小：SFT 的 1/10 量级
    beta=0.1,                # 核心超参：越小越敢偏离 ref，越大越保守
    loss_type="sigmoid",     # 标准 DPO 损失；也可选 ipo / kto_pair
    max_length=512,
    max_prompt_length=128,   # prompt 与回答分开截断，防止偏好被截掉
    num_train_epochs=1,
)

trainer = DPOTrainer(
    model=model,             # 待训练策略
    ref_model=None,          # 传 None：TRL 自动复制一份冻结 ref
    args=args,
    train_dataset=train_data,
    tokenizer=tokenizer,
)
trainer.train()              # 全程无需 RM、无需在线采样
```

### Demo 2：GRPO 组内优势的纯 numpy 实现

```python
import numpy as np

def grpo_advantage(rewards: np.ndarray, eps: float = 1e-8) -> np.ndarray:
    """GRPO 组内相对优势：同 prompt 的 G 条回答为一组，
    优势 = (奖励 - 组均值) / 组标准差，替代 PPO 中 Critic 给出的优势估计。
    rewards: shape (num_groups, G)，每行是同 prompt 的一组采样奖励。"""
    mean = rewards.mean(axis=1, keepdims=True)            # 组内均值 = baseline
    std  = rewards.std(axis=1, keepdims=True)             # 组内标准差
    return (rewards - mean) / (std + eps)                 # eps 防 std=0 除零

# 模拟：2 个 prompt，各采样 4 条回答，RM 打分（假设已归一化到 0~1）
rewards = np.array([
    [0.2, 0.5, 0.8, 0.3],   # prompt A 的 4 条回答
    [0.9, 0.1, 0.4, 0.6],   # prompt B 的 4 条回答
])
print(grpo_advantage(rewards))
# 组内高于均值的回答优势为正（提高其生成概率），反之为负（压低其概率）；
# 两组之间互不影响——A 组 0.8 与 B 组 0.9 的优势值只取决于各自组内的相对位置。
```

## 进阶实践与常见坑

### 选型决策总表

| 算法 | 需 RM? | 需 Critic? | 需 Ref? | 采样方式 | 样本效率 | 显存 | 代表模型 |
|------|--------|-----------|---------|----------|----------|------|----------|
| PPO | ✅ | ✅ | ✅ | 在线 | 高（样本可多轮复用） | 最高（4 模型） | InstructGPT、ChatGPT 早期 |
| DPO | ❌ | ❌ | ✅（仅冻结推理） | 离线偏好对 | 中（数据一次性消费） | 低（2 模型） | Zephyr、NeuralChat |
| GRPO | ✅（可掺规则） | ❌ | ✅ | 在线组采样 | 高 | 中（3 模型） | DeepSeekMath、DeepSeek-R1 |

选型经验法则：**数据好、算力紧 → DPO 起步；要冲推理上限、有卡 → GRPO；只在需要严格在线探索且不差钱时才考虑完整 PPO。**

### 框架现状：TRL 与 verl

| 框架 | 定位 | 现状要点 |
|------|------|---------|
| TRL | Hugging Face 官方 RL 库 | 内置 SFTTrainer / RewardTrainer / DPOTrainer / GRPOTrainer / RLOOTrainer 全套训练器；单机友好、上手最快，适合 7B 级实验与教学；2025 年仍在快速迭代（如 v0.25.0 发布记录所示） |
| verl | 字节跳动火山引擎开源的大规模 RL 框架 | 专为百 B 级、千卡级 RL 训练设计，hybrid 编程模型（单进程 controller + 分布式 worker rollout），支持 PPO/GRPO 等主流算法，是社区大规模 GRPO 复现的主流选择 |

实践路径：**小规模验证用 TRL（本文 Demo 即 TRL 用法），上规模换 verl**，两者算法概念互通、迁移成本低。DeepSeek-R1 论文未公开其内部训练框架（自研基础设施，训练于 2048 块 H800），不影响社区用 verl/TRL 复现其 GRPO 管线。

### 奖励模型选型：RewardBench 排行榜

RewardBench（Lambert et al., 2024）是奖励模型的权威评测集，覆盖 Chat / Chat Hard / Safety / Reasoning 四类共 2985 个偏好对，用"RM 认为好回答分更高"的准确率排序。选型要点：

| 选型关注点 | 建议 |
|-----------|------|
| 通用能力基线 | 查 RewardBench 官方榜单，榜单前列长期由 70B 级模型占据，如 infly/INF-ORM-Llama3.1-70B（95.1 分）与 Skywork/Skywork-Critic-Llama-3.1-70B 等（具体名次随更新变动，使用时以榜单实时数据为准） |
| 领域适配 | 通用 RM 在金融/医疗等垂直领域打分偏差大，需用本领域偏好对精调 |
| 与上线口径一致 | RM 训练数据的分级标准必须与产品实际评价标准（合规、准确性、可读性）对齐 |
| 成本约束 | 70B RM 打分贵；预算有限可用 7B-14B 级 RM + 规则奖励组合 |

> [!warning] RM 数据的坑
> 偏好对数据天然带三种偏差：**长度偏差**（标注者偏爱长回答）、**位置偏差**（先看到的那条更容易被选）、**风格偏差**（华丽文风 ≠ 事实正确）。构建 RM 数据时要做长度归一化、随机化展示顺序，并在评测集上单列长度对抗样本验证。

### 金融垂直案例：SFT LoRA → RM 训练 → GRPO 对齐

把上面的理论串成一条可落地的金融领域对齐流水线：

1. **SFT LoRA 打底座**：收集 3k-10k 条金融问答/研报摘要指令数据，用 LoRA 微调领域基座（实操详见 [[LoRA参数高效微调实战]]），让模型先"会说金融行话"；
2. **偏好对与 RM 训练**：对同一金融问题采样 2-4 条回答，由资深分析师（或教师模型 + 规则）排序，构造 (chosen, rejected) 对（数据构建见 [[微调数据工程与模型蒸馏]]）；用 Llama-Factory 的 `stage: rm` 或 TRL RewardTrainer 训练领域 RM，并在金融偏好子集上验证打分一致性；
3. **GRPO 对齐**：以 SFT LoRA 模型为 actor，奖励 = 领域 RM 打分 + 规则奖励（合规红线一票否决、格式校验、引用来源检测）；同 prompt 采样 G=8-16 条回答做组内优势，β 控制偏离幅度；
4. **上线评估**：金融基准（财报问答、风险提示）+ 人工抽检，重点盯奖励黑客（模型学会"话多 + 套模板"刷分而非答对）。

> [!info] 复合奖励函数示意
> r_total = w1·RM 分数 + w2·格式分 + w3·合规分（违规直接 −∞）。规则奖励是 GRPO 的免费午餐：不占显存、可解释、能硬性兜底。

### 常见坑清单

| 坑 | 现象 | 对策 |
|----|------|------|
| 奖励黑客 | 分数涨、质量降：模型学会刷长度/套模板 | 长度归一化惩罚 + 复合奖励 + 定期人工抽检 |
| KL 失控 | 训练后期回答变成乱码/复读 | 加大 β 或降低学习率，监控每步 KL 值 |
| ref 未冻结 | DPO/GRPO 中参考模型被误更新，KL 失去锚点 | ref 全程 eval 模式，梯度置零 |
| GRPO 组内方差为零 | 同组奖励全相同 → 优势除零爆炸 | 优势分母加 eps；组大小 G ≥ 4 |
| 组太小 | G=2 时优势只有两个极端值，噪声大 | G 取 8-16，批内重排保证多样性 |
| RM 过拟合偏好集 | 训练集打分准、线上打分飘 | 划留出偏好集早停；数据加长度/位置对抗样本 |
| SFT 底座太弱 | RL 起步即崩，奖励再准也拉不动 | 先补 SFT 数据量/质量，再上 RL（数据上限论） |
| 学习率沿用 SFT | 1e-4 直接跑 RL 立刻发散 | RL 阶段 lr 降一个数量级（1e-6 ~ 5e-6 起调） |

## 相关文档

- [[AI大模型开发]] — 知识库 LLM 开发总笔记，对齐篇的预训练/SFT 背景可交叉阅读；
- [[AI-Dev-KB-Home]] — AI 开发子 Vault 首页 MOC，本文所在章节的导航入口；
- [[微调数据工程与模型蒸馏]] — 本文的上游：偏好对 (chosen/rejected) 怎么造、RM 训练数据怎么构建；
- [[LoRA参数高效微调实战]] — 金融案例第一步 SFT LoRA 的完整实操；
- [[预训练迷你Kimi-K3实录-章节总结]] — 对齐的上游：基座模型预训练实录，理解"底座决定上限"。

## 参考资料

- GRPO / DeepSeekMath（arXiv:2402.03300）: https://arxiv.org/abs/2402.03300
- DeepSeek-R1（arXiv:2501.12948）: https://arxiv.org/abs/2501.12948
- DeepSeek-R1 蒸馏方案社区讨论（GitHub Issue #113）: https://github.com/deepseek-ai/DeepSeek-R1/issues/113
- DPO（arXiv:2305.18290）: https://arxiv.org/abs/2305.18290
- PPO（arXiv:1707.06347）: https://arxiv.org/abs/1707.06347
- InstructGPT（arXiv:2203.02155）: https://arxiv.org/abs/2203.02155
- GRPO 算法公式参考（skillsbench 仓库）: https://raw.githubusercontent.com/benchflow-ai/skillsbench/main/tasks/debug-trl-grpo/environment/skills/grpo/references/grpo-algorithm.md
- TRL 框架（GitHub）: https://github.com/huggingface/trl
- TRL v0.25.0 发布记录: https://github.com/huggingface/trl/releases/tag/v0.25.0
- TRL GRPO Trainer 文档: https://mintlify.wiki/huggingface/trl/grpo-trainer
- verl 框架（GitHub）: https://github.com/volcengine/verl
- RewardBench（arXiv:2403.13787）: https://arxiv.org/abs/2403.13787
- RewardBench 排行榜数据: https://benchmarklist.com/benchmarks/rewardbench/
- Long-form RewardBench（INFORM-Llama3.1-70B 95.1 分数据来源）: https://ar5iv.labs.arxiv.org/html/2603.12963

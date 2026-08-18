#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gemma_scope_features.py — 用 Gemma Scope SAE 扫描「一句话点亮了哪些单义特征」
============================================================================

对应「核磁 / fMRI 式扫描」（哪里亮）：
    直接看神经元没用（叠加/多义），得先用稀疏自编码器 (SAE) 把某层激活
    拆成上万个「单义特征」。本脚本加载 Google DeepMind 的 Gemma Scope
    预训练 SAE，跑一句话，看哪些特征被点亮，并给出每个特征的 Neuronpedia
    链接 —— 点进去就是人类可读的特征含义（如「金门大桥」「Python 代码」）。

配套文章：articles/给LLM做脑扫描-可解释性技术全景.md（第三层 · SAE 特征扫描）

⚠️ 两个前提（比 logit_lens_gpt2.py 重）：
  1. Gemma 2 是【门控模型】：先去 https://huggingface.co/google/gemma-2-2b
     点同意许可，再 `huggingface-cli login` 填 token，否则加载会 401。
  2. 【显存/内存】：gemma-2-2b bf16 约 5GB，fp32 约 10GB。建议 GPU；
     纯 CPU 能跑但慢，且需 ≥16GB 内存。

依赖安装（针对 SAELens ≥ 4.x 编写；API 若有变见函数内注释）：
    pip install sae-lens transformer-lens torch
    # 可选（--explain 拉取特征描述）：无需额外依赖，用 stdlib urllib

用法：
    huggingface-cli login          # 首次，填已接受 Gemma 许可的 token
    python3 gemma_scope_features.py --prompt "The Golden Gate Bridge is beautiful"
    python3 gemma_scope_features.py --prompt "..." --layer 20 --width 16k --topk 15
    python3 gemma_scope_features.py --prompt "..." --explain   # 顺带拉 Neuronpedia 描述
"""

import argparse
import json
import sys
import urllib.request


def parse_args():
    p = argparse.ArgumentParser(description="Gemma Scope SAE 特征扫描")
    p.add_argument("--model", default="gemma-2-2b", help="TransformerLens 模型名")
    p.add_argument("--prompt", default="The Golden Gate Bridge is a beautiful landmark",
                   help="要扫描的输入句子")
    p.add_argument("--layer", type=int, default=20, help="扫描哪一层的残差流 SAE")
    p.add_argument("--width", default="16k", help="SAE 宽度：16k / 65k / 262k ...")
    p.add_argument("--topk", type=int, default=12, help="展示前 K 个最活跃特征")
    p.add_argument("--agg", choices=["last", "max"], default="max",
                   help="跨 token 聚合方式：last=只看末 token，max=取整句最大激活")
    p.add_argument("--explain", action="store_true",
                   help="best-effort 拉取 Neuronpedia 特征描述（需联网）")
    p.add_argument("--device", default=None, help="cpu / cuda（默认自动）")
    p.add_argument("--dtype", default="bfloat16", help="bfloat16 / float32")
    return p.parse_args()


def fetch_explanation(model_id, source_set, idx, timeout=8):
    """best-effort：从 Neuronpedia 拉该特征的自动解释文本。失败返回 None。"""
    url = f"https://www.neuronpedia.org/api/feature/{model_id}/{source_set}/{idx}"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "logit-lens-demo"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = json.load(r)
        exps = data.get("explanations") or []
        if exps:
            return exps[0].get("description")
    except Exception:
        return None
    return None


def main():
    args = parse_args()

    try:
        import torch
        from sae_lens import SAE, HookedSAETransformer
    except ImportError as e:
        sys.exit(f"缺少依赖：pip install sae-lens transformer-lens torch\n({e})")

    device = args.device or ("cuda" if torch.cuda.is_available() else "cpu")
    dtype = getattr(torch, args.dtype)
    print(f"设备={device} dtype={args.dtype}")

    # ── 1. 加载 Gemma 2 ────────────────────────────────────────────────
    print(f"加载模型 {args.model} ...（门控模型，需已登录 HF 并接受许可）")
    model = HookedSAETransformer.from_pretrained(
        args.model, device=device, dtype=dtype)
    model.eval()

    # ── 2. 加载对应层的 Gemma Scope 残差流 SAE ──────────────────────────
    #   canonical 版本每层每宽度只选一个 L0，sae_id 形如 layer_20/width_16k/canonical
    release = "gemma-scope-2b-pt-res-canonical"
    sae_id = f"layer_{args.layer}/width_{args.width}/canonical"
    print(f"加载 SAE：{release}  {sae_id}")
    loaded = SAE.from_pretrained(release=release, sae_id=sae_id, device=device)
    # SAELens 版本差异兼容：老版返回 (sae, cfg, sparsity)，新版直接返回 sae
    sae = loaded[0] if isinstance(loaded, (tuple, list)) else loaded
    sae = sae.to(device)

    hook_name = sae.cfg.hook_name              # 如 blocks.20.hook_resid_post
    print(f"SAE 挂载点：{hook_name}，特征数 d_sae={sae.cfg.d_sae}\n")

    # ── 3. 前向 + 取该层激活 + SAE 编码 ─────────────────────────────────
    tokens = model.to_tokens(args.prompt)
    str_tokens = model.to_str_tokens(args.prompt)
    with torch.no_grad():
        _, cache = model.run_with_cache(tokens, names_filter=hook_name)
        acts = cache[hook_name]                # [1, seq, d_model]
        feature_acts = sae.encode(acts)[0]     # [seq, d_sae]

    # ── 4. 跨 token 聚合 → top-k 特征 ──────────────────────────────────
    if args.agg == "last":
        scores = feature_acts[-1]              # 只看末 token
    else:
        scores = feature_acts.max(dim=0).values   # 整句每个特征的最大激活
    top_vals, top_idx = scores.float().topk(args.topk)

    # Neuronpedia 的 source-set id，如 20-gemmascope-res-16k
    np_source = f"{args.layer}-gemmascope-res-{args.width}"
    np_model = "gemma-2-2b"

    print(f"Prompt: {args.prompt!r}")
    print(f"token: {str_tokens}\n")
    print(f"第 {args.layer} 层最活跃的 {args.topk} 个 SAE 特征（agg={args.agg}）：")
    print("-" * 78)
    for rank, (val, idx) in enumerate(zip(top_vals.tolist(), top_idx.tolist()), 1):
        url = f"https://www.neuronpedia.org/{np_model}/{np_source}/{idx}"
        line = f"{rank:>2}. feat#{idx:<6} act={val:6.2f}  {url}"
        if args.explain:
            desc = fetch_explanation(np_model, np_source, idx)
            if desc:
                line += f"\n      ↳ {desc}"
        print(line)

    print("-" * 78)
    print("提示：点开 Neuronpedia 链接即可看到该特征的人类可读含义与激活样例。")
    if not args.explain:
        print("      加 --explain 可尝试直接把描述拉到终端（best-effort）。")


if __name__ == "__main__":
    main()

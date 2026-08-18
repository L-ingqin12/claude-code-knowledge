#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
logit_lens_gpt2.py — 在 GPT-2 上跑 Logit Lens 逐层扫描
================================================================

Logit Lens 原理（对应「CT 断层扫描」）：
    Transformer 每个 token 有一条贯穿所有层的残差流 (residual stream)。
    把「每一层」的残差流拿出来，套上模型最终的 LayerNorm + Unembed，
    直接投影到词表，就能看到「模型在第几层就已经想好要输出哪个词」。
    答案往往在中后层才突然成型 —— 这就是逐层切片的意义。

配套文章：articles/给LLM做脑扫描-可解释性技术全景.md（第三层 · 第 1 步）

依赖安装：
    pip install transformer_lens torch
    # 可选（画图）：pip install matplotlib

用法：
    python3 logit_lens_gpt2.py
    python3 logit_lens_gpt2.py --prompt "The Eiffel Tower is located in the city of"
    python3 logit_lens_gpt2.py --prompt "..." --answer " Paris" --topk 5
    python3 logit_lens_gpt2.py --prompt "..." --plot lens.png

首次运行会自动下载 GPT-2 small（约 500MB）。CPU 即可，无需 GPU。
"""

import argparse
import sys

import torch


def parse_args():
    p = argparse.ArgumentParser(description="GPT-2 Logit Lens 逐层扫描")
    p.add_argument("--model", default="gpt2",
                   help="模型名（gpt2 / gpt2-medium / gpt2-large / gpt2-xl）")
    p.add_argument("--prompt", default="The Eiffel Tower is located in the city of",
                   help="输入 prompt，脚本预测其后的下一个 token")
    p.add_argument("--answer", default=None,
                   help="要追踪的目标 token（含前导空格，如 ' Paris'）。"
                        "不指定则自动追踪模型最终预测的 top-1 token")
    p.add_argument("--topk", type=int, default=5, help="每层展示的 top-k 候选数")
    p.add_argument("--plot", default=None, metavar="PNG",
                   help="把目标 token 的逐层概率曲线存成 PNG（需 matplotlib）")
    p.add_argument("--device", default="cpu", help="cpu 或 cuda")
    return p.parse_args()


def main():
    args = parse_args()

    try:
        from transformer_lens import HookedTransformer
    except ImportError:
        sys.exit("缺少依赖：pip install transformer_lens torch")

    print(f"加载模型 {args.model} ...（首次运行需下载）")
    # from_pretrained 默认 fold_ln=True：把 LayerNorm 的可学习缩放折进后续权重，
    # 于是 ln_final 变成纯 centering+normalize，这正是 logit lens 的标准做法。
    model = HookedTransformer.from_pretrained(args.model, device=args.device)
    model.eval()

    tokens = model.to_tokens(args.prompt)          # [1, seq]，默认前置 BOS
    str_tokens = model.to_str_tokens(args.prompt)
    print(f"\nPrompt: {args.prompt!r}")
    print(f"切分为 {len(str_tokens)} 个 token（含 BOS）：{str_tokens}\n")

    # 一次前向，缓存所有中间激活
    with torch.no_grad():
        final_logits, cache = model.run_with_cache(tokens)

    # 只看最后一个位置（预测「下一个 token」）
    last = -1

    # 确定要追踪的目标 token id
    if args.answer is not None:
        ans_ids = model.to_tokens(args.answer, prepend_bos=False)[0]
        target_id = ans_ids[0].item()
        target_str = model.to_string(target_id)
        note = "（用户指定）"
    else:
        target_id = final_logits[0, last].argmax().item()
        target_str = model.to_string(target_id)
        note = "（模型最终 top-1）"
    print(f"追踪目标 token：{target_str!r}  id={target_id} {note}\n")

    n_layers = model.cfg.n_layers
    ln_final = model.ln_final
    unembed = model.unembed

    def resid_to_logits(resid_vec):
        """把某层残差流（最后一个位置）投影到词表。resid_vec: [d_model]"""
        x = resid_vec.reshape(1, 1, -1)          # [1,1,d_model]
        x = ln_final(x)                          # 套最终 LayerNorm
        logits = unembed(x)[0, 0]                # -> [d_vocab]
        return logits

    # 逐层构建：layer 0 = 词嵌入(resid_pre[0])，之后每个 block 的 resid_post
    rows = []
    resid_stack = [("embed", cache["resid_pre", 0][0, last])]
    for layer in range(n_layers):
        resid_stack.append((f"blk{layer:02d}", cache["resid_post", layer][0, last]))

    target_probs = []
    for name, resid_vec in resid_stack:
        logits = resid_to_logits(resid_vec)
        probs = torch.softmax(logits, dim=-1)

        # 该层 top-k
        top_p, top_i = probs.topk(args.topk)
        topk_str = "  ".join(
            f"{model.to_string(i.item())!r}:{p.item():.2f}"
            for p, i in zip(top_p, top_i)
        )

        # 目标 token 在该层的概率与排名
        tgt_prob = probs[target_id].item()
        tgt_rank = (probs > probs[target_id]).sum().item() + 1
        target_probs.append(tgt_prob)

        rows.append((name, tgt_rank, tgt_prob, topk_str))

    # 打印表格
    print(f"{'层':<7} {'目标rank':>7} {'目标prob':>9}   top-{args.topk} 候选")
    print("-" * 88)
    for name, rank, prob, topk_str in rows:
        # 目标 token 冲进 top-1 的那一层高亮标记
        mark = " ★" if rank == 1 else "  "
        print(f"{name:<7} {rank:>7} {prob:>9.3f}{mark} {topk_str}")

    # 一致性自检：最后一层的 logit lens 应与模型真实输出一致
    lens_top = resid_to_logits(resid_stack[-1][1]).argmax().item()
    real_top = final_logits[0, last].argmax().item()
    ok = "✓" if lens_top == real_top else "✗ (异常)"
    print("-" * 88)
    print(f"自检：末层 logit lens top-1 == 模型真实 top-1 ? {ok}  "
          f"({model.to_string(real_top)!r})")

    # 可选画图
    if args.plot:
        try:
            import matplotlib.pyplot as plt
        except ImportError:
            print("\n跳过画图：pip install matplotlib")
            return
        labels = [r[0] for r in rows]
        plt.figure(figsize=(10, 4))
        plt.plot(range(len(target_probs)), target_probs, marker="o")
        plt.xticks(range(len(labels)), labels, rotation=45, ha="right", fontsize=8)
        plt.ylabel(f"P({target_str!r})")
        plt.title(f"Logit Lens：目标 token 逐层概率  ({args.model})")
        plt.grid(alpha=0.3)
        plt.tight_layout()
        plt.savefig(args.plot, dpi=130)
        print(f"\n已保存曲线图：{args.plot}")


if __name__ == "__main__":
    main()

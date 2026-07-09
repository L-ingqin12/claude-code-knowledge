#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
circuit_tracer_attribution.py — 生成「归因图」，复现给 Claude 做脑扫描那套
============================================================================

对应「三维 / 全脑扫描」（还原计算通路）：
    用跨层转码器 (cross-layer transcoder) 把模型换成可读特征，再对【一个
    具体 prompt】画出【归因图 attribution graph】—— 一张「这句话是怎么被
    一步步算出来的」的电路流程图。这正是 Anthropic《On the Biology of a
    Large Language Model》(2025) 里扫出 Claude 怎么做加法、写诗提前押韵的方法。

配套文章：articles/给LLM做脑扫描-可解释性技术全景.md（第四层 · 归因图 / 电路追踪）

────────────────────────────────────────────────────────────────────────────
★ 先看零代码方案（多数人应先用这个）
    直接打开 https://www.neuronpedia.org/gemma-2-2b ，输入一句话，在线生成
    并交互浏览归因图，完全不用装库、不用显卡。本脚本是想【本地/批量/离线】
    跑时才需要。
────────────────────────────────────────────────────────────────────────────

⚠️ 三个前提（三条路径里最重、最难验证的一条）：
  1. 库年轻、API 会变：本脚本按开源库 `circuit-tracer`
     (github.com/safety-research/circuit-tracer) 的 quickstart 写。
     跑之前请对照该仓库【当前 README】核对函数签名，可能已调整。
  2. 门控 + 算力：默认 google/gemma-2-2b 是门控模型（需 HF 登录+接受许可），
     且归因计算需要转码器权重 + 反传，【实际需要 GPU】(bf16, 显存建议 ≥16GB)。
     纯 CPU 基本跑不动。
  3. 可视化靠前端：归因图要在 Neuronpedia 前端（本地或线上）里看，脚本
     产出 graph 文件后用内置本地服务器打开。

依赖安装：
    pip install circuit-tracer          # 会带 transformer-lens / torch 等
    huggingface-cli login               # 需已接受 gemma-2-2b 许可

用法：
    python3 circuit_tracer_attribution.py --prompt "The capital of France is"
    python3 circuit_tracer_attribution.py --prompt "..." --serve      # 产图并起本地前端
    python3 circuit_tracer_attribution.py --prompt "..." --model google/gemma-2-2b \
        --transcoder gemma --out graph.pt --slug france
"""

import argparse
import sys


def parse_args():
    p = argparse.ArgumentParser(description="circuit-tracer 归因图生成")
    p.add_argument("--prompt", default="The capital of France is",
                   help="要追踪的 prompt")
    p.add_argument("--model", default="google/gemma-2-2b",
                   help="HF 模型名（gemma-2-2b / meta-llama/Llama-3.2-1B）")
    p.add_argument("--transcoder", default="gemma",
                   help="预训练转码器集名：gemma / llama（须与 --model 匹配）")
    p.add_argument("--out", default="graph.pt", help="归因图输出文件 (.pt)")
    p.add_argument("--slug", default="demo-graph", help="前端展示用的图名 slug")
    p.add_argument("--graph-dir", default="./graph_files",
                   help="前端可视化文件目录")
    p.add_argument("--node-threshold", type=float, default=0.8,
                   help="剪枝：保留累计影响 ≥ 此比例的节点")
    p.add_argument("--edge-threshold", type=float, default=0.98,
                   help="剪枝：保留累计影响 ≥ 此比例的边")
    p.add_argument("--serve", action="store_true",
                   help="产图后起本地 Neuronpedia 前端浏览")
    p.add_argument("--port", type=int, default=8032, help="本地前端端口")
    p.add_argument("--dtype", default="bfloat16", help="bfloat16 / float32")
    return p.parse_args()


def main():
    args = parse_args()

    try:
        import torch
        # 注意：以下导入路径以 circuit-tracer 当前版本为准，若报 ImportError
        # 请对照仓库 README 调整（库仍在快速迭代）。
        from circuit_tracer import ReplacementModel, attribute
        from circuit_tracer.utils import create_graph_files
    except ImportError as e:
        sys.exit(
            "缺少/不匹配依赖：pip install circuit-tracer\n"
            f"（若已安装仍报错，多半是 API 变了，请查 "
            "github.com/safety-research/circuit-tracer 的当前 README）\n{}".format(e))

    if not torch.cuda.is_available():
        print("⚠️  未检测到 CUDA：归因计算在 CPU 上基本跑不动，仅供 dry-run。")

    dtype = getattr(torch, args.dtype)

    # ── 1. 用转码器把模型换成「可读特征」版本 ──────────────────────────
    print(f"加载 ReplacementModel：{args.model} + 转码器[{args.transcoder}] ...")
    model = ReplacementModel.from_pretrained(
        args.model, args.transcoder, dtype=dtype)

    # ── 2. 对该 prompt 计算归因图 ──────────────────────────────────────
    print(f"计算归因图，prompt={args.prompt!r} ...（较慢，需要反传）")
    graph = attribute(
        prompt=args.prompt,
        model=model,
        max_n_logits=10,          # 追踪概率最高的前 N 个输出 token
        desired_logit_prob=0.95,  # 覆盖到累计 95% 概率质量
        batch_size=256,
        verbose=True,
    )
    graph.to_pt(args.out)
    print(f"已保存归因图：{args.out}")

    # ── 3. 生成前端可视化文件（供 Neuronpedia 前端渲染）────────────────
    print("生成可视化文件（剪枝节点/边）...")
    create_graph_files(
        graph_or_path=args.out,
        slug=args.slug,
        output_path=args.graph_dir,
        node_threshold=args.node_threshold,
        edge_threshold=args.edge_threshold,
    )
    print(f"可视化文件已写入：{args.graph_dir}")

    # ── 4. 可选：起本地前端浏览 ────────────────────────────────────────
    if args.serve:
        from circuit_tracer.frontend.local_server import serve
        print(f"启动本地前端： http://localhost:{args.port}  (Ctrl-C 停止)")
        server = serve(data_dir=args.graph_dir, port=args.port)
        try:
            server.process.wait()
        except (KeyboardInterrupt, AttributeError):
            pass
    else:
        print("\n下一步：加 --serve 起本地前端，或把 graph_files 传到 Neuronpedia 查看。")
        print("零代码替代：直接在 https://www.neuronpedia.org/gemma-2-2b 在线生成同类图。")


if __name__ == "__main__":
    main()

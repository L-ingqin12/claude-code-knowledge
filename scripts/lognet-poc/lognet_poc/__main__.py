"""CLI entrypoints: build / query / subgraph.

Examples:
  python -m lognet_poc build <pkg_dir> --db out/lognet.db
  python -m lognet_poc query --db out/lognet.db --keyword ext4_io_error --limit 20
  python -m lognet_poc subgraph --db out/lognet.db --node 42 --depth 2 --window 5
"""
from __future__ import annotations

import argparse
import json
import sys


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="lognet_poc")
    sub = ap.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("build")
    b.add_argument("pkg_dir")
    b.add_argument("--db", required=True)

    q = sub.add_parser("query")
    q.add_argument("--db", required=True)
    q.add_argument("--keyword")
    q.add_argument("--ts-from", type=float)
    q.add_argument("--ts-to", type=float)
    q.add_argument("--pid", type=int)
    q.add_argument("--tid", type=int)
    q.add_argument("--tag")
    q.add_argument("--level")
    q.add_argument("--limit", type=int, default=50)

    s = sub.add_parser("subgraph")
    s.add_argument("--db", required=True)
    s.add_argument("--node", type=int, required=True)
    s.add_argument("--depth", type=int, default=2)
    s.add_argument("--window", type=float, default=5.0)
    s.add_argument("--budget-tokens", type=int, default=8000)

    args = ap.parse_args(argv)

    if args.cmd == "build":
        from .builder import build_package

        bld, _conn = build_package(args.pkg_dir, args.db)
        print("built:", args.db)
        print("stats:", json.dumps(bld.stats, ensure_ascii=True))
        return 0

    if args.cmd == "query":
        from .query import query_logs

        res = query_logs(
            args.db,
            args.keyword,
            ts_from=args.ts_from,
            ts_to=args.ts_to,
            pid=args.pid,
            tid=args.tid,
            tag=args.tag,
            level=args.level,
            limit=args.limit,
        )
        print("total:", res["total"])
        for it in res["items"]:
            print(
                "#%-6d %.3f %-6s pid=%-6s lvl=%s cnt=%-4d [%s] %s"
                % (
                    it["id"],
                    it["ts"],
                    it["source"],
                    it["pid"],
                    it["level"],
                    it["count"],
                    it["tag"],
                    it["snippet"][:90].replace("\n", " "),
                )
            )
        return 0

    if args.cmd == "subgraph":
        from .subgraph import get_subgraph

        sg = get_subgraph(
            args.db,
            args.node,
            depth=args.depth,
            window_s=args.window,
            budget_tokens=args.budget_tokens,
        )
        print(
            "nodes=%d edges=%d truncated=%s"
            % (len(sg["nodes"]), len(sg["edges"]), sg["truncated"])
        )
        print(json.dumps(sg, ensure_ascii=True)[:4000])
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())

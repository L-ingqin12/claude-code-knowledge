"""get_subgraph — local graph-expansion primitive (design doc §六 渐进展开).

BFS (undirected) from a node, pruned to a time window around the ROOT,
with a token-budget guard and a visited-set cycle guard. Output stays
bounded so one hop never blows the agent context (≤ budget_tokens est.).
"""
from __future__ import annotations

import json
import sqlite3


def _node_row(conn, nid: int):
    return conn.execute(
        "SELECT id,kind,ts,source,pid,tid,tag,level,payload FROM nodes WHERE id=?",
        (nid,),
    ).fetchone()


def _summary(payload: str | None, n: int = 80) -> str:
    return (payload or "")[:n]


def get_subgraph(
    db_path: str,
    node_id: int,
    depth: int = 2,
    window_s: float = 5.0,
    budget_tokens: int = 8000,
) -> dict:
    conn = sqlite3.connect(db_path)
    try:
        root = _node_row(conn, node_id)
        if root is None:
            raise ValueError(f"node {node_id} not found")
        root_ts = root[2]

        out: dict = {
            "root": node_id,
            "window_s": window_s,
            "depth": depth,
            "nodes": [],
            "edges": [],
            "truncated": False,
        }

        def node_obj(r) -> dict:
            return {
                "id": r[0],
                "kind": r[1],
                "ts": r[2],
                "source": r[3],
                "tag": r[6],
                "level": r[7],
                "summary": _summary(r[8]),
            }

        seen = {node_id}
        # root is unconditional; size tracked incrementally (O(1) budget probes)
        out["nodes"].append(node_obj(root))
        size = len(json.dumps(out))
        frontier = [node_id]
        for _level in range(max(1, depth)):
            nxt: list[int] = []
            for cur in frontier:
                adj = conn.execute(
                    "SELECT src,dst,etype,weight FROM edges WHERE src=? "
                    "UNION SELECT src,dst,etype,weight FROM edges WHERE dst=?",
                    (cur, cur),
                ).fetchall()
                for src, dst, etype, weight in adj:
                    nb_id = dst if src == cur else src
                    if nb_id in seen:
                        continue
                    nb = _node_row(conn, nb_id)
                    if nb is None:
                        continue
                    if abs((nb[2] or 0.0) - root_ts) > window_s:
                        continue
                    cand_node = node_obj(nb)
                    cand_edge = {"src": src, "dst": dst, "etype": etype, "weight": weight}
                    cand_len = (
                        len(json.dumps(cand_node)) + len(json.dumps(cand_edge)) + 4
                    )
                    if size + cand_len > budget_tokens * 4:
                        out["truncated"] = True
                        nxt = []
                        break
                    seen.add(nb_id)
                    out["nodes"].append(cand_node)
                    out["edges"].append(cand_edge)
                    size += cand_len
                    nxt.append(nb_id)
                if out["truncated"]:
                    break
            if out["truncated"] or not nxt:
                break
            frontier = nxt
        return out
    finally:
        conn.close()

#!/usr/bin/env python3
"""Scores evaluation runs: score.py RUNS_DIR [--out results.json]

Each RUNS_DIR/<system>.jsonl holds one line per claim. A claim is stale when its
label is OUTDATED, and every system flags one by saying OUTDATED or CONTRADICTED,
because S1 can only say a claim is false. So a CONTRADICTED verdict on a claim
not labelled stale counts as a false alarm. strict_recall also shows how many
stale claims got the exact verdict OUTDATED. Confidence intervals are a seeded
percentile bootstrap over claims.
"""
import argparse
import json
import pathlib
import random
import sys
from collections import Counter

FLAGGED = {"OUTDATED", "CONTRADICTED"}
BOOTSTRAP = 2000


def prf(pairs):
    """Precision, recall and F1 of (is_stale, flagged) pairs. None if undefined."""
    tp = sum(1 for s, f in pairs if s and f)
    fp = sum(1 for s, f in pairs if not s and f)
    fn = sum(1 for s, f in pairs if s and not f)
    precision = tp / (tp + fp) if tp + fp else None
    recall = tp / (tp + fn) if tp + fn else None
    f1 = 2 * tp / (2 * tp + fp + fn) if tp else (0.0 if fp + fn else None)
    return precision, recall, f1


def interval(pairs, seed=7):
    rng = random.Random(seed)
    values = sorted(v for v in (prf(rng.choices(pairs, k=len(pairs)))[2] for _ in range(BOOTSTRAP)) if v is not None)
    if not values:
        return None
    return [values[int(0.025 * len(values))], values[int(0.975 * len(values)) - 1]]


def score(rows):
    pairs = [(r["expected_verdict"] == "OUTDATED", r["verdict"] in FLAGGED) for r in rows]
    stale = [r for r in rows if r["expected_verdict"] == "OUTDATED"]
    precision, recall, f1 = prf(pairs)
    n = len(rows)
    latencies = sorted(r.get("latency_ms", 0) for r in rows)
    return {"claims": n, "stale_precision": precision, "stale_recall": recall, "stale_f1": f1, "stale_f1_ci95": interval(pairs),
            "strict_recall": sum(r["verdict"] == "OUTDATED" for r in stale) / len(stale) if stale else None,
            "exact_verdict_rate": sum(r["verdict"] == r["expected_verdict"] for r in rows) / n,
            "coverage": sum(r["verdict"] != "NOT_CHECKED" for r in rows) / n,
            "tavily_credits": sum(r.get("credits", 0) for r in rows), "llm_calls": sum(r.get("llm_calls", 0) for r in rows),
            "latency_ms_p50": latencies[n // 2], "latency_ms_p95": latencies[min(n - 1, int(n * 0.95))],
            "verdicts": dict(sorted(Counter(r["verdict"] for r in rows).items()))}


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("runs", type=pathlib.Path)
    parser.add_argument("--out", type=pathlib.Path)
    args = parser.parse_args()
    results = {}
    for path in sorted(args.runs.glob("S*.jsonl")):
        rows = [json.loads(line) for line in path.read_text().splitlines()]
        if rows:
            results[path.stem] = score(rows)
    if not results:
        sys.exit(f"no runs in {args.runs}")
    text = json.dumps(results, indent=2, sort_keys=True)
    print(text)
    if args.out:
        args.out.write_text(text + "\n")


if __name__ == "__main__":
    main()

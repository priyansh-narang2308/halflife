#!/usr/bin/env python3
"""Scores the labelling review: review.py A.csv B.csv [C.csv]

A and B are copies of review-sheet.csv filled in independently. Prints Cohen's
kappa and each disagreement. With C, the third labeller's sheet, it also writes
final-labels.csv: the agreed label, or C's where A and B differ.
"""
import csv
import pathlib
import sys
from collections import Counter

LABELS = {"CURRENT", "OUTDATED", "CONTRADICTED", "CONFLICTING", "UNVERIFIABLE"}


def read(path):
    with open(path, newline="", encoding="utf-8") as f:
        labels = {r["id"]: r["label"].strip().upper() for r in csv.DictReader(f)}
    bad = {v for v in labels.values() if v} - LABELS
    if bad:
        sys.exit(f"{path}: unknown labels {sorted(bad)}")
    return labels


def kappa(a, b):
    """Cohen's kappa of two equal-length label lists."""
    n = len(a)
    observed = sum(x == y for x, y in zip(a, b)) / n
    ca, cb = Counter(a), Counter(b)
    expected = sum(ca[k] * cb[k] for k in ca) / (n * n)
    return 1.0 if expected == 1 else (observed - expected) / (1 - expected)


def main():
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    a, b = read(sys.argv[1]), read(sys.argv[2])
    both = sorted(i for i in a if a[i] and b.get(i))
    if not both:
        sys.exit("no claim is labelled by both")
    print(f"{len(both)} of {len(a)} claims labelled by both; kappa = {kappa([a[i] for i in both], [b[i] for i in both]):.3f}")
    differ = [i for i in both if a[i] != b[i]]
    for i in differ:
        print(f"  {i}: {a[i]} vs {b[i]}")
    if len(sys.argv) == 4:
        c = read(sys.argv[3])
        missing = [i for i in differ if not c.get(i)]
        if missing:
            sys.exit(f"the third labeller has not decided {len(missing)} disagreements")
        out = pathlib.Path(sys.argv[1]).parent / "final-labels.csv"
        with out.open("w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["id", "label"])
            w.writerows((i, c[i] if a[i] != b[i] else a[i]) for i in both)
        print(f"wrote {out}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Builds HL-Claims v1 from data/hl-claims-sources (see fetch.sh).

Deterministic: a question is used at most once across all strata, questions are
picked by a salted hash, and the dev/test split is drawn per stratum by a second
hash, so no question can leak between splits. MANIFEST.json pins the sources and
freezes the split; a rebuild that would change either fails unless --freeze is
given, which is only for the first build.

Labels are DRAFTS made by rule. They are not ground truth until the review in
README.md is done: label_status stays "draft_pending_review" until then.
"""
import argparse
import csv
import hashlib
import json
import pathlib
import re
import sys
from collections import Counter

HERE = pathlib.Path(__file__).resolve().parent
SOURCES = HERE.parent.parent / "data" / "hl-claims-sources"
SNAPSHOT = "2026-11-04"
OLD, NEW = "freshqa-2024-02-26.csv", "freshqa-2026-04-21.csv"
SALT = "hl-claims-v1"
DEV_SHARE = 0.4
TARGETS = {"recently_changed": 60, "stable": 40, "historical": 30, "never_true": 30,
           "conflicting": 20, "ambiguous": 30, "unverifiable": 30}
RECENCYQA_SAMPLE = 400

# RecencyQA's 12 classes, collapsed to Halflife's volatility bands (audit §3.2).
BANDS = {"An-Hour": "HOURS_DAYS", "A-Few-Hours": "HOURS_DAYS", "A-Day": "HOURS_DAYS", "A-Few-Days": "HOURS_DAYS",
         "A-Week": "WEEKS_MONTHS", "A-Few-Weeks": "WEEKS_MONTHS", "A-Month": "WEEKS_MONTHS", "A-Few-Months": "WEEKS_MONTHS",
         "A-Year": "YEAR", "A-Few-Years": "YEARS", "Many-Years": "YEARS", "Never": "NEVER"}

# Unverifiable: private facts about invented entities. Invented for this file;
# the review should drop any that turn out to exist.
ENTITIES = ["Brackenfield Logistics", "Ostrander Biofoods", "Tallowmere Systems", "Quillon & Hask", "Verrow Marine",
            "Lindqvist-Oyelaran Partners", "Harrowgate Micro", "Sundale Pipework", "Nimbrel Labs", "Corvath Textiles"]
PRIVATE = [" plans {n} new hires next quarter, according to its internal target.", " has an unpublished 2026 budget of {n} thousand dollars.",
           " keeps {n} days of stock in its private warehouse."]


def rank(*parts):
    return hashlib.sha256("|".join((SALT, *parts)).encode()).hexdigest()


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_freshqa(path):
    rows = list(csv.reader(path.open(newline="", encoding="utf-8")))
    header = next(i for i, r in enumerate(rows) if r and r[0] == "id")
    names = rows[header]
    out = {}
    for row in rows[header + 1:]:
        if len(row) > 3 and row[0]:
            item = dict(zip(names, row))
            out[item["question"].strip()] = item
    return out


def norm(s):
    return re.sub(r"\W+", " ", s.lower()).strip()


def usable(answer):
    return bool(answer) and "\n" not in answer and len(answer) <= 80


def first_url(source):
    for line in source.split():
        if line.startswith("http"):
            return line.split("#")[0]
    return ""


def perturb(answer):
    """Changes the last number in answer, keeping its format; None if it has none."""
    found = list(re.finditer(r"\d[\d,]*", answer))
    if not found or ":" in answer:  # a clock time doesn't survive arithmetic
        return None
    m = found[-1]
    n = int(m.group().replace(",", ""))
    year = 1000 <= n <= 2100 and "," not in m.group()
    wrong = n + 7 if year else n + max(1, round(n * 0.1))
    text = f"{wrong:,}" if "," in m.group() else str(wrong)
    return answer[:m.start()] + text + answer[m.end():]


def take(pool, used, n, stratum):
    picked = []
    for q in sorted(pool, key=lambda q: rank(stratum, q)):
        if q not in used:
            picked.append(q)
            used.add(q)
            if len(picked) == n:
                return picked
    sys.exit(f"{stratum}: only {len(picked)} of {n} candidates")


def claim(stratum, key, text, verdict, scope, **fields):
    return {"id": "hlc-" + hashlib.sha256(f"{stratum}|{key}".encode()).hexdigest()[:12], "stratum": stratum, "claim": text,
            "expected_verdict": verdict, "temporal_scope": scope, "snapshot_date": SNAPSHOT,
            "label_status": "draft_pending_review", **fields}


def build(sources):
    old, new = load_freshqa(sources / OLD), load_freshqa(sources / NEW)
    plain = {q: r for q, r in new.items() if r["false_premise"] == "FALSE" and usable(r["answer_0"])}
    changed = [q for q in plain if q in old and usable(old[q]["answer_0"]) and norm(old[q]["answer_0"]) != norm(plain[q]["answer_0"])
               and plain[q]["fact_type"] != "never-changing" and not q.lower().startswith("how long")]
    never = [q for q in plain if plain[q]["fact_type"] == "never-changing" and q not in changed]
    numeric = [q for q in never if perturb(plain[q]["answer_0"])]
    moving = [q for q in plain if plain[q]["fact_type"] != "never-changing" and q not in changed]
    used, claims = set(), []

    def freshqa(q):
        r = plain[q]
        return {"question": q, "source_url": first_url(r["source"]), "provenance": f"FreshQA {NEW[8:18]}"}

    for q in take(changed, used, TARGETS["recently_changed"], "recently_changed"):
        was, now = old[q]["answer_0"], plain[q]["answer_0"]
        claims.append(claim("recently_changed", q, f'Asked "{q}", the answer is "{was}".', "OUTDATED", "CURRENT",
                            asserted_value=was, current_value=now, **freshqa(q),
                            review_note=f"FreshQA changed this answer between {OLD[8:18]} and {NEW[8:18]}; re-verify as of the snapshot date"))
    for q in take(changed, used, TARGETS["historical"], "historical"):
        was = old[q]["answer_0"]
        claims.append(claim("historical", q, f'As of February 2024, the answer to "{q}" was "{was}".', "CURRENT", "HISTORICAL",
                            asserted_value=was, current_value=was, **freshqa(q),
                            review_note="a correctly scoped past fact: the temporal scope must stop it reading as outdated"))
    for q in take(numeric, used, TARGETS["never_true"], "never_true"):
        right = plain[q]["answer_0"]
        wrong = perturb(right)
        claims.append(claim("never_true", q, f'Asked "{q}", the answer is "{wrong}".', "CONTRADICTED", "TIMELESS",
                            asserted_value=wrong, current_value=right, **freshqa(q), review_note="value perturbed by build.py"))
    for q in take(never, used, TARGETS["stable"], "stable"):
        a = plain[q]["answer_0"]
        claims.append(claim("stable", q, f'Asked "{q}", the answer is "{a}".', "CURRENT", "TIMELESS",
                            asserted_value=a, current_value=a, **freshqa(q), review_note=""))
    for q in take(moving, used, TARGETS["ambiguous"], "ambiguous"):
        a = plain[q]["answer_0"]
        claims.append(claim("ambiguous", q, f'It is currently "{a}".', "UNVERIFIABLE", "UNCLEAR",
                            asserted_value=a, current_value="", **freshqa(q), review_note="subject removed on purpose; the question is kept only to trace the source"))
    for i in range(TARGETS["unverifiable"]):
        entity, tail = ENTITIES[i % len(ENTITIES)], PRIVATE[i % len(PRIVATE)]
        text = entity + tail.format(n=int(rank("n", str(i))[:4], 16) % 900 + 100)
        claims.append(claim("unverifiable", text, text, "UNVERIFIABLE", "CURRENT", asserted_value="", current_value="",
                            question="", source_url="", provenance="invented for HL-Claims", review_note="check the entity does not exist"))
    for item in json.loads((HERE / "curated-conflicting.json").read_text()):
        claims.append(claim("conflicting", item["claim"], item["claim"], "CONFLICTING", "CURRENT", asserted_value="", current_value="",
                            question="", source_url=item["url"], provenance="curated", review_note=item["dispute"]))

    for stratum in TARGETS:
        members = sorted((c for c in claims if c["stratum"] == stratum), key=lambda c: rank("split", c["id"]))
        dev = round(len(members) * DEV_SHARE)
        for i, c in enumerate(members):
            c["split"] = "dev" if i < dev else "test"
    return sorted(claims, key=lambda c: c["id"])


def recency_sample(sources):
    items = [r for r in json.loads((sources / "recencyqa.json").read_text()) if r["recency_label_RL1"] in BANDS]
    picked = sorted(items, key=lambda r: rank("recencyqa", str(r["q_id"])))[:RECENCYQA_SAMPLE]
    return [{"q_id": r["q_id"], "question": r["question"], "recency_label": r["recency_label_RL1"],
             "band": BANDS[r["recency_label_RL1"]]} for r in sorted(picked, key=lambda r: r["q_id"])]


def digest(ids):
    return hashlib.sha256("\n".join(sorted(ids)).encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--sources", type=pathlib.Path, default=SOURCES)
    parser.add_argument("--freeze", action="store_true", help="write MANIFEST.json; first build only")
    args = parser.parse_args()

    claims = build(args.sources)
    manifest = {"version": "v1", "snapshot_date": SNAPSHOT, "salt": SALT, "dev_share": DEV_SHARE,
                "sources": {p.name: sha256(p) for p in sorted(args.sources.iterdir())},
                "counts": {s: dict(sorted(Counter(c["split"] for c in claims if c["stratum"] == s).items())) for s in TARGETS},
                "dev_ids_sha256": digest(c["id"] for c in claims if c["split"] == "dev"),
                "test_ids_sha256": digest(c["id"] for c in claims if c["split"] == "test")}
    path = HERE / "MANIFEST.json"
    if args.freeze:
        if path.exists():
            sys.exit("MANIFEST.json exists: the split is frozen")
        path.write_text(json.dumps(manifest, indent=2) + "\n")
    elif json.loads(path.read_text()) != manifest:
        sys.exit("this build differs from MANIFEST.json: the sources or the split changed")

    with (HERE / "claims.jsonl").open("w") as f:
        for c in claims:
            f.write(json.dumps(c, ensure_ascii=False, sort_keys=True) + "\n")
    with (HERE / "recencyqa-sample.jsonl").open("w") as f:
        for r in recency_sample(args.sources):
            f.write(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n")
    # The sheet shows no draft label or stratum: reviewers label independently.
    with (HERE / "review-sheet.csv").open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["id", "claim", "source_url", "label", "evidence_url", "evidence_date", "notes"])
        for c in sorted(claims, key=lambda c: rank("sheet", c["id"])):
            w.writerow([c["id"], c["claim"], c["source_url"], "", "", "", ""])
    print(f"{len(claims)} claims", manifest["counts"])


if __name__ == "__main__":
    main()

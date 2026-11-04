#!/usr/bin/env python3
"""Runs one system over HL-Claims: run.py SYSTEM --out FILE [--per-stratum N]

S0  no verification: every claim stands
S1  simple checker: one basic search on the claim text, then an LLM true/false
S2  verify-all: Halflife with priority skipping off (config verify_all)
S3  Halflife as shipped

S1 talks to the replay proxy; S2 and S3 send each claim through the gateway as a
mock model's answer. Only the dev split can be run here: the test split waits for
reviewed labels and the single run the audit allows.
"""
import argparse
import json
import pathlib
import sys
import time
import urllib.error
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent
GATEWAY = "http://127.0.0.1:8090"
PROXY = "http://127.0.0.1:9103"
TOKEN = "halflife-test-setup-token"  # synthetic, from the test config
APP_KEY = "sk-bf-halflife-acme"  # synthetic
S1_MODELS = ["nvidia/nemotron-3.5-super-vl:free", "xingchen-agi/xing4.0-29b-a4b:free", "openrouter/free"]


def question(claim):
    return "Fact check " + claim["id"]


def select(per_stratum, strata=None):
    claims = [json.loads(line) for line in (HERE / "hl-claims" / "claims.jsonl").read_text().splitlines()]
    dev = [c for c in claims if c["split"] == "dev" and (not strata or c["stratum"] in strata)]
    if not per_stratum:
        return dev
    picked, seen = [], {}
    for c in dev:
        seen[c["stratum"]] = seen.get(c["stratum"], 0) + 1
        if seen[c["stratum"]] <= per_stratum:
            picked.append(c)
    return picked


def call(url, body=None, headers=None, timeout=200):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json", **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, dict(resp.headers), json.loads(resp.read() or b"null")
    except urllib.error.HTTPError as err:
        return err.code, dict(err.headers), None


def s0(_):
    return {"verdict": "CURRENT"}


def s1(claim):
    status, _, found = call(PROXY + "/search", {"query": claim["claim"], "search_depth": "basic", "max_results": 5, "include_usage": True})
    if status != 200:
        return {"verdict": "NOT_CHECKED", "error": f"search {status}"}
    evidence = "\n".join(f"- {r['content']}" for r in found["results"])
    credits = found.get("usage", {}).get("credits", 1)
    prompt = f'Evidence:\n{evidence}\n\nClaim: {claim["claim"]}\n\nIs the claim true today? Reply with only the word true or false.'
    for calls, model in enumerate(S1_MODELS, 1):
        status, _, reply = call(PROXY + "/v1/chat/completions", {"model": model, "temperature": 0, "max_tokens": 2048,
                                                                 "messages": [{"role": "user", "content": prompt}]})
        if status == 200 and reply.get("choices"):
            text = (reply["choices"][0]["message"].get("content") or "").strip().lower()
            if text.startswith(("true", "false")):
                return {"verdict": "CURRENT" if text.startswith("true") else "CONTRADICTED", "credits": credits, "llm_calls": calls}
    return {"verdict": "NOT_CHECKED", "credits": credits, "llm_calls": len(S1_MODELS), "error": "no usable reply"}


def halflife(claim):
    status, headers, _ = call(GATEWAY + "/v1/chat/completions", {"model": "openai/ok", "messages": [{"role": "user", "content": question(claim)}]},
                              {"x-bf-vk": APP_KEY})
    report_id = {k.lower(): v for k, v in headers.items()}.get("x-halflife-report")
    if status != 200 or not report_id:
        return {"verdict": "NOT_CHECKED", "error": f"gateway {status}"}
    deadline = time.time() + 190
    while time.time() < deadline:
        status, _, report = call(f"{GATEWAY}/api/halflife/reports/{report_id}", headers={"X-Bifrost-Setup-Token": TOKEN}, timeout=10)
        if status == 200 and report["status"] == "complete":
            claims = report.get("claims") or []
            judged = sum(1 for c in claims if c.get("judge"))
            calls = sum((c.get("judge") or {}).get("calls", 0) for c in claims) + (report.get("extraction") or {}).get("calls", 0)
            return {"verdict": report.get("verdict"), "outcome": report.get("outcome"), "judged": judged, "llm_calls": calls,
                    "credits": sum((c.get("evidence") or {}).get("credits", 0) for c in claims),
                    "extracted": [{"text": c.get("text"), "status": c.get("status"), "reason": c.get("status_reason") or c.get("verdict_reason"),
                                   "scope": c.get("temporal_scope"), "priority": c.get("priority")} for c in claims]}
        time.sleep(0.5)
    return {"verdict": "NOT_CHECKED", "error": "audit did not finish"}


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("system", choices=["S0", "S1", "S2", "S3"])
    parser.add_argument("--out", type=pathlib.Path, required=True)
    parser.add_argument("--per-stratum", type=int, default=0)
    parser.add_argument("--strata", help="only these strata, comma-separated")
    parser.add_argument("--fixtures", type=pathlib.Path, help="write the mock model's fixtures and exit")
    args = parser.parse_args()
    claims = select(args.per_stratum, args.strata.split(",") if args.strata else None)
    if args.fixtures:
        args.fixtures.write_text(json.dumps({"replies": {question(c): c["claim"] for c in claims}}))
        return
    run = {"S0": s0, "S1": s1, "S2": halflife, "S3": halflife}[args.system]
    with args.out.open("w") as out:
        for i, claim in enumerate(claims, 1):
            start = time.time()
            result = run(claim)
            row = {"id": claim["id"], "stratum": claim["stratum"], "expected_verdict": claim["expected_verdict"],
                   "latency_ms": round((time.time() - start) * 1000), **result}
            out.write(json.dumps(row, sort_keys=True) + "\n")
            out.flush()
            print(f"{args.system} {i}/{len(claims)} {claim['stratum']}: {row['verdict']} (draft {claim['expected_verdict']})", file=sys.stderr)


if __name__ == "__main__":
    main()

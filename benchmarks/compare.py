#!/usr/bin/env python3
"""
compare.py — Full benchmark comparison report.

Usage:
    python3 benchmarks/compare.py                    # auto-discover all runs
    python3 benchmarks/compare.py run_a run_b        # compare two specific runs
"""
import json
import sys
import os
import glob

BENCH_DIR = os.path.dirname(os.path.abspath(__file__))


def load_run(name):
    path = os.path.join(BENCH_DIR, name, "summary.json")
    with open(path) as f:
        data = json.load(f)
    return data["runs"]


def load_codex_jsonl_metrics(name):
    """Parse real token counts from codex JSONL files."""
    base = os.path.join(BENCH_DIR, name)
    metrics = {}
    for jf in glob.glob(os.path.join(base, "*.jsonl")):
        input_tok = output_tok = turns = tools = 0
        with open(jf) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except Exception:
                    continue
                if ev.get("type") == "turn.completed":
                    turns += 1
                    u = ev.get("usage", {})
                    input_tok += u.get("input_tokens", 0) + u.get("cached_input_tokens", 0)
                    output_tok += u.get("output_tokens", 0)
                if ev.get("type") == "item.completed":
                    item = ev.get("item", {})
                    if item.get("type") in ("function_call", "mcp_tool_call"):
                        tools += 1
        task = os.path.basename(jf).split("_codex-")[0]
        metrics[task] = {
            "tokens": input_tok + output_tok,
            "turns": turns,
            "tool_calls": tools,
        }
    return metrics


def fmtk(n):
    if n >= 1_000_000:
        return f"{n/1_000_000:.1f}M"
    if n >= 1000:
        return f"{n/1000:.0f}K"
    return str(n)


def classify(name):
    if "claude" in name or "codex" in name or name.startswith("llm_"):
        return "llm"
    return "cli"


def print_cli_report(cli_runs):
    print("\n" + "=" * 80)
    print("  CLI BENCHMARK COMPARISON (tool-level)")
    print("=" * 80)

    names = sorted(cli_runs.keys())
    all_data = {n: {r["id"]: r for r in load_run(n)} for n in names}

    # Collect all test IDs
    all_ids = []
    seen = set()
    for n in names:
        for rid in all_data[n]:
            if rid not in seen:
                all_ids.append(rid)
                seen.add(rid)

    # Header
    hdr = f"{'Test':<30}"
    for n in names:
        hdr += f" {n:>14} {'tok':>8}"
    if len(names) >= 2:
        hdr += f" {'Δ ms':>10} {'Δ tok':>10}"
    print(hdr)
    print("-" * len(hdr))

    totals = {n: {"ms": 0, "tok": 0} for n in names}
    for rid in all_ids:
        row = f"{rid:<30}"
        vals = {}
        for n in names:
            r = all_data[n].get(rid)
            if r:
                row += f" {r['elapsed_ms']:>13.1f} {r['est_tokens']:>8}"
                vals[n] = r
                totals[n]["ms"] += r["elapsed_ms"]
                totals[n]["tok"] += r["est_tokens"]
            else:
                row += f" {'—':>14} {'—':>8}"
        if len(names) >= 2:
            first, last = names[0], names[-1]
            if first in vals and last in vals:
                dms = vals[last]["elapsed_ms"] - vals[first]["elapsed_ms"]
                dtok = vals[last]["est_tokens"] - vals[first]["est_tokens"]
                row += f" {dms:>+10.1f} {dtok:>+10}"
            else:
                row += f" {'—':>10} {'—':>10}"
        print(row)

    # Total
    row = f"{'TOTAL':<30}"
    for n in names:
        row += f" {totals[n]['ms']:>13.1f} {totals[n]['tok']:>8}"
    if len(names) >= 2:
        first, last = names[0], names[-1]
        dms = totals[last]["ms"] - totals[first]["ms"]
        dtok = totals[last]["tok"] - totals[first]["tok"]
        pct_ms = (dms / totals[first]["ms"] * 100) if totals[first]["ms"] else 0
        pct_tok = (dtok / totals[first]["tok"] * 100) if totals[first]["tok"] else 0
        row += f" {dms:>+10.1f} {dtok:>+10}"
        print("-" * len(hdr))
        print(row)
        print(f"\n  Time: {pct_ms:+.1f}%  Tokens: {pct_tok:+.1f}%")
    else:
        print("-" * len(hdr))
        print(row)


def print_llm_report(llm_runs):
    print("\n" + "=" * 80)
    print("  LLM BENCHMARK COMPARISON")
    print("=" * 80)

    names = sorted(llm_runs.keys())

    # Load data with codex JSONL enrichment
    all_data = {}
    for n in names:
        runs = load_run(n)
        if "codex" in n:
            codex_metrics = load_codex_jsonl_metrics(n)
            for r in runs:
                for task_key, m in codex_metrics.items():
                    if task_key in r["id"]:
                        r["est_tokens"] = m["tokens"]
                        r["tool_calls"] = m["tool_calls"]
                        r["num_turns"] = m["turns"]
                        break
        all_data[n] = {r["description"]: r for r in runs}

    # Collect tasks
    tasks = []
    seen = set()
    for n in names:
        for t in all_data[n]:
            if t not in seen:
                tasks.append(t)
                seen.add(t)

    # Per-task comparison
    print(f"\n{'Task':<28}", end="")
    for n in names:
        label = n.replace("llm_", "")
        print(f" {label:>16}", end="")
    print()
    print("-" * (28 + 17 * len(names)))

    totals = {n: {"tok": 0, "cost": 0, "time": 0, "tools": 0} for n in names}
    for task in tasks:
        print(f"{task:<28}", end="")
        for n in names:
            r = all_data[n].get(task)
            if r:
                tok = r["est_tokens"]
                totals[n]["tok"] += tok
                totals[n]["cost"] += r.get("cost_usd", 0) or 0
                totals[n]["time"] += r["elapsed_ms"]
                totals[n]["tools"] += r.get("tool_calls", 0) or 0
                print(f" {fmtk(tok):>16}", end="")
            else:
                print(f" {'—':>16}", end="")
        print()

    # Totals
    print("-" * (28 + 17 * len(names)))
    for metric, key, fmt_fn in [
        ("TOTAL TOKENS", "tok", fmtk),
        ("TOTAL COST", "cost", lambda x: f"${x:.2f}" if x > 0 else "—"),
        ("TOTAL TIME", "time", lambda x: f"{x/1000:.0f}s"),
        ("TOOL CALLS", "tools", lambda x: str(int(x))),
    ]:
        print(f"{metric:<28}", end="")
        for n in names:
            print(f" {fmt_fn(totals[n][key]):>16}", end="")
        print()

    # Delta summary: no-MCP vs MCP for each LLM
    if len(names) >= 2:
        print("\n  MCP impact (no-MCP → with-MCP):")
        pairs = [
            ("llm_claude_nomcp", "llm_claude_mcp", "Claude"),
            ("llm_codex_nomcp", "llm_codex_mcp", "Codex"),
        ]
        for no_mcp, with_mcp, label in pairs:
            if no_mcp in totals and with_mcp in totals:
                ta, tb = totals[no_mcp]["tok"], totals[with_mcp]["tok"]
                if ta > 0:
                    pct = (tb - ta) / ta * 100
                    arrow = "↓ saved" if pct < 0 else "↑ added"
                    print(f"    {label}: {pct:+.1f}% {arrow} ({fmtk(ta)} → {fmtk(tb)})")
                ca, cb = totals[no_mcp]["cost"], totals[with_mcp]["cost"]
                if ca > 0 and cb > 0:
                    cpct = (cb - ca) / ca * 100
                    print(f"           cost: {cpct:+.1f}% (${ca:.2f} → ${cb:.2f})")
                sa, sb = totals[no_mcp]["time"], totals[with_mcp]["time"]
                if sa > 0:
                    spct = (sb - sa) / sa * 100
                    print(f"           time: {spct:+.1f}% ({sa/1000:.0f}s → {sb/1000:.0f}s)")


def main():
    # Discover runs
    index_path = os.path.join(BENCH_DIR, "index.json")
    if os.path.exists(index_path):
        with open(index_path) as f:
            all_names = json.load(f)
    else:
        all_names = sorted(
            os.path.basename(os.path.dirname(p))
            for p in glob.glob(os.path.join(BENCH_DIR, "*/summary.json"))
        )

    # If args provided, filter to those
    if len(sys.argv) > 1:
        all_names = [n for n in sys.argv[1:] if n in all_names or os.path.exists(os.path.join(BENCH_DIR, n, "summary.json"))]

    cli_runs = {n: True for n in all_names if classify(n) == "cli"}
    llm_runs = {n: True for n in all_names if classify(n) == "llm"}

    print("\n" + "=" * 80)
    print("  CODEBASE-MEMORY-MCP BENCHMARK REPORT")
    print("=" * 80)
    print(f"\n  Runs found: {len(all_names)}")
    print(f"    CLI: {', '.join(cli_runs.keys()) or 'none'}")
    print(f"    LLM: {', '.join(llm_runs.keys()) or 'none'}")

    if cli_runs:
        print_cli_report(cli_runs)

    if llm_runs:
        print_llm_report(llm_runs)

    print("\n" + "=" * 80)
    print("  END REPORT")
    print("=" * 80 + "\n")


if __name__ == "__main__":
    main()

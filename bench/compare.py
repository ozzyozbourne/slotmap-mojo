#!/usr/bin/env python3
"""Joins the Criterion (Rust) and std.benchmark (Mojo) results into one table.

Both tools report the mean time per iteration, and each iteration is one pass
over n elements, so the table shows the mean time per element in nanoseconds.
When a case was measured more than once (two passes per CI run), the smaller
mean is used for each language.
Writes results.md (also appended to $GITHUB_STEP_SUMMARY when set) and
results.json to the output directory.
"""

import argparse
import csv
import json
import os
import platform
import re
import subprocess
from pathlib import Path

MAPS = ["SlotMap", "HopSlotMap", "DenseSlotMap", "SecondaryMap", "SparseSecondaryMap"]
OPS = ["insert", "get", "remove", "iter_half", "iter", "reinsert"]


def rust_results(criterion_dir: Path) -> dict:
    """Mean per element; when a case was measured twice (Criterion keeps the
    previous run as `base`), the smaller of the two."""
    out = {}
    for est in criterion_dir.glob("*/*/*/*/estimates.json"):
        if est.parts[-2] not in ("new", "base"):
            continue
        map_name, op, n = est.parts[-5], est.parts[-4], est.parts[-3]
        mean_ns = json.loads(est.read_text())["mean"]["point_estimate"]
        key = (map_name, op, int(n))
        out[key] = min(out.get(key, float("inf")), mean_ns / int(n))
    return out


def mojo_results(csv_paths: list) -> dict:
    out = {}
    for csv_path in csv_paths:
        with csv_path.open() as f:
            for row in csv.DictReader(f):
                m = re.fullmatch(r"(\w+)/(\w+)/input_id:(\d+)", row["name"])
                if not m:
                    continue
                n = int(m.group(3))
                key = (m.group(1), m.group(2), n)
                v = float(row["met (ms)"]) * 1e6 / n
                out[key] = min(out.get(key, float("inf")), v)  # min over passes
    return out


def command_output(cmd: list) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True).stdout.strip()
    except OSError:
        return "unknown"


def fmt(ns):
    return "—" if ns is None else (f"{ns:.2f}" if ns < 100 else f"{ns:.0f}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rust", type=Path, required=True, help="Criterion output dir")
    ap.add_argument("--mojo", type=Path, nargs="+", required=True, help="Mojo CSV file(s)")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--mode", default="thorough")
    ap.add_argument("--baseline", type=Path, help="results.json of an earlier run, "
                    "to show how the Mojo/Rust ratio changed")
    args = ap.parse_args()

    rust, mojo = rust_results(args.rust), mojo_results(args.mojo)
    base = {}
    if args.baseline:
        for r in json.loads(args.baseline.read_text())["results"]:
            if r["rust_ns_per_elem"] and r["mojo_ns_per_elem"]:
                base[(r["map"], r["op"], r["n"])] = r["mojo_ns_per_elem"] / r["rust_ns_per_elem"]
    keys = sorted(
        set(rust) | set(mojo),
        key=lambda k: (MAPS.index(k[0]) if k[0] in MAPS else 99,
                       OPS.index(k[1]) if k[1] in OPS else 99, k[2]),
    )

    cpu = command_output(["sysctl", "-n", "machdep.cpu.brand_string"]) or platform.processor()
    env = {
        "machine": f"{cpu} ({platform.system()} {platform.machine()})",
        "rustc": command_output(["rustc", "--version"]),
        "mojo": command_output(["mojo", "--version"]),
        "mode": args.mode,
    }

    lines = [
        "## slotmap: Rust vs Mojo",
        "",
        f"Mean time per element, in ns (lower is better). Mode: **{env['mode']}**.  ",
        f"Machine: {env['machine']}  ",
        f"Rust: {env['rustc']} with `slotmap` 1.1.1 and Criterion  ",
        f"Mojo: {env['mojo']} with `std.benchmark`",
        "",
        "Mojo/Rust below 1.00 means Mojo is faster. The two sparse maps use aHash in "
        "both languages. Shared CI runners are noisy: treat differences under "
        "~15% as noise.",
    ]
    rows = []
    current = None
    for k in keys:
        map_name, op, n = k
        if map_name != current:
            current = map_name
            lines += ["", f"### {map_name}", "",
                      "| operation | n | Rust | Mojo | Mojo/Rust |" + (" was |" if base else ""),
                      "| --- | ---: | ---: | ---: | ---: |" + (" ---: |" if base else "")]
        r, m = rust.get(k), mojo.get(k)
        ratio = f"{m / r:.2f}" if r and m else "—"
        was = f" {base[k]:.2f} |" if base and k in base else (" — |" if base else "")
        lines.append(f"| {op} | {n:,} | {fmt(r)} | {fmt(m)} | {ratio} |{was}")
        rows.append({"map": map_name, "op": op, "n": n,
                     "rust_ns_per_elem": r, "mojo_ns_per_elem": m})

    args.out.mkdir(parents=True, exist_ok=True)
    md = "\n".join(lines) + "\n"
    (args.out / "results.md").write_text(md)
    (args.out / "results.json").write_text(json.dumps({"env": env, "results": rows}, indent=2))
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write(md)
    print(md)


if __name__ == "__main__":
    main()

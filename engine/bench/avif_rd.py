#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Rate-distortion comparison of AVIF encoders against the one Clop runs (heif-enc).

For every image and each of Clop's two AVIF qualities (heif-enc -q 60 at "normal", -q 43 at
"aggressive"), it finds, per candidate encoder, the smallest file whose SSIMULACRA2 is at least
heif-enc's, by bisection over the candidate's quality. The median size ratio per candidate is
the number that decides which encoder the engine ships; it does not depend on any quality
mapping. A candidate is a command template with {in}, {out} and {q} (0..100).

Usage: avif_rd.py CORPUS --candidate NAME='cmd {in} {out} {q}' [...] [--engine PATH]
Needs heif-enc, avifdec and ssimulacra2 on PATH.
"""

import argparse
import json
import shlex
import statistics
import subprocess
import tempfile
import time
from pathlib import Path

CLOP_QUALITIES = {"normal": 60, "aggressive": 43}


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=True)


ENGINE = None


def score(src_png, avif, work):
    png = work / "dec.png"
    run(["avifdec", "--depth", "8", str(avif), str(png)])
    # Some encoders (ImageIO) signal unspecified primaries and transfer; avifdec carries that
    # into a cICP chunk ssimulacra2 refuses. Viewers treat unspecified as sRGB, so drop it.
    req = {"input": str(png), "params": {"in_place": True, "keep": []}}
    run([ENGINE, "metadata.strip", "--json", json.dumps(req)])
    return float(run(["ssimulacra2", str(src_png), str(png)]).stdout.split()[-1])


def encode(template, src, out, q):
    cmd = [part.format(**{"in": src, "out": out, "q": q}) for part in shlex.split(template)]
    t = time.perf_counter()
    run(cmd)
    return time.perf_counter() - t


def smallest_matching(template, src, src_png, target, work):
    """Lowest quality in 1..100 whose SSIMULACRA2 >= target: (q, size, ssim, seconds)."""
    out = work / "cand.avif"
    lo, hi, best = 1, 100, None
    while lo <= hi:
        mid = (lo + hi) // 2
        secs = encode(template, src, out, mid)
        s = score(src_png, out, work)
        if s >= target:
            best = (mid, out.stat().st_size, s, secs)
            hi = mid - 1
        else:
            lo = mid + 1
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("corpus", type=Path)
    ap.add_argument("--candidate", action="append", required=True, help="NAME=command template")
    ap.add_argument("--engine", default=str(Path(__file__).resolve().parent.parent / "target/release/esclop-engine"))
    a = ap.parse_args()
    global ENGINE
    ENGINE = a.engine
    cands = dict(c.split("=", 1) for c in a.candidate)
    files = sorted(p for p in a.corpus.iterdir() if p.suffix.lower() in (".png", ".jpg"))
    ratios = {(n, level): [] for n in cands for level in CLOP_QUALITIES}
    times = {n: [] for n in cands}
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        for src in files:
            src_png = work / "src.png"
            req = {"input": str(src), "output": str(src_png), "params": {"format": "png", "lossy": False, "strip": True}}
            run([a.engine, "convert", "--json", json.dumps(req)])
            for level, hq in CLOP_QUALITIES.items():
                ref = work / "ref.avif"
                t = time.perf_counter()
                run(["heif-enc", "--avif", "-q", str(hq), "-o", str(ref), str(src_png)])
                ref_t = time.perf_counter() - t
                rs, rsize = score(src_png, ref, work), ref.stat().st_size
                line = f"{src.name:22} {level:10} heif {rsize:>8} ssim {rs:5.1f} {ref_t:5.2f}s"
                for name, template in cands.items():
                    hit = smallest_matching(template, str(src_png), src_png, rs, work)
                    if hit is None:
                        line += f" | {name}: never reaches it"
                        continue
                    q, size, s, secs = hit
                    ratios[(name, level)].append(size / rsize)
                    times[name].append(secs / ref_t)
                    line += f" | {name}: q{q} {size:>8} ({size / rsize:.3f}) {secs:5.2f}s"
                print(line, flush=True)
    print("\n| candidate | normal: median size / heif-enc at equal SSIMULACRA2 | aggressive | time / heif-enc |")
    print("|---|--:|--:|--:|")
    for name in cands:
        med = lambda xs: f"{statistics.median(xs):.3f}" if xs else "–"
        print(f"| {name} | {med(ratios[(name, 'normal')])} | {med(ratios[(name, 'aggressive')])} | {med(times[name])} |")


if __name__ == "__main__":
    main()

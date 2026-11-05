#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Calibrates the engine's JPEG quality scale against jpegoptim's.

The protocol's JPEG `quality` (and the ceiling the compression factor maps to) is on the
libjpeg/jpegoptim scale, the one Clop's curves were tuned on. mozjpeg's trellis quantisation
spends fewer bits at the same nominal quality, so the engine translates: for each libjpeg
quality Q it finds the lowest mozjpeg quality whose SSIMULACRA2 is at least jpegoptim's at Q,
per image, and prints the median as the table in codec/jpeg.rs (`LIBJPEG_TO_MOZJPEG`).

The mozjpeg side is the engine's own encoder at native qualities (`examples/jpeg-sweep.rs`, run
with `cargo run --release --example jpeg-sweep`), so the calibration matches what ships. Needs on
PATH: jpegoptim (libjpeg-turbo build, as Homebrew's) and ssimulacra2.
Usage: calibrate_jpeg.py CORPUS [--engine PATH] [--sweep PATH]
"""

import argparse
import json
import statistics
import subprocess
import tempfile
from pathlib import Path

REF_QUALITIES = [95, 90, 85, 80, 75, 70, 65, 58, 50, 42, 35, 25, 18]


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, check=True, **kw)


def to_png(engine, src, dst):
    req = {"input": str(src), "output": str(dst), "params": {"format": "png", "lossy": False, "strip": True}}
    run([engine, "convert", "--json", json.dumps(req)])


def score(engine, ref_png, jpg, work):
    p = work / "score.png"
    to_png(engine, jpg, p)
    return float(run(["ssimulacra2", str(ref_png), str(p)]).stdout.split()[-1])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("corpus", type=Path)
    root = Path(__file__).resolve().parent.parent
    ap.add_argument("--engine", default=str(root / "target/release/esclop-engine"))
    ap.add_argument("--sweep", default=str(root / "target/release/examples/jpeg-sweep"))
    a = ap.parse_args()
    files = sorted(a.corpus.glob("*.jpg"))
    table = {q: [] for q in REF_QUALITIES}
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        for src in files:
            src_png = work / "src.png"
            to_png(a.engine, src, src_png)
            # mozjpeg curve for this image
            sweep = work / "sweep"
            run([a.sweep, str(src_png), str(sweep)])
            curve = []
            for mq in range(10, 99):
                out = sweep / f"m{mq}.jpg"
                curve.append((mq, score(a.engine, src_png, out, work), out.stat().st_size))
            for q in REF_QUALITIES:
                d = work / "jo"
                d.mkdir(exist_ok=True)
                run(["jpegoptim", "--keep-all", "--force", "--max", str(q), "--auto-mode", "--dest", str(d), "-q", str(src)])
                ref = d / src.name
                rs, rsize = score(a.engine, src_png, ref, work), ref.stat().st_size
                ref.unlink()
                hit = next(((mq, s, size) for mq, s, size in curve if s >= rs), None)
                if hit:
                    table[q].append(hit[0])
                    print(f"{src.name:24} libjpeg q{q:<3} ssim {rs:6.2f} {rsize:>9}  ->  mozjpeg q{hit[0]:<3} ssim {hit[1]:6.2f} {hit[2]:>9} ({hit[2] / rsize:.3f})")
    print("\nconst LIBJPEG_TO_MOZJPEG: &[(u8, u8)] = &[")
    for q in sorted(REF_QUALITIES):
        if table[q]:
            print(f"    ({q}, {round(statistics.median(table[q]))}),")
    print("];")


if __name__ == "__main__":
    main()

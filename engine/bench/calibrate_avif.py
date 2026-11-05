#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Calibrates the engine's AVIF quality (ravif) against the encoder Clop uses (heif-enc).

Clop converts to AVIF with `heif-enc --avif -q Q`, Q being the same conversion quality it gives
cwebp (60 at factor 30). ravif's scale differs, so for each such Q this finds the lowest ravif
quality whose SSIMULACRA2 is at least heif-enc's, per image, and prints the median as the table
`quality::avif_quality` interpolates (`HEIF_TO_RAVIF`).

Inputs are downscaled to at most 1200 px on the long edge first to keep the sweep quick.
Needs on PATH: heif-enc, avifdec, ssimulacra2. Usage: calibrate_avif.py CORPUS [--engine PATH]
"""

import argparse
import json
import statistics
import subprocess
import tempfile
from pathlib import Path

HEIF_QUALITIES = [75, 60, 50, 43, 32, 15]  # conversion quality at factors 0, 30, 50, 64, 80, 100


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=True)


def engine(e, op, src, dst, params):
    run([e, op, "--json", json.dumps({"input": str(src), "output": str(dst), "params": params})])


def score(src_png, avif, work):
    png = work / "dec.png"
    run(["avifdec", str(avif), str(png)])
    return float(run(["ssimulacra2", str(src_png), str(png)]).stdout.split()[-1])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("corpus", type=Path)
    ap.add_argument("--engine", default=str(Path(__file__).resolve().parent.parent / "target/release/esclop-engine"))
    a = ap.parse_args()
    files = sorted(p for p in a.corpus.iterdir() if p.suffix.lower() in (".png", ".jpg") and not p.name.startswith("alpha"))
    table = {q: [] for q in HEIF_QUALITIES}
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        for src in files:
            src_png = work / "src.png"
            engine(a.engine, "resize", src, src_png, {"long_edge": 1200, "format": "png", "lossy": False, "strip": True})
            curve = []
            for q in range(20, 96, 2):
                out = work / "e.avif"
                engine(a.engine, "avif.encode", src_png, out, {"quality": q})
                curve.append((q, score(src_png, out, work), out.stat().st_size))
            for hq in HEIF_QUALITIES:
                ref = work / "r.avif"
                run(["heif-enc", "--avif", "-q", str(hq), "-o", str(ref), str(src_png)])
                rs, rsize = score(src_png, ref, work), ref.stat().st_size
                hit = next(((q, s, size) for q, s, size in curve if s >= rs), None)
                if hit:
                    table[hq].append(hit[0])
                    print(f"{src.name:24} heif q{hq:<3} ssim {rs:6.2f} {rsize:>8}  ->  ravif q{hit[0]:<3} ssim {hit[1]:6.2f} {hit[2]:>8} ({hit[2] / rsize:.3f})", flush=True)
    print("\nconst HEIF_TO_RAVIF: &[(u8, u8)] = &[")
    for q in sorted(HEIF_QUALITIES):
        if table[q]:
            print(f"    ({q}, {round(statistics.median(table[q]))}),")
    print("];")


if __name__ == "__main__":
    main()

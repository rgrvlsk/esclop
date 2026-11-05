#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Benchmark esclop-engine against the tools Clop runs, on a corpus directory.

For every PNG, JPEG and GIF in the corpus (and every PNG/JPEG converted to WebP) it records
output size, SSIMULACRA2 (when the `ssimulacra2` binary is on PATH), wall time and peak RSS
(`/usr/bin/time -l`), for the engine and for a reference run with Clop 3.5's flags:

    PNG   pngquant --force --speed S --quality 0-Q [colours]
    JPEG  jpegoptim --keep-all --force --max Q --auto-mode
    GIF   gifsicle -OL --lossy=N [--colors=N] --threads=T
    WebP  cwebp -mt -q Q -sharp_yuv -metadata all
    AVIF  heif-enc --avif -q Q            (Q: the same conversion quality as WebP)

The reference binaries come from $CLOP_BIN when it is set (a local Clop.app, or the folder
holding its tools) and from PATH otherwise. Clop's binaries are never copied, committed or
redistributed; this script only executes them where they already are.

Standard library only. Usage:
    bench.py CORPUS [--engine PATH] [--compression 30] [--out results.md] [--big FILE]
"""

import argparse
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path

# --- Clop 3.5 factor -> tool settings (mirrors engine/crates/esclop-engine/src/quality.rs) ---


def clamp(v, lo, hi):
    return max(lo, min(hi, int(round_half_away(v))))


def round_half_away(v):
    return int(v + 0.5) if v >= 0 else -int(-v + 0.5)


def jpeg_max(f):
    if f <= 70:
        return clamp(85 - (f - 30) * 55 / 70, 25, 95)
    return clamp(54 - (f - 70) * 36 / 30, 18, 95)


def png_max(f):
    return clamp(100 - (f - 30) * 75 / 70, 25, 100)


def png_colors(f):
    return None if f < 80 else max(64, min(256, 224 - (f - 80) * 8))


def png_speed(f):
    return 4 if f < 40 else 3 if f < 60 else 2 if f < 85 else 1


def gif_args(f):
    level = 3 if f >= 50 else 2 if f >= 20 else 1
    lossy = clamp(30 + (f - 30) * 50 / 34, 0, 200) if f <= 70 else round(89 * (2000 / 89) ** ((f - 70) / 30))
    a = [f"-O{level}", f"--lossy={lossy}"]
    if f >= 50:
        a.append(f"--colors={clamp(256 - (f - 50) * 192 / 50, 32, 256)}")
    return a


def webp_q(f):
    return clamp(75 - f * 0.5, 20, 90) if f <= 70 else clamp(40 - (f - 70) * 25 / 30, 15, 90)


# --- measurement ---------------------------------------------------------------------------


def timed(cmd, env=None):
    """Runs cmd under /usr/bin/time -l; returns (returncode, seconds, peak_rss_bytes, stdout)."""
    with tempfile.NamedTemporaryFile(mode="r", suffix=".time") as t:
        p = subprocess.run(["/usr/bin/time", "-l", "-o", t.name] + cmd, capture_output=True, text=True, env=env)
        out = open(t.name).read()
    real = re.search(r"([\d.]+)\s+real", out)
    rss = re.search(r"(\d+)\s+maximum resident set size", out)
    return p.returncode, float(real.group(1)) if real else None, int(rss.group(1)) if rss else None, p.stdout


def ssim2(orig, dist, engine, work):
    """SSIMULACRA2 of dist against orig, both converted to PNG by the engine first."""
    if not shutil.which("ssimulacra2"):
        return None
    pa, pb = work / "ssim-a.png", work / "ssim-b.png"
    for src, dst in ((orig, pa), (dist, pb)):
        if src.suffix == ".avif":
            # the engine does not decode AVIF (ImageIO does on the Swift side)
            if not shutil.which("avifdec") or subprocess.run(["avifdec", str(src), str(dst)], capture_output=True).returncode != 0:
                return None
            continue
        req = {"input": str(src), "output": str(dst), "params": {"format": "png", "lossy": False, "strip": True}}
        if subprocess.run([engine, "convert", "--json", json.dumps(req)], capture_output=True).returncode != 0:
            return None
    p = subprocess.run(["ssimulacra2", str(pa), str(pb)], capture_output=True, text=True)
    try:
        return float(p.stdout.strip().split()[-1])
    except (ValueError, IndexError):
        return None


def find_tool(name, clop_bin):
    if clop_bin:
        base = Path(clop_bin)
        for d in (base, base / "Contents/Resources/bin", base / "Contents/Resources"):
            if (d / name).is_file():
                return str(d / name)
    return shutil.which(name)


def engine_run(engine, op, src, dst, params):
    req = {"input": str(src), "output": str(dst), "params": params}
    rc, secs, rss, out = timed([engine, op, "--json", json.dumps(req)])
    try:
        resp = json.loads(out)
    except json.JSONDecodeError:
        resp = {"ok": False, "error": {"code": "crash", "message": out[:200]}}
    if not resp.get("ok"):
        code = resp.get("error", {}).get("code")
        if code == "already_smaller":
            shutil.copy(src, dst)
        else:
            return None, secs, rss, code
    return dst.stat().st_size, secs, rss, None


def reference_run(kind, src, dst, f, clop_bin):
    if kind == "png":
        tool = find_tool("pngquant", clop_bin)
        cmd = [tool, "--force", "--speed", str(png_speed(f)), "--quality", f"0-{png_max(f)}"]
        if png_colors(f):
            cmd.append(str(png_colors(f)))
        cmd += ["--output", str(dst), str(src)]
    elif kind == "jpeg":
        tool = find_tool("jpegoptim", clop_bin)
        outdir = dst.parent / "jpegoptim"
        outdir.mkdir(exist_ok=True)
        cmd = [tool, "--keep-all", "--force", "--max", str(jpeg_max(f)), "--auto-mode", "--overwrite", "--dest", str(outdir), str(src)]
    elif kind == "gif":
        tool = find_tool("gifsicle", clop_bin)
        threads = min(8, os.cpu_count() or 1)
        cmd = [tool] + gif_args(f) + [f"--threads={threads}", "--output", str(dst), str(src)]
    elif kind == "avif":
        tool = find_tool("heif-enc", clop_bin)
        cmd = [tool, "--avif", "-q", str(webp_q(f)), "-o", str(dst), str(src)]
    else:  # webp
        tool = find_tool("cwebp", clop_bin)
        cmd = [tool, "-mt", "-q", str(webp_q(f)), "-sharp_yuv", "-metadata", "all", str(src), "-o", str(dst)]
    if not tool:
        return None, None, None, f"{kind} tool not found"
    rc, secs, rss, _ = timed(cmd)
    if kind == "jpeg":
        produced = dst.parent / "jpegoptim" / src.name
        if produced.exists():
            shutil.move(produced, dst)
    if rc not in (0, 99) or not dst.exists():
        # pngquant exits 99 when it would not meet the quality floor; Clop then keeps the original
        shutil.copy(src, dst)
    return dst.stat().st_size, secs, rss, None


def median(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def fmt(v, spec):
    return "–" if v is None else format(v, spec)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("corpus", type=Path)
    here = Path(__file__).resolve().parent
    ap.add_argument("--engine", default=str(here.parent / "target/release/esclop-engine"))
    ap.add_argument("--compression", type=int, default=30)
    ap.add_argument("--out", type=Path, help="write the markdown report here too")
    ap.add_argument("--big", type=Path, help="a large JPEG (24 MP) for the memory target")
    ap.add_argument("--no-webp", action="store_true")
    ap.add_argument("--no-avif", action="store_true")
    ap.add_argument("--big-only", action="store_true", help="only the memory runs on --big")
    a = ap.parse_args()
    clop_bin = os.environ.get("CLOP_BIN")
    f = a.compression
    files = sorted(p for p in a.corpus.iterdir() if p.suffix.lower() in (".png", ".jpg", ".jpeg", ".gif"))
    if not files:
        sys.exit(f"no images in {a.corpus}")
    rows = []
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        jobs = []
        for src in files:
            kind = {".png": "png", ".gif": "gif"}.get(src.suffix.lower(), "jpeg")
            jobs.append((kind, src))
            if kind != "gif" and not a.no_webp:
                jobs.append(("webp", src))
            if kind != "gif" and not a.no_avif:
                jobs.append(("avif", src))
        for kind, src in ([] if a.big_only else jobs):
            ext = kind if kind in ("webp", "avif") else src.suffix.lstrip(".")
            e_out, r_out = work / f"e-{src.stem}.{ext}", work / f"r-{src.stem}.{ext}"
            op, params = {
                "png": ("png.optimise", {"compression": f}),
                "jpeg": ("jpeg.optimise", {"compression": f}),
                "gif": ("gif.optimise", {"compression": f}),
                "webp": ("webp.encode", {"compression": f}),
                "avif": ("avif.encode", {"compression": f}),
            }[kind]
            e_size, e_t, e_rss, e_err = engine_run(a.engine, op, src, e_out, params)
            r_size, r_t, r_rss, r_err = reference_run(kind, src, r_out, f, clop_bin)
            scored = kind != "gif"
            row = {
                "file": src.name,
                "kind": kind,
                "before": src.stat().st_size,
                "engine": e_size,
                "ref": r_size,
                "ratio": e_size / r_size if e_size and r_size else None,
                "e_ssim": ssim2(src, e_out, a.engine, work) if scored and e_size else None,
                "r_ssim": ssim2(src, r_out, a.engine, work) if scored and r_size else None,
                "e_t": e_t,
                "r_t": r_t,
                "e_rss": e_rss,
                "r_rss": r_rss,
                "err": e_err or r_err,
            }
            rows.append(row)
            print(f"{kind:5} {src.name:28} engine {fmt(e_size, ',')} ref {fmt(r_size, ',')}", file=sys.stderr)

        big = None
        if a.big:
            big = []
            for name, op, ext, params in [
                ("probe", "probe", None, {}),
                ("jpeg.optimise (re-encode)", "jpeg.optimise", "jpg", {"compression": f}),
                ("jpeg.optimise (lossless)", "jpeg.optimise", "jpg", {"quality": None}),
                ("metadata.strip", "metadata.strip", "jpg", {}),
                ("resize scale 0.5", "resize", "jpg", {"scale": 0.5}),
                ("crop aspect 1:1", "crop", "jpg", {"aspect": "1:1"}),
                ("webp.encode", "webp.encode", "webp", {"compression": f}),
                ("avif.encode (speed 6)", "avif.encode", "avif", {"compression": f}),
                ("convert to png", "convert", "png", {"format": "png"}),
                ("fit 1.5 MB", "fit", "jpg", {"target_bytes": 1_500_000}),
            ]:
                out = work / f"big-{len(big)}.{ext or 'none'}"
                req = {"input": str(a.big), "params": params}
                if ext:
                    req["output"] = str(out)
                rc, t, rss, outp = timed([a.engine, op, "--json", json.dumps(req)])
                ok = json.loads(outp).get("ok") if outp.strip() else False
                big.append((name, t, rss, ok))
                print(f"big   {name:28} {t}s {rss and rss // 1_000_000} MB ok={ok}", file=sys.stderr)

    ref_name = f"Clop binaries from $CLOP_BIN" if clop_bin else "reference tools from PATH with Clop's flags"
    lines = [f"# esclop-engine benchmark (compression {f})", "", f"Corpus: {len(files)} files. Reference: {ref_name}.", ""]
    lines += ["| file | kind | input | engine | reference | engine/ref | SSIMULACRA2 engine | SSIMULACRA2 ref | time engine s | time ref s | RSS engine MB | RSS ref MB |", "|---|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|"]
    for r in rows:
        mb = lambda b: None if b is None else b / 1e6
        lines.append(
            f"| {r['file']} | {r['kind']} | {r['before']:,} | {fmt(r['engine'], ',')} | {fmt(r['ref'], ',')} | {fmt(r['ratio'], '.3f')} | "
            f"{fmt(r['e_ssim'], '.1f')} | {fmt(r['r_ssim'], '.1f')} | {fmt(r['e_t'], '.2f')} | {fmt(r['r_t'], '.2f')} | {fmt(mb(r['e_rss']), '.0f')} | {fmt(mb(r['r_rss']), '.0f')} |"
            + (f" {r['err']}" if r["err"] else "")
        )
    lines += ["", "## Per format (medians)", "", "| kind | n | size engine/ref | SSIMULACRA2 engine | SSIMULACRA2 ref | time engine/ref | target size ≤ 1.02 at ≥ quality |", "|---|--:|--:|--:|--:|--:|---|"]
    for kind in ("png", "jpeg", "gif", "webp", "avif"):
        rs = [r for r in rows if r["kind"] == kind]
        if not rs:
            continue
        ratio = median([r["ratio"] for r in rs])
        es, rq = median([r["e_ssim"] for r in rs]), median([r["r_ssim"] for r in rs])
        tr = median([r["e_t"] / r["r_t"] if r["e_t"] and r["r_t"] else None for r in rs])
        ok = ratio is not None and ratio <= 1.02 and (es is None or rq is None or es >= rq - 0.5)
        lines.append(f"| {kind} | {len(rs)} | {fmt(ratio, '.3f')} | {fmt(es, '.1f')} | {fmt(rq, '.1f')} | {fmt(tr, '.2f')} | {'pass' if ok else 'FAIL'} |")
    if big:
        lines += ["", f"## Memory on {a.big.name}", "", "| op | time s | peak RSS MB | target ≤ 300 MB |", "|---|--:|--:|---|"]
        for name, t, rss, ok in big:
            verdict = ("pass" if rss and rss <= 300e6 else "FAIL") if ok else "op failed"
            lines.append(f"| {name} | {fmt(t, '.2f')} | {fmt(rss and rss / 1e6, '.0f')} | {verdict} |")
    report = "\n".join(lines) + "\n"
    print(report)
    if a.out:
        a.out.write_text(report)


if __name__ == "__main__":
    main()

# SPDX-License-Identifier: GPL-3.0-or-later
"""PDF benchmark: Ghostscript (the arguments L'Esclop shipped) against esclop-engine's pdf.optimise.

    python3 engine/bench/pdf/run.py CORPUS_DIR [--paths gs,engine] [--engine PATH] [--out DIR]

For every PDF, at the default and the aggressive setting, records the output size, the wall
time, whether it opens, SSIM per page at 150 dpi, and whether text, page, link, outline and
form-field counts match the original. Results land in OUT/results.json and a Markdown table on
stdout. See README.md.
"""

import argparse
import json
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent

# MARK: the Ghostscript path, frozen from Sources/EsclopOptimisers/GhostscriptArguments.swift
# (commit e751e6a, the last one that shipped gs). The Swift side picks the DPI per document
# (judge.swift ports that scan), steps one stop down when aggressive, refuses locked files and
# keeps the original when the result is not smaller.

DPI_STOPS = [300, 250, 200, 150, 100, 72, 48]


def step_down(dpi):
    return next((s for s in DPI_STOPS if s < dpi), DPI_STOPS[-1])


def gs_args(inp, out, dpi):
    dpi = min(max(dpi, 48), 300)
    down = dpi < 300
    lossy = down
    b = lambda v: "true" if v else "false"
    base = """-dSAFER -dALLOWPSTRANSPARENCY -dAutoRotatePages=/None -dBATCH -dCannotEmbedFontPolicy=/Warning
    -dColorConversionStrategy=/RGB -dCompatibilityLevel=1.6 -dCompressFonts=true -dCompressPages=true
    -dCompressStreams=true -dConvertCMYKImagesToRGB=true -dConvertImagesToIndexed=false -dCreateJobTicket=false
    -dDetectDuplicateImages=true -dDoThumbnails=false -dEmbedAllFonts=true -dEncodeColorImages=true
    -dEncodeGrayImages=true -dEncodeMonoImages=true -dFastWebView=false -dGrayDetection=true -dHaveTransparency=true
    -dLZWEncodePages=true -dMaxBitmap=0 -dMonoImageFilter=/CCITTFaxEncode -dNOPAUSE -dNOPROMPT -dOptimize=true
    -dParseDSCComments=false -dParseDSCCommentsForDocInfo=false -dPDFNOCIDFALLBACK -dPDFSETTINGS=/screen
    -dPreserveAnnots=true -dPreserveCopyPage=false -dPreserveDeviceN=true -dPreserveEPSInfo=false
    -dPreserveHalftoneInfo=false -dPreserveOPIComments=false -dPreserveOverprintSettings=true
    -dPreserveSeparation=true -dPrinted=false -dProcessColorModel=/DeviceRGB -dSubsetFonts=true
    -dTransferFunctionInfo=/Preserve -dUCRandBGInfo=/Remove""".split()
    res = []
    for k in ("Color", "Gray", "Mono"):
        res += [f"-d{k}ImageDownsampleThreshold=1.0", f"-d{k}ImageDownsampleType=/Bicubic"]
        res.append(f"-d{k}ImageResolution={max(dpi, 300) if k == 'Mono' else dpi}")
    opt = [
        "-dAutoFilterColorImages=false", "-dAutoFilterGrayImages=false", f"-dAutoFilterMonoImages={b(lossy)}",
        "-dColorImageFilter=/DCTEncode", f"-dDownsampleColorImages={b(down)}", f"-dDownsampleGrayImages={b(down)}",
        f"-dDownsampleMonoImages={b(down)}", "-dGrayImageFilter=/DCTEncode",
        f"-dPassThroughJPEGImages={b(not down)}", f"-dPassThroughJPXImages={b(not down)}", f"-dShowAcroForm={b(not lossy)}",
    ]
    q = []
    if lossy and dpi <= 100:
        qf = 1.3 if dpi <= 48 else (1.0 if dpi <= 72 else 0.76)
        d = f"<< /QFactor {qf} /Blend 1 /HSamples [2 1 1 2] /VSamples [2 1 1 2] >>"
        q = ["-c", f"<< /ColorImageDict {d} /GrayImageDict {d} >> setdistillerparams", "-f"]
    fonts = ":".join(p for p in [os.path.expanduser("~/Library/Fonts"), "/Library/Fonts/", "/System/Library/Fonts/", "/Library/Fonts/Microsoft/"] if os.path.exists(p))
    outa = ["-dColorConversionStrategy=/RGB", "-sDEVICE=pdfwrite", f"-sFONTPATH={fonts}", "-o", str(out)]
    d68 = "<< /QFactor 0.68 /Blend 1 /HSamples [2 1 1 2] /VSamples [2 1 1 2] >>"
    pre = [
        "-c",
        f"<< /ColorImageDict {d68} >> setdistillerparams << /ColorACSImageDict {d68} >> setdistillerparams << /GrayImageDict {d68} >> setdistillerparams << /GrayACSImageDict {d68} >> setdistillerparams << /AlwaysEmbed [ ] >> setdistillerparams << /NeverEmbed [/Courier /Courier-Bold /Courier-Oblique /Courier-BoldOblique /Helvetica /Helvetica-Bold /Helvetica-Oblique /Helvetica-BoldOblique /Times-Roman /Times-Bold /Times-Italic /Times-BoldItalic /Symbol /ZapfDingbats /Arial] >> setdistillerparams",
        "-f", "-c",
        "/originalpdfmark { //pdfmark } bind def /pdfmark { { { counttomark pop } stopped { /pdfmark errordict /unmatchedmark get exec stop } if dup type /nametype ne { /pdfmark errordict /typecheck get exec stop } if dup /DOCINFO eq { (Skipping DOCINFO pdfmark\\n) print cleartomark exit } if originalpdfmark exit } loop } def",
        "-f",
    ]
    post = ["-c", "/pdfmark { originalpdfmark } bind def", "-f", "-c", "[ /Producer () /ModDate () /CreationDate () /DOCINFO pdfmark", "-f"]
    return ["gs"] + base + res + opt + outa + q + pre + [str(inp)] + post


def judge(*args):
    out = subprocess.run([str(JUDGE), *map(str, args)], capture_output=True, text=True)
    return json.loads(out.stdout) if out.returncode == 0 and out.stdout.strip() else {"opens": False}


REPEAT = 1


def timed(cmd):
    """Runs `cmd` REPEAT times; the median wall time and the last result."""
    times = []
    for _ in range(REPEAT):
        t = time.perf_counter()
        p = subprocess.run(cmd, capture_output=True, text=True)
        times.append(time.perf_counter() - t)
    return p, statistics.median(times)


def run_gs(src, out, info, aggressive):
    if not info.get("opens") or info.get("locked"):
        return {"status": "refused"}
    dpi = info["adaptive_dpi"]
    if aggressive:
        dpi = step_down(dpi)
    p, secs = timed(gs_args(src, out, dpi))
    if p.returncode != 0 or not out.exists():
        return {"status": "failed", "seconds": secs, "error": p.stderr[-300:]}
    return {"status": "ok", "seconds": secs, "dpi": dpi}


def run_engine(src, out, info, aggressive):
    """Same DPI choice as the gs path (the Swift side keeps it); compression 30 or 64."""
    if not info.get("opens") or info.get("locked"):
        return {"status": "refused"}
    dpi = info["adaptive_dpi"]
    if aggressive:
        dpi = step_down(dpi)
    params = {"dpi": dpi, "compression": 64 if aggressive else 30, "strip": True}
    req = json.dumps({"input": str(src), "output": str(out), "params": params})
    p, secs = timed([str(ENGINE), "pdf.optimise", "--json", req])
    try:
        reply = json.loads(p.stdout.strip().splitlines()[-1])
    except Exception:
        return {"status": "failed", "seconds": secs, "error": (p.stderr or p.stdout)[-300:]}
    if not reply.get("ok"):
        code = reply["error"]["code"]
        status = "kept" if code == "already_smaller" else "refused" if code in ("unsupported", "decode") else "failed"
        return {"status": status, "seconds": secs, "error": f"{code}: {reply['error']['message']}"}
    return {"status": "ok", "seconds": secs, "dpi": dpi}


PATHS = {"gs": run_gs, "engine": run_engine}


def evaluate(src, out, rec, info):
    before = src.stat().st_size
    rec["bytes_before"] = before
    if rec["status"] != "ok":
        rec["bytes"] = before
        return rec
    c = judge("compare", src, out)
    o = c.get("output", {})
    rec["raw_bytes"] = out.stat().st_size
    rec["opens"] = bool(o.get("opens"))
    rec["ssim"] = c.get("ssim", [])
    rec["min_ssim"] = min(rec["ssim"]) if rec["ssim"] else 0.0
    checks = {}
    for k in ("pages", "text_sha", "links", "outline", "fields"):
        checks[k] = info.get(k) == o.get(k)
    rec["checks"] = checks
    # Not smaller: the app keeps the original (alreadySmaller).
    rec["bytes"] = min(before, rec["raw_bytes"]) if rec["opens"] else before
    if rec["raw_bytes"] >= before:
        rec["status"] = "kept"
    return rec


def main():
    global JUDGE, ENGINE, REPEAT
    ap = argparse.ArgumentParser()
    ap.add_argument("corpus", type=Path)
    ap.add_argument("--paths", default="gs,engine")
    ap.add_argument("--engine", type=Path, default=HERE.parent.parent / "target/release/esclop-engine")
    ap.add_argument("--out", type=Path, default=Path("pdf-bench-out"))
    ap.add_argument("--only", default="")
    ap.add_argument("--repeat", type=int, default=3, help="runs per file and setting; the median time counts")
    ap.add_argument("--table", action="store_true", help="only print the table from OUT/results.json")
    a = ap.parse_args()
    REPEAT = max(1, a.repeat)
    ENGINE = a.engine.resolve()
    a.out.mkdir(parents=True, exist_ok=True)
    JUDGE = a.out / "judge"
    results_path = a.out / "results.json"
    results = json.loads(results_path.read_text()) if results_path.exists() else {}
    if not a.table:
        if not JUDGE.exists() or JUDGE.stat().st_mtime < (HERE / "judge.swift").stat().st_mtime:
            subprocess.run(["swiftc", "-O", str(HERE / "judge.swift"), "-o", str(JUDGE)], check=True)
        sums = HERE / "corpus.sha256"
        if sums.exists():
            import hashlib

            for line in sums.read_text().splitlines():
                h, name = line.split()
                f = a.corpus / name
                if not f.exists() or hashlib.sha256(f.read_bytes()).hexdigest() != h:
                    print(f"warning: {name} differs from corpus.sha256", file=sys.stderr)
        files = sorted(a.corpus.glob("*.pdf"))
        if a.only:
            files = [f for f in files if any(s in f.name for s in a.only.split(","))]
        for src in files:
            info = judge("info", src)
            entry = results.setdefault(src.stem, {})
            entry["info"] = info
            for path in a.paths.split(","):
                for mode in ("default", "aggressive"):
                    out = a.out / path / mode / src.name
                    out.parent.mkdir(parents=True, exist_ok=True)
                    out.unlink(missing_ok=True)
                    rec = PATHS[path](src, out, info, mode == "aggressive")
                    entry[f"{path}/{mode}"] = evaluate(src, out, rec, info)
            print(src.stem, {k: (v.get("status"), v.get("bytes"), round(v.get("min_ssim", 0), 4)) for k, v in entry.items() if k != "info"}, file=sys.stderr, flush=True)
            results_path.write_text(json.dumps(results, indent=1, sort_keys=True))
    print(table(results, a.paths.split(",")))


def table(results, paths):
    lines = []
    for mode in ("default", "aggressive"):
        lines.append(f"\n### {mode}\n")
        head = "| file | original | " + " | ".join(f"{p} size | {p} min SSIM | {p} s" for p in paths) + " | notes |"
        lines.append(head)
        lines.append("|" + "---|" * (head.count("|") - 1))
        tot = {p: 0 for p in paths}
        times = {p: [] for p in paths}
        for name in sorted(results):
            e = results[name]
            row = [name, kb(next(iter(v["bytes_before"] for k, v in e.items() if k != "info")))]
            notes = []
            for p in paths:
                r = e.get(f"{p}/{mode}")
                if not r:
                    row += ["", "", ""]
                    continue
                tot[p] += r["bytes"]
                if "seconds" in r:
                    times[p].append(r["seconds"])
                st = r["status"]
                ssim = f"{r['min_ssim']:.4f}" if "min_ssim" in r else "-"
                row += [kb(r["bytes"]) + ("" if st == "ok" else f" ({st})"), ssim, f"{r.get('seconds', 0):.2f}"]
                bad = [k for k, v in r.get("checks", {}).items() if not v]
                if bad:
                    notes.append(f"{p}: {','.join(bad)} differ")
                if r.get("opens") is False:
                    notes.append(f"{p}: does not open")
            lines.append("| " + " | ".join(row + ["; ".join(notes)]) + " |")
        lines.append("| **total** | | " + " | ".join(f"**{kb(tot[p])}** | | median {statistics.median(times[p]) if times[p] else 0:.2f}" for p in paths) + " | |")
    return "\n".join(lines)


def kb(n):
    return f"{n / 1e6:.2f} MB" if n >= 1e6 else f"{n / 1e3:.0f} kB"


if __name__ == "__main__":
    main()

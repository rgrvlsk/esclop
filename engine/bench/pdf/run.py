# SPDX-License-Identifier: GPL-3.0-or-later
"""PDF benchmark: Ghostscript (the arguments L'Esclop shipped) against esclop-engine's pdf.optimise.

    python3 engine/bench/pdf/run.py CORPUS_DIR [--paths gs,engine] [--engine PATH] [--out DIR]

For every PDF, at the default and the aggressive setting, records the output size, the wall
time, whether it opens, SSIM per page at 150 dpi, and whether text, page, link, outline and
form-field counts match the original. Results land in OUT/results.json and a Markdown table on
stdout. See README.md.
"""

import argparse
import concurrent.futures as cf
import hashlib
import shutil
import threading
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


TIMEOUT = 120  # seconds per tool run; Swift gave Ghostscript 1800, a hang shows long before
JUDGE_TIMEOUT = 900
REPEAT = 1


def judge(*args, timeout=JUDGE_TIMEOUT):
    try:
        out = subprocess.run([str(JUDGE), *map(str, args)], capture_output=True, text=True, errors="replace", timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"opens": False, "judge_timeout": True}
    return json.loads(out.stdout) if out.returncode == 0 and out.stdout.strip() else {"opens": False, "judge_error": out.returncode}


def timed(cmd):
    """Runs `cmd` REPEAT times under TIMEOUT: (last CompletedProcess or None on timeout, median seconds)."""
    times, p = [], None
    for _ in range(REPEAT):
        t = time.perf_counter()
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, errors="replace", timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            return None, float(TIMEOUT)
        times.append(time.perf_counter() - t)
    return p, statistics.median(times)


def gs_opens(src):
    """Whether Ghostscript reads the file at all (its first page renders to the null device)."""
    try:
        p = subprocess.run(["gs", "-q", "-dSAFER", "-dBATCH", "-dNOPAUSE", "-sDEVICE=nullpage", "-dFirstPage=1", "-dLastPage=1", str(src)],
                           capture_output=True, timeout=60)
        return p.returncode == 0
    except subprocess.TimeoutExpired:
        return False


def dpi_for(info, aggressive):
    dpi = info.get("adaptive_dpi", 300)
    return step_down(dpi) if aggressive else dpi


def run_gs(src, out, info, aggressive):
    if info.get("valid") != "ok":
        return {"status": "refused"}
    dpi = dpi_for(info, aggressive)
    p, secs = timed(gs_args(src, out, dpi))
    if p is None:
        return {"status": "timeout", "seconds": secs}
    if p.returncode < 0:
        return {"status": "crash", "seconds": secs, "error": f"signal {-p.returncode}"}
    if p.returncode != 0 or not out.exists():
        return {"status": "failed", "seconds": secs, "error": p.stderr[-300:]}
    return {"status": "ok", "seconds": secs, "dpi": dpi}


def run_engine(src, out, info, aggressive):
    """Same DPI choice as the gs path (the Swift side keeps it); compression 30 or 64. Runs on
    every file, valid or not, to catch crashes and hangs; only valid ones are scored."""
    dpi = dpi_for(info, aggressive)
    params = {"dpi": dpi, "compression": 64 if aggressive else 30, "strip": True}
    req = json.dumps({"input": str(src.resolve()), "output": str(out.resolve()), "params": params})
    p, secs = timed([str(ENGINE), "pdf.optimise", "--json", req])
    if p is None:
        return {"status": "timeout", "seconds": secs}
    if p.returncode < 0:
        return {"status": "crash", "seconds": secs, "error": f"signal {-p.returncode}"}
    try:
        reply = json.loads(p.stdout.strip().splitlines()[-1])
    except Exception:
        return {"status": "crash", "seconds": secs, "error": (p.stderr or p.stdout)[-300:]}
    if not reply.get("ok"):
        code = reply["error"]["code"]
        status = {"already_smaller": "kept", "unsupported": "refused", "decode": "refused", "internal": "internal"}.get(code, "failed")
        return {"status": status, "seconds": secs, "error": f"{code}: {reply['error']['message']}"[:300]}
    return {"status": "ok", "seconds": secs, "dpi": dpi}


PATHS = {"gs": run_gs, "engine": run_engine}
CHECKS = ("pages", "text_sha", "links", "outline", "fields")


def evaluate(src, out, rec, info, compared, aggressive):
    """Fills sizes and, for an output that would replace the original, what it got wrong."""
    before = src.stat().st_size
    rec["bytes_before"] = before
    rec["bytes"] = before
    fails = []
    if rec["status"] in ("timeout", "crash", "internal"):
        fails.append(rec["status"])
    if rec["status"] == "ok":
        rec["raw_bytes"] = out.stat().st_size
        if rec["raw_bytes"] >= before:
            rec["status"] = "kept"  # the app keeps the original (alreadySmaller)
        elif compared is not None:
            o = compared.get("output", {})
            rec["opens"] = bool(o.get("opens"))
            rec["ssim"] = compared.get("ssim", [])
            rec["min_ssim"] = min(rec["ssim"]) if rec["ssim"] else 0.0
            rec["checks"] = {k: info.get(k) == o.get(k) for k in CHECKS}
            if not rec["opens"]:
                fails.append("unopenable")
            else:
                fails += [k for k, ok in rec["checks"].items() if not ok]
                if rec["min_ssim"] < (0.95 if aggressive else 0.98):
                    fails.append(f"ssim {rec['min_ssim']:.3f}")
            rec["bytes"] = rec["raw_bytes"] if rec["opens"] else before
    rec["fails"] = fails
    return rec


def process(src, name, a):
    info = judge("info", src, timeout=300)
    if info.get("opens") and not info.get("locked"):
        info["valid"] = "ok"
    elif info.get("locked"):
        info["valid"] = "locked"
    else:
        info["valid"] = "gs-only" if gs_opens(src) else "invalid"
    entry = {"info": info}
    work = a.out / "work" / name.replace("/", "__")
    work.mkdir(parents=True, exist_ok=True)
    runs = []
    for path in a.paths.split(","):
        for mode in ("default", "aggressive"):
            out = work / f"{path}-{mode}.pdf"
            out.unlink(missing_ok=True)
            runs.append((path, mode, out, PATHS[path](src, out, info, mode == "aggressive")))
    scored = [r for r in runs if r[3]["status"] == "ok" and r[2].exists() and r[2].stat().st_size < src.stat().st_size]
    compared = {}
    if info["valid"] == "ok" and scored and not a.timing_only:
        c = judge("compare-many", src, *[r[2] for r in scored])
        if "outputs" in c:
            for r, o in zip(scored, c["outputs"]):
                compared[(r[0], r[1])] = o
        else:
            entry["judge_failed"] = c  # the judge, not the tool: scored as unknown, listed
    for path, mode, out, rec in runs:
        e = evaluate(src, out, rec, info, compared.get((path, mode)), mode == "aggressive")
        if info["valid"] != "ok":
            e["fails"] = [f for f in e["fails"] if f in ("timeout", "crash")]
        entry[f"{path}/{mode}"] = e
    if not a.keep_outputs:
        shutil.rmtree(work, ignore_errors=True)
    return entry


def main():
    global JUDGE, ENGINE, REPEAT, TIMEOUT
    ap = argparse.ArgumentParser()
    ap.add_argument("corpus", type=Path)
    ap.add_argument("--paths", default="gs,engine")
    ap.add_argument("--engine", type=Path, default=HERE.parent.parent / "target/release/esclop-engine")
    ap.add_argument("--out", type=Path, default=Path("pdf-bench-out"))
    ap.add_argument("--only", default="")
    ap.add_argument("--repeat", type=int, default=3, help="runs per file and setting; the median time counts")
    ap.add_argument("--timeout", type=int, default=TIMEOUT, help="seconds per tool run")
    ap.add_argument("--jobs", type=int, default=1, help="files in parallel (times are then under load)")
    ap.add_argument("--timing-only", action="store_true", help="run the tools, skip the judge")
    ap.add_argument("--keep-outputs", action="store_true")
    ap.add_argument("--resume", action="store_true", help="skip files already in results.json")
    ap.add_argument("--table", action="store_true", help="only print the table from OUT/results.json")
    a = ap.parse_args()
    REPEAT, TIMEOUT = max(1, a.repeat), a.timeout
    ENGINE = a.engine.resolve()
    a.out.mkdir(parents=True, exist_ok=True)
    JUDGE = a.out / "judge"
    results_path = a.out / ("timing.json" if a.timing_only else "results.json")
    results = json.loads(results_path.read_text()) if results_path.exists() else {}
    if not a.table:
        if not JUDGE.exists() or JUDGE.stat().st_mtime < (HERE / "judge.swift").stat().st_mtime:
            subprocess.run(["swiftc", "-O", str(HERE / "judge.swift"), "-o", str(JUDGE)], check=True)
        sums = HERE / "corpus.sha256"
        if sums.exists() and (a.corpus / sums.read_text().split()[1]).exists():
            for line in sums.read_text().splitlines():
                h, name = line.split()
                f = a.corpus / name
                if not f.exists() or hashlib.sha256(f.read_bytes()).hexdigest() != h:
                    print(f"warning: {name} differs from corpus.sha256", file=sys.stderr)
        files = sorted(a.corpus.rglob("*.pdf"))
        if a.only:
            files = [f for f in files if any(s in str(f) for s in a.only.split(","))]
        names = {f: str(f.relative_to(a.corpus))[: -len(".pdf")] for f in files}
        todo = [f for f in files if not (a.resume and names[f] in results)]
        lock = threading.Lock()

        def one(src):
            try:
                entry = process(src, names[src], a)
            except Exception as e:  # a runner bug must not end the run: listed, not scored
                entry = {"info": {"valid": "runner-error", "error": repr(e)[:300]}}
            with lock:
                results[names[src]] = entry
                bad = {k: v["fails"] for k, v in entry.items() if k != "info" and v.get("fails")}
                print(names[src], entry["info"]["valid"], {k: (v["status"], v["bytes"]) for k, v in entry.items() if k != "info"}, bad or "", file=sys.stderr, flush=True)
                if len(results) % 10 == 0:
                    results_path.write_text(json.dumps(results, indent=1, sort_keys=True))

        with cf.ThreadPoolExecutor(max(1, a.jobs)) as pool:
            list(pool.map(one, todo))
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

# Usage: python3 fontoracle.py ENGINE_NAME OUT_DIR. Binaries (engine-v1, ENGINE_NAME, judge-new built from judge.swift) and the real/ corpus live in bench/pdf/.data.
"""Font oracle: v1 and a font-subsetting engine differ only in font programs, so their outputs
must render identically. Judges v1's output against the new one's on every real file."""
import json, sys, shutil, threading, concurrent.futures as cf
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import run
D = Path(__file__).resolve().parent / ".data"
run.JUDGE = D / "judge-new"
new, out = sys.argv[1], D / sys.argv[2]
out.mkdir(exist_ok=True)
files = sorted((D / "real").rglob("*.pdf"))
res_path = out / "oracle.json"
res = json.loads(res_path.read_text()) if res_path.exists() else {}
lock = threading.Lock()
def eng(binary, src, dst):
    req = json.dumps({"input": str(src), "output": str(dst), "params": {"dpi": 150, "compression": 30, "strip": True}})
    p = run.child([D / binary, "pdf.optimise", "--json", req], 120, run.TOOL_MEM_MB, "tool")
    if p is None: return "timeout"
    if p.killed: return "memory"
    try: r = json.loads(p.stdout.strip().splitlines()[-1])
    except Exception: return f"crash {p.returncode}"
    return "ok" if r.get("ok") else r["error"]["code"]
def one(src):
    name = str(src.relative_to(D / "real"))
    if name in res: return
    work = out / "w" / name.replace("/", "__"); work.mkdir(parents=True, exist_ok=True)
    a, b = work / "v1.pdf", work / "new.pdf"
    sa, sb = eng("engine-v1", src, a), eng(new, src, b)
    rec = {"v1": sa, "new": sb}
    if sa == "ok" and sb == "ok":
        rec["bytes"] = [src.stat().st_size, a.stat().st_size, b.stat().st_size]
        if a.read_bytes() != b.read_bytes():
            c = run.judge("compare-many", a, b)
            o = c.get("outputs", [{}])[0]
            rec["ssim"], rec["diffpx"], rec["ink"] = o.get("ssim"), o.get("diffpx"), o.get("diffpx_ink")
            if "outputs" not in c: rec["judge"] = c
    shutil.rmtree(work, ignore_errors=True)
    with lock:
        res[name] = rec
        if len(res) % 20 == 0: res_path.write_text(json.dumps(res))
with cf.ThreadPoolExecutor(2) as pool: list(pool.map(one, files))
res_path.write_text(json.dumps(res))
print(f"peak RSS judge {run.PEAKS['judge'] >> 20} MB tools {run.PEAKS['tool'] >> 20} MB")

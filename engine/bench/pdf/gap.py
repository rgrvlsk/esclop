#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Splits the size gap between the engine and Ghostscript by cause.

    python3 gap.py OUT/results.json CORPUS ENGINE [--top 30] [--mode default]

Takes the files that add most to the gap in a `run.py` result, makes both outputs again (the
frozen gs arguments and per-file DPI from run.py, every child under run.py's memory caps),
measures where each output's bytes are (examples/pdf-bytes) and attributes the difference:
files the engine leaves as stored, image downsampling (gs keeps fewer pixels, valued at the
engine's bytes per pixel), image recompression (the rest of the image bytes), fonts by kind,
content streams, other streams and structure.
"""
import argparse
import json
import sys
import tempfile
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import run  # noqa: E402

BYTES = HERE.parent.parent / "target/release/examples/pdf-bytes"


def measure(path):
    p = run.child([BYTES, path], 120, run.TOOL_MEM_MB, "tool")
    try:
        return json.loads(p.stdout.strip().splitlines()[-1])
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results", type=Path)
    ap.add_argument("corpus", type=Path)
    ap.add_argument("engine", type=Path)
    ap.add_argument("--top", type=int, default=30)
    ap.add_argument("--mode", default="default")
    ap.add_argument("--clean", action="store_true", help="only files where gs's output passes every check")
    a = ap.parse_args()
    run.ENGINE = a.engine.resolve()
    r = json.loads(a.results.read_text())
    mode, aggressive = a.mode, a.mode == "aggressive"
    rows = []
    for name, e in r.items():
        g, en = e.get(f"gs/{mode}"), e.get(f"engine/{mode}")
        if e["info"].get("valid") != "ok" or not g or not en or (a.clean and g["fails"]):
            continue
        rows.append((en["bytes"] - g["bytes"], name, e))
    total_gap = sum(d for d, *_ in rows)
    rows.sort(reverse=True)
    causes, top = Counter(), []
    with tempfile.TemporaryDirectory() as tmp:
        for gap, name, e in rows[: a.top]:
            src = a.corpus / f"{name}.pdf"
            info = e["info"]
            go, eo = Path(tmp) / "g.pdf", Path(tmp) / "e.pdf"
            g = run.run_gs(src, go, info, aggressive)
            en = run.run_engine(src, eo, info, aggressive)
            o = measure(src)
            gm = measure(go) if g["status"] == "ok" and go.exists() and go.stat().st_size < src.stat().st_size else o
            em = measure(eo) if en["status"] == "ok" and eo.exists() and eo.stat().st_size < src.stat().st_size else o
            row = {"file": name, "gap": gap, "original": o["total"], "gs": gm["total"], "engine": em["total"]}
            if em is o and gm is not o:
                causes["engine leaves as stored"] += em["total"] - gm["total"]
                row["cause"] = f"engine {en['status']}: {en.get('error', '')[:60]}"
            else:
                d_img = em["images"] - gm["images"]
                fewer_px = max(0, em["image_px"] - gm["image_px"])
                per_px = em["images"] / em["image_px"] if em["image_px"] else 0
                down = min(d_img, int(fewer_px * per_px)) if d_img > 0 else 0
                causes["images: gs downsamples more"] += down
                causes["images: recompression"] += d_img - down
                for k in set(em["by_font"]) | set(gm["by_font"]):
                    causes[f"fonts: {k}"] += em["by_font"].get(k, 0) - gm["by_font"].get(k, 0)
                for k in ("content", "other", "structure"):
                    causes[k] += em[k] - gm[k]
                row.update({k: em[k] - gm[k] for k in ("images", "fonts", "content", "other", "structure")})
                row["px"] = [gm["image_px"], em["image_px"]]
                row["filters"] = [gm["by_filter"], em["by_filter"]]
            top.append(row)
    covered = sum(t["gap"] for t in top)
    print(json.dumps({"mode": mode, "total_gap": total_gap, "top_files_gap": covered, "causes": dict(causes.most_common()), "top": top}, indent=1))


if __name__ == "__main__":
    main()

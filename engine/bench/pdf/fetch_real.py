# SPDX-License-Identifier: GPL-3.0-or-later
"""Fetches the real-world PDF corpora into a folder outside the repository.

    python3 engine/bench/pdf/fetch_real.py OUT_DIR [--no-links] [--no-govdocs]

- pdf.js test corpus (mozilla/pdf.js, Apache-2.0) at a pinned commit: every `test/pdfs/*.pdf`,
  plus the files its `*.link` entries point to when they still download (OUT/pdfjs/).
- GovDocs1 (Digital Corpora; documents from US government web servers, public domain as works of
  the US government): the PDFs of the pinned zip threads (OUT/govdocs/). Scans and office exports,
  what the pdf.js set lacks.

Nothing fetched is committed. `real.sha256` lists the files of one fetch; the script reports
files that differ from it (links can change upstream).
"""

import argparse
import concurrent.futures as cf
import hashlib
import io
import os
import shutil
import subprocess
import sys
import urllib.request
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
PDFJS_REPO = "https://github.com/mozilla/pdf.js"
PDFJS_COMMIT = "94a48f3c844d4677b264b6e7c0a1e239c245189f"
GOVDOCS = "https://downloads.digitalcorpora.org/corpora/files/govdocs1/zipfiles/{:03d}.zip"
GOVDOCS_THREADS = [0]
MAX_BYTES = 60 << 20
# Stop fetching when the disk gets this full: the benchmark itself needs room for outputs.
KEEP_FREE = 300 << 20
UA = {"User-Agent": "pdf-bench-fetch/1"}


def room(out, need=0):
    return shutil.disk_usage(out).free - need > KEEP_FREE


class RemoteFile(io.RawIOBase):
    """A seekable view of a URL through HTTP range requests, so zipfile reads only what it needs."""

    def __init__(self, url):
        req = urllib.request.Request(url, method="HEAD", headers=UA)
        with urllib.request.urlopen(req, timeout=60) as r:
            self.url, self.size = r.url, int(r.headers["Content-Length"])
        self.pos = 0

    def seekable(self):
        return True

    def readable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, off, whence=0):
        self.pos = {0: off, 1: self.pos + off, 2: self.size + off}[whence]
        return self.pos

    def readinto(self, b):
        if self.pos >= self.size:
            return 0
        end = min(self.size, self.pos + len(b)) - 1
        req = urllib.request.Request(self.url, headers={**UA, "Range": f"bytes={self.pos}-{end}"})
        with urllib.request.urlopen(req, timeout=120) as r:
            data = r.read()
        b[: len(data)] = data
        self.pos += len(data)
        return len(data)


def get(url, timeout=60):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        data = r.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise ValueError("too large")
    return data


def pdfjs(out, links):
    repo = out / ".pdfjs-repo"
    if (out / ".pdfjs-links").exists():
        return pdfjs_links(out, links)
    if not repo.exists():
        subprocess.run(["git", "clone", "-q", "--filter=blob:none", "--no-checkout", PDFJS_REPO, str(repo)], check=True)
        subprocess.run(["git", "-C", str(repo), "sparse-checkout", "set", "test/pdfs"], check=True)
    subprocess.run(["git", "-C", str(repo), "checkout", "-q", PDFJS_COMMIT], check=True)
    dest = out / "pdfjs"
    dest.mkdir(parents=True, exist_ok=True)
    src = repo / "test/pdfs"
    for f in sorted(src.glob("*.pdf")):
        if not (dest / f.name).exists():
            os.link(f, dest / f.name)
    links_dir = out / ".pdfjs-links"
    links_dir.mkdir(exist_ok=True)
    for f in src.glob("*.link"):
        shutil.copy(f, links_dir / f.name)
    # The clone holds a second, compressed copy of every file: drop it.
    shutil.rmtree(repo)
    src = links_dir
    pdfjs_links(out, links)


def pdfjs_links(out, links):
    src, dest = out / ".pdfjs-links", out / "pdfjs"
    if not links:
        return
    jobs = []
    for f in sorted(src.glob("*.link")):
        name = f.name[: -len(".link")]
        if not name.endswith(".pdf"):
            name += ".pdf"
        target = dest / name
        if target.exists():
            continue
        url = f.read_text().strip().splitlines()[0].strip()
        jobs.append((url, target))

    def fetch(job):
        url, target = job
        if not room(out, MAX_BYTES):
            return f"{target.name}: skipped, disk nearly full"
        try:
            data = get(url)
            if b"%PDF" not in data[:1024]:
                return f"not a PDF: {target.name}"
            target.write_bytes(data)
            return None
        except Exception as e:  # dead links are expected
            return f"{target.name}: {type(e).__name__}"

    with cf.ThreadPoolExecutor(8) as pool:
        failed = [r for r in pool.map(fetch, jobs) if r]
    print(f"pdf.js links: {len(jobs) - len(failed)} of {len(jobs)} downloaded", file=sys.stderr)


def govdocs(out):
    dest = out / "govdocs"
    dest.mkdir(parents=True, exist_ok=True)
    for t in GOVDOCS_THREADS:
        with zipfile.ZipFile(io.BufferedReader(RemoteFile(GOVDOCS.format(t)), 1 << 20)) as z:
            for info in z.infolist():
                target = dest / Path(info.filename).name
                if not info.filename.lower().endswith(".pdf") or target.exists():
                    continue
                if info.file_size > MAX_BYTES or not room(out, info.file_size):
                    continue
                target.write_bytes(z.read(info))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out", type=Path)
    ap.add_argument("--no-links", action="store_true")
    ap.add_argument("--no-govdocs", action="store_true")
    a = ap.parse_args()
    out = a.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    pdfjs(out, not a.no_links)
    if not a.no_govdocs:
        govdocs(out)
    lines = []
    for f in sorted(out.glob("*/*.pdf")):
        lines.append(f"{hashlib.sha256(f.read_bytes()).hexdigest()}  {f.parent.name}/{f.name}")
    (out / "SHA256SUMS").write_text("\n".join(lines) + "\n")
    known = HERE / "real.sha256"
    if known.exists():
        diff = set(known.read_text().splitlines()) ^ set(lines)
        print(f"{len(diff)} lines differ from real.sha256", file=sys.stderr)
    print(f"{len(lines)} PDFs in {out}", file=sys.stderr)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Reject machine-specific home paths in tracked files without printing their contents."""
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent.parent
paths = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).split(b"\0")
home_path = re.compile(rb"/(?:Users|home)/[A-Za-z0-9_.-]+")
failures = 0
for raw_path in filter(None, paths):
    path = pathlib.Path(raw_path.decode())
    file = root / path
    if not file.is_file() or file.is_symlink():
        continue
    for line_number, line in enumerate(file.read_bytes().splitlines(), 1):
        if home_path.search(line):
            print(f"{path}:{line_number}: machine-specific home path", file=sys.stderr)
            failures += 1
if failures:
    sys.exit(1)
print("Tracked files contain no machine-specific home paths.")

#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fillability check: can the form fields of an output still be filled as in the original?

    python3 formcheck.py ORIGINAL OUTPUT...      (needs pikepdf and fontTools)

For each field in both files, the font its /DA names is looked up in the field's /DR, then the
AcroForm's /DR. When the original's font is embedded, the output's must be too, and its program
must cover what the original's covered: no fewer glyphs, every glyph that had an outline still
has one, every cmap mapping (or CFF charset entry, or Type 1 glyph name) still there, and a simple
font's /Encoding, /FirstChar and /LastChar unchanged. A subset font (a filler typing a new
character would find nothing to draw) fails. An XFA form keeps its fields in the XFA template,
which picks fonts by typeface from the AcroForm's /DR: there every /DR font counts as a field
font. Prints one JSON object per output:
{"fields": N, "checked": M, "bad": [[field, reason], ...]}.
"""
import io
import json
import re
import sys

import pikepdf
from fontTools.cffLib import CFFFontSet
from fontTools.ttLib import TTFont

PATH_OPS = {"rmoveto", "hmoveto", "vmoveto", "rlineto", "hlineto", "vlineto", "rrcurveto", "hhcurveto",
            "hvcurveto", "vhcurveto", "vvcurveto", "rcurveline", "rlinecurve", "flex", "hflex", "hflex1",
            "flex1", "callsubr", "callgsubr", "seac"}


def fields(pdf):
    """(fully qualified name, field dictionary) for every terminal field."""
    form = pdf.Root.get("/AcroForm")
    if form is None:
        return []
    out = []

    def walk(f, prefix, depth):
        if depth > 32:
            return
        t = f.get("/T")
        name = f"{prefix}.{t}" if prefix and t is not None else (str(t) if t is not None else prefix)
        kids = f.get("/Kids")
        if kids is not None and any("/T" in k for k in kids):
            for k in kids:
                walk(k, name, depth + 1)
        else:
            out.append((name, f))

    for f in form.get("/Fields", []):
        walk(f, "", 0)
    return out


def inherited(f, key):
    for _ in range(32):
        if f is None:
            return None
        if key in f:
            return f[key]
        f = f.get("/Parent")
    return None


def da_font(pdf, f):
    """The font dictionary the field's /DA names, or None (no /DA, no font, not found)."""
    form = pdf.Root.get("/AcroForm")
    da = inherited(f, "/DA") or (form.get("/DA") if form is not None else None)
    if da is None:
        return None
    m = re.search(rb"/([^\s/\[\]()<>{}%]+)\s+[-+.\d]+\s+Tf", bytes(da))
    if not m:
        return None
    name = "/" + m.group(1).decode("latin-1")
    for res in (inherited(f, "/DR"), form.get("/DR") if form is not None else None):
        fonts = res.get("/Font") if res is not None else None
        if fonts is not None and name in fonts:
            return fonts[name]
    return None


def program(font):
    """(kind, bytes) of the font's embedded program, or None."""
    desc = font.get("/FontDescriptor")
    if desc is None and "/DescendantFonts" in font:
        desc = font.DescendantFonts[0].get("/FontDescriptor")
    if desc is None:
        return None
    for key in ("/FontFile2", "/FontFile3", "/FontFile"):
        if key in desc:
            return key, bytes(desc[key].read_bytes())
    return None


def empty_cff(cs):
    cs.decompile()
    return not any(isinstance(t, str) and t in PATH_OPS for t in cs.program)


def coverage(kind, data):
    """(glyph count, glyphs with an outline, mapping set) of a font program."""
    if data[:1] == b"\x01":  # bare CFF
        fs = CFFFontSet()
        fs.decompile(io.BytesIO(data), None)
        top = fs[fs.keys()[0]]
        names = top.charset
        outlined = {i for i, n in enumerate(names) if not empty_cff(top.CharStrings[n])}
        return len(names), outlined, set(enumerate(names))
    if kind == "/FontFile":  # Type 1: glyph names in the CharStrings dict
        from fontTools.t1Lib import T1Font
        import tempfile
        with tempfile.NamedTemporaryFile(suffix=".pfa") as t:
            t.write(data)
            t.flush()
            f = T1Font(t.name)
            f.parse()
            names = sorted(f["CharStrings"].keys())
        return len(names), set(names), set(names)
    tt = TTFont(io.BytesIO(data), fontNumber=0, lazy=True)
    order = tt.getGlyphOrder()
    if "glyf" in tt:
        glyf = tt["glyf"]
        outlined = {i for i, g in enumerate(order) if glyf[g].numberOfContours != 0}
    elif "CFF " in tt:
        cs = tt["CFF "].cff[tt["CFF "].cff.keys()[0]].CharStrings
        outlined = {i for i, g in enumerate(order) if not empty_cff(cs[g])}
    else:
        outlined = set(range(len(order)))
    maps = set()
    if "cmap" in tt:
        for t in tt["cmap"].tables:
            maps |= {(t.platformID, t.platEncID, c, g) for c, g in t.cmap.items()}
    return len(order), outlined, maps


def compare(a_font, b_font):
    """None when b's font covers what a's did, else the reason."""
    if b_font is None:
        return "font missing"
    pa = program(a_font)
    if pa is None:
        return None  # not embedded in the original: a viewer's own font fills it
    pb = program(b_font)
    if pb is None:
        return "font no longer embedded"
    if pa[1] == pb[1]:
        pass  # the same program: coverage cannot differ
    else:
        try:
            coverage(*pa)
        except Exception:
            return "original font unreadable and changed: cannot verify"
    for key in ("/Encoding", "/FirstChar", "/LastChar"):
        if repr(a_font.get(key)) != repr(b_font.get(key)):
            return f"{key[1:]} changed"
    if pa[1] == pb[1]:
        return None
    try:
        ca, cb = coverage(*pa), coverage(*pb)
    except Exception as e:
        return f"output font unreadable: {type(e).__name__}"
    if cb[0] < ca[0]:
        return f"glyphs {ca[0]} -> {cb[0]}"
    lost = len(ca[1] - cb[1])
    if lost:
        return f"{lost} glyph outlines dropped"
    gone = len(ca[2] - cb[2])
    if gone:
        return f"{gone} cmap/charset entries dropped"
    return None


def xfa_fonts(pdf):
    """For an XFA form, every font of the AcroForm's /DR by resource name; else {}."""
    form = pdf.Root.get("/AcroForm")
    if form is None or "/XFA" not in form:
        return {}
    fonts = form.get("/DR", {}).get("/Font", {})
    return {str(k): v for k, v in fonts.items()}


def check(original, output):
    a, b = pikepdf.open(original), pikepdf.open(output)
    fa, fb = fields(a), dict(fields(b))
    bad, checked = [], 0
    xa, xb = xfa_fonts(a), xfa_fonts(b)
    for name, font in xa.items():
        checked += 1
        reason = compare(font, xb.get(name))
        if reason:
            bad.append([f"XFA font {name}", reason])
    for name, f in fa:
        if name not in fb:
            continue  # field counts are checked elsewhere
        font = da_font(a, f)
        if font is None:
            continue
        checked += 1
        reason = compare(font, da_font(b, fb[name]))
        if reason:
            bad.append([name, reason])
    return {"fields": len(fa) + len(xa), "checked": checked, "bad": bad}


def main():
    original, outputs = sys.argv[1], sys.argv[2:]
    for out in outputs:
        try:
            r = check(original, out)
        except Exception as e:
            r = {"error": f"{type(e).__name__}: {str(e)[:120]}"}
        print(json.dumps(r))


if __name__ == "__main__":
    main()

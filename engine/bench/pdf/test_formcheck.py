# SPDX-License-Identifier: GPL-3.0-or-later
"""python3 -m unittest test_formcheck  (needs pikepdf and fontTools)"""
import io
import tempfile
import unittest
from pathlib import Path

import pikepdf
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools import subset

import formcheck


def tiny_font():
    fb = FontBuilder(1000, isTTF=True)
    names = [".notdef", "A", "B"]
    fb.setupGlyphOrder(names)
    fb.setupCharacterMap({0x41: "A", 0x42: "B"})
    glyphs = {}
    for n in names:
        pen = TTGlyphPen(None)
        pen.moveTo((100, 0)); pen.lineTo((100, 700)); pen.lineTo((500, 700)); pen.closePath()
        glyphs[n] = pen.glyph()
    fb.setupGlyf(glyphs)
    fb.setupHorizontalMetrics({n: (600, 100) for n in names})
    fb.setupHorizontalHeader(ascent=800, descent=-200)
    fb.setupNameTable({"familyName": "Tiny", "styleName": "Regular"})
    fb.setupOS2(); fb.setupPost(); fb.setupHead(unitsPerEm=1000)
    buf = io.BytesIO(); fb.save(buf)
    return buf.getvalue()


def form_pdf(path, font_bytes):
    pdf = pikepdf.new()
    page = pdf.add_blank_page()
    ff = pikepdf.Stream(pdf, font_bytes); ff.Length1 = len(font_bytes)
    desc = pdf.make_indirect(pikepdf.Dictionary(Type=pikepdf.Name.FontDescriptor, FontName=pikepdf.Name.Tiny,
                                                Flags=32, FontBBox=[0, 0, 600, 700], ItalicAngle=0, Ascent=800,
                                                Descent=-200, CapHeight=700, StemV=80, FontFile2=ff))
    font = pdf.make_indirect(pikepdf.Dictionary(Type=pikepdf.Name.Font, Subtype=pikepdf.Name.TrueType,
                                                BaseFont=pikepdf.Name.Tiny, FirstChar=65, LastChar=66,
                                                Widths=[600, 600], Encoding=pikepdf.Name.WinAnsiEncoding,
                                                FontDescriptor=desc))
    field = pdf.make_indirect(pikepdf.Dictionary(FT=pikepdf.Name.Tx, T=pikepdf.String("name"),
                                                 DA=pikepdf.String("/F1 12 Tf 0 g"), Rect=[10, 10, 200, 40],
                                                 Type=pikepdf.Name.Annot, Subtype=pikepdf.Name.Widget, P=page.obj))
    page.obj.Annots = pdf.make_indirect(pikepdf.Array([field]))
    pdf.Root.AcroForm = pdf.make_indirect(pikepdf.Dictionary(Fields=[field], DR=pikepdf.Dictionary(Font=pikepdf.Dictionary(F1=font))))
    pdf.save(path)


class FormCheck(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.font = tiny_font()
        form_pdf(self.dir / "original.pdf", self.font)

    def test_kept_font_passes(self):
        form_pdf(self.dir / "kept.pdf", self.font)
        r = formcheck.check(self.dir / "original.pdf", self.dir / "kept.pdf")
        self.assertEqual((r["checked"], r["bad"]), (1, []))

    def test_subset_font_fails(self):
        opts = subset.Options(); opts.retain_gids = True; opts.notdef_outline = True
        s = subset.Subsetter(opts); s.populate(unicodes=[0x41])
        f = formcheck.TTFont(io.BytesIO(self.font)); s.subset(f)
        buf = io.BytesIO(); f.save(buf)
        form_pdf(self.dir / "subset.pdf", buf.getvalue())
        r = formcheck.check(self.dir / "original.pdf", self.dir / "subset.pdf")
        self.assertEqual(len(r["bad"]), 1, r)

    def test_dropped_font_fails(self):
        pdf = pikepdf.open(self.dir / "original.pdf")
        del pdf.Root.AcroForm.DR.Font.F1.FontDescriptor["/FontFile2"]
        pdf.save(self.dir / "dropped.pdf")
        r = formcheck.check(self.dir / "original.pdf", self.dir / "dropped.pdf")
        self.assertEqual(r["bad"], [["name", "font no longer embedded"]])


    def test_xfa_dr_font_subset_fails(self):
        for name, font_bytes in (("xfa-orig.pdf", self.font), ("xfa-sub.pdf", None)):
            pdf = pikepdf.open(self.dir / "original.pdf")
            pdf.Root.AcroForm.Fields = pikepdf.Array([])
            pdf.Root.AcroForm.XFA = pikepdf.Stream(pdf, b"<xdp:xdp/>")
            if font_bytes is None:
                opts = subset.Options(); opts.retain_gids = True
                s = subset.Subsetter(opts); s.populate(unicodes=[0x41])
                f = formcheck.TTFont(io.BytesIO(self.font)); s.subset(f)
                buf = io.BytesIO(); f.save(buf)
                pdf.Root.AcroForm.DR.Font.F1.FontDescriptor.FontFile2.write(buf.getvalue())
            pdf.save(self.dir / name)
        self.assertEqual(formcheck.check(self.dir / "xfa-orig.pdf", self.dir / "xfa-orig.pdf")["bad"], [])
        r = formcheck.check(self.dir / "xfa-orig.pdf", self.dir / "xfa-sub.pdf")
        self.assertEqual(len(r["bad"]), 1, r)


if __name__ == "__main__":
    unittest.main()

# SPDX-License-Identifier: GPL-3.0-or-later
"""Generates the PDF benchmark corpus: every file is synthesised here, nothing is downloaded.

    python3 engine/bench/pdf/make_corpus.py OUT_DIR

Needs Python 3 with numpy and Pillow, `gs` on PATH (only to make the linearised file), and on
macOS `swiftc` (Quartz writes the text documents with subset fonts, as Mac apps do). Fonts and
ICC profiles are read from the system; none are committed. Files depend on the Pillow, libjpeg
and macOS versions, so `corpus.sha256` records one run rather than a guarantee; `run.py` warns
when a file differs.
"""

import hashlib
import io
import os
import struct
import subprocess
import sys
import zlib
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).resolve().parent
FONTS = Path("/System/Library/Fonts/Supplemental")
PROFILES = Path("/System/Library/ColorSync/Profiles")
A4 = (595.276, 841.89)
WORDS = (
    "the of and to in a is that for it as was with be by on not he this are or his from at which "
    "but have an they you were her she there been one all we their has would when if more no out so "
    "said what up its about into than them can only other new some could time these two may then do "
    "first any my now such like our over man me even most made after also did many before must "
    "through back years where much your way well down should because each just those people how too "
    "little state good very make world still own see men work long get here between both life being "
    "under never day same another know while last might us great old year off come since against go "
    "came right used take three compression optimiser engine document page image stream object font"
).split()


def words(rng, n):
    return " ".join(WORDS[i] for i in rng.integers(0, len(WORDS), n))


# MARK: a small PDF writer


class PDF:
    """Objects are bytes bodies; `write` lays out a classic xref table."""

    def __init__(self, version="1.7"):
        self.version = version
        self.objs = []
        self.encrypt = None  # (key, encrypt-dict object number)

    def reserve(self):
        self.objs.append(None)
        return len(self.objs)

    def add(self, body, num=None):
        if isinstance(body, str):
            body = body.encode("latin-1")
        if num is None:
            self.objs.append(body)
            return len(self.objs)
        self.objs[num - 1] = body
        return num

    def stream(self, dictionary, data, num=None, flate=True, level=6, raw_filter=None):
        filters = []
        if flate:
            data = zlib.compress(data, level)
            filters.append("/FlateDecode")
        if raw_filter:
            filters.append(raw_filter)
        filt = ""
        if len(filters) == 1:
            filt = "/Filter " + filters[0]
        elif filters:
            filt = "/Filter [" + " ".join(filters) + "]"
        num = num or self.reserve()
        self.objs[num - 1] = ("stream", dictionary, filt, data)
        return num

    def _body(self, num, obj):
        if isinstance(obj, tuple):
            _, dictionary, filt, data = obj
            if self.encrypt and num != self.encrypt[1]:
                data = rc4(object_key(self.encrypt[0], num), data)
            head = f"<< {dictionary} {filt} /Length {len(data)} >>\nstream\n".encode("latin-1")
            return head + data + b"\nendstream"
        return obj

    def write(self, path, root, info=None, file_id=None, trailer_extra=""):
        out = io.BytesIO()
        out.write(f"%PDF-{self.version}\n%\xe2\xe3\xcf\xd3\n".encode("latin-1"))
        offsets = []
        for i, obj in enumerate(self.objs, 1):
            offsets.append(out.tell())
            out.write(f"{i} 0 obj\n".encode() + self._body(i, obj) + b"\nendobj\n")
        xref = out.tell()
        out.write(f"xref\n0 {len(self.objs) + 1}\n0000000000 65535 f \n".encode())
        for off in offsets:
            out.write(f"{off:010d} 00000 n \n".encode())
        fid = file_id or hashlib.md5(Path(path).name.encode()).hexdigest()
        trailer = f"/Size {len(self.objs) + 1} /Root {root} 0 R /ID [<{fid}> <{fid}>] {trailer_extra}"
        if info:
            trailer += f" /Info {info} 0 R"
        out.write(f"trailer\n<< {trailer} >>\nstartxref\n{xref}\n%%EOF\n".encode())
        Path(path).write_bytes(out.getvalue())


def catalog(pdf, page_nums, extra="", pages_num=None):
    pages_num = pages_num or pdf.reserve()
    kids = " ".join(f"{n} 0 R" for n in page_nums)
    pdf.add(f"<< /Type /Pages /Kids [{kids}] /Count {len(page_nums)} >>", pages_num)
    return pdf.add(f"<< /Type /Catalog /Pages {pages_num} 0 R {extra} >>"), pages_num


def page(pdf, parent, content_num, resources, size=A4, extra="", num=None):
    w, h = size
    return pdf.add(
        f"<< /Type /Page /Parent {parent} 0 R /MediaBox [0 0 {w:.3f} {h:.3f}] "
        f"/Resources {resources} /Contents {content_num} 0 R {extra} >>",
        num,
    )


def jpeg_bytes(img, quality, subsampling=0, **kw):
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=quality, subsampling=subsampling, optimize=False, **kw)
    return buf.getvalue()


def image_xobject(pdf, img, kind="flate", quality=90, subsampling=0, colorspace=None, smask=None, level=6):
    """kind: flate, jpeg, ccitt, raw."""
    w, h = img.size
    mode = img.mode
    cs = colorspace or {"RGB": "/DeviceRGB", "L": "/DeviceGray", "CMYK": "/DeviceCMYK", "1": "/DeviceGray"}.get(mode)
    extra = f" /SMask {smask} 0 R" if smask else ""
    if kind == "jpeg":
        data = jpeg_bytes(img, quality, subsampling)
        decode = " /Decode [1 0 1 0 1 0 1 0]" if mode == "CMYK" else ""
        return pdf.stream(
            f"/Type /XObject /Subtype /Image /Width {w} /Height {h} /ColorSpace {cs} /BitsPerComponent 8{decode}{extra}",
            data,
            flate=False,
            raw_filter="/DCTDecode",
        )
    if kind == "ccitt":
        buf = io.BytesIO()
        # One strip: G4 strips cannot simply be concatenated.
        img.convert("1").save(buf, "TIFF", compression="group4", strip_size=1 << 30)
        tif = Image.open(io.BytesIO(buf.getvalue()))
        offs, counts = tif.tag_v2[273], tif.tag_v2[279]
        assert len(offs) == 1, "G4 written in several strips"
        photometric = tif.tag_v2.get(262, 0)
        raw = b"".join(buf.getvalue()[o : o + c] for o, c in zip(offs, counts))
        return pdf.stream(
            f"/Type /XObject /Subtype /Image /Width {w} /Height {h} /ColorSpace /DeviceGray /BitsPerComponent 1 "
            f"/DecodeParms << /K -1 /Columns {w} /Rows {h} /BlackIs1 {'true' if photometric == 1 else 'false'} >>",
            raw,
            flate=False,
            raw_filter="/CCITTFaxDecode",
        )
    if mode == "1":
        data = np.packbits(~np.array(img, dtype=bool), axis=1).tobytes()
        return pdf.stream(
            f"/Type /XObject /Subtype /Image /Width {w} /Height {h} /ImageMask true /BitsPerComponent 1 /Decode [0 1]",
            data,
            level=level,
        )
    if mode == "P":
        pal = img.getpalette()[: 3 * 256]
        n = len(pal) // 3
        cs = f"[/Indexed /DeviceRGB {n - 1} <{bytes(pal).hex()}>]"
        return pdf.stream(
            f"/Type /XObject /Subtype /Image /Width {w} /Height {h} /ColorSpace {cs} /BitsPerComponent 8{extra}",
            img.tobytes(),
            level=level,
        )
    return pdf.stream(
        f"/Type /XObject /Subtype /Image /Width {w} /Height {h} /ColorSpace {cs} /BitsPerComponent 8{extra}",
        img.tobytes(),
        flate=(kind != "raw"),
        level=level,
    )


def full_page_image(pdf, xobj_num, size=A4, parent=None):
    w, h = size
    content = pdf.stream("", f"q {w:.3f} 0 0 {h:.3f} 0 0 cm /Im0 Do Q".encode())
    return content, f"<< /XObject << /Im0 {xobj_num} 0 R >> >>"


# MARK: pixels


def fractal(rng, w, h, octaves=6, base=4):
    acc = np.zeros((h, w), np.float32)
    amp, total = 1.0, 0.0
    for o in range(octaves):
        cells = base * 2**o
        grid = rng.random((cells + 1, int(cells * w / h) + 2)).astype(np.float32)
        layer = Image.fromarray(grid).resize((w, h), Image.BICUBIC)
        acc += amp * np.asarray(layer)
        total += amp
        amp *= 0.55
    acc /= total
    return (acc - acc.min()) / (np.ptp(acc) + 1e-6)


def photo(rng, w, h, grain=4.0):
    """Photo-like: smooth colour fields, soft shapes, sensor grain."""
    t = fractal(rng, w, h)
    stops = rng.random((5, 3)) * 255
    idx = t * (len(stops) - 1)
    lo = np.floor(idx).astype(int).clip(0, len(stops) - 2)
    f = (idx - lo)[..., None]
    rgb = stops[lo] * (1 - f) + stops[lo + 1] * f
    img = Image.fromarray(rgb.astype(np.uint8), "RGB")
    over = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(over)
    for _ in range(12):
        x, y = rng.integers(0, w), rng.integers(0, h)
        r = rng.integers(w // 20, w // 5)
        d.ellipse([x - r, y - r, x + r, y + r], fill=tuple(int(c) for c in rng.integers(0, 255, 3)))
    over = over.filter(ImageFilter.GaussianBlur(w / 80))
    img = Image.blend(img, over, 0.35)
    detail = (fractal(rng, w, h, octaves=3, base=w // 16)[..., None] - 0.5) * 40
    arr = np.asarray(img, np.float32) + detail + rng.normal(0, grain, (h, w, 3))
    return Image.fromarray(arr.clip(0, 255).astype(np.uint8), "RGB")


def font(size, name="Arial.ttf"):
    return ImageFont.truetype(str(FONTS / name), size)


def scan_page(rng, w, h, color=True, lines=45):
    """A printed page as a scanner sees it: tinted paper, slightly grey text, a photo, noise."""
    paper = np.array([248, 246, 238] if color else [244, 244, 244], np.float32)
    img = Image.new("RGB", (w, h), tuple(int(c) for c in paper))
    d = ImageDraw.Draw(img)
    f = font(int(h / 110), "Times New Roman.ttf")
    margin = w // 9
    y = h // 12
    d.text((margin, y), words(rng, 6).title(), font=font(int(h / 55), "Arial Bold.ttf"), fill=(30, 30, 40))
    y += h // 25
    for i in range(lines):
        if i == 12 and color:
            ph = photo(rng, w - 2 * margin, h // 5)
            img.paste(ph, (margin, y))
            y += h // 5 + h // 60
        d.text((margin, y), words(rng, 13), font=f, fill=(35, 35, 35))
        y += int(h / 70)
    img = img.rotate(0.4, resample=Image.BICUBIC, fillcolor=tuple(int(c) for c in paper))
    arr = np.asarray(img, np.float32) + rng.normal(0, 3.0, (h, w, 1))
    img = Image.fromarray(arr.clip(0, 255).astype(np.uint8), "RGB")
    return img if color else img.convert("L")


def slide(rng, w, h, n):
    """A presentation slide rendered to pixels: flat fills, gradient, text, a chart, a photo."""
    top = np.array(rng.integers(20, 90, 3), np.float32)
    bottom = top + 60
    ramp = np.linspace(0, 1, h, dtype=np.float32)[:, None, None]
    bg = (top * (1 - ramp) + bottom * ramp) * np.ones((1, w, 1), np.float32)
    img = Image.fromarray(bg.astype(np.uint8), "RGB")
    d = ImageDraw.Draw(img)
    d.text((w // 14, h // 12), f"{n}. " + words(rng, 4).title(), font=font(h // 12, "Arial Bold.ttf"), fill="white")
    f = font(h // 30)
    for i in range(6):
        d.text((w // 12, h // 4 + i * h // 14), "• " + words(rng, 7), font=f, fill=(230, 230, 235))
    x0, y0 = int(w * 0.58), int(h * 0.25)
    for i in range(7):
        bh = int(rng.integers(h // 12, h // 2.5))
        d.rectangle([x0 + i * w // 28, y0 + h // 2 - bh, x0 + i * w // 28 + w // 36, y0 + h // 2], fill=tuple(int(c) for c in rng.integers(80, 255, 3)))
    if n % 2 == 0:
        img.paste(photo(rng, w // 3, h // 3), (int(w * 0.6), int(h * 0.62)))
    return img


# MARK: documents


def doc_scans(path, rng, pages, dpi, kind, color=True, quality=88):
    pdf = PDF("1.4")
    parent = pdf.reserve()
    w, h = int(8.27 * dpi), int(11.69 * dpi)
    nums = []
    for _ in range(pages):
        img = scan_page(rng, w, h, color=color and kind != "ccitt")
        if kind == "ccitt":
            img = img.convert("L").point(lambda v: 255 if v > 150 else 0).convert("1")
        x = image_xobject(pdf, img, kind=kind, quality=quality, subsampling=0 if color else 0)
        c, res = full_page_image(pdf, x)
        nums.append(page(pdf, parent, c, res))
    root, _ = catalog(pdf, nums, pages_num=parent)
    pdf.write(path, root)


def doc_slides(path, rng, n, kind="flate", alpha=False, size=(1920, 1080)):
    pdf = PDF("1.6")
    parent = pdf.reserve()
    nums = []
    ps = (960.0, 540.0)
    for i in range(1, n + 1):
        img = slide(rng, *size, i)
        smask = None
        if alpha:
            a = Image.new("L", size, 0)
            ImageDraw.Draw(a).rounded_rectangle([40, 40, size[0] - 40, size[1] - 40], radius=80, fill=255)
            a = a.filter(ImageFilter.GaussianBlur(6))
            smask = image_xobject(pdf, a)
        x = image_xobject(pdf, img, kind=kind, quality=95, smask=smask)
        title = words(rng, 5)
        content = pdf.stream(
            "",
            (
                f"q 0.95 0.95 0.95 rg 0 0 {ps[0]} {ps[1]} re f Q q {ps[0]} 0 0 {ps[1]} 0 0 cm /Im0 Do Q "
                f"BT /F1 9 Tf 20 12 Td ({title}) Tj ET"
            ).encode(),
        )
        res = f"<< /XObject << /Im0 {x} 0 R >> /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >> >> >>"
        nums.append(page(pdf, parent, content, res, size=ps))
    root, _ = catalog(pdf, nums, pages_num=parent)
    pdf.write(path, root)


def text_content(rng, lines, fontname="/F1", size=10.5, leading=14, compress_hint=None):
    out = [f"BT {fontname} {size} Tf {leading} TL 72 770 Td"]
    for i in range(lines):
        if i % 12 == 0:
            out.append(f"/F2 13 Tf ({words(rng, 5).title()}) ' {fontname} {size} Tf")
        out.append(f"({words(rng, 12)}) '")
    out.append("ET")
    return "\n".join(out).encode()


def ttf_font(pdf, path, name):
    """A fully embedded TrueType font (FontFile2) with WinAnsi widths, as some exporters write."""
    data = path.read_bytes()
    ff = pdf.stream(f"/Length1 {len(data)}", data)
    pil = ImageFont.truetype(str(path), 1000)
    widths = " ".join(str(round(pil.getlength(chr(c)))) for c in range(32, 127))
    desc = pdf.add(
        f"<< /Type /FontDescriptor /FontName /{name} /Flags 32 /FontBBox [-600 -300 1600 1000] /ItalicAngle 0 "
        f"/Ascent 900 /Descent -220 /CapHeight 700 /StemV 80 /FontFile2 {ff} 0 R >>"
    )
    return pdf.add(
        f"<< /Type /Font /Subtype /TrueType /BaseFont /{name} /FirstChar 32 /LastChar 126 "
        f"/Widths [{widths}] /Encoding /WinAnsiEncoding /FontDescriptor {desc} 0 R >>"
    )


def doc_text_full_fonts(path, rng, pages):
    pdf = PDF("1.4")
    parent = pdf.reserve()
    f1 = ttf_font(pdf, FONTS / "Georgia.ttf", "Georgia")
    f2 = ttf_font(pdf, FONTS / "Arial Bold.ttf", "Arial-BoldMT")
    res = f"<< /Font << /F1 {f1} 0 R /F2 {f2} 0 R >> >>"
    nums = [page(pdf, parent, pdf.stream("", text_content(rng, 48)), res) for _ in range(pages)]
    root, _ = catalog(pdf, nums, pages_num=parent)
    pdf.write(path, root)


BASE14 = "<< /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Times-Roman /Encoding /WinAnsiEncoding >> /F2 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >> >> >>"


def doc_text_uncompressed(path, rng, pages):
    pdf = PDF("1.3")
    parent = pdf.reserve()
    nums = [page(pdf, parent, pdf.stream("", text_content(rng, 50), flate=False), BASE14) for _ in range(pages)]
    root, _ = catalog(pdf, nums, pages_num=parent)
    pdf.write(path, root)


def vector_content(rng, n_paths, w=595, h=842):
    out = []
    for _ in range(n_paths):
        r, g, b = rng.random(3)
        pts = rng.random((int(rng.integers(3, 9)), 2)) * [w, h]
        out.append(f"{r:.4f} {g:.4f} {b:.4f} RG {rng.random() * 2 + 0.2:.3f} w")
        out.append(f"{pts[0][0]:.4f} {pts[0][1]:.4f} m")
        for i in range(1, len(pts) - 1, 2):
            a, c = pts[i], pts[i + 1]
            out.append(f"{a[0]:.4f} {a[1]:.4f} {c[0]:.4f} {c[1]:.4f} {c[0]:.4f} {c[1]:.4f} c")
        out.append("S" if rng.random() < 0.6 else f"{r:.3f} {g:.3f} {b:.3f} rg b")
    return "\n".join(out).encode()


def doc_vector(path, rng, pages, n_paths, level):
    pdf = PDF("1.4")
    parent = pdf.reserve()
    nums = [page(pdf, parent, pdf.stream("", vector_content(rng, n_paths), flate=level > 0, level=max(level, 1)), "<< >>") for _ in range(pages)]
    root, _ = catalog(pdf, nums, pages_num=parent)
    pdf.write(path, root)


def doc_mixed(path, rng, pdf=None, write=True):
    pdf = pdf or PDF("1.5")
    parent = pdf.reserve()
    f1 = ttf_font(pdf, FONTS / "Arial.ttf", "ArialMT")
    nums = []
    for p in range(6):
        res_x = []
        content = [text_content(rng, 18).decode()]
        if p % 3 == 0:
            x = image_xobject(pdf, photo(rng, 1600, 1000), kind="jpeg", quality=92, subsampling=0)
            res_x.append(f"/P {x} 0 R")
            content.append("q 400 0 0 250 97 250 cm /P Do Q")
        if p % 3 == 1:
            shot = slide(rng, 1400, 900, p)
            x = image_xobject(pdf, shot)
            res_x.append(f"/S {x} 0 R")
            content.append("q 420 0 0 270 87 230 cm /S Do Q")
        content.append("q 0.5 w 72 72 m " + " ".join(f"{72 + i * 9} {72 + rng.random() * 120:.2f} l" for i in range(50)) + " S Q")
        res = f"<< /Font << /F1 {f1} 0 R /F2 {f1} 0 R >> /XObject << {' '.join(res_x)} >> >>"
        nums.append(page(pdf, parent, pdf.stream("", "\n".join(content).encode()), res))
    root, _ = catalog(pdf, nums, pages_num=parent)
    if write:
        pdf.write(path, root)
    return pdf, root


def pdf_string(s):
    return "(" + s.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)") + ")"


def doc_forms(path, rng):
    pdf = PDF("1.6")
    parent = pdf.reserve()
    helv = pdf.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    zadb = pdf.add("<< /Type /Font /Subtype /Type1 /BaseFont /ZapfDingbats >>")
    pg = pdf.reserve()
    fields = []
    lines = ["BT /F1 16 Tf 72 780 Td (Application form) Tj ET"]
    for i in range(8):
        y = 720 - i * 60
        lines.append(f"BT /F1 10 Tf 72 {y + 20} Td (Field {i + 1}: {words(rng, 4)}) Tj ET")
        value = words(rng, 3)
        ap = pdf.stream(f"/Type /XObject /Subtype /Form /BBox [0 0 300 20] /Resources << /Font << /Helv {helv} 0 R >> >>", f"/Tx BMC q BT /Helv 10 Tf 2 6 Td {pdf_string(value)} Tj ET Q EMC".encode())
        fields.append(
            pdf.add(
                f"<< /Type /Annot /Subtype /Widget /FT /Tx /T (name{i}) /V {pdf_string(value)} /DA (/Helv 10 Tf 0 g) "
                f"/Rect [72 {y} 372 {y + 20}] /P {pg} 0 R /F 4 /MK << /BC [0 0 0] /BG [0.95 0.95 1] >> /AP << /N {ap} 0 R >> >>"
            )
        )
    for i in range(4):
        y = 230 - i * 30
        on = pdf.stream("/Type /XObject /Subtype /Form /BBox [0 0 14 14] /Resources << /Font << /ZaDb " + str(zadb) + " 0 R >> >>", b"q BT /ZaDb 12 Tf 1 2 Td (4) Tj ET Q")
        off = pdf.stream("/Type /XObject /Subtype /Form /BBox [0 0 14 14]", b"q 0 0 14 14 re S Q")
        state = "/Yes" if i % 2 == 0 else "/Off"
        fields.append(pdf.add(f"<< /Type /Annot /Subtype /Widget /FT /Btn /T (check{i}) /V {state} /AS {state} /Rect [72 {y} 86 {y + 14}] /P {pg} 0 R /F 4 /AP << /N << /Yes {on} 0 R /Off {off} 0 R >> >> >>"))
        lines.append(f"BT /F1 10 Tf 92 {y + 3} Td (Option {i + 1}) Tj ET")
    content = pdf.stream("", "\n".join(lines).encode())
    annots = " ".join(f"{f} 0 R" for f in fields)
    page(pdf, parent, content, f"<< /Font << /F1 {helv} 0 R >> >>", extra=f"/Annots [{annots}]", num=pg)
    acro = f"/AcroForm << /Fields [{annots}] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv {helv} 0 R /ZaDb {zadb} 0 R >> >> >>"
    root, _ = catalog(pdf, [pg], extra=acro, pages_num=parent)
    pdf.write(path, root)


def doc_annotations(path, rng):
    """Links (URI and internal), notes, highlights and a two-level outline."""
    pdf = PDF("1.6")
    parent = pdf.reserve()
    pgs = [pdf.reserve() for _ in range(5)]
    for i, pg in enumerate(pgs):
        annots = []
        annots.append(pdf.add(f"<< /Type /Annot /Subtype /Link /Rect [72 700 300 716] /Border [0 0 0] /A << /S /URI /URI (https://example.org/page{i}) >> >>"))
        target = pgs[(i + 1) % len(pgs)]
        annots.append(pdf.add(f"<< /Type /Annot /Subtype /Link /Rect [72 680 300 696] /Border [0 0 0] /Dest [{target} 0 R /XYZ 0 842 0] >>"))
        annots.append(pdf.add(f"<< /Type /Annot /Subtype /Text /Rect [500 750 520 770] /Contents {pdf_string('Note ' + words(rng, 6))} /Name /Comment /C [1 1 0] >>"))
        annots.append(pdf.add(f"<< /Type /Annot /Subtype /Highlight /Rect [70 600 400 616] /QuadPoints [70 616 400 616 70 600 400 600] /C [1 0.9 0] /Contents (hl) >>"))
        text = text_content(rng, 40).decode() + f"\nBT /F2 12 Tf 72 704 Td (Visit example.org page {i}) Tj 0 -20 Td (Go to page {(i + 1) % 5 + 1}) Tj ET"
        page(pdf, parent, pdf.stream("", text.encode()), BASE14, extra=f"/Annots [{' '.join(f'{a} 0 R' for a in annots)}]", num=pg)
    outline = pdf.reserve()
    items = [pdf.reserve() for _ in range(5)]
    for i, it in enumerate(items):
        child = pdf.add(f"<< /Title (Section {i + 1}.1) /Parent {it} 0 R /Dest [{pgs[i]} 0 R /XYZ 0 400 0] >>")
        prev = f"/Prev {items[i - 1]} 0 R" if i else ""
        nxt = f"/Next {items[i + 1]} 0 R" if i < 4 else ""
        pdf.add(f"<< /Title (Chapter {i + 1}) /Parent {outline} 0 R {prev} {nxt} /First {child} 0 R /Last {child} 0 R /Count 1 /Dest [{pgs[i]} 0 R /Fit] >>", it)
    pdf.add(f"<< /Type /Outlines /First {items[0]} 0 R /Last {items[-1]} 0 R /Count 10 >>", outline)
    root, _ = catalog(pdf, pgs, extra=f"/Outlines {outline} 0 R /PageMode /UseOutlines", pages_num=parent)
    pdf.write(path, root)


def doc_tagged(path, rng):
    pdf = PDF("1.7")
    parent = pdf.reserve()
    st = pdf.reserve()
    pgs = [pdf.reserve() for _ in range(3)]
    elems = []
    for i, pg in enumerate(pgs):
        parts = []
        kids = []
        for m in range(10):
            tag = "H1" if m == 0 else "P"
            parts.append(f"/{tag} << /MCID {m} >> BDC BT /F{1 if m else 2} {16 if m == 0 else 10.5} Tf 72 {760 - m * 60} Td ({words(rng, 9)}) Tj ET EMC")
            kids.append((tag, m))
        page(pdf, parent, pdf.stream("", "\n".join(parts).encode()), BASE14, extra=f"/StructParents {i} /Tabs /S", num=pg)
        for tag, m in kids:
            elems.append((i, pg, tag, m))
    doc_el = pdf.reserve()
    el_nums = [pdf.add(f"<< /Type /StructElem /S /{tag} /P {doc_el} 0 R /Pg {pg} 0 R /K {m} >>") for (_, pg, tag, m) in elems]
    pdf.add(f"<< /Type /StructElem /S /Document /P {st} 0 R /K [{' '.join(f'{e} 0 R' for e in el_nums)}] >>", doc_el)
    nums_arr = []
    for i in range(3):
        nums_arr.append(f"{i} [{' '.join(f'{el_nums[i * 10 + m]} 0 R' for m in range(10))}]")
    pdf.add(f"<< /Type /StructTreeRoot /K {doc_el} 0 R /ParentTree << /Nums [{' '.join(nums_arr)}] >> /ParentTreeNextKey 3 >>", st)
    meta = pdf.stream("/Type /Metadata /Subtype /XML", xmp("Tagged report").encode(), flate=False)
    root, _ = catalog(pdf, pgs, extra=f"/StructTreeRoot {st} 0 R /MarkInfo << /Marked true >> /Lang (en-GB) /Metadata {meta} 0 R /ViewerPreferences << /DisplayDocTitle true >>", pages_num=parent)
    info = pdf.add("<< /Title (Tagged report) /Author (Bench) /Producer (make_corpus.py) >>")
    pdf.write(path, root, info=info)


def xmp(title, pad=0):
    return (
        '<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?><x:xmpmeta xmlns:x="adobe:ns:meta/">'
        '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" '
        f'xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title><rdf:Alt><rdf:li xml:lang="x-default">{title}</rdf:li>'
        "</rdf:Alt></dc:title></rdf:Description></rdf:RDF></x:xmpmeta>" + " " * pad + '<?xpacket end="w"?>'
    )


def doc_transparency_icc(path, rng):
    """ICC-based images (Display P3), a soft-masked image, a knockout group and blend modes."""
    pdf = PDF("1.6")
    parent = pdf.reserve()
    p3 = (PROFILES / "Display P3.icc").read_bytes()
    icc = pdf.stream("/N 3", p3)
    gray_icc = pdf.stream("/N 1", (PROFILES / "Generic Gray Gamma 2.2 Profile.icc").read_bytes())
    nums = []
    for p in range(3):
        ph = photo(rng, 1800, 1200)
        a = Image.new("L", ph.size, 0)
        ImageDraw.Draw(a).ellipse([100, 100, 1700, 1100], fill=255)
        a = a.filter(ImageFilter.GaussianBlur(30))
        sm = image_xobject(pdf, a, colorspace=f"[/ICCBased {gray_icc} 0 R]")
        im = image_xobject(pdf, ph, kind="jpeg" if p == 1 else "flate", quality=94, colorspace=f"[/ICCBased {icc} 0 R]", smask=sm)
        grp = pdf.stream(
            f"/Type /XObject /Subtype /Form /BBox [0 0 595 842] /Group << /S /Transparency /CS /DeviceRGB /I true /K true >> /Resources << /ExtGState << /G1 << /CA 0.5 /ca 0.5 /BM /Multiply >> >> >>",
            b"/G1 gs 1 0 0 rg 100 100 300 300 re f 0 0 1 rg 200 200 300 300 re f",
        )
        content = f"q 0.2 0.6 0.3 rg 0 0 595 842 re f Q q 500 0 0 333 47 450 cm /Im Do Q q /GS1 gs /Fm Do Q BT /F1 12 Tf 72 60 Td ({words(rng, 8)}) Tj ET"
        res = f"<< /XObject << /Im {im} 0 R /Fm {grp} 0 R >> /ExtGState << /GS1 << /BM /Screen /ca 0.8 >> >> {BASE14[2:-2]} >>"
        nums.append(page(pdf, parent, pdf.stream("", content.encode()), res, extra="/Group << /S /Transparency /CS /DeviceRGB >>"))
    oi = f"/OutputIntents [<< /Type /OutputIntent /S /GTS_PDFA1 /OutputConditionIdentifier (P3) /DestOutputProfile {icc} 0 R >>]"
    root, _ = catalog(pdf, nums, extra=oi, pages_num=parent)
    pdf.write(path, root)


def doc_cmyk(path, rng):
    pdf = PDF("1.4")
    parent = pdf.reserve()
    nums = []
    for p in range(2):
        img = photo(rng, 2000, 1400).convert("CMYK")
        x = image_xobject(pdf, img, kind="jpeg" if p == 0 else "flate", quality=93)
        c = pdf.stream("", b"q 0.1 0.2 0 0.05 k 0 0 595 842 re f Q q 500 0 0 350 47 300 cm /Im0 Do Q")
        nums.append(page(pdf, parent, c, f"<< /XObject << /Im0 {x} 0 R >> >>"))
    root, _ = catalog(pdf, nums, pages_num=parent)
    pdf.write(path, root)


def doc_duplicates(path, rng):
    """The same logo and photo stored again on every page, as merged exports do."""
    pdf = PDF("1.4")
    parent = pdf.reserve()
    logo = slide(rng, 600, 300, 2)
    ph = photo(rng, 1400, 900)
    nums = []
    for p in range(10):
        a = image_xobject(pdf, logo)
        b = image_xobject(pdf, ph, kind="jpeg", quality=90)
        c = pdf.stream("", (f"q 200 0 0 100 72 700 cm /A Do Q q 450 0 0 290 72 300 cm /B Do Q " + text_content(rng, 8).decode()).encode())
        nums.append(page(pdf, parent, c, f"<< /XObject << /A {a} 0 R /B {b} 0 R >> {BASE14[2:-2]} >>"))
    root, _ = catalog(pdf, nums, pages_num=parent)
    pdf.write(path, root)


def doc_metadata_heavy(path, rng):
    """Big XMP, page thumbnails, PieceInfo and a long Info dictionary."""
    pdf = PDF("1.6")
    parent = pdf.reserve()
    nums = []
    for p in range(4):
        thumb = image_xobject(pdf, photo(rng, 120, 170), kind="raw")
        piece = pdf.stream("", os.urandom(0) + bytes(rng.integers(0, 255, 40000, dtype=np.uint8)))
        c = pdf.stream("", text_content(rng, 45))
        nums.append(page(pdf, parent, c, BASE14, extra=f"/Thumb {thumb} 0 R /PieceInfo << /Illustrator << /Private {piece} 0 R /LastModified (D:20240101) >> >> /LastModified (D:20240101)"))
    meta = pdf.stream("/Type /Metadata /Subtype /XML", xmp("Metadata heavy", pad=60000).encode(), flate=False)
    root, _ = catalog(pdf, nums, extra=f"/Metadata {meta} 0 R", pages_num=parent)
    info = pdf.add("<< /Title (Metadata heavy) /Author (Bench Author) /Subject (A test) /Keywords (a, b, c) /Creator (make_corpus.py) /Producer (make_corpus.py) /CreationDate (D:20240101000000Z) /ModDate (D:20240102000000Z) >>")
    pdf.write(path, root, info=info)


def doc_photobook(path, rng):
    pdf = PDF("1.4")
    parent = pdf.reserve()
    nums = []
    for p in range(4):
        x = image_xobject(pdf, photo(rng, 3200, 4500, grain=2.5), kind="jpeg", quality=97, subsampling=0)
        c, res = full_page_image(pdf, x)
        nums.append(page(pdf, parent, c, res))
    root, _ = catalog(pdf, nums, pages_num=parent)
    pdf.write(path, root)


def doc_indexed(path, rng):
    pdf = PDF("1.4")
    parent = pdf.reserve()
    nums = []
    for p in range(3):
        img = slide(rng, 1600, 900, p + 1).quantize(64, dither=Image.Dither.NONE)
        x = image_xobject(pdf, img)
        c = pdf.stream("", b"q 595 0 0 335 0 400 cm /Im0 Do Q")
        nums.append(page(pdf, parent, c, f"<< /XObject << /Im0 {x} 0 R >> >>"))
    root, _ = catalog(pdf, nums, pages_num=parent)
    pdf.write(path, root)


def doc_inline_and_masks(path, rng):
    """Inline images, a stencil /ImageMask and a colour-key /Mask."""
    pdf = PDF("1.4")
    parent = pdf.reserve()
    stencil = Image.new("1", (800, 800), 1)
    ImageDraw.Draw(stencil).ellipse([50, 50, 750, 750], fill=0)
    sx = image_xobject(pdf, stencil)
    ck = slide(rng, 900, 600, 3)
    ckx = pdf.stream(f"/Type /XObject /Subtype /Image /Width 900 /Height 600 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Mask [0 40 0 40 0 40]", ck.tobytes())
    inline = bytes(rng.integers(0, 255, 16 * 16 * 3, dtype=np.uint8))
    content = (
        b"q 1 0 0 rg 300 0 0 300 50 450 cm /St Do Q q 400 0 0 266 150 120 cm /Ck Do Q "
        b"q 100 0 0 100 400 600 cm BI /W 16 /H 16 /CS /RGB /BPC 8 ID " + inline + b" EI Q"
    )
    c = pdf.stream("", content)
    nums = [page(pdf, parent, c, f"<< /XObject << /St {sx} 0 R /Ck {ckx} 0 R >> >>")]
    root, _ = catalog(pdf, nums, pages_num=parent)
    pdf.write(path, root)


def doc_sixteen_bit(path, rng):
    pdf = PDF("1.5")
    parent = pdf.reserve()
    ph = np.asarray(photo(rng, 1200, 800), np.uint16) * 257
    data = ph.astype(">u2").tobytes()
    x = pdf.stream("/Type /XObject /Subtype /Image /Width 1200 /Height 800 /ColorSpace /DeviceRGB /BitsPerComponent 16", data)
    c = pdf.stream("", b"q 500 0 0 333 47 400 cm /Im0 Do Q")
    nums = [page(pdf, parent, c, f"<< /XObject << /Im0 {x} 0 R >> >>")]
    root, _ = catalog(pdf, nums, pages_num=parent)
    pdf.write(path, root)


def doc_predictor_png(path, rng):
    """Flate with PNG predictors, as many exporters write images."""
    pdf = PDF("1.5")
    parent = pdf.reserve()
    img = slide(rng, 1600, 1000, 4)
    arr = np.asarray(img)
    rows = []
    prev = np.zeros_like(arr[0])
    for row in arr:
        rows.append(b"\x02" + (row.astype(np.int16) - prev).astype(np.uint8).tobytes())
        prev = row.astype(np.int16)
    x = pdf.stream("/Type /XObject /Subtype /Image /Width 1600 /Height 1000 /ColorSpace /DeviceRGB /BitsPerComponent 8 /DecodeParms << /Predictor 15 /Colors 3 /Columns 1600 >>", b"".join(rows))
    c = pdf.stream("", b"q 595 0 0 372 0 400 cm /Im0 Do Q")
    nums = [page(pdf, parent, c, f"<< /XObject << /Im0 {x} 0 R >> >>")]
    root, _ = catalog(pdf, nums, pages_num=parent)
    pdf.write(path, root)


def doc_object_streams(path, src):
    """Rewrites a classic file with every non-stream object in object streams and an xref stream."""
    data = src.read_bytes()
    import re

    objs = {}
    for m in re.finditer(rb"(\d+) 0 obj\n(.*?)\nendobj\n", data, re.S):
        objs[int(m.group(1))] = m.group(2)
    root = int(re.search(rb"/Root (\d+) 0 R", data[data.rfind(b"trailer") :]).group(1))
    plain = {n: b for n, b in objs.items() if b"stream\n" not in b}
    streams = {n: b for n, b in objs.items() if n not in plain}
    out = io.BytesIO()
    out.write(b"%PDF-1.5\n%\xe2\xe3\xcf\xd3\n")
    offsets = {}
    size = max(objs) + 3
    ostm = max(objs) + 1
    for n, b in streams.items():
        offsets[n] = (1, out.tell(), 0)
        out.write(f"{n} 0 obj\n".encode() + b + b"\nendobj\n")
    header, body = [], io.BytesIO()
    for i, (n, b) in enumerate(plain.items()):
        header.append(f"{n} {body.tell()}")
        body.write(b + b"\n")
        offsets[n] = (2, ostm, i)
    head = " ".join(header).encode() + b"\n"
    payload = zlib.compress(head + body.getvalue(), 9)
    offsets[ostm] = (1, out.tell(), 0)
    out.write(f"{ostm} 0 obj\n<< /Type /ObjStm /N {len(plain)} /First {len(head)} /Filter /FlateDecode /Length {len(payload)} >>\nstream\n".encode() + payload + b"\nendstream\nendobj\n")
    xref_num = ostm + 1
    xref_off = out.tell()
    offsets[xref_num] = (1, xref_off, 0)
    rows = [struct.pack(">BIH", 0, 0, 65535)]
    for n in range(1, size):
        t, a, b = offsets.get(n, (0, 0, 0))
        rows.append(struct.pack(">BIH", t, a, b))
    xs = zlib.compress(b"".join(rows))
    fid = hashlib.md5(b"objstm").hexdigest()
    out.write(f"{xref_num} 0 obj\n<< /Type /XRef /Size {size} /W [1 4 2] /Root {root} 0 R /ID [<{fid}> <{fid}>] /Filter /FlateDecode /Length {len(xs)} >>\nstream\n".encode() + xs + f"\nendstream\nendobj\nstartxref\n{xref_off}\n%%EOF\n".encode())
    Path(path).write_bytes(out.getvalue())


# MARK: encryption (standard security handler, RC4 128-bit, revision 3)

PAD = bytes.fromhex("28BF4E5E4E758A4164004E56FFFA01082E2E00B6D0683E802F0CA9FE6453697A")


def rc4(key, data):
    s = list(range(256))
    j = 0
    for i in range(256):
        j = (j + s[i] + key[i % len(key)]) & 255
        s[i], s[j] = s[j], s[i]
    arr = np.frombuffer(data, np.uint8)
    ks = np.empty(len(arr), np.uint8)
    i = j = 0
    for n in range(len(arr)):
        i = (i + 1) & 255
        j = (j + s[i]) & 255
        s[i], s[j] = s[j], s[i]
        ks[n] = s[(s[i] + s[j]) & 255]
    return (arr ^ ks).tobytes()


def object_key(key, num):
    return hashlib.md5(key + struct.pack("<I", num)[:3] + b"\x00\x00").digest()[: min(len(key) + 5, 16)]


def encrypt_values(user, owner, perms, file_id):
    pad = lambda p: (p.encode() + PAD)[:32]
    h = hashlib.md5(pad(owner)).digest()
    for _ in range(50):
        h = hashlib.md5(h).digest()
    o = rc4(h[:16], pad(user))
    for i in range(1, 20):
        o = rc4(bytes(b ^ i for b in h[:16]), o)
    k = hashlib.md5(pad(user) + o + struct.pack("<i", perms) + file_id).digest()
    for _ in range(50):
        k = hashlib.md5(k[:16]).digest()
    key = k[:16]
    u = rc4(key, hashlib.md5(PAD + file_id).digest())
    for i in range(1, 20):
        u = rc4(bytes(b ^ i for b in key), u)
    return key, o, u + b"\x00" * 16


def doc_encrypted(path, rng, user):
    """Strings avoided outside streams, so only stream data needs encrypting."""
    pdf = PDF("1.4")
    parent = pdf.reserve()
    x = image_xobject(pdf, photo(rng, 900, 600), kind="flate")
    nums = []
    for p in range(3):
        c = pdf.stream("", text_content(rng, 30) + b"\nq 300 0 0 200 150 80 cm /Im0 Do Q")
        nums.append(page(pdf, parent, c, f"<< /XObject << /Im0 {x} 0 R >> {BASE14[2:-2]} >>"))
    root, _ = catalog(pdf, nums, pages_num=parent)
    fid = hashlib.md5(Path(path).name.encode()).digest()
    perms = -3904  # printing and copying refused
    key, o, u = encrypt_values(user, "owner-secret", perms, fid)
    enc = pdf.add(f"<< /Filter /Standard /V 2 /R 3 /Length 128 /P {perms} /O <{o.hex()}> /U <{u.hex()}> >>")
    pdf.encrypt = (key, enc)
    pdf.write(path, root, file_id=fid.hex(), trailer_extra=f"/Encrypt {enc} 0 R")


# MARK: Quartz documents


QUARTZ = r"""
import AppKit
import CoreText
// args: out.pdf pages seed photoEvery
let a = CommandLine.arguments
let out = URL(fileURLWithPath: a[1]); let pages = Int(a[2])!; var seed = UInt64(a[3])!; let photoEvery = Int(a[4])!
func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return seed >> 33 }
let words = "WORDS".split(separator: " ").map(String.init)
func sentence(_ n: Int) -> String { (0..<n).map { _ in words[Int(next() % UInt64(words.count))] }.joined(separator: " ") }
var box = CGRect(x: 0, y: 0, width: 595.276, height: 841.89)
let info: [CFString: Any] = [kCGPDFContextTitle: "Quartz report", kCGPDFContextCreator: "make_corpus.py"]
let ctx = CGContext(out as CFURL, mediaBox: &box, info as CFDictionary)!
let body = NSFont(name: "Georgia", size: 10.5)!, head = NSFont(name: "Avenir Next Demi Bold", size: 15) ?? NSFont.boldSystemFont(ofSize: 15), mono = NSFont(name: "Menlo", size: 9)!
for p in 0..<pages {
    ctx.beginPDFPage(nil)
    let text = NSMutableAttributedString()
    text.append(NSAttributedString(string: "\(p + 1). " + sentence(5).capitalized + "\n", attributes: [.font: head]))
    for i in 0..<9 {
        let f = i == 4 ? mono : body
        text.append(NSAttributedString(string: sentence(40 + Int(next() % 30)) + ".\n\n", attributes: [.font: f]))
    }
    let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text), CFRange(location: 0, length: 0), CGPath(rect: CGRect(x: 72, y: 72, width: 451, height: 698), transform: nil), nil)
    CTFrameDraw(frame, ctx)
    ctx.setStrokeColor(CGColor(red: 0.2, green: 0.3, blue: 0.7, alpha: 1)); ctx.setLineWidth(0.6)
    ctx.move(to: CGPoint(x: 72, y: 60)); for i in 0..<60 { ctx.addLine(to: CGPoint(x: 72 + Double(i) * 7.5, y: 40 + Double(next() % 18))) }; ctx.strokePath()
    if photoEvery > 0 && p % photoEvery == 0 {
        let w = 320, h = 200
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 3, bitsPerPixel: 24)!
        let px = rep.bitmapData!
        for y in 0..<h { for x in 0..<w { let o = (y * w + x) * 3; let n = UInt8(next() % 24); px[o] = UInt8((x * 255 / w)) &+ n; px[o+1] = UInt8(y * 255 / h) &+ n; px[o+2] = 128 &+ n } }
        ctx.draw(rep.cgImage!, in: CGRect(x: 400, y: 720, width: 120, height: 75))
    }
    ctx.endPDFPage()
}
ctx.closePDF()
"""


def quartz(path, pages, seed, photo_every, workdir):
    src = workdir / "quartz_doc.swift"
    exe = workdir / "quartz_doc"
    if not exe.exists():
        src.write_text(QUARTZ.replace("WORDS", " ".join(WORDS)))
        subprocess.run(["swiftc", "-O", str(src), "-o", str(exe)], check=True)
    subprocess.run([str(exe), str(path), str(pages), str(seed), str(photo_every)], check=True)


# MARK: main


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "pdf-corpus").resolve()
    out.mkdir(parents=True, exist_ok=True)
    work = out / ".work"
    work.mkdir(exist_ok=True)
    R = lambda n: np.random.default_rng(n)
    jobs = {
        "scan-color-jpeg-300dpi": lambda p: doc_scans(p, R(1), 3, 300, "jpeg", quality=90),
        "scan-gray-jpeg-200dpi": lambda p: doc_scans(p, R(2), 4, 200, "jpeg", color=False, quality=85),
        "scan-ccitt-300dpi": lambda p: doc_scans(p, R(3), 4, 300, "ccitt"),
        "scan-ccitt-600dpi": lambda p: doc_scans(p, R(4), 1, 600, "ccitt"),
        "scan-gray-flate-300dpi": lambda p: doc_scans(p, R(5), 2, 300, "flate", color=False),
        "scan-color-flate-150dpi": lambda p: doc_scans(p, R(6), 3, 150, "flate"),
        "slides-flate-images": lambda p: doc_slides(p, R(7), 8),
        "slides-jpeg-images": lambda p: doc_slides(p, R(8), 8, kind="jpeg"),
        "slides-alpha-smask": lambda p: doc_slides(p, R(9), 5, alpha=True),
        "text-quartz-subset-fonts": lambda p: quartz(p, 24, 10, 0, work),
        "text-full-embedded-fonts": lambda p: doc_text_full_fonts(p, R(11), 12),
        "text-uncompressed-base14": lambda p: doc_text_uncompressed(p, R(12), 20),
        "vector-uncompressed": lambda p: doc_vector(p, R(13), 4, 3000, 0),
        "vector-flate-level1": lambda p: doc_vector(p, R(14), 6, 2500, 1),
        "mixed-report": lambda p: doc_mixed(p, R(15)),
        "forms-acroform": lambda p: doc_forms(p, R(16)),
        "annotations-links-outline": lambda p: doc_annotations(p, R(17)),
        "tagged-structure": lambda p: doc_tagged(p, R(18)),
        "encrypted-owner-password": lambda p: doc_encrypted(p, R(19), ""),
        "encrypted-user-password": lambda p: doc_encrypted(p, R(20), "user-secret"),
        "transparency-icc-p3": lambda p: doc_transparency_icc(p, R(21)),
        "cmyk-images": lambda p: doc_cmyk(p, R(22)),
        "pages-300-quartz": lambda p: quartz(p, 300, 23, 10, work),
        "duplicate-images": lambda p: doc_duplicates(p, R(24)),
        "metadata-heavy": lambda p: doc_metadata_heavy(p, R(25)),
        "photobook-jpeg-q97": lambda p: doc_photobook(p, R(26)),
        "indexed-images": lambda p: doc_indexed(p, R(27)),
        "inline-images-masks": lambda p: doc_inline_and_masks(p, R(28)),
        "sixteen-bit-image": lambda p: doc_sixteen_bit(p, R(29)),
        "png-predictor-image": lambda p: doc_predictor_png(p, R(30)),
        # A scanned book of about 330 MB: more stream data than the engine's 256 MB memory
        # budget, which must not count it (every page a different scan).
        "scan-book-color-jpeg-300dpi": lambda p: doc_scans(p, R(31), 140, 300, "jpeg", quality=92),
    }
    # `make_corpus.py OUT NAME...` makes only those files.
    only = set(sys.argv[2:])
    for name, make in jobs.items():
        if only and name not in only:
            continue
        make(out / f"{name}.pdf")
        print(name, flush=True)
    if only:
        return
    doc_object_streams(out / "object-streams-xref-stream.pdf", out / "mixed-report.pdf")
    # Linearised: gs with lossless settings, so the images stay as they are.
    env = dict(os.environ, SOURCE_DATE_EPOCH="1700000000")
    subprocess.run(
        ["gs", "-q", "-dSAFER", "-dBATCH", "-dNOPAUSE", "-sDEVICE=pdfwrite", "-dFastWebView=true", "-dPassThroughJPEGImages=true",
         "-dAutoFilterColorImages=false", "-dColorImageFilter=/FlateEncode", "-dDownsampleColorImages=false", "-dDownsampleGrayImages=false",
         "-dAutoFilterGrayImages=false", "-dGrayImageFilter=/FlateEncode", "-dCompressFonts=false", "-dSubsetFonts=false",
         f"-sOutputFile={out / 'linearised.pdf'}", str(out / "slides-jpeg-images.pdf")],
        check=True, env=env,
    )
    # Damaged: truncated in the middle (no xref, no trailer), and one with a broken xref and a
    # stream whose /Length lies.
    whole = (out / "mixed-report.pdf").read_bytes()
    (out / "damaged-truncated.pdf").write_bytes(whole[: int(len(whole) * 0.7)])
    bad = bytearray((out / "annotations-links-outline.pdf").read_bytes())
    sx = bad.rfind(b"startxref")
    bad[sx + 10 : sx + 16] = b"999999"
    first = bad.find(b"/Length ")
    bad[first + 8 : first + 9] = b"9"
    (out / "damaged-bad-xref.pdf").write_bytes(bytes(bad))
    for f in work.iterdir():
        f.unlink()
    work.rmdir()
    with open(out / "SHA256SUMS", "w") as sums:
        for f in sorted(out.glob("*.pdf")):
            sums.write(f"{hashlib.sha256(f.read_bytes()).hexdigest()}  {f.name}\n")
    print(f"{len(list(out.glob('*.pdf')))} files in {out}")


if __name__ == "__main__":
    main()

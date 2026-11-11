// SPDX-License-Identifier: GPL-3.0-or-later
//! Subsetting of CFF font programs with glyph ids kept: the charstring of every glyph no page
//! draws becomes a bare `endchar`, and nothing else changes. The charset (so CID to glyph),
//! FDSelect, Encoding, Private dicts, local and global subroutines are copied byte for byte;
//! only the CharStrings INDEX is rebuilt, the FDArray INDEX is re-serialised because its Private
//! offsets move, and the Top DICT gets the new offsets. (A general subsetter renumbers or
//! rewrites the charset, which changed how a viewer looked up CIDs: skera turned a CID-keyed
//! font's glyphs into dots, pdf.js issue18062.)
//!
//! Layout written: header, Name, Top DICT, String and Global Subr INDEXes, then the rest of the
//! original file with the old CharStrings and FDArray cut out, then the new CharStrings and
//! FDArray. DICT offsets are written as five-byte integers, so a DICT's size does not depend on
//! the values. A Private dict whose Subrs would not stay at the same distance after the cut,
//! more than one font, or CFF2, leave the program as it is (`None`).

const ENDCHAR: u8 = 14;

/// The byte ranges of an INDEX starting at `at`: its items and where it ends.
fn index(data: &[u8], at: usize) -> Option<(Vec<std::ops::Range<usize>>, usize)> {
    let count = u16::from_be_bytes([*data.get(at)?, *data.get(at + 1)?]) as usize;
    if count == 0 {
        return Some((Vec::new(), at + 2));
    }
    let off_size = *data.get(at + 2)? as usize;
    if !(1..=4).contains(&off_size) {
        return None;
    }
    let offsets_at = at + 3;
    let read = |i: usize| -> Option<usize> {
        let b = data.get(offsets_at + i * off_size..offsets_at + (i + 1) * off_size)?;
        Some(b.iter().fold(0usize, |v, x| (v << 8) | *x as usize))
    };
    let base = offsets_at + (count + 1) * off_size - 1;
    let mut items = Vec::with_capacity(count);
    for i in 0..count {
        let (a, b) = (read(i)?, read(i + 1)?);
        if a == 0 || b < a || base + b > data.len() {
            return None;
        }
        items.push(base + a..base + b);
    }
    let end = base + read(count)?;
    Some((items, end))
}

#[cfg(test)]
pub fn test_index(items: &[&[u8]]) -> Vec<u8> {
    write_index(items)
}

fn write_index(items: &[&[u8]]) -> Vec<u8> {
    let mut out = (items.len() as u16).to_be_bytes().to_vec();
    if items.is_empty() {
        return out;
    }
    let total: usize = items.iter().map(|i| i.len()).sum::<usize>() + 1;
    let off_size = match total {
        0..=0xFF => 1,
        0x100..=0xFFFF => 2,
        0x1_0000..=0xFF_FFFF => 3,
        _ => 4,
    };
    out.push(off_size as u8);
    let mut pos = 1usize;
    let put = |out: &mut Vec<u8>, v: usize| out.extend_from_slice(&(v as u32).to_be_bytes()[4 - off_size..]);
    put(&mut out, pos);
    for i in items {
        pos += i.len();
        put(&mut out, pos);
    }
    for i in items {
        out.extend_from_slice(i);
    }
    out
}

/// One DICT entry: its operator (two-byte operators as 1200 + second byte) and the raw bytes
/// of its operands, with the integer values where they are integers.
struct Entry {
    op: u16,
    raw: Vec<u8>,
    ints: Vec<Option<i64>>,
}

fn parse_dict(data: &[u8]) -> Option<Vec<Entry>> {
    let mut out = Vec::new();
    let (mut raw, mut ints) = (Vec::new(), Vec::new());
    let mut i = 0;
    while i < data.len() {
        let b0 = data[i];
        match b0 {
            0..=21 => {
                let op = if b0 == 12 {
                    i += 1;
                    1200 + u16::from(*data.get(i)?)
                } else {
                    u16::from(b0)
                };
                i += 1;
                out.push(Entry { op, raw: std::mem::take(&mut raw), ints: std::mem::take(&mut ints) });
            }
            28 => {
                let v = i16::from_be_bytes([*data.get(i + 1)?, *data.get(i + 2)?]);
                raw.extend_from_slice(data.get(i..i + 3)?);
                ints.push(Some(i64::from(v)));
                i += 3;
            }
            29 => {
                let v =
                    i32::from_be_bytes([*data.get(i + 1)?, *data.get(i + 2)?, *data.get(i + 3)?, *data.get(i + 4)?]);
                raw.extend_from_slice(data.get(i..i + 5)?);
                ints.push(Some(i64::from(v)));
                i += 5;
            }
            30 => {
                let start = i;
                i += 1;
                loop {
                    let b = *data.get(i)?;
                    i += 1;
                    if b & 0x0F == 0x0F || b >> 4 == 0x0F {
                        break;
                    }
                }
                raw.extend_from_slice(&data[start..i]);
                ints.push(None);
            }
            32..=246 => {
                raw.push(b0);
                ints.push(Some(i64::from(b0) - 139));
                i += 1;
            }
            247..=250 => {
                let b1 = i64::from(*data.get(i + 1)?);
                raw.extend_from_slice(&data[i..i + 2]);
                ints.push(Some((i64::from(b0) - 247) * 256 + b1 + 108));
                i += 2;
            }
            251..=254 => {
                let b1 = i64::from(*data.get(i + 1)?);
                raw.extend_from_slice(&data[i..i + 2]);
                ints.push(Some(-(i64::from(b0) - 251) * 256 - b1 - 108));
                i += 2;
            }
            _ => return None,
        }
    }
    raw.is_empty().then_some(out)
}

fn int5(v: i64) -> [u8; 5] {
    let b = (v as i32).to_be_bytes();
    [29, b[0], b[1], b[2], b[3]]
}

/// Serialises `entries`, writing the operands of the operators in `fixed` as five-byte
/// integers with the values `value(op, index, old)` gives.
fn write_dict(entries: &[Entry], fixed: &[u16], value: &dyn Fn(u16, usize, i64) -> i64) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    for e in entries {
        if fixed.contains(&e.op) {
            for (k, v) in e.ints.iter().enumerate() {
                out.extend_from_slice(&int5(value(e.op, k, (*v)?)));
            }
        } else {
            out.extend_from_slice(&e.raw);
        }
        if e.op >= 1200 {
            out.extend_from_slice(&[12, (e.op - 1200) as u8]);
        } else {
            out.push(e.op as u8);
        }
    }
    Some(out)
}

fn get(entries: &[Entry], op: u16) -> Option<&Entry> {
    entries.iter().find(|e| e.op == op)
}

const CHARSET: u16 = 15;
const ENCODING: u16 = 16;
const CHARSTRINGS: u16 = 17;
const PRIVATE: u16 = 18;
const SUBRS: u16 = 19;
const FDARRAY: u16 = 1236;
const FDSELECT: u16 = 1237;

/// The CFF with every glyph `keep` refuses reduced to `endchar`, glyph ids, charset and
/// everything else unchanged; `None` when the layout is not one this handles.
pub fn subset(data: &[u8], keep: &dyn Fn(usize) -> bool) -> Option<Vec<u8>> {
    if data.first() != Some(&1) {
        return None; // CFF2 or not CFF
    }
    let hdr = *data.get(2)? as usize;
    let (_, name_end) = index(data, hdr)?;
    let (tops, top_end) = index(data, name_end)?;
    if tops.len() != 1 {
        return None;
    }
    let (_, strings_end) = index(data, top_end)?;
    let (_, gsubrs_end) = index(data, strings_end)?;
    let top = parse_dict(&data[tops[0].clone()])?;
    let off = |op: u16, k: usize| get(&top, op).and_then(|e| *e.ints.get(k)?).map(|v| v as usize);
    let cs_at = off(CHARSTRINGS, 0)?;
    let (glyphs, cs_end) = index(data, cs_at)?;
    let fd = get(&top, FDARRAY).is_some().then(|| off(FDARRAY, 0)).flatten();
    let fd_index = match fd {
        Some(at) => Some((at, index(data, at)?)),
        None => None,
    };
    // Regions cut from the copied tail, sorted.
    let mut cuts = vec![(cs_at, cs_end)];
    if let Some((at, (_, end))) = &fd_index {
        cuts.push((*at, *end));
    }
    cuts.sort();
    if cuts.iter().any(|c| c.0 < gsubrs_end) || cuts.windows(2).any(|w| w[0].1 > w[1].0) {
        return None;
    }
    // Old offset (in the copied tail) -> offset after the new head; `None` inside a cut.
    let shift = |o: usize, head: usize| -> Option<usize> {
        if o < gsubrs_end || o > data.len() {
            return None;
        }
        let mut removed = 0;
        for &(a, b) in &cuts {
            if o >= b {
                removed += b - a;
            } else if o >= a {
                return None;
            }
        }
        Some(head + o - gsubrs_end - removed)
    };
    // Private dicts must keep their Subrs at the same distance.
    let private_ok = |entries: &[Entry]| -> bool {
        let Some(p) = get(entries, PRIVATE) else { return true };
        let (Some(Some(size)), Some(Some(at))) = (p.ints.first(), p.ints.get(1)) else { return false };
        let (size, at) = (*size as usize, *at as usize);
        let Some(pd) = data.get(at..at + size).and_then(parse_dict) else { return false };
        match get(&pd, SUBRS).and_then(|e| *e.ints.first()?) {
            None => true,
            Some(rel) => {
                let sub = at + rel as usize;
                matches!((shift(at, 0), shift(sub, 0)), (Some(a), Some(b)) if b == a + rel as usize)
            }
        }
    };
    if !private_ok(&top) {
        return None;
    }
    let fd_dicts: Vec<Vec<Entry>> = match &fd_index {
        Some((_, (items, _))) => items.iter().map(|r| parse_dict(&data[r.clone()])).collect::<Option<_>>()?,
        None => Vec::new(),
    };
    if !fd_dicts.iter().all(|d| private_ok(d)) {
        return None;
    }

    // Head: header, Name, Top DICT (fixed-size offsets), String, Global Subrs.
    let tail_len = data.len() - gsubrs_end - cuts.iter().map(|c| c.1 - c.0).sum::<usize>();
    let fixed = [CHARSET, ENCODING, CHARSTRINGS, PRIVATE, FDARRAY, FDSELECT];
    let head_len = |top_dict: &[u8]| hdr + (name_end - hdr) + write_index(&[top_dict]).len() + (gsubrs_end - top_end);
    let draft = write_dict(&top, &fixed, &|_, _, v| v)?;
    let head = head_len(&draft);
    let new_cs_at = head + tail_len;
    let charstrings: Vec<&[u8]> = glyphs
        .iter()
        .enumerate()
        .map(|(g, r)| if g == 0 || keep(g) { &data[r.clone()] } else { &[ENDCHAR][..] })
        .collect();
    let cs_index = write_index(&charstrings);
    let new_fd_at = new_cs_at + cs_index.len();
    let moved = |op: u16, k: usize, v: i64| -> i64 {
        let v = v as usize;
        let mapped = match (op, k) {
            (CHARSTRINGS, _) => Some(new_cs_at),
            (FDARRAY, _) => Some(new_fd_at),
            (CHARSET, _) if v <= 2 => Some(v),
            (ENCODING, _) if v <= 1 => Some(v),
            (PRIVATE, 0) => Some(v),
            _ => shift(v, head),
        };
        mapped.map_or(-1, |m| m as i64)
    };
    let top_dict = write_dict(&top, &fixed, &moved)?;
    if top_dict.len() != draft.len() || parse_dict(&top_dict)?.iter().any(|e| e.ints.contains(&Some(-1))) {
        return None;
    }
    let fd_bytes: Vec<Vec<u8>> = fd_dicts.iter().map(|d| write_dict(d, &[PRIVATE], &moved)).collect::<Option<_>>()?;
    if fd_bytes.iter().any(|b| parse_dict(b).is_none_or(|e| e.iter().any(|e| e.ints.contains(&Some(-1))))) {
        return None;
    }

    let mut out = Vec::with_capacity(data.len());
    out.extend_from_slice(&data[..name_end]);
    out.extend_from_slice(&write_index(&[&top_dict]));
    out.extend_from_slice(&data[top_end..gsubrs_end]);
    let mut at = gsubrs_end;
    for &(a, b) in &cuts {
        out.extend_from_slice(&data[at..a]);
        at = b;
    }
    out.extend_from_slice(&data[at..]);
    debug_assert_eq!(out.len(), new_cs_at);
    out.extend_from_slice(&cs_index);
    if fd_index.is_some() {
        let refs: Vec<&[u8]> = fd_bytes.iter().map(Vec::as_slice).collect();
        out.extend_from_slice(&write_index(&refs));
    }
    Some(out)
}

/// The number of glyphs (CharStrings) of a CFF font.
pub fn glyph_count(data: &[u8]) -> Option<usize> {
    let hdr = *data.get(2)? as usize;
    let (_, name_end) = index(data, hdr)?;
    let (tops, _) = index(data, name_end)?;
    let top = parse_dict(&data[tops.first()?.clone()])?;
    let at = get(&top, CHARSTRINGS).and_then(|e| *e.ints.first()?)? as usize;
    Some(index(data, at)?.0.len())
}

/// Whether the font is CID-keyed (its Top DICT has `ROS`).
pub fn is_cid(data: &[u8]) -> bool {
    (|| {
        let hdr = *data.get(2)? as usize;
        let (_, name_end) = index(data, hdr)?;
        let (tops, _) = index(data, name_end)?;
        Some(get(&parse_dict(&data[tops.first()?.clone()])?, 1230).is_some())
    })()
    .unwrap_or(false)
}

/// For a CID-keyed font (its Top DICT has `ROS`), the CID of each glyph from the charset
/// (formats 0, 1 and 2); `None` for a name-keyed font or a charset this cannot read.
pub fn cids(data: &[u8]) -> Option<Vec<u16>> {
    let hdr = *data.get(2)? as usize;
    let (_, name_end) = index(data, hdr)?;
    let (tops, _) = index(data, name_end)?;
    let top = parse_dict(&data[tops.first()?.clone()])?;
    get(&top, 1230)?; // ROS
    let n = glyph_count(data)?;
    let mut at = get(&top, CHARSET).and_then(|e| *e.ints.first()?)? as usize;
    if at <= 2 {
        return None;
    }
    let u16_at = |i: usize| -> Option<u16> { Some(u16::from_be_bytes([*data.get(i)?, *data.get(i + 1)?])) };
    let format = *data.get(at)?;
    at += 1;
    let mut out = vec![0u16];
    while out.len() < n {
        match format {
            0 => {
                out.push(u16_at(at)?);
                at += 2;
            }
            1 | 2 => {
                let first = u16_at(at)?;
                let left = if format == 1 { u16::from(*data.get(at + 2)?) } else { u16_at(at + 2)? };
                at += if format == 1 { 3 } else { 4 };
                for k in 0..=left {
                    out.push(first.checked_add(k)?);
                }
            }
            _ => return None,
        }
    }
    out.truncate(n);
    Some(out)
}

/// The glyphs that the glyphs in `kept` draw through `seac` (an accented glyph built from a base
/// and an accent named by StandardEncoding codes: `endchar` with four arguments, or Type 1's
/// `seac`), found by running each kept charstring with its subroutines. Empty for a CID-keyed
/// font, where `seac` does not apply. `None` when a kept charstring does not run or names a
/// glyph the charset lacks: the caller then keeps the font whole.
pub fn seac_components(data: &[u8], kept: &std::collections::BTreeSet<u16>) -> Option<std::collections::BTreeSet<u16>> {
    use read_fonts::model::Error;
    use read_fonts::ps::charstring::{CharstringContext, CharstringKind, NullSink, evaluate};
    use read_fonts::ps::{PredefinedEncoding, Sid};
    use std::cell::RefCell;
    use std::collections::{BTreeSet, HashMap};

    if is_cid(data) {
        return Some(BTreeSet::new());
    }
    let hdr = *data.get(2)? as usize;
    let (_, name_end) = index(data, hdr)?;
    let (tops, top_end) = index(data, name_end)?;
    let (_, strings_end) = index(data, top_end)?;
    let (gsubrs, _) = index(data, strings_end)?;
    let top = parse_dict(&data[tops.first()?.clone()])?;
    let cs = charstrings(data)?;
    // Local subroutines: the Private DICT's Subrs, relative to the Private DICT.
    let subrs = match get(&top, PRIVATE) {
        Some(p) => {
            let (size, at) = ((*p.ints.first()?)? as usize, (*p.ints.get(1)?)? as usize);
            let pd = parse_dict(data.get(at..at.checked_add(size)?)?)?;
            match get(&pd, SUBRS).and_then(|e| *e.ints.first()?) {
                Some(rel) => index(data, at.checked_add(rel as usize)?)?.0,
                None => Vec::new(),
            }
        }
        None => Vec::new(),
    };
    // Glyph by standard name, through the charset (0: ISOAdobe, glyph i is SID i).
    let charset_at = get(&top, CHARSET).and_then(|e| *e.ints.first()?).unwrap_or(0) as usize;
    let sids: Vec<u16> = match charset_at {
        0 => (0..cs.len() as u16).collect(),
        1 | 2 => return kept_without_seac(data, &cs, &gsubrs, &subrs, kept),
        at => names_keyed_charset(data, at, cs.len())?,
    };
    let by_name: HashMap<&'static [u8], u16> =
        sids.iter().enumerate().filter_map(|(g, s)| Some((Sid::new(*s).resolve_standard().ok()?, g as u16))).collect();

    struct Context<'a> {
        cs: &'a [&'a [u8]],
        gsubrs: Vec<&'a [u8]>,
        subrs: Vec<&'a [u8]>,
        by_name: Option<HashMap<&'static [u8], u16>>,
        found: RefCell<Vec<u16>>,
    }
    fn bias(n: usize) -> i32 {
        if n < 1240 {
            107
        } else if n < 33900 {
            1131
        } else {
            32768
        }
    }
    impl CharstringContext for Context<'_> {
        fn kind(&self) -> CharstringKind {
            CharstringKind::Type2
        }
        fn seac_components(&self, base: i32, accent: i32) -> Result<[&[u8]; 2], Error> {
            let by_name = self.by_name.as_ref().ok_or(Error::InvalidOperation)?;
            let gid = |code: i32| -> Option<u16> {
                let name = PredefinedEncoding::Standard.name(u8::try_from(code).ok()?);
                by_name.get(name.as_bytes()).copied()
            };
            let (b, a) = (gid(base).ok_or(Error::InvalidOperation)?, gid(accent).ok_or(Error::InvalidOperation)?);
            self.found.borrow_mut().extend([b, a]);
            Ok([self.cs.get(b as usize).ok_or(Error::Malformed)?, self.cs.get(a as usize).ok_or(Error::Malformed)?])
        }
        fn global_subr(&self, i: i32) -> Result<&[u8], Error> {
            usize::try_from(i + bias(self.gsubrs.len()))
                .ok()
                .and_then(|i| self.gsubrs.get(i).copied())
                .ok_or(Error::Malformed)
        }
        fn subr(&self, i: i32) -> Result<&[u8], Error> {
            usize::try_from(i + bias(self.subrs.len()))
                .ok()
                .and_then(|i| self.subrs.get(i).copied())
                .ok_or(Error::Malformed)
        }
    }

    /// For predefined Expert charsets (rare): fine as long as no kept glyph uses `seac`.
    fn kept_without_seac(
        data: &[u8],
        cs: &[&[u8]],
        gsubrs: &[std::ops::Range<usize>],
        subrs: &[std::ops::Range<usize>],
        kept: &BTreeSet<u16>,
    ) -> Option<BTreeSet<u16>> {
        let ctx = Context {
            cs,
            gsubrs: gsubrs.iter().map(|r| &data[r.clone()]).collect(),
            subrs: subrs.iter().map(|r| &data[r.clone()]).collect(),
            by_name: None,
            found: RefCell::new(Vec::new()),
        };
        for g in kept {
            evaluate(&ctx, None, cs.get(*g as usize)?, &mut NullSink).ok()?;
        }
        Some(BTreeSet::new())
    }

    let ctx = Context {
        cs: &cs,
        gsubrs: gsubrs.iter().map(|r| &data[r.clone()]).collect(),
        subrs: subrs.iter().map(|r| &data[r.clone()]).collect(),
        by_name: Some(by_name),
        found: RefCell::new(Vec::new()),
    };
    for g in kept {
        evaluate(&ctx, None, cs.get(*g as usize)?, &mut NullSink).ok()?;
    }
    Some(ctx.found.into_inner().into_iter().collect())
}

/// The SID of each glyph of a name-keyed font's charset at `at` (formats 0, 1 and 2).
fn names_keyed_charset(data: &[u8], mut at: usize, n: usize) -> Option<Vec<u16>> {
    let u16_at = |i: usize| -> Option<u16> { Some(u16::from_be_bytes([*data.get(i)?, *data.get(i + 1)?])) };
    let format = *data.get(at)?;
    at += 1;
    let mut out = vec![0u16];
    while out.len() < n {
        match format {
            0 => {
                out.push(u16_at(at)?);
                at += 2;
            }
            1 | 2 => {
                let first = u16_at(at)?;
                let left = if format == 1 { u16::from(*data.get(at + 2)?) } else { u16_at(at + 2)? };
                at += if format == 1 { 3 } else { 4 };
                for k in 0..=left {
                    out.push(first.checked_add(k)?);
                }
            }
            _ => return None,
        }
    }
    out.truncate(n);
    Some(out)
}

/// The charstring bytes of each glyph.
pub fn charstrings(data: &[u8]) -> Option<Vec<&[u8]>> {
    let hdr = *data.get(2)? as usize;
    let (_, name_end) = index(data, hdr)?;
    let (tops, _) = index(data, name_end)?;
    let top = parse_dict(&data[tops.first()?.clone()])?;
    let at = get(&top, CHARSTRINGS).and_then(|e| *e.ints.first()?)? as usize;
    Some(index(data, at)?.0.into_iter().map(|r| &data[r]).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn charset_formats() {
        // Format 2 range: CIDs 5..=7 for glyphs 1..=3, through a minimal font's charset.
        let ranges = [2u8, 0, 5, 0, 2];
        let mut cids = vec![0u16];
        let (first, left) = (u16::from_be_bytes([ranges[1], ranges[2]]), u16::from_be_bytes([ranges[3], ranges[4]]));
        for k in 0..=left {
            cids.push(first + k);
        }
        assert_eq!(cids, vec![0, 5, 6, 7]);
    }

    #[test]
    fn index_round_trip() {
        let items: Vec<&[u8]> = vec![b"ab", b"", b"cde"];
        let bytes = write_index(&items);
        let (ranges, end) = index(&bytes, 0).unwrap();
        assert_eq!(end, bytes.len());
        assert_eq!(ranges.iter().map(|r| &bytes[r.clone()]).collect::<Vec<_>>(), items);
    }

    #[test]
    fn dict_round_trip() {
        // 391 (charset), then 1000 0 Private, 12 36 with a five-byte operand.
        let d = [248u8, 27, 15, 250, 124, 139, 18, 29, 0, 0, 1, 0, 12, 36];
        let e = parse_dict(&d).unwrap();
        assert_eq!(e.iter().map(|e| e.op).collect::<Vec<_>>(), vec![15, 18, 1236]);
        assert_eq!(e[0].ints, vec![Some(391)]);
        assert_eq!(e[1].ints, vec![Some(1000), Some(0)]);
        assert_eq!(write_dict(&e, &[], &|_, _, v| v).unwrap(), d.to_vec());
    }
}

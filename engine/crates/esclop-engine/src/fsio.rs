// SPDX-License-Identifier: GPL-3.0-or-later
//! Reading inputs and writing outputs atomically.
//!
//! Every output goes to a temporary file in the destination folder and is renamed into place, so
//! a reader never sees a half-written file and a failed or cancelled request leaves nothing
//! behind. In-place writes keep the original's permissions, creation date and extended
//! attributes. The engine never opens a network connection.

use crate::error::{EngineError, ErrorCode, Result};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

/// Refuse inputs bigger than this (2 GiB): nothing the engine handles is legitimately that large.
const MAX_INPUT: u64 = 2 << 30;

pub fn read_input(path: &Path) -> Result<Vec<u8>> {
    let meta = fs::metadata(path).map_err(|e| EngineError::io(e, path))?;
    if !meta.is_file() {
        return Err(EngineError::new(ErrorCode::InvalidParams, format!("{} is not a file", path.display())));
    }
    if meta.len() > MAX_INPUT {
        return Err(EngineError::unsupported(format!("{} is larger than 2 GiB", path.display())));
    }
    fs::read(path).map_err(|e| EngineError::io(e, path))
}

/// Where and how a result is written.
#[derive(Debug, Clone)]
pub struct OutputTarget {
    pub path: PathBuf,
    pub in_place: bool,
    /// The input whose permissions (and, in place, dates and xattrs) the output takes.
    pub source: Option<PathBuf>,
}

impl OutputTarget {
    /// Validates `input`/`output` against the protocol rules.
    pub fn resolve(input: Option<&Path>, output: Option<&Path>, in_place: bool) -> Result<Self> {
        let output = match (output, in_place) {
            (Some(o), _) => o.to_path_buf(),
            (None, true) => input.ok_or_else(|| EngineError::invalid("`in_place` needs `input`"))?.to_path_buf(),
            (None, false) => return Err(EngineError::invalid("missing `output` (or set `params.in_place`)")),
        };
        if !output.is_absolute() {
            return Err(EngineError::invalid(format!("`output` must be an absolute path: {}", output.display())));
        }
        let same = input.is_some_and(|i| same_file(i, &output));
        if same && !in_place {
            return Err(EngineError::invalid("`output` equals `input`; set `params.in_place` to overwrite it"));
        }
        // Writing through a symlink replaces the link's target, not the link.
        let path = if same { fs::canonicalize(&output).unwrap_or(output) } else { output };
        Ok(Self { path, in_place: same, source: input.map(Path::to_path_buf) })
    }

    /// Atomically writes `data`.
    pub fn write(&self, data: &[u8]) -> Result<()> {
        let dir = self.path.parent().filter(|d| !d.as_os_str().is_empty()).unwrap_or(Path::new("."));
        if !dir.is_dir() {
            return Err(EngineError::new(
                ErrorCode::NotFound,
                format!("output folder {} does not exist", dir.display()),
            ));
        }
        let name = self.path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let mut tmp = tempfile::Builder::new()
            .prefix(&format!(".{name}."))
            .suffix(".esclop-tmp")
            .tempfile_in(dir)
            .map_err(|e| EngineError::io(e, dir))?;
        tmp.write_all(data).map_err(|e| EngineError::io(e, tmp.path()))?;
        tmp.as_file().sync_all().map_err(|e| EngineError::io(e, tmp.path()))?;
        if let Some(src) = &self.source {
            if let Ok(meta) = fs::metadata(src) {
                let _ = fs::set_permissions(tmp.path(), meta.permissions());
                if self.in_place {
                    preserve_dates_and_xattrs(src, tmp.as_file(), tmp.path(), &meta);
                }
            }
        } else {
            // tempfile creates 0600; give new files the usual 0644
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = fs::set_permissions(tmp.path(), fs::Permissions::from_mode(0o644));
            }
        }
        tmp.persist(&self.path).map_err(|e| EngineError::io(e.error, &self.path))?;
        Ok(())
    }
}

fn same_file(a: &Path, b: &Path) -> bool {
    if a == b {
        return true;
    }
    match (fs::canonicalize(a), fs::canonicalize(b)) {
        (Ok(x), Ok(y)) => x == y,
        _ => false,
    }
}

#[cfg(target_os = "macos")]
fn preserve_dates_and_xattrs(src: &Path, file: &fs::File, tmp: &Path, meta: &fs::Metadata) {
    use std::os::darwin::fs::FileTimesExt;
    if let Ok(created) = meta.created() {
        let _ = file.set_times(fs::FileTimes::new().set_created(created));
    }
    copy_xattrs(src, tmp);
}

#[cfg(not(target_os = "macos"))]
fn preserve_dates_and_xattrs(_src: &Path, _file: &fs::File, _tmp: &Path, _meta: &fs::Metadata) {}

/// Copies extended attributes (Finder tags, "where from", quarantine) best effort.
#[cfg(target_os = "macos")]
fn copy_xattrs(src: &Path, dst: &Path) {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    let (Ok(s), Ok(d)) = (CString::new(src.as_os_str().as_bytes()), CString::new(dst.as_os_str().as_bytes())) else {
        return;
    };
    unsafe {
        let len = libc::listxattr(s.as_ptr(), std::ptr::null_mut(), 0, 0);
        if len <= 0 {
            return;
        }
        let mut names = vec![0u8; len as usize];
        let len = libc::listxattr(s.as_ptr(), names.as_mut_ptr().cast(), names.len(), 0);
        if len <= 0 {
            return;
        }
        for name in names[..len as usize].split(|&c| c == 0).filter(|n| !n.is_empty()) {
            let Ok(n) = CString::new(name) else { continue };
            let size = libc::getxattr(s.as_ptr(), n.as_ptr(), std::ptr::null_mut(), 0, 0, 0);
            if size < 0 {
                continue;
            }
            let mut val = vec![0u8; size as usize];
            let size = libc::getxattr(s.as_ptr(), n.as_ptr(), val.as_mut_ptr().cast(), val.len(), 0, 0);
            if size >= 0 {
                libc::setxattr(d.as_ptr(), n.as_ptr(), val.as_ptr().cast(), size as usize, 0, 0);
            }
        }
    }
}

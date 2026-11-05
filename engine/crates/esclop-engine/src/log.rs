// SPDX-License-Identifier: GPL-3.0-or-later
//! Logs go to stderr only; stdout belongs to the protocol. `ESCLOP_ENGINE_LOG=debug` adds detail.

use std::io::Write;
use std::sync::OnceLock;

fn debug_enabled() -> bool {
    static D: OnceLock<bool> = OnceLock::new();
    *D.get_or_init(|| std::env::var("ESCLOP_ENGINE_LOG").is_ok_and(|v| v.eq_ignore_ascii_case("debug")))
}

fn emit(level: &str, msg: &str) {
    let _ = writeln!(std::io::stderr().lock(), "esclop-engine {level}: {msg}");
}

pub fn error(msg: &str) {
    emit("error", msg);
}

pub fn warn(msg: &str) {
    emit("warning", msg);
}

pub fn debug(msg: &str) {
    if debug_enabled() {
        emit("debug", msg);
    }
}

/// Peak resident memory of this process so far, in MB (for debug logs).
pub fn peak_rss_mb() -> u64 {
    let mut ru: libc::rusage = unsafe { std::mem::zeroed() };
    if unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut ru) } != 0 {
        return 0;
    }
    // bytes on macOS, kilobytes on Linux
    let v = ru.ru_maxrss as u64;
    if cfg!(target_os = "macos") { v >> 20 } else { v >> 10 }
}

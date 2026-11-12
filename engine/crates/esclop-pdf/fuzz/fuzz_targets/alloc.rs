// SPDX-License-Identifier: MPL-2.0
//! Counts the live heap, and aborts (libFuzzer then saves the input) once one input holds more
//! than `LIMIT`: the memory budget (256 MB), the images decoded in flight (256 MB at most), the
//! input and its copies, with room to spare. libFuzzer's own `-rss_limit_mb` reads the process's
//! peak RSS, which cannot tell which input reached it.

use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering};

pub const LIMIT: usize = 768 << 20;

pub struct Counting;

static LIVE: AtomicUsize = AtomicUsize::new(0);

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let live = LIVE.fetch_add(layout.size(), Ordering::Relaxed) + layout.size();
        if live > LIMIT {
            eprintln!("live heap {} MB over the {} MB limit", live >> 20, LIMIT >> 20);
            std::process::abort();
        }
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        LIVE.fetch_sub(layout.size(), Ordering::Relaxed);
        unsafe { System.dealloc(ptr, layout) }
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        let live = LIVE.fetch_add(layout.size(), Ordering::Relaxed) + layout.size();
        if live > LIMIT {
            eprintln!("live heap {} MB over the {} MB limit", live >> 20, LIMIT >> 20);
            std::process::abort();
        }
        unsafe { System.alloc_zeroed(layout) }
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        if new_size > layout.size() {
            let live = LIVE.fetch_add(new_size - layout.size(), Ordering::Relaxed) + new_size - layout.size();
            if live > LIMIT {
                eprintln!("live heap {} MB over the {} MB limit", live >> 20, LIMIT >> 20);
                std::process::abort();
            }
        } else {
            LIVE.fetch_sub(layout.size() - new_size, Ordering::Relaxed);
        }
        unsafe { System.realloc(ptr, layout, new_size) }
    }
}

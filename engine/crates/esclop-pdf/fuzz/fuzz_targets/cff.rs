// SPDX-License-Identifier: MPL-2.0
#![no_main]

mod alloc;

#[global_allocator]
static HEAP: alloc::Counting = alloc::Counting;

libfuzzer_sys::fuzz_target!(|data: &[u8]| esclop_pdf::fuzzing::cff(data));

// SPDX-License-Identifier: GPL-3.0-or-later
//! Why `pdf.optimise` leaves a file as it is, in words for people: sent as the error's `reason`
//! (the `message` keeps the detail). The app shows them translated; every sentence here needs an
//! entry in Sources/EsclopAppKit/Resources/Localizable.xcstrings (a Swift test reads this file).

pub const SIGNED: &str = "Signed PDFs are left as they are, so their signatures stay valid.";
pub const PASSWORD: &str = "PDFs that need a password are left as they are.";
pub const ENCRYPTION: &str = "PDFs whose encryption L’Esclop cannot write again are left as they are.";
pub const ENCRYPTED_LARGE: &str = "Encrypted PDFs over 64 MB are left as they are.";
pub const MEMORY: &str = "PDFs that would need more than 256 MB of memory are left as they are.";
pub const TOO_LARGE: &str = "PDFs over 1 GB are left as they are.";

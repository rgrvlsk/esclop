// SPDX-License-Identifier: MPL-2.0
//! Makes PDFs smaller without changing what they show.
//!
//! [`optimise`] takes the bytes of a PDF and gives back a smaller PDF, or says why it left the
//! file as it is. Fonts, text, annotations, forms, outlines, the structure tree and every other
//! object stay as they are; what changes is how streams are stored:
//!
//! - images are downsampled to [`OptionsBuilder::max_dpi`] when drawn denser, and stored as the
//!   smaller of a JPEG at the compression's quality ceiling and lossless Flate, but only where the
//!   result keeps a structural similarity (SSIM) to the original of at least 0.98 per page at
//!   default settings (0.95 aggressive), and at least 0.90 (0.85) for any single image, however
//!   little of its page it covers;
//! - JPEGs are re-encoded only when downsampled, or when a `max_dpi` is set and they were saved
//!   above the ceiling; otherwise they are recoded losslessly;
//! - embedded TrueType and CFF fonts keep only the glyphs the document draws, with glyph ids
//!   unchanged (fonts an interactive form types with stay whole);
//! - large inline images move into image XObjects, every other stream is recompressed, identical
//!   streams are stored once, unreachable objects are dropped, and objects go into object
//!   streams;
//! - with [`OptionsBuilder::strip_metadata`], the document information, XMP, page thumbnails and
//!   application data are removed.
//!
//! Encrypted files that open without a password are encrypted again with the same keys and
//! permissions. Signed, Reader-extended and password-protected files, and files the crate cannot
//! rewrite faithfully, are left as they are ([`Outcome::Kept`]); damaged files are an error
//! ([`ErrorKind::Damaged`]). Memory stays within [`OptionsBuilder::memory_budget`] besides the
//! file itself; see the README for the numbers.
//!
//! ```no_run
//! use esclop_pdf::{Options, Outcome};
//!
//! let input = std::fs::read("report.pdf")?;
//! let options = Options::builder().max_dpi(150).strip_metadata(true).build()?;
//! match esclop_pdf::optimise(input, &options)? {
//!     Outcome::Rewritten { bytes, report, .. } => {
//!         println!("{} -> {} bytes", report.bytes_before, report.bytes_after);
//!         std::fs::write("report-small.pdf", bytes)?;
//!     }
//!     Outcome::Kept { reason, .. } => println!("left as it is: {reason}"),
//!     _ => {}
//! }
//! # Ok::<(), Box<dyn std::error::Error>>(())
//! ```

#![cfg_attr(docsrs, feature(doc_cfg))]
#![warn(missing_docs)]

mod budget;
mod cff;
mod deflate;
mod error;
mod fonts;
mod images;
mod inline;
mod integrity;
mod jpeg;
mod mono;
mod placement;
mod rewrite;

#[cfg(feature = "fuzzing")]
#[doc(hidden)]
pub mod fuzzing;

pub use error::{Error, ErrorKind};

use std::fmt;

/// How to optimise. Build one with [`Options::builder`]; [`Options::default`] is compression 30
/// (the JPEG ceiling of quality 66 and the 0.98 page gate), no downsampling, metadata kept and a
/// 256 MB memory budget.
///
/// ```
/// use esclop_pdf::Options;
///
/// let options = Options::builder().aggressive().max_dpi(150).build()?;
/// assert_eq!(options.compression(), Options::AGGRESSIVE_COMPRESSION);
/// assert_eq!(options.max_dpi(), Some(150));
/// # Ok::<(), esclop_pdf::Error>(())
/// ```
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub struct Options {
    compression: u8,
    max_dpi: Option<u32>,
    strip_metadata: bool,
    memory_budget: usize,
}

impl Options {
    /// The default compression: JPEG quality ceiling 66 (libjpeg scale), page SSIM gate 0.98.
    pub const DEFAULT_COMPRESSION: u8 = 30;
    /// The aggressive compression: JPEG quality ceiling 58, page SSIM gate 0.95.
    pub const AGGRESSIVE_COMPRESSION: u8 = 64;
    /// The default memory budget, 256 MB.
    pub const DEFAULT_MEMORY_BUDGET: usize = 256 << 20;

    /// A builder starting from the defaults.
    pub fn builder() -> OptionsBuilder {
        OptionsBuilder { options: Self::default() }
    }

    /// 0 to 100. See [`OptionsBuilder::compression`].
    pub fn compression(&self) -> u8 {
        self.compression
    }

    /// The highest resolution images are kept at, in pixels per inch of the page; `None` keeps
    /// every image's resolution.
    pub fn max_dpi(&self) -> Option<u32> {
        self.max_dpi
    }

    /// Whether document metadata is removed.
    pub fn strip_metadata(&self) -> bool {
        self.strip_metadata
    }

    /// The memory budget, in bytes. See [`OptionsBuilder::memory_budget`].
    pub fn memory_budget(&self) -> usize {
        self.memory_budget
    }
}

impl Default for Options {
    fn default() -> Self {
        Self {
            compression: Self::DEFAULT_COMPRESSION,
            max_dpi: None,
            strip_metadata: false,
            memory_budget: Self::DEFAULT_MEMORY_BUDGET,
        }
    }
}

/// Builds [`Options`]; [`build`](Self::build) checks the ranges.
///
/// ```
/// let err = esclop_pdf::Options::builder().max_dpi(20).build().unwrap_err();
/// assert_eq!(err.kind(), esclop_pdf::ErrorKind::InvalidOptions);
/// ```
#[derive(Debug, Clone)]
#[must_use]
pub struct OptionsBuilder {
    options: Options,
}

impl OptionsBuilder {
    /// How hard images are compressed, 0 to 100. 0 leaves every image exactly as stored (only
    /// streams, fonts and metadata change). Above 0 it sets the JPEG quality ceiling (85 at 30,
    /// falling with the factor, and capped at 66, or lower when downsampling to 100 dpi or less),
    /// and over 40 the gentler aggressive fidelity gate (SSIM 0.95 per page, 0.85 per image,
    /// instead of 0.98 and 0.90).
    pub fn compression(mut self, factor: u8) -> Self {
        self.options.compression = factor;
        self
    }

    /// [`Options::AGGRESSIVE_COMPRESSION`].
    pub fn aggressive(self) -> Self {
        self.compression(Options::AGGRESSIVE_COMPRESSION)
    }

    /// Downsamples images drawn denser than `dpi` pixels per inch of the page, 48 to 300 (300
    /// keeps every image's resolution). An image is downsampled only as far as the fidelity gate
    /// allows.
    pub fn max_dpi(mut self, dpi: u32) -> Self {
        self.options.max_dpi = Some(dpi);
        self
    }

    /// Keeps every image's resolution (the default).
    pub fn keep_resolution(mut self) -> Self {
        self.options.max_dpi = None;
        self
    }

    /// Removes the document information dictionary, the catalog's XMP metadata, page thumbnails
    /// and application private data (`/PieceInfo`).
    pub fn strip_metadata(mut self, strip: bool) -> Self {
        self.options.strip_metadata = strip;
        self
    }

    /// What a rewrite may hold in memory besides the file itself: the objects it parses and the
    /// font programs it decodes. A file that needs more is left as it is
    /// ([`KeptReason::MemoryBudget`]). At least 16 MB.
    ///
    /// The peak is higher: the file's own streams are held once and decoded images are worked on
    /// a few at a time (up to 256 MB more). For a large file the peak is about twice its size,
    /// because the file is copied while it is parsed.
    pub fn memory_budget(mut self, bytes: usize) -> Self {
        self.options.memory_budget = bytes;
        self
    }

    /// The options, or [`ErrorKind::InvalidOptions`] when one is out of range.
    pub fn build(self) -> Result<Options, Error> {
        let o = self.options;
        if o.compression > 100 {
            return Err(Error::new(ErrorKind::InvalidOptions, "compression must be 0 to 100"));
        }
        if o.max_dpi.is_some_and(|d| !(48..=300).contains(&d)) {
            return Err(Error::new(ErrorKind::InvalidOptions, "max_dpi must be 48 to 300"));
        }
        if o.memory_budget < 16 << 20 {
            return Err(Error::new(ErrorKind::InvalidOptions, "memory_budget must be at least 16 MB"));
        }
        Ok(o)
    }
}

/// Follows a rewrite: progress, and whether to stop. Both methods have defaults, so an
/// implementation overrides only what it needs. Called from several threads at once.
///
/// ```
/// use std::sync::atomic::{AtomicBool, Ordering};
///
/// struct Stop(AtomicBool);
///
/// impl esclop_pdf::Observer for Stop {
///     fn is_cancelled(&self) -> bool {
///         self.0.load(Ordering::Relaxed)
///     }
/// }
///
/// let stop = Stop(AtomicBool::new(true));
/// let pdf = b"%PDF-1.7\n".to_vec();
/// let err = esclop_pdf::optimise_with(pdf, &esclop_pdf::Options::default(), &stop).unwrap_err();
/// assert_eq!(err.kind(), esclop_pdf::ErrorKind::Cancelled);
/// ```
pub trait Observer: Sync {
    /// `fraction` of the work is done (0 to 1, not decreasing), now in `stage`.
    fn progress(&self, fraction: f32, stage: Stage) {
        let _ = (fraction, stage);
    }

    /// Whether to stop: the rewrite then ends with [`ErrorKind::Cancelled`] soon after, between
    /// two small steps (a font, an image, a few thousand operators of page content).
    fn is_cancelled(&self) -> bool {
        false
    }
}

/// Observes nothing.
impl Observer for () {}

/// What a rewrite is doing, for [`Observer::progress`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum Stage {
    /// Reading and checking the file.
    Load,
    /// Finding the glyphs each font draws and subsetting the fonts.
    Fonts,
    /// Recompressing images and other streams.
    Compress,
    /// Writing the new file and reading it back.
    Write,
}

/// What [`optimise`] did.
#[derive(Debug, Clone, PartialEq)]
#[non_exhaustive]
pub enum Outcome {
    /// The file was rewritten. `bytes` may be larger than the input (rare, mostly for files that
    /// are already tight): compare [`Report::bytes_after`] with [`Report::bytes_before`] and keep
    /// the original if it is smaller.
    #[non_exhaustive]
    Rewritten {
        /// The new PDF.
        bytes: Vec<u8>,
        /// What was done.
        report: Report,
    },
    /// The file was left as it is, on purpose.
    #[non_exhaustive]
    Kept {
        /// Why.
        reason: KeptReason,
        /// The detail, in English, for logs; its wording may change between versions.
        detail: String,
    },
}

/// What a rewrite did.
#[derive(Debug, Clone, Default, PartialEq)]
#[non_exhaustive]
pub struct Report {
    /// The input's size.
    pub bytes_before: u64,
    /// The output's size.
    pub bytes_after: u64,
    /// Whether any image lost information (re-encoded as JPEG, or downsampled).
    pub lossy: bool,
    /// The JPEG quality ceiling images were encoded at (libjpeg scale), when any was.
    pub jpeg_quality: Option<u8>,
    /// Images stored anew (smaller), lossless or not.
    pub images_rewritten: usize,
    /// Of those, images whose pixels changed.
    pub images_changed: usize,
    /// Other streams recompressed (page content, fonts, ...).
    pub streams_recompressed: usize,
    /// Embedded fonts reduced to the glyphs the document draws.
    pub fonts_subset: usize,
    /// Inline images moved into image objects.
    pub inline_images_moved: usize,
    /// Whether metadata was removed.
    pub metadata_stripped: bool,
}

/// Why a file was left as it is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum KeptReason {
    /// It carries a digital signature, DocMDP permissions or Reader usage rights (`/Perms`):
    /// any rewrite would invalidate them.
    Signed,
    /// It cannot be opened without a password.
    PasswordRequired,
    /// It is encrypted in a way this crate cannot write again exactly (another security
    /// handler, per-stream crypt filters, crypt filters it cannot read).
    Encryption,
    /// It is encrypted and over 64 MB, or has more object streams than an encrypted file's
    /// shared parsing limit allows.
    EncryptedTooLarge,
    /// Rewriting it would need more than the [memory budget](OptionsBuilder::memory_budget).
    MemoryBudget,
    /// It is over 1 GB.
    InputTooLarge,
    /// The rewrite would be more than twice its size plus 64 MB.
    OutputTooLarge,
}

impl fmt::Display for KeptReason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Signed => "signed PDFs are left as they are, so their signatures stay valid",
            Self::PasswordRequired => "the PDF needs a password",
            Self::Encryption => "the PDF's encryption cannot be written again exactly",
            Self::EncryptedTooLarge => "encrypted PDFs over 64 MB are left as they are",
            Self::MemoryBudget => "rewriting the PDF would need more memory than the budget",
            Self::InputTooLarge => "PDFs over 1 GB are left as they are",
            Self::OutputTooLarge => "the rewritten PDF would be more than twice the size",
        })
    }
}

/// Optimises a PDF. The input is taken by value: once it is parsed it is dropped, so a large
/// file is not held twice for the whole rewrite.
///
/// ```
/// // A one-page PDF with an uncompressed content stream.
/// let pdf = b"%PDF-1.4
/// 1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
/// 2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
/// 3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R >> endobj
/// 4 0 obj << /Length 44 >> stream
/// 0 0 1 rg 10 10 180 180 re f 0 0 1 rg 10 10 180 180 re f
/// endstream endobj
/// trailer << /Root 1 0 R >>
/// %%EOF
/// ";
/// match esclop_pdf::optimise(pdf.to_vec(), &esclop_pdf::Options::default())? {
///     esclop_pdf::Outcome::Rewritten { report, .. } => assert!(report.bytes_after > 0),
///     other => panic!("{other:?}"),
/// }
/// # Ok::<(), esclop_pdf::Error>(())
/// ```
pub fn optimise(input: Vec<u8>, options: &Options) -> Result<Outcome, Error> {
    optimise_with(input, options, &())
}

/// [`optimise`], reporting to `observer` and stopping when it says so.
pub fn optimise_with(input: Vec<u8>, options: &Options, observer: &dyn Observer) -> Result<Outcome, Error> {
    let options = OptionsBuilder { options: options.clone() }.build()?;
    let ctx = Ctx { observer };
    let settings = rewrite::Settings::from_options(&options);
    match rewrite::rewrite(input, &settings, ctx) {
        Ok((bytes, report)) => Ok(Outcome::Rewritten { bytes, report }),
        Err(f) => match f.reason {
            Some(reason) => Ok(Outcome::Kept { reason, detail: f.message }),
            None => Err(f.into_error()),
        },
    }
}

/// The observer, as the stages see it.
#[derive(Clone, Copy)]
pub(crate) struct Ctx<'a> {
    observer: &'a dyn Observer,
}

impl<'a> Ctx<'a> {
    #[cfg(test)]
    pub fn new(observer: &'a dyn Observer) -> Self {
        Self { observer }
    }

    /// A context that never reports progress and is never cancelled.
    #[cfg(any(test, feature = "fuzzing"))]
    pub fn silent() -> Ctx<'static> {
        Ctx { observer: &() }
    }

    pub fn is_cancelled(&self) -> bool {
        self.observer.is_cancelled()
    }

    /// `cancelled` once the observer asks to stop.
    pub fn check(&self) -> error::Result<()> {
        if self.is_cancelled() { Err(error::Failure::cancelled()) } else { Ok(()) }
    }

    pub fn progress(&self, fraction: f32, stage: Stage) {
        self.observer.progress(fraction.clamp(0.0, 1.0), stage);
    }
}

/// The JPEG quality ceiling (libjpeg scale) for a compression factor: 85 at 30, falling to 18.
fn jpeg_max_quality(factor: u8) -> u8 {
    let clamp = |v: f64, lo: i64, hi: i64| (v.round() as i64).clamp(lo, hi);
    let f = factor as f64;
    if f <= 70.0 {
        clamp(85.0 - (f - 30.0) * (55.0 / 70.0), 25, 95) as u8
    } else {
        clamp(54.0 - (f - 70.0) * (36.0 / 30.0), 18, 95) as u8
    }
}

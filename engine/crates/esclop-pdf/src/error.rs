// SPDX-License-Identifier: MPL-2.0
//! The crate's one error type, and the internal `Failure` the stages report, which becomes an
//! [`Error`] or, when the file is deliberately left as it is, an [`Outcome::Kept`].
//!
//! [`Outcome::Kept`]: crate::Outcome::Kept

use crate::KeptReason;
use std::fmt;

/// What kind of failure an [`Error`] is.
///
/// ```
/// // A file whose page tree points at nothing cannot be rewritten faithfully.
/// let pdf = b"%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n";
/// let err = esclop_pdf::optimise(pdf.to_vec(), &esclop_pdf::Options::default()).unwrap_err();
/// assert_eq!(err.kind(), esclop_pdf::ErrorKind::Damaged);
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[non_exhaustive]
pub enum ErrorKind {
    /// The input does not start like a PDF (no `%PDF-` in its first kilobyte).
    NotPdf,
    /// The PDF cannot be read completely: a damaged cross-reference table, a stream cut short,
    /// a page that does not decode. A rewrite could silently lose content, so there is none.
    Damaged,
    /// [`Observer::is_cancelled`](crate::Observer::is_cancelled) returned `true`.
    Cancelled,
    /// An [`Options`](crate::Options) value is out of range.
    InvalidOptions,
    /// A bug: the rewritten file failed the crate's own checks (it must read back with every
    /// page, and encrypted files with the same keys). Please report it with the input.
    Internal,
}

/// Why [`optimise`](crate::optimise) failed. A file left as it is on purpose (signed,
/// password-protected...) is not an error: see [`Outcome::Kept`](crate::Outcome::Kept).
///
/// ```
/// let err = esclop_pdf::optimise(b"not a PDF".to_vec(), &esclop_pdf::Options::default()).unwrap_err();
/// assert_eq!(err.kind(), esclop_pdf::ErrorKind::NotPdf);
/// ```
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Error {
    kind: ErrorKind,
    message: String,
}

impl Error {
    pub(crate) fn new(kind: ErrorKind, message: impl Into<String>) -> Self {
        Self { kind, message: message.into() }
    }

    /// What kind of failure this is.
    pub fn kind(&self) -> ErrorKind {
        self.kind
    }

    /// The detail, in English, for logs; its wording may change between versions.
    pub fn message(&self) -> &str {
        &self.message
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for Error {}

/// What went wrong inside a stage.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Code {
    /// Not handled: with a `reason`, the file is left as it is on purpose.
    Unsupported,
    Decode,
    Encode,
    Internal,
    Cancelled,
    NotPdf,
}

/// A stage's failure: an [`Error`], or with `reason` a file left as it is.
#[derive(Debug, Clone)]
pub(crate) struct Failure {
    pub code: Code,
    pub message: String,
    pub reason: Option<KeptReason>,
}

pub(crate) type Result<T, E = Failure> = std::result::Result<T, E>;

impl Failure {
    pub fn new(code: Code, message: impl Into<String>) -> Self {
        Self { code, message: message.into(), reason: None }
    }
    pub fn unsupported(m: impl Into<String>) -> Self {
        Self::new(Code::Unsupported, m)
    }
    pub fn decode(m: impl Into<String>) -> Self {
        Self::new(Code::Decode, m)
    }
    pub fn encode(m: impl Into<String>) -> Self {
        Self::new(Code::Encode, m)
    }
    pub fn internal(m: impl Into<String>) -> Self {
        Self::new(Code::Internal, m)
    }
    pub fn cancelled() -> Self {
        Self::new(Code::Cancelled, "cancelled")
    }
    pub fn not_pdf() -> Self {
        Self::new(Code::NotPdf, "not a PDF")
    }
    /// The file is left as it is, for `reason`; `detail` is for logs.
    pub fn left_as_is(reason: KeptReason, detail: impl Into<String>) -> Self {
        Self { reason: Some(reason), ..Self::unsupported(detail) }
    }

    /// The public error (for a failure without a reason).
    pub fn into_error(self) -> Error {
        let kind = match self.code {
            Code::NotPdf => ErrorKind::NotPdf,
            Code::Decode => ErrorKind::Damaged,
            Code::Cancelled => ErrorKind::Cancelled,
            Code::Unsupported | Code::Encode | Code::Internal => ErrorKind::Internal,
        };
        Error::new(kind, self.message)
    }
}

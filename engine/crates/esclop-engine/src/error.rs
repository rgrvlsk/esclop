// SPDX-License-Identifier: GPL-3.0-or-later
//! Errors carry one of the protocol's error codes and a message meant for people and agents.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use std::fmt;

/// Error codes from `engine/PROTOCOL.md`. The set is closed: clients switch on it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    /// The input format, or this combination of input and op, is not handled by the engine.
    Unsupported,
    /// The input file (or the folder of the output) does not exist.
    NotFound,
    /// The input could not be decoded (corrupt or truncated file).
    Decode,
    /// An encoder failed.
    Encode,
    /// Reading or writing a file failed.
    Io,
    /// The result would not be smaller than the input; nothing was written.
    AlreadySmaller,
    /// The request or its params are malformed or out of range.
    InvalidParams,
    /// The request was cancelled before it finished; nothing was written.
    Cancelled,
    /// A bug in the engine (a caught panic, an impossible state).
    Internal,
}

#[derive(Debug, Clone)]
pub struct EngineError {
    pub code: ErrorCode,
    pub message: String,
}

pub type Result<T, E = EngineError> = std::result::Result<T, E>;

impl EngineError {
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self { code, message: message.into() }
    }
    pub fn unsupported(m: impl Into<String>) -> Self {
        Self::new(ErrorCode::Unsupported, m)
    }
    pub fn decode(m: impl Into<String>) -> Self {
        Self::new(ErrorCode::Decode, m)
    }
    pub fn encode(m: impl Into<String>) -> Self {
        Self::new(ErrorCode::Encode, m)
    }
    pub fn invalid(m: impl Into<String>) -> Self {
        Self::new(ErrorCode::InvalidParams, m)
    }
    pub fn internal(m: impl Into<String>) -> Self {
        Self::new(ErrorCode::Internal, m)
    }
    pub fn already_smaller(before: u64, after: u64) -> Self {
        Self::new(
            ErrorCode::AlreadySmaller,
            format!("the result ({after} bytes) is not smaller than the input ({before} bytes); nothing was written"),
        )
    }
    pub fn cancelled() -> Self {
        Self::new(ErrorCode::Cancelled, "cancelled")
    }
    /// An io error with the path it concerns.
    pub fn io(err: std::io::Error, path: &std::path::Path) -> Self {
        let code = if err.kind() == std::io::ErrorKind::NotFound { ErrorCode::NotFound } else { ErrorCode::Io };
        Self::new(code, format!("{}: {err}", path.display()))
    }
}

impl fmt::Display for EngineError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:?}: {}", self.code, self.message)
    }
}

impl std::error::Error for EngineError {}

impl From<image::ImageError> for EngineError {
    fn from(e: image::ImageError) -> Self {
        use image::ImageError as E;
        match e {
            E::Unsupported(u) => Self::unsupported(u.to_string()),
            E::Limits(l) => Self::unsupported(format!("image too large: {l}")),
            E::IoError(io) => Self::new(ErrorCode::Io, io.to_string()),
            other => Self::decode(other.to_string()),
        }
    }
}

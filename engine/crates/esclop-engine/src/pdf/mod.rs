// SPDX-License-Identifier: GPL-3.0-or-later
//! `pdf.optimise`: the protocol's side of the esclop-pdf crate. Parameters become
//! `esclop_pdf::Options`, the request's context an `Observer`, and the outcome a result or an
//! error with the `reason` the app shows.

pub mod reasons;

use crate::ctx::Ctx;
use crate::error::{EngineError, Result};
use crate::ops::{Encoded, compression, finish, open, parse_params};
use crate::protocol::{Format, OpResult, PdfParams, Request};
use esclop_pdf::{ErrorKind, Observer, Options, Outcome, Stage};

pub fn optimise(req: &Request, ctx: &Ctx) -> Result<OpResult> {
    let (p, ignored) = parse_params::<PdfParams>(&req.params)?;
    let factor = compression(p.compression)?;
    let mut options = Options::builder().compression(factor).strip_metadata(p.out.strip);
    match p.dpi {
        None | Some(0) => {}
        Some(d) if (48..=300).contains(&d) => options = options.max_dpi(d),
        Some(_) => return Err(EngineError::invalid("`dpi` must be 0 or 48..=300")),
    }
    let options = options.build().map_err(|e| EngineError::invalid(e.to_string()))?;
    let (bytes, target) = open(req, &p.out)?;
    let before = bytes.len() as u64;
    let outcome = esclop_pdf::optimise_with(bytes, &options, &Observed(ctx)).map_err(|e| match e.kind() {
        ErrorKind::Damaged => EngineError::decode(e.to_string()),
        ErrorKind::Cancelled => EngineError::cancelled(),
        ErrorKind::NotPdf => EngineError::unsupported("not a PDF"),
        ErrorKind::InvalidOptions => EngineError::invalid(e.to_string()),
        _ => EngineError::internal(e.to_string()),
    })?;
    match outcome {
        Outcome::Rewritten { bytes, report, .. } => {
            let enc = Encoded {
                bytes,
                format: Some(Format::Pdf),
                quality: report.jpeg_quality,
                lossy: report.lossy,
                ..Default::default()
            };
            finish(&target, before, enc, p.out.allow_larger.unwrap_or(false), ignored, ctx)
        }
        Outcome::Kept { reason, detail, .. } => Err(match reasons::sentence(reason) {
            Some(sentence) => EngineError::left_as_is(sentence, detail),
            None => EngineError::unsupported(detail),
        }),
        _ => Err(EngineError::internal("esclop-pdf returned an outcome this engine does not know")),
    }
}

/// The request's cancel flag and progress, for esclop-pdf.
struct Observed<'a>(&'a Ctx);

impl Observer for Observed<'_> {
    fn progress(&self, fraction: f32, stage: Stage) {
        let name = match stage {
            Stage::Load => "decode",
            Stage::Fonts => "fonts",
            Stage::Compress => "compress",
            Stage::Write => "write",
            _ => "work",
        };
        self.0.progress(fraction, name);
    }

    fn is_cancelled(&self) -> bool {
        self.0.is_cancelled()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorCode;

    #[test]
    fn a_reason_reaches_the_reply() {
        let r = crate::error_response(serde_json::json!("1"), EngineError::left_as_is(reasons::SIGNED, "signed"));
        let line = serde_json::to_value(&r).unwrap();
        assert_eq!(line["error"]["reason"], reasons::SIGNED);
        assert_eq!(line["error"]["code"], "unsupported");
        let plain =
            serde_json::to_value(crate::error_response(serde_json::json!("1"), EngineError::unsupported("x"))).unwrap();
        assert!(plain["error"].get("reason").is_none());
    }

    #[test]
    fn every_reason_the_app_shows_has_a_sentence() {
        use esclop_pdf::KeptReason as K;
        for k in
            [K::Signed, K::PasswordRequired, K::Encryption, K::EncryptedTooLarge, K::MemoryBudget, K::InputTooLarge]
        {
            assert!(reasons::sentence(k).is_some(), "{k:?}");
        }
        assert_eq!(reasons::sentence(K::OutputTooLarge), None);
        let _ = ErrorCode::Unsupported;
    }
}

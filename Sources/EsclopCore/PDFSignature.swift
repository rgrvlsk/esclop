// SPDX-License-Identifier: GPL-3.0-or-later
//
// Whether a PDF carries a signature, for the PDFKit writes (crop, uncrop) that run outside
// esclop-engine. It mirrors the engine's own refusal (engine/crates/esclop-engine/src/pdf/mod.rs,
// `is_signed`): a catalog `/Perms` (DocMDP, Reader usage rights) or a signature value with a
// `/ByteRange`. Rewriting such a file moves the bytes the signature covers and breaks it.

import CoreGraphics
import Foundation

public enum PDFSignature {
    /// The engine's reason, word for word, so the app shows the same translated sentence.
    public static let reason = "Signed PDFs are left as they are, so their signatures stay valid."

    /// Throws `leftAsIs` when `url` is signed.
    public static func refuseSigned(_ url: URL) throws {
        if isSigned(url) { throw EsclopError.leftAsIs(reason) }
    }

    /// A `/ByteRange` anywhere in the file's bytes (signature dictionaries are written
    /// uncompressed so a signer can fill them in), or, for one kept in an object stream, a
    /// non-empty catalog `/Perms` or a form field whose value has a `/ByteRange`.
    public static func isSigned(_ url: URL) -> Bool {
        if let bytes = try? Data(contentsOf: url, options: .alwaysMapped), bytes.range(of: Data("/ByteRange".utf8)) != nil {
            return true
        }
        // The catalog belongs to the document: keep the document alive while it is read.
        guard let document = CGPDFDocument(url as CFURL), let catalog = document.catalog else { return false }
        defer { withExtendedLifetime(document) {} }
        var perms: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Perms", &perms), let perms, CGPDFDictionaryGetCount(perms) > 0 {
            return true
        }
        var form: CGPDFDictionaryRef?
        var fields: CGPDFArrayRef?
        guard CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form), let form,
              CGPDFDictionaryGetArray(form, "Fields", &fields), let fields
        else { return false }
        return hasSignedField(fields, depth: 0)
    }

    private static func hasSignedField(_ fields: CGPDFArrayRef, depth: Int) -> Bool {
        guard depth < 32 else { return false }
        for index in 0 ..< CGPDFArrayGetCount(fields) {
            var field: CGPDFDictionaryRef?
            guard CGPDFArrayGetDictionary(fields, index, &field), let field else { continue }
            var value: CGPDFDictionaryRef?
            var range: CGPDFArrayRef?
            if CGPDFDictionaryGetDictionary(field, "V", &value), let value, CGPDFDictionaryGetArray(value, "ByteRange", &range) {
                return true
            }
            var kids: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(field, "Kids", &kids), let kids, hasSignedField(kids, depth: depth + 1) {
                return true
            }
        }
        return false
    }
}

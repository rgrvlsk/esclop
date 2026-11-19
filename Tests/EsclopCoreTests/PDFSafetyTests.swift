// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import EsclopCore

/// A one-page PDF built from `catalog`, optional `annots` on the page and `extra` objects
/// (numbered from 6), with a correct cross-reference table.
func handMadePDF(at url: URL, catalog: String = "", annots: String = "", extra: [String] = []) throws {
    let content = "BT /F1 24 Tf 72 700 Td (Hello) Tj ET"
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R \(catalog) >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> \(annots) >>",
        "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ] + extra
    var text = "%PDF-1.7\n"
    var offsets: [Int] = []
    for (index, object) in objects.enumerated() {
        offsets.append(text.utf8.count)
        text += "\(index + 1) 0 obj\n\(object)\nendobj\n"
    }
    let xref = text.utf8.count
    text += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
    for offset in offsets { text += String(format: "%010d 00000 n \n", offset) }
    text += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
    try Data(text.utf8).write(to: url)
}

@Suite struct PDFSignatureTests {
    static let widget = "<< /Type /Annot /Subtype /Widget /FT /Sig /T (Sig1) /Rect [0 0 0 0] /P 3 0 R"

    @Test(arguments: [
        // A signature value in the bytes.
        ("signed", "/AcroForm << /Fields [6 0 R] /SigFlags 3 >>", "/Annots [6 0 R]",
         ["\(widget) /V 7 0 R >>", "<< /Type /Sig /Filter /Adobe.PPKLite /ByteRange [0 100 200 300] /Contents <00> >>"], true),
        // The same name spelt with a # escape: only the field walk sees it.
        ("escaped", "/AcroForm << /Fields [6 0 R] >>", "/Annots [6 0 R]",
         ["\(widget) /V 7 0 R >>", "<< /Type /Sig /Byte#52ange [0 1 2 3] /Contents <00> >>"], true),
        // Reader usage rights alone.
        ("rights", "/Perms << /UR3 6 0 R >>", "", ["<< /Type /Sig /Filter /Adobe.PPKLite /Contents <00> >>"], true),
        // A signature field nobody has signed yet.
        ("empty", "/AcroForm << /Fields [6 0 R] >>", "/Annots [6 0 R]", ["\(widget) >>"], false),
        ("plain", "", "", [], false),
    ])
    func signedMeansAValueOrPermissions(name: String, catalog: String, annots: String, extra: [String], signed: Bool) throws {
        let url = try scratchFolder().appendingPathComponent("\(name).pdf")
        try handMadePDF(at: url, catalog: catalog, annots: annots, extra: extra)
        #expect(PDFSignature.isSigned(url) == signed, "\(name)")
    }
}

@Suite struct StagedFilesTests {
    @Test func takenNamesAreKept() throws {
        let folder = try scratchFolder()
        try Data("keep".utf8).write(to: folder.appendingPathComponent("doc-1.png"))
        let written = try StagedFiles.publish(["doc-1.png", "doc-2.png"], into: folder) { index, url in
            try Data("page \(index + 1)".utf8).write(to: url)
        }
        #expect(written.map(\.lastPathComponent) == ["doc-1 2.png", "doc-2.png"])
        #expect(try String(contentsOf: folder.appendingPathComponent("doc-1.png"), encoding: .utf8) == "keep")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["doc-1 2.png", "doc-1.png", "doc-2.png"])
    }

    @Test func aFailureLeavesNothing() throws {
        let folder = try scratchFolder()
        #expect(throws: EsclopError.self) {
            try StagedFiles.publish(["doc-1.png", "doc-2.png", "doc-3.png"], into: folder) { index, url in
                // Page 2 is never written; page 3 is never reached.
                if index != 1 { try Data("page".utf8).write(to: url) }
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
}

// SPDX-License-Identifier: GPL-3.0-or-later
//
// The real engine takes the pipeline steps the contract does not cover. The conformance lives
// here because EsclopOptimisers sits below EsclopPipelines and cannot see this protocol.

import EsclopCore
import EsclopOptimisers
import Foundation

extension EsclopEngine: PipelineMediaOperations {
    public func watermark(
        _ source: URL, image: URL, position: WatermarkPosition, opacity: Double, scale: Double,
        request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void
    ) async throws -> OptimisationResult {
        try await watermark(
            source, image: image, position: WatermarkCorner(rawValue: position.rawValue) ?? .bottomRight,
            opacity: opacity, scale: scale, request: request, progress: progress
        )
    }

    public func extractPages(
        _ source: URL, format: PageImageFormat, scale: Double, into directory: URL,
        request: OptimisationRequest, progress: @Sendable (OptimisationProgress) -> Void
    ) async throws -> [URL] {
        try await extractPDFPages(source, format: format == .jpeg ? .jpeg : .png, dpi: Int((72 * scale).rounded()), to: directory)
    }
}

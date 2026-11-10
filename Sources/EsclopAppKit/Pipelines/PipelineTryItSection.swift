// SPDX-License-Identifier: GPL-3.0-or-later
//
// "Try it": drop or choose a file and run the pipeline as the form has it on a copy, with each
// step's outcome and the final saving. The original is only read.

import AppKit
import EsclopCore
import EsclopPipelines
import SwiftUI
import UniformTypeIdentifiers

struct PipelineTryItSection: View {
    @Bindable var model: PipelineEditorModel
    @State private var isTargeted = false

    var body: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "testtube.2").foregroundStyle(Palette.accent).accessibilityHidden(true)
                Text(Strings.text("Drop a file here, or choose one. The pipeline runs on a copy; your file stays as it is."))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(Strings.text("Choose a File…")) { choose() }
                    .accessibilityLabel(Strings.text("Choose a file to try the pipeline on"))
                    .disabled(!model.check.isValid || isRunning)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(isTargeted ? Palette.accent : .clear, lineWidth: 2))
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: \.isFileURL), model.check.isValid else { return false }
                Task { await model.tryIt(on: url) }
                return true
            } isTargeted: { isTargeted = $0 }
            switch model.tryState {
            case .idle:
                EmptyView()
            case let .running(name):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(Strings.format("Trying it on “%@”…", name))
                }
            case let .done(result):
                PipelineTryResultView(result: result)
            }
        } header: {
            Text(Strings.text("Try It"))
        }
    }

    private var isRunning: Bool { if case .running = model.tryState { return true } else { return false } }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.prompt = Strings.text("Try It")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.tryIt(on: url) }
    }
}

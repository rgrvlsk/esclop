// SPDX-License-Identifier: GPL-3.0-or-later
//
// Prototype of the windows: batch, Settings, the first run, the pipeline editor and compare.
// Stock chrome and controls; the proposal is in what they say and how they are grouped.

import AppKit
@testable import EsclopAppKit
import SwiftUI

// MARK: - Batch

struct ProtoBatch: View {
    var running = false

    private let rows: [(String, String, String?, NSImage, Bool)] = [
        ("Beach 01.jpg", "4.8 MB → 1.2 MB", "−75 %", ProtoSamples.photo, false),
        ("Beach 02.jpg", "5.1 MB → 1.4 MB", "−73 %", ProtoSamples.photo, true),
        ("Harbour.heic", "3.2 MB → 2 MB", "−39 %", ProtoSamples.poster, false),
        ("Menu scan.pdf", "13 MB → 3.1 MB", "−76 %", ProtoSamples.page, false),
        ("Map.png", "Already small · 180 kB", nil, ProtoSamples.chart, false),
        ("Sunset walk.mov", "Not a video L’Esclop can read", nil, ProtoSamples.photo, false),
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("−71 %").font(Proto.figure(34)).foregroundStyle(Proto.saving)
                    Text("29 MB → 8.4 MB").font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer()
                    if running {
                        Text("7 of 9").font(.system(size: 13)).foregroundStyle(.secondary)
                        ProgressView().controlSize(.small)
                    } else {
                        Button { } label: { Label("1 failed", systemImage: "exclamationmark.triangle.fill") }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Proto.error)
                    }
                }
                .monospacedDigit()
                ProtoSplitBar(kept: 0.29, height: 8)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 16)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 12) {
                            Image(nsImage: row.3).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.0).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(row.1).font(.system(size: 11)).foregroundStyle(index == 5 ? AnyShapeStyle(Proto.error) : AnyShapeStyle(.secondary))
                            }
                            Spacer()
                            if row.4 {
                                // Hover: the actions arrive beside the figure; the figure stays.
                                HStack(spacing: 2) {
                                    ProtoIconButton(symbol: "arrow.uturn.backward", name: "Undo")
                                    ProtoIconButton(symbol: "rectangle.split.2x1", name: "Compare")
                                    ProtoIconButton(symbol: "folder", name: "Show in Finder")
                                }
                            }
                            if let saving = row.2 {
                                Text(saving).font(.system(size: 15, weight: .medium, design: .rounded)).frame(width: 58, alignment: .trailing)
                            } else if index == 5 {
                                Button("Retry") {}.controlSize(.small)
                            }
                        }
                        .monospacedDigit()
                        .padding(.horizontal, 20)
                        .frame(height: 56)
                        .background(row.4 ? Color.primary.opacity(0.05) : .clear)
                        if index < rows.count - 1 { Divider().padding(.leading, 72) }
                    }
                }
            }
        }
        .frame(width: 560, height: 480)
        .toolbar {
            ToolbarItemGroup {
                if running {
                    Button("Pause", systemImage: "pause.fill") {}
                    Button("Stop", systemImage: "stop.fill") {}
                }
                Button("Undo All", systemImage: "arrow.uturn.backward") {}
                Button("Show in Finder", systemImage: "folder") {}
            }
        }
    }
}

// MARK: - Settings

struct ProtoSettings: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general = "General", automatic = "Automatic", quality = "Quality", results = "Results"
        case uploads = "Uploads", agents = "Agents", advanced = "Advanced"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .automatic: return "wand.and.sparkles"
            case .quality: return "slider.horizontal.3"
            case .results: return "rectangle.on.rectangle"
            case .uploads: return "icloud.and.arrow.up"
            case .agents: return "sparkle"
            case .advanced: return "wrench.and.screwdriver"
            }
        }
    }

    @State var pane: Pane? = .general
    @State private var on = true
    @State private var off = false
    @State private var level = 1
    @State private var place = 0

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { pane in
                Label(pane.rawValue, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(190)
            .searchable(text: .constant(""), placement: .sidebar, prompt: "Search")
        } detail: {
            Group {
                switch pane {
                case .quality: quality
                case .automatic: automatic
                default: general
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pane?.rawValue ?? "")
        }
        .frame(width: 760, height: 560)
    }

    private var general: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $on)
            }
            Section("Where files go") {
                Picker("Optimised files", selection: $place) {
                    Text("Replace the original").tag(0)
                    Text("Next to the original").tag(1)
                    Text("A folder…").tag(2)
                }
                Text("The original is kept for 7 days and can be put back from the menu.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Picker("Converted files", selection: .constant(1)) {
                    Text("Replace the original").tag(0)
                    Text("Next to the original").tag(1)
                }
                LabeledContent("Different for video, PDF or audio") { Button("Set…") {} }
            }
            Section("Every file") {
                Toggle("Remove metadata", isOn: $on)
                Toggle("Keep file dates", isOn: $on)
                Toggle("Keep HDR", isOn: $on)
            }
            Section("Shortcuts") {
                LabeledContent("Pause") { ProtoKeys(keys: ["⌃", "⇧", "P"]) }
                LabeledContent("Optimise the clipboard") { ProtoKeys(keys: ["⌃", "⇧", "C"]) }
                LabeledContent("Optimise it aggressively") { ProtoKeys(keys: ["⌃", "⇧", "A"]) }
                LabeledContent("Go to the newest result") { ProtoKeys(keys: ["⌃", "⇧", "R"]) }
            }
        }
    }

    private var automatic: some View {
        Form {
            Section("When you copy") {
                Toggle("Images", isOn: $on)
                Toggle("Videos", isOn: $off)
                Toggle("PDFs", isOn: $off)
                Toggle("Audio", isOn: $off)
            }
            Section("Folders") {
                LabeledContent("~/Desktop") { Text("Images").foregroundStyle(.secondary) }
                LabeledContent("~/Movies/Recordings") { Text("Videos").foregroundStyle(.secondary) }
                Button("Add a Folder…") {}
            }
            Section("Rules") {
                LabeledContent("Screenshots") { Text("WebP, adaptive").foregroundStyle(.secondary) }
                LabeledContent("Photos from Photos") { Text("JPEG, no location").foregroundStyle(.secondary) }
            }
        }
    }

    private var quality: some View {
        Form {
            Section {
                ForEach(["Images", "Video", "PDF", "Audio"], id: \.self) { kind in
                    Picker(kind, selection: $level) {
                        Text("Light").tag(0)
                        Text("Balanced").tag(1)
                        Text("Strong").tag(2)
                    }
                    .pickerStyle(.segmented)
                }
            } header: {
                Text("Normal")
            } footer: {
                Text("Balanced is visually lossless. Strong makes smaller files with loss you can find if you look.")
            }
            Section("Aggressive") {
                Picker("Images", selection: .constant(2)) {
                    Text("Light").tag(0)
                    Text("Balanced").tag(1)
                    Text("Strong").tag(2)
                }
                .pickerStyle(.segmented)
                LabeledContent("Always aggressive for") { Text("PNG, GIF").foregroundStyle(.secondary) }
            }
            Section {
                LabeledContent("Exact numbers") { Button("Fine-tune…") {} }
            }
        }
    }
}

// MARK: - First run

struct ProtoOnboarding: View {
    enum Step { case tryIt, tried, menuBar }
    var step: Step = .tryIt

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            switch step {
            case .tryIt, .tried: stage
            case .menuBar: menuBar
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Button("Skip") {}.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0 ..< 3, id: \.self) { index in
                        Capsule().fill(Color.primary.opacity(index == dot ? 0.7 : 0.18)).frame(width: index == dot ? 16 : 6, height: 6)
                    }
                }
                Spacer()
                Button(step == .menuBar ? "Done" : "Continue") {}
                    .buttonStyle(.borderedProminent)
                    .disabled(step == .tryIt)
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
        }
        .frame(width: 600, height: 480)
    }

    private var dot: Int { step == .menuBar ? 2 : 0 }

    private var stage: some View {
        VStack(spacing: 18) {
            Text(step == .tried ? "That is all it does" : "Copy a screenshot")
                .font(.system(size: 28, weight: .semibold))
            if step == .tryIt {
                HStack(spacing: 8) {
                    Text("Press")
                    ProtoKeys(keys: ["⌃", "⇧", "⌘", "4"])
                    Text("and drag over anything.")
                }
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            } else {
                Text("It was smaller before you could paste it. The original is kept for 7 days.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.05))
                if step == .tried {
                    HStack(spacing: 22) {
                        Image(nsImage: ProtoSamples.screenshot).resizable().aspectRatio(contentMode: .fit)
                            .frame(height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("−75 %").font(Proto.figure(44)).foregroundStyle(Proto.saving)
                            Text("2.4 MB → 612 kB").font(.system(size: 13)).foregroundStyle(.secondary)
                            ProtoSplitBar(kept: 0.25).frame(width: 150)
                        }
                        .monospacedDigit()
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "camera.viewfinder").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                        Text("Waiting for a screenshot").font(.system(size: 13)).foregroundStyle(.secondary)
                        Button("Use a Sample Instead") {}.controlSize(.small)
                    }
                }
            }
            .frame(width: 440, height: 180)
        }
        .padding(.horizontal, 40)
    }

    private var menuBar: some View {
        VStack(spacing: 18) {
            if let glyph = MenuBarLabel.customGlyph {
                Image(nsImage: glyph).renderingMode(.template).resizable().aspectRatio(contentMode: .fit).frame(width: 64)
            }
            Text("It lives in the menu bar").font(.system(size: 28, weight: .semibold))
            Text("Results, undo and pause are there. These work from anywhere:")
                .font(.system(size: 14)).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow { ProtoKeys(keys: ["⌃", "⇧", "C"]); Text("Optimise the clipboard") }
                GridRow { ProtoKeys(keys: ["⌃", "⇧", "P"]); Text("Pause") }
                GridRow { ProtoKeys(keys: ["⌃", "⇧", "R"]); Text("Go to the newest result") }
            }
            .font(.system(size: 13))
            Button("Connect an AI Agent…") {}.buttonStyle(.link).font(.system(size: 13))
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - Pipeline editor

struct ProtoPipeline: View {
    private let steps: [(String, String, String, String?)] = [
        ("crop", "Crop", "Long edge 1600 px", nil),
        ("arrow.triangle.2.circlepath", "Convert", "To WebP", nil),
        ("arrow.down.to.line", "Fit under", "−5 MB", "A size has to be more than zero."),
        ("icloud.and.arrow.up", "Upload", "To R2, copy the link", nil),
    ]

    var body: some View {
        NavigationSplitView {
            List(selection: .constant("Blog screenshots")) {
                Section("Yours") {
                    Label("Blog screenshots", systemImage: "photo").tag("Blog screenshots")
                    Label("Archive PDFs", systemImage: "doc").tag("Archive PDFs")
                }
                Section("Examples") {
                    ForEach(["To WebP", "Sort screenshots", "Under 1 MB", "Video to GIF", "PDF for sending"], id: \.self) { name in
                        Label(name, systemImage: "square.on.square.dashed").tag(name)
                    }
                }
            }
            .navigationSplitViewColumnWidth(200)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Blog screenshots").font(.system(size: 22, weight: .semibold))
                        Text("Screenshots for the blog").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Text("Runs for").font(.system(size: 13)).foregroundStyle(.secondary)
                        chip("PNG screenshots", "line.3.horizontal.decrease")
                        Text("when").font(.system(size: 13)).foregroundStyle(.secondary)
                        chip("copied", "doc.on.clipboard")
                        chip("dropped on its zone", "arrow.down.to.line")
                        Image(systemName: "plus.circle").foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(spacing: 0) {
                                    Image(systemName: step.0)
                                        .font(.system(size: 13, weight: .medium))
                                        .frame(width: 30, height: 30)
                                        .background(Circle().fill(Color.primary.opacity(0.08)))
                                    if index < steps.count - 1 {
                                        Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1.5).frame(maxHeight: .infinity)
                                    }
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(step.1).font(.system(size: 13, weight: .semibold))
                                    Text(step.2).font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                                    if let problem = step.3 {
                                        Label(problem, systemImage: "exclamationmark.circle.fill")
                                            .font(.system(size: 12)).foregroundStyle(Proto.error).padding(.top, 2)
                                    }
                                }
                                .padding(.top, 5)
                                .padding(.bottom, 18)
                                Spacer()
                                if index == 1 {
                                    Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).padding(.top, 8)
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 12) {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 30, height: 30)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.2)))
                            Text("Add a step").font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toolbar {
                ToolbarItemGroup {
                    Picker("View", selection: .constant(0)) {
                        Text("Steps").tag(0)
                        Text("Text").tag(1)
                    }
                    .pickerStyle(.segmented)
                    Button("Try It…", systemImage: "play.fill") {}.labelStyle(.titleAndIcon)
                }
            }
        }
        .frame(width: 820, height: 560)
    }

    private func chip(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

// MARK: - Compare

struct ProtoCompare: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ProtoChecker()
                Image(nsImage: ProtoSamples.photo).resizable().aspectRatio(contentMode: .fit).padding(28)
                Rectangle().fill(.white).frame(width: 1.5).shadow(color: .black.opacity(0.4), radius: 1.5)
                Image(systemName: "chevron.left.chevron.right")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(Color(white: 0.2))
                    .frame(width: 24, height: 32).background(Capsule().fill(.white))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            }
            Divider()
            HStack {
                Text("Original").foregroundStyle(.secondary) + Text("  PNG · 4.8 MB")
                Spacer()
                Text("−75 %").font(Proto.figure(15)).foregroundStyle(Proto.saving)
                Spacer()
                Text("JPEG · 1.2 MB  ") + Text("Optimised").foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .monospacedDigit()
            .padding(.horizontal, 16)
            .frame(height: 34)
        }
        .frame(width: 820, height: 560)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Layout", selection: .constant(0)) {
                    Text("Split").tag(0)
                    Text("Side by Side").tag(1)
                    Text("Flip").tag(2)
                }
                .pickerStyle(.segmented)
            }
            ToolbarItemGroup {
                Button("Differences", systemImage: "square.2.layers.3d") {}
                Button("Zoom to Fit", systemImage: "arrow.up.left.and.arrow.down.right") {}
                Menu("Try Another", systemImage: "wand.and.sparkles") { Text("WebP") }
                Button("Undo", systemImage: "arrow.uturn.backward") {}
            }
        }
    }
}

/// Transparency, in the appearance's own greys.
struct ProtoChecker: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 12
            let (a, b) = scheme == .dark ? (Color(white: 0.13), Color(white: 0.16)) : (Color(white: 0.93), Color(white: 0.97))
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(a))
            for row in 0 ..< Int(size.height / cell) + 1 {
                for column in 0 ..< Int(size.width / cell) + 1 where (row + column) % 2 == 0 {
                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)), with: .color(b))
                }
            }
        }
    }
}

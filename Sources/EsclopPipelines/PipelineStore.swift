// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pipelines on disk: one `<name>.pipeline` text file each, in `Paths.pipelines`, so people can
// edit them in any editor and agents can write them.

import EsclopCore
import Foundation

/// A file in the store, valid or not. Invalid files are listed so the UI can show what is wrong.
public struct PipelineStoreEntry: Sendable {
    public var name: String
    public var url: URL
    /// Nil when the file has errors.
    public var pipeline: Pipeline?
    public var diagnostics: [PipelineDiagnostic]
}

public struct PipelineStore: Sendable {
    public static let fileExtension = "pipeline"

    public let directory: URL
    /// `delete` moves files to the Trash when true, removes them when false (tests, temp stores).
    public let useTrash: Bool

    public init(directory: URL = Paths.pipelines, useTrash: Bool = true) {
        self.directory = directory
        self.useTrash = useTrash
    }

    // MARK: Reading

    /// Every `.pipeline` file, sorted by name. Files with errors are included with their diagnostics.
    public func entries() throws -> [PipelineStoreEntry] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == Self.fileExtension }
        return files.map { url in
            let name = url.deletingPathExtension().lastPathComponent
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                return PipelineStoreEntry(name: name, url: url, pipeline: nil, diagnostics: [PipelineDiagnostic(line: 1, column: 1, "The file is not UTF-8 text.")])
            }
            let result = PipelineParser.check(text, name: name)
            return PipelineStoreEntry(name: name, url: url, pipeline: result.pipeline, diagnostics: result.diagnostics)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The valid pipelines.
    public func list() throws -> [Pipeline] {
        try entries().compactMap(\.pipeline)
    }

    /// Loads by name, ignoring case. Throws `PipelineSyntaxError` when the file has errors.
    public func load(_ name: String) throws -> Pipeline {
        let url = try existingURL(for: name)
        let text = try String(contentsOf: url, encoding: .utf8)
        return try PipelineParser.parse(text, name: url.deletingPathExtension().lastPathComponent)
    }

    /// The file's text as written, comments included.
    public func text(of name: String) throws -> String {
        try String(contentsOf: existingURL(for: name), encoding: .utf8)
    }

    public func contains(_ name: String) -> Bool {
        (try? existingURL(for: name)) != nil
    }

    /// Pipelines with this trigger, e.g. everything attached to the clipboard.
    public func pipelines(triggeredBy trigger: PipelineTrigger) throws -> [Pipeline] {
        try list().filter { p in p.triggers.contains { Self.same(trigger, $0) } }
    }

    // MARK: Writing

    /// Writes the pipeline as canonical text. Comments in an existing file are not kept; use
    /// `save(text:name:)` to keep a person's formatting.
    @discardableResult
    public func save(_ pipeline: Pipeline, overwrite: Bool = true) throws -> URL {
        try write(pipeline.text, name: pipeline.name, overwrite: overwrite)
    }

    /// Validates and writes text exactly as given. Throws `PipelineSyntaxError` without writing
    /// anything when the text has errors.
    @discardableResult
    public func save(text: String, name: String, overwrite: Bool = true) throws -> Pipeline {
        let pipeline = try PipelineParser.parse(text, name: name)
        _ = try write(text.hasSuffix("\n") ? text : text + "\n", name: name, overwrite: overwrite)
        return pipeline
    }

    /// Moves the file to the Trash when there is one, so a deleted pipeline can be recovered.
    public func delete(_ name: String) throws {
        let url = try existingURL(for: name)
        if useTrash, (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil { return }
        try FileManager.default.removeItem(at: url)
    }

    public func rename(_ name: String, to newName: String) throws {
        try Self.validate(name: newName)
        let url = try existingURL(for: name)
        let dest = fileURL(for: newName)
        let sameFile = url.lastPathComponent.lowercased() == dest.lastPathComponent.lowercased()
        if !sameFile, contains(newName) {
            throw EsclopError.invalidArgument("a pipeline named “\(newName)” already exists")
        }
        try FileManager.default.moveItem(at: url, to: dest)
    }

    /// Adds a trigger to a saved pipeline. Adding one it already has does nothing.
    public func attach(_ trigger: PipelineTrigger, to name: String) throws {
        var pipeline = try load(name)
        guard !pipeline.triggers.contains(where: { Self.same(trigger, $0) }) else { return }
        pipeline.triggers.append(trigger)
        try save(pipeline)
    }

    /// Removes a trigger. Returns false when the pipeline did not have it.
    @discardableResult
    public func detach(_ trigger: PipelineTrigger, from name: String) throws -> Bool {
        var pipeline = try load(name)
        let before = pipeline.triggers.count
        pipeline.triggers.removeAll { Self.same(trigger, $0) }
        guard pipeline.triggers.count != before else { return false }
        try save(pipeline)
        return true
    }

    /// Copies a built-in preset into the store so it can be edited and attached.
    @discardableResult
    public func install(preset name: String, overwrite: Bool = false) throws -> Pipeline {
        guard let preset = Self.preset(named: name) else {
            throw EsclopError.invalidArgument("no preset named “\(name)”; presets: " + Self.presets.map(\.name).joined(separator: ", "))
        }
        try save(preset, overwrite: overwrite)
        return preset
    }

    // MARK: Resolving what a person or agent typed

    /// A saved pipeline by name, then a preset by name, then the text as inline steps. This is
    /// how the CLI and MCP read a `pipeline` argument.
    public func resolve(_ nameOrSteps: String) throws -> Pipeline {
        let trimmed = nameOrSteps.trimmingCharacters(in: .whitespacesAndNewlines)
        if contains(trimmed) { return try load(trimmed) }
        if let preset = Self.preset(named: trimmed) { return preset }
        return try PipelineParser.parse(trimmed)
    }

    // MARK: Names and paths

    public func fileURL(for name: String) -> URL {
        directory.appendingPathComponent(name).appendingPathExtension(Self.fileExtension)
    }

    /// Names become file names: no `/` or `:`, no leading dot, not empty, at most 200 characters.
    public static func validate(name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EsclopError.invalidArgument("a pipeline needs a name") }
        guard trimmed == name else { throw EsclopError.invalidArgument("pipeline names cannot start or end with spaces") }
        guard !name.contains("/"), !name.contains(":"), !name.hasPrefix("."), name.count <= 200, !name.contains(where: \.isNewline) else {
            throw EsclopError.invalidArgument("“\(name)” cannot be a pipeline name: avoid “/”, “:”, new lines and a leading “.”")
        }
    }

    func existingURL(for name: String) throws -> URL {
        let exact = fileURL(for: name)
        if FileManager.default.fileExists(atPath: exact.path) {
            // The file system may be case-insensitive: report the name as stored.
            if let match = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first(where: { $0.lastPathComponent.lowercased() == exact.lastPathComponent.lowercased() })
            {
                return match
            }
            return exact
        }
        let wanted = "\(name).\(Self.fileExtension)".lowercased()
        if let match = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first(where: { $0.lastPathComponent.lowercased() == wanted })
        {
            return match
        }
        throw EsclopError.invalidArgument("no pipeline named “\(name)”")
    }

    func write(_ text: String, name: String, overwrite: Bool) throws -> URL {
        try Self.validate(name: name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !overwrite, contains(name) {
            throw EsclopError.invalidArgument("a pipeline named “\(name)” already exists")
        }
        let url = (try? existingURL(for: name)) ?? fileURL(for: name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Folder triggers match when their paths point at the same folder (`~` or not, trailing `/` or not).
    static func same(_ a: PipelineTrigger, _ b: PipelineTrigger) -> Bool {
        guard case let .folder(x) = a, case let .folder(y) = b else { return a == b }
        func norm(_ p: String) -> String { URL(fileURLWithPath: TemplateContext.expandHome(p)).standardizedFileURL.path }
        return norm(x) == norm(y)
    }
}

// MARK: - Presets

extension PipelineStore {
    /// Built-in pipelines. They live in code rather than a resource bundle so the `esclop` binary
    /// keeps them when it is copied out of the app (SwiftPM's `Bundle.module` would trap there).
    public static let presets: [Pipeline] = presetTexts.map { name, text in
        do {
            return try PipelineParser.parse(text, name: name)
        } catch {
            preconditionFailure("built-in preset “\(name)” does not parse: \(error)")
        }
    }

    /// A preset by name, ignoring case.
    public static func preset(named name: String) -> Pipeline? {
        presets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    static let presetTexts: [(String, String)] = [
        ("to WebP", """
        ---
        description: Convert images to WebP, next to the original
        icon: photo
        ---
        [image]
        convert(to: webp)
        """),
        ("sort screenshots", #"""
        ---
        description: Optimise screenshots and file them by year and month in ~/Pictures/Screenshots
        icon: folder
        ---
        [image]
        if(regex: "^(screen\s?shot|cleanshot)") -> optimise -> move(to: "~/Pictures/Screenshots/%y/%m/")
        """#),
        ("fit under 1 MB", """
        ---
        description: Shrink any file until it is under 1 MB, for forms and chat apps with upload limits
        icon: arrow.down.circle
        ---
        targetSize(size: 1MB)
        """),
        ("video to GIF", """
        ---
        description: Turn a video into an animated GIF at most 800 px on its long side, next to the original
        icon: photo.on.rectangle.angled
        ---
        [video]
        crop(longEdge: 800) -> convert(to: gif)
        """),
        ("pdf for sending", """
        ---
        description: Downsample a PDF to 150 dpi for reading on screen and keep it under 10 MB for email
        icon: paperplane
        ---
        [pdf]
        optimise(dpi: 150) -> targetSize(size: 10MB)
        """),
    ]
}

// SPDX-License-Identifier: GPL-3.0-or-later
//
// MCP resources (recent results, settings, pipelines) and prompts (write a pipeline, shrink for a
// destination).

import EsclopCore
import EsclopIPC
import EsclopPipelines
import Foundation
import MCP

enum MCPResources {
    static let recentURI = "esclop://results/recent"
    static let settingsURI = "esclop://settings"
    static let pipelinePrefix = "esclop://pipelines/"

    static func list(service: EsclopService) -> [Resource] {
        var resources = [
            Resource(name: "recent-results", uri: recentURI, title: "Recent results", description: "The last 50 optimisation results, newest first, as JSON.", mimeType: "application/json"),
            Resource(name: "settings", uri: settingsURI, title: "Settings", description: "Every esclop setting with its current value and schema, as JSON.", mimeType: "application/json"),
        ]
        for entry in (try? service.context.pipelines.entries()) ?? [] {
            let info = PipelineInfo(entry: entry)
            resources.append(Resource(
                name: "pipeline-\(entry.name)", uri: pipelineURI(entry.name), title: "Pipeline \(entry.name)",
                description: info.valid ? info.summary : "Has errors", mimeType: "text/plain"
            ))
        }
        return resources
    }

    static let templates = [
        Resource.Template(
            uriTemplate: "esclop://pipelines/{name}", name: "pipeline", title: "Saved pipeline",
            description: "The DSL source of a saved pipeline.", mimeType: "text/plain"
        ),
    ]

    static func pipelineURI(_ name: String) -> String {
        pipelinePrefix + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? name)
    }

    static func read(_ uri: String, service: EsclopService) async throws -> [Resource.Content] {
        switch uri {
        case recentURI:
            let results = await service.recentResults(limit: 50).map(ResultSummary.init)
            return [.text(JSONCoding.presentationString(results), uri: uri, mimeType: "application/json")]
        case settingsURI:
            let settings = try await service.settingsSchema(query: nil).map(ToolCatalog.settingJSON)
            return [.text(JSONValue.array(settings).jsonString(pretty: true), uri: uri, mimeType: "application/json")]
        default:
            guard uri.hasPrefix(pipelinePrefix) else { throw MCPError.serverError(code: -32002, message: "Resource not found: \(uri)") }
            let encoded = String(uri.dropFirst(pipelinePrefix.count))
            let name = encoded.removingPercentEncoding ?? encoded
            guard let text = (try? service.context.pipelines.text(of: name)) ?? PipelineStore.preset(named: name)?.text else {
                throw MCPError.serverError(code: -32002, message: "No pipeline named \(name)")
            }
            return [.text(text, uri: uri, mimeType: "text/plain")]
        }
    }
}

enum MCPPrompts {
    static let all = [
        Prompt(
            name: "write_pipeline", title: "Write a pipeline",
            description: "Turn a goal (\"every screenshot becomes a 1600px WebP\") into L'Esclop pipeline steps and save it.",
            arguments: [
                .init(name: "goal", title: "Goal", description: "What the pipeline should do, in plain words.", required: true),
                .init(name: "fileType", title: "File type", description: "image, video, pdf or audio, if it only applies to one.", required: false),
                .init(name: "name", title: "Name", description: "A name to save it under.", required: false),
            ]
        ),
        Prompt(
            name: "shrink_for", title: "Shrink for a destination",
            description: "Make files fit where they are going: email, Slack, the web, or App Store screenshots.",
            arguments: [
                .init(name: "platform", title: "Destination", description: "email, slack, web or app-store", required: true),
                .init(name: "paths", title: "Files", description: "Files or folders, comma-separated.", required: false),
            ]
        ),
    ]

    /// Generated from the parser's step catalog.
    static var dslReference: String { PipelineLanguage.referenceMarkdown() }

    static func get(_ name: String, arguments: [String: String]) throws -> GetPrompt.Result {
        switch name {
        case "write_pipeline":
            guard let goal = arguments["goal"], !goal.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw MCPError.invalidParams("write_pipeline needs goal: what the pipeline should do")
            }
            let scope = arguments["fileType"].map { " It applies to \($0) files." } ?? ""
            let saveAs = arguments["name"].map { "Save it as \"\($0)\"" } ?? "Pick a short, descriptive name and save it"
            let text = """
            Write an L'Esclop pipeline for this goal: \(goal)\(scope)

            \(dslReference)

            Prefer built-in steps over runScript; say which built-in step you tried before reaching for a script.
            Reply with the pipeline in one code block and a sentence on what each step does. Then \(saveAs.prefix(1).lowercased() + saveAs.dropFirst()) \
            with the esclop_pipeline_write tool (name, steps). If it comes back as invalidPipeline, fix what the line and column \
            point at and call again. If the goal implies running automatically (on the clipboard, a folder or the drop zone), \
            ask the person before calling esclop_pipeline_attach. Built-in presets (esclop_pipeline_list) may already do it.
            """
            return GetPrompt.Result(description: "Write an L'Esclop pipeline", messages: [.user(.text(text: text))])

        case "shrink_for":
            guard let platform = arguments["platform"]?.lowercased().trimmingCharacters(in: .whitespaces), !platform.isEmpty else {
                throw MCPError.invalidParams("shrink_for needs platform: email, slack, web or app-store")
            }
            guard let guidance = targets[platform.replacingOccurrences(of: " ", with: "-")] else {
                throw MCPError.invalidParams("platform is one of \(targets.keys.sorted().joined(separator: ", "))")
            }
            let files = arguments["paths"].map { "Files: \($0)." } ?? "Ask which files to prepare if the conversation does not say."
            let text = """
            Prepare files for \(platform) with L'Esclop's tools. \(files)

            \(guidance)

            Check each file's size and kind first if you can. Call the tools on all files at once, report the before → after \
            sizes and output paths from the results, and leave the originals alone unless the person asked to replace them.
            """
            return GetPrompt.Result(description: "Shrink files for \(platform)", messages: [.user(.text(text: text))])

        default:
            throw MCPError.invalidParams("Unknown prompt \(name). Prompts: write_pipeline, shrink_for")
        }
    }

    static let targets: [String: String] = [
        "email": """
        Email: most providers cap a whole message at 20-25 MB, and attachments over a few MB are unkind to read on a phone.
        - Photos and screenshots: esclop_downscale so the long edge is about 2000 px (or esclop_crop with longEdge 2000), then esclop_optimise. JPEG for photos (esclop_convert format jpeg), PNG stays PNG for screenshots with text.
        - Several files: esclop_fit_under_size with maxSize so the total stays under 20MB (for example 2MB each for up to 10 files).
        - Videos: esclop_fit_under_size maxSize 20MB, or suggest a link instead when even that is too much.
        - PDFs: esclop_optimise (pdfDPI 150 keeps text sharp).
        """,
        "slack": """
        Slack: previews look best at up to about 2000 px; GIFs over a few MB do not autoplay well.
        - Images: esclop_crop with longEdge 2048, then esclop_optimise. Keep PNG for UI screenshots, JPEG for photos.
        - Animated GIF: esclop_convert to mp4 (much smaller, still plays inline) unless a GIF is required, then esclop_fit_under_size 5MB.
        - Screen recordings: esclop_optimise with downscale 0.5 for Retina recordings; removeAudio when it is silent.
        """,
        "web": """
        Web: aim for under 200 KB per content image and under 500 KB for a hero image.
        - Images: esclop_convert to webp (or avif for the smallest files), with esclop_crop longEdge 1920 for full-width images or 1200 for content images. stripMetadata true.
        - Keep a 2x variant only when the layout needs it: downscale the 2x by 0.5 for the 1x file.
        - Video backgrounds: esclop_convert to mp4 with removeAudio true, then esclop_fit_under_size 3MB.
        """,
        "app-store": """
        App Store screenshots must have exact pixel sizes, so never downscale them.
        - iPhone 6.9": 1320x2868 (or 1290x2796); iPad 13": 2064x2752 (or 2048x2732). Landscape swaps the numbers.
        - Use esclop_crop with width and height set to the exact size only when a screenshot is slightly off, and smart false.
        - App Store Connect takes JPEG or PNG without transparency: esclop_convert to jpeg flattens transparency; PNG screenshots stay lossless with esclop_optimise.
        - stripMetadata true before uploading.
        """,
    ]
}

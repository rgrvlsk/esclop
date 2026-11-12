// SPDX-License-Identifier: GPL-3.0-or-later
//
// The wire protocol between the CLI / MCP server and the running app.
//
// Transport: CFMessagePort, one-way messages carrying JSON. The app listens on four well-known
// ports, one per concern, so a settings call can never be mistaken for an optimisation request:
//
//   dev.esclop.app.request    OptimisationJob         -> optimise / convert / crop / pipeline ...
//   dev.esclop.app.stop       StopRequest             -> cancel jobs by id
//   dev.esclop.app.settings   SettingsCall            -> schema / get / set
//   dev.esclop.app.control    ControlCommand          -> status / recent results / quit
//
// Every message names a reply port the client opened for itself (`dev.esclop.app.reply.<uuid>`).
// The app streams `AppEvent`s there: `accepted`, then `progress` and one `result` or `failure` per
// file, then `finished`; or a single `settings`/`status`/`results`/`done`/`refused` answer.
// Replies are per client, so several CLIs and MCP servers can talk to the app at once.

import EsclopCore
import Foundation

public enum IPCProtocol {
    /// Bumped on any incompatible change to the envelopes below.
    public static let version = 1
    /// `msgid` on every CFMessagePort message. The payload says what it is.
    public static let messageID: Int32 = 0x45_53_43_31 // "ESC1"
}

/// Port names. The prefix is the bundle identifier; tests use a unique prefix so they never talk
/// to a real app.
public struct IPCPorts: Sendable, Hashable {
    public var prefix: String

    public init(prefix: String = Paths.bundleIdentifier) {
        self.prefix = prefix
    }

    public static let `default` = IPCPorts()

    public var request: String { "\(prefix).request" }
    public var stop: String { "\(prefix).stop" }
    public var settings: String { "\(prefix).settings" }
    public var control: String { "\(prefix).control" }
    /// Where the app sends progress and responses for one exchange.
    public func reply(_ id: UUID) -> String { "\(prefix).reply.\(id.uuidString)" }
}

// MARK: - Envelope

public struct IPCEnvelope<Body: Codable & Sendable>: Codable, Sendable {
    public var version: Int
    /// Correlates a request with its replies.
    public var id: UUID
    /// The port the sender listens on for replies. nil on replies themselves.
    public var replyPort: String?
    public var body: Body

    public init(id: UUID = UUID(), replyPort: String? = nil, body: Body) {
        self.version = IPCProtocol.version
        self.id = id
        self.replyPort = replyPort
        self.body = body
    }

    public func encoded() throws -> Data { try JSONCoding.wireEncoder().encode(self) }

    public static func decode(_ data: Data) throws -> IPCEnvelope<Body> {
        let envelope = try JSONCoding.wireDecoder().decode(IPCEnvelope<Body>.self, from: data)
        guard envelope.version == IPCProtocol.version else {
            throw EsclopError.other("IPC version mismatch: got \(envelope.version), expected \(IPCProtocol.version). Update the esclop CLI and app together.")
        }
        return envelope
    }
}

// MARK: - Jobs

/// What to do with the files. The request carries the files and modifiers (quality, location,
/// downscale...); the operation picks the engine entry point.
public enum JobOperation: Codable, Hashable, Sendable {
    case optimise
    case convert(OutputFormat)
    case downscale(Double)
    case crop(CropSize)
    case fit(underBytes: Int)
    case stripMetadata
    /// A saved pipeline name, or inline DSL.
    case pipeline(String)
    /// Non-destructive PDF crop: sets each page's crop box.
    case cropPDF(PDFCropSpec)
    /// Removes a crop box set by `cropPDF`.
    case uncropPDF
    /// Uploads the file to an upload target (by name; nil: the default one) and returns its link.
    /// Only the app can: the credentials are in its Keychain.
    case upload(target: String?)

    public var name: String {
        switch self {
        case .optimise: return "optimise"
        case .convert: return "convert"
        case .downscale: return "downscale"
        case .crop: return "crop"
        case .fit: return "fit"
        case .stripMetadata: return "strip"
        case .pipeline: return "pipeline"
        case .cropPDF: return "crop-pdf"
        case .uncropPDF: return "uncrop-pdf"
        case .upload: return "upload"
        }
    }
}

public struct PDFCropSpec: Codable, Hashable, Sendable {
    /// Width divided by height of the target, for example 0.75 for 3:4.
    public var aspectRatio: Double
    /// Pad with blank paper instead of clipping.
    public var extend: Bool
    /// Rotate the ratio to match each page's orientation.
    public var matchOrientation: Bool

    public init(aspectRatio: Double, extend: Bool = false, matchOrientation: Bool = true) {
        self.aspectRatio = aspectRatio
        self.extend = extend
        self.matchOrientation = matchOrientation
    }
}

public struct OptimisationJob: Codable, Sendable, Identifiable {
    public var request: OptimisationRequest
    public var operation: JobOperation
    public var id: UUID { request.id }

    public init(request: OptimisationRequest, operation: JobOperation) {
        self.request = request
        self.operation = operation
    }
}

public struct StopRequest: Codable, Sendable, Hashable {
    public var ids: [UUID]
    /// Also remove the result cards from the floating UI.
    public var remove: Bool

    public init(ids: [UUID], remove: Bool = false) {
        self.ids = ids
        self.remove = remove
    }
}

/// One file that could not be processed.
public struct FileFailure: Codable, Sendable, Equatable {
    public var source: URL
    public var error: EsclopError

    public init(source: URL, error: EsclopError) {
        self.source = source
        self.error = error
    }
}

/// What the app (or the in-process executor) reports while a job runs.
public enum JobEvent: Codable, Sendable {
    case progress(OptimisationProgress)
    case result(OptimisationResult)
    case failure(FileFailure)
}

/// Everything a job produced.
public struct JobReport: Codable, Sendable {
    public var results: [OptimisationResult]
    public var failures: [FileFailure]
    /// `app` when the running app did the work, `in-process` otherwise.
    public var route: String

    public init(results: [OptimisationResult] = [], failures: [FileFailure] = [], route: String = "in-process") {
        self.results = results
        self.failures = failures
        self.route = route
    }
}

// MARK: - Settings

public enum SettingsCommand: Codable, Sendable, Hashable {
    case schema(query: String?)
    case get(key: String)
    case set(key: String, value: String)
}

public struct SettingsCall: Codable, Sendable {
    public var command: SettingsCommand
    /// The app refuses writes from `.mcp` unless the person allowed them.
    public var origin: RequestOrigin

    public init(command: SettingsCommand, origin: RequestOrigin) {
        self.command = command
        self.origin = origin
    }
}

public enum SettingsReply: Codable, Sendable {
    case descriptors([SettingDescriptor])
    case value(key: String, value: JSONValue)
}

// MARK: - Control

public enum ControlCommand: Codable, Sendable, Hashable {
    case status
    case recentResults(limit: Int)
    case quit
}

public struct AppStatus: Codable, Sendable, Hashable {
    public var version: String
    public var pid: Int32
    public var activeJobs: Int

    public init(version: String, pid: Int32, activeJobs: Int) {
        self.version = version
        self.pid = pid
        self.activeJobs = activeJobs
    }
}

// MARK: - Replies

public enum AppEvent: Codable, Sendable {
    case accepted
    case progress(OptimisationProgress)
    case result(OptimisationResult)
    case failure(FileFailure)
    case finished
    case settings(SettingsReply)
    case status(AppStatus)
    case results([OptimisationResult])
    case done
    case refused(EsclopError)

    public init(_ event: JobEvent) {
        switch event {
        case let .progress(p): self = .progress(p)
        case let .result(r): self = .result(r)
        case let .failure(f): self = .failure(f)
        }
    }
}

public enum EsclopVersion {
    public static let string = "0.1.1"

    /// Where the corresponding source lives (GPL/AGPL: the MCP server and About expose it). Set by
    /// the bundle script as `EsclopSourceURL` in Info.plist; nil in a development build.
    public static var sourceURL: String? {
        (Bundle.main.object(forInfoDictionaryKey: "EsclopSourceURL") as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? ProcessInfo.processInfo.environment["ESCLOP_SOURCE_URL"]
    }
}

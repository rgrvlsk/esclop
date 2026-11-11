// SPDX-License-Identifier: GPL-3.0-or-later
//
// The permission gate for requests from AI agents. Lives here, next to the protocol, because both
// sides apply it: the MCP server before it starts any work, and the app on every request it
// receives, since the app is the place an agent cannot route around.

import EsclopCore
import Foundation

// MARK: - Permission gate

/// What an agent may do. Applies to requests whose origin is `.mcp`; everything else passes. The
/// app runs the same checks on requests it receives, since it is the place an agent cannot route
/// around; the MCP server runs them first so a refusal comes back before any work starts.
public struct AgentPolicy: Sendable {
    public var origin: RequestOrigin
    public var permissions: any AgentPermissionReading

    public init(origin: RequestOrigin, permissions: any AgentPermissionReading) {
        self.origin = origin
        self.permissions = permissions
    }

    public var applies: Bool { origin == .mcp }

    public func allowed(_ permission: AgentPermission) -> Bool {
        !applies || permissions.isAllowed(permission)
    }

    /// The location an agent's request gets when it does not say: in place when overwriting is
    /// allowed (a backup is kept), next to the original otherwise.
    public var defaultLocation: OutputLocation {
        allowed(.allowOverwriteOriginals) ? .inPlace : .sameFolder
    }

    public func check(_ job: OptimisationJob, pipelineUsesScripts: Bool = false, pipelineUploads: Bool = false) throws {
        guard applies else { return }
        if case .upload = job.operation {
            // An upload writes nothing on disk: only its own switch applies.
            guard permissions.isAllowed(.allowUploads) else { throw refusal(.allowUploads, "Uploading files is off for agents") }
            return
        }
        if pipelineUploads, !permissions.isAllowed(.allowUploads) {
            throw refusal(.allowUploads, "This pipeline has an upload step, and uploading files is off for agents")
        }
        if job.request.location == .inPlace, !permissions.isAllowed(.allowOverwriteOriginals) {
            throw refusal(.allowOverwriteOriginals, "Overwriting originals is off for agents. Leave location out (or pass \"sameFolder\") to write next to the original")
        }
        if !permissions.isAllowed(.allowOverwriteOriginals) {
            // An output path is no way around the switch: it may not land on a file that exists,
            // nor on the same file for two sources.
            var planned = Set<String>()
            for source in job.request.sources {
                guard let target = OutputPlanner.plannedFile(for: source, location: job.request.location, operation: job.operation) else { break }
                if FileManager.default.fileExists(atPath: target.path) {
                    throw refusal(.allowOverwriteOriginals, "The output \(target.path) already exists, and overwriting files is off for agents. Pick a new name or folder")
                }
                guard planned.insert(target.resolvingSymlinksInPath().path).inserted else {
                    throw refusal(.allowOverwriteOriginals, "Several files would be written to \(target.path). Use a folder (ending in /) or a template with %f")
                }
            }
        }
        if pipelineUsesScripts, !permissions.isAllowed(.allowRunScripts) {
            throw refusal(.allowRunScripts, "This pipeline has a runScript or runShortcut step, and script steps are off for agents")
        }
    }

    public func checkSettingsChange(_ descriptor: SettingDescriptor) throws {
        guard applies else { return }
        guard descriptor.agentWritable else {
            throw EsclopError.notPermitted("\(descriptor.key) can only be changed by the person, in L'Esclop Settings → Agents and MCP (esclop://settings/agents/\(descriptor.key)). Agents can read it")
        }
        if !permissions.isAllowed(.allowSettingsChanges) {
            throw refusal(.allowSettingsChanges, "Changing settings is off for agents")
        }
    }

    public func checkPipelineWrite(replacing: Bool, usesScripts: Bool) throws {
        guard applies else { return }
        if usesScripts, !permissions.isAllowed(.allowRunScripts) {
            throw refusal(.allowRunScripts, "This pipeline has a runScript or runShortcut step, and script steps are off for agents. Use built-in steps instead")
        }
        if replacing, !permissions.isAllowed(.allowSettingsChanges) {
            throw refusal(.allowSettingsChanges, "Replacing an existing pipeline is off for agents. Save it under a new name instead")
        }
    }

    /// `automatic`: the pipeline has triggers that run it on their own (clipboard, folders...).
    public func checkPipelineDelete(automatic: Bool) throws {
        guard applies, automatic, !permissions.isAllowed(.allowSettingsChanges) else { return }
        throw refusal(.allowSettingsChanges, "This pipeline runs on its own (it has triggers), and changing automations is off for agents")
    }

    public func checkAutomationChange() throws {
        guard applies, !permissions.isAllowed(.allowSettingsChanges) else { return }
        throw refusal(.allowSettingsChanges, "Attaching pipelines to triggers and editing preset zones is off for agents")
    }

    public func checkRestore(deleteBackup: Bool) throws {
        guard applies else { return }
        if !permissions.isAllowed(.allowOverwriteOriginals) {
            throw refusal(.allowOverwriteOriginals, "Restoring a backup replaces the current file, and overwriting is off for agents")
        }
        if deleteBackup, !permissions.isAllowed(.allowDeleteBackups) {
            throw refusal(.allowDeleteBackups, "Deleting backups is off for agents. Restore without deleteBackup")
        }
    }

    private func refusal(_ permission: AgentPermission, _ why: String) -> EsclopError {
        // The switch's name as the Settings window shows it.
        let title = SettingsRegistry.shared.setting(permission.rawValue)?.title ?? permission.title
        return .notPermitted("\(why). The person can allow it with “\(title)” in L'Esclop Settings → Agents and MCP (setting \(permission.rawValue), link esclop://settings/agents/\(permission.rawValue)); ask them rather than working around it.")
    }
}

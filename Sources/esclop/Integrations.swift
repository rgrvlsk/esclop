// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shared engine, settings and pipeline store for the CLI and MCP server.

import EsclopCore
import EsclopIPC
import EsclopMCP
import EsclopOptimisers
import EsclopPipelines
import Foundation

enum EngineResolver {
    static func resolve() -> any OptimisationEngine {
        EsclopEngine()
    }

    static var name: String { "EsclopEngine" }
}

enum Integrations {
    static func context(origin: RequestOrigin, inProcess: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) -> ServiceContext {
        let locations = EsclopLocations.current(environment: environment)
        return ServiceContext(
            origin: origin,
            engine: EngineResolver.resolve(),
            engineName: EngineResolver.name,
            settings: RegistrySettingsProvider(),
            pipelines: PipelineStore(directory: locations.pipelines, useTrash: environment["ESCLOP_SUPPORT_DIR"] == nil),
            locations: locations,
            app: AppClient(),
            useApp: !inProcess && environment["ESCLOP_NO_APP"] != "1"
        )
    }
}

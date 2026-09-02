import Foundation
import FoundationModels

public extension ToolInfo {
    /// Snapshot of a tool's metadata. The schema is `GenerationSchema` encoded as JSON (it is `Codable`).
    init(_ tool: some Tool) {
        // GenerationSchema encodes its keys in nondeterministic order; sort them so identical tools
        // always produce identical JSON (equality, de-duplication, exports).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(tool.parameters)).flatMap { String(data: $0, encoding: .utf8) }
        self.init(name: tool.name, description: tool.description, parametersJSON: json,
                  includesSchemaInInstructions: tool.includesSchemaInInstructions)
    }
}

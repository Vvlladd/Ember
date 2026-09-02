import Foundation
import FoundationModels

public extension ToolInfo {
    /// Snapshot of a tool's metadata. The schema is `GenerationSchema` encoded as JSON (it is `Codable`).
    init(_ tool: some Tool) {
        let json = (try? JSONEncoder().encode(tool.parameters)).flatMap { String(data: $0, encoding: .utf8) }
        self.init(name: tool.name, description: tool.description, parametersJSON: json,
                  includesSchemaInInstructions: tool.includesSchemaInInstructions)
    }
}

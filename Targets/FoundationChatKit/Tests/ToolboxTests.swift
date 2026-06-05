import Testing
@testable import FoundationChatKit

struct ToolboxTests {
    @Test func defaultSetHasThreeUniquelyNamedTools() {
        let tools = Toolbox.defaultTools()
        #expect(tools.count == 3)
        let names = Set(tools.map(\.name))
        #expect(names == ["currentDateTime", "calculator", "unitConverter"])
    }
    @Test func accountingMetadataMirrorsTools() {
        let tools = Toolbox.defaultTools()
        let meta = Toolbox.accountingMetadata(for: tools)
        #expect(meta.count == 3)
        #expect(meta.allSatisfy { !$0.schemaDigest.isEmpty })
        #expect(meta.map(\.name) == tools.map(\.name))
    }
}

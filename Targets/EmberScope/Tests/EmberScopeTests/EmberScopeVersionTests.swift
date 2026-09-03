import Testing
@testable import EmberScope

struct EmberScopeVersionTests {
    @Test func versionIsSemver() {
        let parts = EmberScopeVersion.current.split(separator: ".")
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { Int($0) != nil })
    }
}

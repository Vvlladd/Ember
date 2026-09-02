import Testing
@testable import EmberScope

struct ScopeConfigurationTests {
    @Test func defaultsMatchSpec() {
        let c = ScopeConfiguration()
        #expect(c.maxEvents == 2_000)
        #expect(c.maxSessions == 50)
        #expect(c.captureContent)
        #expect(c.logToOSLog)
        #expect(!c.logContent)
        #expect(c.streamProgressInterval == .milliseconds(250))
    }

    @Test func enabledFollowsBuildConfigurationByDefault() {
        #if DEBUG
        #expect(ScopeConfiguration.defaultIsEnabled)
        #expect(ScopeConfiguration().isEnabled)
        #else
        #expect(!ScopeConfiguration.defaultIsEnabled)
        #endif
    }

    @Test func explicitEnableOverridesDefault() {
        #expect(ScopeConfiguration(isEnabled: true).isEnabled)
        #expect(!ScopeConfiguration(isEnabled: false).isEnabled)
    }
}

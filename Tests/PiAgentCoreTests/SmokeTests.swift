import Testing
@testable import PiAgentCore

struct SmokeTests {
    @Test func upstreamVersionIsPinned() {
        #expect(PiAgentCoreInfo.piUpstreamVersion == "0.85.1")
    }
}

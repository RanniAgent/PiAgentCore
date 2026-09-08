import Testing
@testable import PiAgentHarness

struct PlaceholderTests {
    @Test func targetBuilds() { #expect(PiAgentHarnessInfo.placeholder) }
}

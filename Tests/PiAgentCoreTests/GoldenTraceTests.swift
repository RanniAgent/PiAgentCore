import Foundation
import Testing
@testable import PiAgentCore
@testable import PiAgentTestSupport

struct GoldenTraceTests {
    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

    static var scenarioNames: [String] {
        let dir = fixtures.appendingPathComponent("scenarios")
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .sorted()
    }

    @Test(arguments: scenarioNames)
    func replayMatchesDesktopTrace(name: String) async throws {
        let scenario = try Scenario.load(from: Self.fixtures.appendingPathComponent("scenarios/\(name).json"))
        let expected = try JSONDecoder().decode(TraceDocument.self, from: Data(contentsOf: Self.fixtures.appendingPathComponent("traces/\(name).json")))
        #expect(expected.piVersion == PiAgentCoreInfo.piUpstreamVersion, "金标准来自 pi \(expected.piVersion)，包对齐的是 \(PiAgentCoreInfo.piUpstreamVersion)，先同步再比")

        let actual = try await ScenarioRunner.run(scenario)
        if actual.events != expected.events {
            let firstDiff = zip(actual.events, expected.events).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(actual.events.count, expected.events.count)
            let mine = firstDiff < actual.events.count ? (try? actual.events[firstDiff].serialized()) ?? "" : "<缺>"
            let theirs = firstDiff < expected.events.count ? (try? expected.events[firstDiff].serialized()) ?? "" : "<缺>"
            Issue.record("\(name): 第 \(firstDiff) 条事件不一致\nSwift:   \(mine)\n桌面端: \(theirs)\n（Swift \(actual.events.count) 条，桌面端 \(expected.events.count) 条）")
        }
    }
}

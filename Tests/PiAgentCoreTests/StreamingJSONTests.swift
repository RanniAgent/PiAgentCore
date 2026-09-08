import Testing
@testable import PiAgentCore

struct StreamingJSONTests {
    @Test func repairEscapesRawControlCharactersInsideStrings() {
        let broken = "{\"a\":\"line1\nline2\"}"
        #expect(StreamingJSON.repair(broken) == "{\"a\":\"line1\\nline2\"}")
    }

    @Test func repairDoublesBackslashesBeforeInvalidEscapes() {
        #expect(StreamingJSON.repair(#"{"p":"C:\Users\x"}"#) == #"{"p":"C:\\Users\\x"}"#)
        #expect(StreamingJSON.repair(#"{"p":"a\nb"}"#) == #"{"p":"a\nb"}"#)      // 合法转义不动
        #expect(StreamingJSON.repair(#"{"u":"\u00e9"}"#) == #"{"u":"\u00e9"}"#)  // 合法 \u 不动
        #expect(StreamingJSON.repair(#"{"u":"\u00"}"#) == #"{"u":"\\u00"}"#)      // 残缺 \u 加倍
    }

    @Test func repairLeavesTextOutsideStringsAlone() {
        #expect(StreamingJSON.repair("{\"a\":1,\n\"b\":2}") == "{\"a\":1,\n\"b\":2}")
    }

    @Test func parseWithRepairFallsBackOnlyWhenRepairChangesSomething() throws {
        #expect(try StreamingJSON.parseWithRepair("{\"a\":\"x\ny\"}") == ["a": "x\ny"])
        #expect(throws: (any Error).self) { _ = try StreamingJSON.parseWithRepair("{\"a\":") }
    }

    @Test func parseStreamingReturnsBestEffortObjects() {
        #expect(StreamingJSON.parseStreaming("") == [:])
        #expect(StreamingJSON.parseStreaming("   ") == [:])
        #expect(StreamingJSON.parseStreaming(#"{"command":"ls -la"}"#) == ["command": "ls -la"])
        #expect(StreamingJSON.parseStreaming(#"{"command":"ls -l"#) == ["command": "ls -l"])
        #expect(StreamingJSON.parseStreaming(#"{"command":"ls","timeout_ms":12"#) == ["command": "ls", "timeout_ms": 12])
        #expect(StreamingJSON.parseStreaming(#"{"items":[1,2,{"k":"v"#) == ["items": [1, 2, ["k": "v"]]])
        #expect(StreamingJSON.parseStreaming(#"{"comm"#) == [:])
        #expect(StreamingJSON.parseStreaming(#"{"a":tr"#) == ["a": true])
        #expect(StreamingJSON.parseStreaming("not json") == [:])
    }
}

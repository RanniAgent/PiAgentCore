# 上游文件 → Swift 文件

| 上游（pi 0.85.1） | Swift | 备注 |
|---|---|---|
| chord types.ts `JsonValue` | Sources/PiAgentCore/JSON/JSONValue.swift | 加了 Foundation 桥接 |
| packages/ai/src/utils/json-parse.ts | Sources/PiAgentCore/JSON/StreamingJSON.swift | partial-json 用自写解析器替代 |
| packages/ai/src/utils/validation.ts | Sources/PiAgentCore/JSON/JSONSchemaValidator.swift | typebox 换自写子集；纠偏与可选 null 规则照搬（顺序同上游：先删可选 null 再纠偏） |

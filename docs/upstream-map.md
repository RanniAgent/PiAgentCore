# 上游文件 → Swift 文件

| 上游（pi 0.85.1） | Swift | 备注 |
|---|---|---|
| chord types.ts `JsonValue` | Sources/PiAgentCore/JSON/JSONValue.swift | 加了 Foundation 桥接 |
| packages/ai/src/utils/json-parse.ts | Sources/PiAgentCore/JSON/StreamingJSON.swift | partial-json 用自写解析器替代 |
| packages/ai/src/utils/validation.ts | Sources/PiAgentCore/JSON/JSONSchemaValidator.swift | typebox 换自写子集；纠偏与可选 null 规则照搬（顺序同上游：先删可选 null 再纠偏） |
| packages/ai/src/types.ts（内容块与消息） | Sources/PiAgentCore/Types/Content.swift、Messages.swift | JSON 形状一致；custom 分支代替声明合并；未移植 AssistantMessage.diagnostics / deferred |

# 上游文件 → Swift 文件

| 上游（pi 0.85.1） | Swift | 备注 |
|---|---|---|
| chord types.ts `JsonValue` | Sources/PiAgentCore/JSON/JSONValue.swift | 加了 Foundation 桥接 |
| packages/ai/src/utils/json-parse.ts | Sources/PiAgentCore/JSON/StreamingJSON.swift | partial-json 用自写解析器替代 |

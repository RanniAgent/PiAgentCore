# PiAgentCore

pi-agent-core（https://github.com/earendil-works/pi）合同的 Swift 移植：事件、钩子、消息模型、循环、插话队列。供 Ranni iOS 使用。

- 对齐版本见 UPSTREAM.md，合同说明见 CONTRACT.md
- `swift build` / `swift test`
- 包内约定：零第三方依赖（Harness 目标除外）、零 `@unchecked Sendable`

## 安装

Xcode：File → Add Package Dependencies… → 填 `https://github.com/RanniAgent/PiAgentCore.git`。

Package.swift：

```swift
dependencies: [
    .package(url: "https://github.com/RanniAgent/PiAgentCore.git", .upToNextMinor(from: "0.1.0")),
]
```

三个产品：`PiAgentCore`（合同与纯逻辑）、`PiAgentHarness`（总装原语，当前是占位）、`PiAgentTestSupport`（假供应商、场景回放，给测试用）。

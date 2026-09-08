# 对齐的 pi 版本

| 项目 | 值 |
|---|---|
| pi-agent-core | 0.85.1 |
| pi-ai | 0.85.1 |
| 上游提交 | tag v0.85.1 |
| 上次同步 | 2026-09-07（首次） |

## 同步记录

| 日期 | 从 → 到 | 变更摘要 | 受影响文件 |
|---|---|---|---|
| 2026-09-07 | — → 0.85.1 | 首次移植 | 全部 |

## 同步流程

1. 读 packages/agent/CHANGELOG.md 与 packages/ai/CHANGELOG.md，先看 Breaking Changes。
2. 按 docs/upstream-map.md 逐文件 diff 上游，先改移植的测试，再改代码。
3. 桌面端重新导出金标准序列（`npm run trace:export`），`swift test` 全绿。
4. 更新本文件，打 tag，发布说明第一行写"对齐 pi x.y.z"。

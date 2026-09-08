#!/bin/sh
# 包内（Sources/）不允许出现 @unchecked Sendable；测试目标不限。
set -e
if grep -rn "@unchecked Sendable" Sources/; then
  echo "✗ Sources/ 里出现了 @unchecked Sendable" >&2
  exit 1
fi
echo "✓ 没有 @unchecked Sendable"

#!/bin/sh
# 一键启用仓库内 Git hooks（GitHub 大文件守卫）。
set -e
cd "$(dirname "$0")/.."
chmod +x scripts/check-large-files.sh .githooks/pre-commit
git config core.hooksPath .githooks
echo "✓ 已启用 .githooks/pre-commit（GitHub 100 MiB 大文件守卫）"
echo "  手动体检：./scripts/check-large-files.sh"
echo "  跳过检查：git commit --no-verify（不推荐）"

#!/usr/bin/env bash
#
# check-large-files.sh — GitHub 大文件守卫
#
# GitHub 对普通 Git 仓库的单文件硬限制为 100 MiB（超过则 push 被拒），
# 50 MiB 起会警告。本脚本用于在提交前/CI 中提前发现并阻止大文件进入历史。
#
# 用法：
#   ./scripts/check-large-files.sh                  全历史 + 仓库体积体检
#   ./scripts/check-large-files.sh --staged         只查暂存区（pre-commit hook）
#   ./scripts/check-large-files.sh --history RANGE  查指定提交范围（默认 --all）
#
# 环境变量：
#   FV_WARN_MB    警告阈值，默认 50
#   FV_BLOCK_MB   失败阈值，默认 100
#
# 退出码：0 通过；1 发现超过失败阈值的 blob；2 用法/环境错误。

# -u: an unset variable must be an error, not an empty string that silently
#     changes a threshold; pipefail stays so a failing stage cannot look empty.
set -uo pipefail

WARN_MB="${FV_WARN_MB:-}"
BLOCK_MB="${FV_BLOCK_MB:-}"
[ -z "$WARN_MB" ] && WARN_MB=50
[ -z "$BLOCK_MB" ] && BLOCK_MB=100

# Fail CLOSED on a bad threshold: bash 3.2 turns non-numeric values into 0
# inside $(( )), which silently disabled the whole guard (v4.2.26).
case "$WARN_MB" in
  ''|*[!0-9]*) echo "✗ FV_WARN_MB 必须是整数（当前：${WARN_MB}）" >&2; exit 2 ;;
esac
case "$BLOCK_MB" in
  ''|*[!0-9]*) echo "✗ FV_BLOCK_MB 必须是整数（当前：${BLOCK_MB}）" >&2; exit 2 ;;
esac
if [ "$WARN_MB" -ge "$BLOCK_MB" ]; then
  echo "✗ FV_WARN_MB（${WARN_MB}）必须小于 FV_BLOCK_MB（${BLOCK_MB}）" >&2
  exit 2
fi

WARN_BYTES=$((WARN_MB * 1024 * 1024))
BLOCK_BYTES=$((BLOCK_MB * 1024 * 1024))
REPO_WARN_BYTES=$((1024 * 1024 * 1024))
REPO_HARD_BYTES=$((5 * 1024 * 1024 * 1024))

if [ -t 1 ]; then
  RED="$(printf '\033[31m')"
  YELLOW="$(printf '\033[33m')"
  GREEN="$(printf '\033[32m')"
  RESET="$(printf '\033[0m')"
else
  RED=""
  YELLOW=""
  GREEN=""
  RESET=""
fi

usage() {
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
}

bytes_to_mib() {
  awk -v b="$1" 'BEGIN { printf "%.1f", b / 1048576 }'
}

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "✗ 当前目录不是 Git 仓库"
  exit 2
fi

MODE="history"
RANGE="--all"
if [ $# -gt 0 ]; then
  case "$1" in
    --staged)
      MODE="staged"
      ;;
    --history)
      MODE="history"
      if [ $# -gt 1 ]; then
        RANGE="$2"
      fi
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数：$1"
      usage
      exit 2
      ;;
  esac
fi

# ---------- 暂存区检查 ----------

check_staged() {
  local violations=0
  local warnings=0
  local checked=0
  local path size

  # Read the file list into a temp file instead of a process substitution:
  # with <( ) the producer's exit status is invisible, so a failing
  # `git diff`/`git ls-files` reported "✓ 0 files" and the guard passed
  # (v4.2.26). A bash variable cannot hold NUL-separated output, hence a file.
  local listing_file
  listing_file=$(mktemp) || { echo "✗ 无法创建临时文件" >&2; return 2; }
  if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    if ! git diff --cached --name-only -z --diff-filter=ACMRT > "$listing_file"; then
      rm -f "$listing_file"
      echo "✗ 无法读取暂存区（git diff --cached 失败），已停止检查" >&2
      return 2
    fi
  else
    if ! git ls-files -z > "$listing_file"; then
      rm -f "$listing_file"
      echo "✗ 无法读取索引（git ls-files 失败），已停止检查" >&2
      return 2
    fi
  fi
  if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    while IFS= read -r -d '' path; do
      [ -z "$path" ] && continue
      if ! size=$(git cat-file -s ":$path" 2>/dev/null); then
        rm -f "$listing_file"
        echo "✗ 无法读取 $path 的大小（git cat-file 失败），已停止检查" >&2
        return 2
      fi
      checked=$((checked + 1))
      if [ "$size" -gt "$BLOCK_BYTES" ]; then
        violations=$((violations + 1))
        printf '%s✗ %s  %s MiB%s（超过 GitHub %s MiB 单文件上限）\n' \
          "$RED" "$path" "$(bytes_to_mib "$size")" "$RESET" "$BLOCK_MB"
      elif [ "$size" -gt "$WARN_BYTES" ]; then
        warnings=$((warnings + 1))
        printf '%s! %s  %s MiB%s（超过 %s MiB，建议改用 LFS 或移出仓库）\n' \
          "$YELLOW" "$path" "$(bytes_to_mib "$size")" "$RESET" "$WARN_MB"
      fi
    done < "$listing_file"
  else
    # 首次提交（HEAD 尚不存在）：检查索引中的全部文件
    while IFS= read -r -d '' path; do
      [ -z "$path" ] && continue
      if ! size=$(git cat-file -s ":$path" 2>/dev/null); then
        rm -f "$listing_file"
        echo "✗ 无法读取 $path 的大小（git cat-file 失败），已停止检查" >&2
        return 2
      fi
      checked=$((checked + 1))
      if [ "$size" -gt "$BLOCK_BYTES" ]; then
        violations=$((violations + 1))
        printf '%s✗ %s  %s MiB%s（超过 GitHub %s MiB 单文件上限）\n' \
          "$RED" "$path" "$(bytes_to_mib "$size")" "$RESET" "$BLOCK_MB"
      elif [ "$size" -gt "$WARN_BYTES" ]; then
        warnings=$((warnings + 1))
        printf '%s! %s  %s MiB%s（超过 %s MiB，建议改用 LFS 或移出仓库）\n' \
          "$YELLOW" "$path" "$(bytes_to_mib "$size")" "$RESET" "$WARN_MB"
      fi
    done < "$listing_file"
  fi
  rm -f "$listing_file"

  if [ "$violations" -gt 0 ]; then
    printf '\n%s提交已阻止：%s 个文件超过 %s MiB。\n%s' \
      "$RED" "$violations" "$BLOCK_MB" "$RESET"
    echo "处理方式：移出仓库（git rm --cached + .git/info/exclude）、改用 Git LFS，或改用 Release 分发。"
    return 1
  fi
  if [ "$warnings" -gt 0 ]; then
    printf '%s提醒：%s 个文件超过 %s MiB，仍可提交，但请尽快处理。\n%s' \
      "$YELLOW" "$warnings" "$WARN_MB" "$RESET"
  else
    printf '%s✓ 暂存区无大文件（检查 %s 个文件）%s\n' "$GREEN" "$checked" "$RESET"
  fi
  return 0
}

# ---------- 历史检查 ----------

check_history() {
  local range="$1"
  local listing violations=0 warnings=0
  local size path

  if ! git rev-list -n 1 "$range" >/dev/null 2>&1; then
    echo "✗ 无法解析提交范围：$range"
    return 2
  fi

  # Enumerate objects FIRST and check the exit status: a corrupt/missing object
  # database used to yield an empty list, which this script reported as
  # "no large blobs" and exit 0 — letting a broken (and unpushable) commit
  # through (v4.2.25).
  local objects
  if ! objects=$(git rev-list --objects "$range" 2>&1); then
    printf '%s✗ 无法枚举提交对象（仓库可能损坏），拒绝放行：%s%s\n' "$RED" "$range" "$RESET" >&2
    printf '%s\n' "$objects" | sed -n '1,3p' >&2
    return 2
  fi

  listing=$(printf '%s\n' "$objects" \
    | git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' 2>/dev/null \
    | awk -v warn="$WARN_BYTES" -v block="$BLOCK_BYTES" '
        $1 == "blob" && $3 + 0 > warn {
          size = $3
          path = $4
          for (i = 5; i <= NF; i++) path = path " " $i
          if (path == "") path = $2
          if (!(path in max) || size > max[path]) max[path] = size
        }
        END {
          for (p in max) printf "%d\t%s\n", max[p], p
        }' \
    | sort -k1,1rn)
  if [ $? -ne 0 ]; then
    printf '%s✗ 读取对象信息失败，拒绝放行（仓库可能损坏）%s\n' "$RED" "$RESET" >&2
    return 2
  fi

  if [ -z "$listing" ]; then
    printf '%s✓ 历史中未发现超过 %s MiB 的 blob（范围：%s）%s\n' \
      "$GREEN" "$WARN_MB" "$range" "$RESET"
    return 0
  fi

  while IFS=$'\t' read -r size path; do
    [ -z "$size" ] && continue
    if [ "$size" -gt "$BLOCK_BYTES" ]; then
      violations=$((violations + 1))
      printf '%s✗ %s  %s MiB%s（GitHub 会拒绝包含该 blob 的 push）\n' \
        "$RED" "$path" "$(bytes_to_mib "$size")" "$RESET"
    else
      warnings=$((warnings + 1))
      printf '%s! %s  %s MiB%s（接近上限，建议清理或改用 LFS）\n' \
        "$YELLOW" "$path" "$(bytes_to_mib "$size")" "$RESET"
    fi
  done <<< "$listing"

  if [ "$violations" -gt 0 ]; then
    printf '\n%s发现 %s 个超过 %s MiB 的历史 blob，push 会被 GitHub 拒绝。%s\n' \
      "$RED" "$violations" "$BLOCK_MB" "$RESET"
    echo "处理方式：git filter-repo --strip-blobs-bigger-than ""$BLOCK_MB""M（先备份），或新建干净仓库。详见 docs/05-GitHub-100MB限制解决方案.md"
    return 1
  fi

  if [ "$warnings" -gt 0 ]; then
    printf '%s提醒：%s 个 blob 超过 %s MiB，尚未超限但建议处理。%s\n' \
      "$YELLOW" "$warnings" "$WARN_MB" "$RESET"
  fi
  return 0
}

# ---------- 仓库体积 ----------

check_repo_size() {
  local size_kb bytes_size
  size_kb=$(git count-objects -v 2>/dev/null \
    | awk '/^size:/{s += $2} /^size-pack:/{s += $2} END {print s + 0}')
  bytes_size=$((size_kb * 1024))
  if [ "$bytes_size" -gt "$REPO_HARD_BYTES" ]; then
    printf '%s⚠ 仓库对象体积约 %s MiB，超过 GitHub 强烈建议的 5 GiB 上限%s\n' \
      "$RED" "$(bytes_to_mib "$bytes_size")" "$RESET"
  elif [ "$bytes_size" -gt "$REPO_WARN_BYTES" ]; then
    printf '%s⚠ 仓库对象体积约 %s MiB，建议保持在 1 GiB 以内%s\n' \
      "$YELLOW" "$(bytes_to_mib "$bytes_size")" "$RESET"
  fi
  return 0
}

# ---------- 主流程 ----------

status=0
case "$MODE" in
  staged)
    check_staged || status=$?
    ;;
  history)
    check_history "$RANGE" || status=$?
    check_repo_size
    ;;
esac

if [ "$status" -eq 0 ]; then
  exit 0
fi
exit "$status"

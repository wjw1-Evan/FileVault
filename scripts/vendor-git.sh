#!/bin/zsh
# 打包期：把「内嵌 git」下载并校验好，供 make_app.sh 塞进 FileVault.app/Contents/Resources/git
#
# 为什么需要：FileVault 的 FR-01 首选策略是「应用自带 git」，这样用户首次启动
# 完全不需要联网，也不依赖 Xcode/Homebrew。这个脚本只在打包机（开发者）上跑。
#
# 用法:
#   ./scripts/vendor-git.sh                 # 默认只为当前机器架构准备
#   ./scripts/vendor-git.sh --arch all      # 同时准备 arm64 + x64（分发包两个架构都要）
#   ./scripts/vendor-git.sh --dest build/vendor/git
#
# 上游: desktop/dugite-native（GitHub Desktop 同源的自包含 git 包）
# 版本与 sha256 必须和 Sources/FileVaultCore/GitProvisioner.swift 里的 GitBuildCatalog 一致。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="2.56.1"
TAG="v${VERSION}"
ASSET_VERSION_TOKEN="238326e"

declare -A ASSET ASSET_SHA
ASSET[arm64]="dugite-native-${TAG}-${ASSET_VERSION_TOKEN}-macOS-arm64.tar.gz"
ASSET_SHA[arm64]="a882ec6882416b57d212a22bac845ae27944f96cf73453a864f6a12c17863a79"
ASSET[x64]="dugite-native-${TAG}-${ASSET_VERSION_TOKEN}-macOS-x64.tar.gz"
ASSET_SHA[x64]="3fdb0c2f102fe0273d64b5d5fb77315c19f2b4648a154593723cb9ed98f2bc7d"

ARCH="host"
DEST="build/vendor/git"
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCH="$2"; shift 2 ;;
    --dest) DEST="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

case "$ARCH" in
  host)  [ "$(uname -m)" = "arm64" ] && ARCH=arm64 || ARCH=x64 ;;
  arm64|x64|all) ;;
  *) echo "--arch 只能是 arm64 / x64 / all" >&2; exit 2 ;;
esac
[ "$ARCH" = "all" ] && TARGETS=(arm64 x64) || TARGETS=($ARCH)

CACHE="build/vendor/downloads"
mkdir -p "$CACHE" "$DEST"

# 与 App 内 GitMirror.defaultLadder 保持一致；任一地址可用即可。
URL_TEMPLATES=(
  "https://github.com/desktop/dugite-native/releases/download/{tag}/{asset}"
  "https://ghfast.top/https://github.com/desktop/dugite-native/releases/download/{tag}/{asset}"
  "https://gh-proxy.com/https://github.com/desktop/dugite-native/releases/download/{tag}/{asset}"
  "https://ghproxy.cfd/https://github.com/desktop/dugite-native/releases/download/{tag}/{asset}"
)
# 本项目自建镜像（把同一份包作为 FileVault 自己的 release 资源上传后可用）
URL_TEMPLATES+=("https://github.com/wjw1-Evan/FileVault/releases/download/git-${VERSION}/{asset}")

fetch_with_mirrors() {
  local url_file="$1"
  local output="$2"
  local template url
  for template in "${URL_TEMPLATES[@]}"; do
    url="${template//\{tag\}/$TAG}"
    url="${url//\{asset\}/$url_file}"
    echo "  尝试: $url"
    # -C - 断点续传；单地址最多 15 分钟；失败换下一个地址
    if curl -fL --retry 2 --retry-delay 2 -C - --connect-timeout 10 --max-time 900 -o "$output" "$url"; then
      return 0
    fi
    echo "  ↳ 失败，换下一个地址"
  done
  return 1
}

for target in "${TARGETS[@]}"; do
  asset="${ASSET[$target]}"
  expected="${ASSET_SHA[$target]}"
  archive="${CACHE}/${asset}"
  echo "==> $asset"
  if [ -f "$archive" ] && [ "$(shasum -a 256 "$archive" | awk '{print $1}')" = "$expected" ]; then
    echo "  已缓存且校验通过"
  else
    rm -f "$archive"
    fetch_with_mirrors "$asset" "$archive" || { echo "❌ 所有下载地址都失败: $asset" >&2; exit 1; }
    actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
      echo "❌ sha256 不匹配，已删除：期望 $expected 实际 $actual" >&2
      rm -f "$archive"
      exit 1
    fi
  fi

  outdir="${DEST}/${target}"
  rm -rf "$outdir"
  mkdir -p "$outdir"
  tar -xzf "$archive" -C "$outdir"
  # 统一成 <root>/bin/git 布局（App 的 bundled 定位逻辑依赖它）
  if [ ! -x "${outdir}/bin/git" ]; then
    inner=$(find "$outdir" -maxdepth 2 -type d -name bin | head -1)
    if [ -z "$inner" ]; then echo "❌ 压缩包结构异常：没有 bin/" >&2; exit 1; fi
    parent="$(dirname "$inner")"
    tmp="${outdir}.tmp"; mv "$parent" "$tmp"; rm -rf "$outdir"; mv "$tmp" "$outdir"
  fi
  # 去掉用不到的 Git Credential Manager（约 110 MB 的 .NET/Avalonia 运行时）：
  # 凭证在本项目里走 gh / 钥匙串 / SSH，从不调用 GCM。
  # 与 App 内 GitBinaryProvisioner.pruneUnusedHelpers 保持一致。
  core="${outdir}/libexec/git-core"
  if [ -f "${core}/git-credential-manager" ]; then
    rm -rf "${core}"/*.dll "${core}"/*.dylib "${core}/createdump" \
      "${core}"/git-credential-manager* \
      "${core}"/cs "${core}"/de "${core}"/es "${core}"/fr "${core}"/it "${core}"/ja \
      "${core}"/ko "${core}"/pl "${core}"/pt-BR "${core}"/ru "${core}"/tr \
      "${core}"/zh-Hans "${core}"/zh-Hant
    echo "  已移除 GCM（.NET 运行时）"
  fi
  "${outdir}/bin/git" --version | sed 's/^/  /'
  du -sh "$outdir" | sed 's/^/  体积: /'
done

echo "✅ 内嵌 git 已就绪: $DEST (可被 make_app.sh 打包)"

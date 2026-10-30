#!/usr/bin/env bash
# install.sh —— 免 sudo 安装 GitHub CLI(gh)到本仓库 bin/
#
# 思路: 不走 github.com(常被阻断),改走 api.github.com 的 release 资源端点,
#       并用官方 checksums.txt 校验 sha256。
# 依赖: curl; 解压用系统自带 unzip(macOS)/ tar(Linux)。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$ROOT/bin"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say() { printf '%s\n' "$*"; }
die() { printf '错误: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "需要 curl"
command -v awk  >/dev/null 2>&1 || die "需要 awk"

# ---------------------------------------------------------------- 平台探测
OS="$(uname -s)"; ARCH="$(uname -m)"
case "$OS" in
  Darwin) PLAT="macOS"; EXT="zip" ;;
  Linux)  PLAT="linux"; EXT="tar.gz" ;;
  *) die "不支持的平台: $OS(本脚本只覆盖 macOS / Linux)" ;;
esac
case "$ARCH" in
  arm64|aarch64) A="arm64" ;;
  x86_64|amd64)  A="amd64" ;;
  *) die "不支持的架构: $ARCH" ;;
esac
say "平台: $PLAT $A"

# ------------------------------------------------------------------ API 访问
if [ -n "${GH_TOKEN:-}" ]; then
  AUTH_HDR="Authorization: Bearer $GH_TOKEN"
else
  AUTH_HDR=""
fi

api_get() { # api_get <path> <output>
  if [ -n "$AUTH_HDR" ]; then
    curl -fsSL --retry 3 --retry-delay 2 --max-time 60 -H "$AUTH_HDR" "https://api.github.com$1" -o "$2"
  else
    curl -fsSL --retry 3 --retry-delay 2 --max-time 60 "https://api.github.com$1" -o "$2"
  fi
}

asset_download() { # asset_download <asset_id> <output>
  if [ -n "$AUTH_HDR" ]; then
    curl -fsSL --retry 3 --retry-delay 2 --max-time 300 \
      -H "$AUTH_HDR" -H "Accept: application/octet-stream" \
      "https://api.github.com/repos/cli/cli/releases/assets/$1" -o "$2"
  else
    curl -fsSL --retry 3 --retry-delay 2 --max-time 300 \
      -H "Accept: application/octet-stream" \
      "https://api.github.com/repos/cli/cli/releases/assets/$1" -o "$2"
  fi
}

# 从 release JSON 里取出某个资产名对应的 asset id
# (GitHub 返回的是逐字段换行的 pretty JSON,用 awk 顺序扫描足够可靠)
asset_id() {
  awk -v want="$1" '
    match($0, /"url": "https:\/\/api\.github\.com\/repos\/[^"]*\/releases\/assets\/[0-9]+"/) {
      s = substr($0, RSTART, RLENGTH)
      if (match(s, /assets\/[0-9]+/)) cur = substr(s, RSTART + 7, RLENGTH - 7)
    }
    match($0, /"name": "[^"]*"/) {
      n = substr($0, RSTART, RLENGTH)
      n = substr(n, 10, length(n) - 10)
      if (n == want) { print cur; exit }
    }' "$TMP/release.json"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# ------------------------------------------------------------------ 主流程
say "查询 gh 最新版本(api.github.com)..."
api_get /repos/cli/cli/releases/latest "$TMP/release.json"

TAG="$(sed -n 's/^ *"tag_name": "\([^"]*\)",*$/\1/p' "$TMP/release.json" | head -1)"
[ -n "$TAG" ] || die "解析版本号失败"
VER="${TAG#v}"
ASSET="gh_${VER}_${PLAT}_${A}.${EXT}"
say "最新版本: $TAG"

ID="$(asset_id "$ASSET")"
[ -n "$ID" ] || die "在 release 中找不到资产 $ASSET"

say "下载 $ASSET ..."
asset_download "$ID" "$TMP/$ASSET"
say "校验 sha256 ..."
CID="$(asset_id "gh_${VER}_checksums.txt")"
[ -n "$CID" ] || die "找不到 checksums 资产"
asset_download "$CID" "$TMP/checksums.txt"
EXPECT="$(awk -v f="$ASSET" '$2 == f || $2 == "*"f {print $1}' "$TMP/checksums.txt" | head -1)"
[ -n "$EXPECT" ] || die "checksums 里没有 $ASSET 的条目"
ACTUAL="$(sha256_file "$TMP/$ASSET")"
[ "$EXPECT" = "$ACTUAL" ] || die "sha256 不匹配!
  期望: $EXPECT
  实际: $ACTUAL"
say "sha256 OK ($ACTUAL)"

say "解压安装到 $BIN/gh.bin ..."
mkdir -p "$BIN"
if [ "$EXT" = "zip" ]; then
  command -v unzip >/dev/null 2>&1 || die "需要 unzip"
  unzip -oq "$TMP/$ASSET" -d "$TMP/x"
else
  mkdir -p "$TMP/x" && tar xzf "$TMP/$ASSET" -C "$TMP/x"
fi
GHBIN="$(find "$TMP/x" -type f -path '*/bin/gh' | head -1)"
[ -n "$GHBIN" ] || die "压缩包里没找到 bin/gh"
install -m 0755 "$GHBIN" "$BIN/gh.bin"

chmod +x "$BIN/gh" 2>/dev/null || true
say ""
say "✅ gh 已安装: $("$BIN/gh" --version | head -1)"
say "   入口: $BIN/gh(包装器,自动带认证配置与 PATH)"
say "   下一步: 用 PAT 登录 —— 见 README「认证」一节,或运行 tools/set-token.sh"

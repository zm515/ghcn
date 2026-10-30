#!/usr/bin/env bash
# install-git.sh —— 免 sudo 安装 git(conda-forge,自带全部动态库依赖)到 .gitenv/
#
# 适用场景: 机器上没有 Homebrew、没有 Xcode Command Line Tools、也没有 sudo,
#           但需要一个真 git(系统 /usr/bin/git 可能只是 118KB 的 shim)。
#
# 用法:
#   ./install-git.sh          # 用官方 conda-forge 源
#   ./install-git.sh --cn     # 用清华 TUNA 镜像(国内更快),并给 git 配置镜像改写
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say() { printf '%s\n' "$*"; }
die() { printf '错误: %s\n' "$*" >&2; exit 1; }

CN=0
for a in "$@"; do [ "$a" = "--cn" ] && CN=1; done

command -v curl >/dev/null 2>&1 || die "需要 curl"

# ---------------------------------------------------------------- 平台探测
OS="$(uname -s)"; ARCH="$(uname -m)"
case "$OS" in
  Darwin) case "$ARCH" in arm64) MMB="micromamba-osx-arm64" ;; x86_64) MMB="micromamba-osx-64" ;; *) die "不支持的架构: $ARCH" ;; esac ;;
  Linux)  case "$ARCH" in aarch64|arm64) MMB="micromamba-linux-aarch64" ;; x86_64) MMB="micromamba-linux-64" ;; *) die "不支持的架构: $ARCH" ;; esac ;;
  *) die "不支持的平台: $OS" ;;
esac
say "平台: $OS $ARCH  →  $MMB"

# ------------------------------------------------------------ 下载 micromamba
asset_id() { # asset_id <file> <asset name>
  awk -v want="$2" '
    match($0, /"url": "https:\/\/api\.github\.com\/repos\/[^"]*\/releases\/assets\/[0-9]+"/) {
      s = substr($0, RSTART, RLENGTH)
      if (match(s, /assets\/[0-9]+/)) cur = substr(s, RSTART + 7, RLENGTH - 7)
    }
    match($0, /"name": "[^"]*"/) {
      n = substr($0, RSTART, RLENGTH); n = substr(n, 10, length(n) - 10)
      if (n == want) { print cur; exit }
    }' "$1"
}

say "查询 micromamba 最新版本..."
curl -fsSL --retry 3 --max-time 60 \
  https://api.github.com/repos/mamba-org/micromamba-releases/releases/latest \
  -o "$TMP/rel.json" || die "无法访问 api.github.com"

ID="$(asset_id "$TMP/rel.json" "$MMB")"
[ -n "$ID" ] || die "release 里找不到 $MMB"
say "下载 $MMB ..."
curl -fsSL --retry 3 --max-time 300 -H "Accept: application/octet-stream" \
  "https://api.github.com/repos/mamba-org/micromamba-releases/releases/assets/$ID" \
  -o "$TMP/micromamba"

SHID="$(asset_id "$TMP/rel.json" "$MMB.sha256")"
EXPECT=""
if [ -n "$SHID" ]; then
  curl -fsSL --max-time 60 -H "Accept: application/octet-stream" \
    "https://api.github.com/repos/mamba-org/micromamba-releases/releases/assets/$SHID" \
    -o "$TMP/mm.sha256" || true
  EXPECT="$(awk '{print $1}' "$TMP/mm.sha256" 2>/dev/null | head -1)"
fi
if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL="$(sha256sum "$TMP/micromamba" | awk '{print $1}')"
else
  ACTUAL="$(shasum -a 256 "$TMP/micromamba" | awk '{print $1}')"
fi
if [ -n "$EXPECT" ]; then
  [ "$EXPECT" = "$ACTUAL" ] || die "micromamba sha256 不匹配(期望 $EXPECT 实际 $ACTUAL)"
  say "sha256 OK"
else
  say "警告: 未取到官方 sha256,跳过校验(实际 $ACTUAL)"
fi

mkdir -p "$ROOT/tools"
install -m 0755 "$TMP/micromamba" "$ROOT/tools/micromamba"

# ---------------------------------------------------------------- 创建环境
export MAMBA_ROOT_PREFIX="$ROOT/.mamba"
export CONDA_PKGS_DIRS="$ROOT/.mamba/pkgs"
mkdir -p "$CONDA_PKGS_DIRS"

if [ "$CN" = "1" ]; then
  CHANNEL="https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud/conda-forge"
else
  CHANNEL="https://conda.anaconda.org/conda-forge"
fi
say "conda 源: $CHANNEL"
say "创建环境 .gitenv(下载约 50MB)..."
"$ROOT/tools/micromamba" create -y --no-rc \
  -p "$ROOT/.gitenv" --override-channels -c "$CHANNEL" git \
  || die "创建环境失败"

chmod +x "$ROOT/bin/git" 2>/dev/null || true

# ------------------------------------------------------------ 写全局配置模板
if [ ! -f "$ROOT/.gitconfig" ]; then
  {
    echo "[init]"
    echo "	defaultBranch = main"
    echo "[core]"
    echo "	quotepath = false"
    echo "[color]"
    echo "	ui = auto"
    echo "[http]"
    echo "	sslCAInfo = $ROOT/.gitenv/ssl/cacert.pem"
  } > "$ROOT/.gitconfig"
  if [ "$CN" = "1" ]; then
    {
      echo ""
      echo "[url \"https://gitclone.com/github.com/\"]"
      echo "	insteadOf = https://github.com/"
    } >> "$ROOT/.gitconfig"
    say "已配置 github.com → gitclone.com 镜像改写(仅影响读操作)"
  fi
fi

say ""
say "✅ git 已安装: $("$ROOT/bin/git" --version)"
say "   提示: 再加 --cn 可用国内镜像;身份请自行设置:"
say "         ./bin/git config --global user.name  '你的名字'"
say "         ./bin/git config --global user.email '你的邮箱'"

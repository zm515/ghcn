#!/bin/bash
# tools/set-token.sh —— 用 Personal Access Token 登录(设备流在受限网络下走不通)
#
# 用法:
#   printf '%s' 'ghp_xxx' | ./tools/set-token.sh
#   ./tools/set-token.sh < token.txt
#
# token 只从 stdin 读,不回显、不写日志;仅存进仓库内 .gh-config/(700)。
set -u

WS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG="$WS/.gh-config"
GH="$WS/bin/gh"

[ -x "$GH" ] || { echo "错误: 先运行 ./install.sh 安装 gh" >&2; exit 1; }

TOKEN="$(head -n1 | tr -d '[:space:]')"
[ -n "$TOKEN" ] || { echo "错误: 没有从 stdin 收到 token" >&2; exit 1; }
case "$TOKEN" in
  gh[pousr]_*|github_pat_*) : ;;
  *) echo "警告: 格式不像 GitHub token(通常 ghp_ / github_pat_ 开头),仍继续尝试" >&2 ;;
esac

echo "1/3 校验 token(走 api.github.com,不依赖被墙的 github.com)..."
HDR="$(mktemp)"; trap 'rm -f "$HDR"' EXIT
BODY="$(curl -sS --max-time 20 -D "$HDR" \
        -H "Authorization: Bearer $TOKEN" \
        -H 'Accept: application/vnd.github+json' \
        https://api.github.com/user 2>&1)"
CODE="$(grep -i '^HTTP/' "$HDR" | tail -1 | awk '{print $2}')"
LOGIN="$(printf '%s' "$BODY" | sed -n 's/.*"login": *"\([^"]*\)".*/\1/p' | head -1)"
SCOPES="$(grep -i '^x-oauth-scopes:' "$HDR" | sed 's/^[^:]*: *//' | tr -d '\r')"

if [ "$CODE" != "200" ] || [ -z "$LOGIN" ]; then
  echo "✗ token 无效或已过期(HTTP ${CODE:-?})" >&2
  exit 1
fi
echo "   OK: 账号 $LOGIN"
[ -n "$SCOPES" ] && echo "   作用域: $SCOPES"

echo "2/3 写入 $CFG ..."
mkdir -p "$CFG" && chmod 700 "$CFG"
export GH_CONFIG_DIR="$CFG"
printf '%s' "$TOKEN" | "$GH" auth login --with-token 2>&1 | sed 's/gh[pousr]_[A-Za-z0-9_]*/***/g'

echo "3/3 验证 ..."
"$GH" auth status 2>&1 | sed 's/gh[pousr]_[A-Za-z0-9_]*/***/g'
echo ""
echo "✅ 完成。试试: ./bin/gh api /user"

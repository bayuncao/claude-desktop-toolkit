#!/bin/zsh
# setup.sh — 生成 Claude (Proxy) 配置并组装可双击的 .app
#
# 用法:
#   ./setup.sh                    # 交互式：自动探测代理端口与 Claude 路径，回车确认
#   ./setup.sh --proxy URL --claude PATH   # 非交互式（适合脚本/CI）
#   ./setup.sh --open             # 组装完立即启动
#   ./setup.sh --help
#
# 产物:
#   ~/.claude-proxy/proxy.env            配置文件（权限 600，不进仓库）
#   ~/Applications/Claude (Proxy).app   可双击的启动器
#
# 不会修改 /Applications/Claude.app 本体，也不会改动 macOS 系统代理设置。

SCRIPT_DIR="${0:A:h}"
CFG="$HOME/.claude-proxy/proxy.env"
APP="$HOME/Applications/Claude (Proxy).app"

PROXY_ARG=""; CLAUDE_ARG=""; DO_OPEN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --proxy)  PROXY_ARG="$2"; shift 2 ;;
    --claude) CLAUDE_ARG="$2"; shift 2 ;;
    --open)   DO_OPEN=1; shift ;;
    -h|--help)
      print -r -- "用法: ./setup.sh [--proxy URL] [--claude PATH] [--open]"
      print -r -- "  --proxy   代理地址，例如 http://127.0.0.1:7897"
      print -r -- "  --claude  Claude 可执行文件完整路径"
      print -r -- "  --open    组装后立即启动"
      exit 0 ;;
    *) print -u2 -- "未知参数: $1"; exit 1 ;;
  esac
done

# ---- 探测本机正在监听的 HTTP 代理端口（只作建议值，不写死）----
detect_proxy() {
  local p
  for p in 7890 7897 7892 8080 8888 1087 6152; do
    if command -v nc >/dev/null 2>&1 && nc -z -G 1 127.0.0.1 "$p" 2>/dev/null; then
      print -r -- "http://127.0.0.1:$p"; return 0
    fi
  done
  return 1
}

# ---- 探测 Claude Desktop ----
detect_claude() {
  local c
  for c in "/Applications/Claude.app/Contents/MacOS/Claude" \
           "$HOME/Applications/Claude.app/Contents/MacOS/Claude"; do
    [[ -x "$c" ]] && { print -r -- "$c"; return 0; }
  done
  if command -v mdfind >/dev/null 2>&1; then
    c="$(mdfind "kMDItemCFBundleIdentifier == 'com.anthropic.claudefordesktop'" 2>/dev/null | head -1)"
    [[ -n "$c" && -x "$c/Contents/MacOS/Claude" ]] && { print -r -- "$c/Contents/MacOS/Claude"; return 0; }
  fi
  return 1
}

if [[ -z "$PROXY_ARG" ]]; then
  SUGGEST="$(detect_proxy || print -r -- '')"
  if [[ -n "$SUGGEST" ]]; then
    printf "代理地址（回车使用探测值 %s）: " "$SUGGEST"
  else
    printf "代理地址（未探测到，请手动输入，例如 http://127.0.0.1:7897）: "
  fi
  read -r ans
  PROXY_ARG="${ans:-$SUGGEST}"
  [[ -n "$PROXY_ARG" ]] || { print -u2 -- "错误: 必须提供代理地址。"; exit 1; }
fi

if [[ -z "$CLAUDE_ARG" ]]; then
  SUGGEST="$(detect_claude || print -r -- '')"
  if [[ -n "$SUGGEST" ]]; then
    printf "Claude 可执行文件（回车使用 %s）: " "$SUGGEST"
  else
    printf "Claude 可执行文件（未探测到，请输入完整路径）: "
  fi
  read -r ans
  CLAUDE_ARG="${ans:-$SUGGEST}"
  [[ -n "$CLAUDE_ARG" ]] || { print -u2 -- "错误: 必须提供 Claude 路径。"; exit 1; }
fi
[[ -x "$CLAUDE_ARG" ]] || print -u2 -- "警告: $CLAUDE_ARG 当前不可执行（配置仍会写入）。"

# ---- 写配置 ----
mkdir -p "$(dirname "$CFG")" || exit 1
{
  print -r -- "PROXY=\"$PROXY_ARG\""
  print -r -- "CLAUDE_BIN=\"$CLAUDE_ARG\""
} > "$CFG"
chmod 600 "$CFG"
print -r -- "✓ 配置已写入 $CFG"

# ---- 组装 .app ----
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" || exit 1
cp "$SCRIPT_DIR/launch" "$APP/Contents/MacOS/launch" || exit 1
cp "$SCRIPT_DIR/Info.plist" "$APP/Contents/Info.plist" || exit 1
chmod +x "$APP/Contents/MacOS/launch"

APP_SRC="${CLAUDE_ARG%/Contents/MacOS/Claude}"
if [[ -r "$APP_SRC/Contents/Resources/electron.icns" ]]; then
  cp "$APP_SRC/Contents/Resources/electron.icns" "$APP/Contents/Resources/" 2>/dev/null
else
  # 仓库不含图标文件；取不到时移除该键，app 使用系统默认图标即可正常启动
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

# ad-hoc 签名 + 清除 quarantine：避免从网络下载后被 Gatekeeper 拦截
command -v codesign >/dev/null 2>&1 && codesign --force --deep --sign - "$APP" 2>/dev/null || true
xattr -cr "$APP" 2>/dev/null || true
print -r -- "✓ 启动器已组装 $APP"

print -r -- ""
print -r -- "启动:   open \"$APP\""
print -r -- "或:     \"$SCRIPT_DIR/launch\""
print -r -- "改配置: 编辑 $CFG，或用 CLAUDE_PROXY=... 临时覆盖"

[[ "$DO_OPEN" -eq 1 ]] && open "$APP"

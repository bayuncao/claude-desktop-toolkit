#!/bin/zsh
# ============================================================
# clean-claude.sh — Claude Desktop 彻底清理（重置机器码 + 全清数据）
#
# 用法: ./clean-claude.sh
#   无参数、无确认，直接执行：退出 Claude → 清偏好缓存 → 全部数据移入废纸篓 → 残留复查
#   注意: 会退出登录、丢失本地会话；数据保留在 ~/.Trash 可反悔
#
# 安全机制:
#   - 只 mv 到 ~/.Trash，绝不 rm；命名带父目录+时间戳+PID+序号，杜绝同名覆盖
#   - 结束后复查残留；失败不隐藏原因
# ============================================================

setopt NULL_GLOB   # 通配符无匹配时展开为空，不报错

TS="$(date +%Y%m%d-%H%M%S).$$"   # 时间戳 + PID，避免同秒重复运行撞名
TRASH="$HOME/.Trash"

echo "=== 彻底清理 Claude Desktop（会退出登录）==="

# 运行中则先优雅退出
if pgrep -x Claude >/dev/null 2>&1; then
  echo "[*] Claude 正在运行，尝试退出..."
  osascript -e 'quit app "Claude"' 2>/dev/null
  sleep 2
  if pgrep -x Claude >/dev/null 2>&1; then
    echo "[!] Claude 未能退出（可能无 Apple Events 权限），中止。请手动关闭后重试。"
    exit 1
  fi
fi

TARGETS=(
  "$HOME/Library/Application Support/Claude"
  "$HOME/Library/Application Support/Claude-3p"
  "$HOME/Library/Application Support/Claude-machineid-backup-"*
  "$HOME/Library/Application Support/com.anthropic.claudefordesktop"*
  "$HOME/Library/Caches/com.anthropic.claudefordesktop"*
  "$HOME/Library/Caches/claude-cli-nodejs"
  "$HOME/Library/HTTPStorages/com.anthropic.claudefordesktop"*
  "$HOME/Library/Logs/Claude"
  "$HOME/Library/Preferences/com.anthropic.claudefordesktop"*
  "$HOME/Library/WebKit/com.anthropic.claudefordesktop"*
  "$HOME/Library/Saved Application State/com.anthropic.claudefordesktop"*
  "$HOME/Library/Containers/com.anthropic.claudefordesktop"*
)

# 收集实际存在的目标（-L 兼顾断链的符号链接）
EXISTING=()
for t in "${TARGETS[@]}"; do
  { [ -e "$t" ] || [ -L "$t" ]; } && EXISTING+=("$t")
done

if [ ${#EXISTING[@]} -eq 0 ]; then
  echo "没有发现需要清理的文件，一切干净。"
  exit 0
fi

echo "将清理以下 ${#EXISTING[@]} 项:"
for f in "${EXISTING[@]}"; do echo "  - $f"; done

mkdir -p "$TRASH" || { echo "[!] 无法创建废纸篓目录 $TRASH，中止。"; exit 1; }

# 先清 cfprefsd 缓存，否则它可能在应用启动时把旧偏好写回 plist
defaults delete com.anthropic.claudefordesktop 2>/dev/null

# 生成绝不冲突的废纸篓目标名：父目录标签 + 时间戳 + PID + 递增序号
unique_trash_path() {
  local src="$1" base parent label cand n=1
  base=$(basename "$src")
  parent=$(basename "$(dirname "$src")")
  label="${parent}__${base}"
  cand="$TRASH/${label}.${TS}"
  while [ -e "$cand" ] || [ -L "$cand" ]; do
    cand="$TRASH/${label}.${TS}.${n}"
    n=$((n + 1))
  done
  printf '%s' "$cand"
}

# ---- 执行：移入废纸篓（可反悔），不用 rm ----
OK=0; FAIL=0
for f in "${EXISTING[@]}"; do
  dest=$(unique_trash_path "$f")
  if mv "$f" "$dest"; then
    echo "✓ 已入废纸篓: $f -> $(basename "$dest")"
    OK=$((OK+1))
  else
    echo "✗ 失败: $f"
    FAIL=$((FAIL+1))
  fi
done

# ---- 残留复查 ----
LEFTOVERS=(
  "$HOME"/Library/Application\ Support/*[Cc]laude*(N)
  "$HOME"/Library/Application\ Support/com.anthropic.claudefordesktop*(N)
  "$HOME"/Library/Caches/*[Cc]laude*(N)
  "$HOME"/Library/Preferences/com.anthropic.claudefordesktop*(N)
  "$HOME"/Library/HTTPStorages/com.anthropic.claudefordesktop*(N)
  "$HOME"/Library/WebKit/com.anthropic.claudefordesktop*(N)
  "$HOME"/Library/Saved\ Application\ State/com.anthropic.claudefordesktop*(N)
  "$HOME"/Library/Logs/*[Cc]laude*(N)
)
if [ ${#LEFTOVERS[@]} -gt 0 ]; then
  echo "[!] 复查发现 ${#LEFTOVERS[@]} 项残留（可能是 Claude 运行中重新生成的）:"
  for f in "${LEFTOVERS[@]}"; do echo "    - $f"; done
else
  echo "复查: 无残留 ✓"
fi

echo "----"
echo "完成: 成功 $OK 项, 失败 $FAIL 项。"
echo "提示: 数据仍在废纸篓占空间，确认 Claude 可正常启动后清空废纸篓即可彻底释放；需重新登录。"
[ "$FAIL" -gt 0 ] && exit 1
exit 0

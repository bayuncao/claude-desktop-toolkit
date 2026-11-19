#!/bin/zsh
# accounts.sh — 管理 Claude Desktop 的独立账号档案
#
# 每个档案就是一个完整的 Electron userData 目录：登录态、机器码、缓存彼此隔离。
# 切换账号 = 指定另一个档案目录启动，不再是在同一个目录里登出/登入互相覆盖。
#
# 用法:
#   ./accounts.sh list                    列出所有档案及状态
#   ./accounts.sh use <name>              设为下次启动的默认账号（不存在则创建）
#   ./accounts.sh add <name>              新建空档案（稍后在其中登录）
#   ./accounts.sh import-current <name>   把「当前默认目录的登录态」导入指定档案
#   ./accounts.sh status                  显示当前账号
#   ./accounts.sh path <name>             输出档案绝对路径
#   ./accounts.sh --help
#
# 档案目录: ~/.claude-accounts/<name>/        权限 700
# 当前账号: ~/.claude-accounts/current        纯文本，权限 600
#
# ⚠️ 档案内含 Cookies 与 OAuth token，等同账号凭据。
#    绝不要提交到仓库、上传网盘或分享给他人；只在使用者本机保存。

ROOT="$HOME/.claude-accounts"
CURRENT="$ROOT/current"
DEFAULT_DATA="$HOME/Library/Application Support/Claude"

# 登录态必需文件。刻意排除 ant-did / 机器码 / 缓存 / 日志，
# 让每个档案首次启动时生成自己的设备 ID。
LOGIN_FILES=(Cookies Cookies-journal config.json "Local State" Preferences
             "Network Persistent State" TransportSecurity claude_desktop_config.json)
LOGIN_DIRS=("Local Storage" "Session Storage" IndexedDB WebStorage blob_storage)

valid_name() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

# 用 strings + grep 判断 Cookies 里是否存在 sessionKey（不依赖 python3 / sqlite3）
has_login() {
  [[ -f "$ROOT/$1/Cookies" ]] || return 1
  strings "$ROOT/$1/Cookies" 2>/dev/null | grep -q 'sessionKey'
}

read_current() {
  local c=""
  [[ -r "$CURRENT" ]] && IFS= read -r c < "$CURRENT"
  print -r -- "${c//[[:space:]]/}"
}

ensure_dir() {
  mkdir -p "$ROOT/$1" || { print -u2 -- "错误: 无法创建 $ROOT/$1"; return 1; }
  chmod 700 "$ROOT/$1" 2>/dev/null
}

usage() {
  print -r -- "用法: ./accounts.sh <命令> [账号名]"
  print -r -- ""
  print -r -- "  list                    列出所有档案及状态（★ = 当前默认）"
  print -r -- "  use <name>              设为下次启动的默认账号（不存在则创建）"
  print -r -- "  add <name>              新建空档案，稍后在其中登录"
  print -r -- "  import-current <name>   把当前默认数据目录的登录态导入档案"
  print -r -- "  status                  显示当前账号与路径"
  print -r -- "  path <name>             输出档案绝对路径"
  print -r -- ""
  print -r -- "档案目录: $ROOT/<name>/   当前账号: $CURRENT"
  print -r -- "启动: ./launch <name>   或  CLAUDE_ACCOUNT=<name> ./launch"
  print -r -- "切换账号前必须完全退出 Claude（⌘Q / Dock 右键退出）。"
}

mkdir -p "$ROOT" 2>/dev/null; chmod 700 "$ROOT" 2>/dev/null
CMD="${1:-list}"; NAME="${2:-}"

case "$CMD" in
  -h|--help|help) usage; exit 0 ;;

  list)
    cur="$(read_current)"
    printf "%-12s %-14s %-8s %s\n" "档案" "登录态" "大小" "备注"
    printf "%-12s %-14s %-8s %s\n" "----" "------" "----" "----"
    found=0
    for d in "$ROOT"/*(N/); do
      n="${d:t}"
      sz="$(du -sh "$d" 2>/dev/null | awk '{print $1}')"
      if has_login "$n"; then st="已保存"; else st="空 / 未登录"; fi
      mark=""; [[ "$n" == "$cur" ]] && mark="★ 当前默认"
      printf "%-12s %-14s %-8s %s\n" "$n" "$st" "${sz:-0}" "$mark"
      found=1
    done
    [[ "$found" -eq 1 ]] || print -r -- "（还没有任何档案，用 ./accounts.sh add <name> 创建）"
    ;;

  status)
    cur="$(read_current)"
    if [[ -z "$cur" ]]; then
      print -r -- "未设置默认账号：启动将使用 Claude 默认数据目录。用 ./accounts.sh use <name> 设置。"
    else
      print -r -- "当前账号: $cur"
      print -r -- "档案路径: $ROOT/$cur"
      has_login "$cur" && print -r -- "登录态:   已保存" || print -r -- "登录态:   无（需在该档案里登录一次）"
    fi
    ;;

  path)
    [[ -n "$NAME" ]] || { print -u2 -- "错误: 需要账号名。"; exit 1; }
    valid_name "$NAME" || { print -u2 -- "错误: 账号名只能包含字母、数字、点、下划线、连字符。"; exit 1; }
    print -r -- "$ROOT/$NAME"
    ;;

  add)
    [[ -n "$NAME" ]] || { print -u2 -- "错误: 需要账号名，例如 ./accounts.sh add account3"; exit 1; }
    valid_name "$NAME" || { print -u2 -- "错误: 账号名只能包含字母、数字、点、下划线、连字符。"; exit 1; }
    if [[ -d "$ROOT/$NAME" ]]; then
      print -r -- "档案 $NAME 已存在: $ROOT/$NAME"
    else
      ensure_dir "$NAME" || exit 1
      print -r -- "✓ 已创建空档案 $NAME: $ROOT/$NAME"
    fi
    print -r -- "下一步: ./accounts.sh use $NAME && ./launch $NAME（启动后登录该账号）"
    ;;

  use)
    [[ -n "$NAME" ]] || { print -u2 -- "错误: 需要账号名，例如 ./accounts.sh use account2"; exit 1; }
    valid_name "$NAME" || { print -u2 -- "错误: 账号名只能包含字母、数字、点、下划线、连字符。"; exit 1; }
    ensure_dir "$NAME" || exit 1
    print -r -- "$NAME" > "$CURRENT" || { print -u2 -- "错误: 无法写入 $CURRENT"; exit 1; }
    chmod 600 "$CURRENT" 2>/dev/null
    print -r -- "✓ 默认账号已设为 $NAME ($ROOT/$NAME)"
    has_login "$NAME" && print -r -- "  该档案已有登录态，可直接启动" || print -r -- "  该档案是空的，启动后需要登录一次"
    ;;

  import-current)
    [[ -n "$NAME" ]] || { print -u2 -- "错误: 需要目标档案名，例如 ./accounts.sh import-current account1"; exit 1; }
    valid_name "$NAME" || { print -u2 -- "错误: 账号名只能包含字母、数字、点、下划线、连字符。"; exit 1; }
    if [[ ! -f "$DEFAULT_DATA/Cookies" ]] || ! strings "$DEFAULT_DATA/Cookies" 2>/dev/null | grep -q 'sessionKey'; then
      print -u2 -- "错误: 默认数据目录里没有检测到登录态（sessionKey）。请先登录，再执行导入。"
      exit 1
    fi
    # 导入时 Claude 应已完全退出，否则数据库可能正在被写入
    if pgrep -x Claude >/dev/null 2>&1; then
      print -u2 -- "警告: Claude 正在运行，复制到的登录态可能不是最新。建议先 ⌘Q 完全退出。"
    fi
    ensure_dir "$NAME" || exit 1
    target="$ROOT/$NAME"
    n=0
    for f in "${LOGIN_FILES[@]}"; do
      if [[ -f "$DEFAULT_DATA/$f" ]]; then
        cp -p "$DEFAULT_DATA/$f" "$target/" && n=$((n+1))
      fi
    done
    for d in "${LOGIN_DIRS[@]}"; do
      if [[ -d "$DEFAULT_DATA/$d" ]]; then
        mkdir -p "$target/$d"
        cp -Rp "$DEFAULT_DATA/$d/." "$target/$d/" && n=$((n+1))
      fi
    done
    print -r -- "✓ 已把默认目录的登录态导入 $NAME（$n 项，$target）"
    print -r -- "  刻意未复制 ant-did / 机器码 / 缓存，该档案会生成自己的设备 ID。"
    print -r -- "下一步: ./accounts.sh use $NAME && ./launch $NAME（先完全退出 Claude）"
    ;;

  *)
    print -u2 -- "未知命令: $CMD"
    usage
    exit 1
    ;;
esac

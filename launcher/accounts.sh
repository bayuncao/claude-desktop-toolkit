#!/bin/zsh
# accounts.sh — 管理 Claude Desktop 的独立账号档案
#
# 每个档案就是一个完整的 Electron userData 目录：登录态、机器码、缓存彼此隔离。
# 切换账号 = 指定另一个档案目录启动，不再是在同一个目录里登出/登入互相覆盖。
#
# 用法:
#   ./accounts.sh list                    列出所有档案及状态（含登录邮箱）
#   ./accounts.sh use <name>              切换默认账号：显示目标邮箱，输入 Y 后才执行；
#                                         成功后自动显示全部档案最新额度（同目录 usage.sh）
#   ./accounts.sh add <name>              新建空档案（稍后在其中登录）
#   ./accounts.sh email <name>            输出该档案的登录邮箱
#   ./accounts.sh import-current <name>  把「当前默认目录的登录态」导入指定档案
#   ./accounts.sh status                  显示当前账号、路径与邮箱
#   ./accounts.sh path <name>             输出档案绝对路径
#   ./accounts.sh --help
#
# 切换确认:
#   交互终端 → 打印「当前 → 目标」的邮箱，读取 stdin，仅 Y/y 放行。
#   非交互环境（cron / 脚本 / Agent 代执行）→ 默认拒绝；
#   确已在别处确认时，显式设置 ACCOUNTS_CONFIRM=Y 才放行。
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

# 读取档案里的登录邮箱（account.email_address，明文存于 claude.ai 的 IndexedDB）。
# 纯 shell：strings 把二进制转成可打印行 → 优先定位 email_address 字段 →
# 退化到「出现次数最多的邮箱」。不依赖 python3 / sqlite3。
# 空档案或读不到时返回非 0 且无输出。
profile_email() {
  local name="$1" dir="$ROOT/$1/IndexedDB" e=""
  [[ -d "$dir" ]] || return 1
  local files=( "$dir"/**/*(N.) )
  [[ ${#files[@]} -gt 0 ]] || return 1
  e="$(strings -a "${files[@]}" 2>/dev/null \
       | grep -A3 -m1 'email_address' \
       | grep -aoE '[A-Za-z0-9._%+_-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,10}' \
       | head -1)"
  if [[ -z "$e" ]]; then
    # 退化：只扫 claude.ai 的 IndexedDB，登录邮箱出现频次远高于其他地址；
    # 不做域名黑名单过滤，避免误伤真实邮箱。
    e="$(strings -a "${files[@]}" 2>/dev/null \
         | grep -aoE '[A-Za-z0-9._%+_-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,10}' \
         | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')"
  fi
  [[ -n "$e" ]] && print -r -- "$e"
}

# 切换前确认目标邮箱。仅在确认通过后才允许产生任何副作用。
# 非交互（无 TTY）时必须显式设置 ACCOUNTS_CONFIRM=Y，否则拒绝 —— 避免静默失败。
confirm_switch() {
  local cur="$1" cur_mail="$2" target="$3" target_mail="$4" ans=""
  print -r -- ""
  print -r -- "即将切换 Claude Desktop 账号档案："
  print -r -- "  当前: ${cur:-<默认目录>}  ${cur_mail:-（未检测到邮箱）}"
  print -r -- "  目标: $target  ${target_mail:-（未检测到邮箱 / 空档案）}"
  print -r -- ""
  if [[ ! -t 0 ]]; then
    if [[ "${ACCOUNTS_CONFIRM:-}" != "Y" && "${ACCOUNTS_CONFIRM:-}" != "y" ]]; then
      print -u2 -- "错误: 非交互环境无法读取确认输入，已取消切换（未做任何更改）。"
      print -u2 -- "      请在终端直接运行本命令并输入 Y；若已在别处确认，可设置 ACCOUNTS_CONFIRM=Y。"
      return 2
    fi
    print -r -- "  [非交互] ACCOUNTS_CONFIRM=Y，确认通过"
    return 0
  fi
  print -n -r -- "是否切换到邮箱 ${target_mail:-（该档案未检测到邮箱）}？输入 Y 确认，其他任意输入取消（60 秒无输入自动取消）: "
  # -t 60：有 TTY 但无人输入（自动化 / 挂起的终端）时不能无限等待，超时按取消处理
  IFS= read -r -t 60 ans || ans=""
  print -r -- ""
  if [[ "$ans" != "Y" && "$ans" != "y" ]]; then
    print -r -- "已取消，未做任何更改。"
    return 1
  fi
  return 0
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
  print -r -- "  list                    列出所有档案、登录态、邮箱（★ = 当前默认）"
  print -r -- "  use <name>              切换默认账号：显示目标邮箱，输入 Y 后才执行"
  print -r -- "  add <name>              新建空档案，稍后在其中登录"
  print -r -- "  email <name>            输出该档案的登录邮箱"
  print -r -- "  import-current <name>   把当前默认数据目录的登录态导入档案"
  print -r -- "  status                  显示当前账号、路径与邮箱"
  print -r -- "  path <name>             输出档案绝对路径"
  print -r -- ""
  print -r -- "非交互切换: ACCOUNTS_CONFIRM=Y ./accounts.sh use <name>"
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
    printf "%-12s %-12s %-34s %-8s %s\n" "档案" "登录态" "邮箱" "大小" "备注"
    printf "%-12s %-12s %-34s %-8s %s\n" "----" "------" "----" "----" "----"
    found=0
    for d in "$ROOT"/*(N/); do
      n="${d:t}"
      sz="$(du -sh "$d" 2>/dev/null | awk '{print $1}')"
      if has_login "$n"; then st="已保存"; else st="空 / 未登录"; fi
      em="$(profile_email "$n")"
      mark=""; [[ "$n" == "$cur" ]] && mark="★ 当前默认"
      printf "%-12s %-12s %-34s %-8s %s\n" "$n" "$st" "${em:-（未检测到）}" "${sz:-0}" "$mark"
      found=1
    done
    [[ "$found" -eq 1 ]] || print -r -- "（还没有任何档案，用 ./accounts.sh add <name> 创建）"
    ;;

  status)
    cur="$(read_current)"
    if [[ -z "$cur" ]]; then
      print -r -- "未设置默认账号：启动将使用 Claude 默认数据目录。用 ./accounts.sh use <name> 设置。"
    else
      em="$(profile_email "$cur")"
      print -r -- "当前账号: $cur"
      print -r -- "档案路径: $ROOT/$cur"
      print -r -- "登录邮箱: ${em:-（未检测到 / 空档案）}"
      has_login "$cur" && print -r -- "登录态:   已保存" || print -r -- "登录态:   无（需在该档案里登录一次）"
    fi
    ;;

  path)
    [[ -n "$NAME" ]] || { print -u2 -- "错误: 需要账号名。"; exit 1; }
    valid_name "$NAME" || { print -u2 -- "错误: 账号名只能包含字母、数字、点、下划线、连字符。"; exit 1; }
    print -r -- "$ROOT/$NAME"
    ;;

  email)
    [[ -n "$NAME" ]] || { print -u2 -- "错误: 需要账号名，例如 ./accounts.sh email account2"; exit 1; }
    valid_name "$NAME" || { print -u2 -- "错误: 账号名只能包含字母、数字、点、下划线、连字符。"; exit 1; }
    [[ -d "$ROOT/$NAME" ]] || { print -u2 -- "错误: 档案 $NAME 不存在。"; exit 1; }
    em="$(profile_email "$NAME")"
    if [[ -n "$em" ]]; then
      print -r -- "$em"
    else
      print -u2 -- "档案 $NAME 中未检测到邮箱（空档案或尚未登录）。"
      exit 1
    fi
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
    cur="$(read_current)"
    if [[ "$NAME" == "$cur" ]]; then
      print -r -- "$NAME 已经是当前默认账号，无需切换。"
      exit 0
    fi
    # 运行中只影响「下次启动」，提前告知，避免误以为窗口会立刻变
    if pgrep -x Claude >/dev/null 2>&1; then
      print -r -- "注意: Claude 正在运行；本次只修改「下次启动的默认账号」，当前窗口不受影响。"
      print -r -- "      要立即切换，请先完全退出 Claude 后从启动器重新打开。"
    fi
    cur_mail=""; [[ -n "$cur" ]] && cur_mail="$(profile_email "$cur")"
    target_mail="$(profile_email "$NAME")"
    confirm_switch "$cur" "$cur_mail" "$NAME" "$target_mail"; rc=$?
    [[ "$rc" -eq 0 ]] || exit "$rc"
    # 确认通过后才产生副作用
    ensure_dir "$NAME" || exit 1
    print -r -- "$NAME" > "$CURRENT" || { print -u2 -- "错误: 无法写入 $CURRENT"; exit 1; }
    chmod 600 "$CURRENT" 2>/dev/null
    print -r -- "✓ 默认账号已设为 $NAME（${target_mail:-未检测到邮箱}）→ $ROOT/$NAME"
    has_login "$NAME" && print -r -- "  该档案已有登录态，可直接启动" || print -r -- "  该档案是空的，启动后需要登录一次"
    # 切换成功后自动显示全部档案的最新额度（usage.sh 只读，不产生副作用；
    # 查询失败不影响切换结果，仅提示手动执行）
    SCRIPT_DIR="${0:A:h}"
    if [[ -x "$SCRIPT_DIR/usage.sh" ]]; then
      print -r -- ""
      print -r -- "=== 全部账号最新额度 ==="
      out="$(CLAUDE_ACCOUNTS_DIR="$ROOT" "$SCRIPT_DIR/usage.sh" 2>&1)"
      if print -r -- "$out" | grep -q 'HTTP 000'; then
        out="$(CLAUDE_ACCOUNTS_DIR="$ROOT" "$SCRIPT_DIR/usage.sh" 2>&1)"
      fi
      if print -r -- "$out" | grep -q 'HTTP 000'; then
        print -r -- "$out"
        print -r -- "（部分档案查询失败，可稍后手动执行: $SCRIPT_DIR/usage.sh）"
      else
        print -r -- "$out"
      fi
    fi
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

#!/bin/zsh
# usage.sh — 查询每个账号档案的 Claude 用量额度（5 小时 / 7 天窗口）
#
# 每个档案的 OAuth token 存在 config.json 的 oauth:tokenCacheV2（v10 加密）。
# 本脚本在本机解密后直接请求 api.anthropic.com/api/oauth/usage，
# 只输出「已用百分比 + 重置时间」，不写文件、不打印 token、不改动任何档案。
#
# 用法:
#   ./usage.sh                        查询全部已登录档案
#   ./usage.sh account2 account4      只查指定档案
#   ./usage.sh --json                 输出 JSON（便于脚本处理）
#   ./usage.sh --no-proxy             直连，不走代理
#   ./usage.sh http://127.0.0.1:7890 临时指定代理
#   ./usage.sh --help
#
# 代理优先级: http(s):// 参数 > USAGE_PROXY / CLAUDE_PROXY 环境变量
#             > ~/.claude-proxy/proxy.env 的 PROXY= > 直连
# 档案目录:   CLAUDE_ACCOUNTS_DIR 或 ~/.claude-accounts
# 依赖:       python3, openssl, curl, security（macOS）
#             Keychain 项 "Claude Safe Storage" 需可读（Claude 登录过后才有）
#
# ⚠️ API 只返回百分比与重置时间，不返回「还能发多少条」的绝对上限：
#    Claude 的 5 小时限制按 token 与模型动态计算，官方不公开数值上限。
# ⚠️ 解密出的 token 等同账号凭据，绝不写入仓库、日志或分享给他人。

set -u
ROOT="${CLAUDE_ACCOUNTS_DIR:-$HOME/.claude-accounts}"
CONFIG_FILE="$HOME/.claude-proxy/proxy.env"

help() {
  print -r -- "用法: ./usage.sh [选项] [档案名 ...]"
  print -r -- ""
  print -r -- "  (无参数)          查询全部已登录档案的 5 小时 / 7 天用量"
  print -r -- "  account2 ...      只查指定档案"
  print -r -- "  --json            输出 JSON"
  print -r -- "  --no-proxy        直连，不走代理"
  print -r -- "  http://host:port  临时指定代理"
  print -r -- "  --help            显示本帮助"
  print -r -- ""
  print -r -- "代理优先级: 参数 > USAGE_PROXY/CLAUDE_PROXY > ~/.claude-proxy/proxy.env > 直连"
  print -r -- "档案目录:   CLAUDE_ACCOUNTS_DIR 或 $ROOT"
  print -r -- "依赖:       python3, openssl, curl, security；Keychain 'Claude Safe Storage'"
  print -r -- ""
  print -r -- "只提供已用百分比与重置时间；Claude 不公开绝对条数上限。"
}

PROXY=""; NOPROXY=0; JSON_OUT=0; NAMES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help|help) help; exit 0 ;;
    --json) JSON_OUT=1 ;;
    --no-proxy) NOPROXY=1 ;;
    *://*) [[ -z "$PROXY" ]] && PROXY="$1" ;;
    -*) print -u2 -- "错误: 未知选项 $1"; exit 1 ;;
    *) NAMES+=("$1") ;;
  esac
  shift
done

for c in python3 openssl curl security; do
  command -v "$c" >/dev/null 2>&1 || {
    print -u2 -- "错误: 缺少依赖 $c（macOS 上 python3 随 Xcode Command Line Tools 提供）"
    exit 1
  }
done
[[ -d "$ROOT" ]] || { print -u2 -- "错误: 档案目录不存在: $ROOT"; exit 1; }

if [[ "$NOPROXY" -eq 1 ]]; then
  PROXY=""
else
  [[ -n "$PROXY" ]] || PROXY="${USAGE_PROXY:-${CLAUDE_PROXY:-}}"
  if [[ -z "$PROXY" && -r "$CONFIG_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in PROXY=*) PROXY="${line#PROXY=}" ;; esac
    done < "$CONFIG_FILE"
    PROXY="${PROXY//\"/}"
  fi
fi

export USAGE_ROOT="$ROOT" USAGE_PROXY="$PROXY"
export USAGE_JSON="$JSON_OUT" USAGE_NAMES="${(j: :)NAMES}"

python3 - <<'PY'
import os, sys, json, base64, hashlib, subprocess, glob, re
from datetime import datetime, timezone, timedelta
from collections import Counter

ROOT = os.environ["USAGE_ROOT"]
PROXY = os.environ.get("USAGE_PROXY", "")
JSON_OUT = os.environ.get("USAGE_JSON") == "1"
NAMES = os.environ.get("USAGE_NAMES", "").split()
CN = timezone(timedelta(hours=8))
API = "https://api.anthropic.com/api/oauth/usage"

def fail(msg):
    print("错误: " + msg, file=sys.stderr)
    sys.exit(1)

def get_key():
    # Chromium/Electron OSCrypt on macOS: the Keychain string is used verbatim
    # (do NOT base64-decode it), PBKDF2-HMAC-SHA1(saltysalt, 1003, 16).
    try:
        pw = subprocess.check_output(
            ["security", "find-generic-password", "-s", "Claude Safe Storage", "-w"],
            stderr=subprocess.DEVNULL).strip()
    except Exception as e:
        fail("无法读取 Keychain 'Claude Safe Storage'（Claude 需至少登录过一次）: %s" % e)
    return hashlib.pbkdf2_hmac("sha1", pw, b"saltysalt", 1003, 16)

def decrypt_v10(b64, key):
    try:
        raw = base64.b64decode(b64)
    except Exception:
        return None
    if raw[:3] != b"v10":
        return None
    r = subprocess.run(
        ["openssl", "enc", "-d", "-aes-128-cbc", "-K", key.hex(), "-iv", "20" * 16],
        input=raw[3:], capture_output=True)
    if r.returncode != 0:
        return None
    # Plaintext is JSON, sometimes prefixed by a 32-byte SHA256(host_key) tag.
    for buf in (r.stdout, r.stdout[32:]):
        try:
            t = buf.decode("utf-8")
        except Exception:
            continue
        i = t.find("{")
        if i >= 0:
            try:
                return json.loads(t[i:])
            except Exception:
                pass
    return None

def pick_token(cache):
    # Keys look like: acct:<accountUuid>|...:<orgUuid>:https://api.anthropic.com:<scopes>
    # Prefer the entry whose scope list includes user:sessions:claude_code.
    best, best_score = None, -1
    for k, v in cache.items():
        if not isinstance(v, dict):
            continue
        tok = v.get("token")
        if not isinstance(tok, str) or len(tok) < 20:
            continue
        score = len(k) + (10000 if "user:sessions:claude_code" in k else 0)
        if score > best_score:
            best, best_score = tok, score
    return best

EMAIL_RE = rb"[A-Za-z0-9][A-Za-z0-9._%+-]*@[A-Za-z0-9.-]+\.[A-Za-z]{2,10}"
# 页面文案/厂商域名里的占位地址，不是登录邮箱
BAD_EMAIL_RE = re.compile(
    rb"@(?:example\.(?:com|org|net)|anthropic\.(?:com|ai)|claude\.ai|"
    rb"sentry\.io|google\.com|gstatic\.com|w3\.org|schema\.org)$", re.I)

def _scan(patterns, budget):
    """按给定 glob 读入文件内容（单文件 <8MB，总量受 budget 限制），返回拼接后的二进制。"""
    blob = b""
    for pat in patterns:
        for f in glob.glob(pat, recursive=True):
            if not os.path.isfile(f):
                continue
            try:
                if os.path.getsize(f) > 8 * 1024 * 1024:
                    continue
                blob += open(f, "rb").read()
            except Exception:
                pass
            if len(blob) > budget:
                return blob
    return blob

def _clean(cand):
    return bool(cand) and not BAD_EMAIL_RE.search(cand)

def _pick_frequent(blob):
    if not blob:
        return ""
    found = [e for e in re.findall(EMAIL_RE, blob.replace(b"%40", b"@")) if _clean(e)]
    if not found:
        return ""
    return Counter(e.decode() for e in found).most_common(1)[0][0]

MARKED_RE = re.compile(
    rb"(?:email_address|emailAddress|email)[^A-Za-z0-9]{0,4}"
    rb"([A-Za-z0-9._%+-]{2,}@[A-Za-z0-9.-]+\.[A-Za-z]{2,10})", re.I)

def _pick_marked(blob):
    """只取紧跟在 email= / email_address 标记后的地址：命中率最高、噪声最小。"""
    if not blob:
        return ""
    for m in MARKED_RE.finditer(blob.replace(b"%40", b"@")):
        cand = m.group(1)
        if _clean(cand):
            return cand.decode()
    return ""

def profile_email(d):
    # account.email_address 在 IndexedDB 里可能被分块压缩截断（"xxx@g" + "x.com"），
    # 此时退回 Cache：同一地址会以 %40 编码出现在 login_methods 等请求里。
    # 三级策略：IndexedDB 频次 → Cache 标记 → Cache 频次。
    email = _pick_frequent(_scan([os.path.join(d, "IndexedDB", "**", "*")], 24 * 1024 * 1024))
    if email:
        return email
    cache_pats = [
        os.path.join(d, "Cache", "Cache_Data", "*"),
        os.path.join(d, "Local Storage", "**", "*"),
        os.path.join(d, "Session Storage", "**", "*"),
    ]
    blob = _scan(cache_pats, 24 * 1024 * 1024)
    return _pick_marked(blob) or _pick_frequent(blob)

def fetch(token):
    cmd = ["curl", "-sS", "-m", "18"]
    if PROXY:
        cmd += ["-x", PROXY]
    cmd += ["-H", "Authorization: Bearer " + token,
            "-H", "anthropic-beta: oauth-2025-04-20",
            "-H", "accept: application/json",
            "-w", "\n__HTTP__%{http_code}", API]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except Exception as e:
        return None, "请求失败: %s" % e
    if "__HTTP__" not in r.stdout:
        return None, (r.stderr.strip() or "无响应")[:120]
    body, code = r.stdout.rsplit("\n__HTTP__", 1)
    if code.strip() != "200":
        return None, "HTTP " + code.strip()
    try:
        return json.loads(body), None
    except Exception as e:
        return None, "JSON 解析失败: %s" % e

def fmt_reset(s):
    if not s:
        return "—", "—"
    try:
        t = s.replace("Z", "+00:00")
        try:
            dt = datetime.fromisoformat(t)
        except ValueError:
            dt = datetime.fromisoformat(re.sub(r"\.\d+", "", t))
        dt = dt.astimezone(CN)
        sec = (dt - datetime.now(CN)).total_seconds()
        if sec > 0:
            h, m = int(sec // 3600), int((sec % 3600) // 60)
            left = ("%d小时%d分" % (h, m)) if h else ("%d分钟" % m)
        else:
            left = "已过期"
        # Resets are reported as ...:59.7 — round to the nearest minute for display.
        return (dt + timedelta(seconds=30)).strftime("%m-%d %H:%M"), left
    except Exception:
        return (s or "")[:16], "—"

def pct(obj):
    if not isinstance(obj, dict):
        return None
    v = obj.get("utilization")
    return None if v is None else float(v)

K = get_key()

targets = []
if NAMES:
    for n in NAMES:
        d = os.path.join(ROOT, n)
        if os.path.isdir(d):
            targets.append((n, d))
        else:
            print("警告: 档案 %s 不存在" % n, file=sys.stderr)
else:
    targets = [(os.path.basename(d), d)
               for d in sorted(glob.glob(os.path.join(ROOT, "*")))
               if os.path.isdir(d)]

rows = []
for name, d in targets:
    cfg = os.path.join(d, "config.json")
    if not os.path.isfile(cfg):
        continue                                  # empty / never signed in
    try:
        c = json.load(open(cfg))
    except Exception:
        continue
    cache = c.get("oauth:tokenCacheV2")
    if not cache:
        continue
    email = profile_email(d)
    j = decrypt_v10(cache, K)
    if not j:
        rows.append(dict(profile=name, email=email, error="token 解密失败")); continue
    tok = pick_token(j)
    if not tok:
        rows.append(dict(profile=name, email=email, error="无可用 token")); continue
    data, err = fetch(tok)
    if err:
        rows.append(dict(profile=name, email=email, error=err)); continue
    fh = data.get("five_hour") or {}
    sd = data.get("seven_day") or {}
    rows.append(dict(profile=name, email=email,
                     five_hour=pct(fh), five_hour_reset=fh.get("resets_at"),
                     seven_day=pct(sd), seven_day_reset=sd.get("resets_at"),
                     extra_usage=(data.get("extra_usage") or {}).get("is_enabled"),
                     error=None))

if JSON_OUT:
    print(json.dumps(rows, ensure_ascii=False, indent=2))
    sys.exit(0)

if not rows:
    print("没有可查询的已登录档案（都需要先在档案里登录一次）。")
    sys.exit(0)

def w(s):
    return sum(2 if ord(ch) > 127 else 1 for ch in str(s))

def pad(s, n):
    s = str(s)
    return s + " " * max(0, n - w(s))

head = ("档案", "邮箱", "5小时", "重置(北京)", "剩余", "7天", "7天重置", "状态")
cols = (12, 34, 8, 14, 11, 7, 14, 16)
print(" ".join(pad(h, n) for h, n in zip(head, cols)))
print(" ".join(pad("-" * n, n) for n in cols))
for r in rows:
    if r.get("error"):
        cells = (r["profile"], r.get("email") or "—", "—", "—", "—", "—", "—", r["error"])
    else:
        t5, l5 = fmt_reset(r.get("five_hour_reset"))
        t7, _ = fmt_reset(r.get("seven_day_reset"))
        u5, u7 = r.get("five_hour"), r.get("seven_day")
        if u5 is None:
            state = "无数据"
        elif u5 >= 100:
            state = "已用满"
        elif u5 == 0:
            state = "可用(未使用)"
        else:
            state = "可用"
        cells = (r["profile"], r.get("email") or "—",
                 ("%.0f%%" % u5) if u5 is not None else "—",
                 t5, l5,
                 ("%.0f%%" % u7) if u7 is not None else "—",
                 t7, state)
    print(" ".join(pad(c, n) for c, n in zip(cells, cols)))

print("")
print("代理: %s" % (PROXY or "直连"))
print("时间均为北京时间 (UTC+8)；百分比为已用比例。")
print("Claude 不公开绝对条数上限，只能给出百分比与重置时间。")
PY

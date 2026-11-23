# claude-desktop-toolkit

> [简体中文](README.md) | English

A small set of tools for maintaining the local Claude Desktop environment on macOS:

- **Full reset**: remove local data, caches and the device identifier in one command, so the app starts from a clean state
- **Launch with a pinned proxy**: start Claude Desktop through an explicitly configured proxy, independent of the macOS system proxy switch
- **Separate account profiles**: give each account its own user-data directory, so sign-in state and device IDs stay isolated and switching accounts never overwrites another

The original `/Applications/Claude.app` is never modified — its code signature and auto-update stay intact.

> **Nothing machine-specific is hardcoded in this repo.** The proxy address, the Claude install path and account names all come from your own configuration. Run `launcher/setup.sh` once before first use.

## Files

| Path | Description |
| --- | --- |
| `clean-claude.sh` | Zero-argument cleanup script |
| `launcher/launch` | Launcher: pinned proxy + optional account profile (reads configuration; no hardcoded values) |
| `launcher/setup.sh` | One-shot setup: writes the config and assembles a double-clickable `.app` |
| `launcher/accounts.sh` | Account profile manager: add / switch (shows target email, requires confirmation; after switching, automatically shows every profile's latest usage) / import / show status & email |
| `launcher/usage.sh` | Usage query: 5-hour / 7-day utilisation and reset times for every profile |
| `launcher/Info.plist` | Bundle definition for the wrapper app (generic values; see below) |

The config file `~/.claude-proxy/proxy.env` and the account profiles `~/.claude-accounts/` are created on your machine by the scripts and are **not part of the repo**.

## Can I run it right after cloning?

| Script | Works right after clone | Notes |
| --- | --- | --- |
| `clean-claude.sh` | ✅ Yes | No config, no arguments: `./clean-claude.sh` |
| `launcher/launch` | ❌ Needs one-time setup | Config is external; without `~/.claude-proxy/proxy.env` it exits with a clear error. Run `./launcher/setup.sh` first |
| `launcher/setup.sh` | ✅ Yes | Generates the config and assembles the `.app` |
| `launcher/accounts.sh` | ✅ Yes | `list` / `add` / `status` / `email` work with no config; `use` shows the target email and asks for `Y` before switching, then automatically calls the sibling `usage.sh` to show every profile's latest usage (a failed lookup does not affect the switch) |
| `launcher/usage.sh` | ✅ Yes | No config; needs `python3` and a Claude sign-in on this Mac (Keychain key) |

This is a deliberate trade-off: the repo does not bake in anyone's proxy address or install path, so the launcher needs to be configured once. After that, everyday use is still zero-argument. Git preserves the executable bit (`100755`) on the scripts, so `./` works directly after cloning.

> If you download a ZIP instead of using `git clone`, some systems may drop the executable bit. On `Permission denied`, run `zsh clean-claude.sh` or `zsh launcher/setup.sh` instead — same result. `setup.sh` runs `chmod +x` itself when assembling the `.app`, so it is unaffected.

**Shortest path for a new user**:

```bash
git clone https://github.com/bayuncao/claude-desktop-toolkit.git && cd claude-desktop-toolkit
./launcher/setup.sh                              # once only
open "$HOME/Applications/Claude (Proxy).app"      # launch with the pinned proxy afterwards
./clean-claude.sh                                 # run whenever a reset is needed
```

For multiple accounts, add one line: `./launcher/accounts.sh use account2` (it shows the target email and asks for `Y`; see section 3).

## 1. Full reset

```bash
./clean-claude.sh
```

No arguments, no confirmation prompt. It immediately:

1. Gracefully quits a running Claude (aborts if Claude cannot be quit)
2. Clears the preferences cache (`defaults delete com.anthropic.claudefordesktop`)
3. Moves all data, caches, logs and preferences into `~/.Trash` using unique names with a timestamp and PID (no overwrites)
4. Re-scans for leftovers and reports the result

**Impact**: you will be signed out and local sessions are lost; the next launch generates a new device identifier and requires signing in again. Data stays in the Trash and can be dragged back to restore it — empty the Trash only once you are satisfied, to reclaim disk space.

The script builds paths from `$HOME`, so it works from any location, and never calls `rm`. Note that it cleans the **default Claude data directory**, not the profiles in `~/.claude-accounts/`.

## 2. Launch with a pinned proxy

### Quick start (for other Mac users)

```bash
./launcher/setup.sh          # interactive: detects the proxy port and Claude path, press Enter to accept
open "$HOME/Applications/Claude (Proxy).app"
```

`setup.sh` will:

- Scan common local HTTP proxy ports (7890 / 7897 / 7892 / 8080 / 8888 / 1087 / 6152) and offer the result as a **suggestion** — press Enter or type your own address
- Locate Claude Desktop, with an option to specify the path manually
- Write `~/.claude-proxy/proxy.env` (mode 600)
- Assemble `~/Applications/Claude (Proxy).app`, handling the icon, ad-hoc signing and the quarantine attribute
- Optionally `--account NAME`: create that profile and make it the default

Non-interactive usage:

```bash
./launcher/setup.sh --proxy http://127.0.0.1:7897 \
                    --claude /Applications/Claude.app/Contents/MacOS/Claude \
                    --account account1
```

### Configuration (no hardcoded values)

`launch` resolves values in this order — **it does not guess, auto-scan, or follow the system proxy**:

| Kind | Priority | Method | Example |
| --- | --- | --- | --- |
| Proxy | 1 | First `http(s)://` argument | `./launch http://127.0.0.1:7897` |
| Proxy | 2 | Environment variable | `CLAUDE_PROXY=http://127.0.0.1:7897 ./launch` |
| Proxy | 3 | Config file | `~/.claude-proxy/proxy.env` |
| Account | 1 | First plain argument | `./launch account2` |
| Account | 2 | Environment variable | `CLAUDE_ACCOUNT=account2 ./launch` |
| Account | 3 | `~/.claude-accounts/current` | written by `accounts.sh use` (asks to confirm the target email) |
| Claude binary | — | `CLAUDE_BIN` / config file; auto-detected if unset | — |

A proxy URL and an account name can be passed together (in any order); remaining arguments are forwarded to Claude unchanged. **When no account is configured, Claude's default data directory is used**, preserving the original behavior.

Format for creating the config file manually:

```zsh
# ~/.claude-proxy/proxy.env
PROXY="http://127.0.0.1:7897"
CLAUDE_BIN="/Applications/Claude.app/Contents/MacOS/Claude"
```

**If no proxy address is configured, `launch` exits with an error** instead of silently using a default. Once configured, everyday launches take no arguments.

### What the configuration sets

| Where | Purpose |
| --- | --- |
| `--proxy-server` / `--proxy-bypass-list` | Electron / Chromium network stack |
| `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` (plus lowercase) | Code / MCP child processes |
| `NO_PROXY` | `localhost,127.0.0.1,::1,.local` connect directly |
| `--user-data-dir` + `CLAUDE_USER_DATA_DIR` | When an account is selected, points to `~/.claude-accounts/<name>/` |

### Run directly (no `.app` needed)

```bash
./launcher/launch                # default account (or Claude's default directory)
./launcher/launch account2       # temporarily select an account
CLAUDE_PROXY=... ./launcher/launch account2
```

Once configured, it behaves the same from any directory.

### About `Info.plist`

`CFBundleIdentifier`, `LSMinimumSystemVersion` and `NSHighResolutionCapable` are generic values with no machine-specific information. The only external dependency is the icon referenced by `CFBundleIconFile`: the repo ships no icon file (to avoid bundling third-party assets), so `setup.sh` copies one from your local Claude.app. If it cannot be found, the key is removed and the app launches fine with the default system icon.

If you assemble the app manually, take the icon from your own installation:

```bash
APP="$HOME/Applications/Claude (Proxy).app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp launcher/launch "$APP/Contents/MacOS/launch"
cp launcher/Info.plist "$APP/Contents/Info.plist"
cp /Applications/Claude.app/Contents/Resources/electron.icns "$APP/Contents/Resources/" 2>/dev/null
chmod +x "$APP/Contents/MacOS/launch"
xattr -cr "$APP"
open "$APP"
```

If macOS says the app "cannot be opened because it is from an unidentified developer", run `xattr -cr "$APP"` (`setup.sh` already does this automatically).

## 3. Separate account profiles

There is only one default data directory: signing out of A and into B there simply replaces the session in that directory, and A's sign-in state is gone. Account profiles solve this with **separate user-data directories** — one per account, no overwrites, and each generates its own device identifier (`ant-did`).

### How it works

At launch, Electron receives `--user-data-dir=<profile>` and `CLAUDE_USER_DATA_DIR` is exported to the same directory. Claude Desktop then reads and writes `Cookies`, `config.json`, `Local Storage`, `IndexedDB` and all other data there. Sign-in state is encrypted (macOS Keychain `Claude Safe Storage`), so a profile **only works on the same Mac, for the same user**.

### Common commands

```bash
./launcher/accounts.sh list                    # list profiles, sign-in state, email, current default (★)
./launcher/accounts.sh add account3            # create an empty profile (sign in later)
./launcher/accounts.sh use account3            # switch default: shows target email, requires Y; auto-shows usage after success
./launcher/accounts.sh email account3          # print that profile's sign-in email
./launcher/accounts.sh status                  # current account, path and email
./launcher/accounts.sh path account3           # print the profile's absolute path
./launcher/accounts.sh import-current account1 # rescue an account already signed in to the default dir
```

The email is read live from `account.email_address` inside the profile's `IndexedDB` using plain shell (no python3), never stored in the repo and requiring no extra config file. `list` / `status` / `email` all show it; an empty profile shows "not detected".

### Switch confirmation

`use` is the only command that rewrites the default account, so every switch first shows the **current → target** emails and waits for confirmation:

```
About to switch Claude Desktop account profile:
  current: account3  alice@example.com
  target:  account2  bob@example.com

Switch to bob@example.com? Enter Y to confirm, anything else cancels:
```

- Only `Y` / `y` proceeds. `N`, a bare Enter, or anything else cancels **with no side effects** (`current` is not written, no profile directory is created). If a TTY exists but nobody answers, it cancels after 60 seconds instead of hanging forever.
- **Non-interactive environments** (cron, scripts, called by another program) are **rejected by default**, so a `read` hitting EOF cannot silently pass. When confirmation has already been obtained elsewhere, set the variable explicitly:
  ```bash
  ACCOUNTS_CONFIRM=Y ./launcher/accounts.sh use account2
  ```
- Switching to the already-current profile returns immediately without asking.
- Switching to an empty profile (no email) still requires confirmation and honestly says "not detected", preventing an accidental switch to a profile that was never signed in.

> Note: confirmation only covers `accounts.sh use` (day-to-day switching of the default). Two paths skip it: **one-off launches** with an explicit argument such as `./launch account2` / `CLAUDE_ACCOUNT=account2` (they neither ask nor write `current`), and `setup.sh --account` writing the initial default during **first-time setup** (the profile is empty at that point).

### Correct flow for adding a new account

```bash
# ① Fully quit Claude: ⌘Q or right-click the Dock icon → Quit
#    (closing the window or signing out of the account is NOT enough)
./launcher/accounts.sh use account3            # shows the target email, enter Y to confirm
# ② Launch with the profile
open "$HOME/Applications/Claude (Proxy).app"     # or ./launcher/launch account3
# ③ Sign in inside that window — credentials are written to the account3 profile
```

From then on, always open that account via the `Claude (Proxy)` launcher (or `./launcher/launch account3`), and **do not click the original `Claude` icon in the Dock** (that returns to the default directory). Fully quit Claude before switching, otherwise Electron's single-instance behavior ignores the new `--user-data-dir`.

`import-current` is the rescue path: if an account is already signed in to the default directory, it copies `Cookies`, `config.json`, `Local Storage`, `Session Storage`, `IndexedDB` and the other sign-in files into the named profile (deliberately excluding `ant-did` / caches / logs, so the profile generates its own device ID). Quit Claude fully first so the databases are flushed to disk.

### Profile layout

```
~/.claude-accounts/
├── current              # plain text, default profile name (mode 600)
├── account1/            # one complete user-data directory (mode 700)
├── account2/
└── ...
```

> ⚠️ **Profiles contain Cookies and OAuth tokens — they are equivalent to account credentials.** Never commit them, upload them to cloud storage, or share them. The repo's `.gitignore` excludes `.claude-accounts/`-style directories. The cleanup script `clean-claude.sh` does not delete profile directories.

## 4. Usage limits per account

`launcher/usage.sh` lists the **5-hour / 7-day utilisation, reset time and countdown** for every profile, so you can tell which account still has quota:

```bash
./launcher/usage.sh                        # all profiles
./launcher/usage.sh account2 account4      # only these profiles
./launcher/usage.sh --json                 # JSON output for scripting
./launcher/usage.sh --no-proxy             # direct connection, no proxy
./launcher/usage.sh http://127.0.0.1:7890  # one-off proxy override
```

Example (times in UTC+8; placeholder emails):

```
Profile    Email                 5h     Reset (UTC+8)  Left       7d    7d reset      Status
account2   alice@example.com     100%   11-20 20:40   9 min      27%   11-24 23:00  Exhausted
account3   bob@example.com       100%   11-21 00:00   3h29m      27%   11-23 00:00  Exhausted
account4   carol@example.com     0%     —             —          14%   11-26 16:00  Available
```

**How it works**: each profile's `config.json` holds `oauth:tokenCacheV2` (v10-encrypted). The script decrypts it locally with the Keychain `Claude Safe Storage` key, then calls `https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer` and `anthropic-beta: oauth-2025-04-20`. It **deliberately avoids `claude.ai/api/organizations/.../usage`**, which is blocked by a Cloudflare challenge, while `api.anthropic.com` is not. The token stays in memory — never written to disk, printed, or committed.

- Proxy precedence: `http(s)://` argument > `USAGE_PROXY` / `CLAUDE_PROXY` env vars > `PROXY=` in `~/.claude-proxy/proxy.env` > direct
- Empty profiles (never signed in, no `oauth:tokenCacheV2`) are skipped; override the profile root with `CLAUDE_ACCOUNTS_DIR`
- Requires `python3` / `openssl` / `curl` / `security` and the `Claude Safe Storage` Keychain item (Claude must have been signed in at least once)
- Read-only: does not modify profiles, switch accounts, or affect a running Claude

> ⚠️ **Only the used percentage and reset time are available** — not an absolute "messages remaining" number. Claude's 5-hour limit is computed dynamically from tokens and models, and the API does not expose a numeric cap.

## Requirements and caveats

- macOS + Claude Desktop installed + a working `http://` / `https://` local proxy (Clash / mihomo / Surge, etc.; use your own port)
- **Fully quit Claude first** (⌘Q): Electron's single-instance behavior will ignore the proxy and account arguments if Claude is already running
- The proxy is pinned: if it is unreachable, requests fail — **there is no fallback to a direct connection**. Requests fail rather than bypassing the proxy, so the main traffic does not expose your real IP, but Claude becomes unusable whenever the proxy is down
- App update checks and pages opened in the system browser still follow the OS proxy settings and are not covered here
- SOCKS URLs and URLs with embedded credentials are not supported; if your proxy requires authentication, run a local forwarding proxy (e.g. Cntlm / Px) and point to that instead
- Account profiles are unrelated to system-level hardware identifiers (IOPlatformUUID); Claude's device recognition relies mainly on the local ID files inside each profile
- At startup, `launch` warns if the proxy port is unreachable, but does not block the launch
- `usage.sh` additionally needs `python3` / `openssl` / `curl` / `security` and the `Claude Safe Storage` Keychain item; it only reads profiles and changes nothing

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `Error: proxy address not configured` | Run `./launcher/setup.sh`, or create `~/.claude-proxy/proxy.env` manually |
| `Claude Desktop executable not found` | Specify the full path via `--claude`, `CLAUDE_BIN`, or the config file |
| `Warning: proxy ... is unreachable` | Start your proxy software or fix the port; Claude will be offline while the proxy is down |
| Proxy arguments not applied | ⌘Q to fully quit Claude, then launch again from `Claude (Proxy)` |
| Still the old account after switching / sign-in state overwritten | Usually launched from the original Dock icon, or Claude was not fully quit; use `./launcher/launch <name>` and check `accounts.sh status` |
| New profile asks you to sign in again | The profile is empty, which is expected; sign in once inside it and the state is saved there |
| `import-current` says no sign-in state | No `sessionKey` in the default directory; sign in first, then import |
| `use` says "non-interactive environment cannot read confirmation" | Scripts / cron / programmatic calls never pass silently; run in a terminal and enter `Y`, or set `ACCOUNTS_CONFIRM=Y` when already confirmed |
| `use` says "email not detected" | The target profile is empty or not signed in yet; you can still enter `Y` to switch there and sign in |
| `usage.sh`: "cannot read Keychain 'Claude Safe Storage'" | Claude has never been signed in on this Mac, or Keychain access was denied; sign in once in Claude Desktop |
| `usage.sh`: one profile shows `HTTP 401` | That profile's OAuth token expired; open it once with `./launcher/launch <name>` to refresh the sign-in |
| `usage.sh`: everything shows "no response" / `HTTP 000` | Proxy is down or the port is wrong; try `--no-proxy`, or pass `http://host:port` |
| App blocked by Gatekeeper | `xattr -cr "$HOME/Applications/Claude (Proxy).app"` |
| Config change has no effect | Config is read at launch; quit Claude and start it again |

## Privacy

The repo contains no credentials or machine-specific values: scripts use `$HOME` rather than hardcoded usernames, and the proxy address lives in `~/.claude-proxy/proxy.env`, while account profiles live in `~/.claude-accounts/` — all on your machine, outside the repo (`.gitignore` also excludes same-named directories inside the repo). The email shown during switch confirmation is read live from the local profile's `IndexedDB` at runtime and **never written into the repo** (all documentation examples use placeholder addresses). The OAuth token decrypted by `usage.sh` stays in process memory — never written to disk, printed, or logged; its output contains only utilisation percentages and reset times. Account profiles contain sign-in credentials; sharing them publicly may also violate the terms of the services involved. Make sure your usage complies with those terms and your local regulations.

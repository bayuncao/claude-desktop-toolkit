# claude-desktop-toolkit

macOS 上维护 Claude Desktop 本地环境的一组小工具：

- **彻底清理**：一键移除本地数据、缓存与设备标识，让应用以全新状态启动
- **固定代理启动**：不依赖系统代理开关，用你显式配置的代理地址启动 Claude Desktop

原版 `/Applications/Claude.app` 不会被修改，签名与自动更新保持完整。

> **仓库内不含任何机器特定的硬编码值**：代理地址、Claude 安装路径都由使用者自己的配置提供。第一次使用请先运行 `launcher/setup.sh`。

## 文件

| 路径 | 说明 |
| --- | --- |
| `clean-claude.sh` | 零参数清理脚本 |
| `launcher/launch` | 代理启动脚本（读取配置，不含硬编码值） |
| `launcher/setup.sh` | 一键生成配置并组装可双击的 `.app` |
| `launcher/Info.plist` | wrapper app 的 bundle 定义（通用值，见下方说明） |

配置文件 `~/.claude-proxy/proxy.env` 由 `setup.sh` 生成，属于本机文件，不进仓库。

## 能否直接使用

| 脚本 | clone 后直接运行 | 说明 |
| --- | --- | --- |
| `clean-claude.sh` | ✅ 可以 | 零配置、零参数：`./clean-claude.sh` |
| `launcher/launch` | ❌ 需先配置一次 | 配置外置，没有 `~/.claude-proxy/proxy.env` 会明确报错退出；先运行 `./launcher/setup.sh` |
| `launcher/setup.sh` | ✅ 可以 | 一次性生成配置并组装 `.app` |

这是刻意的取舍：仓库不写死任何人的代理地址或安装路径，所以启动器需要先配置一次；配置完成后，日常使用仍是零参数。git 会保留三个脚本的可执行位（mode `100755`），clone 后可直接 `./` 执行。

> 通过 GitHub 下载 ZIP 而不是 `git clone` 时，个别系统可能丢失可执行位；遇到 `Permission denied` 改用 `zsh clean-claude.sh` / `zsh launcher/setup.sh` 执行即可，效果相同。`setup.sh` 组装 `.app` 时会自行 `chmod +x`，不受影响。

**新用户最短路径**：

```bash
git clone https://github.com/bayuncao/claude-desktop-toolkit.git && cd claude-desktop-toolkit
./launcher/setup.sh                              # 只需一次
open "$HOME/Applications/Claude (Proxy).app"      # 之后固定代理启动
./clean-claude.sh                                 # 需要清理时随时执行
```

## 1. 彻底清理

```bash
./clean-claude.sh
```

无参数、无确认，直接执行：

1. 优雅退出正在运行的 Claude（退不掉则中止）
2. 清除偏好设置缓存（`defaults delete com.anthropic.claudefordesktop`）
3. 把数据、缓存、日志、偏好等全部移入 `~/.Trash`（带时间戳与 PID 的唯一名字，不会覆盖）
4. 复查残留并输出结果

**影响**：会退出登录、丢失本地会话；下次启动会生成新的设备标识，需要重新登录。数据保留在废纸篓，可随时拖回还原，确认无误后再清空废纸篓释放空间。

脚本只使用 `$HOME` 拼接路径，放在任何位置都能运行；全程不调用 `rm`。

## 2. 固定代理启动

### 快速开始（其他 Mac 用户）

```bash
./launcher/setup.sh          # 交互式：探测代理端口与 Claude 路径，回车确认即可
open "$HOME/Applications/Claude (Proxy).app"
```

`setup.sh` 会：

- 扫描本机常见 HTTP 代理端口（7890 / 7897 / 7892 / 8080 / 8888 / 1087 / 6152），把探测结果作为**建议值**，你可直接回车或输入自己的地址
- 定位 Claude Desktop，允许手动指定路径
- 生成 `~/.claude-proxy/proxy.env`（权限 600）
- 组装 `~/Applications/Claude (Proxy).app`，自动处理图标、ad-hoc 签名与 quarantine

非交互式用法：

```bash
./launcher/setup.sh --proxy http://127.0.0.1:7897 \
                    --claude /Applications/Claude.app/Contents/MacOS/Claude
```

### 配置方式（无硬编码）

`launch` 按以下优先级取值，**不会猜测、不会自动扫描、不会跟随系统代理**：

| 优先级 | 方式 | 示例 |
| --- | --- | --- |
| 1 | 第一个参数 | `./launch http://127.0.0.1:7897` |
| 2 | 环境变量 | `CLAUDE_PROXY=http://127.0.0.1:7897 ./launch` |
| 3 | 配置文件 | `~/.claude-proxy/proxy.env`（由 setup.sh 生成） |
| 4 | Claude 路径 | 未配置时自动探测常见安装位置，也可用 `CLAUDE_BIN` 覆盖 |

手动创建配置文件的格式：

```zsh
# ~/.claude-proxy/proxy.env
PROXY="http://127.0.0.1:7897"
CLAUDE_BIN="/Applications/Claude.app/Contents/MacOS/Claude"
```

**未提供代理地址时 `launch` 会直接报错退出**，不会偷偷使用某个默认值。配置一次后，日常启动仍是零参数。

### 配置会设置什么

| 位置 | 用途 |
| --- | --- |
| `--proxy-server` / `--proxy-bypass-list` | Electron / Chromium 网络栈 |
| `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY`（含小写） | Code / MCP 等子进程 |
| `NO_PROXY` | `localhost,127.0.0.1,::1,.local` 直连 |

### 直接运行（无需组装 .app）

```bash
./launcher/launch
```

配置好之后，从任意目录执行效果相同；也可以直接用 `CLAUDE_PROXY=... ./launcher/launch` 临时换代理。

### 关于 `Info.plist`

文件里的 `CFBundleIdentifier`、`LSMinimumSystemVersion`、`NSHighResolutionCapable` 都是通用值，不含机器信息。唯一的外部依赖是 `CFBundleIconFile` 指向的图标：仓库不含图标文件（避免打包第三方资源），`setup.sh` 会从你本机的 Claude.app 复制；取不到时自动移除该键，app 用系统默认图标，仍可正常启动。

若手动组装，图标取自你自己的安装包：

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

从网络下载仓库后若提示「无法打开，因为来自身份不明的开发者」，执行 `xattr -cr "$APP"` 即可（`setup.sh` 已自动处理）。

## 前提与注意

- macOS + 已安装 Claude Desktop + 一个可用的 `http://` / `https://` 本地代理（Clash / mihomo / Surge 等均可，端口按你的实际配置）
- **启动前必须完全退出 Claude**（⌘Q）：Electron 单实例机制下，已运行时再启动会忽略代理参数
- 固定代理是硬指定：代理不可达时请求直接失败，**不会回退直连**；请求失败而非绕行，主流量不会因此暴露真实 IP，但代理一挂 Claude 就不可用
- 应用更新检查、系统浏览器打开的登录页等仍跟随系统代理，不受本配置约束
- 不支持 SOCKS URL 与带账号密码的 URL；需要认证时请在本机跑一个转发代理（如 Cntlm / Px）再指向它
- `launch` 启动时会检查代理端口是否可达并给出警告，但不会阻止启动

## 故障排查

| 现象 | 处理 |
| --- | --- |
| `错误: 未配置代理地址` | 运行 `./launcher/setup.sh`，或手动创建 `~/.claude-proxy/proxy.env` |
| `找不到 Claude Desktop 可执行文件` | 用 `--claude` / `CLAUDE_BIN` / 配置文件指定完整路径 |
| `警告: 代理 ... 当前不可达` | 启动代理软件，或改配置里的端口；代理没开时 Claude 会断网 |
| 代理参数没生效 | 先 ⌘Q 完全退出 Claude，再从 `Claude (Proxy)` 启动 |
| app 被 Gatekeeper 拦截 | `xattr -cr "$HOME/Applications/Claude (Proxy).app"` |
| 改了配置没变化 | 配置在启动时读取，退出 Claude 后重新启动即可 |

## 隐私

仓库内不含任何凭据或机器特定值：脚本使用 `$HOME`，不硬编码用户名；代理地址由使用者写入自己用户目录下的 `~/.claude-proxy/proxy.env`，该文件不在仓库内，不会被提交（`.gitignore` 另排除了仓库内同名目录）。请自行确保使用方式符合所用服务的条款与所在地法规。

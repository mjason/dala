# dala MCP 服务器

让 AI 助手（Claude Code、Claude Desktop 等）通过 [MCP（Model Context
Protocol）](https://modelcontextprotocol.io) 直接驱动 dala 的**服务端设置和终端会话**：
定义主题、配置语音，以及在显式授权后读取、等待和控制终端。

传输方式为 **Streamable HTTP**：在 dala 已有的 Phoenix 端口上暴露一个
`POST /mcp`，用 JSON-RPC 2.0 通信，单个 `application/json` 响应体（无 SSE）。
无状态（不需要 `Mcp-Session-Id`）。请求须带 `Content-Type: application/json`
（MCP 客户端默认如此）；其它 content-type 会被当成解析失败返回 `-32700`。

---

## 1. 安全模型

- **默认关闭 + 强制令牌，fail-closed（失败即关）。** 见下方“启用”。
- **只绑定回环地址。** dala 默认 `DALA_LISTEN_IP=127.0.0.1`，`/mcp` 只对本机可达。
  AI 助手本来就跑在这台机器上，无需对外暴露。
- **令牌由服务器生成，显示在 UI 里。** 令牌不再来自环境变量，而是由服务器随机生成
  （高熵、url-safe，≥ 32 字符）并存在数据库里；它显示在**设置面板的 MCP 标签**中，
  可一键复制、可随时重生成。它**不是** `sensitive?` 字段——Web UI 就是控制面板，
  必须能显示它。这没有削弱安全边界：Web UI 本身已是登录鉴权 + 只绑回环，能打开面板
  的人本就掌控这台机器。令牌本身**绝不写进日志或响应体**。
- **共享 / 全局 actor 模型。** 所有工具动作都以 `actor: nil` 运行，也就是写入
  “全局 / 共享”那一份设置（`owner_id` = 全零哨兵 uuid）。这与 dala 在**关闭登录**
  时“大家共用 `user_id nil` 那一行”的设计一致：**AI 创建的主题是全局的，所有设备
  都能看到**。
- **绝不外泄敏感字段。** 结果只序列化资源的“公开且非 `sensitive?`”属性；语音 API
  key 是私有 + 敏感字段，任何工具结果里都**不会**出现它的值（只会返回
  `api_key_set: true/false`）。
- **MCP 无法自管。** 管理 MCP 开关、终端权限与令牌的 rpc 动作（`mcp_settings` /
  `set_mcp_enabled` / `set_mcp_terminal_access` / `regenerate_mcp_token`）**只暴露给 Web UI**，被显式排除在 MCP
  工具表之外——绝不让接在 `/mcp` 上的 AI 关掉自己、读取或轮换自己的令牌（提权 /
  自锁的脚枪）。
- **终端权限单独授权。** “读取终端”和“控制终端”默认都关闭；控制隐含读取。控制权限
  会让 bearer token 等价于远程 shell 凭据，只应对可信 agent 开启。工具发现和实际
  执行都会检查权限，不能靠缓存旧的 `tools/list` 绕过。
- **输出和附件有硬边界。** `wait_terminal` 是最多 25 秒的事件驱动长轮询，每会话最多
  8 个、全局最多 128 个等待者。MCP 附件解码后单个最多 64 MB、私有保存 24 小时，
  受管目录总容量默认 5 GB，并有上传速率限制。

三态门（`DalaWeb.Plugs.RequireMcp`），状态从数据库单例（`Dala.Settings.Mcp`）读取：

| 状态 | 结果 |
| --- | --- |
| MCP 未开（默认） | **404**——`/mcp` 当作不存在 |
| 已开、但存储的令牌为空（防御性，正常不会发生） | **503**——失败即关，首个 `/mcp` 请求到达时告警一次，拒绝每个请求 |
| 已开、缺少/错误的 `Authorization` | **401** |
| 已开、`Authorization: Bearer <token>` 正确 | 放行（常量时间比较） |

---

## 2. 启用

MCP 现在从 dala **设置面板的 MCP 标签**里开关开启/关闭——**无需改环境变量或重启**。
令牌由服务器生成并显示在同一面板上：

1. 打开 dala Web UI → 设置 → **MCP** 标签。
2. 打开开关即可启用 `/mcp`（关闭即 404，立刻生效）。
3. 按需打开“读取终端会话”或“控制终端会话”；不用终端能力时保持关闭。
4. 令牌就显示在面板上：**一键复制**粘贴进你的 MCP 客户端配置（见下一节），
   或点**重新生成**换一个新令牌（旧令牌立即失效）。

> 旧的 `DALA_MCP_ENABLED` / `DALA_MCP_TOKEN` 环境变量已移除，不再有效。

---

## 3. 客户端配置

下面示例里的端口 **4400** 是 release 默认端口（`DALA_PORT`）；开发环境默认 4000。
把它换成你的 dala 实际端口。示例中的 `<你的 DALA_MCP_TOKEN>` 占位符，填**设置面板
MCP 标签里显示的那个令牌**（点复制即可）。

### Claude Code（CLI）

```bash
claude mcp add --transport http dala http://127.0.0.1:4400/mcp \
  --header "Authorization: Bearer <你的 DALA_MCP_TOKEN>"
```

- `--transport http` 指定 Streamable HTTP。
- `--header`（可简写 `-H`）注入固定的鉴权头。
- 可加 `-s user`（或 `-s project`）改变作用域，默认 `local`。

或者直接写进项目根目录的 `.mcp.json`：

```json
{
  "mcpServers": {
    "dala": {
      "type": "http",
      "url": "http://127.0.0.1:4400/mcp",
      "headers": {
        "Authorization": "Bearer <你的 DALA_MCP_TOKEN>"
      }
    }
  }
}
```

用 `claude mcp list` / `/mcp` 确认连接成功。

### Claude Desktop（经 mcp-remote 桥接）

Claude Desktop 目前只吃 stdio MCP，用官方 `mcp-remote` 桥接到我们的 HTTP 端点。
编辑其 `claude_desktop_config.json`：

```json
{
  "mcpServers": {
    "dala": {
      "command": "npx",
      "args": [
        "-y",
        "mcp-remote",
        "http://127.0.0.1:4400/mcp",
        "--header",
        "Authorization: Bearer <你的 DALA_MCP_TOKEN>"
      ]
    }
  }
}
```

### Codex（OpenAI `codex` CLI）

写进 `~/.codex/config.toml`（或项目级 `.codex/config.toml`）：

```toml
[mcp_servers.dala]
url = "http://127.0.0.1:4400/mcp"
http_headers = { "Authorization" = "Bearer <你的 DALA_MCP_TOKEN>" }
```

想把令牌放环境变量里（更安全）就用 `bearer_token_env_var`（它会自动拼成
`Authorization: Bearer …`）：

```toml
[mcp_servers.dala]
url = "http://127.0.0.1:4400/mcp"
bearer_token_env_var = "DALA_TOKEN"
```

> ⚠️ **需要较新的 Codex。** 旧版本（约 2025 年底之前）的 streamable-HTTP 需要在
> `config.toml` 顶层加 `experimental_use_rmcp_client = true` 才能启用；若上面的写法连不
> 上，先补这一行再试，仍不行则退回本页末尾的 `mcp-remote` 桥接（用 `command`/`args`
> 形式）。

### OpenCode（`sst/opencode`）

写进项目根的 `opencode.json`，或全局 `~/.config/opencode/opencode.json`：

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "dala": {
      "type": "remote",
      "url": "http://127.0.0.1:4400/mcp",
      "enabled": true,
      "headers": {
        "Authorization": "Bearer <你的 DALA_MCP_TOKEN>"
      }
    }
  }
}
```

> OpenCode 对 remote 服务器默认会尝试 OAuth 发现；dala 用的是纯静态 Bearer 头，
> 如果 OAuth 探测干扰连接，给这个块加一行 `"oauth": false` 强制走纯头部认证。

### 任意只支持 stdio 的客户端（`mcp-remote` 兜底）

`mcp-remote` 是官方 npm 桥接器，把只会 stdio 的 MCP 客户端接到远程 HTTP 端点、代转
自定义头。上面三家现版本都**原生**支持远程 HTTP + Bearer，一般用不到它；只有客户端
不支持远程 HTTP 时才需要：

```bash
npx -y mcp-remote http://127.0.0.1:4400/mcp --header "Authorization: Bearer <你的 DALA_MCP_TOKEN>"
```

---

## 4. 工具列表

设置工具由 `Dala.Settings` 领域的 `typescript_rpc` 自动派生；终端工具显式注册，
避免把删除会话、文件系统写入等整个 Terminal 领域意外暴露出去。

| 工具 | 作用 |
| --- | --- |
| `theme_reference` | 完整能力参考：45 个 token 的用途、分组、亮/暗默认值，6 个内置预设、可执行操作和对比度规则。**定义主题前先调它一次。** |
| `preview_theme` | 不保存主题；接收 `theme_id`，或 `base` + 稀疏 `tokens`，返回完整 token、审查报告和标准 Dala 界面的 `image/png`。 |
| `list_themes` | 列出可见主题（内置预设 + 全局库，内置优先）。 |
| `get_theme` | 按 `id` 取单个主题（取不到返回 `null`，不是错误）。 |
| `create_theme` | 新建全局主题：`name`、`base`（`light`/`dark`）、`tokens`（稀疏颜色覆盖）。 |
| `update_theme` | 改自己的主题：`id` + 想改的字段。内置预设不可改。 |
| `delete_theme` | 删自己的主题（按 `id`）。内置预设不可删。 |
| `speech_settings` | 读语音设置（`endpoint`、`model`、`api_key_set`；**永不返回 key 本体**）。 |
| `set_speech_settings` | 写语音设置（`endpoint`、`model`、`api_key`、`clear_api_key`）。 |
| `list_terminal_sessions` | 列出会话 UUID、页面短引用（如 `#7F2A9C`）、名称、cwd、状态和当前 `seq`。 |
| `read_terminal` | 从 holder 网格读取文本；普通缓冲区含 scrollback，TUI 返回当前 alternate screen、光标、输入模式及反色/背景高亮区间。 |
| `wait_terminal` | 用 `after_seq` 等待输出、文本匹配、agent idle/question/permission/stop 或退出；最多 25 秒，可连续调用。 |
| `send_terminal_message` | 按 UUID、短引用或唯一名称发送正文、附件路径、Enter 或控制键；同会话请求串行，返回基线 `seq`。 |
| `send_terminal_keys` | 向 TUI 顺序发送最多 100 个安全按键；支持方向键、Home/End、PageUp/PageDown、Space、Tab/Shift-Tab、Enter/Esc、有限控制键，以及 `CHAR:y`、`CHAR:a` 形式的单字符快捷键。 |
| `terminal_upload_attachment` | 上传单个文件/图片到私有的 24 小时受管目录，返回绝对路径；解码后默认上限 64 MB。 |

附件二进制不会进入 PTY：先由 `terminal_upload_attachment` 落盘，随后
`send_terminal_message` 只把路径按 Claude/Codex/OpenCode/Gemini 对应的粘贴策略发送。
已有的服务器普通文件也可直接使用；目录和符号链接会被拒绝。

主题 `tokens` 是一个稀疏的 `键 -> CSS 颜色` 映射，一共 45 个槽位（UI 8 / Git 6 /
diff 5 / CodeMirror 5 / 终端 5 / ANSI 16）。**只写你要覆盖的槽位**，其余回退到
`base` 调色板。Git 六个状态槽位是 `gitAdded`、`gitModified`、`gitDeleted`、
`gitRenamed`、`gitUntracked`、`gitConflict`。
颜色只接受纯 CSS 颜色（`#rrggbb`、`rgb()/rgba()/hsl()/hsla()`、`transparent`），
`url(...)` 之类会在写入时被拒。追求可读对比度：正文 ≥ 4.5:1，UI 装饰 ≥ 3.0:1。
`theme_reference.tokenDefinitions` 会逐项说明颜色落在哪个界面区域，并同时给出基础亮色和
暗色默认值；`supportedOperations` 列出可读、预览和写入能力，因此不需要 Agent 猜测
“这个 MCP 到底能改什么”。

推荐的主题设计闭环：

```text
theme_reference
→ preview_theme
→ 根据 PNG 和 errors / warnings / suggestions 调整
→ 再次 preview_theme
→ create_theme / update_theme
```

`preview_theme` 的标准场景完全由服务端生成，不依赖浏览器、Chromium 或已经打开的
Dala 页面。场景只包含固定的虚构界面形状，不读取文件、终端和页面内容；Elixir 生成
SVG，独立 Rust `resvg/tiny-skia` 模块确定性转换为 PNG。预览不会写数据库。

### TUI 选择工作流

`read_terminal` 在 alternate screen 下额外返回 `highlightedRanges`：每项包含行、起止列、
文字、前景/背景以及 `inverse`/`bold`/`dim`。它表示终端中使用反色或非默认背景的可见
区域，通常就是当前选择、聚焦按钮或活动面板；不是由 Dala 猜出的业务语义，Agent 应
结合相邻文本判断。`inputModes.applicationCursor` 也会返回，`send_terminal_keys` 会据此
自动在普通 CSI 与 application-cursor SS3 方向键之间切换。

推荐操作顺序：

```text
read_terminal
→ 根据 highlightedRanges / cursor 确认当前项
→ send_terminal_keys {keys: ["DOWN", "CHAR:y"]}
→ wait_terminal（使用返回的 seq）
→ 再次 read_terminal 验证
```

这能覆盖键盘可操作的 TUI 选择。单字符快捷键必须写成 `CHAR:<字符>`，并且仅接受一个
可打印 ASCII 字符；空格使用 `SPACE`。当前没有开放任意鼠标坐标或原始字节注入，只接受
工具 schema 中列出的安全按键，避免 Agent 因转义序列错误破坏会话状态。旧 holder 会继续
返回纯文本，但 `styleAware: false`；重启对应会话后即可使用高亮和输入模式字段。

---

## 5. 示例提示词

关键：**明确说“用 dala MCP”**，否则 AI 可能把它当成普通的写代码任务，而不是去调工具。

**（a）定义一个暗色主题**

> 用 dala MCP，创建一个叫 “Midnight Ink” 的暗色主题：背景接近纯黑、正文是柔和的
> 冷白、强调色用青绿。先调 `theme_reference` 看清 token 词汇表，再用
> `preview_theme` 反复检查图片和审查报告，达标后再调 `create_theme`。

**（b）fork 一个内置预设再微调**

> 使用 dala MCP 服务器，基于内置的 Nord 主题创建一个新主题 “Nord Warm”：先
> `list_themes` 找到 Nord、复制它的 tokens，把强调色 `mint` 往暖一点调，其余保持
> 不变，然后 `create_theme` 存下来。

**（c）设置语音转写端点**

> 用 dala MCP，把语音设置的 `set_speech_settings` 端点设为
> `https://api.openai.com/v1/audio/transcriptions`、模型设为 `whisper-1`，并写入我
> 的 API key。写完再用 `speech_settings`确认 `api_key_set` 变成了 true。

### 示例对话（节选）

> **你：** 用 dala MCP 创建一个叫 “Midnight Ink” 的暗色主题。
>
> **助手：** 我先调 `theme_reference` 看看可用的 token 键和颜色规则……
> 拿到 45 个键和规则了。我先用 `preview_theme` 检查 `base: "dark"`，`tokens` 里设了
> `bg0: "#0a0a0f"`、`fg: "#e6e9f0"`、`mint: "#3dd7c0"`。PNG 中层级清晰，报告的
> 硬性检查全部通过；现在再用同一组参数调用 `create_theme`。
> ✅ 已创建，id 是 `c2b4…`。它是全局主题，你所有设备都能在主题列表里选到它。

---

## 附：内部实现坐标

- 运行时配置（开关 + 令牌，DB 单例）：`lib/dala/settings/mcp.ex`（`Dala.Settings.Mcp`）
- 门（读单例，从不落日志）：`lib/dala_web/plugs/require_mcp.ex`
- 控制器（JSON-RPC 2.0）：`lib/dala_web/controllers/mcp_controller.ex`
- 原始 body 读取（用于 `-32700`）：`lib/dala_web/mcp_body_reader.ex`
- 工具注册表（内省领域，**排除 `Dala.Settings.Mcp` 自管动作**）：`lib/dala/mcp/registry.ex`
- 执行器：`lib/dala/mcp/tools.ex`
- 主题解析、审查与固定 SVG：`lib/dala/settings/theme/{preview,audit,svg}.ex`
- 确定性 PNG 渲染 NIF：`native/dala_theme_renderer`（`resvg/tiny-skia`）
- 显式终端工具：`lib/dala/mcp/terminal_tools.ex`
- 纯文本快照与事件等待：`lib/dala/terminal/server.ex`、`native/dala_holder/src/screen.rs`
- 受管附件：`lib/dala/terminal/attachments.ex`
- 路由：`lib/dala_web/router.ex`（`:mcp` pipeline + `POST /mcp`）
- Web UI 用的 rpc 动作：`mcp_settings` / `set_mcp_enabled` /
  `set_mcp_terminal_access` / `regenerate_mcp_token`
  （见 `Dala.Settings` 的 `typescript_rpc`）

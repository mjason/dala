# Render mode：把 zellij 的渲染模型搬进 holder

调研分支：`zellij-render-mode`。源码依据是 zellij 本体
（`zellij-server/src/panes/grid.rs`、`zellij-server/src/screen.rs`、
`zellij-server/src/output/mod.rs`、`zellij-client/src/lib.rs`）。

## zellij 的模型

**客户端是一根哑管子。** `zellij-client/src/lib.rs:1375` 收到 `Render(output)`
之后只做一件事：`stdout.write_all(...)`，前后包一层 `\x1b[?2026h` / `?2026l`。
没有解析、没有状态机、没有输入闸门。

**服务端的 Grid 自己回答设备查询。** `grid.rs:4925` 起，DSR/CPR/DECREQTPARM/
`CSI 18 t` 全在服务端答掉，回复推进 `pending_messages_to_pty` 直接写回 PTY。
查询字节根本不离开服务器。答不出来的（`CSI 14t`/`16t` 窗口像素、`CSI ?996n`
主题模式）走 `ForwardQueryToHost { token, query_bytes }`，客户端替它问宿主终端、
带 token 把答案送回来 —— 每一条查询都有明确归属。

**渲染是 10ms 去抖 + 脏行 diff + 只发视口。** `screen.rs:3884` 调度背景 job
去抖；`OutputBuffer`（`output/mod.rs:1748`）只序列化 `changed_lines`；新客户端
attach 或切 tab 时 `render_full_viewport()` 重发整屏。滚动是**服务端**操作
（`grid.rs:1354`），视口大小不变，历史永远不过网。

结论：zellij 的字节量上界是「视口 × 帧率」，恒定；dala 转发原始 PTY 字节，
上界是程序**写了多少**。

## 搬了什么

### 1. holder 独家回答设备查询（`d26db73`、`ae86097`）

alacritty 靠 `Event::PtyWrite` 报告 DA1/DA2、CPR、DECRQM、kitty keyboard、
text-area size。dala 的监听器原来叫 `Quiet`，一个不落全丢了 —— 唯一能答的是
浏览器，查询要走一整圈 websocket 出去、xterm 自动回包、再当普通输入送回来。
每次 2×RTT；detach 之后压根没人答。

现在收进 `Responder`，并且答复和转发**一起决定**：holder 答掉的那条查询，
同时从客户端看到的流里摘掉，所以永远只有一份答案。详见下面第 1 条尾巴。

这一条与 render mode 无关，兜底模式下同样生效。

### 2. alternate screen 的增量帧（`7f8aaa8`、`5ce9f65`）

`Screen::alt_frame` + `FrameTracker`：绝对行寻址，只发渲染结果真正变了的行。
10ms tick，和 zellij 同一个数。帧只是 ANSI 字节，进的还是原来那个 ring，
所以 Elixir、channel、seq/dedup、ack 流控整条下游一行没改。

实测：300 次重绘同一行，render mode 收到 <10 份，关掉收到 300 份。

## 没搬什么，为什么

**普通缓冲区继续走原始字节流。** 这不是偷懒：

- alt 是固定网格，没有 scrollback、没有软换行的逻辑行，逐行 diff 无损；而这
  三样正是 dala 的本地滚动、选中、搜索赖以存在的东西 —— zellij 干脆不向客户端
  提供它们（它的滚动是服务端操作），dala 提供，所以不能照抄。
- 普通缓冲区的输出本来就是追加式的、字节已经很省；给它做 diff 反而更费
  （每行都要加 CUP 寻址）。
- 洪水都发生在 alt：claude code、vim、htop、lazygit。流控水位被顶爆的场景
  一个不落全在这边。

交接由 `normal_resync_frame()` 完成，**进出 alt 都不发 RIS** —— RIS 会连
客户端的 scrollback 一起清掉，进一次 vim 就没了历史；真实终端也不这么干。

**同步更新（DECSET 2026）没搬。** zellij 用它让客户端终端原子换帧；dala 目前
是「保留旧帧 + 单次写入」，等价效果，改造收益不大。

## 三条尾巴的处置

**1. 查询的 2×RTT —— 已消除。** holder 现在独家回答：答掉的那条查询同时从
客户端看到的流里摘掉，所以永远只有一份答案。归属不靠「alacritty 会答哪些」
的表，而是把流按 query 形状的序列切段逐段喂给模拟器、谁产生回复就归给谁；
认不出来的落进 `unattributed`，attach 时不发，退回旧行为让客户端答。扫描器
只认 `ESC [`、不认 C1 的 `0x9B`（那是合法的 UTF-8 后续字节，误判会删掉真实
文字）。

**2. 流控水位 —— 已按 BDP 缩放。** `Dala.Terminal.FlowWindow`：往返时间和
速率都从客户端本来就在发的 ack 里量出来，有效水位 = 基线 + 实测 BDP，
封顶 4 倍基线。往返取 ack 覆盖到的**最新**那个 marker（更老的大头是排队
不是往返），平滑系数压得低，一次 GC 停顿不足以重新定义链路。

**3. 浸泡 —— 转成了自动化覆盖，并且真挖出一个回归。**

alacritty 0.26 **不支持任何内联图形协议**（只有 kitty *键盘*，没有 kitty
graphics，没有 sixel）。render mode 下这意味着图形序列被解析、什么都没存下、
也永远不转发 —— 图片会**静默消失**。现在检测到 kitty APC `ESC _ G`、
iTerm2 `OSC 1337;` 或 sixel `DCS <数字> q` 就把该会话永久退回原始字节流；
交接在推进模拟器**之前**做，先把客户端同步到「本块之前」的画面再整块原样
转发，既不丢图也不会把这一块的文字应用两遍。（`DCS $q` DECRQSS 和
`DCS +q` XTGETTCAP 都以 q 结尾，明确排除。）

另外补了：`?2026` 同步更新块跨 tick 不会露出半张画面，且开了 `?2026h`
之后卡死的程序不会把客户端画面永久冻住（tick 上按 deadline 强制收尾）；
CJK 宽字符、组合符、emoji 走完整的重放比对；鼠标模式中途关闭要发 unset。

剩下的仍然是**真机时间**：这些都是单测和集成测试级别的信心，兜底开关就是
为此存在的。

## 延迟自适应：低延迟和高延迟要的是相反的东西

zellij 的 10ms 去抖是**尾沿**的：任何一次重绘都要多等 0–10ms 才离开 holder。
在 300ms 链路上这是噪声，在 localhost 上（往返 ~1ms）却是 5 倍。为了修高延迟
卡顿反而让低延迟变差，说不过去。

拆成两件事：

**前沿立即发。** 距上一帧已经超过一个窗口 → 说明这是一次**孤立**的变化
（vim 里一次按键的重绘，不是重绘循环），立刻发，零额外延迟，**任何延迟档位
都如此**。窗口只用来给连续重绘封顶。

**尾沿窗口跟着往返走。** `render_window(rtt)` = `clamp(rtt, 8ms, 50ms)`：

| 链路 | 窗口 | 理由 |
|---|---|---|
| localhost ~1ms | 8ms（≈120fps） | 带宽免费、人就在跟前，再攒只是白加延迟 |
| LAN 20ms | 20ms | 攒够一个往返的量刚好 |
| WAN 100ms+ | 50ms（20fps） | 每省一帧就是省在最稀缺的地方；再低就开始看着卡了 |

**延迟从哪来。** 复用 `FlowWindow` 已经在量的 ack 往返 —— 同一个测量，
两个用途：per-client 的水位管**带宽**，per-session 的帧窗口管**新鲜度**。
channel 每次 ack 上报，`Terminal.Server` 取所有**可见**客户端里的**最小值**
发给 holder（`T_LATENCY` 帧）。

取最小值是有意的：帧窗口是新鲜度预算，得迁就最先察觉到延迟的那个人；而慢客户端
的带宽已经由它自己那份 BDP 水位单独管着了。隐藏的预热终端不参与投票。上报做了
迟滞（变化不到五分之一就不发），否则每个 ack 都要写一次 socket。

## 没有开关，这是有意的

曾经有过一个 `terminal.renderMode` 配置项，作为「万一渲染出问题」的保险丝。
删掉了，理由是：

- **兜底路径本来就还在，而且一直被跑着。** 原始字节流承载着普通缓冲区，
  以及任何画过图的会话的 alternate screen（见上面第 3 条）。所以「留个开关
  免得那条路径烂掉」这个理由不成立 —— 它烂不了。
- **它是实现细节漏进了配置面。** 「增量帧还是原始字节流」不是用户能判断的
  产品选择，把它摆在 `port`、`auth.enabled` 旁边只会招人去调。
- 加配置项在这个项目里有固定代价（见 CLAUDE.md 的配置规则），而这一项的
  收益是时间有限的 —— 泡稳之后它就是纯负担，而「万一呢」会让它永远留着。

**代价说清楚：渲染出问题时没有当场恢复的开关了。** 自动回退只覆盖内联图形
协议（那个能探测）；「某个 TUI 画错了」探测不到，只有人能看出来。真遇到就是
报 issue + 回滚版本，而不是改一行配置。这是明知的取舍。

排障时想对比两条路径，改 `native/dala_holder/src/main.rs` 里那行
`let render_alt = !shared.graphics_seen && shared.screen.alt_screen();`
临时置 false 重编即可 —— 开发手段，不是产品面。

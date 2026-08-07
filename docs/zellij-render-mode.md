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

### 1. holder 自己回答设备查询（`d26db73`）

alacritty 靠 `Event::PtyWrite` 报告 DA1/DA2、CPR、DECRQM、kitty keyboard、
text-area size。dala 的监听器原来叫 `Quiet`，一个不落全丢了 —— 唯一能答的是
浏览器，查询要走一整圈 websocket 出去、xterm 自动回包、再当普通输入送回来。
每次 2×RTT；detach 之后压根没人答。

现在收进 `Responder`。谁来答由 PTY reader 决定，规则是「同一把锁下的同一个
标志」：client 在 → 字节会到浏览器，它会自动回包，我们答就是第二份，丢弃；
client 不在 → 字节本来就不进 transit 环，我们是仅存的模拟器，写回 PTY。

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

## 还没做的

1. **查询的 2×RTT 还在。** 现在只修了 detach 场景。要彻底消掉，得让 holder
   在转发流里把查询序列摘掉（它本来就逐字节 VTE 解析，知道 CSI 的确切边界），
   然后由 holder 独家回答。风险是和 alacritty 升级后的答复集合漂移，需要一张
   查询表配套测试。
2. **流控水位仍然是 RTT 盲的**（alt 128 KiB、normal 768 KiB）。高延迟链路上
   in-flight ≈ 带宽 × RTT 会把它误判成洪水。render mode 大幅降低了 alt 侧触发
   概率，但没有根治。前端现在有 `flowStats.echoMs`（自适应本地回显的测量），
   可以复用它按 BDP 缩放水位。
3. **需要真机浸泡。** 单测覆盖了「重放每一帧到真模拟器、逐步比对文本/样式/
   光标」，集成测试做过证伪，但 CJK 宽字符、sixel/kitty 图形、鼠标模式切换、
   `?2026` 同步更新块跨 tick 这些还只有单测级别的信心。

## 关掉

```jsonc
// ~/.config/dala/config.jsonc
{ "terminal": { "renderMode": false } }
```

或 `DALA_TERMINAL_RENDER_MODE=false`。回到每个旧版本 dala 的原始字节流，
holder 也随之退回「只有浏览器回答查询」。

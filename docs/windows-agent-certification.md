# Windows agent compatibility certification

Run this checklist on Windows 10 1809+ or Windows 11 x64 before publishing a
server release. Automated project CI does not install third-party agents or
exercise authenticated workflows, so record the exact agent version for every
manual result.

CI covers the native holder transport, ConPTY shell behavior, process-tree
detection, packaged Scheduled Task installation, failed-update rollback,
successful cross-version reattachment and purge uninstall. This checklist
covers the third-party and authenticated behavior that automation deliberately
does not claim.

Record the Windows build, Dala commit, shell, agent version and result for each
row. Test both PowerShell 7 (when installed) and CMD. Use a project path that
contains spaces.

| Check | Claude Code | Codex CLI | OpenCode | Gemini CLI |
|---|---|---|---|---|
| Launcher is detected (`.exe` or npm `.cmd`) | | | | |
| Input, resize, color and alternate-screen rendering | | | | |
| `cd` updates Dala through OSC 7 | | | | |
| Text file and image attachment path with spaces | | | | |
| Completion / approval notification reaches Dala | OSC 777 plugin | OSC 9 | OSC 777 plugin | OSC 777 plugin |
| Agent remains detected while running git/build child processes | | | | |
| Dala restart and upgrade reattach to the same agent session | | | | |

Codex must additionally pass with its default sandbox and with the supported
elevated/unelevated combinations. Confirm automatic OSC 9 notification output;
repeat with explicit `notification_method = "osc9"`. Resolve or document any
compatibility regression before publishing the Windows release.

Dala must not edit any agent configuration during certification. Claude Code,
OpenCode and Gemini use the user-installed Warp integrations; Codex remains
plugin-free.

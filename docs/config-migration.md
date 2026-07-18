# Migrating from `dala.env` to `config.jsonc`

从 dala.env 迁移到 config.jsonc（中文说明在后半部分）。

## Why / 为什么

Dala used to be configured through environment variables in
`~/.config/dala/dala.env`. Every variable in the service's environment is
inherited by everything it starts — which is how configuration and secrets
can leak toward the shells dala spawns, and how ambient variables (for
example agent session markers) caused real bugs.

Since the config-file release, dala reads `~/.config/dala/config.jsonc`
instead, and generates its secrets itself (`<dataDir>/secrets.json`, 0600).
A migrated service process carries **no dala-specific environment
variables at all** — and once `config.jsonc` exists, dala ignores
environment variables entirely (they remain only as a development tool and
for unmigrated legacy installs).

If your sidebar footer shows a "config upgrade" notice, you are running in
legacy mode.

## One-command migration / 一键迁移

```sh
curl -fsSL https://raw.githubusercontent.com/mjason/dala/main/migrate-config.sh | bash
```

What it does — idempotent and reversible:

1. Reads your existing `~/.config/dala/dala.env`.
2. Moves the two secrets into `<dataDir>/secrets.json` (0600).
3. Writes an equivalent `~/.config/dala/config.jsonc`
   (`DALA_USERS` is deliberately **not** migrated: accounts already live in
   the database; the line only held a plaintext bootstrap password).
4. Renames `dala.env` to `dala.env.migrated-<timestamp>` (your backup).
5. Removes the `EnvironmentFile=` line from the systemd unit (Linux) —
   the macOS runner already ignores a missing env file.
6. Restarts the service and waits for it to come back healthy.

Roll back: restore the backup name, re-add `EnvironmentFile=` (Linux),
restart.

## Manual migration / 手动迁移

1. Create `~/.config/dala/config.jsonc` — key reference in the README's
   *Configuration reference* section. The old env names map 1:1:
   `PORT`→`port`, `DALA_LISTEN_IP`→`listenIp`, `PHX_HOST`→`host`,
   `PHX_CHECK_ORIGIN`→`checkOrigin`, `DATABASE_PATH`→`databasePath`,
   `DALA_DATA_DIR`→`dataDir`, `DALA_RELEASE_ROOT`→`releaseRoot`,
   `DALA_SERVICE`→`serviceName`, `DALA_AUTH_ENABLED`→`auth.enabled`.
2. Secrets: either copy `SECRET_KEY_BASE`/`TOKEN_SIGNING_SECRET` into
   `<dataDir>/secrets.json` as `secretKeyBase`/`tokenSigningSecret`
   (chmod 600), or delete them and let dala generate fresh ones on next
   boot — note fresh secrets sign out all sessions once.
3. Delete (or rename) `dala.env`; on Linux remove the `EnvironmentFile=`
   line from `~/.config/systemd/user/dala.service` and run
   `systemctl --user daemon-reload`.
4. Restart the service.

---

## 中文速览

- **为什么**：环境变量会被服务进程的所有子进程继承——配置和密钥可能泄漏进
  dala 打开的 shell。迁移后服务进程**不携带任何 dala 环境变量**；环境变量
  仅保留为开发用途的覆盖手段。
- **一键迁移**：运行上面的 `migrate-config.sh`。它把密钥挪进
  `<dataDir>/secrets.json`（0600）、把其余配置写成 `config.jsonc`、备份并
  停用 `dala.env`、清理 systemd 的 `EnvironmentFile` 行、重启并健康检查。
  全程幂等、可回滚（恢复备份文件名即可）。
- **`DALA_USERS` 不迁移**：账号早已入库，那一行只是首启引导的明文密码；
  需要重置密码时才在 `config.jsonc` 里临时加 `auth.users` + `usersReset`。
- 侧栏底部出现"配置方式已升级"提示 = 仍在旧模式运行。

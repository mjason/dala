# Migrating from `dala.env` to `config.jsonc`

从 dala.env 迁移到 config.jsonc（中文说明在后半部分）。

## Why / 为什么

Dala used to be configured through environment variables in
`~/.config/dala/dala.env` on Unix (see the Windows paths below). Every
variable in the service's environment is
inherited by everything it starts — which is how configuration and secrets
can leak toward the shells dala spawns, and how ambient variables (for
example agent session markers) caused real bugs.

Since the config-file release, dala reads `~/.config/dala/config.jsonc` on
Unix instead, and generates its secrets itself (`<dataDir>/secrets.json`,
mode 0600 on Unix and protected by the profile ACL on Windows).
A migrated service process carries **no dala-specific environment
variables at all** — and once `config.jsonc` exists, dala ignores
environment variables entirely (they remain only as a development tool and
for unmigrated legacy installs).

If your sidebar footer shows a "config upgrade" notice, you are running in
legacy mode.

## One-command migration (Linux and macOS) / 一键迁移（Linux 和 macOS）

> [!IMPORTANT]
> This command is not supported on Windows, including from Git Bash or WSL.
> The standard Windows install uses a per-user Scheduled Task and Windows
> profile directories; follow the Windows procedure below instead.

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

## Windows migration / Windows 迁移

Run the commands below from PowerShell as the same Windows user that runs Dala.
Administrator rights are not required for the standard per-user installation.
Do not run `migrate-config.sh` from Git Bash: its restart logic only supports
systemd and launchd.

### Choose the correct profile / 选择正确的账户目录

Dala resolves its configuration and data directories from the account that
runs the process:

| How Dala runs | Config directory | Default data directory |
| --- | --- | --- |
| Interactive or standard Scheduled Task | `%APPDATA%\Dala` | `%LOCALAPPDATA%\Dala\data` |
| Legacy custom Windows service | The service account's roaming profile | The service account's local profile |

The standard installer registers a Scheduled Task for the current interactive
user. It therefore reads the same config and data before and after installation.
Only old custom services running as `LocalSystem` need the system profile paths;
migrate those files into your user profile before replacing the service.

Windows paths inside JSON must use forward slashes (`C:/Users/...`) or escaped
backslashes (`C:\\Users\\...`).

### Migrate / 迁移

1. Stop the existing Dala process before changing its configuration. For the
   standard Scheduled Task:

   ```powershell
   $TaskName = "Dala"
   Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
   ```

   For a legacy custom service, use `Stop-Service`; for an interactive process,
   stop that process directly.

2. Select the current user's paths and create the directories:

   ```powershell
   $ConfigDir = Join-Path $env:APPDATA "Dala"
   $DataDir = Join-Path $env:LOCALAPPDATA "Dala\data"
   $LegacyEnv = Join-Path $ConfigDir "dala.env"
   $ConfigFile = Join-Path $ConfigDir "config.jsonc"

   New-Item -ItemType Directory -Force -Path $ConfigDir, $DataDir | Out-Null
   ```

3. Create `config.jsonc` using the mapping in the manual migration section.
   A minimal installed configuration looks like this; preserve any
   non-default values from `dala.env`:

   ```jsonc
   {
     "server": true,
     "port": 4400,
     "listenIp": "127.0.0.1",
     "host": "localhost",
     "checkOrigin": false,
     "dataDir": "C:/Users/you/AppData/Local/Dala/data",
     "releaseRoot": "C:/Users/you/AppData/Local/Dala",
     "serviceName": "Dala",
     "auth": { "enabled": false },
   }
   ```

   Open the destination selected above with:

   ```powershell
   notepad.exe $ConfigFile
   ```

4. Either copy `SECRET_KEY_BASE` and `TOKEN_SIGNING_SECRET` to
   `<dataDir>\secrets.json` as `secretKeyBase` and `tokenSigningSecret`, or
   omit the file and let Dala generate new secrets at startup. Generating new
   secrets signs out all existing sessions once. Do not migrate `DALA_USERS`.

   Windows does not use Unix `chmod 600`. Files created inside the selected
   profile inherit that profile's NTFS ACL. Check a manually created secrets
   file with:

   ```powershell
   icacls.exe (Join-Path $DataDir "secrets.json")
   ```

5. Back up the legacy file after `config.jsonc` and `secrets.json` are ready:

   ```powershell
   if (Test-Path -LiteralPath $LegacyEnv) {
     $Stamp = Get-Date -Format "yyyyMMddHHmmss"
     Move-Item -LiteralPath $LegacyEnv -Destination "${LegacyEnv}.migrated-${Stamp}"
   }
   ```

6. Start Dala and verify the configured port:

   ```powershell
   Start-ScheduledTask -TaskName $TaskName
   $Task = Get-ScheduledTask -TaskName $TaskName
   if ($Task.State -ne "Running") { throw "Dala task is $($Task.State)" }
   Invoke-RestMethod "http://127.0.0.1:4400/version"
   ```

   For an interactive installation, start it with the same launcher used
   before the migration.

### Roll back / 回滚

Stop Dala, rename `config.jsonc` so it is no longer active, restore the newest
`dala.env.migrated-*` backup to `dala.env`, and start Dala with the legacy
launcher that originally loaded that file. The Scheduled Task launcher does
not load `dala.env`, so restoring the filename alone is not enough when a
custom launcher previously imported those variables.

## Configuration mapping and manual migration / 配置映射与手动迁移

1. Create `~/.config/dala/config.jsonc` on Unix, or the `$ConfigFile` selected
   above on Windows. The key reference is in the README's _Configuration
   reference_ section. The old env names map 1:1:
   `PORT`→`port`, `DALA_LISTEN_IP`→`listenIp`, `PHX_HOST`→`host`,
   `PHX_CHECK_ORIGIN`→`checkOrigin`, `DATABASE_PATH`→`databasePath`,
   `DALA_DATA_DIR`→`dataDir`, `DALA_RELEASE_ROOT`→`releaseRoot`,
   `DALA_SERVICE`→`serviceName`, `DALA_AUTH_ENABLED`→`auth.enabled`.
2. Secrets: either copy `SECRET_KEY_BASE`/`TOKEN_SIGNING_SECRET` into
   `<dataDir>/secrets.json` as `secretKeyBase`/`tokenSigningSecret`
   (`chmod 600` on Unix; inherited profile ACL on Windows), or delete them and
   let dala generate fresh ones on next boot — note fresh secrets sign out all
   sessions once.
3. Delete (or rename) `dala.env`; on Linux remove the `EnvironmentFile=`
   line from `~/.config/systemd/user/dala.service` and run
   `systemctl --user daemon-reload`.
4. Restart the service.

---

## 中文速览

- **为什么**：环境变量会被服务进程的所有子进程继承——配置和密钥可能泄漏进
  dala 打开的 shell。迁移后服务进程**不携带任何 dala 环境变量**；环境变量
  仅保留为开发用途的覆盖手段。
- **Linux/macOS 一键迁移**：运行上面的 `migrate-config.sh`。Windows
  不能运行该脚本，应使用前述当前用户 PowerShell 步骤。脚本把密钥挪进
  `<dataDir>/secrets.json`（0600）、把其余配置写成 `config.jsonc`、备份并
  停用 `dala.env`、清理 systemd 的 `EnvironmentFile` 行、重启并健康检查。
  全程幂等、可回滚（恢复备份文件名即可）。
- **Windows 标准安装使用当前账户**：配置位于 `%APPDATA%\Dala`，数据默认
  位于 `%LOCALAPPDATA%\Dala\data`。安装器注册当前用户的 Scheduled Task，
  安装、迁移和任务控制均不需要管理员权限。只有旧的自定义 Windows 服务
  可能以 `LocalSystem` 运行；替换它之前，应先把 `systemprofile` 中的旧文件
  迁移到当前用户目录。
- **Windows 密钥权限**：没有 `chmod 600`；密钥文件继承账户配置目录的
  NTFS ACL，可用 `icacls.exe` 检查。
- **`DALA_USERS` 不迁移**：账号早已入库，那一行只是首启引导的明文密码；
  需要重置密码时才在 `config.jsonc` 里临时加 `auth.users` + `usersReset`。
- 侧栏底部出现"配置方式已升级"提示 = 仍在旧模式运行。

$ErrorActionPreference = "Stop"

$Root = if ($env:DALA_HOME) { $env:DALA_HOME } else { Split-Path -Parent $PSCommandPath }
$Root = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]"\/")
$MetadataFile = Join-Path $Root "install.json"

function Read-InstallMetadata([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

  try {
    $value = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($name in @("schemaVersion", "root", "dataDir", "configFile", "taskName", "port", "repo", "platform")) {
      if ($value.PSObject.Properties.Name -notcontains $name) { throw "required field '$name' is missing" }
    }
    if ([int]$value.schemaVersion -ne 1) { throw "unsupported schemaVersion" }
    foreach ($name in @("root", "dataDir", "configFile", "taskName", "repo", "platform")) {
      if ([string]::IsNullOrWhiteSpace([string]$value.$name)) { throw "field '$name' is empty" }
    }
    if ([int]$value.port -lt 1 -or [int]$value.port -gt 65535) { throw "invalid port" }
    if ([string]$value.platform -ne "windows-x86_64") { throw "unsupported platform" }
    if (-not ([IO.Path]::GetFullPath([string]$value.root).TrimEnd([char[]]"\/")).Equals(
        $Root, [StringComparison]::OrdinalIgnoreCase)) {
      throw "root does not match the runner location"
    }
    $value
  } catch {
    throw "Invalid Dala install metadata at $Path`: $($_.Exception.Message)"
  }
}

$metadata = Read-InstallMetadata $MetadataFile
$ConfigFile = if ($metadata) {
  [string]$metadata.configFile
} else {
  $env:DALA_CONFIG
}
if ([string]::IsNullOrWhiteSpace($ConfigFile)) {
  $ConfigFile = Join-Path $env:APPDATA "Dala\config.jsonc"
}
if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
  throw "Dala configuration is missing: $ConfigFile"
}
$ConfigFile = [IO.Path]::GetFullPath($ConfigFile)

# DALA_CONFIG is the only Dala setting the BEAM needs. Clear legacy config and
# secrets so neither the server nor shells spawned from it can inherit them.
foreach ($name in @(
  "DALA_HOME", "DALA_CONFIG", "DALA_DATA_DIR", "DALA_RELEASE_ROOT", "DALA_SERVICE",
  "DALA_UPDATE_REPO", "DALA_SERVER", "DALA_PORT", "DALA_LISTEN_IP", "DALA_HOST",
  "DALA_SCHEME", "DALA_URL_PORT", "DALA_CHECK_ORIGIN", "DALA_DATABASE_PATH", "DALA_POOL_SIZE",
  "DALA_AUTH_ENABLED", "DALA_USERS", "DALA_USERS_RESET", "DALA_SECRET_KEY_BASE",
  "DALA_TOKEN_SIGNING_SECRET", "DALA_TEXT_PREVIEW_DEFAULT_MB", "DALA_TEXT_PREVIEW_MAX_MB",
  "DALA_DRAWER_UPLOAD_MAX_MB", "DALA_BROWSER_ATTACHMENT_MAX_MB", "DALA_MCP_ATTACHMENT_MAX_MB",
  "DALA_ATTACHMENT_STORAGE_MAX_MB", "DALA_TEXT_SAVE_MAX_MB", "PHX_SERVER", "PHX_HOST",
  "PHX_SCHEME", "PHX_URL_PORT", "PHX_CHECK_ORIGIN", "PORT", "POOL_SIZE", "DATABASE_PATH",
  "SECRET_KEY_BASE", "TOKEN_SIGNING_SECRET", "DNS_CLUSTER_QUERY",
  "RELEASE_NAME", "RELEASE_VSN", "RELEASE_MODE", "RELEASE_NODE", "RELEASE_COOKIE",
  "RELEASE_TMP", "RELEASE_VM_ARGS", "RELEASE_REMOTE_VM_ARGS", "RELEASE_DISTRIBUTION",
  "RELEASE_BOOT_SCRIPT", "RELEASE_BOOT_SCRIPT_CLEAN", "RELEASE_SYS_CONFIG", "RELEASE_ROOT",
  "RELEASE_COMMAND", "RELEASE_PROG", "RELEASE_MUTABLE_DIR", "RELEASE_READ_ONLY",
  "ERL_FLAGS", "ERL_AFLAGS", "ERL_ZFLAGS", "ERL_LIBS", "ERL_INETRC", "ELIXIR_ERL_OPTIONS"
)) {
  [Environment]::SetEnvironmentVariable($name, $null, "Process")
}
[Environment]::SetEnvironmentVariable("DALA_CONFIG", $ConfigFile, "Process")

$tag = (Get-Content -LiteralPath (Join-Path $Root "current.txt") -Raw).Trim()
if ($tag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
  throw "Invalid Dala version pointer: $tag"
}

$dala = Join-Path $Root "versions\$tag\bin\dala.bat"
if (-not (Test-Path -LiteralPath $dala -PathType Leaf)) {
  throw "Dala release executable is missing: $dala"
}

function Invoke-Dala([ValidateSet("eval", "start")][string]$Command, [string]$Expression) {
  $commandLine = '""' + $dala + '" ' + $Command
  if (-not [string]::IsNullOrEmpty($Expression)) {
    $commandLine += ' "' + $Expression + '"'
  }
  $commandLine += '"'

  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = if ($env:ComSpec) { $env:ComSpec } else { Join-Path $env:SystemRoot "System32\cmd.exe" }
  $startInfo.Arguments = "/d /s /c $commandLine"
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.WorkingDirectory = Split-Path -Parent $dala

  $process = [Diagnostics.Process]::Start($startInfo)
  $process.WaitForExit()
  $exitCode = $process.ExitCode
  $process.Dispose()
  $exitCode
}

$migrateStatus = Invoke-Dala "eval" "Dala.Release.migrate()"
if ($migrateStatus -ne 0) { exit $migrateStatus }

exit (Invoke-Dala "start")

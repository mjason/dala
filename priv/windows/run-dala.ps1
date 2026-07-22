$ErrorActionPreference = "Stop"

$Root = if ($env:DALA_HOME) { $env:DALA_HOME } else { Split-Path -Parent $PSCommandPath }
$Root = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]"\/")
$MetadataFile = Join-Path $Root "install.json"

function Read-InstallMetadata([string]$Path) {
  try {
    $metadataItem = Get-SafeInstallMetadataItem $Path
    if ($null -eq $metadataItem) { return $null }

    $value = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
    foreach ($name in @("schemaVersion", "root", "dataDir", "configFile", "taskName", "port", "repo", "platform")) {
      if ($value.PSObject.Properties.Name -notcontains $name) { throw "required field '$name' is missing" }
    }
    if ([int]$value.schemaVersion -ne 1) { throw "unsupported schemaVersion" }
    foreach ($name in @("root", "dataDir", "configFile", "taskName", "repo", "platform")) {
      if ([string]::IsNullOrWhiteSpace([string]$value.$name)) { throw "field '$name' is empty" }
    }
    if ([int]$value.port -lt 1 -or [int]$value.port -gt 65535) { throw "invalid port" }
    if ([string]$value.platform -ne "windows-x86_64") { throw "unsupported platform" }
    $discoveryField = Get-MetadataField $value "discoveryFile"
    if ($discoveryField.Present) {
      $null = Get-CanonicalDiscoveryFile ([string]$discoveryField.Value)
    }
    if (-not ([IO.Path]::GetFullPath([string]$value.root).TrimEnd([char[]]"\/")).Equals(
        $Root, [StringComparison]::OrdinalIgnoreCase)) {
      throw "root does not match the runner location"
    }
    $value
  } catch {
    throw "Invalid Dala install metadata at $Path`: $($_.Exception.Message)"
  }
}

function Get-SafeInstallMetadataItem([string]$Path) {
  if (-not (Test-NoReparseAncestors $Path)) {
    throw "Refusing to read Dala install metadata through a reparse point: $Path"
  }

  try {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
  } catch {
    if ([string]$_.CategoryInfo.Category -ceq "ObjectNotFound") { return $null }
    throw "Could not inspect Dala install metadata at $Path`: $($_.Exception.Message)"
  }

  try {
    $attributes = [IO.File]::GetAttributes($Path)
  } catch {
    throw "Could not inspect Dala install metadata at $Path`: $($_.Exception.Message)"
  }
  if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
      ($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
      ($item.Attributes -band [IO.FileAttributes]::Directory) -ne 0 -or
      ($attributes -band [IO.FileAttributes]::Directory) -ne 0 -or
      $item.PSIsContainer -or
      -not ($item -is [IO.FileInfo])) {
    throw "Dala install metadata target must be a regular file: $Path"
  }
  $item
}

function Get-MetadataField($Metadata, [string]$Name) {
  if ($null -eq $Metadata) {
    return [pscustomobject]@{ Present = $false; Value = $null }
  }
  $property = $null
  foreach ($candidate in $Metadata.PSObject.Properties) {
    if ([string]$candidate.Name -ceq $Name) {
      $property = $candidate
      break
    }
  }
  if ([string]$Name -ceq "discoveryFile") {
    $discoveryProperties = @(
      $Metadata.PSObject.Properties | Where-Object { [string]$_.Name -ieq $Name }
    )
    if ($discoveryProperties.Count -gt 1 -or
        ($discoveryProperties.Count -eq 1 -and
         [string]($discoveryProperties[0].Name) -cne $Name)) {
      throw "Dala install metadata field 'discoveryFile' has invalid casing"
    }
  }
  if ($null -eq $property) {
    return [pscustomobject]@{ Present = $false; Value = $null }
  }
  if ($property.Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
    throw "Dala install metadata field '$Name' is empty"
  }
  [pscustomobject]@{ Present = $true; Value = [string]$property.Value }
}

function Test-NoReparseAncestors([string]$Path) {
  try {
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($root)) { return $false }
    $current = $root
    $remainder = $full.Substring($root.Length)
    foreach ($segment in @($remainder -split '[\\/]')) {
      if ([string]::IsNullOrEmpty($segment)) { continue }
      $current = Join-Path $current $segment
      try {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
      } catch {
        if ([string]$_.CategoryInfo.Category -ceq "ObjectNotFound") { break }
        return $false
      }
      if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        return $false
      }
    }
    $true
  } catch {
    $false
  }
}

function Get-CanonicalDiscoveryFile([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path) -or
      $Path -notmatch '^(?:[A-Za-z]:[\\/]|\\\\)' -or
      $Path -match '^\\\\[.?]\\' -or
      ($Path.Length -gt 2 -and $Path.Substring(2).Contains(":"))) {
    throw "Dala discoveryFile must be an absolute Windows path: $Path"
  }
  try {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]"\\/")
  } catch {
    throw "Dala discoveryFile is invalid: $Path"
  }
  if (-not (Test-NoReparseAncestors $full)) {
    throw "Refusing to use Dala discoveryFile through a reparse point: $full"
  }
  if (Test-Path -LiteralPath $full) {
    $attributes = [IO.File]::GetAttributes($full)
    if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($attributes -band [IO.FileAttributes]::Directory) -ne 0 -or
        -not (Test-Path -LiteralPath $full -PathType Leaf)) {
      throw "Dala discoveryFile must be a regular file: $full"
    }
  }
  $full
}

function Assert-InstallMetadataMatch($Left, $Right) {
  foreach ($name in @("root", "dataDir", "configFile")) {
    if (-not ([IO.Path]::GetFullPath([string]$Left.$name).TrimEnd([char[]]"\/")).Equals(
        [IO.Path]::GetFullPath([string]$Right.$name).TrimEnd([char[]]"\/"),
        [StringComparison]::OrdinalIgnoreCase)) {
      throw "Dala discovery and root install metadata disagree on $name"
    }
  }
  foreach ($name in @("taskName", "repo", "platform")) {
    if ([string]$Left.$name -cne [string]$Right.$name) {
      throw "Dala discovery and root install metadata disagree on $name"
    }
  }
  if ([int]$Left.port -ne [int]$Right.port) {
    throw "Dala discovery and root install metadata disagree on port"
  }
  $leftField = Get-MetadataField $Left "discoveryFile"
  $rightField = Get-MetadataField $Right "discoveryFile"
  if ($leftField.Present -ne $rightField.Present) {
    throw "Dala discovery and root install metadata disagree on discoveryFile"
  }
  if ($leftField.Present -and
      -not ([IO.Path]::GetFullPath([string]$leftField.Value).TrimEnd([char[]]"\/")).Equals(
        [IO.Path]::GetFullPath([string]$rightField.Value).TrimEnd([char[]]"\/"),
        [StringComparison]::OrdinalIgnoreCase)) {
    throw "Dala discovery and root install metadata disagree on discoveryFile"
  }
}

function Resolve-DiscoveryFile($RootMetadata) {
  $field = Get-MetadataField $RootMetadata "discoveryFile"
  $candidate = if ($field.Present) {
    [string]$field.Value
  } elseif (-not [string]::IsNullOrWhiteSpace($env:DALA_DISCOVERY_FILE)) {
    $env:DALA_DISCOVERY_FILE
  } elseif (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
    Join-Path $env:APPDATA "Dala\install.json"
  } else {
    throw "Dala discoveryFile is missing and APPDATA is not set"
  }
  Get-CanonicalDiscoveryFile $candidate
}

$metadata = Read-InstallMetadata $MetadataFile
$DiscoveryFile = Resolve-DiscoveryFile $metadata
$discoveryMetadata = Read-InstallMetadata $DiscoveryFile
if ($metadata -and $discoveryMetadata) {
  Assert-InstallMetadataMatch $metadata $discoveryMetadata
}
if (-not $metadata -and $discoveryMetadata) {
  $field = Get-MetadataField $discoveryMetadata "discoveryFile"
  if ($field.Present -and
      -not ([IO.Path]::GetFullPath([string]$field.Value).TrimEnd([char[]]"\/")).Equals(
        $DiscoveryFile, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Dala discovery metadata disagrees with its path"
  }
  $metadata = $discoveryMetadata
}
$ConfigFile = if ($metadata) {
  [string]$metadata.configFile
} else {
  $env:DALA_CONFIG
}
if ([string]::IsNullOrWhiteSpace($ConfigFile)) {
  if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
    throw "Dala configuration is missing and APPDATA is not set"
  }
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
  "DALA_DISCOVERY_FILE",
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
  "ERL_FLAGS", "ERL_AFLAGS", "ERL_ZFLAGS", "ERL_LIBS", "ERL_INETRC",
  "ERL_EPMD_PORT", "ERL_EPMD_ADDRESS", "ERL_EPMD_RELAXED_COMMAND_CHECK",
  "ELIXIR_ERL_OPTIONS"
)) {
  [Environment]::SetEnvironmentVariable($name, $null, "Process")
}
[Environment]::SetEnvironmentVariable("DALA_CONFIG", $ConfigFile, "Process")
[Environment]::SetEnvironmentVariable("DALA_DISCOVERY_FILE", $DiscoveryFile, "Process")

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

Write-Output "Dala runner: migration starting"
$migrateStatus = Invoke-Dala "eval" "Dala.Release.migrate()"
Write-Output "Dala runner: migration exited with status $migrateStatus"
if ($migrateStatus -ne 0) { exit $migrateStatus }

Write-Output "Dala runner: server starting"
exit (Invoke-Dala "start")

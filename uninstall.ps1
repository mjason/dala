[CmdletBinding()]
param([switch]$PurgeData)

$ErrorActionPreference = "Stop"
$DefaultRoot = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "Dala"
$DefaultDataDir = Join-Path $DefaultRoot "data"
$Root = if ($env:DALA_HOME) { $env:DALA_HOME } else { $DefaultRoot }
$DataDir = if ($env:DALA_DATA_DIR) { $env:DALA_DATA_DIR } else { $DefaultDataDir }
$ConfigDir = Join-Path $env:APPDATA "Dala"
$TaskName = if ($env:DALA_SERVICE) { $env:DALA_SERVICE } else { "Dala" }

function Get-SafeRemovalTarget([string]$Path, [string]$Label) {
  if ([string]::IsNullOrWhiteSpace($Path)) { throw "$Label is empty" }

  $full = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]"\/")
  $volume = [IO.Path]::GetPathRoot($full).TrimEnd([char[]]"\/")
  if ($full -eq $volume) { throw "Refusing to remove volume root for $Label`: $full" }

  foreach ($sensitive in @($env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA, [IO.Path]::GetTempPath())) {
    if (-not [string]::IsNullOrWhiteSpace($sensitive)) {
      $normalized = [IO.Path]::GetFullPath($sensitive).TrimEnd([char[]]"\/")
      if ($full.Equals($normalized, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove sensitive directory for $Label`: $full"
      }
    }
  }

  $full
}

function Test-SamePath([string]$Left, [string]$Right) {
  $leftFull = [IO.Path]::GetFullPath($Left).TrimEnd([char[]]"\/")
  $rightFull = [IO.Path]::GetFullPath($Right).TrimEnd([char[]]"\/")
  $leftFull.Equals($rightFull, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-DalaRoot([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return }
  if ((Test-SamePath $Path $DefaultRoot) -or (Test-Path -LiteralPath (Join-Path $Path ".dala-install") -PathType Leaf)) {
    return
  }
  throw "Refusing to remove unverified DALA_HOME: $Path"
}

function Assert-DalaDataDir([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return }
  if ((Test-SamePath $Path $DefaultDataDir) -or (Test-Path -LiteralPath (Join-Path $Path ".dala-data") -PathType Leaf)) {
    return
  }
  throw "Refusing to remove unverified DALA_DATA_DIR: $Path"
}

function Assert-DalaConfigDir([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return }
  if (Test-Path -LiteralPath (Join-Path $Path "dala.env") -PathType Leaf) { return }
  throw "Refusing to remove unverified config directory: $Path"
}

function Get-CurrentExecutable([string]$InstallRoot) {
  $current = Join-Path $InstallRoot "current.txt"
  if (-not (Test-Path -LiteralPath $current -PathType Leaf)) { return $null }

  $tag = (Get-Content -LiteralPath $current -Raw).Trim()
  if ($tag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
    return $null
  }

  $candidate = Join-Path $InstallRoot "versions\$tag\bin\dala.bat"
  if (Test-Path -LiteralPath $candidate -PathType Leaf) { $candidate } else { $null }
}

function Get-RestartHelper([string]$InstallRoot) {
  Get-ChildItem -LiteralPath $InstallRoot -Filter "restart-dala.ps1" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -like "*\priv\windows\restart-dala.ps1" } |
    Select-Object -First 1 -ExpandProperty FullName
}

$Root = Get-SafeRemovalTarget $Root "DALA_HOME"
$DataDir = Get-SafeRemovalTarget $DataDir "DALA_DATA_DIR"
$ConfigDir = Get-SafeRemovalTarget $ConfigDir "config directory"
Assert-DalaRoot $Root

if ($PurgeData) {
  Assert-DalaDataDir $DataDir
  Assert-DalaConfigDir $ConfigDir
}

$CurrentExecutable = Get-CurrentExecutable $Root
if ($CurrentExecutable) {
  $RestartHelper = Get-RestartHelper $Root

  if ($RestartHelper) {
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $RestartHelper -StopOnly -StopExecutable $CurrentExecutable
    if ($LASTEXITCODE -ne 0) { throw "Could not stop the running Dala release" }
  } else {
    & $CurrentExecutable stop 2>$null | Out-Null
  }
}

Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

if ($PurgeData) {
  Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $DataDir -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $ConfigDir -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host "Dala and its data were removed."
} else {
  Remove-Item -LiteralPath (Join-Path $Root "versions") -Recurse -Force -ErrorAction SilentlyContinue

  foreach ($name in @("current.txt", ".current.new", "run-dala.ps1")) {
    Remove-Item -LiteralPath (Join-Path $Root $name) -Force -ErrorAction SilentlyContinue
  }

  if ((Test-Path -LiteralPath $Root) -and -not (Get-ChildItem -LiteralPath $Root -Force | Select-Object -First 1)) {
    Remove-Item -LiteralPath $Root -Force -ErrorAction SilentlyContinue
  }

  Write-Host "Dala was removed. Data remains at $DataDir; use -PurgeData to remove it."
}

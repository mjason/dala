[CmdletBinding()]
param([string]$Version)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$Repo = if ($env:DALA_REPO) { $env:DALA_REPO } else { "mjason/dala" }
$DefaultRoot = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "Dala"
$DefaultDataDir = Join-Path $DefaultRoot "data"
$Root = if ($env:DALA_HOME) { $env:DALA_HOME } else { $DefaultRoot }
$DataDir = if ($env:DALA_DATA_DIR) { $env:DALA_DATA_DIR } else { $DefaultDataDir }
$ConfigDir = Join-Path $env:APPDATA "Dala"
$ConfigFile = Join-Path $ConfigDir "dala.env"
$TaskName = if ($env:DALA_SERVICE) { $env:DALA_SERVICE } else { "Dala" }
$Port = if ($env:DALA_PORT) { $env:DALA_PORT } else { "4400" }
$Platform = "windows-x86_64"

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Green }
function New-Secret {
  $bytes = New-Object byte[] 48
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
  [Convert]::ToBase64String($bytes).TrimEnd("=")
}
function Set-Current([string]$Tag) {
  $current = Join-Path $Root "current.txt"
  $fresh = Join-Path $Root ".current.new"
  [IO.File]::WriteAllText($fresh, "$Tag`n", [Text.UTF8Encoding]::new($false))
  if (Test-Path -LiteralPath $current) {
    [IO.File]::Replace($fresh, $current, $null)
  } else {
    [IO.File]::Move($fresh, $current)
  }
}
function Get-CurrentExecutable {
  $current = Join-Path $Root "current.txt"
  if (-not (Test-Path -LiteralPath $current -PathType Leaf)) { return $null }

  $tag = (Get-Content -LiteralPath $current -Raw).Trim()
  if ($tag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
    return $null
  }

  $candidate = Join-Path $Root "versions\$tag\bin\dala.bat"
  if (Test-Path -LiteralPath $candidate -PathType Leaf) { $candidate } else { $null }
}
function Get-RestartHelper([string]$ReleaseDir) {
  Get-ChildItem -LiteralPath $ReleaseDir -Filter "restart-dala.ps1" -Recurse -File |
    Where-Object { $_.FullName -like "*\priv\windows\restart-dala.ps1" } |
    Select-Object -First 1 -ExpandProperty FullName
}
function Get-TaskLauncher([string]$ReleaseDir) {
  Get-ChildItem -LiteralPath $ReleaseDir -Filter "dala_task_launcher.exe" -Recurse -File |
    Where-Object { $_.FullName -like "*\priv\bin\dala_task_launcher.exe" } |
    Select-Object -First 1 -ExpandProperty FullName
}
function Test-SamePath([string]$Left, [string]$Right) {
  $leftFull = [IO.Path]::GetFullPath($Left).TrimEnd([char[]]"\/")
  $rightFull = [IO.Path]::GetFullPath($Right).TrimEnd([char[]]"\/")
  $leftFull.Equals($rightFull, [StringComparison]::OrdinalIgnoreCase)
}
function Assert-ClaimableDirectory([string]$Path, [string]$DefaultPath, [string]$Marker, [string]$Label) {
  if ((Test-SamePath $Path $DefaultPath) -or -not (Test-Path -LiteralPath $Path)) { return }
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "$Label is not a directory: $Path" }
  if (Test-Path -LiteralPath (Join-Path $Path $Marker) -PathType Leaf) { return }
  if (-not (Get-ChildItem -LiteralPath $Path -Force | Select-Object -First 1)) { return }

  throw "Refusing to claim non-empty unverified $Label`: $Path"
}

if (-not [Environment]::Is64BitOperatingSystem) { throw "Dala requires 64-bit Windows" }
if ([Environment]::OSVersion.Version -lt [Version]"10.0.17763") { throw "Dala requires Windows 10 1809 or newer" }

if (-not $Version) {
  Write-Step "Resolving latest server release from $Repo"
  $releases = Invoke-RestMethod -Headers @{ "User-Agent" = "dala-installer" } -Uri "https://api.github.com/repos/$Repo/releases?per_page=15"
  $release = $releases | Where-Object { -not $_.draft -and -not $_.prerelease -and $_.tag_name -match '^v[0-9]' } | Select-Object -First 1
  if (-not $release) { throw "No server release is available" }
  $Version = $release.tag_name
}
if ($Version -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
  throw "Invalid version: $Version"
}

$Asset = "dala-$Version-$Platform.zip"
$Url = "https://github.com/$Repo/releases/download/$Version/$Asset"
$Dest = Join-Path $Root "versions\$Version"
$Executable = Join-Path $Dest "bin\dala.bat"
$ReleaseRunner = Join-Path $Dest "run-dala.ps1"

Assert-ClaimableDirectory $Root $DefaultRoot ".dala-install" "DALA_HOME"
Assert-ClaimableDirectory $DataDir $DefaultDataDir ".dala-data" "DALA_DATA_DIR"
New-Item -ItemType Directory -Force -Path $Root, $DataDir, $ConfigDir, (Join-Path $Root "versions") | Out-Null
[IO.File]::WriteAllText((Join-Path $Root ".dala-install"), "Dala installation root`n", [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $DataDir ".dala-data"), "Dala data directory`n", [Text.UTF8Encoding]::new($false))
$PreviousExecutable = Get-CurrentExecutable
if (-not (Test-Path -LiteralPath $Executable -PathType Leaf) -or -not (Test-Path -LiteralPath $ReleaseRunner -PathType Leaf)) {
  Write-Step "Downloading $Asset"
  $temp = Join-Path ([IO.Path]::GetTempPath()) ("dala-" + [guid]::NewGuid().ToString("N"))
  $staging = Join-Path $Root ("versions\.install-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $temp | Out-Null
  try {
    $archive = Join-Path $temp $Asset
    $checksum = "$archive.sha256"
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $archive
    Invoke-WebRequest -UseBasicParsing -Uri "$Url.sha256" -OutFile $checksum
    $expected = ((Get-Content -LiteralPath $checksum -Raw).Trim() -split '\s+')[0].ToUpperInvariant()
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToUpperInvariant()
    if ($expected -ne $actual) { throw "SHA-256 checksum mismatch for $Asset" }
    Write-Step "Checksum verified"

    New-Item -ItemType Directory -Path $staging | Out-Null
    Expand-Archive -LiteralPath $archive -DestinationPath $staging -Force
    if (-not (Test-Path -LiteralPath (Join-Path $staging "bin\dala.bat") -PathType Leaf)) {
      throw "Release archive is missing bin\dala.bat"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $staging "run-dala.ps1") -PathType Leaf)) {
      throw "Release archive is missing run-dala.ps1"
    }

    if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Recurse -Force }
    Move-Item -LiteralPath $staging -Destination $Dest
  } finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$RestartHelper = Get-RestartHelper $Dest
if (-not $RestartHelper) { throw "Release is missing priv\windows\restart-dala.ps1" }
$TaskLauncher = Get-TaskLauncher $Dest
if (-not $TaskLauncher) { throw "Release is missing priv\bin\dala_task_launcher.exe" }

if (-not (Test-Path -LiteralPath $ConfigFile)) {
  Write-Step "Writing $ConfigFile"
  $config = @"
# Dala runtime configuration (loaded by the current-user scheduled task).
PHX_SERVER=true
PORT=$Port
PHX_HOST=localhost
DALA_LISTEN_IP=127.0.0.1
PHX_CHECK_ORIGIN=false
DATABASE_PATH=$DataDir\dala.db
DALA_DATA_DIR=$DataDir
DALA_RELEASE_ROOT=$Root
DALA_SERVICE=$TaskName
SECRET_KEY_BASE=$(New-Secret)
TOKEN_SIGNING_SECRET=$(New-Secret)
# Optional login:
# DALA_AUTH_ENABLED=true
# DALA_USERS=you@example.com:yourpassword
"@
  [IO.File]::WriteAllText($ConfigFile, $config, [Text.UTF8Encoding]::new($false))
} else {
  Write-Step "Keeping existing $ConfigFile"
}

if (-not (Test-Path -LiteralPath $ReleaseRunner)) { throw "Release is missing run-dala.ps1" }
$runner = Join-Path $Root "run-dala.ps1"
Copy-Item -LiteralPath $ReleaseRunner -Destination $runner -Force

if ($PreviousExecutable) {
  Write-Step "Stopping the currently running release"
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $RestartHelper -StopOnly -StopExecutable $PreviousExecutable
  if ($LASTEXITCODE -ne 0) { throw "Could not stop the currently running Dala release" }
}

Set-Current $Version

Write-Step "Registering current-user scheduled task $TaskName"
$logFile = Join-Path $Root "logs\server.log"
$action = New-ScheduledTaskAction -Execute $TaskLauncher -Argument "`"$runner`" `"$logFile`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "Dala terminal server" -Force | Out-Null
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName $TaskName

Write-Step "Waiting for http://localhost:$Port"
for ($attempt = 0; $attempt -lt 30; $attempt++) {
  try {
    $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 -Uri "http://localhost:$Port"
    if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
      Write-Step "Dala $Version is running at http://localhost:$Port"
      exit 0
    }
  } catch {}
  Start-Sleep -Seconds 1
}
throw "Dala did not become healthy. Run: Get-ScheduledTaskInfo -TaskName '$TaskName'"

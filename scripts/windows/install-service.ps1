[CmdletBinding()]
param(
  [string]$SourceRoot,
  [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA "Dala"),
  [Alias("ServiceName")]
  [string]$TaskName = "Dala",
  [string]$Version,
  [int]$Port = 4400,
  [int]$HealthCheckAttempts = 30,
  [switch]$NoStart
)

$ErrorActionPreference = "Stop"

function Write-Utf8NoBom([string]$Path, [string]$Value) {
  [System.IO.File]::WriteAllText($Path, $Value, [System.Text.UTF8Encoding]::new($false))
}

function Wait-DalaHealthy([string]$Url, [string]$ExpectedVersion, [string]$TaskName, [string]$Entrypoint, [int]$Attempts = 30) {
  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    try {
      $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
      $version = Invoke-RestMethod -Uri $Url -TimeoutSec 2
      $taskHealthy = $task.State -eq "Running" -or
        ($task.State -eq "Ready" -and (Test-DalaReleaseProcess $Entrypoint))
      if ($taskHealthy -and $version.ToString().Trim() -eq $ExpectedVersion) {
        Start-Sleep -Seconds 1
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        $version = Invoke-RestMethod -Uri $Url -TimeoutSec 2
        $taskHealthy = $task.State -eq "Running" -or
          ($task.State -eq "Ready" -and (Test-DalaReleaseProcess $Entrypoint))
        if ($taskHealthy -and $version.ToString().Trim() -eq $ExpectedVersion) {
          return $true
        }
      }
    } catch {}

    if ($attempt -lt $Attempts) { Start-Sleep -Seconds 1 }
  }

  return $false
}

function Get-DalaReleaseInfo([string]$Entrypoint) {
  $expression = 'cfg = Dala.RuntimeConfig.load; port = Dala.RuntimeConfig.get_int cfg, ~s/DALA_PORT/, ~s/port/, 4000; version = Application.spec :dala, :vsn; IO.puts port; IO.write to_string version'
  $output = @(& $Entrypoint eval $expression)
  if ($LASTEXITCODE -ne 0) {
    throw "Could not read Dala release metadata using $Entrypoint"
  }

  if ($output.Count -ne 2) { throw "Dala returned invalid release metadata" }
  $portValue = $output[0].ToString().Trim()
  $releaseVersion = $output[1].ToString().Trim()
  $configuredPort = 0
  if (-not [int]::TryParse($portValue, [ref]$configuredPort) -or $configuredPort -lt 1 -or $configuredPort -gt 65535) {
    throw "Dala returned an invalid configured port: $portValue"
  }
  if ($releaseVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$') {
    throw "Dala returned an invalid release version: $releaseVersion"
  }

  return [pscustomobject]@{ Port = $configuredPort; Version = $releaseVersion }
}

function Get-DalaReleasePid([string]$Entrypoint) {
  if (-not $Entrypoint -or -not (Test-Path -LiteralPath $Entrypoint)) { return $null }

  $output = @(& $Entrypoint pid 2>$null)
  if ($LASTEXITCODE -ne 0 -or $output.Count -eq 0) { return $null }

  $processId = 0
  if ([int]::TryParse($output[-1].ToString().Trim(), [ref]$processId) -and $processId -gt 0) {
    return $processId
  }

  return $null
}

function Test-DalaReleaseProcess([string]$Entrypoint) {
  $releasePid = Get-DalaReleasePid $Entrypoint
  if ($null -eq $releasePid) { return $false }

  $process = Get-CimInstance Win32_Process -Filter "ProcessId=$releasePid" -ErrorAction SilentlyContinue
  if ($null -eq $process -or -not $process.ExecutablePath) { return $false }

  $versionRoot = Split-Path (Split-Path $Entrypoint -Parent) -Parent
  $versionsRoot = Split-Path $versionRoot -Parent
  $expectedPrefix = $versionsRoot.TrimEnd('\') + '\'
  return $process.ExecutablePath.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Stop-DalaRelease([string]$Entrypoint, [int]$Attempts = 30) {
  $releasePid = Get-DalaReleasePid $Entrypoint
  if ($null -eq $releasePid) { return $true }

  & {
    $ErrorActionPreference = "SilentlyContinue"
    & $Entrypoint stop 2>&1 | Write-Verbose
  }

  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    if ($null -eq (Get-Process -Id $releasePid -ErrorAction SilentlyContinue)) { return $true }
    if ($attempt -lt $Attempts) { Start-Sleep -Seconds 1 }
  }

  $process = Get-CimInstance Win32_Process -Filter "ProcessId=$releasePid" -ErrorAction SilentlyContinue
  $versionRoot = Split-Path (Split-Path $Entrypoint -Parent) -Parent
  $versionsRoot = Split-Path $versionRoot -Parent
  $expectedPrefix = $versionsRoot.TrimEnd('\') + '\'
  if ($null -eq $process -or
      -not $process.ExecutablePath.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $false
  }

  Stop-Process -Id $releasePid -Force
  for ($attempt = 1; $attempt -le 10; $attempt++) {
    if ($null -eq (Get-Process -Id $releasePid -ErrorAction SilentlyContinue)) { return $true }
    Start-Sleep -Milliseconds 200
  }

  return $false
}

function Wait-DalaTaskStopped([string]$TaskName, [int]$Attempts = 30) {
  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task -or $task.State -ne "Running") { return $true }
    if ($attempt -lt $Attempts) { Start-Sleep -Seconds 1 }
  }

  return $false
}

function Register-DalaTask([string]$Name, [string]$Root, [string]$VersionOverride = "") {
  $userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
  $arguments = "launcher.vbs"
  if ($VersionOverride) { $arguments += " $VersionOverride" }

  $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot "System32\wscript.exe") `
    -Argument $arguments -WorkingDirectory $Root
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
  $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew

  Register-ScheduledTask -TaskName $Name -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Description "Dala terminal server" -Force | Out-Null
}

function Set-DalaTaskStableAction([string]$Name, [string]$Root) {
  $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot "System32\wscript.exe") `
    -Argument "launcher.vbs" -WorkingDirectory $Root
  Set-ScheduledTask -TaskName $Name -Action $action | Out-Null
}

if (-not $SourceRoot) {
  $SourceRoot = Join-Path $PSScriptRoot "..\.."
}

$SourceRoot = [System.IO.Path]::GetFullPath($SourceRoot)
$InstallRoot = [System.IO.Path]::GetFullPath($InstallRoot)
if ($HealthCheckAttempts -lt 1) { throw "HealthCheckAttempts must be positive" }

if (-not (Test-Path -LiteralPath (Join-Path $SourceRoot "bin\dala.bat"))) {
  throw "Dala release entrypoint not found under $SourceRoot"
}

if (-not $Version) {
  $releaseDirs = @(Get-ChildItem -LiteralPath (Join-Path $SourceRoot "lib") -Directory -Filter "dala-*")
  if ($releaseDirs.Count -ne 1) {
    throw "Could not determine the Dala version under $SourceRoot\lib; pass -Version vX.Y.Z"
  }

  $Version = "v" + $releaseDirs[0].Name.Substring("dala-".Length)
}

if ($Version -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$') {
  throw "Invalid release version: $Version"
}

$destination = Join-Path $InstallRoot "versions\$Version"
$sourcePrefix = $SourceRoot.TrimEnd('\') + '\'
if ($destination.StartsWith($sourcePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "Extract the release outside $InstallRoot before installing it"
}

New-Item -ItemType Directory -Force -Path (Join-Path $InstallRoot "versions") | Out-Null

if (-not (Test-Path -LiteralPath (Join-Path $destination "bin\dala.bat"))) {
  New-Item -ItemType Directory -Force -Path $destination | Out-Null
  Copy-Item -Path (Join-Path $SourceRoot "*") -Destination $destination -Recurse -Force
}

$launcherSource = Join-Path $SourceRoot "scripts\windows\launcher.cmd"
$hiddenLauncherSource = Join-Path $SourceRoot "scripts\windows\launcher.vbs"
$helperSource = Join-Path $SourceRoot "scripts\windows\update-helper.ps1"
$queueSource = Join-Path $SourceRoot "scripts\windows\queue-update.ps1"
foreach ($required in @($launcherSource, $hiddenLauncherSource, $helperSource, $queueSource)) {
  if (-not (Test-Path -LiteralPath $required)) { throw "Required installer file is missing: $required" }
}

$configDir = Join-Path $env:APPDATA "Dala"
$dataDir = Join-Path $env:LOCALAPPDATA "Dala\data"
$configFile = Join-Path $configDir "config.jsonc"
$legacyEnv = Join-Path $configDir "dala.env"
New-Item -ItemType Directory -Force -Path $configDir, $dataDir | Out-Null

if ((Test-Path -LiteralPath $legacyEnv) -and -not (Test-Path -LiteralPath $configFile)) {
  throw "Legacy config detected at $legacyEnv. Migrate it before installing; see docs/config-migration.md."
}

if (-not (Test-Path -LiteralPath $configFile)) {
  $config = [ordered]@{
    server = $true
    port = $Port
    listenIp = "127.0.0.1"
    host = "localhost"
    checkOrigin = $false
    dataDir = $dataDir.Replace('\', '/')
    releaseRoot = $InstallRoot.Replace('\', '/')
    serviceName = $TaskName
    auth = [ordered]@{ enabled = $false }
  }

  Write-Utf8NoBom $configFile (($config | ConvertTo-Json -Depth 4) + "`r`n")
}

$entrypoint = Join-Path $destination "bin\dala.bat"
$releaseInfo = Get-DalaReleaseInfo $entrypoint

$existingService = Get-Service -Name $TaskName -ErrorAction SilentlyContinue
if ($null -ne $existingService) {
  throw "A legacy Windows service named '$TaskName' exists. Remove it before installing the per-user scheduled task."
}

$currentFile = Join-Path $InstallRoot "current.txt"
$launcher = Join-Path $InstallRoot "launcher.cmd"
$hiddenLauncher = Join-Path $InstallRoot "launcher.vbs"
$helper = Join-Path $InstallRoot "update-helper.ps1"
$queue = Join-Path $InstallRoot "queue-update.ps1"
$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$previousTaskXml = if ($null -ne $existingTask) { Export-ScheduledTask -TaskName $TaskName } else { $null }
$previousVersion = $null
$previousEntrypoint = $null
$previousReleaseInfo = $null

if (Test-Path -LiteralPath $currentFile) {
  $previousVersion = (Get-Content -LiteralPath $currentFile -Raw).Trim()
  $previousEntrypoint = Join-Path $InstallRoot "versions\$previousVersion\bin\dala.bat"
  if (Test-Path -LiteralPath $previousEntrypoint) {
    $previousReleaseInfo = Get-DalaReleaseInfo $previousEntrypoint
  }
}

$rollbackDir = Join-Path $InstallRoot ".install-rollback-$PID"
New-Item -ItemType Directory -Force -Path $rollbackDir | Out-Null
$backups = @(
  [pscustomobject]@{ Path = $currentFile; Name = "current.txt"; Existed = (Test-Path -LiteralPath $currentFile) },
  [pscustomobject]@{ Path = $launcher; Name = "launcher.cmd"; Existed = (Test-Path -LiteralPath $launcher) },
  [pscustomobject]@{ Path = $hiddenLauncher; Name = "launcher.vbs"; Existed = (Test-Path -LiteralPath $hiddenLauncher) },
  [pscustomobject]@{ Path = $helper; Name = "update-helper.ps1"; Existed = (Test-Path -LiteralPath $helper) },
  [pscustomobject]@{ Path = $queue; Name = "queue-update.ps1"; Existed = (Test-Path -LiteralPath $queue) }
)
foreach ($backup in $backups) {
  if ($backup.Existed) {
    Copy-Item -LiteralPath $backup.Path -Destination (Join-Path $rollbackDir $backup.Name) -Force
  }
}

$healthUrl = "http://127.0.0.1:$($releaseInfo.Port)/version"

try {
  if (-not (Stop-DalaRelease $previousEntrypoint $HealthCheckAttempts)) {
    throw "Previous Dala release did not stop"
  }
  if ($null -ne $existingTask) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not (Wait-DalaTaskStopped $TaskName $HealthCheckAttempts)) {
      throw "Previous scheduled task '$TaskName' did not stop"
    }
  }

  Copy-Item -LiteralPath $launcherSource -Destination $launcher -Force
  Copy-Item -LiteralPath $hiddenLauncherSource -Destination $hiddenLauncher -Force
  Copy-Item -LiteralPath $helperSource -Destination $helper -Force
  Copy-Item -LiteralPath $queueSource -Destination $queue -Force

  if ($NoStart) {
    Write-Utf8NoBom $currentFile ($Version + "`r`n")
    Register-DalaTask $TaskName $InstallRoot
    Write-Output "Installed Dala $Version at $InstallRoot; scheduled task '$TaskName' is registered but not started"
    return
  }

  Register-DalaTask $TaskName $InstallRoot $Version
  Start-ScheduledTask -TaskName $TaskName
  if (-not (Wait-DalaHealthy $healthUrl $releaseInfo.Version $TaskName $entrypoint $HealthCheckAttempts)) {
    throw "Candidate $Version did not become healthy at $healthUrl"
  }

  Write-Utf8NoBom $currentFile ($Version + "`r`n")
  Set-DalaTaskStableAction $TaskName $InstallRoot
  if (-not (Wait-DalaHealthy $healthUrl $releaseInfo.Version $TaskName $entrypoint $HealthCheckAttempts)) {
    throw "Committed $Version did not remain healthy at $healthUrl"
  }

  Write-Output "Installed and started Dala $Version using scheduled task '$TaskName': $healthUrl"
} catch {
  $installError = $_.Exception.Message
  $rollbackError = $null

  try {
    if (-not (Stop-DalaRelease $entrypoint $HealthCheckAttempts)) {
      throw "Candidate Dala release did not stop during rollback"
    }
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not (Wait-DalaTaskStopped $TaskName $HealthCheckAttempts)) {
      throw "Candidate scheduled task '$TaskName' did not stop during rollback"
    }

    foreach ($backup in $backups) {
      $saved = Join-Path $rollbackDir $backup.Name
      if ($backup.Existed) {
        Copy-Item -LiteralPath $saved -Destination $backup.Path -Force
      } else {
        Remove-Item -LiteralPath $backup.Path -Force -ErrorAction SilentlyContinue
      }
    }

    if ($previousTaskXml) {
      Register-ScheduledTask -TaskName $TaskName -Xml $previousTaskXml -Force | Out-Null
      Start-ScheduledTask -TaskName $TaskName

      if ($previousReleaseInfo -and
          -not (Wait-DalaHealthy "http://127.0.0.1:$($previousReleaseInfo.Port)/version" `
            $previousReleaseInfo.Version $TaskName $previousEntrypoint $HealthCheckAttempts)) {
        throw "restored $previousVersion did not become healthy"
      }
    } else {
      Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
  } catch {
    $rollbackError = $_.Exception.Message
  }

  if ($rollbackError) {
    throw "$installError. Rollback also failed: $rollbackError. Inspect $InstallRoot\logs\dala.stderr.log and the TaskScheduler/Operational event log."
  }

  throw "$installError. The previous installation was restored. Inspect $InstallRoot\logs\dala.stderr.log and the TaskScheduler/Operational event log."
} finally {
  Remove-Item -LiteralPath $rollbackDir -Recurse -Force -ErrorAction SilentlyContinue
}

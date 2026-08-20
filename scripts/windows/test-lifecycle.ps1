[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$ReleaseRoot,
  [Parameter(Mandatory = $true)]
  [string]$InstallRoot,
  [string]$TaskName = "Dala-CI",
  [string]$Version = "v0.0.0",
  [int]$Port = 4417
)

$ErrorActionPreference = "Stop"

function Write-Utf8NoBom([string]$Path, [string]$Value) {
  [System.IO.File]::WriteAllText($Path, $Value, [System.Text.UTF8Encoding]::new($false))
}

function Write-Request([string]$Path, [string]$Root, [string]$Target, [string]$Task, [int]$HealthPort, [int]$Attempts) {
  $request = [ordered]@{
    installRoot = $Root
    targetVersion = $Target
    taskName = $Task
    healthUrl = "http://127.0.0.1:$HealthPort/version"
    healthCheckAttempts = $Attempts
  }
  Write-Utf8NoBom $Path (($request | ConvertTo-Json -Compress) + "`r`n")
}

function Wait-UpdateState([string]$Path, [string]$ExpectedState, [int]$Attempts = 180) {
  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    if (Test-Path -LiteralPath $Path) {
      $status = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
      if ($status.state -eq $ExpectedState) { return $status }
      if ($status.state -eq "failed" -or
          ($status.state -eq "rolled_back" -and $ExpectedState -ne "rolled_back")) {
        throw "Update entered $($status.state): $($status.message)"
      }
    }

    if ($attempt -lt $Attempts) { Start-Sleep -Seconds 1 }
  }

  throw "Update did not reach $ExpectedState after $Attempts attempts"
}

$ReleaseRoot = [System.IO.Path]::GetFullPath($ReleaseRoot)
$InstallRoot = [System.IO.Path]::GetFullPath($InstallRoot)
$installer = Join-Path $ReleaseRoot "scripts\windows\install-service.ps1"
$uninstaller = Join-Path $ReleaseRoot "scripts\windows\uninstall-service.ps1"
$helper = Join-Path $InstallRoot "update-helper.ps1"
$queue = Join-Path $InstallRoot "queue-update.ps1"
$updateTaskName = "$TaskName-Update"
$installerFixture = Join-Path ([System.IO.Path]::GetTempPath()) "dala-installer-rollback-$PID-$([guid]::NewGuid().ToString('N'))"

try {
  & $installer -SourceRoot $ReleaseRoot -InstallRoot $InstallRoot -TaskName $TaskName `
    -Version $Version -Port $Port

  $installedTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
  if ($installedTask.State -notin @("Running", "Ready")) {
    throw "Installed scheduled task is $($installedTask.State), expected Running or Ready"
  }
  if ($installedTask.Actions[0].Arguments -ne "/d /c launcher.cmd") {
    throw "Installer left a candidate-specific task action: $($installedTask.Actions[0].Arguments)"
  }

  $currentFile = Join-Path $InstallRoot "current.txt"
  if ((Get-Content -LiteralPath $currentFile -Raw).Trim() -ne $Version) {
    throw "Installer did not activate $Version"
  }

  $installedRelease = Join-Path $InstallRoot "versions\$Version"
  $installedReleaseVersion = (Invoke-RestMethod -Uri "http://127.0.0.1:$Port/version" -TimeoutSec 2).ToString().Trim()

  Copy-Item -LiteralPath $installedRelease -Destination $installerFixture -Recurse
  $brokenInstallerEntrypoint = Join-Path $installerFixture "bin\dala.bat"
  $realInstallerEntrypoint = Join-Path $installerFixture "bin\dala-real.bat"
  Move-Item -LiteralPath $brokenInstallerEntrypoint -Destination $realInstallerEntrypoint
  $brokenInstallerWrapper = @'
@echo off
if /I "%~1"=="eval" call "%~dp0dala-real.bat" %*
if /I "%~1"=="eval" exit /b %errorlevel%
>"%~dp0..\installer-start-attempted.txt" echo attempted
exit /b 1
'@
  Write-Utf8NoBom $brokenInstallerEntrypoint ($brokenInstallerWrapper + "`r`n")

  $brokenInstallerVersion = "v999.999.997"
  $installerRollbackRaised = $false
  try {
    & $installer -SourceRoot $installerFixture -InstallRoot $InstallRoot -TaskName $TaskName `
      -Version $brokenInstallerVersion -Port $Port -HealthCheckAttempts 5
  } catch {
    $installerRollbackRaised = $true
  }

  if (-not $installerRollbackRaised) { throw "Broken installer candidate unexpectedly succeeded" }
  $installerStartMarker = Join-Path $InstallRoot "versions\$brokenInstallerVersion\installer-start-attempted.txt"
  if (-not (Test-Path -LiteralPath $installerStartMarker)) {
    throw "Broken installer candidate was never started"
  }
  if ((Get-Content -LiteralPath $currentFile -Raw).Trim() -ne $Version) {
    throw "Installer rollback did not restore $Version"
  }
  if ((Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop).State -notin @("Running", "Ready")) {
    throw "Installer rollback did not leave the scheduled task registered"
  }
  if ((Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop).Actions[0].Arguments -ne "/d /c launcher.cmd") {
    throw "Installer rollback did not restore the stable task action"
  }
  $restoredReleaseVersion = (Invoke-RestMethod -Uri "http://127.0.0.1:$Port/version" -TimeoutSec 2).ToString().Trim()
  if ($restoredReleaseVersion -ne $installedReleaseVersion) {
    throw "Installer rollback restored release $restoredReleaseVersion, expected $installedReleaseVersion"
  }

  $badVersion = "v999.999.998"
  $badRelease = Join-Path $InstallRoot "versions\$badVersion"
  Copy-Item -LiteralPath $installedRelease -Destination $badRelease -Recurse

  $badEntrypoint = Join-Path $badRelease "bin\dala.bat"
  $realEntrypoint = Join-Path $badRelease "bin\dala-real.bat"
  Move-Item -LiteralPath $badEntrypoint -Destination $realEntrypoint
  $badWrapper = @'
@echo off
if /I "%~1"=="eval" call "%~dp0dala-real.bat" %*
if /I "%~1"=="eval" exit /b %errorlevel%
exit /b 1
'@
  Write-Utf8NoBom $badEntrypoint ($badWrapper + "`r`n")

  $request = Join-Path $InstallRoot "rollback-request.json"
  Write-Request $request $InstallRoot $badVersion $TaskName $Port 5
  & $queue -HelperPath $helper -RequestPath $request -TaskName $updateTaskName | Out-Null
  $rollbackStatus = Wait-UpdateState (Join-Path $InstallRoot "update-status.json") "rolled_back"
  if ((Get-Content -LiteralPath $currentFile -Raw).Trim() -ne $Version) {
    throw "Broken release activation did not restore $Version"
  }

  if ($rollbackStatus.state -ne "rolled_back") { throw "Expected rolled_back update status" }
  if ((Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop).State -notin @("Running", "Ready")) {
    throw "Rollback did not leave the scheduled task registered"
  }

  $goodVersion = "v999.999.999"
  $goodRelease = Join-Path $InstallRoot "versions\$goodVersion"
  Copy-Item -LiteralPath $installedRelease -Destination $goodRelease -Recurse

  $installedEntrypoint = Join-Path $installedRelease "bin\dala.bat"
  $queueExpression = "Dala.Updater.queue_windows_activation ~s/$goodVersion/"
  & $installedEntrypoint rpc $queueExpression
  if ($LASTEXITCODE -ne 0) { throw "Running release could not queue $goodVersion" }

  $successStatus = Wait-UpdateState (Join-Path $InstallRoot "update-status.json") "succeeded"
  if ((Get-Content -LiteralPath $currentFile -Raw).Trim() -ne $goodVersion) {
    throw "Successful activation did not select $goodVersion"
  }

  if ($successStatus.state -ne "succeeded") { throw "Expected succeeded update status" }
  if ((Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop).State -notin @("Running", "Ready")) {
    throw "Successful activation did not leave the scheduled task registered"
  }

  Write-Output "Windows lifecycle verified: install, installer rollback, update rollback, and activation"
} finally {
  & $uninstaller -InstallRoot $InstallRoot -TaskName $TaskName
  Remove-Item -LiteralPath $installerFixture -Recurse -Force -ErrorAction SilentlyContinue
}

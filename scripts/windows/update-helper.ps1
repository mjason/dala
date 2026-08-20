[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$RequestPath,
  [string]$HelperTaskName
)

$ErrorActionPreference = "Stop"

function Write-Utf8NoBom([string]$Path, [string]$Value) {
  [System.IO.File]::WriteAllText($Path, $Value, [System.Text.UTF8Encoding]::new($false))
}

function Write-UpdateStatus([string]$Path, [string]$State, [string]$Message, [string]$Version) {
  $status = [ordered]@{
    state = $State
    message = $Message
    version = $Version
    updatedAt = [DateTimeOffset]::UtcNow.ToString("O")
  }
  Write-Utf8NoBom $Path (($status | ConvertTo-Json -Compress) + "`r`n")
}

function Get-DalaEntrypoint([string]$Root, [string]$Version) {
  Join-Path $Root "versions\$Version\bin\dala.bat"
}

function Get-DalaReleaseVersion([string]$Entrypoint) {
  $output = & $Entrypoint eval 'version = Application.spec :dala, :vsn; IO.write to_string version'
  if ($LASTEXITCODE -ne 0) { throw "Could not read Dala release version using $Entrypoint" }
  $version = ($output | Select-Object -Last 1).ToString().Trim()
  if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$') {
    throw "Dala returned an invalid release version: $version"
  }
  return $version
}

function Get-DalaReleasePid([string]$Entrypoint) {
  if (-not (Test-Path -LiteralPath $Entrypoint)) { return $null }

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

function Wait-DalaHealthy([string]$Url, [string]$ExpectedVersion, [string]$TaskName, [string]$Entrypoint, [int]$Attempts) {
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

function Wait-DalaTaskStopped([string]$TaskName, [int]$Attempts) {
  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task -or $task.State -ne "Running") { return $true }
    if ($attempt -lt $Attempts) { Start-Sleep -Seconds 1 }
  }

  return $false
}

function Stop-DalaTask([string]$TaskName, [string]$Entrypoint, [int]$Attempts) {
  $releasePid = Get-DalaReleasePid $Entrypoint
  if ($null -ne $releasePid) {
    & {
      $ErrorActionPreference = "SilentlyContinue"
      & $Entrypoint stop 2>&1 | Write-Verbose
    }

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
      if ($null -eq (Get-Process -Id $releasePid -ErrorAction SilentlyContinue)) { break }
      if ($attempt -lt $Attempts) { Start-Sleep -Seconds 1 }
    }

    if ($null -ne (Get-Process -Id $releasePid -ErrorAction SilentlyContinue)) {
      $process = Get-CimInstance Win32_Process -Filter "ProcessId=$releasePid" -ErrorAction SilentlyContinue
      $versionRoot = Split-Path (Split-Path $Entrypoint -Parent) -Parent
      $versionsRoot = Split-Path $versionRoot -Parent
      $expectedPrefix = $versionsRoot.TrimEnd('\') + '\'
      if ($null -eq $process -or
          -not $process.ExecutablePath.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
      }
      Stop-Process -Id $releasePid -Force
    }
  }

  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  return Wait-DalaTaskStopped $TaskName $Attempts
}

function Set-CurrentVersion([string]$CurrentFile, [string]$Version, [string]$BackupFile) {
  $fresh = "$CurrentFile.$PID.new"
  Write-Utf8NoBom $fresh ($Version + "`r`n")
  [System.IO.File]::Replace($fresh, $CurrentFile, $BackupFile, $true)
}

function Restore-CurrentVersion([string]$CurrentFile, [string]$BackupFile) {
  if (-not (Test-Path -LiteralPath $BackupFile)) {
    throw "Rollback pointer is missing: $BackupFile"
  }

  # File.Replace requires a real destination-backup path on Windows; passing
  # $null raises before the pointer can be restored.
  $failedVersionBackup = "$CurrentFile.$PID.failed"
  Remove-Item -LiteralPath $failedVersionBackup -Force -ErrorAction SilentlyContinue
  [System.IO.File]::Replace($BackupFile, $CurrentFile, $failedVersionBackup, $true)
  Remove-Item -LiteralPath $failedVersionBackup -Force -ErrorAction SilentlyContinue
}

$request = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json
$installRoot = [System.IO.Path]::GetFullPath([string]$request.installRoot)
$targetVersion = [string]$request.targetVersion
$taskName = [string]$request.taskName
$healthUrl = [string]$request.healthUrl
$attempts = if ($request.healthCheckAttempts) { [int]$request.healthCheckAttempts } else { 30 }
$currentFile = Join-Path $installRoot "current.txt"
$statusFile = Join-Path $installRoot "update-status.json"
$backupFile = Join-Path $installRoot ".current.rollback"

try {
  if ($targetVersion -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$') {
    throw "Invalid target version: $targetVersion"
  }
  if (-not (Test-Path -LiteralPath $currentFile)) { throw "Missing $currentFile" }
  if ($null -eq (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
    throw "Scheduled task '$taskName' is not registered"
  }

  $previousVersion = (Get-Content -LiteralPath $currentFile -Raw).Trim()
  $previousEntrypoint = Get-DalaEntrypoint $installRoot $previousVersion
  $targetEntrypoint = Get-DalaEntrypoint $installRoot $targetVersion
  if (-not (Test-Path -LiteralPath $targetEntrypoint)) {
    throw "Target release entrypoint is missing: $targetEntrypoint"
  }
  $previousReleaseVersion = Get-DalaReleaseVersion $previousEntrypoint
  $targetReleaseVersion = Get-DalaReleaseVersion $targetEntrypoint
} catch {
  Write-UpdateStatus $statusFile "failed" $_.Exception.Message $targetVersion
  Remove-Item -LiteralPath $RequestPath -Force -ErrorAction SilentlyContinue
  if ($HelperTaskName) {
    Unregister-ScheduledTask -TaskName $HelperTaskName -Confirm:$false -ErrorAction SilentlyContinue
  }
  throw
}

Write-UpdateStatus $statusFile "applying" "Stopping $previousVersion" $targetVersion
try {
  if (-not (Stop-DalaTask $taskName $previousEntrypoint $attempts)) {
    throw "Scheduled task '$taskName' did not stop"
  }
  Set-CurrentVersion $currentFile $targetVersion $backupFile
  Start-ScheduledTask -TaskName $taskName

  if (-not (Wait-DalaHealthy $healthUrl $targetReleaseVersion $taskName $targetEntrypoint $attempts)) {
    throw "$targetVersion did not become healthy at $healthUrl"
  }

  Remove-Item -LiteralPath $backupFile -Force -ErrorAction SilentlyContinue
  Write-UpdateStatus $statusFile "succeeded" "Activated $targetVersion" $targetVersion
} catch {
  $activationError = $_.Exception.Message
  $rollbackError = $null

  try {
    if (-not (Stop-DalaTask $taskName $targetEntrypoint $attempts)) {
      throw "Target task did not stop; rollback was not attempted"
    }

    if (Test-Path -LiteralPath $backupFile) {
      Restore-CurrentVersion $currentFile $backupFile
    } else {
      Write-Utf8NoBom $currentFile ($previousVersion + "`r`n")
    }

    Start-ScheduledTask -TaskName $taskName
    $rollbackHealthy = Wait-DalaHealthy $healthUrl $previousReleaseVersion $taskName $previousEntrypoint $attempts
    $rollbackMessage =
      if ($rollbackHealthy) {
        "Rolled back to $previousVersion"
      } else {
        "Rollback to $previousVersion also failed health check"
      }
  } catch {
    $rollbackError = $_.Exception.Message
  }

  if ($rollbackError) {
    $message = "$activationError. Rollback failed: $rollbackError"
    Write-UpdateStatus $statusFile "failed" $message $targetVersion
    throw $message
  }

  $state = if ($rollbackHealthy) { "rolled_back" } else { "failed" }
  Write-UpdateStatus $statusFile $state "$activationError. $rollbackMessage" $targetVersion
  throw "$activationError. $rollbackMessage"
} finally {
  Remove-Item -LiteralPath $RequestPath -Force -ErrorAction SilentlyContinue
  if ($HelperTaskName) {
    Unregister-ScheduledTask -TaskName $HelperTaskName -Confirm:$false -ErrorAction SilentlyContinue
  }
}

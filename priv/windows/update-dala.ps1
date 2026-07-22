[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$InstallRoot,
  [Parameter(Mandatory = $true)][string]$TaskName,
  [Parameter(Mandatory = $true)][string]$TargetTag,
  [string]$PreviousTag,
  [Parameter(Mandatory = $true)][string]$ExpectedVersion,
  [string]$PreviousVersion,
  [Parameter(Mandatory = $true)][string]$AttemptId,
  [string]$ResultFile,
  [int]$DelayMilliseconds = 0,
  [int]$HealthTimeoutSeconds = 90,
  [Parameter(DontShow = $true)][ValidateRange(0, 120000)][int]$LockTimeoutMilliseconds = 30000
)

$ErrorActionPreference = "Stop"
$TagPattern = '^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$'
$Root = [IO.Path]::GetFullPath($InstallRoot).TrimEnd([char[]]"\/")
$MetadataFile = Join-Path $Root "install.json"
$CurrentFile = Join-Path $Root "current.txt"
$Runner = Join-Path $Root "run-dala.ps1"
$RunnerBackup = Join-Path $Root (".run-dala.rollback-" + [guid]::NewGuid().ToString("N") + ".ps1")
$TargetDir = Join-Path $Root "versions\$TargetTag"
$TargetExecutable = Join-Path $TargetDir "bin\dala.bat"
$TargetRunner = Join-Path $TargetDir "run-dala.ps1"
$PreviousDir = if ($PreviousTag) { Join-Path $Root "versions\$PreviousTag" } else { $null }
$PreviousExecutable = if ($PreviousDir) { Join-Path $PreviousDir "bin\dala.bat" } else { $null }
$PreviousRunner = if ($PreviousDir) { Join-Path $PreviousDir "run-dala.ps1" } else { $null }
$Port = 4400
$HadRunner = $false
$UpdateLock = $null

function Invoke-RecoverableFileReplace(
  [Parameter(Mandatory = $true)][string]$Source,
  [Parameter(Mandatory = $true)][string]$Destination,
  [scriptblock]$ReplaceOperation
) {
  $destinationParent = Split-Path -Parent $Destination
  $destinationLeaf = Split-Path -Leaf $Destination
  # Any leftover backup for this destination is ambiguous, regardless of
  # which previous release generated its token. Refuse to guess recovery.
  $backupPattern = '^' + [regex]::Escape($destinationLeaf) + '\.backup-.+$'
  $existingBackups = @(
    Get-ChildItem -LiteralPath $destinationParent -Force -ErrorAction Stop |
      Where-Object { $_.Name -match $backupPattern }
  )
  if ($existingBackups.Count -gt 0) {
    throw "Existing recovery backup requires manual recovery: $($existingBackups[0].FullName)"
  }

  do {
    $backup = "$Destination.backup-$([guid]::NewGuid().ToString('N'))"
  } while (Test-Path -LiteralPath $backup)

  if (-not $ReplaceOperation) {
    $ReplaceOperation = {
      param([string]$SourcePath, [string]$DestinationPath, [string]$BackupPath)
      [IO.File]::Replace($SourcePath, $DestinationPath, $BackupPath)
    }
  }

  $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Source -ErrorAction Stop).Hash
  $reportedErrorAfterCommit = $false
  $postCommitError = $null
  try {
    & $ReplaceOperation $Source $Destination $backup
  } catch {
    $replaceError = $_
    $recoveryFailure = $null

    try {
      $destinationExists = Test-Path -LiteralPath $Destination -ErrorAction Stop
      $backupExists = Test-Path -LiteralPath $backup -ErrorAction Stop
      if ($destinationExists) {
        $destinationHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination -ErrorAction Stop).Hash
        $reportedErrorAfterCommit = $destinationHash -ceq $sourceHash
      }

      if ($reportedErrorAfterCommit) {
        $postCommitError = $replaceError.Exception.Message
      } elseif (-not $destinationExists -and $backupExists) {
        $backupAttributes = [IO.File]::GetAttributes($backup)
        if (($backupAttributes -band [IO.FileAttributes]::Directory) -ne 0 -or
            ($backupAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
          $recoveryFailure = "recovery backup is not a regular file and remains at $backup"
        } else {
          [IO.File]::Move($backup, $Destination)
        }
      } elseif (-not $destinationExists) {
        $recoveryFailure = "destination and recovery backup are both missing"
      } elseif ($backupExists) {
        $recoveryFailure = "replacement state is ambiguous; recovery backup remains at $backup"
      } else {
        # A destination that remains present without a backup is not proof
        # that Replace never moved bytes. Keep the source for manual recovery
        # instead of deleting the only possible new copy.
        $recoveryFailure = "replacement state is ambiguous; destination remains but no recovery backup was observed"
      }
    } catch {
      $recoveryFailure = "could not restore destination; recovery backup remains at $backup`: $($_.Exception.Message)"
    }

    if ($recoveryFailure) {
      if (Test-Path -LiteralPath $Source) {
        $recoveryFailure += "; replacement source remains at $Source"
      }
      throw "$($replaceError.Exception.Message); $recoveryFailure"
    }

    if (-not $reportedErrorAfterCommit) {
      Remove-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue
      throw $replaceError
    }
  }

  if ($reportedErrorAfterCommit) {
    Write-Warning "Replacement reported an error after the destination was verified as committed: $postCommitError" `
      -WarningAction Continue
    try {
      if (Test-Path -LiteralPath $Source -ErrorAction Stop) {
        Remove-Item -LiteralPath $Source -Force -ErrorAction Stop
      }
    } catch {
      Write-Warning "Could not clean committed replacement source at $Source`: $($_.Exception.Message)" `
        -WarningAction Continue
    }
  }

  try {
    if (Test-Path -LiteralPath $backup -ErrorAction Stop) {
      $backupAttributes = [IO.File]::GetAttributes($backup)
      if (($backupAttributes -band [IO.FileAttributes]::Directory) -ne 0 -or
          ($backupAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "recovery backup is not a regular file"
      }
      Remove-Item -LiteralPath $backup -Force -ErrorAction Stop
    }
  } catch {
    # The destination replacement has already committed. A cleanup failure
    # must not turn a successful pointer/result write into a transaction
    # failure that rolls the release back; leave the backup for recovery.
    Write-Warning "Replaced $Destination but could not remove recovery backup at $backup`: $($_.Exception.Message)" `
      -WarningAction Continue
  }
}

function Write-UpdateResult([bool]$Success, [bool]$RolledBack, [string]$Message) {
  if ([string]::IsNullOrWhiteSpace($ResultFile)) { return }

  if (-not (Test-NoReparseAncestors $ResultFile)) {
    throw "Refusing to write update result through a reparse point: $ResultFile"
  }

  $parent = Split-Path -Parent $ResultFile
  if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  $fresh = "$ResultFile.new-$([guid]::NewGuid().ToString('N'))"
  $result = [ordered]@{
    attempt_id = $AttemptId
    success = $Success
    rolled_back = $RolledBack
    target = $TargetTag
    previous = $PreviousTag
    message = $Message
    completed_at = [DateTimeOffset]::UtcNow.ToString("o")
  }
  [IO.File]::WriteAllText($fresh, ($result | ConvertTo-Json -Depth 3) + "`n", [Text.UTF8Encoding]::new($false))

  $helperOwnsFresh = $false
  try {
    if (Test-Path -LiteralPath $ResultFile -PathType Leaf) {
      $helperOwnsFresh = $true
      Invoke-RecoverableFileReplace $fresh $ResultFile
    } else {
      [IO.File]::Move($fresh, $ResultFile)
    }
  } finally {
    if (-not $helperOwnsFresh) {
      Remove-Item -LiteralPath $fresh -Force -ErrorAction SilentlyContinue
    }
  }
}

function Assert-Tag([string]$Tag, [string]$Label) {
  if ([string]::IsNullOrWhiteSpace($Tag) -or $Tag -cnotmatch $TagPattern) {
    throw "Invalid $Label version pointer: $Tag"
  }
}

function Assert-TaskName([string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 238 -or
      $Name -match '[\\/:*?"<>|\[\]]' -or $Name -match '[\r\n]' -or $Name.Trim() -cne $Name) {
    throw "Invalid Scheduled Task name: $Name"
  }
}

function Assert-AttemptId([string]$Value) {
  $parsed = [guid]::Empty
  if (-not [guid]::TryParseExact($Value, "D", [ref]$parsed) -or
      $parsed.ToString("D") -cne $Value) {
    throw "Invalid AttemptId: expected a canonical UUID"
  }
}

function Enter-UpdateLock([int]$TimeoutMilliseconds) {
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $name = "Global\DalaLifecycle-" + ($sid.Value -replace '[^0-9A-Za-z_-]', '_')
  $created = $false
  $mutex = [Threading.Mutex]::new($false, $name, [ref]$created)
  try {
    if (-not $mutex.WaitOne($TimeoutMilliseconds)) {
      $mutex.Dispose()
      throw "another Dala update is already in progress"
    }
  } catch [Threading.AbandonedMutexException] {
    # WaitOne grants ownership when the previous process exited unexpectedly.
  } catch {
    $mutex.Dispose()
    throw
  }
  $mutex
}

function Test-SamePath([string]$Left, [string]$Right) {
  $leftFull = [IO.Path]::GetFullPath($Left).TrimEnd([char[]]"\/")
  $rightFull = [IO.Path]::GetFullPath($Right).TrimEnd([char[]]"\/")
  $leftFull.Equals($rightFull, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-DalaTaskPrincipal($Task) {
  $expectedSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $userId = [string]$Task.Principal.UserId
  try {
    $actualSid = if ($userId -match '^S-[0-9-]+$') {
      [Security.Principal.SecurityIdentifier]::new($userId).Value
    } else {
      ([Security.Principal.NTAccount]::new($userId)).Translate([Security.Principal.SecurityIdentifier]).Value
    }
  } catch {
    throw "Scheduled task '$($Task.TaskName)' is not owned by this Dala installation"
  }

  if ($actualSid -cne $expectedSid -or
      [string]$Task.Principal.LogonType -cne "Interactive" -or
      [string]$Task.Principal.RunLevel -cne "Limited") {
    throw "Scheduled task '$($Task.TaskName)' is not owned by this Dala installation"
  }
}

function Read-InstallMetadata([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Dala install metadata is missing: $Path"
  }

  try {
    $metadata = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($name in @("schemaVersion", "root", "dataDir", "configFile", "taskName", "port", "repo", "platform")) {
      if ($metadata.PSObject.Properties.Name -notcontains $name) { throw "required field '$name' is missing" }
    }
    if ([int]$metadata.schemaVersion -ne 1) { throw "unsupported schemaVersion" }
    foreach ($name in @("root", "dataDir", "configFile", "taskName", "repo", "platform")) {
      if ([string]::IsNullOrWhiteSpace([string]$metadata.$name)) { throw "field '$name' is empty" }
    }
    if ([int]$metadata.port -lt 1 -or [int]$metadata.port -gt 65535) { throw "invalid port" }
    if ([string]$metadata.platform -ne "windows-x86_64") { throw "unsupported platform" }
    $metadata
  } catch {
    throw "Invalid Dala install metadata at $Path`: $($_.Exception.Message)"
  }
}

function Get-ReleaseVersion([string]$VersionOrTag) {
  if ([string]::IsNullOrWhiteSpace($VersionOrTag)) { return $null }
  $version = if ($VersionOrTag.StartsWith("v", [StringComparison]::Ordinal)) {
    $VersionOrTag.Substring(1)
  } else {
    $VersionOrTag
  }
  if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') { return $null }
  $version
}

function Get-ReleaseDirVersion([string]$ReleaseDir) {
  $leaf = Split-Path -Leaf ([IO.Path]::GetFullPath($ReleaseDir).TrimEnd([char[]]"\/"))
  Get-ReleaseVersion $leaf
}

function Get-ReleaseHelper([string]$ReleaseDir, [string]$Version, [string]$RelativePath) {
  if ([string]::IsNullOrWhiteSpace($Version)) { $Version = Get-ReleaseDirVersion $ReleaseDir }
  $version = Get-ReleaseVersion $Version
  if (-not $version) { return $null }
  $candidate = Join-Path (Join-Path $ReleaseDir "lib\dala-$version") $RelativePath
  if (-not (Test-NoReparseAncestors $candidate)) { return $null }
  if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $null }
  try {
    if (([IO.File]::GetAttributes($candidate) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }
  } catch {
    return $null
  }
  [IO.Path]::GetFullPath($candidate)
}

function Get-TaskLauncher([string]$ReleaseDir, [string]$Version) {
  Get-ReleaseHelper $ReleaseDir $Version "priv\bin\dala_task_launcher.exe"
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
      if (-not (Test-Path -LiteralPath $current)) { break }
      if (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        return $false
      }
    }
    $true
  } catch {
    $false
  }
}

function Assert-SafeWritePath([string]$Path, [string]$Label) {
  if (-not (Test-NoReparseAncestors $Path)) {
    throw "Refusing to access $Label through a reparse point: $Path"
  }
  if (Test-Path -LiteralPath $Path) {
    try {
      if (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to access $Label reparse point: $Path"
      }
    } catch {
      if ($_.Exception.Message -like "Refusing to access*") { throw }
      throw "Could not inspect $Label safely: $($_.Exception.Message)"
    }
  }
}

function Test-NoReparsePoints([string]$Path) {
  try {
    if (-not (Test-NoReparseAncestors $Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    if (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $true }
    foreach ($entry in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) {
      if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
      if ($entry.PSIsContainer -and -not (Test-NoReparsePoints $entry.FullName)) { return $false }
    }
    $true
  } catch {
    $false
  }
}

function Test-CompleteDalaRelease([string]$Path, [string]$Version) {
  try {
    $version = Get-ReleaseVersion $Version
    if (-not $version -or -not (Test-Path -LiteralPath $Path -PathType Container) -or
        -not (Test-NoReparsePoints $Path)) { return $false }
    foreach ($relative in @("bin\dala.bat", "run-dala.ps1", "releases\start_erl.data")) {
      if (-not (Test-Path -LiteralPath (Join-Path $Path $relative) -PathType Leaf)) { return $false }
    }
    $tokens = @((Get-Content -LiteralPath (Join-Path $Path "releases\start_erl.data") -Raw).Trim() -split '\s+')
    if ($tokens.Count -ne 2 -or [string]$tokens[1] -cne $version) { return $false }
    $erts = [string]$tokens[0]
    if ($erts -notmatch '^[0-9A-Za-z._-]+$') { return $false }
    foreach ($relative in @(
      "releases\$version\start.boot",
      "releases\$version\dala.rel",
      "erts-$erts\bin\erl.exe",
      "lib\dala-$version\ebin\dala.app",
      "lib\dala-$version\ebin\Elixir.Dala.beam",
      "lib\dala-$version\priv\bin\dala_task_launcher.exe",
      "lib\dala-$version\priv\windows\update-dala.ps1",
      "lib\dala-$version\priv\windows\restart-dala.ps1",
      "lib\dala-$version\priv\windows\publish-dala.ps1"
    )) {
      if (-not (Test-Path -LiteralPath (Join-Path $Path $relative) -PathType Leaf)) { return $false }
    }
    $app = Get-Content -LiteralPath (Join-Path $Path "lib\dala-$version\ebin\dala.app") -Raw
    $matches = [regex]::Matches($app, '\{vsn,\s*"([^"]+)"\}')
    $matches.Count -eq 1 -and $matches[0].Groups[1].Value -ceq $version
  } catch {
    $false
  }
}

function Get-ReleaseIdentity([string]$DalaExecutable) {
  if ([string]::IsNullOrWhiteSpace($DalaExecutable)) { return $null }
  $releaseDir = [IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $DalaExecutable))).TrimEnd([char[]]"\/")
  $tag = Split-Path -Leaf $releaseDir
  $version = Get-ReleaseVersion $tag
  if (-not $version) { throw "Cannot inspect Dala release with an invalid version directory: $releaseDir" }
  $expectedDalaExecutable = Join-Path $releaseDir "bin\dala.bat"
  if (-not (Test-SamePath $DalaExecutable $expectedDalaExecutable)) {
    throw "Dala executable is outside its release layout: $DalaExecutable"
  }
  $startData = @((Get-Content -LiteralPath (Join-Path $releaseDir "releases\start_erl.data") -Raw).Trim() -split '\s+')
  if ($startData.Count -ne 2 -or [string]$startData[1] -cne $version) {
    throw "Cannot inspect Dala release with malformed start_erl.data: $releaseDir"
  }
  $erts = [string]$startData[0]
  if ($erts -notmatch '^[0-9A-Za-z._-]+$') { throw "Cannot inspect Dala release with invalid ERTS version: $releaseDir" }
  $expectedExecutable = Join-Path $releaseDir "erts-$erts\bin\erl.exe"
  [pscustomobject]@{
    ReleaseDir = $releaseDir
    Version = $version
    Executable = [IO.Path]::GetFullPath($expectedExecutable)
    Boot = [IO.Path]::GetFullPath((Join-Path $releaseDir "releases\$version\start"))
    BootFile = [IO.Path]::GetFullPath((Join-Path $releaseDir "releases\$version\start.boot"))
  }
}

function Test-ReleaseBootCommand([string]$CommandLine, [string[]]$BootCandidates) {
  $command = $CommandLine.Replace('/', '\')
  foreach ($boot in $BootCandidates) {
    $normalizedBoot = ([string]$boot).Replace('/', '\')
    $escapedBoot = [regex]::Escape($normalizedBoot)
    $pattern = '(?:^|\s)--?boot(?:=|\s+)(?:"' + $escapedBoot + '"|' + $escapedBoot + ')(?=\s|$)'
    if ([regex]::IsMatch($command, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
      return $true
    }
  }
  $false
}

function Get-DalaTaskExact([string]$Name) {
  $tasks = @(
    Get-ScheduledTask -TaskPath "\" -ErrorAction Stop |
      Where-Object { [string]$_.TaskName -ceq $Name }
  )
  if ($tasks.Count -gt 1) { throw "Multiple root Scheduled Tasks match '$Name'" }
  if ($tasks.Count -eq 1) { return $tasks[0] }
  $null
}

function Assert-DalaTaskObjectOwnership($Task, [string]$ReleaseDir) {
  if (-not $Task) { throw "Dala scheduled task is missing: $TaskName" }
  Assert-DalaTaskPrincipal $Task

  $launcher = Get-TaskLauncher $ReleaseDir (Get-ReleaseDirVersion $ReleaseDir)
  if (-not $launcher) { throw "Release is missing dala_task_launcher.exe: $ReleaseDir" }
  $actions = @($Task.Actions)
  $logFile = Join-Path $Root "logs\server.log"
  $expectedArguments = "`"$Runner`" `"$logFile`""
  if ($actions.Count -ne 1 -or
      -not (Test-SamePath ([string]$actions[0].Execute) $launcher) -or
      [string]$actions[0].Arguments -cne $expectedArguments) {
    throw "Scheduled task '$TaskName' is not owned by this Dala installation"
  }
}

function Assert-DalaTaskOwnership([string]$ReleaseDir) {
  $task = Get-DalaTaskExact $TaskName
  Assert-DalaTaskObjectOwnership $task $ReleaseDir
}

function Stop-DalaTaskVerified([string]$ReleaseDir) {
  $task = Get-DalaTaskExact $TaskName
  Assert-DalaTaskObjectOwnership $task $ReleaseDir
  if ([string]$task.State -notin @("Running", "Queued")) { return }

  $stopError = $null
  try {
    Stop-ScheduledTask -TaskName $TaskName -TaskPath "\" -ErrorAction Stop
  } catch {
    $stopError = $_.Exception.Message
  }

  for ($attempt = 0; $attempt -lt 50; $attempt++) {
    $task = Get-DalaTaskExact $TaskName
    if (-not $task -or [string]$task.State -notin @("Running", "Queued")) { break }
    Start-Sleep -Milliseconds 100
  }
  Assert-DalaTaskObjectOwnership $task $ReleaseDir
  if ([string]$task.State -in @("Running", "Queued")) {
    $message = "Scheduled Task '$TaskName' remained active after stop"
    if ($stopError) { $message = "$stopError; $message" }
    throw $message
  }
  if ($stopError) {
    Write-Warning "Scheduled Task stop reported an error after '$TaskName' stopped: $stopError" `
      -WarningAction Continue
  }
}

function Start-DalaTaskVerified([string]$ReleaseDir) {
  $task = Get-DalaTaskExact $TaskName
  Assert-DalaTaskObjectOwnership $task $ReleaseDir

  $startError = $null
  try {
    Start-ScheduledTask -TaskName $TaskName -TaskPath "\" -ErrorAction Stop
  } catch {
    $startError = $_.Exception.Message
  }

  $task = $null
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    $task = Get-DalaTaskExact $TaskName
    if ($task -and [string]$task.State -in @("Running", "Queued")) { break }
    Start-Sleep -Milliseconds 100
  }
  Assert-DalaTaskObjectOwnership $task $ReleaseDir
  if ([string]$task.State -notin @("Running", "Queued")) {
    $message = "Scheduled Task '$TaskName' did not enter a running state"
    if ($startError) { $message = "$startError; $message" }
    throw $message
  }
  if ($startError) {
    Write-Warning "Scheduled Task start reported an error after '$TaskName' started: $startError" `
      -WarningAction Continue
  }
}

function Get-ReleaseBeamProcesses([string]$Executable) {
  $identity = Get-ReleaseIdentity $Executable
  if (-not $identity) { return @() }
  $releaseProcesses = @()
  foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='erl.exe'" -ErrorAction Stop)) {
    if ($null -eq $process) {
      throw "Cannot determine the identity of an erl.exe process; refusing to continue"
    }

    # A missing CIM identity field is not evidence that the process is
    # unrelated. Treat it as an ambiguous live process so a stop/replace
    # operation cannot proceed while an unknown BEAM may still be running.
    $processExecutable = [string]$process.ExecutablePath
    $processCommandLine = [string]$process.CommandLine
    if ([string]::IsNullOrWhiteSpace($processExecutable) -or
        [string]::IsNullOrWhiteSpace($processCommandLine)) {
      throw "Cannot determine the identity of an erl.exe process; refusing to continue"
    }
    if (-not (Test-SamePath $processExecutable $identity.Executable)) { continue }

    if (-not (Test-ReleaseBootCommand $processCommandLine @($identity.Boot, $identity.BootFile))) {
      throw "Cannot confirm the Dala release identity of erl.exe at $processExecutable; refusing to continue"
    }
    if ($null -eq $process.PSObject.Properties["ProcessId"] -or
        [string]::IsNullOrWhiteSpace([string]$process.ProcessId)) {
      throw "Cannot determine the process id of an erl.exe process; refusing to continue"
    }
    $releaseProcesses += $process
  }
  $releaseProcesses
}

function Stop-DalaRelease([string]$Executable) {
  if ([string]::IsNullOrWhiteSpace($Executable)) {
    throw "Cannot stop Dala release: executable path is empty"
  }
  try {
    $executableExists = Test-Path -LiteralPath $Executable -PathType Leaf -ErrorAction Stop
  } catch {
    throw "Cannot inspect Dala release executable '$Executable': $($_.Exception.Message)"
  }
  if (-not $executableExists) {
    throw "Cannot stop Dala release: executable is missing or not a regular file: $Executable"
  }

  try {
    & $Executable stop 2>$null | Out-Null
  } catch {
    # An unhealthy release may reject RPC stop. The identity-checked process
    # probes below remain authoritative and provide the force-stop fallback.
  }
  for ($attempt = 0; $attempt -lt 100; $attempt++) {
    if ((Get-ReleaseBeamProcesses $Executable).Count -eq 0) { return }
    Start-Sleep -Milliseconds 100
  }

  foreach ($process in Get-ReleaseBeamProcesses $Executable) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
  }

  for ($attempt = 0; $attempt -lt 50; $attempt++) {
    if ((Get-ReleaseBeamProcesses $Executable).Count -eq 0) { return }
    Start-Sleep -Milliseconds 100
  }

  throw "Dala release did not stop: $Executable"
}

function Set-Current([string]$Tag) {
  Assert-Tag $Tag "Dala"
  Assert-SafeWritePath $Root "Dala current pointer"
  Assert-SafeWritePath $CurrentFile "Dala current pointer"
  $fresh = Join-Path $Root (".current-" + [guid]::NewGuid().ToString("N") + ".new")
  [IO.File]::WriteAllText($fresh, "$Tag`n", [Text.UTF8Encoding]::new($false))

  $helperOwnsFresh = $false
  try {
    if (Test-Path -LiteralPath $CurrentFile -PathType Leaf) {
      $helperOwnsFresh = $true
      Invoke-RecoverableFileReplace $fresh $CurrentFile
    } else {
      [IO.File]::Move($fresh, $CurrentFile)
    }
  } finally {
    if (-not $helperOwnsFresh) {
      Remove-Item -LiteralPath $fresh -Force -ErrorAction SilentlyContinue
    }
  }
}

function Deploy-Runner([string]$Source) {
  if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
    throw "Release is missing run-dala.ps1: $Source"
  }

  Assert-SafeWritePath $Root "Dala runner"
  Assert-SafeWritePath $Runner "Dala runner"

  $fresh = Join-Path $Root (".run-dala-" + [guid]::NewGuid().ToString("N") + ".new")
  Copy-Item -LiteralPath $Source -Destination $fresh -Force

  $helperOwnsFresh = $false
  try {
    if (Test-Path -LiteralPath $Runner -PathType Leaf) {
      $helperOwnsFresh = $true
      Invoke-RecoverableFileReplace $fresh $Runner
    } else {
      [IO.File]::Move($fresh, $Runner)
    }
  } finally {
    if (-not $helperOwnsFresh) {
      Remove-Item -LiteralPath $fresh -Force -ErrorAction SilentlyContinue
    }
  }
}

function Set-TaskAction([string]$ReleaseDir) {
  Assert-SafeWritePath $Root "Dala installation root"
  Assert-SafeWritePath $Runner "Dala runner"
  $launcher = Get-TaskLauncher $ReleaseDir (Get-ReleaseDirVersion $ReleaseDir)
  if (-not $launcher) { throw "Release is missing priv\bin\dala_task_launcher.exe: $ReleaseDir" }

  $logFile = Join-Path $Root "logs\server.log"
  $action = New-ScheduledTaskAction -Execute $launcher -Argument "`"$Runner`" `"$logFile`""
  $setError = $null
  try {
    Set-ScheduledTask -TaskName $TaskName -TaskPath "\" -Action $action -ErrorAction Stop | Out-Null
  } catch {
    $setError = $_.Exception.Message
  }

  try {
    $task = Get-DalaTaskExact $TaskName
    Assert-DalaTaskObjectOwnership $task $ReleaseDir
  } catch {
    if ($setError) { throw "$setError; could not verify Scheduled Task action: $($_.Exception.Message)" }
    throw
  }
  if ($setError) {
    Write-Warning "Scheduled Task action update reported an error after '$TaskName' was committed: $setError" `
      -WarningAction Continue
  }
}

function Test-ReleaseTaskRunning([string]$ReleaseDir) {
  $task = Get-DalaTaskExact $TaskName
  if ($task) { Assert-DalaTaskObjectOwnership $task $ReleaseDir }
  $task -and [string]$task.State -ceq "Running" -and (Get-ReleaseBeamProcesses (Join-Path $ReleaseDir "bin\dala.bat")).Count -gt 0
}

function Test-ReleaseOwnsPort([string]$ReleaseDir) {
  $releaseProcessIds = @(
    Get-ReleaseBeamProcesses (Join-Path $ReleaseDir "bin\dala.bat") |
      ForEach-Object { [uint32]$_.ProcessId }
  )
  if ($releaseProcessIds.Count -eq 0) { return $false }

  $listenerProcessIds = @(
    Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop |
      Where-Object { $_.LocalAddress -ceq "127.0.0.1" -or $_.LocalAddress -ceq "0.0.0.0" } |
      ForEach-Object { [uint32]$_.OwningProcess }
  )

  foreach ($processId in $releaseProcessIds) {
    if ($listenerProcessIds -contains $processId) { return $true }
  }
  $false
}

function Wait-DalaVersion([string]$Version, [string]$ReleaseDir) {
  $deadline = [DateTime]::UtcNow.AddSeconds($HealthTimeoutSeconds)
  $uri = "http://127.0.0.1:$Port/version"
  $lastHealthError = $null

  while ([DateTime]::UtcNow -lt $deadline) {
    try {
      if (Test-ReleaseTaskRunning $ReleaseDir) {
        $ownedBefore = Test-ReleaseOwnsPort $ReleaseDir
        $response = Invoke-WebRequest -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 2 -Uri $uri
        $ownedAfter = Test-ReleaseOwnsPort $ReleaseDir
        $contentType = [string]$response.Headers["Content-Type"]
        if ($response.StatusCode -eq 200 -and $contentType.StartsWith("text/plain")) {
          $actualVersion = ([string]$response.Content).Trim()
          if ($ownedBefore -and $ownedAfter) {
            if ($actualVersion -ceq $Version) { return }
            if ($actualVersion) { throw "Dala returned version '$actualVersion', expected '$Version'" }
          }
        }
      }
    } catch {
      if ($_.Exception.Message -like "Dala returned version*") { throw }
      $lastHealthError = $_.Exception.Message
    }

    Start-Sleep -Milliseconds 500
  }

  $message = "Dala $Version did not become healthy at $uri"
  if ($lastHealthError) { $message += "; last health probe error: $lastHealthError" }
  throw $message
}

$rolledBack = $false
$switchAttempted = $false
$pointerSwitched = $false
$taskActionSwitched = $false
$failureMessage = $null
Assert-AttemptId $AttemptId
try {
  $UpdateLock = Enter-UpdateLock $LockTimeoutMilliseconds

  try {
    Assert-Tag $TargetTag "target"
    Assert-TaskName $TaskName
    if ($PreviousTag) { Assert-Tag $PreviousTag "previous" }
    $targetVersion = $TargetTag.Substring(1)
    $previousVersionFromTag = if ($PreviousTag) { $PreviousTag.Substring(1) } else { $null }
    if ($PreviousVersion -and $PreviousVersion -cne $previousVersionFromTag) {
      throw "PreviousVersion does not match PreviousTag"
    }
    $metadata = Read-InstallMetadata $MetadataFile
    Assert-SafeWritePath $Root "Dala installation root"
    Assert-SafeWritePath $MetadataFile "Dala install metadata"
    Assert-SafeWritePath $CurrentFile "Dala current pointer"
    Assert-SafeWritePath $Runner "Dala runner"
    if (-not (Test-SamePath $Root ([string]$metadata.root))) {
      throw "InstallRoot does not match Dala install metadata"
    }
    if ([string]$metadata.taskName -cne $TaskName) {
      throw "TaskName does not match Dala install metadata"
    }
    $Port = [int]$metadata.port
    if (-not (Test-CompleteDalaRelease $TargetDir $targetVersion)) {
      throw "Target release is not a complete Dala Windows release: $TargetDir"
    }
    if (-not $PreviousTag) { throw "PreviousTag is required for an existing Dala task" }
    if (-not (Test-CompleteDalaRelease $PreviousDir $previousVersionFromTag)) {
      throw "Previous release is not a complete Dala Windows release: $PreviousDir"
    }
    if ($DelayMilliseconds -gt 0) { Start-Sleep -Milliseconds $DelayMilliseconds }

    $actualPreviousTag = $null
    if (Test-Path -LiteralPath $CurrentFile -PathType Leaf) {
      $actualPreviousTag = (Get-Content -LiteralPath $CurrentFile -Raw).Trim()
      Assert-Tag $actualPreviousTag "current"
    }
    if (($PreviousTag -and $actualPreviousTag -cne $PreviousTag) -or
        (-not $PreviousTag -and $actualPreviousTag)) {
      $actualLabel = if ($actualPreviousTag) { $actualPreviousTag } else { "<missing>" }
      $expectedLabel = if ($PreviousTag) { $PreviousTag } else { "<missing>" }
      throw "current release changed from $expectedLabel to $actualLabel during update"
    }

    Assert-DalaTaskOwnership $PreviousDir

    $HadRunner = Test-Path -LiteralPath $Runner -PathType Leaf
    if ($HadRunner) { Copy-Item -LiteralPath $Runner -Destination $RunnerBackup -Force }

    $switchAttempted = $true
    Stop-DalaTaskVerified $PreviousDir
    Stop-DalaRelease $PreviousExecutable
    Deploy-Runner $TargetRunner
    Set-Current $TargetTag
    $pointerSwitched = $true
    Set-TaskAction $TargetDir
    $taskActionSwitched = $true
    Start-DalaTaskVerified $TargetDir
    Wait-DalaVersion $ExpectedVersion $TargetDir

    Write-UpdateResult $true $false "updated to $TargetTag"
  } catch {
    $failureMessage = $_.Exception.Message

    if ($switchAttempted) {
      try {
        $actualRollbackTag = $null
        if (Test-Path -LiteralPath $CurrentFile -PathType Leaf) {
          $actualRollbackTag = (Get-Content -LiteralPath $CurrentFile -Raw).Trim()
          Assert-Tag $actualRollbackTag "current"
        }
        $expectedRollbackTag = if ($pointerSwitched) { $TargetTag } else { $PreviousTag }
        if (($expectedRollbackTag -and $actualRollbackTag -cne $expectedRollbackTag) -or
            (-not $expectedRollbackTag -and $actualRollbackTag)) {
          $actualLabel = if ($actualRollbackTag) { $actualRollbackTag } else { "<missing>" }
          $expectedLabel = if ($expectedRollbackTag) { $expectedRollbackTag } else { "<missing>" }
          throw "current release changed from $expectedLabel to $actualLabel during update; refusing rollback"
        }

        $expectedTaskDir = if ($taskActionSwitched) {
          $TargetDir
        } else {
          Join-Path $Root "versions\$PreviousTag"
        }
        Stop-DalaTaskVerified $expectedTaskDir
        # A failure can occur before the pointer/action switch (for example
        # while stopping the previous release). Probe both identities before
        # restoring the previous task, so rollback cannot leave an old BEAM
        # process running beside the restarted one.
        Stop-DalaRelease $TargetExecutable
        Stop-DalaRelease $PreviousExecutable

        if ($PreviousTag) {
          Set-Current $PreviousTag
          if ($HadRunner -and (Test-Path -LiteralPath $RunnerBackup -PathType Leaf)) {
            Deploy-Runner $RunnerBackup
          } else {
            Deploy-Runner $PreviousRunner
          }

          Set-TaskAction $PreviousDir
          Start-DalaTaskVerified $PreviousDir
          if ($PreviousVersion) { Wait-DalaVersion $PreviousVersion $PreviousDir }
          $rolledBack = $true
        } else {
          Remove-Item -LiteralPath $CurrentFile -Force -ErrorAction SilentlyContinue
          if (-not $HadRunner) { Remove-Item -LiteralPath $Runner -Force -ErrorAction SilentlyContinue }
        }
      } catch {
        $failureMessage += "; rollback failed: $($_.Exception.Message)"
      }
    }

    try {
      Write-UpdateResult $false $rolledBack $failureMessage
    } catch {
      $failureMessage += "; could not persist failure result: $($_.Exception.Message)"
    }
  }
} catch {
  $resultWriteError = $_.Exception.Message
  $failureMessage = if ($failureMessage) {
    "$failureMessage; could not write update result: $resultWriteError"
  } else {
    $resultWriteError
  }
  try {
    Write-UpdateResult $false $rolledBack $failureMessage
  } catch {
    $failureMessage += "; could not persist failure result: $($_.Exception.Message)"
  }
} finally {
  try {
    if (Test-Path -LiteralPath $RunnerBackup -ErrorAction Stop) {
      if (-not (Test-NoReparseAncestors $RunnerBackup) -or
          (([IO.File]::GetAttributes($RunnerBackup) -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "runner backup path contains a reparse point"
      }

      # On an incomplete rollback this may be the only copy of the
      # previously running root runner. Keep it for manual recovery.
      $keepRunnerBackup = [bool]$failureMessage -and -not [bool]$rolledBack
      if ($keepRunnerBackup) {
        Write-Warning "Retaining previous Dala runner backup for recovery: $RunnerBackup" `
          -WarningAction Continue
      } else {
        Remove-Item -LiteralPath $RunnerBackup -Force -ErrorAction Stop
      }
    }
  } catch {
    Write-Warning "Could not clean previous Dala runner backup at $RunnerBackup`: $($_.Exception.Message)" `
      -WarningAction Continue
  }
  if ($UpdateLock) {
    $UpdateLock.ReleaseMutex()
    $UpdateLock.Dispose()
    $UpdateLock = $null
  }
}

if ($failureMessage) {
  Write-Error $failureMessage -ErrorAction Continue
  exit 1
}

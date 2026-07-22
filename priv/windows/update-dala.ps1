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

  try {
    if (Test-Path -LiteralPath $ResultFile -PathType Leaf) {
      [IO.File]::Replace($fresh, $ResultFile, $null)
    } else {
      [IO.File]::Move($fresh, $ResultFile)
    }
  } finally {
    Remove-Item -LiteralPath $fresh -Force -ErrorAction SilentlyContinue
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
  try {
    $releaseDir = [IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $DalaExecutable))).TrimEnd([char[]]"\/")
    $tag = Split-Path -Leaf $releaseDir
    $version = Get-ReleaseVersion $tag
    if (-not $version) { return $null }
    $expectedDalaExecutable = Join-Path $releaseDir "bin\dala.bat"
    if (-not (Test-SamePath $DalaExecutable $expectedDalaExecutable)) { return $null }
    $startData = @((Get-Content -LiteralPath (Join-Path $releaseDir "releases\start_erl.data") -Raw).Trim() -split '\s+')
    if ($startData.Count -ne 2 -or [string]$startData[1] -cne $version) { return $null }
    $erts = [string]$startData[0]
    if ($erts -notmatch '^[0-9A-Za-z._-]+$') { return $null }
    $expectedExecutable = Join-Path $releaseDir "erts-$erts\bin\erl.exe"
    [pscustomobject]@{
      ReleaseDir = $releaseDir
      Version = $version
      Executable = [IO.Path]::GetFullPath($expectedExecutable)
      Boot = [IO.Path]::GetFullPath((Join-Path $releaseDir "releases\$version\start"))
      BootFile = [IO.Path]::GetFullPath((Join-Path $releaseDir "releases\$version\start.boot"))
    }
  } catch {
    $null
  }
}

function Assert-DalaTaskOwnership([string]$ReleaseDir) {
  $task = @(Get-ScheduledTask -TaskName $TaskName -TaskPath "\" -ErrorAction SilentlyContinue)
  if ($task.Count -gt 1) { throw "Multiple root Scheduled Tasks match '$TaskName'" }
  $task = if ($task.Count -eq 1) { $task[0] } else { $null }
  if (-not $task) { throw "Dala scheduled task is missing: $TaskName" }

  Assert-DalaTaskPrincipal $task

  $launcher = Get-TaskLauncher $ReleaseDir (Get-ReleaseDirVersion $ReleaseDir)
  if (-not $launcher) { throw "Release is missing dala_task_launcher.exe: $ReleaseDir" }
  $actions = @($task.Actions)
  $logFile = Join-Path $Root "logs\server.log"
  $expectedArguments = "`"$Runner`" `"$logFile`""
  if ($actions.Count -ne 1 -or
      -not (Test-SamePath ([string]$actions[0].Execute) $launcher) -or
      [string]$actions[0].Arguments -cne $expectedArguments) {
    throw "Scheduled task '$TaskName' is not owned by this Dala installation"
  }
}

function Get-ReleaseBeamProcesses([string]$Executable) {
  $identity = Get-ReleaseIdentity $Executable
  if (-not $identity) { return @() }
  $bootCandidates = @($identity.Boot, $identity.BootFile)
  @(
    Get-CimInstance Win32_Process -Filter "Name='erl.exe'" -ErrorAction SilentlyContinue |
      Where-Object {
        $processExecutable = [string]$_.ExecutablePath
        if ([string]::IsNullOrWhiteSpace($processExecutable) -or
            -not (Test-SamePath $processExecutable $identity.Executable)) { return $false }
        $command = ([string]$_.CommandLine).Replace('/', '\').Replace('"', '')
        foreach ($boot in $bootCandidates) {
          $index = $command.IndexOf($boot, [StringComparison]::OrdinalIgnoreCase)
          if ($index -ge 0) {
            $prefix = $command.Substring(0, $index).TrimEnd()
            if ($prefix.EndsWith("-boot", [StringComparison]::OrdinalIgnoreCase) -or
                $prefix.EndsWith("-boot=", [StringComparison]::OrdinalIgnoreCase) -or
                $prefix.EndsWith("--boot", [StringComparison]::OrdinalIgnoreCase) -or
                $prefix.EndsWith("--boot=", [StringComparison]::OrdinalIgnoreCase)) { return $true }
          }
        }
        $false
      }
  )
}

function Stop-DalaRelease([string]$Executable) {
  if ([string]::IsNullOrWhiteSpace($Executable) -or -not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
    return
  }

  & $Executable stop 2>$null | Out-Null
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

  try {
    if (Test-Path -LiteralPath $CurrentFile -PathType Leaf) {
      [IO.File]::Replace($fresh, $CurrentFile, $null)
    } else {
      [IO.File]::Move($fresh, $CurrentFile)
    }
  } finally {
    Remove-Item -LiteralPath $fresh -Force -ErrorAction SilentlyContinue
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

  try {
    if (Test-Path -LiteralPath $Runner -PathType Leaf) {
      [IO.File]::Replace($fresh, $Runner, $null)
    } else {
      [IO.File]::Move($fresh, $Runner)
    }
  } finally {
    Remove-Item -LiteralPath $fresh -Force -ErrorAction SilentlyContinue
  }
}

function Set-TaskAction([string]$ReleaseDir) {
  Assert-SafeWritePath $Root "Dala installation root"
  Assert-SafeWritePath $Runner "Dala runner"
  $launcher = Get-TaskLauncher $ReleaseDir (Get-ReleaseDirVersion $ReleaseDir)
  if (-not $launcher) { throw "Release is missing priv\bin\dala_task_launcher.exe: $ReleaseDir" }

  $logFile = Join-Path $Root "logs\server.log"
  $action = New-ScheduledTaskAction -Execute $launcher -Argument "`"$Runner`" `"$logFile`""
  Set-ScheduledTask -TaskName $TaskName -TaskPath "\" -Action $action | Out-Null
}

function Test-ReleaseTaskRunning([string]$ReleaseDir) {
  $task = Get-ScheduledTask -TaskName $TaskName -TaskPath "\" -ErrorAction SilentlyContinue
  $task -and [string]$task.State -ceq "Running" -and (Get-ReleaseBeamProcesses (Join-Path $ReleaseDir "bin\dala.bat")).Count -gt 0
}

function Test-ReleaseOwnsPort([string]$ReleaseDir) {
  $releaseProcessIds = @(
    Get-ReleaseBeamProcesses (Join-Path $ReleaseDir "bin\dala.bat") |
      ForEach-Object { [uint32]$_.ProcessId }
  )
  if ($releaseProcessIds.Count -eq 0) { return $false }

  try {
    $listenerProcessIds = @(
      Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop |
        Where-Object { $_.LocalAddress -ceq "127.0.0.1" -or $_.LocalAddress -ceq "0.0.0.0" } |
        ForEach-Object { [uint32]$_.OwningProcess }
    )
  } catch {
    return $false
  }

  foreach ($processId in $releaseProcessIds) {
    if ($listenerProcessIds -contains $processId) { return $true }
  }
  $false
}

function Wait-DalaVersion([string]$Version, [string]$ReleaseDir) {
  $deadline = [DateTime]::UtcNow.AddSeconds($HealthTimeoutSeconds)
  $uri = "http://127.0.0.1:$Port/version"

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
    }

    Start-Sleep -Milliseconds 500
  }

  throw "Dala $Version did not become healthy at $uri"
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
    Stop-ScheduledTask -TaskName $TaskName -TaskPath "\" -ErrorAction SilentlyContinue
    Stop-DalaRelease $PreviousExecutable
    Deploy-Runner $TargetRunner
    Set-Current $TargetTag
    $pointerSwitched = $true
    Set-TaskAction $TargetDir
    $taskActionSwitched = $true
    Start-ScheduledTask -TaskName $TaskName -TaskPath "\"
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
        Assert-DalaTaskOwnership $expectedTaskDir

        Stop-ScheduledTask -TaskName $TaskName -TaskPath "\" -ErrorAction SilentlyContinue
        Stop-DalaRelease $TargetExecutable

        if ($PreviousTag) {
          Set-Current $PreviousTag
          if ($HadRunner -and (Test-Path -LiteralPath $RunnerBackup -PathType Leaf)) {
            Deploy-Runner $RunnerBackup
          } else {
            Deploy-Runner $PreviousRunner
          }

          Set-TaskAction $PreviousDir
          Start-ScheduledTask -TaskName $TaskName -TaskPath "\"
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

    Write-UpdateResult $false $rolledBack $failureMessage
  }
} catch {
  $failureMessage = $_.Exception.Message
  Write-UpdateResult $false $false $failureMessage
} finally {
  if (Test-Path -LiteralPath $RunnerBackup) {
    try {
      if ((Test-NoReparseAncestors $RunnerBackup) -and
          (([IO.File]::GetAttributes($RunnerBackup) -band [IO.FileAttributes]::ReparsePoint) -eq 0)) {
        Remove-Item -LiteralPath $RunnerBackup -Force -ErrorAction SilentlyContinue
      }
    } catch {
    }
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

[CmdletBinding()]
param(
  [string]$Version,
  [string]$ArchivePath,
  [string]$ChecksumPath,
  [string]$ExpectedVersion,
  [int]$HealthTimeoutSeconds = 90,
  [Parameter(DontShow = $true)][string]$AttemptId
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$TagPattern = '^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$'
$RepoPattern = '^[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,98}[A-Za-z0-9])?/[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,98}[A-Za-z0-9])?$'
$Platform = "windows-x86_64"
$DefaultRoot = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "Dala"
$DefaultDataDir = Join-Path $DefaultRoot "data"
$DefaultConfigDir = Join-Path $env:APPDATA "Dala"
$DiscoveryFile = Join-Path $DefaultConfigDir "install.json"
$ExistingMetadata = $null
$LifecycleMutex = $null

function Write-Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Green }

function Read-InstallMetadata([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

  try {
    $metadata = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $required = @("schemaVersion", "root", "dataDir", "configFile", "taskName", "port", "repo", "platform")
    foreach ($name in $required) {
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

function ConvertFrom-DalaJsonc([string]$Body) {
  $withoutComments = [Text.StringBuilder]::new($Body.Length)
  $state = "code"

  for ($index = 0; $index -lt $Body.Length; $index++) {
    $character = $Body[$index]
    $next = if ($index + 1 -lt $Body.Length) { $Body[$index + 1] } else { [char]0 }

    if ($state -eq "line-comment") {
      if ($character -eq "`r" -or $character -eq "`n") {
        [void]$withoutComments.Append($character)
        $state = "code"
      }
      continue
    }
    if ($state -eq "block-comment") {
      if ($character -eq "*" -and $next -eq "/") {
        $index++
        $state = "code"
      } elseif ($character -eq "`r" -or $character -eq "`n") {
        [void]$withoutComments.Append($character)
      }
      continue
    }
    if ($state -eq "string") {
      [void]$withoutComments.Append($character)
      if ($character -eq "\" -and $index + 1 -lt $Body.Length) {
        $index++
        [void]$withoutComments.Append($Body[$index])
      } elseif ($character -eq '"') {
        $state = "code"
      }
      continue
    }

    if ($character -eq '"') {
      [void]$withoutComments.Append($character)
      $state = "string"
    } elseif ($character -eq "/" -and $next -eq "/") {
      $index++
      $state = "line-comment"
    } elseif ($character -eq "/" -and $next -eq "*") {
      [void]$withoutComments.Append(" ")
      $index++
      $state = "block-comment"
    } else {
      [void]$withoutComments.Append($character)
    }
  }
  if ($state -eq "block-comment") { throw "unterminated block comment" }

  $json = $withoutComments.ToString()
  $withoutTrailingCommas = [Text.StringBuilder]::new($json.Length)
  $inString = $false
  for ($index = 0; $index -lt $json.Length; $index++) {
    $character = $json[$index]
    if ($inString) {
      [void]$withoutTrailingCommas.Append($character)
      if ($character -eq "\" -and $index + 1 -lt $json.Length) {
        $index++
        [void]$withoutTrailingCommas.Append($json[$index])
      } elseif ($character -eq '"') {
        $inString = $false
      }
      continue
    }
    if ($character -eq '"') {
      $inString = $true
      [void]$withoutTrailingCommas.Append($character)
      continue
    }
    if ($character -eq ",") {
      $lookahead = $index + 1
      while ($lookahead -lt $json.Length -and [char]::IsWhiteSpace($json[$lookahead])) {
        $lookahead++
      }
      if ($lookahead -lt $json.Length -and ($json[$lookahead] -eq "}" -or $json[$lookahead] -eq "]")) {
        continue
      }
    }
    [void]$withoutTrailingCommas.Append($character)
  }

  $withoutTrailingCommas.ToString() | ConvertFrom-Json
}

function Read-DalaConfig([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

  try {
    $value = ConvertFrom-DalaJsonc (Get-Content -LiteralPath $Path -Raw)
    if ($null -eq $value -or $value -is [Array] -or $value -is [string] -or
        $value -is [ValueType]) {
      throw "top-level value must be an object"
    }
    $value
  } catch {
    throw "Invalid Dala configuration at $Path`: $($_.Exception.Message)"
  }
}

function Get-DalaConfigProperty($Config, [string]$Name) {
  if ($Config) {
    foreach ($property in $Config.PSObject.Properties) {
      if ([string]$property.Name -ceq $Name) { return $property.Value }
    }
  }
  $null
}

function Assert-TaskName([string]$Name) {
  if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 200 -or
      $Name -notmatch '^[^\\/:*?"<>|\[\]\x00-\x1F]+$' -or $Name.Trim() -cne $Name) {
    throw "Invalid Dala serviceName: $Name"
  }
}

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
    # The destination replacement has already committed. Do not report a
    # successful metadata/pointer write as a failed install just because its
    # old-byte recovery backup needs operator cleanup.
    Write-Warning "Replaced $Destination but could not remove recovery backup at $backup`: $($_.Exception.Message)" `
      -WarningAction Continue
  }
}

function Write-TextAtomic([string]$Path, [string]$Body) {
  if (-not (Test-NoReparseAncestors $Path)) {
    throw "Refusing to write through a reparse point: $Path"
  }
  $parent = Split-Path -Parent $Path
  if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  $fresh = "$Path.new-$([guid]::NewGuid().ToString('N'))"
  [IO.File]::WriteAllText($fresh, $Body, [Text.UTF8Encoding]::new($false))

  $helperOwnsFresh = $false
  try {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
      $helperOwnsFresh = $true
      Invoke-RecoverableFileReplace $fresh $Path
    } else {
      [IO.File]::Move($fresh, $Path)
    }
  } finally {
    if (-not $helperOwnsFresh) {
      Remove-Item -LiteralPath $fresh -Force -ErrorAction SilentlyContinue
    }
  }
}

function Write-BytesAtomic([string]$Path, [byte[]]$Body) {
  if (-not (Test-NoReparseAncestors $Path)) {
    throw "Refusing to write through a reparse point: $Path"
  }
  $parent = Split-Path -Parent $Path
  if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  $fresh = "$Path.new-$([guid]::NewGuid().ToString('N'))"
  [IO.File]::WriteAllBytes($fresh, $Body)

  $helperOwnsFresh = $false
  try {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
      $helperOwnsFresh = $true
      Invoke-RecoverableFileReplace $fresh $Path
    } else {
      [IO.File]::Move($fresh, $Path)
    }
  } finally {
    if (-not $helperOwnsFresh) {
      Remove-Item -LiteralPath $fresh -Force -ErrorAction SilentlyContinue
    }
  }
}

function Get-BytesSha256([byte[]]$Body) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    ([BitConverter]::ToString($sha.ComputeHash($Body))).Replace("-", "")
  } finally {
    $sha.Dispose()
  }
}

function Write-JsonAtomic([string]$Path, $Value) {
  Write-TextAtomic $Path (($Value | ConvertTo-Json -Depth 8) + "`n")
}

function Test-SamePath([string]$Left, [string]$Right) {
  $leftFull = [IO.Path]::GetFullPath($Left).TrimEnd([char[]]"\/")
  $rightFull = [IO.Path]::GetFullPath($Right).TrimEnd([char[]]"\/")
  $leftFull.Equals($rightFull, [StringComparison]::OrdinalIgnoreCase)
}

function Write-InstallMetadataPair(
  [string]$RootPath,
  [string]$DiscoveryPath,
  $Value,
  [ref]$RollbackIncomplete
) {
  $RollbackIncomplete.Value = $false
  if (Test-SamePath $RootPath $DiscoveryPath) {
    try {
      Write-JsonAtomic $RootPath $Value
    } catch {
      # A single-file replacement can fail after moving bytes. The caller owns
      # the original snapshot and must make one more recovery attempt.
      $RollbackIncomplete.Value = $true
      throw
    }
    return
  }

  $snapshots = @()
  foreach ($path in @($RootPath, $DiscoveryPath)) {
    if ((Test-Path -LiteralPath $path) -and -not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "Dala install metadata target is not a regular file: $path"
    }
    $exists = Test-Path -LiteralPath $path -PathType Leaf
    $snapshots += [pscustomobject]@{
      path = $path
      exists = $exists
      body = if ($exists) { Get-Content -LiteralPath $path -Raw } else { $null }
    }
  }

  try {
    Write-JsonAtomic $RootPath $Value
    Write-JsonAtomic $DiscoveryPath $Value
  } catch {
    $writeError = $_.Exception.Message
    $rollbackErrors = @()
    for ($index = $snapshots.Count - 1; $index -ge 0; $index--) {
      $snapshot = $snapshots[$index]
      try {
        if ($snapshot.exists) {
          Write-TextAtomic ([string]$snapshot.path) ([string]$snapshot.body)
        } else {
          $snapshotPath = [string]$snapshot.path
          if (Test-Path -LiteralPath $snapshotPath) {
            Remove-Item -LiteralPath $snapshotPath -Force -ErrorAction Stop
          }
          if (Test-Path -LiteralPath $snapshotPath) {
            throw "metadata target remains after rollback: $snapshotPath"
          }
        }
      } catch {
        $rollbackErrors += $_.Exception.Message
      }
    }
    if ($rollbackErrors.Count -gt 0) {
      $RollbackIncomplete.Value = $true
      throw "$writeError; install metadata rollback failed: $($rollbackErrors -join '; ')"
    }
    throw $writeError
  }
}

function Assert-InstallMetadataMatch($Left, $Right) {
  foreach ($name in @("root", "dataDir", "configFile")) {
    if (-not (Test-SamePath ([string]$Left.$name) ([string]$Right.$name))) {
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

function Enter-DalaLifecycleMutex {
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $name = "Global\DalaLifecycle-" + ($sid.Value -replace '[^0-9A-Za-z_-]', '_')
  $created = $false
  $mutex = [Threading.Mutex]::new($false, $name, [ref]$created)
  try {
    if (-not $mutex.WaitOne(0)) {
      $mutex.Dispose()
      throw "another Dala install or update is already in progress"
    }
  } catch [Threading.AbandonedMutexException] {
    # WaitOne grants ownership when the previous process exited unexpectedly.
  } catch {
    $mutex.Dispose()
    throw
  }
  $mutex
}

function Exit-DalaLifecycleMutex($Mutex) {
  if (-not $Mutex) { return }
  $Mutex.ReleaseMutex()
  $Mutex.Dispose()
}

function Assert-ClaimableDirectory([string]$Path, [string]$DefaultPath, [string]$Marker, [string]$Label) {
  if ((Test-SamePath $Path $DefaultPath) -or -not (Test-Path -LiteralPath $Path)) { return }
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "$Label is not a directory: $Path" }
  if (Test-Path -LiteralPath (Join-Path $Path $Marker) -PathType Leaf) { return }
  if (-not (Get-ChildItem -LiteralPath $Path -Force | Select-Object -First 1)) { return }
  throw "Refusing to claim non-empty unverified $Label`: $Path"
}

function Assert-Tag([string]$Tag) {
  if ([string]::IsNullOrWhiteSpace($Tag) -or $Tag -cnotmatch $TagPattern) {
    throw "Invalid version: $Tag"
  }
}

function Assert-AttemptId([string]$Value) {
  $parsed = [guid]::Empty
  if (-not [guid]::TryParseExact($Value, "D", [ref]$parsed) -or
      $parsed.ToString("D") -cne $Value) {
    throw "Invalid AttemptId: expected a canonical UUID"
  }
}

function Get-CurrentTag([string]$InstallRoot) {
  $current = Join-Path $InstallRoot "current.txt"
  if (-not (Test-Path -LiteralPath $current -PathType Leaf)) { return $null }
  $tag = (Get-Content -LiteralPath $current -Raw).Trim()
  if ($tag -cnotmatch $TagPattern) { throw "Invalid Dala version pointer: $tag" }
  $tag
}

function Set-Current([string]$InstallRoot, [string]$Tag) {
  Assert-Tag $Tag
  $current = Join-Path $InstallRoot "current.txt"
  if (-not (Test-NoReparseAncestors $InstallRoot) -or
      -not (Test-NoReparseAncestors $current)) {
    throw "Refusing to update current pointer through a reparse point: $current"
  }
  $fresh = Join-Path $InstallRoot (".current-" + [guid]::NewGuid().ToString("N") + ".new")
  [IO.File]::WriteAllText($fresh, "$Tag`n", [Text.UTF8Encoding]::new($false))

  $helperOwnsFresh = $false
  try {
    if (Test-Path -LiteralPath $current -PathType Leaf) {
      $helperOwnsFresh = $true
      Invoke-RecoverableFileReplace $fresh $current
    } else {
      [IO.File]::Move($fresh, $current)
    }
  } finally {
    if (-not $helperOwnsFresh) {
      Remove-Item -LiteralPath $fresh -Force -ErrorAction SilentlyContinue
    }
  }
}

function Get-ReleaseVersion([string]$VersionOrTag) {
  if ([string]::IsNullOrWhiteSpace($VersionOrTag)) { return $null }
  $version = if ($VersionOrTag.StartsWith("v", [StringComparison]::Ordinal)) {
    $VersionOrTag.Substring(1)
  } else {
    $VersionOrTag
  }
  if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
    return $null
  }
  $version
}

function Get-ReleaseAppRoot([string]$ReleaseDir, [string]$Version) {
  if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = Split-Path -Leaf ([IO.Path]::GetFullPath($ReleaseDir).TrimEnd([char[]]"\/"))
  }
  $appVersion = Get-ReleaseVersion $Version
  if (-not $appVersion) { return $null }
  Join-Path $ReleaseDir "lib\dala-$appVersion"
}

function Get-ReleaseHelper([string]$ReleaseDir, [string]$Version, [string]$RelativePath) {
  $appRoot = Get-ReleaseAppRoot $ReleaseDir $Version
  if (-not $appRoot) { return $null }
  $candidate = Join-Path $appRoot $RelativePath
  if (-not (Test-NoReparseAncestors $candidate)) { return $null }
  if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $null }
  try {
    $attributes = [IO.File]::GetAttributes($candidate)
    if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $null }
  } catch {
    return $null
  }
  [IO.Path]::GetFullPath($candidate)
}

function Get-TaskLauncher([string]$ReleaseDir, [string]$Version) {
  Get-ReleaseHelper $ReleaseDir $Version "priv\bin\dala_task_launcher.exe"
}

function Get-UpdateHelper([string]$ReleaseDir, [string]$Version) {
  Get-ReleaseHelper $ReleaseDir $Version "priv\windows\update-dala.ps1"
}

function Get-PublishHelper([string]$ReleaseDir, [string]$Version) {
  Get-ReleaseHelper $ReleaseDir $Version "priv\windows\publish-dala.ps1"
}

function Get-RestartHelper([string]$ReleaseDir, [string]$Version) {
  Get-ReleaseHelper $ReleaseDir $Version "priv\windows\restart-dala.ps1"
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

function Remove-SafeInstallTree([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return }
  if (-not (Test-NoReparseAncestors $Path)) {
    throw "Refusing to remove through a reparse point: $Path"
  }

  $attributes = [IO.File]::GetAttributes($Path)
  if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Refusing to remove a reparse point: $Path"
  }

  if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
    foreach ($entry in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) {
      $childAttributes = [IO.File]::GetAttributes($entry.FullName)
      if (($childAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to remove a reparse point: $($entry.FullName)"
      }
      Remove-SafeInstallTree $entry.FullName
    }

    $attributes = [IO.File]::GetAttributes($Path)
    if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Refusing to remove a reparse point: $Path"
    }
    if (-not (Test-NoReparseAncestors $Path)) {
      throw "Refusing to remove through a reparse point: $Path"
    }
    [IO.File]::SetAttributes($Path, [IO.FileAttributes]::Normal)
    [IO.Directory]::Delete($Path)
  } else {
    $attributes = [IO.File]::GetAttributes($Path)
    if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Refusing to remove a reparse point: $Path"
    }
    if (-not (Test-NoReparseAncestors $Path)) {
      throw "Refusing to remove through a reparse point: $Path"
    }
    [IO.File]::SetAttributes($Path, [IO.FileAttributes]::Normal)
    [IO.File]::Delete($Path)
  }
}

function Remove-CreatedInstallArtifact([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return }
  if (-not (Test-NoReparseAncestors $Path)) {
    throw "refusing to remove through a reparse point: $Path"
  }
  $attributes = [IO.File]::GetAttributes($Path)
  if (($attributes -band [IO.FileAttributes]::Directory) -ne 0 -or
      ($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "created install artifact is not a regular file: $Path"
  }
  [IO.File]::SetAttributes($Path, [IO.FileAttributes]::Normal)
  [IO.File]::Delete($Path)
  if (Test-Path -LiteralPath $Path) {
    throw "created install artifact remains after rollback: $Path"
  }
}

function Restore-InstallArtifacts(
  [string]$RootMetadataPath,
  [bool]$RootMetadataExisted,
  [string]$RootMetadataBody,
  [string]$DiscoveryMetadataPath,
  [bool]$DiscoveryMetadataExisted,
  [string]$DiscoveryMetadataBody,
  [bool]$RestoreMetadata,
  [string]$ConfigPath,
  [bool]$CreatedConfig,
  [string]$ConfigMarkerPath,
  [bool]$CreatedConfigMarker
) {
  $metadataArtifacts = @()
  if ($RestoreMetadata) {
    # Restore in reverse write order so a partial failure leaves the root copy,
    # which is colocated with the release tree, as the last attempted source of
    # truth.
    $metadataArtifacts += [pscustomobject]@{
      path = $DiscoveryMetadataPath
      existed = $DiscoveryMetadataExisted
      body = $DiscoveryMetadataBody
    }
    $metadataArtifacts += [pscustomobject]@{
      path = $RootMetadataPath
      existed = $RootMetadataExisted
      body = $RootMetadataBody
    }
  }
  $rollbackErrors = @()

  foreach ($artifact in $metadataArtifacts) {
    try {
      if ($artifact.existed) {
        Write-TextAtomic ([string]$artifact.path) ([string]$artifact.body)
      } else {
        Remove-CreatedInstallArtifact ([string]$artifact.path)
      }
    } catch {
      $rollbackErrors += $_.Exception.Message
    }
  }

  if ($rollbackErrors.Count -gt 0) {
    throw ($rollbackErrors -join '; ')
  }

  # Config is referenced by metadata and the marker claims ownership of its
  # directory. Preserve each dependency until the artifact above it is known
  # to be restored or removed.
  if ($CreatedConfig) {
    Remove-CreatedInstallArtifact $ConfigPath
  }
  if ($CreatedConfigMarker) {
    Remove-CreatedInstallArtifact $ConfigMarkerPath
  }
}

function Test-NoReparsePoints([string]$Path, [bool]$CheckAncestors = $true) {
  try {
    if ($CheckAncestors -and -not (Test-NoReparseAncestors $Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    $attributes = [IO.File]::GetAttributes($Path)
    if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $true }

    foreach ($entry in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) {
      if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
      if ($entry.PSIsContainer -and -not (Test-NoReparsePoints $entry.FullName $false)) { return $false }
    }
    $true
  } catch {
    $false
  }
}

function Test-CompleteDalaRelease([string]$Path, [string]$Version) {
  try {
    $appVersion = Get-ReleaseVersion $Version
    if (-not $appVersion -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    if (-not (Test-NoReparsePoints $Path)) { return $false }

    foreach ($relative in @("bin\dala.bat", "run-dala.ps1", "releases\start_erl.data")) {
      if (-not (Test-Path -LiteralPath (Join-Path $Path $relative) -PathType Leaf)) { return $false }
    }

    $startData = @((Get-Content -LiteralPath (Join-Path $Path "releases\start_erl.data") -Raw).Trim() -split '\s+')
    if ($startData.Count -ne 2 -or [string]$startData[1] -cne $appVersion) { return $false }
    $ertsVersion = [string]$startData[0]
    if ($ertsVersion -notmatch '^[0-9A-Za-z._-]+$') { return $false }

    foreach ($relative in @(
      "releases\$appVersion\start.boot",
      "releases\$appVersion\dala.rel",
      "erts-$ertsVersion\bin\erl.exe",
      "erts-$ertsVersion\bin\epmd.exe",
      "lib\dala-$appVersion\ebin\dala.app",
      "lib\dala-$appVersion\ebin\Elixir.Dala.beam"
    )) {
      if (-not (Test-Path -LiteralPath (Join-Path $Path $relative) -PathType Leaf)) { return $false }
    }

    $appFile = Join-Path $Path "lib\dala-$appVersion\ebin\dala.app"
    $matches = [regex]::Matches((Get-Content -LiteralPath $appFile -Raw), '\{vsn,\s*"([^"]+)"\}')
    if ($matches.Count -ne 1 -or $matches[0].Groups[1].Value -cne $appVersion) { return $false }

    foreach ($relative in @(
      "priv\bin\dala_task_launcher.exe",
      "priv\windows\update-dala.ps1",
      "priv\windows\restart-dala.ps1",
      "priv\windows\publish-dala.ps1"
    )) {
      if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $Path "lib\dala-$appVersion") $relative) -PathType Leaf)) {
        return $false
      }
    }
    $true
  } catch {
    $false
  }
}

function Assert-CompleteDalaRelease([string]$Path, [string]$Version, [string]$Label) {
  if (-not (Test-CompleteDalaRelease $Path $Version)) {
    throw "$Label is not a complete Dala Windows release for $Version`: $Path"
  }
}

function Assert-SafeArchive([string]$Archive, [string]$DestinationRoot) {
  try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue } catch {}
  $zip = $null
  $seen = @{}
  try {
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    foreach ($entry in $zip.Entries) {
      $name = ([string]$entry.FullName).Replace('/', '\')
      if ([string]::IsNullOrWhiteSpace($name) -or $name.IndexOf([char]0) -ge 0) {
        throw "Release archive contains an invalid ZIP entry"
      }
      if ($name.StartsWith('\') -or $name -match '^[A-Za-z]:' -or $name.Contains(':')) {
        throw "Release archive contains an absolute ZIP entry: $($entry.FullName)"
      }
      $segments = @($name -split '\\')
      if ($segments.Count -gt 0 -and $segments[-1] -ceq '') {
        $segments = @($segments[0..($segments.Count - 2)])
      }
      foreach ($segment in $segments) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment.TrimEnd([char[]]' .') -cne $segment) {
          throw "Release archive contains an invalid Windows path segment: $($entry.FullName)"
        }
        if ($segment -ceq '..' -or $segment -ceq '.') {
          throw "Release archive contains a traversal ZIP entry: $($entry.FullName)"
        }
        $device = ($segment -split '\.', 2)[0]
        if ($device -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
          throw "Release archive contains a Windows device path segment: $($entry.FullName)"
        }
      }

      $normalizedName = $name.TrimEnd('\').ToLowerInvariant()
      if ($seen.ContainsKey($normalizedName)) {
        throw "Release archive contains duplicate ZIP entries: $($entry.FullName)"
      }
      $seen[$normalizedName] = $true

      $external = [BitConverter]::ToUInt32(
        [BitConverter]::GetBytes([int32]$entry.ExternalAttributes), 0
      )
      $unixType = ($external -shr 16) -band 0xF000
      $unsupportedUnixType = $unixType -ne 0 -and $unixType -ne 0x4000 -and $unixType -ne 0x8000
      $unsupportedWindowsType = ($external -band 0x400) -ne 0 -or ($external -band 0x40) -ne 0
      if ($unsupportedUnixType -or $unsupportedWindowsType) {
        throw "Release archive contains a symbolic-link, device, socket, or other special ZIP entry: $($entry.FullName)"
      }

      if ($DestinationRoot) {
        $base = [IO.Path]::GetFullPath($DestinationRoot).TrimEnd([char[]]"\/") + [IO.Path]::DirectorySeparatorChar
        $target = [IO.Path]::GetFullPath((Join-Path $DestinationRoot $name))
        if (-not $target.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
          throw "Release archive entry escapes its staging directory: $($entry.FullName)"
        }
      }
    }
  } finally {
    if ($zip) { $zip.Dispose() }
  }
}

function Deploy-Runner([string]$Source, [string]$Destination) {
  if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Release is missing run-dala.ps1" }
  if (-not (Test-NoReparseAncestors $Source) -or -not (Test-NoReparseAncestors $Destination)) {
    throw "Refusing to deploy run-dala.ps1 through a reparse point"
  }
  $fresh = "$Destination.new-$([guid]::NewGuid().ToString('N'))"
  Copy-Item -LiteralPath $Source -Destination $fresh -Force

  $helperOwnsFresh = $false
  try {
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
      $helperOwnsFresh = $true
      Invoke-RecoverableFileReplace $fresh $Destination
    } else {
      [IO.File]::Move($fresh, $Destination)
    }
  } finally {
    if (-not $helperOwnsFresh) {
      Remove-Item -LiteralPath $fresh -Force -ErrorAction SilentlyContinue
    }
  }
}

function New-DalaTask([string]$Name, [string]$Launcher, [string]$Runner, [string]$LogFile) {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  $action = New-ScheduledTaskAction -Execute $Launcher -Argument "`"$Runner`" `"$LogFile`""
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
  $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  $principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName $Name -TaskPath "\" -Action $action -Trigger $trigger -Settings $settings `
    -Principal $principal -Description "Dala terminal server" | Out-Null
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

function Assert-DalaTaskObjectOwnership($Task, [string]$Name, [string]$ReleaseDir, [string]$ExpectedRunner, [string]$ExpectedLog) {
  if (-not $Task) { throw "Scheduled task '$Name' does not exist" }
  Assert-DalaTaskPrincipal $task

  $releaseTag = Split-Path -Leaf ([IO.Path]::GetFullPath($ReleaseDir).TrimEnd([char[]]"\/"))
  $releaseVersion = Get-ReleaseVersion $releaseTag
  $launcher = Get-TaskLauncher $ReleaseDir $releaseVersion
  if (-not $launcher) { throw "Existing release is missing dala_task_launcher.exe: $ReleaseDir" }
  $actions = @($task.Actions)
  $expectedArguments = "`"$ExpectedRunner`" `"$ExpectedLog`""
  if ($actions.Count -ne 1 -or
      -not (Test-SamePath ([string]$actions[0].Execute) $launcher) -or
      [string]$actions[0].Arguments -cne $expectedArguments) {
    throw "Scheduled task '$Name' is not owned by this Dala installation"
  }
  $true
}

function Assert-DalaTaskOwnership([string]$Name, [string]$ReleaseDir, [string]$ExpectedRunner, [string]$ExpectedLog) {
  $task = Get-DalaTaskExact $Name
  if (-not $task) { return $false }
  Assert-DalaTaskObjectOwnership $task $Name $ReleaseDir $ExpectedRunner $ExpectedLog
}

function Register-DalaTaskVerified(
  [string]$Name,
  [string]$Launcher,
  [string]$Runner,
  [string]$LogFile,
  [string]$ReleaseDir,
  [ref]$Ambiguous
) {
  $Ambiguous.Value = $false
  $registrationError = $null
  try {
    New-DalaTask $Name $Launcher $Runner $LogFile
  } catch {
    $registrationError = $_.Exception.Message
  }

  try {
    $task = Get-DalaTaskExact $Name
  } catch {
    $Ambiguous.Value = $true
    if ($registrationError) {
      throw "$registrationError; could not query Scheduled Task '$Name': $($_.Exception.Message)"
    }
    throw
  }
  if (-not $task) {
    if ($registrationError) { throw $registrationError }
    throw "Scheduled task registration returned without creating '$Name'"
  }
  try {
    $null = Assert-DalaTaskObjectOwnership $task $Name $ReleaseDir $Runner $LogFile
  } catch {
    $Ambiguous.Value = $true
    if ($registrationError) {
      throw "$registrationError; could not verify Scheduled Task '$Name': $($_.Exception.Message)"
    }
    throw
  }

  if ($registrationError) {
    Write-Warning "Scheduled Task registration reported an error after '$Name' was committed: $registrationError" `
      -WarningAction Continue
  }
}

function Remove-DalaTaskVerified(
  [string]$Name,
  [string]$ReleaseDir,
  [string]$Runner,
  [string]$LogFile
) {
  $task = Get-DalaTaskExact $Name
  if (-not $task) { return }
  $null = Assert-DalaTaskObjectOwnership $task $Name $ReleaseDir $Runner $LogFile

  Stop-DalaTaskVerified $Name $ReleaseDir $Runner $LogFile
  $task = Get-DalaTaskExact $Name
  if (-not $task) { return }
  $null = Assert-DalaTaskObjectOwnership $task $Name $ReleaseDir $Runner $LogFile

  $removalError = $null
  try {
    Unregister-ScheduledTask -TaskName $Name -TaskPath "\" -Confirm:$false -ErrorAction Stop
  } catch {
    $removalError = $_.Exception.Message
  }

  try {
    $remaining = Get-DalaTaskExact $Name
  } catch {
    if ($removalError) {
      throw "$removalError; could not verify removal of Scheduled Task '$Name': $($_.Exception.Message)"
    }
    throw
  }

  if (-not $remaining) {
    if ($removalError) {
      Write-Warning "Scheduled Task removal reported an error after '$Name' was removed: $removalError" `
        -WarningAction Continue
    }
    return
  }

  try {
    $null = Assert-DalaTaskObjectOwnership $remaining $Name $ReleaseDir $Runner $LogFile
  } catch {
    if ($removalError) {
      throw "$removalError; Scheduled Task '$Name' remains with uncertain ownership: $($_.Exception.Message)"
    }
    throw
  }
  if ($removalError) { throw "$removalError; Scheduled Task '$Name' still exists" }
  throw "Scheduled Task '$Name' still exists after removal returned"
}

function Stop-DalaTaskVerified(
  [string]$Name,
  [string]$ReleaseDir,
  [string]$Runner,
  [string]$LogFile
) {
  $task = Get-DalaTaskExact $Name
  if (-not $task) { return }
  $null = Assert-DalaTaskObjectOwnership $task $Name $ReleaseDir $Runner $LogFile
  if ([string]$task.State -notin @("Running", "Queued")) { return }

  $stopError = $null
  try {
    Stop-ScheduledTask -TaskName $Name -TaskPath "\" -ErrorAction Stop
  } catch {
    $stopError = $_.Exception.Message
  }

  for ($attempt = 0; $attempt -lt 50; $attempt++) {
    $task = Get-DalaTaskExact $Name
    if (-not $task -or [string]$task.State -notin @("Running", "Queued")) { break }
    Start-Sleep -Milliseconds 100
  }
  if ($task) {
    $null = Assert-DalaTaskObjectOwnership $task $Name $ReleaseDir $Runner $LogFile
  }
  if ($task -and [string]$task.State -in @("Running", "Queued")) {
    $message = "Scheduled Task '$Name' remained active after stop"
    if ($stopError) { $message = "$stopError; $message" }
    throw $message
  }
  if ($stopError) {
    Write-Warning "Scheduled Task stop reported an error after '$Name' stopped: $stopError" `
      -WarningAction Continue
  }
}

function Start-DalaTaskVerified(
  [string]$Name,
  [string]$ReleaseDir,
  [string]$Runner,
  [string]$LogFile
) {
  $task = Get-DalaTaskExact $Name
  if (-not $task) { throw "Scheduled Task '$Name' is missing before start" }
  $null = Assert-DalaTaskObjectOwnership $task $Name $ReleaseDir $Runner $LogFile

  $startError = $null
  try {
    Start-ScheduledTask -TaskName $Name -TaskPath "\" -ErrorAction Stop
  } catch {
    $startError = $_.Exception.Message
  }

  $task = $null
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    $task = Get-DalaTaskExact $Name
    if ($task -and [string]$task.State -in @("Running", "Queued")) { break }
    Start-Sleep -Milliseconds 100
  }
  if (-not $task) {
    $message = "Scheduled Task '$Name' is missing after start"
    if ($startError) { $message = "$startError; $message" }
    throw $message
  }
  $null = Assert-DalaTaskObjectOwnership $task $Name $ReleaseDir $Runner $LogFile
  if ([string]$task.State -notin @("Running", "Queued")) {
    $message = "Scheduled Task '$Name' did not enter a running state"
    if ($startError) { $message = "$startError; $message" }
    throw $message
  }
  if ($startError) {
    Write-Warning "Scheduled Task start reported an error after '$Name' started: $startError" `
      -WarningAction Continue
  }
}

function Find-DalaTaskRegistration([string]$ReleaseDir, [string]$ExpectedRunner, [string]$ExpectedLog) {
  $releaseTag = Split-Path -Leaf ([IO.Path]::GetFullPath($ReleaseDir).TrimEnd([char[]]"\/"))
  $launcher = Get-TaskLauncher $ReleaseDir (Get-ReleaseVersion $releaseTag)
  if (-not $launcher) { throw "Existing release is missing dala_task_launcher.exe: $ReleaseDir" }
  $expectedArguments = "`"$ExpectedRunner`" `"$ExpectedLog`""

  $matches = @(
    Get-ScheduledTask -TaskPath "\" -ErrorAction Stop |
      Where-Object {
        $actions = @($_.Actions)
        $actions.Count -eq 1 -and
          -not [string]::IsNullOrWhiteSpace([string]$actions[0].Execute) -and
          (Test-SamePath ([string]$actions[0].Execute) $launcher) -and
          [string]$actions[0].Arguments -ceq $expectedArguments
      }
  )
  if ($matches.Count -gt 1) {
    throw "Multiple root Scheduled Tasks claim this Dala installation"
  }
  if ($matches.Count -eq 1) {
    Assert-TaskName ([string]$matches[0].TaskName)
    Assert-DalaTaskPrincipal $matches[0]
    return [string]$matches[0].TaskName
  }
  $null
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

function Get-ReleaseBeamProcesses([string]$ReleaseDir) {
  $releaseRoot = [IO.Path]::GetFullPath($ReleaseDir).TrimEnd([char[]]"\/")
  $tag = Split-Path -Leaf $releaseRoot
  if ($tag -cnotmatch $TagPattern) {
    throw "Cannot inspect Dala release with an invalid version directory: $releaseRoot"
  }
  $version = $tag.Substring(1)
  $tokens = @((Get-Content -LiteralPath (Join-Path $releaseRoot "releases\start_erl.data") -Raw).Trim() -split '\s+')
  if ($tokens.Count -ne 2 -or [string]$tokens[1] -cne $version) {
    throw "Cannot inspect Dala release with malformed start_erl.data: $releaseRoot"
  }
  $expectedExecutable = [IO.Path]::GetFullPath((Join-Path $releaseRoot "erts-$($tokens[0])\bin\erl.exe"))
  $boot = [IO.Path]::GetFullPath((Join-Path $releaseRoot "releases\$version\start"))
  $bootFile = [IO.Path]::GetFullPath((Join-Path $releaseRoot "releases\$version\start.boot"))
  $releaseProcesses = @()
  foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='erl.exe'" -ErrorAction Stop)) {
    if ($null -eq $process) {
      throw "Cannot determine the identity of an erl.exe process; refusing to continue"
    }

    $processExecutable = [string]$process.ExecutablePath
    $processCommandLine = [string]$process.CommandLine
    if ([string]::IsNullOrWhiteSpace($processExecutable) -or
        [string]::IsNullOrWhiteSpace($processCommandLine)) {
      throw "Cannot determine the identity of an erl.exe process; refusing to continue"
    }
    if (-not (Test-SamePath $processExecutable $expectedExecutable)) { continue }

    if (-not (Test-ReleaseBootCommand $processCommandLine @($boot, $bootFile))) {
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

function Test-ReleaseTaskRunning([string]$Name, [string]$ReleaseDir) {
  $task = Get-DalaTaskExact $Name
  if ($task) {
    $null = Assert-DalaTaskObjectOwnership $task $Name $ReleaseDir $Runner $LogFile
  }
  $task -and [string]$task.State -ceq "Running" -and (Get-ReleaseBeamProcesses $ReleaseDir).Count -gt 0
}

function Test-ReleaseOwnsPort([int]$PortNumber, [string]$ReleaseDir) {
  $releaseProcessIds = @(
    Get-ReleaseBeamProcesses $ReleaseDir |
      ForEach-Object { [uint32]$_.ProcessId }
  )
  if ($releaseProcessIds.Count -eq 0) { return $false }

  $listenerProcessIds = @(
    Get-NetTCPConnection -State Listen -LocalPort $PortNumber -ErrorAction Stop |
      Where-Object { $_.LocalAddress -ceq "127.0.0.1" -or $_.LocalAddress -ceq "0.0.0.0" } |
      ForEach-Object { [uint32]$_.OwningProcess }
  )

  foreach ($processId in $releaseProcessIds) {
    if ($listenerProcessIds -contains $processId) { return $true }
  }
  $false
}

function Wait-DalaVersion([int]$PortNumber, [string]$Expected, [string]$ReleaseDir, [string]$Name) {
  $deadline = [DateTime]::UtcNow.AddSeconds($HealthTimeoutSeconds)
  $uri = "http://127.0.0.1:$PortNumber/version"
  $lastHealthError = $null

  while ([DateTime]::UtcNow -lt $deadline) {
    try {
      if (Test-ReleaseTaskRunning $Name $ReleaseDir) {
        $ownedBefore = Test-ReleaseOwnsPort $PortNumber $ReleaseDir
        $response = Invoke-WebRequest -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 2 -Uri $uri
        $ownedAfter = Test-ReleaseOwnsPort $PortNumber $ReleaseDir
        $contentType = [string]$response.Headers["Content-Type"]
        if ($response.StatusCode -eq 200 -and $contentType.StartsWith("text/plain")) {
          $actualVersion = ([string]$response.Content).Trim()
          if ($ownedBefore -and $ownedAfter) {
            if ($actualVersion -ceq $Expected) { return }
            if ($actualVersion) { throw "Dala returned version '$actualVersion', expected '$Expected'" }
          }
        }
      }
    } catch {
      if ($_.Exception.Message -like "Dala returned version*") { throw }
      $lastHealthError = $_.Exception.Message
    }
    Start-Sleep -Milliseconds 500
  }

  $message = "Dala $Expected did not become healthy at $uri"
  if ($lastHealthError) { $message += "; last health probe error: $lastHealthError" }
  throw $message
}

if ($AttemptId) { Assert-AttemptId $AttemptId }
if (-not [Environment]::Is64BitOperatingSystem) { throw "Dala requires 64-bit Windows" }
if ([Environment]::OSVersion.Version -lt [Version]"10.0.17763") { throw "Dala requires Windows 10 1809 or newer" }

$LifecycleMutex = Enter-DalaLifecycleMutex
try {
$DiscoveryMetadata = Read-InstallMetadata $DiscoveryFile
$rootHint = if ($env:DALA_HOME) {
  $env:DALA_HOME
} elseif ($DiscoveryMetadata) {
  [string]$DiscoveryMetadata.root
} else {
  $DefaultRoot
}
$RootMetadata = Read-InstallMetadata (Join-Path ([IO.Path]::GetFullPath($rootHint)) "install.json")
if ($DiscoveryMetadata -and $RootMetadata) {
  Assert-InstallMetadataMatch $DiscoveryMetadata $RootMetadata
}
$ExistingMetadata = if ($RootMetadata) { $RootMetadata } else { $DiscoveryMetadata }
$MetadataTaskName = if ($ExistingMetadata) { [string]$ExistingMetadata.taskName } else { $null }
$Repo = if ($env:DALA_REPO) { $env:DALA_REPO } elseif ($ExistingMetadata.repo) { [string]$ExistingMetadata.repo } else { "mjason/dala" }
$Root = if ($env:DALA_HOME) { $env:DALA_HOME } elseif ($ExistingMetadata.root) { [string]$ExistingMetadata.root } else { $DefaultRoot }
$DataDir = if ($env:DALA_DATA_DIR) { $env:DALA_DATA_DIR } elseif ($ExistingMetadata.dataDir) { [string]$ExistingMetadata.dataDir } else { $DefaultDataDir }
$ConfigFile = if ($env:DALA_CONFIG) { $env:DALA_CONFIG } elseif ($ExistingMetadata.configFile) { [string]$ExistingMetadata.configFile } else { Join-Path $DefaultConfigDir "config.jsonc" }
$TaskName = if ($env:DALA_SERVICE) { $env:DALA_SERVICE } elseif ($ExistingMetadata.taskName) { [string]$ExistingMetadata.taskName } else { "Dala" }
$Port = if ($env:DALA_PORT) { [int]$env:DALA_PORT } elseif ($ExistingMetadata.port) { [int]$ExistingMetadata.port } else { 4400 }

$Root = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]"\/")
$DataDir = [IO.Path]::GetFullPath($DataDir).TrimEnd([char[]]"\/")
$ConfigFile = [IO.Path]::GetFullPath($ConfigFile)
$ConfigAuthority = Read-DalaConfig $ConfigFile
if ($ConfigAuthority) {
  $configuredRoot = [string](Get-DalaConfigProperty $ConfigAuthority "releaseRoot")
  if ([string]::IsNullOrWhiteSpace($configuredRoot)) {
    throw "Dala configuration is missing releaseRoot: $ConfigFile"
  }
  if (-not (Test-SamePath $Root $configuredRoot)) {
    throw "releaseRoot in Dala configuration does not match the installation root"
  }

  $configuredDataDir = [string](Get-DalaConfigProperty $ConfigAuthority "dataDir")
  if ([string]::IsNullOrWhiteSpace($configuredDataDir)) {
    throw "Dala configuration is missing dataDir: $ConfigFile"
  }
  $DataDir = [IO.Path]::GetFullPath($configuredDataDir).TrimEnd([char[]]"\/")

  $configuredTaskName = Get-DalaConfigProperty $ConfigAuthority "serviceName"
  $TaskName = if ($null -eq $configuredTaskName) { "Dala" } else { [string]$configuredTaskName }

  $configuredPort = Get-DalaConfigProperty $ConfigAuthority "port"
  if ($null -eq $configuredPort) {
    $Port = 4000
  } else {
    $parsedPort = 0
    if (-not [int]::TryParse([string]$configuredPort, [ref]$parsedPort)) {
      throw "Invalid port in Dala configuration: $configuredPort"
    }
    $Port = $parsedPort
  }

  $configuredRepo = Get-DalaConfigProperty $ConfigAuthority "updateRepo"
  $Repo = if ($null -eq $configuredRepo) { "mjason/dala" } else { [string]$configuredRepo }
}
$ConfigDir = Split-Path -Parent $ConfigFile
$RootMetadataFile = Join-Path $Root "install.json"
$Runner = Join-Path $Root "run-dala.ps1"
$LogFile = Join-Path $Root "logs\server.log"

Assert-TaskName $TaskName
if ($Port -lt 1 -or $Port -gt 65535) { throw "Invalid Dala port: $Port" }
if ($Repo -cnotmatch $RepoPattern) { throw "Invalid Dala updateRepo: $Repo" }
if ($ExistingMetadata) {
  if ($env:DALA_HOME -and -not (Test-SamePath $Root ([string]$ExistingMetadata.root))) {
    throw "DALA_HOME conflicts with the existing install metadata"
  }
  if (-not $ConfigAuthority -and $env:DALA_DATA_DIR -and
      -not (Test-SamePath $DataDir ([string]$ExistingMetadata.dataDir))) {
    throw "DALA_DATA_DIR conflicts with the existing install metadata"
  }
  if ($env:DALA_CONFIG -and -not (Test-SamePath $ConfigFile ([string]$ExistingMetadata.configFile))) {
    throw "DALA_CONFIG conflicts with the existing install metadata"
  }
  if (-not $ConfigAuthority -and $env:DALA_SERVICE -and
      [string]$TaskName -cne [string]$ExistingMetadata.taskName) {
    throw "DALA_SERVICE conflicts with the existing install metadata"
  }
  if (-not $ConfigAuthority -and $env:DALA_PORT -and [int]$Port -ne [int]$ExistingMetadata.port) {
    throw "DALA_PORT conflicts with the existing install metadata"
  }
  if (-not $ConfigAuthority -and $env:DALA_REPO -and [string]$Repo -cne [string]$ExistingMetadata.repo) {
    throw "DALA_REPO conflicts with the existing install metadata"
  }
  if ([string]$ExistingMetadata.platform -cne $Platform) {
    throw "platform conflicts with the existing install metadata"
  }
}

if (-not $Version) {
  Write-Step "Resolving latest server release from $Repo"
  $releases = Invoke-RestMethod -Headers @{ "User-Agent" = "dala-installer" } `
    -Uri "https://api.github.com/repos/$Repo/releases?per_page=15"
  $release = $releases |
    Where-Object { -not $_.draft -and -not $_.prerelease -and [string]$_.tag_name -cmatch $TagPattern } |
    Select-Object -First 1
  if (-not $release) { throw "No server release is available" }
  $Version = $release.tag_name
}
Assert-Tag $Version
if (-not $ExpectedVersion) { $ExpectedVersion = $Version.Substring(1) }
$ReleaseVersion = $Version.Substring(1)

$Asset = "dala-$Version-$Platform.zip"
$Dest = Join-Path $Root "versions\$Version"
$Executable = Join-Path $Dest "bin\dala.bat"
$ReleaseRunner = Join-Path $Dest "run-dala.ps1"
$InstalledNow = $false
$ReplacedDestinationBackup = $null
$CreatedConfig = $false
$CreatedTask = $false
$ConfigMarker = Join-Path $ConfigDir ".dala-config"
$ConfigMarkerExists = Test-Path -LiteralPath $ConfigMarker -PathType Leaf
$ConfigDirExists = Test-Path -LiteralPath $ConfigDir -PathType Container
$ConfigDirClaimable = (Test-SamePath $ConfigDir $DefaultConfigDir) -or -not $ConfigDirExists -or $ConfigMarkerExists
if ($ConfigDirExists -and -not $ConfigDirClaimable) {
  $ConfigDirClaimable = -not (Get-ChildItem -LiteralPath $ConfigDir -Force | Select-Object -First 1)
}
$ShouldCreateConfigMarker = $ConfigDirClaimable -and -not $ConfigMarkerExists
$CreatedConfigMarker = $false
$RootMetadataExisted = Test-Path -LiteralPath $RootMetadataFile -PathType Leaf
$DiscoveryMetadataExisted = Test-Path -LiteralPath $DiscoveryFile -PathType Leaf
$RootMetadataBody = if ($RootMetadataExisted) { Get-Content -LiteralPath $RootMetadataFile -Raw } else { $null }
$DiscoveryMetadataBody = if ($DiscoveryMetadataExisted) { Get-Content -LiteralPath $DiscoveryFile -Raw } else { $null }
$MetadataWritten = $false
$MetadataRollbackIncomplete = $false
$CanRollbackCreatedArtifacts = $true
$PreviousTag = $null

Assert-ClaimableDirectory $Root $DefaultRoot ".dala-install" "DALA_HOME"
Assert-ClaimableDirectory $DataDir $DefaultDataDir ".dala-data" "DALA_DATA_DIR"
if (-not (Test-NoReparseAncestors $Root)) {
  throw "Refusing to use DALA_HOME through a reparse point: $Root"
}
if (-not (Test-NoReparseAncestors $DataDir)) {
  throw "Refusing to use DALA_DATA_DIR through a reparse point: $DataDir"
}
if (-not (Test-NoReparseAncestors $ConfigDir)) {
  throw "Refusing to use Dala config directory through a reparse point: $ConfigDir"
}

$destinationParent = Split-Path -Parent $Dest
$destinationLeaf = Split-Path -Leaf $Dest
$repairPattern = '^\.' + [regex]::Escape($destinationLeaf) + '\.repair-.+$'
$orphanRepairs = if (Test-Path -LiteralPath $destinationParent -PathType Container -ErrorAction Stop) {
  @(
    Get-ChildItem -LiteralPath $destinationParent -Force -ErrorAction Stop |
      Where-Object { $_.Name -match $repairPattern }
  )
} else {
  @()
}
if ($orphanRepairs.Count -gt 0) {
  throw "Previous damaged release backup requires manual recovery: $($orphanRepairs[0].FullName)"
}

try {
New-Item -ItemType Directory -Force -Path $Root | Out-Null
# Dedicated root/data markers retain ownership of partial trees for a safe
# retry. The config marker is transactional because its directory may be shared.
Write-TextAtomic (Join-Path $Root ".dala-install") "Dala installation root`n"
$PreviousTag = Get-CurrentTag $Root
New-Item -ItemType Directory -Force -Path $DataDir, $ConfigDir, (Join-Path $Root "versions"), (Join-Path $Root "logs") | Out-Null
Write-TextAtomic (Join-Path $DataDir ".dala-data") "Dala data directory`n"
if ($ConfigDirClaimable) {
  Write-TextAtomic $ConfigMarker "Dala configuration directory`n"
  if ($ShouldCreateConfigMarker) { $CreatedConfigMarker = $true }
}

if (-not (Test-CompleteDalaRelease $Dest $ReleaseVersion)) {
  $temp = Join-Path ([IO.Path]::GetTempPath()) ("dala-" + [guid]::NewGuid().ToString("N"))
  $staging = Join-Path $Root ("versions\.install-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $temp | Out-Null

  try {
    $archive = Join-Path $temp $Asset
    $checksum = "$archive.sha256"

    if ($ArchivePath) {
      Copy-Item -LiteralPath (Resolve-Path -LiteralPath $ArchivePath).Path -Destination $archive
      if (-not $ChecksumPath) { throw "ChecksumPath is required with ArchivePath" }
      Copy-Item -LiteralPath (Resolve-Path -LiteralPath $ChecksumPath).Path -Destination $checksum
    } else {
      $url = "https://github.com/$Repo/releases/download/$Version/$Asset"
      Write-Step "Downloading $Asset"
      Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $archive
      Invoke-WebRequest -UseBasicParsing -Uri "$url.sha256" -OutFile $checksum
    }

    $expected = ((Get-Content -LiteralPath $checksum -Raw).Trim() -split '\s+')[0]
    if ($expected -notmatch '^[0-9A-Fa-f]{64}$') { throw "Malformed SHA-256 checksum for $Asset" }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash
    if ($expected.ToUpperInvariant() -ne $actual.ToUpperInvariant()) { throw "SHA-256 checksum mismatch for $Asset" }
    Write-Step "Checksum verified"

    New-Item -ItemType Directory -Path $staging | Out-Null
    Assert-SafeArchive $archive $staging
    Expand-Archive -LiteralPath $archive -DestinationPath $staging -Force
    Assert-CompleteDalaRelease $staging $ReleaseVersion "Release archive"

    if (Test-Path -LiteralPath $Dest) {
      if (Test-CompleteDalaRelease $Dest $ReleaseVersion) {
        # A concurrent installer may have won the same-tag race.  Keep the
        # complete winner and discard our duplicate staging tree.
      } else {
        $running = @(Get-ReleaseBeamProcesses $Dest)
        if ($running.Count -gt 0) {
          throw "Existing release directory is damaged while its BEAM is running; refusing repair: $Dest"
        }

        $backup = Join-Path (Split-Path -Parent $Dest) ("." + (Split-Path -Leaf $Dest) + ".repair-" + [guid]::NewGuid().ToString("N"))
        Move-Item -LiteralPath $Dest -Destination $backup -ErrorAction Stop
        try {
          Move-Item -LiteralPath $staging -Destination $Dest -ErrorAction Stop
          $InstalledNow = $true
          $ReplacedDestinationBackup = $backup
        } catch {
          $installMoveError = $_.Exception.Message
          $restoreError = $null
          try {
            if (Test-Path -LiteralPath $Dest) {
              $restoreError = "destination exists after failed replacement"
            } elseif (-not (Test-Path -LiteralPath $backup)) {
              $restoreError = "original release backup is missing"
            } else {
              Move-Item -LiteralPath $backup -Destination $Dest -ErrorAction Stop
              if (-not (Test-Path -LiteralPath $Dest -PathType Container)) {
                $restoreError = "destination was not restored"
              }
            }
          } catch {
            $restoreError = $_.Exception.Message
          }
          if ($restoreError) {
            throw "$installMoveError; could not restore original release from $backup`: $restoreError"
          }
          throw $installMoveError
        }
      }
    } else {
      try {
        Move-Item -LiteralPath $staging -Destination $Dest -ErrorAction Stop
        $InstalledNow = $true
      } catch {
        # A same-tag installer may have won the destination race. Accept only
        # a complete verified layout and never delete what it may be activating.
        if (-not (Test-CompleteDalaRelease $Dest $ReleaseVersion)) {
          throw
        }
      }
    }
  } finally {
    foreach ($cleanupPath in @($temp, $staging)) {
      try {
        Remove-SafeInstallTree $cleanupPath
      } catch {
        Write-Warning "Could not safely remove installer staging at $cleanupPath`: $($_.Exception.Message)" `
          -WarningAction Continue
      }
    }
  }
}

$TaskLauncher = Get-TaskLauncher $Dest $ReleaseVersion
$UpdateHelper = Get-UpdateHelper $Dest $ReleaseVersion
$PublishHelper = Get-PublishHelper $Dest $ReleaseVersion
if (-not $TaskLauncher) { throw "Release is missing priv\bin\dala_task_launcher.exe: $Dest" }
if (-not $UpdateHelper) { throw "Release is missing priv\windows\update-dala.ps1: $Dest" }
if (-not $PublishHelper) { throw "Release is missing priv\windows\publish-dala.ps1: $Dest" }

$LegacyEnvFile = Join-Path $ConfigDir "dala.env"
if ((Test-Path -LiteralPath $LegacyEnvFile -PathType Leaf) -and -not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
  throw "Legacy $LegacyEnvFile detected; migrate it to config.jsonc before installing"
}
if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) {
  Write-Step "Writing $ConfigFile"
  $config = [ordered]@{
    server = $true
    port = $Port
    listenIp = "127.0.0.1"
    host = "localhost"
    checkOrigin = $false
    dataDir = $DataDir
    databasePath = (Join-Path $DataDir "dala.db")
    releaseRoot = $Root
    serviceName = $TaskName
    updateRepo = $Repo
    auth = [ordered]@{ enabled = $false }
  }
  Write-JsonAtomic $ConfigFile $config
  $CreatedConfig = $true
} else {
  Write-Step "Keeping existing $ConfigFile"
}

$metadata = [ordered]@{
  schemaVersion = 1
  root = $Root
  dataDir = $DataDir
  configFile = $ConfigFile
  taskName = $TaskName
  port = $Port
  repo = $Repo
  platform = $Platform
}

if ($PreviousTag) {
  $previousVersion = $PreviousTag.Substring(1)
  $previousDir = Join-Path $Root "versions\$PreviousTag"
  $previousLauncher = Get-TaskLauncher $previousDir $previousVersion
  if (-not $previousLauncher) { throw "Existing release is missing dala_task_launcher.exe" }
  if (-not (Test-Path -LiteralPath $Runner -PathType Leaf)) {
    Deploy-Runner (Join-Path $previousDir "run-dala.ps1") $Runner
  }

  if ($MetadataTaskName) {
    Assert-TaskName $MetadataTaskName
    $metadataTask = Get-DalaTaskExact $MetadataTaskName
    if ($metadataTask) {
      $null = Assert-DalaTaskObjectOwnership $metadataTask $MetadataTaskName $previousDir $Runner $LogFile
    }
  }

  $registeredTaskName = Find-DalaTaskRegistration $previousDir $Runner $LogFile
  $taskNameMigrated = $false
  $previousTaskWasRunning = $false
  if ($registeredTaskName -and [string]$registeredTaskName -cne [string]$TaskName) {
    if (Get-DalaTaskExact $TaskName) {
      throw "Scheduled task $TaskName already exists and cannot receive the Dala configuration migration"
    }

    $registeredTask = Get-DalaTaskExact $registeredTaskName
    if (-not $registeredTask) { throw "Scheduled Task '$registeredTaskName' disappeared during migration" }
    $null = Assert-DalaTaskObjectOwnership $registeredTask $registeredTaskName $previousDir $Runner $LogFile
    $previousTaskWasRunning = [string]$registeredTask.State -in @("Running", "Queued")
    $CanRollbackCreatedArtifacts = $false
    Remove-DalaTaskVerified $registeredTaskName $previousDir $Runner $LogFile
    $targetRegistrationAmbiguous = $false
    try {
      Register-DalaTaskVerified $TaskName $previousLauncher $Runner $LogFile $previousDir `
        ([ref]$targetRegistrationAmbiguous)
      $taskNameMigrated = $true
      $CanRollbackCreatedArtifacts = $true
    } catch {
      $migrationError = $_.Exception.Message
      try {
        Remove-DalaTaskVerified $TaskName $previousDir $Runner $LogFile
        $restoreRegistrationAmbiguous = $false
        Register-DalaTaskVerified $registeredTaskName $previousLauncher $Runner $LogFile $previousDir `
          ([ref]$restoreRegistrationAmbiguous)
        if ($previousTaskWasRunning) {
          Start-DalaTaskVerified $registeredTaskName $previousDir $Runner $LogFile
        }
        $CanRollbackCreatedArtifacts = $true
      } catch {
        throw "$migrationError; could not restore Scheduled Task '$registeredTaskName': $($_.Exception.Message)"
      }
      throw $migrationError
    }
  } elseif (-not $registeredTaskName) {
    if (Get-DalaTaskExact $TaskName) {
      throw "Scheduled task $TaskName already exists without a valid Dala action"
    }
    $taskRegistrationAmbiguous = $false
    try {
      Register-DalaTaskVerified $TaskName $previousLauncher $Runner $LogFile $previousDir `
        ([ref]$taskRegistrationAmbiguous)
    } catch {
      if ($taskRegistrationAmbiguous) { $CanRollbackCreatedArtifacts = $false }
      throw
    }
    $CreatedTask = $true
  }

  try {
    Write-InstallMetadataPair $RootMetadataFile $DiscoveryFile $metadata ([ref]$MetadataRollbackIncomplete)
    $MetadataWritten = $true
    $CanRollbackCreatedArtifacts = $false
  } catch {
    $metadataError = $_.Exception.Message
    if ($taskNameMigrated) {
      $CanRollbackCreatedArtifacts = $false
      try {
        Remove-DalaTaskVerified $TaskName $previousDir $Runner $LogFile
        $restoreRegistrationAmbiguous = $false
        Register-DalaTaskVerified $registeredTaskName $previousLauncher $Runner $LogFile $previousDir `
          ([ref]$restoreRegistrationAmbiguous)
        if ($previousTaskWasRunning) {
          Start-DalaTaskVerified $registeredTaskName $previousDir $Runner $LogFile
        }
        $taskNameMigrated = $false
        $CanRollbackCreatedArtifacts = $true
      } catch {
        throw "$metadataError; could not restore Scheduled Task '$registeredTaskName': $($_.Exception.Message)"
      }
    } elseif ($CreatedTask) {
      $CanRollbackCreatedArtifacts = $false
      try {
        Remove-DalaTaskVerified $TaskName $previousDir $Runner $LogFile
        $CreatedTask = $false
        $CanRollbackCreatedArtifacts = $true
      } catch {
        throw "$metadataError; could not remove newly created Scheduled Task '$TaskName': $($_.Exception.Message)"
      }
    }
    throw $metadataError
  }

  Write-Step "Switching $PreviousTag -> $Version"
  $updateAttemptId = if ($AttemptId) {
    $AttemptId
  } else {
    [guid]::NewGuid().ToString("D")
  }
  $resultFile = Join-Path $Root "logs\update-results\$updateAttemptId.json"
  Exit-DalaLifecycleMutex $LifecycleMutex
  $LifecycleMutex = $null
  # Keep a repaired release backup until the helper has returned success. If
  # rollback is incomplete, that backup may be the only recoverable copy.
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $UpdateHelper `
    -InstallRoot $Root -TaskName $TaskName -TargetTag $Version -PreviousTag $PreviousTag `
    -ExpectedVersion $ExpectedVersion -PreviousVersion $previousVersion `
    -AttemptId $updateAttemptId -ResultFile $resultFile -HealthTimeoutSeconds $HealthTimeoutSeconds
  if ($LASTEXITCODE -ne 0) { throw "Dala update failed; see $resultFile for the correlated recovery result" }
} else {
  $RunnerExistedBeforeFreshInstall = Test-Path -LiteralPath $Runner -PathType Leaf
  $RunnerBodyBeforeFreshInstall = if ($RunnerExistedBeforeFreshInstall) {
    [IO.File]::ReadAllBytes($Runner)
  } else {
    $null
  }
  $RunnerHashBeforeFreshInstall = if ($RunnerExistedBeforeFreshInstall) {
    Get-BytesSha256 $RunnerBodyBeforeFreshInstall
  } else {
    $null
  }
  $ReleaseRunnerHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ReleaseRunner).Hash
  $FreshTaskRegistrationAmbiguous = $false
  $CanRollbackCreatedArtifacts = $false
  try {
    if (Get-DalaTaskExact $TaskName) {
      throw "Scheduled task $TaskName already exists without a valid Dala install pointer"
    }
    Write-InstallMetadataPair $RootMetadataFile $DiscoveryFile $metadata ([ref]$MetadataRollbackIncomplete)
    $MetadataWritten = $true
    Deploy-Runner $ReleaseRunner $Runner
    Set-Current $Root $Version
    Register-DalaTaskVerified $TaskName $TaskLauncher $Runner $LogFile $Dest `
      ([ref]$FreshTaskRegistrationAmbiguous)
    $CreatedTask = $true
    Start-DalaTaskVerified $TaskName $Dest $Runner $LogFile
    Wait-DalaVersion $Port $ExpectedVersion $Dest $TaskName
  } catch {
    $installError = $_.Exception.Message
    if ($FreshTaskRegistrationAmbiguous) {
      throw "$installError; Scheduled Task state is ambiguous; preserving install artifacts for recovery"
    }
    if ($CreatedTask) {
      try {
        Stop-DalaTaskVerified $TaskName $Dest $Runner $LogFile
      } catch {
        throw "$installError; task stop rollback failed: $($_.Exception.Message)"
      }
    }

    $restartHelper = Get-RestartHelper $Dest $ReleaseVersion
    if (-not $restartHelper) {
      throw "$installError; release stop rollback failed: restart helper is missing"
    }
    $stopOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $restartHelper `
      -StopOnly -StopExecutable $Executable 2>&1 | Out-String
    $stopStatus = $LASTEXITCODE
    if ($stopStatus -ne 0) {
      $stopDetails = $stopOutput.Trim()
      if ($stopDetails) {
        throw "$installError; release stop rollback failed with exit status $stopStatus`: $stopDetails"
      }
      throw "$installError; release stop rollback failed with exit status $stopStatus"
    }

    if ($CreatedTask) {
      try {
        Remove-DalaTaskVerified $TaskName $Dest $Runner $LogFile
        $CreatedTask = $false
      } catch {
        throw "$installError; task unregister rollback failed: $($_.Exception.Message)"
      }
    }

    try {
      # Validate the pointer before touching the runner, then validate it
      # again immediately before removal. This preserves the release as a
      # recovery dependency without overwriting a concurrent install switch.
      $currentFile = Join-Path $Root "current.txt"
      if (Test-Path -LiteralPath $currentFile) {
        if (-not (Test-Path -LiteralPath $currentFile -PathType Leaf)) {
          throw "current release pointer is not a regular file during install rollback: $currentFile"
        }
        $rollbackCurrentTag = (Get-Content -LiteralPath $currentFile -Raw).Trim()
        if ($rollbackCurrentTag -cne $Version) {
          throw "current release changed from $Version to $rollbackCurrentTag during install rollback"
        }
      }

      if (Test-Path -LiteralPath $Runner -PathType Leaf) {
        $rollbackRunnerHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Runner).Hash
        $runnerIsOriginal = $RunnerExistedBeforeFreshInstall -and
          $rollbackRunnerHash -ceq $RunnerHashBeforeFreshInstall
        $runnerIsDeployed = $rollbackRunnerHash -ceq $ReleaseRunnerHash
        if (-not $runnerIsOriginal -and -not $runnerIsDeployed) {
          throw "root runner changed during install rollback: $Runner"
        }
      } elseif (Test-Path -LiteralPath $Runner) {
        throw "root runner is not a regular file during install rollback: $Runner"
      }

      if ($RunnerExistedBeforeFreshInstall) {
        if (-not (Test-Path -LiteralPath $Runner -PathType Leaf) -or
            (Get-FileHash -Algorithm SHA256 -LiteralPath $Runner).Hash -cne $RunnerHashBeforeFreshInstall) {
          Write-BytesAtomic $Runner $RunnerBodyBeforeFreshInstall
        }
      } else {
        Remove-CreatedInstallArtifact $Runner
      }

      # Keep current.txt usable until the runner is safely restored or
      # removed. If runner rollback fails, the retained release remains
      # launchable for manual recovery.
      if (Test-Path -LiteralPath $currentFile) {
        if (-not (Test-Path -LiteralPath $currentFile -PathType Leaf)) {
          throw "current release pointer is not a regular file during install rollback: $currentFile"
        }
        $rollbackCurrentTag = (Get-Content -LiteralPath $currentFile -Raw).Trim()
        if ($rollbackCurrentTag -cne $Version) {
          throw "current release changed from $Version to $rollbackCurrentTag during install rollback"
        }
      }
      Remove-CreatedInstallArtifact $currentFile
    } catch {
      throw "$installError; pointer or runner rollback failed: $($_.Exception.Message); preserving $Dest"
    }

    if ($InstalledNow) {
      try {
        Remove-SafeInstallTree $Dest
        if ($ReplacedDestinationBackup -and (Test-Path -LiteralPath $ReplacedDestinationBackup)) {
          Move-Item -LiteralPath $ReplacedDestinationBackup -Destination $Dest -ErrorAction Stop
          $ReplacedDestinationBackup = $null
        }
      } catch {
        throw "$installError; release tree rollback failed: $($_.Exception.Message)"
      }
    }
    $CanRollbackCreatedArtifacts = $true
    throw $installError
  }
}

if ($ReplacedDestinationBackup) {
  try {
    if (Test-Path -LiteralPath $ReplacedDestinationBackup -ErrorAction Stop) {
      Remove-SafeInstallTree $ReplacedDestinationBackup
    }
    $ReplacedDestinationBackup = $null
  } catch {
    Write-Warning ("Dala is running, but the repaired release backup requires manual cleanup at " +
      "$ReplacedDestinationBackup`: $($_.Exception.Message)") -WarningAction Continue
  }
}

Write-Step "Dala $ExpectedVersion is running at http://localhost:$Port"
} catch {
  $installError = $_.Exception.Message
  if ($CanRollbackCreatedArtifacts) {
    try {
      Restore-InstallArtifacts `
        -RootMetadataPath $RootMetadataFile `
        -RootMetadataExisted $RootMetadataExisted `
        -RootMetadataBody $RootMetadataBody `
        -DiscoveryMetadataPath $DiscoveryFile `
        -DiscoveryMetadataExisted $DiscoveryMetadataExisted `
        -DiscoveryMetadataBody $DiscoveryMetadataBody `
        -RestoreMetadata ($MetadataWritten -or $MetadataRollbackIncomplete) `
        -ConfigPath $ConfigFile `
        -CreatedConfig $CreatedConfig `
        -ConfigMarkerPath $ConfigMarker `
        -CreatedConfigMarker $CreatedConfigMarker
    } catch {
      throw "$installError; install artifact rollback failed: $($_.Exception.Message)"
    }
  }
  throw $installError
}
} finally {
  if ($LifecycleMutex) {
    Exit-DalaLifecycleMutex $LifecycleMutex
    $LifecycleMutex = $null
  }
}
return

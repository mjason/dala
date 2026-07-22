[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$StagingDir,
  [Parameter(Mandatory = $true)][string]$DestinationDir,
  [Parameter(Mandatory = $true)][string]$ExpectedVersion
)

$ErrorActionPreference = "Stop"

function Enter-DalaLifecycleMutex {
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $name = "Global\DalaLifecycle-" + ($sid.Value -replace '[^0-9A-Za-z_-]', '_')
  $created = $false
  $mutex = [Threading.Mutex]::new($false, $name, [ref]$created)
  try {
    if (-not $mutex.WaitOne(0)) {
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

function Get-NormalizedFullPath([string]$Path) {
  $full = [IO.Path]::GetFullPath($Path)
  $root = [IO.Path]::GetPathRoot($full)
  $trimmed = $full.TrimEnd([char[]]"\/")
  $trimmedRoot = $root.TrimEnd([char[]]"\/")

  if ($trimmed.Equals($trimmedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    return $root
  }
  $trimmed
}

function Test-SamePath([string]$Left, [string]$Right) {
  $leftFull = Get-NormalizedFullPath $Left
  $rightFull = Get-NormalizedFullPath $Right
  $leftFull.Equals($rightFull, [StringComparison]::OrdinalIgnoreCase)
}

function Test-PathContains([string]$Parent, [string]$Child) {
  $parentPrefix = (Get-NormalizedFullPath $Parent).TrimEnd([char[]]"\/") + [IO.Path]::DirectorySeparatorChar
  $childFull = Get-NormalizedFullPath $Child
  $childFull.StartsWith($parentPrefix, [StringComparison]::OrdinalIgnoreCase)
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

function Test-NoReparsePoints([string]$Path, [bool]$CheckAncestors = $true) {
  try {
    if ($CheckAncestors -and -not (Test-NoReparseAncestors $Path)) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    $attributes = [IO.File]::GetAttributes($Path)
    if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $true }

    foreach ($entry in Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop) {
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
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $Path "bin\dala.bat") -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $Path "run-dala.ps1") -PathType Leaf)) { return $false }

    $startDataPath = Join-Path $Path "releases\start_erl.data"
    if (-not (Test-Path -LiteralPath $startDataPath -PathType Leaf)) { return $false }
    $startData = @((Get-Content -LiteralPath $startDataPath -Raw).Trim() -split '\s+')
    if ($startData.Count -ne 2 -or $startData[1] -cne $Version) { return $false }
    $ertsVersion = [string]$startData[0]
    if ($ertsVersion -notmatch '^[0-9A-Za-z._-]+$') { return $false }

    foreach ($relative in @(
      "releases\$Version\start.boot",
      "releases\$Version\dala.rel",
      "erts-$ertsVersion\bin\erl.exe",
      "lib\dala-$Version\ebin\Elixir.Dala.beam"
    )) {
      if (-not (Test-Path -LiteralPath (Join-Path $Path $relative) -PathType Leaf)) { return $false }
    }

    $appRoot = Join-Path $Path "lib\dala-$Version"
    $appFile = Join-Path $appRoot "ebin\dala.app"
    if (-not (Test-Path -LiteralPath $appFile -PathType Leaf)) { return $false }
    $versionMatches = [regex]::Matches((Get-Content -LiteralPath $appFile -Raw), '\{vsn,\s*"([^"]+)"\}')
    if ($versionMatches.Count -ne 1 -or $versionMatches[0].Groups[1].Value -cne $Version) { return $false }

    foreach ($relative in @(
      "priv\bin\dala_task_launcher.exe",
      "priv\windows\update-dala.ps1",
      "priv\windows\restart-dala.ps1",
      "priv\windows\publish-dala.ps1"
    )) {
      if (-not (Test-Path -LiteralPath (Join-Path $appRoot $relative) -PathType Leaf)) { return $false }
    }
    $true
  } catch {
    $false
  }
}

function Test-EquivalentDalaRelease([string]$Source, [string]$Candidate, [string]$Version) {
  try {
    if (-not (Test-CompleteDalaRelease $Source $Version) -or
        -not (Test-CompleteDalaRelease $Candidate $Version)) {
      return $false
    }
    if (-not (Test-NoReparsePoints $Source) -or -not (Test-NoReparsePoints $Candidate)) {
      return $false
    }

    $sourceRoot = (Get-NormalizedFullPath $Source).TrimEnd([char[]]"\/") + [IO.Path]::DirectorySeparatorChar
    $candidateRoot = (Get-NormalizedFullPath $Candidate).TrimEnd([char[]]"\/") + [IO.Path]::DirectorySeparatorChar
    $sourceFiles = @(
      Get-ChildItem -LiteralPath $Source -Recurse -File -Force -ErrorAction Stop |
        ForEach-Object { $_.FullName.Substring($sourceRoot.Length) } |
        Sort-Object
    )
    $candidateFiles = @(
      Get-ChildItem -LiteralPath $Candidate -Recurse -File -Force -ErrorAction Stop |
        ForEach-Object { $_.FullName.Substring($candidateRoot.Length) } |
        Sort-Object
    )

    if ($sourceFiles.Count -ne $candidateFiles.Count) { return $false }

    for ($index = 0; $index -lt $sourceFiles.Count; $index++) {
      $relative = [string]$sourceFiles[$index]
      if (-not $relative.Equals([string]$candidateFiles[$index], [StringComparison]::OrdinalIgnoreCase)) {
        return $false
      }

      $sourceFile = Join-Path $Source $relative
      $candidateFile = Join-Path $Candidate $relative
      if ((Get-Item -LiteralPath $sourceFile -ErrorAction Stop).Length -ne
          (Get-Item -LiteralPath $candidateFile -ErrorAction Stop).Length) {
        return $false
      }
      if ((Get-FileHash -Algorithm SHA256 -LiteralPath $sourceFile).Hash -cne
          (Get-FileHash -Algorithm SHA256 -LiteralPath $candidateFile).Hash) {
        return $false
      }
    }
    $true
  } catch {
    $false
  }
}

function Copy-DirectoryTree([string]$Source, [string]$Destination) {
  [IO.Directory]::CreateDirectory($Destination) | Out-Null

  foreach ($entry in Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop) {
    if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Release staging contains a reparse point: $($entry.FullName)"
    }

    $target = Join-Path $Destination $entry.Name
    if ($entry.PSIsContainer) {
      Copy-DirectoryTree $entry.FullName $target
    } else {
      [IO.File]::Copy($entry.FullName, $target, $false)
    }
  }
}

function Move-PublishPath([string]$Source, [string]$Destination) {
  if (Test-Path -LiteralPath $Source -PathType Container) {
    [IO.Directory]::Move($Source, $Destination)
  } else {
    [IO.File]::Move($Source, $Destination)
  }
}

$LifecycleMutex = Enter-DalaLifecycleMutex
$publishTemp = $null
$operationError = $null
$cleanupError = $null
try {
  if ($ExpectedVersion -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
    throw "ExpectedVersion is invalid: $ExpectedVersion"
  }

  $staging = Get-NormalizedFullPath $StagingDir
  $destination = Get-NormalizedFullPath $DestinationDir
  $destinationParent = Split-Path -Parent $destination

  if (Test-SamePath $destination ([IO.Path]::GetPathRoot($destination))) {
    throw "DestinationDir must not be a volume root: $destination"
  }
  if (Test-SamePath $staging $destination) {
    throw "StagingDir and DestinationDir must be different"
  }
  if ((Test-PathContains $staging $destination) -or (Test-PathContains $destination $staging)) {
    throw "StagingDir and DestinationDir must not contain one another"
  }
  if (-not (Test-CompleteDalaRelease $staging $ExpectedVersion)) {
    throw "StagingDir is not a complete Dala Windows release for $ExpectedVersion`: $staging"
  }
  if (-not (Test-NoReparsePoints $staging)) {
    throw "StagingDir contains a reparse point or cannot be inspected safely: $staging"
  }

  if (-not (Test-NoReparseAncestors $destinationParent)) {
    throw "Destination parent contains a reparse point or cannot be inspected safely: $destinationParent"
  }
  [IO.Directory]::CreateDirectory($destinationParent) | Out-Null

  $destinationLeaf = Split-Path -Leaf $destination
  $rollbackPattern = '^\.' + [regex]::Escape($destinationLeaf) + '\.rollback-[0-9A-Fa-f]{32}$'
  $orphanBackups = @(
    Get-ChildItem -LiteralPath $destinationParent -Force -ErrorAction Stop |
      Where-Object { $_.Name -cmatch $rollbackPattern }
  )
  if (-not (Test-Path -LiteralPath $destination)) {
    if ($orphanBackups.Count -gt 1) {
      throw "Multiple previous destination backups require manual recovery under $destinationParent"
    }
    if ($orphanBackups.Count -eq 1) {
      $orphan = $orphanBackups[0]
      if (-not $orphan.PSIsContainer -or
          -not (Test-NoReparsePoints $orphan.FullName) -or
          -not (Test-CompleteDalaRelease $orphan.FullName $ExpectedVersion)) {
        throw "Previous destination backup is not a complete safe Dala release: $($orphan.FullName)"
      }
      Move-PublishPath $orphanBackups[0].FullName $destination
    }
  }
  if ((Test-Path -LiteralPath $destination) -and -not (Test-NoReparsePoints $destination)) {
    throw "DestinationDir contains a reparse point or cannot be inspected safely: $destination"
  }

  $destinationReady =
    (Test-Path -LiteralPath $destination) -and
    (Test-EquivalentDalaRelease $staging $destination $ExpectedVersion)

  if (-not $destinationReady) {
    do {
      $publishTemp = Join-Path $destinationParent (".$destinationLeaf.publish-" + [guid]::NewGuid().ToString("N"))
    } while (Test-Path -LiteralPath $publishTemp)

    Copy-DirectoryTree $staging $publishTemp
    if (-not (Test-EquivalentDalaRelease $staging $publishTemp $ExpectedVersion)) {
      throw "Copied release does not match staging: $publishTemp"
    }

    $destinationReady =
      (Test-Path -LiteralPath $destination) -and
      (Test-EquivalentDalaRelease $staging $destination $ExpectedVersion)

    if (-not $destinationReady) {
      $destinationBackup = $null
      if (Test-Path -LiteralPath $destination) {
        do {
          $destinationBackup = Join-Path $destinationParent (".$destinationLeaf.rollback-" + [guid]::NewGuid().ToString("N"))
        } while (Test-Path -LiteralPath $destinationBackup)
        Move-PublishPath $destination $destinationBackup
      }

      try {
        [IO.Directory]::Move($publishTemp, $destination)
        $publishTemp = $null
      } catch {
        $commitMessage = $_.Exception.Message
        if ($destinationBackup -and (Test-Path -LiteralPath $destinationBackup)) {
          if (Test-Path -LiteralPath $destination) {
            throw "$commitMessage; previous destination remains at $destinationBackup"
          }
          try {
            Move-PublishPath $destinationBackup $destination
            $destinationBackup = $null
          } catch {
            throw "$commitMessage; could not restore previous destination: $($_.Exception.Message); backup remains at $destinationBackup"
          }
        }
        throw $commitMessage
      }

      if ($destinationBackup -and (Test-Path -LiteralPath $destinationBackup)) {
        try {
          Remove-Item -LiteralPath $destinationBackup -Recurse -Force -ErrorAction Stop
          $destinationBackup = $null
        } catch {
          Write-Warning "Published $destination but could not remove previous destination at $destinationBackup`: $($_.Exception.Message)"
        }
      }
    }
  }
} catch {
  $operationError = $_
} finally {
  try {
    if ($publishTemp -and (Test-Path -LiteralPath $publishTemp)) {
      Remove-Item -LiteralPath $publishTemp -Recurse -Force -ErrorAction Stop
    }
  } catch {
    $cleanupError = $_
  } finally {
    try {
      Exit-DalaLifecycleMutex $LifecycleMutex
      $LifecycleMutex = $null
    } catch {
      if ($cleanupError) {
        Write-Warning "Lifecycle mutex cleanup also failed: $($_.Exception.Message)"
      } else {
        $cleanupError = $_
      }
    }
  }
}

if ($operationError) {
  if ($cleanupError) {
    throw "$($operationError.Exception.Message); publish cleanup failed: $($cleanupError.Exception.Message)"
  }
  throw $operationError
}
if ($cleanupError) { throw $cleanupError }

[CmdletBinding()]
param(
  [string]$InstallerScript = "install.ps1",
  [string]$UpdateHelperScript = "priv\windows\update-dala.ps1"
)

$ErrorActionPreference = "Stop"

function Assert-True($Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

function Assert-UpdateResultStateSemantics([string]$ScriptPath) {
  $resolved = (Resolve-Path -LiteralPath $ScriptPath).Path
  $body = [IO.File]::ReadAllText($resolved)
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($resolved, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { throw "Cannot inspect invalid PowerShell script: $resolved" }

  $successWrites = @(
    $ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq "Write-UpdateResult" -and
        $node.Extent.Text -match '(?i)^Write-UpdateResult\s+\$true\s+\$false(?:\s|$)'
    }, $true)
  )
  Assert-True ($successWrites.Count -eq 1) `
    "$resolved must have exactly one successful update-result commit"
  $successStatement = $successWrites[0].Parent
  $successBlock = $successStatement.Parent
  Assert-True ($successBlock -is [Management.Automation.Language.StatementBlockAst] -and
      $successBlock.Parent -is [Management.Automation.Language.TryStatementAst] -and
      [object]::ReferenceEquals($successBlock.Statements[-1], $successStatement)) `
    "$resolved performs a fallible transaction step after committing the successful update result"

  $failureWrites = [regex]::Matches(
    $body,
    'Write-UpdateResult\s+\$false\s+\$rolledBack\s+\$failureMessage',
    [Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
  Assert-True ($failureWrites.Count -eq 2) `
    "$resolved must preserve rolledBack in both failure-result write paths"
  Assert-True (-not [regex]::IsMatch(
      $body,
      'Write-UpdateResult\s+\$false\s+\$false',
      [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )) "$resolved overwrites authoritative rollback state with false"
}

function Assert-WarningsCannotTerminate([string]$ScriptPath) {
  $resolved = (Resolve-Path -LiteralPath $ScriptPath).Path
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($resolved, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { throw "Cannot inspect invalid PowerShell script: $resolved" }

  $warnings = @(
    $ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq "Write-Warning"
    }, $true)
  )
  Assert-True ($warnings.Count -gt 0) "$resolved does not expose cleanup warnings"
  foreach ($warning in $warnings) {
    Assert-True ($warning.Extent.Text -match '(?i)-WarningAction\s+Continue') `
      "$resolved allows a caller's WarningPreference to turn cleanup into failure"
  }
}

function Assert-RecoverableReplaceSemantics(
  [string]$ScriptPath,
  [string]$WorkRoot,
  [int]$ExpectedHelperCalls
) {
  $resolved = (Resolve-Path -LiteralPath $ScriptPath).Path
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($resolved, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) {
    $details = @($errors | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" }) -join "; "
    throw "PowerShell parser rejected $resolved`: $details"
  }

  $definitions = @(
    $ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq "Invoke-RecoverableFileReplace"
    }, $true)
  )
  Assert-True ($definitions.Count -eq 1) "$resolved must define exactly one recoverable replace helper"

  $replaceCalls = [regex]::Matches(
    [IO.File]::ReadAllText($resolved),
    '\[IO\.File\]::Replace\s*\(',
    [Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
  Assert-True ($replaceCalls.Count -eq 1) "$resolved must call File.Replace only inside the helper"

  $helperCalls = @(
    $ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -ceq "Invoke-RecoverableFileReplace"
    }, $true)
  )
  Assert-True ($helperCalls.Count -eq $ExpectedHelperCalls) `
    "$resolved must route all $ExpectedHelperCalls atomic replacements through the helper"

  $helperBody = $definitions[0].Extent.Text
  Assert-True ([regex]::IsMatch(
      $helperBody,
      'try\s*\{\s*if\s*\(Test-Path\s+-LiteralPath\s+\$backup\s+-ErrorAction\s+Stop\)',
      [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )) "$resolved probes post-commit backup state outside its cleanup guard"
  Assert-True ([regex]::IsMatch(
      $helperBody,
      'Write-Warning[\s\S]+?-WarningAction\s+Continue',
      [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )) "$resolved allows cleanup warnings to become transaction failures"

  $module = New-Module -ScriptBlock ([ScriptBlock]::Create($definitions[0].Extent.Text))
  $caseRoot = Join-Path $WorkRoot ([IO.Path]::GetFileNameWithoutExtension($resolved))
  New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null

  try {
    $successSource = Join-Path $caseRoot "success-source.txt"
    $successDestination = Join-Path $caseRoot "success-destination.txt"
    [IO.File]::WriteAllText($successSource, "new")
    [IO.File]::WriteAllText($successDestination, "old")
    & $module {
      param($Source, $Destination)
      Invoke-RecoverableFileReplace $Source $Destination
    } $successSource $successDestination
    Assert-True ((Get-Content -LiteralPath $successDestination -Raw) -ceq "new") `
      "$resolved did not replace the destination"
    Assert-True (-not (Test-Path -LiteralPath $successSource)) "$resolved did not consume the replacement source"
    Assert-True (@(Get-ChildItem -LiteralPath $caseRoot -Filter "success-destination.txt.backup-*" -Force).Count -eq 0) `
      "$resolved left a backup after successful replacement"

    # File.Replace has already committed the destination when cleanup of the
    # old-byte backup can fail. On Windows, hold the real backup open without
    # delete sharing; other platforms use an equivalent invalid cleanup target
    # so this helper-level smoke remains portable.
    $cleanupFailureSource = Join-Path $caseRoot "cleanup-failure-source.txt"
    $cleanupFailureDestination = Join-Path $caseRoot "cleanup-failure-destination.txt"
    [IO.File]::WriteAllText($cleanupFailureSource, "new")
    [IO.File]::WriteAllText($cleanupFailureDestination, "old")
    $runningOnWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
    $cleanupFailureHandle = [pscustomobject]@{ stream = $null }
    $simulateCleanupFailure = if ($runningOnWindows) {
      {
        param($Source, $Destination, $Backup)
        [IO.File]::Replace($Source, $Destination, $Backup)
        $cleanupFailureHandle.stream = [IO.File]::Open(
          $Backup,
          [IO.FileMode]::Open,
          [IO.FileAccess]::Read,
          [IO.FileShare]::Read
        )
      }.GetNewClosure()
    } else {
      {
        param($Source, $Destination, $Backup)
        [IO.File]::Delete($Destination)
        [IO.File]::Move($Source, $Destination)
        [IO.Directory]::CreateDirectory($Backup) | Out-Null
        [IO.File]::WriteAllText((Join-Path $Backup "original-bytes.txt"), "old")
      }
    }
    $cleanupFailureReturned = $false
    try {
      try {
        & $module {
          param($Source, $Destination, $Operation)
          $WarningPreference = "Stop"
          Invoke-RecoverableFileReplace $Source $Destination $Operation
        } $cleanupFailureSource $cleanupFailureDestination $simulateCleanupFailure
        $cleanupFailureReturned = $true
      } catch {
        throw "$resolved treated a committed replacement with cleanup failure as a transaction failure: $($_.Exception.Message)"
      }
      Assert-True $cleanupFailureReturned "$resolved did not return success after a committed replacement cleanup failure"
      Assert-True ((Get-Content -LiteralPath $cleanupFailureDestination -Raw) -ceq "new") `
        "$resolved changed the committed destination after backup cleanup failure"
      Assert-True (-not (Test-Path -LiteralPath $cleanupFailureSource)) `
        "$resolved left the replacement source after backup cleanup failure"
      $cleanupFailureBackups = @(
        Get-ChildItem -LiteralPath $caseRoot -Filter "cleanup-failure-destination.txt.backup-*" -Force
      )
      Assert-True ($cleanupFailureBackups.Count -eq 1) `
        "$resolved discarded the recovery artifact after backup cleanup failure"
      if ($runningOnWindows) {
        Assert-True (-not $cleanupFailureBackups[0].PSIsContainer) `
          "$resolved did not retain the regular File.Replace backup"
        Assert-True ((Get-Content -LiteralPath $cleanupFailureBackups[0].FullName -Raw) -ceq "old") `
          "$resolved did not retain the original destination bytes"
      } else {
        Assert-True $cleanupFailureBackups[0].PSIsContainer `
          "$resolved did not retain the portable recovery artifact"
      }
    } finally {
      if ($cleanupFailureHandle.stream) { $cleanupFailureHandle.stream.Dispose() }
      Get-ChildItem -LiteralPath $caseRoot -Filter "cleanup-failure-destination.txt.backup-*" -Force |
        ForEach-Object {
          if ($_.PSIsContainer) {
            [IO.Directory]::Delete($_.FullName, $true)
          } else {
            [IO.File]::Delete($_.FullName)
          }
        }
    }

    $postCommitSource = Join-Path $caseRoot "post-commit-source.txt"
    $postCommitDestination = Join-Path $caseRoot "post-commit-destination.txt"
    [IO.File]::WriteAllText($postCommitSource, "new")
    [IO.File]::WriteAllText($postCommitDestination, "old")
    $simulatePostCommitError = {
      param($Source, $Destination, $Backup)
      [IO.File]::Replace($Source, $Destination, $Backup)
      throw [IO.IOException]::new("replacement reported failure after commit")
    }
    try {
      & $module {
        param($Source, $Destination, $Operation)
        Invoke-RecoverableFileReplace $Source $Destination $Operation
      } $postCommitSource $postCommitDestination $simulatePostCommitError
    } catch {
      throw "$resolved did not recognize a content-verified post-commit replacement: $($_.Exception.Message)"
    }
    Assert-True ((Get-Content -LiteralPath $postCommitDestination -Raw) -ceq "new") `
      "$resolved rolled back a content-verified post-commit replacement"
    Assert-True (-not (Test-Path -LiteralPath $postCommitSource)) `
      "$resolved retained the consumed post-commit replacement source"
    Assert-True (@(
        Get-ChildItem -LiteralPath $caseRoot -Filter "post-commit-destination.txt.backup-*" -Force
      ).Count -eq 0) "$resolved retained a backup after verifying the committed destination"

    $recoverSource = Join-Path $caseRoot "recover-source.txt"
    $recoverDestination = Join-Path $caseRoot "recover-destination.txt"
    [IO.File]::WriteAllText($recoverSource, "new")
    [IO.File]::WriteAllText($recoverDestination, "old")
    $simulate1177 = {
      param($Source, $Destination, $Backup)
      [IO.File]::Move($Destination, $Backup)
      throw [IO.IOException]::new("simulated ERROR_UNABLE_TO_MOVE_REPLACEMENT_2")
    }
    $recoverFailed = $false
    try {
      & $module {
        param($Source, $Destination, $Operation)
        Invoke-RecoverableFileReplace $Source $Destination $Operation
      } $recoverSource $recoverDestination $simulate1177
    } catch {
      if ($_.Exception.Message -notmatch "ERROR_UNABLE_TO_MOVE_REPLACEMENT_2") { throw }
      $recoverFailed = $true
    }
    Assert-True $recoverFailed "$resolved hid the simulated ReplaceFile failure"
    Assert-True ((Get-Content -LiteralPath $recoverDestination -Raw) -ceq "old") `
      "$resolved did not restore the destination from the recovery backup"
    Assert-True (-not (Test-Path -LiteralPath $recoverSource)) `
      "$resolved left a replacement source after successful recovery"
    Assert-True (@(Get-ChildItem -LiteralPath $caseRoot -Filter "recover-destination.txt.backup-*" -Force).Count -eq 0) `
      "$resolved left a backup after successful recovery"

    $ambiguousSource = Join-Path $caseRoot "ambiguous-source.txt"
    $ambiguousDestination = Join-Path $caseRoot "ambiguous-destination.txt"
    [IO.File]::WriteAllText($ambiguousSource, "new")
    [IO.File]::WriteAllText($ambiguousDestination, "old")
    $simulateAmbiguousFailure = {
      param($Source, $Destination, $Backup)
      [IO.File]::Copy($Destination, $Backup, $false)
      throw [IO.IOException]::new("simulated ambiguous replacement failure")
    }
    $ambiguousFailed = $false
    try {
      & $module {
        param($Source, $Destination, $Operation)
        Invoke-RecoverableFileReplace $Source $Destination $Operation
      } $ambiguousSource $ambiguousDestination $simulateAmbiguousFailure
    } catch {
      if ($_.Exception.Message -notmatch "recovery backup remains") { throw }
      $ambiguousFailed = $true
    }
    Assert-True $ambiguousFailed "$resolved hid an ambiguous replacement failure"
    $ambiguousBackups = @(
      Get-ChildItem -LiteralPath $caseRoot -Filter "ambiguous-destination.txt.backup-*" -File -Force
    )
    Assert-True ($ambiguousBackups.Count -eq 1) "$resolved deleted the only backup for an ambiguous failure"
    Assert-True ((Get-Content -LiteralPath $ambiguousBackups[0].FullName -Raw) -ceq "old") `
      "$resolved did not preserve the original destination backup"
    Assert-True ((Get-Content -LiteralPath $ambiguousSource -Raw) -ceq "new") `
      "$resolved deleted the replacement source for an ambiguous failure"

    $missingSource = Join-Path $caseRoot "missing-source.txt"
    $missingDestination = Join-Path $caseRoot "missing-destination.txt"
    [IO.File]::WriteAllText($missingSource, "new")
    [IO.File]::WriteAllText($missingDestination, "old")
    $simulateMissingFailure = {
      param($Source, $Destination, $Backup)
      [IO.File]::Delete($Destination)
      throw [IO.IOException]::new("simulated missing replacement state")
    }
    $missingFailed = $false
    try {
      & $module {
        param($Source, $Destination, $Operation)
        Invoke-RecoverableFileReplace $Source $Destination $Operation
      } $missingSource $missingDestination $simulateMissingFailure
    } catch {
      if ($_.Exception.Message -notmatch "both missing" -or
          $_.Exception.Message -notmatch [regex]::Escape($missingSource)) { throw }
      $missingFailed = $true
    }
    Assert-True $missingFailed "$resolved hid a missing destination and backup"
    Assert-True ((Get-Content -LiteralPath $missingSource -Raw) -ceq "new") `
      "$resolved deleted the only remaining replacement source"

    $presentSource = Join-Path $caseRoot "present-source.txt"
    $presentDestination = Join-Path $caseRoot "present-destination.txt"
    [IO.File]::WriteAllText($presentSource, "new")
    [IO.File]::WriteAllText($presentDestination, "current")
    $simulatePresentFailure = {
      param([string]$Source, [string]$Destination, [string]$Backup)
      throw [IO.IOException]::new("simulated destination-present replacement failure")
    }
    $presentFailed = $false
    try {
      & $module {
        param($Source, $Destination, $Operation)
        Invoke-RecoverableFileReplace $Source $Destination $Operation
      } $presentSource $presentDestination $simulatePresentFailure
    } catch {
      if ($_.Exception.Message -notmatch "ambiguous" -or
          $_.Exception.Message -notmatch [regex]::Escape($presentSource)) { throw }
      $presentFailed = $true
    }
    Assert-True $presentFailed "$resolved treated a present destination without backup as safe"
    Assert-True ((Get-Content -LiteralPath $presentSource -Raw) -ceq "new") `
      "$resolved deleted the source for an ambiguous destination-present failure"

    $invalidSource = Join-Path $caseRoot "invalid-source.txt"
    $invalidDestination = Join-Path $caseRoot "invalid-destination.txt"
    [IO.File]::WriteAllText($invalidSource, "new")
    [IO.File]::WriteAllText($invalidDestination, "old")
    $simulateInvalidBackup = {
      param($Source, $Destination, $Backup)
      [IO.File]::Delete($Destination)
      [IO.Directory]::CreateDirectory($Backup) | Out-Null
      throw [IO.IOException]::new("simulated invalid backup type")
    }
    $invalidFailed = $false
    try {
      & $module {
        param($Source, $Destination, $Operation)
        Invoke-RecoverableFileReplace $Source $Destination $Operation
      } $invalidSource $invalidDestination $simulateInvalidBackup
    } catch {
      if ($_.Exception.Message -notmatch "not a regular file") { throw }
      $invalidFailed = $true
    }
    Assert-True $invalidFailed "$resolved accepted a directory as a recovery backup"
    Assert-True (-not (Test-Path -LiteralPath $invalidDestination)) `
      "$resolved renamed a directory backup over the destination"
    Assert-True ((Get-Content -LiteralPath $invalidSource -Raw) -ceq "new") `
      "$resolved deleted the source after rejecting an invalid backup"

    $orphanSource = Join-Path $caseRoot "orphan-source.txt"
    $orphanDestination = Join-Path $caseRoot "orphan-destination.txt"
    # Older releases used numeric/base64 backup tokens. The helper must reject
    # those leftovers too instead of treating only GUID-shaped names as safe.
    $orphanBackup = "$orphanDestination.backup-legacy-token"
    [IO.File]::WriteAllText($orphanSource, "new")
    [IO.File]::WriteAllText($orphanDestination, "current")
    [IO.File]::WriteAllText($orphanBackup, "recovery")
    $orphanRejected = $false
    try {
      & $module {
        param($Source, $Destination)
        Invoke-RecoverableFileReplace $Source $Destination
      } $orphanSource $orphanDestination
    } catch {
      if ($_.Exception.Message -notmatch "manual recovery") { throw }
      $orphanRejected = $true
    }
    Assert-True $orphanRejected "$resolved ignored an existing recovery backup"
    Assert-True ((Get-Content -LiteralPath $orphanDestination -Raw) -ceq "current") `
      "$resolved changed the destination while rejecting an orphan backup"
    Assert-True ((Get-Content -LiteralPath $orphanBackup -Raw) -ceq "recovery") `
      "$resolved deleted an orphan recovery backup"
    Assert-True ((Get-Content -LiteralPath $orphanSource -Raw) -ceq "new") `
      "$resolved deleted the staged source while rejecting an orphan backup"
  } finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
  }
}

function Assert-SafeInstallRemovalSemantics([string]$ScriptPath, [string]$WorkRoot) {
  $resolved = (Resolve-Path -LiteralPath $ScriptPath).Path
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($resolved, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { throw "Cannot inspect invalid PowerShell script: $resolved" }

  $requiredFunctions = @("Test-NoReparseAncestors", "Remove-SafeInstallTree")
  $definitions = @(
    $ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $requiredFunctions -contains $node.Name
    }, $true)
  )
  foreach ($name in $requiredFunctions) {
    Assert-True (@($definitions | Where-Object { $_.Name -ceq $name }).Count -eq 1) `
      "$resolved must define exactly one $name function"
  }
  Assert-True ([regex]::Matches([IO.File]::ReadAllText($resolved), 'Remove-Item[^\r\n]*-Recurse', `
      [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count -eq 0) `
    "$resolved still uses recursive Remove-Item"

  $moduleBody = @($definitions | ForEach-Object { $_.Extent.Text }) -join "`n"
  $module = New-Module -ScriptBlock ([ScriptBlock]::Create($moduleBody))
  $safeRoot = Join-Path $WorkRoot "safe installer cleanup"
  $safeChild = Join-Path $safeRoot "nested\payload.txt"
  $junctionRoot = Join-Path $WorkRoot "junction installer cleanup"
  $victim = Join-Path $WorkRoot "installer cleanup victim"
  $junction = Join-Path $junctionRoot "external-junction"
  $sentinel = Join-Path $victim "must-survive.txt"

  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $safeChild), $junctionRoot, $victim | Out-Null
  [IO.File]::WriteAllText($safeChild, "remove me")
  [IO.File]::WriteAllText($sentinel, "must survive")
  $linkType = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    "Junction"
  } else {
    "SymbolicLink"
  }
  New-Item -ItemType $linkType -Path $junction -Target $victim -ErrorAction Stop | Out-Null
  Assert-True (Test-Path -LiteralPath $junction) `
    "$resolved smoke fixture did not create the external directory link"

  try {
    & $module { param($Path) Remove-SafeInstallTree $Path } $safeRoot
    Assert-True (-not (Test-Path -LiteralPath $safeRoot)) "$resolved did not remove a safe staging tree"

    $rejected = $false
    try {
      & $module { param($Path) Remove-SafeInstallTree $Path } $junctionRoot
    } catch {
      if ($_.Exception.Message -notmatch "reparse") { throw }
      $rejected = $true
    }
    Assert-True $rejected "$resolved followed a junction during cleanup"
    Assert-True (Test-Path -LiteralPath $sentinel -PathType Leaf) `
      "$resolved removed a file outside the installer cleanup tree"
  } finally {
    if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction) }
    Remove-Module $module -Force -ErrorAction SilentlyContinue
  }
}

$workRoot = Join-Path ([IO.Path]::GetTempPath()) ("dala-atomic-replace-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $workRoot | Out-Null
try {
  Assert-RecoverableReplaceSemantics $InstallerScript $workRoot 4
  Assert-RecoverableReplaceSemantics $UpdateHelperScript $workRoot 3
  Assert-UpdateResultStateSemantics $UpdateHelperScript
  Assert-WarningsCannotTerminate $InstallerScript
  Assert-WarningsCannotTerminate $UpdateHelperScript
  Assert-SafeInstallRemovalSemantics $InstallerScript $workRoot
} finally {
  Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}

[pscustomobject]@{
  scripts = 2
  successful_replace_cleanup = $true
  error_1177_recovered = $true
  ambiguous_backup_preserved = $true
  missing_state_source_preserved = $true
  destination_present_ambiguous = $true
  invalid_backup_rejected = $true
  orphan_backup_rejected = $true
  authoritative_failure_result = $true
  junction_cleanup_rejected = $true
}

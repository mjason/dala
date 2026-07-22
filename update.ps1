[CmdletBinding()]
param([string]$Version)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$RepoPattern = '^[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,98}[A-Za-z0-9])?/[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,98}[A-Za-z0-9])?$'
$DefaultRoot = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "Dala"
$DefaultConfigDir = Join-Path $env:APPDATA "Dala"
$DiscoveryFile = Join-Path $DefaultConfigDir "install.json"
$installer = Join-Path ([IO.Path]::GetTempPath()) ("dala-install-" + [guid]::NewGuid().ToString("N") + ".ps1")

function Assert-UpdateRepo([string]$Repo) {
  if ([string]::IsNullOrWhiteSpace($Repo) -or
      $Repo -cnotmatch $RepoPattern) {
    throw "Invalid Dala update repository: $Repo"
  }
  $Repo
}

function Test-SamePath([string]$Left, [string]$Right) {
  $leftFull = [IO.Path]::GetFullPath($Left).TrimEnd([char[]]"\/")
  $rightFull = [IO.Path]::GetFullPath($Right).TrimEnd([char[]]"\/")
  $leftFull.Equals($rightFull, [StringComparison]::OrdinalIgnoreCase)
}

function Read-InstallMetadata([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
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

function Get-UpdateRepo {
  $discoveryMetadata = Read-InstallMetadata $DiscoveryFile
  $rootHint = if ($env:DALA_HOME) {
    $env:DALA_HOME
  } elseif ($discoveryMetadata) {
    [string]$discoveryMetadata.root
  } else {
    $DefaultRoot
  }
  $rootMetadata = Read-InstallMetadata (Join-Path ([IO.Path]::GetFullPath($rootHint)) "install.json")
  if ($discoveryMetadata -and $rootMetadata) {
    Assert-InstallMetadataMatch $discoveryMetadata $rootMetadata
  }
  $metadata = if ($rootMetadata) { $rootMetadata } else { $discoveryMetadata }

  if (-not $metadata) {
    if ($env:DALA_REPO) { return $env:DALA_REPO }
    return "mjason/dala"
  }
  if ($env:DALA_REPO -and [string]$env:DALA_REPO -cne [string]$metadata.repo) {
    throw "DALA_REPO conflicts with the existing install metadata"
  }
  [string]$metadata.repo
}

try {
  $repo = Assert-UpdateRepo (Get-UpdateRepo)
  Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/$repo/main/install.ps1" -OutFile $installer

  if ($Version) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Version $Version
  } else {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer
  }

  $status = $LASTEXITCODE
  if ($status -ne 0) { throw "Dala installer failed with exit status $status" }
} finally {
  Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
}

return

[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ReleaseRoot)

$ErrorActionPreference = "Stop"
$applications = @(Get-ChildItem -Path (Join-Path $ReleaseRoot "lib/dala-*") -Directory)
if ($applications.Count -ne 1) { throw "Expected one Dala application in $ReleaseRoot" }
$static = Join-Path $applications[0].FullName "priv/static"
$manifestPath = Join-Path $static "cache_manifest.json"
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
  throw "Static manifest missing: $manifestPath"
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
foreach ($asset in @("assets/index.js", "assets/app.js", "assets/css/app.css")) {
  if (-not $manifest.latest.$asset) { throw "Static manifest has no entry for $asset" }
}
foreach ($entry in $manifest.latest.PSObject.Properties) {
  foreach ($relativePath in @($entry.Name, [string]$entry.Value)) {
    $file = Get-Item -LiteralPath (Join-Path $static $relativePath) -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Length -eq 0) { throw "Static asset is empty: $relativePath" }
  }
}
Write-Output "Static assets verified: entrypoints, manifest, and all digested files"

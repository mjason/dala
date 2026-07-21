[CmdletBinding()]
param([string]$Version)

$ErrorActionPreference = "Stop"
$installer = Join-Path ([IO.Path]::GetTempPath()) ("dala-install-" + [guid]::NewGuid().ToString("N") + ".ps1")
try {
  $repo = if ($env:DALA_REPO) { $env:DALA_REPO } else { "mjason/dala" }
  Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/$repo/main/install.ps1" -OutFile $installer
  if ($Version) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Version $Version
  } else {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer
  }
  exit $LASTEXITCODE
} finally {
  Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
}

[CmdletBinding()]
param(
  [string]$ReleaseDir = "_build/prod/rel/dala",
  [string]$UninstallScript = "uninstall.ps1"
)

$ErrorActionPreference = "Stop"

function Get-FreePort {
  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
  $listener.Start()
  try {
    ([Net.IPEndPoint]$listener.LocalEndpoint).Port
  } finally {
    $listener.Stop()
  }
}

function Wait-Http([int]$Port) {
  for ($attempt = 0; $attempt -lt 60; $attempt++) {
    try {
      $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 -Uri "http://127.0.0.1:$Port/"
      if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) {
        return $response.StatusCode
      }
    } catch {}

    Start-Sleep -Milliseconds 500
  }

  throw "Dala did not become healthy on port $Port"
}

function Start-Runner([string]$Launcher, [string]$Runner, [string]$LogFile) {
  Start-Process -FilePath $Launcher -ArgumentList @(
    "`"$Runner`"",
    "`"$LogFile`""
  ) -PassThru
}

function Find-SmokeBeam([string]$InstallRoot, [string]$ReleaseRoot) {
  Get-CimInstance Win32_Process -Filter "Name='erl.exe'" |
    Where-Object {
      $_.CommandLine -like "*$InstallRoot*" -or $_.CommandLine -like "*$ReleaseRoot*"
    } |
    Select-Object -First 1
}

function Assert-NoVisibleConsole([uint32]$BeamPid, [uint32[]]$ExistingOpenConsolePids) {
  $processIds = @()
  $processChain = @()
  $process = Get-CimInstance Win32_Process -Filter "ProcessId=$BeamPid"

  while ($process -and $processIds -notcontains [uint32]$process.ProcessId) {
    $processIds += [uint32]$process.ProcessId
    $processChain += "$($process.Name):$($process.ProcessId)"
    if ($process.Name -eq "dala_task_launcher.exe") { break }
    if ($process.ParentProcessId -eq 0) { break }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($process.ParentProcessId)" -ErrorAction SilentlyContinue
  }

  if (-not $process -or $process.Name -ne "dala_task_launcher.exe") {
    throw "release process chain is not owned by dala_task_launcher.exe"
  }

  $visibleConsole = Get-CimInstance Win32_Process -Filter "Name='OpenConsole.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      $ExistingOpenConsolePids -notcontains [uint32]$_.ProcessId -and
      $_.CommandLine -notmatch '(?:^|\s)--headless(?:\s|$)'
    } |
    Select-Object -First 1

  if ($visibleConsole) {
    throw "release process chain $($processChain -join ' <- ') created visible console host PID $($visibleConsole.ProcessId): $($visibleConsole.CommandLine)"
  }
}

$release = (Resolve-Path -LiteralPath $ReleaseDir).Path
$uninstall = (Resolve-Path -LiteralPath $UninstallScript).Path
$releaseBatch = Join-Path $release "bin\dala.bat"
$releaseRunner = Join-Path $release "run-dala.ps1"
$restartHelper = Get-ChildItem -LiteralPath $release -Filter "restart-dala.ps1" -Recurse -File |
  Where-Object { $_.FullName -like "*\priv\windows\restart-dala.ps1" } |
  Select-Object -First 1 -ExpandProperty FullName
$taskLauncher = Get-ChildItem -LiteralPath $release -Filter "dala_task_launcher.exe" -Recurse -File |
  Where-Object { $_.FullName -like "*\priv\bin\dala_task_launcher.exe" } |
  Select-Object -First 1 -ExpandProperty FullName

if (-not (Test-Path -LiteralPath $releaseBatch -PathType Leaf)) {
  throw "Release is missing bin\dala.bat: $release"
}

if (-not (Test-Path -LiteralPath $releaseRunner -PathType Leaf)) {
  throw "Release is missing run-dala.ps1: $release"
}

if (-not $restartHelper) {
  throw "Release is missing priv\windows\restart-dala.ps1: $release"
}

if (-not $taskLauncher) {
  throw "Release is missing priv\bin\dala_task_launcher.exe: $release"
}

$smokeRoot = Join-Path ([IO.Path]::GetTempPath()) ("dala release smoke " + [guid]::NewGuid().ToString("N"))
$installRoot = Join-Path $smokeRoot "install root"
$dataDir = Join-Path $smokeRoot "data dir"
$configFile = Join-Path $smokeRoot "dala.env"
$helperFile = Join-Path $smokeRoot "release_smoke.exs"
$resultFile = Join-Path $smokeRoot "result.json"
$logFile = Join-Path $smokeRoot "server.log"
$tag = "v0.0.0"
$versionDir = Join-Path $installRoot "versions\$tag"
$installedReleaseBatch = Join-Path $versionDir "bin\dala.bat"
$runner = Join-Path $installRoot "run-dala.ps1"
$port = Get-FreePort
$sessionId = "release-smoke-" + [guid]::NewGuid().ToString("N")
$marker = "DALA_RELEASE_REATTACH_" + [guid]::NewGuid().ToString("N")
$releaseNode = "dala_smoke_" + [guid]::NewGuid().ToString("N")
$releaseCookie = "dala_smoke_cookie_" + [guid]::NewGuid().ToString("N")
$server = $null
$serverAfterRestart = $null
$holderPid = $null
$summary = $null
$openConsolePidsBefore = @(
  Get-CimInstance Win32_Process -Filter "Name='OpenConsole.exe'" -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty ProcessId
)

$helper = @'
alias Dala.Terminal.{Holder, Shell}

id = System.fetch_env!("DALA_SMOKE_ID")
marker = System.fetch_env!("DALA_SMOKE_MARKER")
result_path = System.fetch_env!("DALA_SMOKE_RESULT")

receive_frame = fn receive_frame, socket, expected_type ->
  receive do
    {:tcp, ^socket, message} ->
      type = :binary.first(message)
      payload = binary_part(message, 1, byte_size(message) - 1)

      if type == expected_type do
        payload
      else
        receive_frame.(receive_frame, socket, expected_type)
      end
  after
    5_000 -> raise "holder frame timeout"
  end
end

case System.fetch_env!("DALA_SMOKE_PHASE") do
  "spawn" ->
    shell = Shell.default_shell()
    shell_options = Shell.spawn_options(shell)

    opts = [
      shell: shell,
      args: shell_options[:args],
      cwd: System.fetch_env!("DALA_DATA_DIR"),
      env: [{"TERM", "xterm-256color"}, {"COLORTERM", "truecolor"}] ++ shell_options[:env],
      env_remove: ["TERM_PROGRAM", "WT_SESSION", "WT_PROFILE_ID"],
      rows: 24,
      cols: 100,
      history_lines: 1_000
    ]

    {:ok, socket, false} = Holder.attach_or_spawn(id, opts)
    _hello = receive_frame.(receive_frame, socket, Holder.type_hello())
    :ok = Holder.send_input(socket, "echo #{marker}\r")

    wait_for_marker = fn wait_for_marker, acc ->
      payload = receive_frame.(receive_frame, socket, Holder.type_output())
      output = acc <> payload

      if String.contains?(output, marker) do
        :ok
      else
        wait_for_marker.(wait_for_marker, output)
      end
    end

    :ok = wait_for_marker.(wait_for_marker, "")
    :gen_tcp.close(socket)
    File.write!(result_path, Jason.encode!(%{spawned: true}))

  "reattach" ->
    {:ok, socket, true} = Holder.attach_or_spawn(id, [])
    _hello = receive_frame.(receive_frame, socket, Holder.type_hello())
    :ok = Holder.send_text_snapshot_req(socket, 200, 65_536)
    snapshot = receive_frame.(receive_frame, socket, Holder.type_text_snapshot())
    true = String.contains?(snapshot, marker)
    File.write!(result_path, Jason.encode!(%{reattached: true, marker_preserved: true}))
    :ok = Holder.send_kill(socket)
    :gen_tcp.close(socket)
end
'@

try {
  New-Item -ItemType Directory -Force -Path $installRoot, $dataDir, (Join-Path $installRoot "versions") | Out-Null
  New-Item -ItemType Junction -Path $versionDir -Target $release | Out-Null
  Copy-Item -LiteralPath $releaseRunner -Destination $runner

  [IO.File]::WriteAllText((Join-Path $installRoot "current.txt"), "$tag`n", [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($helperFile, $helper, [Text.UTF8Encoding]::new($false))

  $config = @"
PHX_SERVER=true
PORT=$port
PHX_HOST=localhost
DALA_LISTEN_IP=127.0.0.1
PHX_CHECK_ORIGIN=false
DATABASE_PATH=$dataDir\dala.db
DALA_DATA_DIR=$dataDir
DALA_RELEASE_ROOT=$installRoot
DALA_SERVICE=DalaReleaseSmoke
RELEASE_NODE=$releaseNode
RELEASE_COOKIE=$releaseCookie
SECRET_KEY_BASE=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
TOKEN_SIGNING_SECRET=abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789
"@
  [IO.File]::WriteAllText($configFile, $config, [Text.UTF8Encoding]::new($false))

  $env:DALA_HOME = $installRoot
  $env:DALA_CONFIG = $configFile
  $env:PHX_SERVER = "true"
  $env:PORT = [string]$port
  $env:PHX_HOST = "localhost"
  $env:DALA_LISTEN_IP = "127.0.0.1"
  $env:PHX_CHECK_ORIGIN = "false"
  $env:DATABASE_PATH = Join-Path $dataDir "dala.db"
  $env:DALA_DATA_DIR = $dataDir
  $env:DALA_RELEASE_ROOT = $installRoot
  $env:DALA_SERVICE = "DalaReleaseSmoke"
  $env:RELEASE_NODE = $releaseNode
  $env:RELEASE_COOKIE = $releaseCookie
  $env:SECRET_KEY_BASE = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  $env:TOKEN_SIGNING_SECRET = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
  $env:DALA_SMOKE_ID = $sessionId
  $env:DALA_SMOKE_MARKER = $marker
  $env:DALA_SMOKE_RESULT = $resultFile
  $env:DALA_SMOKE_SCRIPT = $helperFile
  $env:DALA_SMOKE_PHASE = "spawn"

  $server = Start-Runner $taskLauncher $runner $logFile
  $status = Wait-Http $port

  $rpcExpression = "Code.eval_file(System.get_env(to_string(:DALA_SMOKE_SCRIPT)))"
  $spawnOutput = & $releaseBatch rpc $rpcExpression 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) { throw "holder spawn RPC failed: $spawnOutput" }

  $spawnResult = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
  if (-not $spawnResult.spawned) { throw "holder spawn result is missing" }

  $holder = Get-CimInstance Win32_Process -Filter "Name='dala_holder.exe'" |
    Where-Object { $_.CommandLine -like "*$sessionId*" } |
    Select-Object -First 1
  if (-not $holder) { throw "holder process was not found" }
  $holderPid = [uint32]$holder.ProcessId

  $beam = Find-SmokeBeam $installRoot $release
  if (-not $beam) { throw "release BEAM process was not found" }
  Assert-NoVisibleConsole ([uint32]$beam.ProcessId) $openConsolePidsBefore

  $stopOutput = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $restartHelper -StopOnly -StopExecutable $installedReleaseBatch 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) { throw "release stop helper failed: $stopOutput" }
  if (Find-SmokeBeam $installRoot $release) { throw "release stop helper left BEAM running" }
  $server.WaitForExit(10000) | Out-Null

  if (-not (Get-Process -Id $holderPid -ErrorAction SilentlyContinue)) {
    throw "holder died with the BEAM"
  }

  $env:DALA_SMOKE_PHASE = "reattach"
  $serverAfterRestart = Start-Runner $taskLauncher $runner $logFile
  $restartStatus = Wait-Http $port

  $beamAfterRestart = Find-SmokeBeam $installRoot $release
  if (-not $beamAfterRestart) { throw "restarted release BEAM process was not found" }
  Assert-NoVisibleConsole ([uint32]$beamAfterRestart.ProcessId) $openConsolePidsBefore

  if (-not (Get-Process -Id $holderPid -ErrorAction SilentlyContinue)) {
    throw "holder PID changed across the BEAM restart"
  }

  $reattachOutput = & $releaseBatch rpc $rpcExpression 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) { throw "holder reattach RPC failed: $reattachOutput" }

  $reattachResult = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json
  if (-not $reattachResult.reattached -or -not $reattachResult.marker_preserved) {
    throw "holder reattach marker assertion failed"
  }

  $uninstallRoot = Join-Path $smokeRoot "uninstall root"
  $uninstallData = Join-Path $uninstallRoot "data"
  $uninstallConfigRoot = Join-Path $smokeRoot "uninstall appdata"
  $uninstallConfig = Join-Path $uninstallConfigRoot "Dala"
  New-Item -ItemType Directory -Force -Path (Join-Path $uninstallRoot "versions\v0.0.0"), $uninstallData, $uninstallConfig | Out-Null
  [IO.File]::WriteAllText((Join-Path $uninstallRoot "current.txt"), "v0.0.0`n")
  [IO.File]::WriteAllText((Join-Path $uninstallRoot "run-dala.ps1"), "# smoke fixture`n")
  [IO.File]::WriteAllText((Join-Path $uninstallRoot ".dala-install"), "Dala installation root`n")
  [IO.File]::WriteAllText((Join-Path $uninstallData ".dala-data"), "Dala data directory`n")
  [IO.File]::WriteAllText((Join-Path $uninstallData "keep.txt"), "keep`n")
  [IO.File]::WriteAllText((Join-Path $uninstallConfig "dala.env"), "KEEP=true`n")

  $env:DALA_HOME = $uninstallRoot
  $env:DALA_DATA_DIR = $uninstallData
  $env:DALA_SERVICE = "DalaReleaseSmokeMissingTask"
  $env:APPDATA = $uninstallConfigRoot

  & $uninstall
  if ($LASTEXITCODE -ne 0) { throw "non-purge uninstall failed" }
  if (-not (Test-Path -LiteralPath (Join-Path $uninstallData "keep.txt"))) {
    throw "non-purge uninstall removed user data"
  }
  if (-not (Test-Path -LiteralPath (Join-Path $uninstallConfig "dala.env"))) {
    throw "non-purge uninstall removed configuration"
  }
  if (Test-Path -LiteralPath (Join-Path $uninstallRoot "versions")) {
    throw "non-purge uninstall kept installed versions"
  }
  if (Test-Path -LiteralPath (Join-Path $uninstallRoot "current.txt")) {
    throw "non-purge uninstall kept current.txt"
  }

  & $uninstall -PurgeData
  if ($LASTEXITCODE -ne 0) { throw "purge uninstall failed" }
  if ((Test-Path -LiteralPath $uninstallRoot) -or (Test-Path -LiteralPath $uninstallConfig)) {
    throw "purge uninstall kept data or configuration"
  }

  $invalidRoot = Join-Path $smokeRoot "invalid pointer root"
  New-Item -ItemType Directory -Force -Path $invalidRoot | Out-Null
  [IO.File]::WriteAllText((Join-Path $invalidRoot "current.txt"), "v0.0.0\..\outside`n")
  $env:DALA_HOME = $invalidRoot
  $env:DALA_CONFIG = $configFile
  $pointerRejected = $false
  try {
    & $releaseRunner
  } catch {
    if ($_.Exception.Message -notmatch "Invalid Dala version pointer") { throw }
    $pointerRejected = $true
  }
  if (-not $pointerRejected) { throw "invalid current.txt pointer was accepted" }

  $env:DALA_HOME = [IO.Path]::GetPathRoot($smokeRoot)
  $env:DALA_DATA_DIR = $dataDir
  $unsafeRootRejected = $false
  try {
    & $uninstall -PurgeData
  } catch {
    if ($_.Exception.Message -notmatch "Refusing to remove volume root") { throw }
    $unsafeRootRejected = $true
  }
  if (-not $unsafeRootRejected) { throw "volume-root uninstall target was accepted" }

  $unverifiedRoot = Join-Path $smokeRoot "unverified custom root"
  New-Item -ItemType Directory -Force -Path $unverifiedRoot | Out-Null
  [IO.File]::WriteAllText((Join-Path $unverifiedRoot "keep.txt"), "must survive`n")
  $env:DALA_HOME = $unverifiedRoot
  $unverifiedRejected = $false
  try {
    & $uninstall -PurgeData
  } catch {
    if ($_.Exception.Message -notmatch "unverified DALA_HOME") { throw }
    $unverifiedRejected = $true
  }
  if (-not $unverifiedRejected) { throw "unverified custom uninstall root was accepted" }
  if (-not (Test-Path -LiteralPath (Join-Path $unverifiedRoot "keep.txt"))) {
    throw "unverified custom uninstall root was modified"
  }

  $summary = [pscustomobject]@{
    http_status = $status
    restart_http_status = $restartStatus
    holder_pid = $holderPid
    reattached = [bool]$reattachResult.reattached
    marker_preserved = [bool]$reattachResult.marker_preserved
    visible_console_absent = $true
    uninstall_preserved_data = $true
    purge_removed_data = $true
    invalid_pointer_rejected = $pointerRejected
    unsafe_root_rejected = $unsafeRootRejected
    unverified_custom_root_rejected = $unverifiedRejected
  }
} finally {
  $beamProcesses = @(Get-CimInstance Win32_Process -Filter "Name='erl.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      $_.CommandLine -like "*$installRoot*" -or $_.CommandLine -like "*$release*"
    })
  foreach ($beamProcess in $beamProcesses) {
    Stop-Process -Id $beamProcess.ProcessId -Force -ErrorAction SilentlyContinue
    Wait-Process -Id $beamProcess.ProcessId -Timeout 10 -ErrorAction SilentlyContinue
  }

  if ($server -and -not $server.HasExited) {
    Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    $server.WaitForExit(10000) | Out-Null
  }
  if ($serverAfterRestart -and -not $serverAfterRestart.HasExited) {
    Stop-Process -Id $serverAfterRestart.Id -Force -ErrorAction SilentlyContinue
    $serverAfterRestart.WaitForExit(10000) | Out-Null
  }
  if ($holderPid) {
    Stop-Process -Id $holderPid -Force -ErrorAction SilentlyContinue
    Wait-Process -Id $holderPid -Timeout 10 -ErrorAction SilentlyContinue
  }

  for ($attempt = 0; $attempt -lt 20 -and (Test-Path -LiteralPath $smokeRoot); $attempt++) {
    Remove-Item -LiteralPath $smokeRoot -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $smokeRoot) { Start-Sleep -Milliseconds 100 }
  }
  if (Test-Path -LiteralPath $smokeRoot) { throw "could not clean smoke root: $smokeRoot" }
}

$summary | ConvertTo-Json -Compress

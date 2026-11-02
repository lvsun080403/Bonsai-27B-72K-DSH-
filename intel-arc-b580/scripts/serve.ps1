# serve.ps1 - local llama.cpp server manager for Intel Arc (Vulkan) on Windows.
#
# Contract shared with the DSH "local model toggle" plugin:
#   * file name is scripts\serve.ps1
#   * the context argument is -Context <tokens>  (not -Ctx)
#   * $Port has a default value; the plugin reads it to match a DSH provider
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\serve.ps1
#   powershell ... -File scripts\serve.ps1 -Status
#   powershell ... -File scripts\serve.ps1 -Stop
[CmdletBinding()]
param(
    [int]$Port = 18080,
    [int]$Context = 16384,
    [string]$Model = '',
    [string]$BinDir = '',
    [string]$KeyFile = '',
    [switch]$Status,
    [switch]$Stop,
    [switch]$Foreground,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'

$Here   = Split-Path -Parent $PSScriptRoot
$RunDir = Join-Path $Here 'run'
$PidFile = Join-Path $RunDir 'server.pid'
$LogOut  = Join-Path $RunDir 'server.out.log'
$LogErr  = Join-Path $RunDir 'server.err.log'

function Say([string]$m) { Write-Host "[serve] $m" }

function Resolve-BinDir {
    if ($BinDir) {
        if (Test-Path (Join-Path $BinDir 'llama-server.exe')) { return (Resolve-Path $BinDir).Path }
        throw "llama-server.exe not found in -BinDir '$BinDir'"
    }
    $pkg = Join-Path $Here 'bin'
    if (Test-Path (Join-Path $pkg 'llama-server.exe')) { return $pkg }
    $hit = Get-ChildItem -Path $Here -Recurse -File -Filter 'llama-server.exe' -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if ($hit) { return $hit.Directory.FullName }
    throw "llama-server.exe not found. Put the Vulkan build in <package>\bin\ or pass -BinDir."
}

function Resolve-Model {
    if ($Model) {
        if (Test-Path $Model) { return (Resolve-Path $Model).Path }
        throw "model not found: $Model"
    }
    $pkg = Join-Path $Here 'model'
    if (Test-Path $pkg) {
        $f = Get-ChildItem -Path $pkg -Filter '*.gguf' -File -ErrorAction SilentlyContinue |
             Sort-Object Length -Descending | Select-Object -First 1
        if ($f) { return $f.FullName }
    }
    $hit = Get-ChildItem -Path $Here -Recurse -File -Filter '*.gguf' -ErrorAction SilentlyContinue |
           Sort-Object Length -Descending | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    throw "no *.gguf found. Put the model in <package>\model\ or pass -Model."
}

function Get-RunningPid {
    if (-not (Test-Path $PidFile)) { return $null }
    $raw = (Get-Content $PidFile -Raw).Trim()
    if (-not $raw) { return $null }
    $p = Get-Process -Id ([int]$raw) -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -like 'llama-server*') { return $p }
    return $null
}

function Test-Health([int]$p) {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$p/health" -TimeoutSec 2 -UseBasicParsing
        return ($r.Content -match '"ok"')
    } catch { return $false }
}

if (-not (Test-Path $RunDir)) { New-Item -ItemType Directory -Force -Path $RunDir | Out-Null }

# ---------------------------------------------------------------- Stop
if ($Stop) {
    $p = Get-RunningPid
    if (-not $p) { Say 'not running'; exit 0 }
    Say "stopping pid $($p.Id)"
    & taskkill /F /T /PID $p.Id | Out-Null
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    Say 'stopped'
    exit 0
}

# ---------------------------------------------------------------- Status
if ($Status) {
    $p = Get-RunningPid
    if (-not $p) { Say 'not running'; exit 1 }
    $ok = Test-Health $Port
    Say ("pid={0} port={1} health={2}" -f $p.Id, $Port, ($(if ($ok) { 'ok' } else { 'down' })))
    if ($ok) {
        try {
            $models = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/v1/models" -TimeoutSec 3 -UseBasicParsing
            Say ("models: " + $models.Content)
        } catch { }
    }
    exit 0
}

# ---------------------------------------------------------------- Start
$existing = Get-RunningPid
if ($existing) {
    Say "already running (pid $($existing.Id)); use -Stop first"
    if (-not $Foreground) { exit 0 }
}

$bin   = Resolve-BinDir
$model = Resolve-Model
$exe   = Join-Path $bin 'llama-server.exe'

$cliArgs = @(
    '-m', $model,
    '-ngl', '99',
    '-c', "$Context",
    '-ctk', 'q8_0',
    '-ctv', 'q8_0',
    '-np', '1',
    '--host', '127.0.0.1',
    '--port', "$Port"
)

if ($KeyFile -and (Test-Path $KeyFile)) {
    $key = ((Get-Content $KeyFile -Raw) -replace "`r?`n", '').Trim()
    if ($key) { $cliArgs += @('--api-key', $key) }
} else {
    $defaultKeyFile = Join-Path $Here 'api-key.txt'
    if (Test-Path $defaultKeyFile) {
        $key = ((Get-Content $defaultKeyFile -Raw) -replace "`r?`n", '').Trim()
        if ($key) { $cliArgs += @('--api-key', $key) }
    }
}

Say "bin   = $exe"
Say "model = $model"
Say "port  = $Port  ctx = $Context"

if ($Foreground) {
    & $exe @cliArgs
    exit $LASTEXITCODE
}

$argStr = ($cliArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
$proc = Start-Process -FilePath $exe -ArgumentList $argStr -WorkingDirectory $bin `
        -RedirectStandardOutput $LogOut -RedirectStandardError $LogErr `
        -WindowStyle Hidden -PassThru
Set-Content -Path $PidFile -Value $proc.Id -NoNewline -Encoding ASCII
Say "started pid $($proc.Id), waiting for /health ..."

$deadline = (Get-Date).AddSeconds(180)
while ((Get-Date) -lt $deadline) {
    if ($proc.HasExited) {
        Say "engine exited with code $($proc.ExitCode); see run\server.err.log"
        Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
        exit 1
    }
    if (Test-Health $Port) {
        Say "ready: http://127.0.0.1:$Port  (base url for DSH: http://127.0.0.1:$Port/v1)"
        exit 0
    }
    Start-Sleep -Milliseconds 1500
}

Say 'timed out waiting for /health; the engine is still running, check run\server.err.log'
exit 1

# Bonsai 27B / 72K 上下文 本地服务管理脚本
# 由 start.bat / stop.bat / status.bat 调用，也可以直接用 powershell 跑。
[CmdletBinding()]
param(
    [int]$Port = 18200,
    [int]$Context = 73728,
    [int]$Reserve = 4096,
    [int]$HostMiB = 2048,
    [int]$Sessions = 2,
    [switch]$Background,
    [switch]$Foreground,
    [switch]$Status,
    [switch]$Stop,
    [switch]$NoBrowser,
    [switch]$AllowDevFallback   # 仅开发机：允许用 D:\1\Deepseek\kvmem 下的包外文件
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# ---------------------------------------------------------------- 路径解析
# 优先用包内 engine\ 与 model\（一键部署后的形态）；找不到再退回本机绝对路径，
# 这样同一个包既能"装好即用"，也能直接指向已有的引擎和权重（省一次 10 GB 复制）。
$Here    = Split-Path -Parent $PSScriptRoot          # 包根目录
$RunDir  = Join-Path $Here 'run'
$PidFile = Join-Path $RunDir 'host.pid'
$CfgFile = Join-Path $RunDir 'config.json'
$LogOut  = Join-Path $RunDir 'server.out.log'
$LogErr  = Join-Path $RunDir 'server.err.log'
$Launch  = Join-Path $RunDir 'launch.ps1'

# 只认包内文件。以前这里有两个开发机的绝对路径兜底，结果是"点 start.bat 明明没装也能跑起来"，
# 让人误以为包是自包含的 —— 已删除，改成显式 -AllowDevFallback 才启用。
$EngineRoot = $null
$pkgEngine  = Join-Path $Here 'engine'
# 包内引擎：允许 zip 自带一层目录（engine\kvmem-xxx\scripts\windows\start-ninfer.ps1）
if (Test-Path $pkgEngine) {
    $starter = Get-ChildItem -Path $pkgEngine -Recurse -File -Filter 'start-ninfer.ps1' -ErrorAction SilentlyContinue |
               Select-Object -First 1
    if ($starter) { $EngineRoot = $starter.Directory.Parent.Parent.FullName }
}
$ModelPath = $null
$pkgModelDir = Join-Path $Here 'model'
if (Test-Path $pkgModelDir) {
    $f = Get-ChildItem -Path $pkgModelDir -Filter '*.ninfer' -File -ErrorAction SilentlyContinue |
         Sort-Object Length -Descending | Select-Object -First 1
    if ($f) { $ModelPath = $f.FullName }
}

# 开发机专用兜底：显式 -AllowDevFallback 才用，且会大声警告
if ($AllowDevFallback) {
    if (-not $EngineRoot -and (Test-Path 'D:\1\Deepseek\kvmem\infer-sm120a')) {
        $EngineRoot = 'D:\1\Deepseek\kvmem\infer-sm120a\kvmem-v0.18.0-ninfer-windows-rtx50-sm120a'
    }
    if (-not $ModelPath -and (Test-Path 'D:\1\Deepseek\kvmem\pan\Ternary-Bonsai-2-27B-ninfer-v3.ninfer')) {
        $ModelPath = 'D:\1\Deepseek\kvmem\pan\Ternary-Bonsai-2-27B-ninfer-v3.ninfer'
    }
    if ($EngineRoot -or $ModelPath) {
        Warn "用的是包外文件（-AllowDevFallback）：engine=$EngineRoot model=$ModelPath"
    }
}

# API Key：包根目录的 api-key.txt（纯 ASCII、无 BOM 最好），没有就不校验
$KeyFile = Join-Path $Here 'api-key.txt'
$ApiKey = ''
if (Test-Path $KeyFile) {
    try { $ApiKey = ((Get-Content $KeyFile -Raw -Encoding UTF8) -replace "`r?`n", '').Trim() } catch { $ApiKey = '' }
}

if (-not (Test-Path $RunDir)) { New-Item -ItemType Directory -Force -Path $RunDir | Out-Null }

function Info($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok  ($m) { Write-Host "[+] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Die ($m) { Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

# 原生程序统一走这个壳：避免 $ErrorActionPreference='Stop' 把 stderr 当成终止错误
function Invoke-Native([string]$Exe, [string[]]$NativeArgs) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = (& $Exe @NativeArgs 2>&1 | Out-String)
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
        [pscustomobject]@{ Code = $code; Out = "$out" }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Get-Health {
    $r = Invoke-Native 'curl.exe' @('-s', '--noproxy', '*', '-o', 'NUL', '-w', '%{http_code}',
                                    '-m', '2', "http://127.0.0.1:$Port/health")
    return ("$($r.Out)").Trim()
}

function Get-PortPid {
    $r = Invoke-Native 'netstat.exe' @('-ano', '-p', 'TCP')
    foreach ($line in ($r.Out -split "`r?`n")) {
        if ($line -match 'LISTENING' -and $line -match ":$Port\s") {
            $cols = ($line -split '\s+') | Where-Object { $_ }
            return ($cols[-1]).Trim()
        }
    }
    return ''
}

function Get-EnginePid {
$r = Invoke-Native 'tasklist.exe' @('/FI', 'IMAGENAME eq ninfer-kvmem-server.exe', '/FO', 'CSV', '/NH')
    foreach ($line in ($r.Out -split "`r?`n")) {
if ($line -match 'ninfer-kvmem-server\.exe","(\d+)"') { return $Matches[1] }
    }
    return ''
}

function Get-WorkerArgs {
    $wk = @('--no-cuda-graph', '--fast-prefill-kernel', '--draft-tokens', '2', '--prefill-chunk', '512')
    if ($ApiKey) { $wk += @('--api-key', $ApiKey) }
    return $wk
}

function Show-Status {
    $h = Get-Health
    $pp = Get-PortPid
    $ep = Get-EnginePid
    $ctx = if (Test-Path $CfgFile) { (Get-Content $CfgFile -Raw -Encoding UTF8 | ConvertFrom-Json).context } else { $Context }
    Write-Host ''
    Write-Host '  Bonsai 27B · 本地服务状态' -ForegroundColor White
    Write-Host '  --------------------------------------------'
    if ($h -eq '200') {
        Write-Host "  状态      : 运行中" -ForegroundColor Green
        Write-Host "  地址      : http://127.0.0.1:$Port/v1"
        Write-Host "  模型名    : bonsai2-27b"
        Write-Host "  上下文    : $ctx tokens"
        if ($ApiKey) {
            $mask = if ($ApiKey.Length -gt 12) { $ApiKey.Substring(0, 8) + '…' + $ApiKey.Substring($ApiKey.Length - 4) } else { '***' }
            Write-Host "  API Key   : $mask（来自 api-key.txt）"
        } else {
            Write-Host "  API Key   : 未设置（仅回环访问）"
        }
        if ($ep) { Write-Host "  引擎 PID  : $ep" }
        if ($pp) { Write-Host "  端口 PID  : $pp" }
    } else {
        Write-Host "  状态      : 未运行（/health 返回 $h）" -ForegroundColor DarkGray
        if ($ep) { Write-Host "  注意      : 发现残留引擎进程 PID $ep，可执行 stop.bat 清理" -ForegroundColor Yellow }
    }
    if (Test-Path $LogErr) {
        $tail = @(Get-Content $LogErr -Tail 1 -Encoding UTF8 -ErrorAction SilentlyContinue)
        if ($tail.Count -gt 0 -and "$($tail[0])".Trim()) { Write-Host ("  日志末行  : " + "$($tail[0])".Trim()) -ForegroundColor DarkGray }
    }
    Write-Host ''
}

function Kill-Pid([string]$Id) {
    if (-not ($Id -match '^\d+$')) { return $false }
    $r = Invoke-Native 'taskkill.exe' @('/PID', $Id, '/T', '/F')
    if ($r.Code -eq 0) { return $true }
    # 受限环境里 taskkill 可能被拒绝（Access denied），退回 .NET 的 Stop-Process
    try {
        Stop-Process -Id ([int]$Id) -Force -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Stop-Engine {
    $wasRunning = (((Get-PortPid) -ne '') -or ((Get-EnginePid) -ne ''))
    $killed = @()

    if (Test-Path $PidFile) {
        $hostPid = (Get-Content $PidFile -Raw).Trim()
        if (Kill-Pid $hostPid) { $killed += "host $hostPid" }
        Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    }
    $pp = Get-PortPid
    if ($pp) { if (Kill-Pid $pp) { $killed += "port $pp" } }
    $ep = Get-EnginePid
    if ($ep) { if (Kill-Pid $ep) { $killed += "engine $ep" } }

    if ($killed.Count -gt 0) { Ok ('已停止: ' + ($killed -join ', ')) }
    elseif ($wasRunning) { Warn '检测到服务在跑，但没权限结束它（用管理员身份运行 stop.bat）' }
    else { Ok '本来就没有在运行' }
}
function Start-Engine {
    if (-not $EngineRoot -or -not (Test-Path $EngineRoot)) { Die "找不到引擎（包内 engine\ 目录是空的）。`n    先双击 install.bat 部署，或把引擎解压到本目录的 engine\ 下。" }
    if (-not $ModelPath -or -not (Test-Path $ModelPath)) { Die "找不到模型（包内 model\ 目录是空的）。`n    先双击 install.bat 部署，或把 .ninfer 放到本目录的 model\ 下。" }
    # 引擎 exe 的位置在版本间有差异，按名字递归找最稳
    $exe = Get-ChildItem -Path $EngineRoot -Recurse -File -Filter '*kvmem-server.exe' -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if (-not $exe) { Die "在 $EngineRoot 下找不到 *kvmem-server.exe" }

    $budget = $Context - $Reserve
    if ($budget -lt 8192) { Die "上下文太小：Budget=$budget（sink 8192 + recent 1024 至少要 9216）" }

    # WorkerArgs 的字面量：写进生成的 launch.ps1，避免 -File 传参把数组拼成逗号串
    $wkLiteral = (@(Get-WorkerArgs) | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', '

    $body = @"
& '$EngineRoot\scripts\windows\start-ninfer.ps1' -Model '$ModelPath' -Gpu 0 ``
    -Context $Context -HostMiB $HostMiB -Budget $budget -Reserve $Reserve ``
    -SinkTokens 8192 -KvType rk4v4 -NoVision -MtpDrafts 2 -RetainedSessions $Sessions ``
    -Port $Port ``
    -WorkerArgs @($wkLiteral)
"@
    [IO.File]::WriteAllText($Launch, $body, (New-Object Text.UTF8Encoding($true)))

    $cfg = [pscustomobject]@{
        port = $Port; context = $Context; budget = $budget; reserve = $Reserve
        hostMiB = $HostMiB; sessions = $Sessions; kvType = 'rk4v4'
        model = $ModelPath; engine = $EngineRoot; apiKey = $(if ($ApiKey) { 'set' } else { '' })
    }
    [IO.File]::WriteAllText($CfgFile, ($cfg | ConvertTo-Json), (New-Object Text.UTF8Encoding($true)))

    Info '拉起引擎（首次加载约 5–10 秒）…'
    $p = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Launch) `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $LogOut -RedirectStandardError $LogErr
    [IO.File]::WriteAllText($PidFile, "$($p.Id)", (New-Object Text.UTF8Encoding($false)))

    $ok = $false
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 800
        if ((Get-Health) -eq '200') { $ok = $true; break }
        if ($p.HasExited) { break }
    }

    if (-not $ok) {
        Warn "引擎没有在 48 秒内就绪。最后几行日志："
        if (Test-Path $LogErr) { Get-Content $LogErr -Tail 12 -Encoding UTF8 | ForEach-Object { "    $_" } }
        Die '启动失败。常见原因：显存被占用（先关掉别的模型）、参数越界、驱动不支持 sm_120a。'
    }

    Ok '就绪'
    Write-Host ''
    Write-Host "  Base URL : http://127.0.0.1:$Port/v1"
    Write-Host "  模型名   : bonsai2-27b"
    Write-Host "  上下文   : $Context tokens"
    if ($ApiKey) { Write-Host "  API Key  : 已启用（见 api-key.txt）" } else { Write-Host "  API Key  : 未设置" }
    Write-Host "  Web UI   : http://127.0.0.1:$Port"
    Write-Host "  日志     : $LogErr"
    Write-Host ''
    if (-not $NoBrowser) { Start-Process "http://127.0.0.1:$Port" | Out-Null }
}

if ($Status) { Show-Status; exit 0 }
if ($Stop)   { Stop-Engine; exit 0 }

if ($Foreground) {
    Info '前台模式：关掉这个窗口就会停止服务'
    $wk = Get-WorkerArgs
    & (Join-Path $EngineRoot 'scripts\windows\start-ninfer.ps1') -Model $ModelPath -Gpu 0 `
        -Context $Context -HostMiB $HostMiB -Budget ($Context - $Reserve) -Reserve $Reserve `
        -SinkTokens 8192 -KvType rk4v4 -NoVision -MtpDrafts 2 -RetainedSessions $Sessions `
        -Port $Port `
        -WorkerArgs $wk
    exit $LASTEXITCODE
}

if ((Get-Health) -eq '200') {
    Ok "已经在运行：http://127.0.0.1:$Port/v1"
    Show-Status
    exit 0
}

Start-Engine
Show-Status

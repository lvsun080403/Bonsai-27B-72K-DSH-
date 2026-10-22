# Bonsai 27B · 72K 一键部署脚本（从零开始）
# 由 install.bat 调用。做四件事：查环境 → 下引擎 + 权重 → 校验 → 拉起服务。
[CmdletBinding()]
param(
    [int]$Port = 18200,
    [string]$Proxy = '',   # 留空 = 安装时自动测速选最快的镜像；指定则强制用它
    [string]$HfMirror = 'https://hf-mirror.com',
    [string]$EngineZipPath = '',      # 已有引擎 zip 时直接用它（跳过下载）
    [string]$ModelFilePath = '',      # 已有 .ninfer 时直接用它（跳过下载）
    [switch]$SkipDownload,            # 只解压/校验，不下载
    [switch]$NoStart,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$Here = Split-Path -Parent $PSScriptRoot
$EngineDir = Join-Path $Here 'engine'
$ModelDir  = Join-Path $Here 'model'
$DownDir   = Join-Path $Here 'download'
$KeyFile   = Join-Path $Here 'api-key.txt'
$RunDir    = Join-Path $Here 'run'

$EngineZipName = 'kvmem-v0.18.0-ninfer-windows-rtx50-sm120a.zip'
$GithubEngineUrl = "https://github.com/kvmem/kvmem/releases/download/v0.18.0/$EngineZipName"
$EngineZipUrl  = "${Proxy}$GithubEngineUrl"   # 显式 -Proxy 时的地址；不指定则安装时自动测速挑最快的
$EngineZipSha  = 'F893DC9053CB27EF8CDBC32687C6BB29346D5829D5EB2272A58DDEF7B6DBDF7D'
$EngineZipSize = 900767487

$ModelFileName = 'Ternary-Bonsai-2-27B-ninfer-v3.ninfer'
$ModelUrl      = "$HfMirror/WaveCut/Ternary-Bonsai-2-27B-NInfer-v3/resolve/main/$ModelFileName"
$ModelSha      = 'CDC4810B0FF17C40D0F62CF214B6E0BCD08346E9EB05CA53371507037793C14A'
$ModelSize     = 9520051456

$DefaultKey = 'sk-171212e1b4a08d12xh2131234356647yu'

function Info($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok  ($m) { Write-Host "[+] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Die ($m) { Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

function Invoke-Native([string]$Exe, [string[]]$NativeArgs) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = (& $Exe @NativeArgs 2>&1 | Out-String)
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 0 }
        [pscustomobject]@{ Code = $code; Out = "$out" }
    } finally { $ErrorActionPreference = $prev }
}

function Format-GB([double]$bytes) { '{0:N1} GB' -f ($bytes / 1GB) }

# 把外部已有的大文件搬进包里：同盘用硬链接（瞬间完成、不占额外空间），跨盘才复制
function Link-Or-Copy([string]$Src, [string]$Dst) {
    if (Test-Path $Dst) { return }
    $parent = Split-Path -Parent $Dst
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $sameVolume = ([IO.Path]::GetPathRoot($Src)) -eq ([IO.Path]::GetPathRoot($Dst))
    if ($sameVolume) {
        $r = Invoke-Native 'cmd.exe' @('/c', 'mklink', '/H', "`"$Dst`"", "`"$Src`"")
        if ($r.Code -eq 0) { return }
    }
    Copy-Item -Path $Src -Destination $Dst -Force
}

# ---------------------------------------------------------------- 下载进度条
# curl 自带的 --progress-bar 写在 stderr，被 Invoke-Native 吞掉后屏幕上什么都不显示，
# 所以这里自己盯文件大小画进度：解析大小、速度、剩余时间，并支持断点续传。
function Format-Size([double]$bytes) {
    if ($bytes -ge 1GB) { return ('{0:N2} GB' -f ($bytes / 1GB)) }
    if ($bytes -ge 1MB) { return ('{0:N1} MB' -f ($bytes / 1MB)) }
    if ($bytes -ge 1KB) { return ('{0:N0} KB' -f ($bytes / 1KB)) }
    return ('{0:N0} B' -f $bytes)
}

function Format-Dur([double]$sec) {
    if ($sec -lt 0 -or [double]::IsNaN($sec) -or [double]::IsInfinity($sec)) { return '--:--' }
    if ($sec -gt 86400) { return '>1 天' }
    $s = [long][math]::Round($sec)   # 必须用 long：859MB / 0.3 B/s 的秒数会超过 Int32 上限
    if ($s -ge 3600) { return ('{0}:{1:00}:{2:00}' -f [int]($s / 3600), [int](($s % 3600) / 60), ($s % 60)) }
    return ('{0:00}:{1:00}' -f [int]($s / 60), ($s % 60))
}

function Invoke-Download([string]$Url, [string]$Dest, [int64]$Expected, [string]$Label) {
    $dir = Split-Path -Parent $Dest
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $redirected = $false
    try { $redirected = [Console]::IsOutputRedirected } catch { }
    $barWidth = 28
    $useResume = $true
    $code = 0
    $errText = ''
    $total = 0.0
    $final = 0

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        if ($attempt -eq 2) {
            Warn '这个地址不支持断点续传，从头重新下一次…'
            Remove-Item $Dest -Force -ErrorAction SilentlyContinue
            $useResume = $false
        }

        $curlArgs = @('-L', '--fail', '-sS', '--ssl-no-revoke', '--retry', '5', '--retry-delay', '3', '--connect-timeout', '20')
        if ($useResume) { $curlArgs += @('-C', '-') }
        $curlArgs += @('-o', $Dest, $Url)

        # 用 .NET Process 而不是 Start-Process：后者拿到的 ExitCode 常是 $null，
        # 会把"下完了"误判成失败（这个坑在 qwen-deploy 上踩过一次）。
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = 'curl.exe'
        $psi.Arguments = (($curlArgs | ForEach-Object { if ("$_" -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' ')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardOutput = $true
        $proc = New-Object Diagnostics.Process
        $proc.StartInfo = $psi

        $lastTick = 0.0
        $lastBucket = 0
        $lastBytes = if (Test-Path $Dest) { (Get-Item $Dest).Length } else { 0 }
        $speed = 0.0
        $stalled = $false
        $lastGrowAt = 0.0
        $sw = [Diagnostics.Stopwatch]::StartNew()
        [void]$proc.Start()

        # 先打一行 0%，让用户立刻看到"已经在下了"，而不是干等
        if ($Expected -gt 0) {
            if ($redirected) {
                Write-Host ('  [{0}] {1,6:N1}%  {2} / {3}  启动中…' -f ('-' * $barWidth), 0, (Format-Size 0), (Format-Size $Expected))
            } else {
                $w0 = 100
                try { $cw0 = [Console]::WindowWidth; if ($cw0 -gt 20) { $w0 = $cw0 - 2 } } catch { }
                [Console]::Write("`r" + (('  [{0}] {1,6:N1}%  {2} / {3}  启动中…' -f ('-' * $barWidth), 0, (Format-Size 0), (Format-Size $Expected)).PadRight($w0)))
            }
        }

        while (-not $proc.HasExited) {
            Start-Sleep -Milliseconds 800
            $cur = 0
            if (Test-Path $Dest) { try { $cur = (Get-Item $Dest).Length } catch { $cur = 0 } }
            $now = $sw.Elapsed.TotalSeconds
            $dt = $now - $lastTick
            if ($dt -ge 0.8) {
                $inst = ($cur - $lastBytes) / $dt
                if ($inst -lt 0) { $inst = 0 }
                $speed = if ($speed -le 0) { $inst } else { $speed * 0.6 + $inst * 0.4 }
                $lastTick = $now
                if ($cur -gt $lastBytes) { $lastGrowAt = $now }
                $lastBytes = $cur
            }

            if (($now - $lastGrowAt) -gt 45) {
                try { $proc.Kill() } catch { }
                $stalled = $true
                break
            }

            if ($Expected -gt 0) {
                $pct = [math]::Min(100.0, ($cur / $Expected) * 100.0)
                $filled = [int][math]::Floor($barWidth * $pct / 100.0)
                if ($filled -lt 0) { $filled = 0 }
                if ($filled -gt $barWidth) { $filled = $barWidth }
                $bar = ('#' * $filled) + ('-' * ($barWidth - $filled))
                $etaSec = if ($speed -gt 4096) { ($Expected - $cur) / $speed } else { -1 }
                if ($speed -lt 20480) { $etaSec = -1 }
                $line = '  [{0}] {1,6:N1}%  {2} / {3}  {4}/s  剩 {5}' -f `
                        $bar, $pct, (Format-Size $cur), (Format-Size $Expected), (Format-Size $speed), (Format-Dur $etaSec)
                $bucket = [int][math]::Floor($pct / 10.0)
            } else {
                $line = '  已下载 {0}  {1}/s' -f (Format-Size $cur), (Format-Size $speed)
                $bucket = [int][math]::Floor($now / 5.0)
            }

            if ($redirected) {
                # 输出被重定向（管道/日志）时不能原地刷新，改成每 10% 打一行
                if ($bucket -ne $lastBucket) {
                    $lastBucket = $bucket
                    Write-Host $line
                }
            } else {
                $width = 100
                try { $cw = [Console]::WindowWidth; if ($cw -gt 20) { $width = $cw - 2 } } catch { }
                $text = $line
                if ($text.Length -gt $width) { $text = $text.Substring(0, $width) }
                [Console]::Write("`r" + $text.PadRight($width))
            }
        }

        $proc.WaitForExit()
        $code = $proc.ExitCode
        if ($stalled) {
            $code = -2
            if (-not $redirected) { Write-Host '' }
            Warn '下载卡住了：45 秒没有任何增长，已中断。换个源重跑，例如  install.bat -Proxy https://gh-proxy.com/'
        }
        try { if ($proc.StandardError) { $errText = "$($proc.StandardError.ReadToEnd())".Trim() } } catch { }
        try { if ($proc.StandardOutput) { $null = $proc.StandardOutput.ReadToEnd() } } catch { }

        if (-not $redirected) {
            try { $width = [Console]::WindowWidth - 2; [Console]::Write("`r" + (' ' * $width) + "`r") } catch { Write-Host '' }
        }

        $total = $sw.Elapsed.TotalSeconds
        $final = if (Test-Path $Dest) { (Get-Item $Dest).Length } else { 0 }

        if ($code -eq 33 -and $useResume) {
            # 文件本来就已经完整时 curl 会返回 33（416），别当成失败去重下 9 GB
            if ($Expected -gt 0 -and (Test-Path $Dest) -and (Get-Item $Dest).Length -eq $Expected) {
                Write-Host '  （文件本来就已经完整，跳过下载）' -ForegroundColor DarkGray
                $code = 0
            } else { continue }
        }
        break
    }

    if ($code -eq -2) { return [pscustomobject]@{ Ok = $false; Code = -2; Err = 'stalled' } }
    $avg = if ($total -gt 0) { $final / $total } else { 0 }
    if ($code -eq 0) {
        Ok ("{0} 完成：{1}，用时 {2}，平均 {3}/s" -f $Label, (Format-Size $final), (Format-Dur $total), (Format-Size $avg))
    }

    return [pscustomobject]@{ Ok = ($code -eq 0); Code = $code; Err = "$errText".Trim() }
}

# 依次尝试多个源：测速给出的顺序，卡住/失败自动换下一个（双击 install.bat 也能自己跑通）
function Invoke-DownloadFromMirrors([object[]]$Sources, [string]$Dest, [int64]$Expected, [string]$Label) {
    $last = $null
    $i = 0
    foreach ($s in $Sources) {
        $i++
        Info ('[{0}/{1}] 源：{2}' -f $i, $Sources.Count, $s.Name)
        $r = Invoke-Download -Url $s.Url -Dest $Dest -Expected $Expected -Label $Label
        if ($r.Ok) { return $r }
        $last = $r
        if ($i -lt $Sources.Count) { Warn ('这个源不行（exit {0}），换下一个…' -f $r.Code) }
    }
    return $last
}

# ---------------------------------------------------------------- 0. 环境自检
Write-Host ''
Write-Host '  Bonsai 27B · 72K 一键部署' -ForegroundColor White
Write-Host '  ============================================' -ForegroundColor DarkGray

Info '检查运行环境…'

if (-not [Environment]::Is64BitOperatingSystem) { Die '需要 64 位 Windows' }
$win = [Environment]::OSVersion.Version
if ($win.Major -lt 10) { Die "需要 Windows 10 或更高版本（当前 $win）" }
Ok "Windows $($win.Major).$($win.Minor) 64 位"

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { Die '找不到 curl.exe（Windows 10 1803+ 自带）。请升级系统或手动装 curl。' }
Ok 'curl.exe 可用'

if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) { Warn '没有 tar.exe，将退回 Expand-Archive（慢一些）' }

# 显卡：必须能认出 NVIDIA GPU，且 compute capability = 12.0（RTX 50 系）
$smi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
if (-not $smi) { $smiPath = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'; if (Test-Path $smiPath) { $smi = $smiPath } }
if (-not $smi) { Die '没找到 nvidia-smi.exe：请先装 NVIDIA 显卡驱动（RTX 50 系需要较新的版本）。' }
$q = Invoke-Native 'nvidia-smi.exe' @('--query-gpu=name,compute_cap,memory.total', '--format=csv,noheader')
if ($q.Code -ne 0 -or -not $q.Out.Trim()) { Die "nvidia-smi 查询失败：$($q.Out.Trim())" }
$gpuLine = ($q.Out -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1
Ok "显卡：$($gpuLine.Trim())"
if ($gpuLine -notmatch '12\.0') {
    Warn "这台机器的 compute capability 不是 12.0（RTX 50 系 / Blackwell）。"
    Warn '本包里的引擎是 rtx50-sm120a 构建，40 系要用 rtx40-sm89 包，30 系用 rtx30-sm86。'
    Die '为避免装完跑不起来，先停下。需要我换一版引擎包请联系作者。'
}

# 内存：host KV 2 GiB + 引擎自身约 2.2 GB，14 GB 以下会很紧张
# 注意：某些受限环境里 WMI/CIM 会被拒绝，这里只做"能读到就提醒"，读不到就跳过
$ramGB = 0
foreach ($probe in @(
    { [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1) },
    { [math]::Round((Get-WmiObject -Class Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1) }
)) {
    try { $v = & $probe; if ($v) { $ramGB = $v; break } } catch { }
}
if ($ramGB) {
    Ok "内存：$ramGB GB"
    if ($ramGB -lt 14) { Warn "内存偏小（$ramGB GB）。本包按 2 GiB host KV 配置，14 GB 以下可能启动失败。" }
} else {
    Warn '读不到物理内存大小（WMI 被拒绝），跳过内存检查'
}

# 磁盘：引擎 0.9 + 解压 1.7 + 权重 9.5 + 余量
$need = 22GB
try {
    $drive = (Get-Item $Here).PSDrive
    $free = $drive.Free
    if ($free -and $free -lt $need) { Die ("磁盘空间不足：" + (Format-GB $free) + " 可用，至少需要 " + (Format-GB $need)) }
    if ($free) { Ok "磁盘可用：" + (Format-GB $free) }
} catch { }

# VC++ 运行库：引擎是 MSVC 编译的，裸机常缺
$sys32 = Join-Path $env:SystemRoot 'System32'
$needVc = @('vcruntime140.dll', 'msvcp140.dll') | Where-Object { -not (Test-Path (Join-Path $sys32 $_)) }
if ($needVc) {
    Warn "缺 VC++ 运行库：$($needVc -join ', ')"
    if ($DryRun) { Warn '[DryRun] 否则会下载并安装 vc_redist.x64.exe' }
    else {
        $vc = Join-Path $env:TEMP 'vc_redist.x64.exe'
        Info '下载 VC++ 2015-2022 x64 运行库（约 25 MB）…'
        $r = Invoke-Download -Url 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -Dest $vc -Expected 0 -Label 'VC++ 运行库'
        if (-not $r.Ok -or -not (Test-Path $vc)) { Die "下载 VC++ 运行库失败（curl exit $($r.Code)）。手动装：https://aka.ms/vs/17/release/vc_redist.x64.exe" }
        Info '安装（会弹一次 UAC）…'
        $p = Start-Process -FilePath $vc -ArgumentList '/install', '/quiet', '/norestart' -Verb RunAs -Wait -PassThru
        if ($p.ExitCode -notin @(0, 1638, 3010)) { Die "VC++ 运行库安装失败（exit $($p.ExitCode)）" }
        Ok 'VC++ 运行库已安装'
    }
} else { Ok 'VC++ 运行库已就位' }

# ---------------------------------------------------------------- 镜像速度探测
# GitHub release 在国内时快时慢，所以每次安装先抽 3 MB 测一圈，选当下最快的一个。
function Select-FastestProxy([string]$githubUrl) {
    $cands = @(
        @{ Name = '直连';    Prefix = '' },
        @{ Name = 'gh-proxy.com'; Prefix = 'https://gh-proxy.com/' },
        @{ Name = 'ghfast.top';   Prefix = 'https://ghfast.top/' },
        @{ Name = 'gh-proxy.net'; Prefix = 'https://gh-proxy.net/' },
        @{ Name = 'ghproxy.net';  Prefix = 'https://ghproxy.net/' },
        @{ Name = 'gh.llkk.cc';   Prefix = 'https://gh.llkk.cc/' },
        @{ Name = 'moeyy.xyz';    Prefix = 'https://github.moeyy.xyz/' },
        @{ Name = 'gitmirror';    Prefix = 'https://hub.gitmirror.com/' }
    )
    $probeBytes = 3145728
    $best = $null
    $rows = @()
    foreach ($c in $cands) {
        $url = "$($c.Prefix)$githubUrl"
        $r = Invoke-Native 'curl.exe' @('-sL', '--fail', '--ssl-no-revoke', '--max-time', '6', '-r', "0-$($probeBytes - 1)",
                                        '-o', 'NUL', '-w', '%{speed_download}', $url)
        $spd = 0.0
        if ($r.Code -eq 0) { [void][double]::TryParse("$($r.Out)".Trim(), [ref]$spd) }
        $rows += [pscustomobject]@{ Name = $c.Name; Prefix = $c.Prefix; Speed = $spd; Code = $r.Code }
        if ($spd -gt 0 -and ($null -eq $best -or $spd -gt $best.Speed)) { $best = $rows[-1] }
    }

    foreach ($row in ($rows | Sort-Object -Property Speed -Descending)) {
        $shown = if ($row.Speed -gt 0) {
                     '{0,7:N2} MB/s' -f ($row.Speed / 1MB)
                 } elseif ($row.Code -eq 35) {
                     '   TLS失败(35)'
                 } elseif ($row.Code -ne 0) {
                     '   失败(' + $row.Code + ')'
                 } else { '       0 B/s' }
        $mark = if ($best -and $row.Name -eq $best.Name) { '  <- 选它' } else { '' }
        Write-Host ('    {0,-14} {1}{2}' -f $row.Name, $shown, $mark)
    }
    return $best
}

# ---------------------------------------------------------------- 1. 引擎
if (-not (Test-Path $DownDir)) { if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $DownDir | Out-Null } }
$engineZip = Join-Path $DownDir $EngineZipName
$exePath   = Join-Path $EngineDir 'workers\ninfer\ninfer-kvmem-server.exe'

Write-Host ''
if (Test-Path $exePath) {
    Ok "引擎已存在：$EngineDir"
} else {
    Info "准备引擎：$EngineZipName（$(Format-GB $EngineZipSize)）"
    if ($DryRun) {
        Warn "[DryRun] 会从 $EngineZipUrl 下载到 $engineZip"
        Warn "[DryRun] 校验 SHA256 = $($EngineZipSha.Substring(0,16))…，解压到 $EngineDir"
    } else {
        if ($EngineZipPath) {
            if (-not (Test-Path $EngineZipPath)) { Die "指定的引擎 zip 不存在：$EngineZipPath" }
            Link-Or-Copy $EngineZipPath $engineZip
            Ok "已把本地引擎包放入 download\：$engineZip"
        }
        if ((Test-Path $engineZip) -and (Get-Item $engineZip).Length -eq $EngineZipSize) {
            Ok '引擎包已在 download\ 目录，跳过下载'
        } elseif (-not $SkipDownload) {
            # 组装候选源：显式 -Proxy 就只用它；否则按测速排序，测速失败的也留着兜底
            $sources = @()
            if ($Proxy) {
                $sources = @([pscustomobject]@{ Name = '你指定的源'; Url = "$Proxy$GithubEngineUrl" })
            } else {
                Info '测一下几个 GitHub 镜像的速度（每个抽 3 MB，最多约 1 分钟）…'
                $probed = @(Select-FastestProxy $GithubEngineUrl)
                $fast = @($probed | Where-Object { $_.Speed -gt 0 } | Sort-Object Speed -Descending)
                $slow = @($probed | Where-Object { $_.Speed -le 0 })
                # 直连放到最后：它常常"开头很快、几 MB 后就断流"，不适合当首选
                $ordered = @($fast | Where-Object { $_.Prefix -ne '' }) + @($slow | Where-Object { $_.Prefix -ne '' }) + @([pscustomobject]@{ Name = '直连'; Prefix = ''; Speed = 0 })
                foreach ($c in $ordered) {
                    $nm = if ($c.Prefix) { "$($c.Name) $($c.Prefix)" } else { '直连 github.com' }
                    if ($c.Speed -gt 0) { $nm = $nm + ('（测速 {0:N2} MB/s）' -f ($c.Speed / 1MB)) }
                    $sources += [pscustomobject]@{ Name = $nm; Url = "$($c.Prefix)$GithubEngineUrl" }
                }
            }

            Info '下载中（断了重跑本脚本会续传；卡住会自动换源）…'
            $r = Invoke-DownloadFromMirrors $sources $engineZip $EngineZipSize '引擎包'
            if (-not $r -or -not $r.Ok) {
                $code = if ($r) { $r.Code } else { -1 }
                $tail = if ($r -and $r.Err) { "`n    curl: $($r.Err)" } else { '' }
                Die "所有源都失败了（最后 exit $code）。可以换手机热点后重跑，或用 -Proxy 指定一个能用的镜像（例如 https://gh-proxy.com/）。$tail"
            }
        } else { Die "找不到引擎包：$engineZip" }

        $size = (Get-Item $engineZip).Length
        if ($size -ne $EngineZipSize) { Die "引擎包大小不对：$size / $EngineZipSize" }
        Info '校验 SHA256…'
        $sha = (Get-FileHash $engineZip -Algorithm SHA256).Hash
        if ($sha -ne $EngineZipSha) { Die "引擎包校验失败：$sha" }
        Ok '引擎包校验通过'

        Info '解压…'
        if (Test-Path $EngineDir) { Remove-Item $EngineDir -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $EngineDir | Out-Null
        if (Get-Command tar.exe -ErrorAction SilentlyContinue) {
            $t = Invoke-Native 'tar.exe' @('-xf', $engineZip, '-C', $EngineDir)
            if ($t.Code -ne 0) { Expand-Archive -Path $engineZip -DestinationPath $EngineDir -Force }
        } else {
            Expand-Archive -Path $engineZip -DestinationPath $EngineDir -Force
        }
        if (-not (Test-Path $exePath)) {
            # zip 自带一层 kvmem-v0.18.0-xxx\，把它拍平到 engine\
            $inner = Get-ChildItem $EngineDir -Recurse -File -Filter '*kvmem-server.exe' -ErrorAction SilentlyContinue |
                     Select-Object -First 1
            if ($inner) {
                $root = $inner.Directory.Parent.Parent   # ...\kvmem-xxx\workers\ninfer\x.exe
                if ($root -and (Test-Path (Join-Path $root 'workers'))) {
                    $sub = Join-Path $EngineDir ('_unpack_' + [guid]::NewGuid().ToString('N').Substring(0,8))
                    Move-Item $root.FullName $sub -Force
                    Get-ChildItem $sub -Force | ForEach-Object { Move-Item $_.FullName $EngineDir -Force }
                    Remove-Item $sub -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
        if (-not (Test-Path $exePath)) {
            $any = Get-ChildItem $EngineDir -Recurse -File -Filter '*kvmem-server.exe' -ErrorAction SilentlyContinue |
                   Select-Object -First 1
            if ($any) { $exePath = $any.FullName } else { Die '解压后仍找不到引擎可执行文件（包结构可能变了）' }
        }
        Ok "引擎 exe：$exePath"
        Ok '引擎就位'
    }
}

# ---------------------------------------------------------------- 2. 权重
Write-Host ''
$modelPath = Join-Path $ModelDir $ModelFileName
$modelNew = $false
if ($ModelFilePath -and -not $DryRun) {
    if (-not (Test-Path $ModelFilePath)) { Die "指定的权重文件不存在：$ModelFilePath" }
    if (-not (Test-Path $modelPath)) { Link-Or-Copy $ModelFilePath $modelPath; $modelNew = $true }
    Ok "已把本地权重放入 model\：$modelPath"
}
$existing = if (Test-Path $modelPath) { Get-Item $modelPath } else { $null }

if ($existing -and $existing.Length -eq $ModelSize) {
    if ($modelNew) {
        Info '校验 SHA256（9.5 GB，约 30–60 秒）…'
        $sha0 = (Get-FileHash $modelPath -Algorithm SHA256).Hash
        if ($sha0 -ne $ModelSha) {
            Remove-Item $modelPath -Force -ErrorAction SilentlyContinue
            Die "权重校验失败：$sha0"
        }
        Ok '权重校验通过'
    } else {
        Ok "权重已存在且大小正确：$modelPath（跳过重复校验）"
    }
} else {
    Info "准备权重：$ModelFileName（$(Format-GB $ModelSize)）"
    if ($DryRun) {
        Warn "[DryRun] 会从 $ModelUrl 下载到 $modelPath"
        Warn "[DryRun] 校验 SHA256 = $($ModelSha.Substring(0,16))…"
    } else {
        if ($true) {
            New-Item -ItemType Directory -Force -Path $ModelDir | Out-Null
            if ($SkipDownload) {
                Die "找不到权重：$modelPath"
            } elseif ((Test-Path $modelPath) -and (Get-Item $modelPath).Length -eq $ModelSize) {
                Ok ('权重已在 model\ 目录（{0}），跳过下载' -f (Format-Size $ModelSize))
            } else {
                Info '下载中（9.5 GB，断了重跑会续传；卡住会自动换源）…'
                $mSources = @(
                    [pscustomobject]@{ Name = "HF 镜像 $HfMirror"; Url = $ModelUrl }
                )
                if ($HfMirror -ne 'https://hf-mirror.com') {
                    $mSources += [pscustomobject]@{ Name = 'HF 镜像 hf-mirror.com'; Url = "https://hf-mirror.com/WaveCut/Ternary-Bonsai-2-27B-NInfer-v3/resolve/main/$ModelFileName" }
                }
                $mSources += [pscustomobject]@{ Name = 'HuggingFace 官方'; Url = "https://huggingface.co/WaveCut/Ternary-Bonsai-2-27B-NInfer-v3/resolve/main/$ModelFileName" }
                $r = Invoke-DownloadFromMirrors $mSources $modelPath $ModelSize '权重'
                if (-not $r -or -not $r.Ok) {
                    $code = if ($r) { $r.Code } else { -1 }
                    $tail = if ($r -and $r.Err) { "`n    curl: $($r.Err)" } else { '' }
                    Die "所有源都失败了（最后 exit $code）。重跑 install.bat 会续传；也可以下好 gguf 后用 -ModelFilePath 指给脚本。$tail"
                }
            }
        }

        $size = (Get-Item $modelPath).Length
        if ($size -ne $ModelSize) { Die "权重大小不对：$size / $ModelSize" }
        Info '校验 SHA256（9.5 GB，约 30 秒）…'
        $sha = (Get-FileHash $modelPath -Algorithm SHA256).Hash
        if ($sha -ne $ModelSha) { Die "权重校验失败：$sha" }
        Ok '权重校验通过'
    }
}

# ---------------------------------------------------------------- 3. API Key
Write-Host ''
if (-not (Test-Path $KeyFile)) {
    if ($DryRun) { Warn "[DryRun] 会写入 api-key.txt：$DefaultKey" }
    else {
        [IO.File]::WriteAllText($KeyFile, $DefaultKey, (New-Object Text.UTF8Encoding($false)))
        Ok "已写入 api-key.txt（默认密钥）"
    }
} else {
    $k = ((Get-Content $KeyFile -Raw -Encoding UTF8) -replace "`r?`n", '').Trim()
    if ($k) { Ok "api-key.txt 已存在（$($k.Substring(0, [Math]::Min(8, $k.Length)))…）" }
    else { Warn 'api-key.txt 是空的，服务将不做密钥校验' }
}

# ---------------------------------------------------------------- 4. 起服务
Write-Host ''
if ($DryRun) {
    Warn '[DryRun] 到此为止，没有下载、没有解压、没有启动。'
    exit 0
}
if ($NoStart) { Ok '部署完成（按要求没有启动）。双击 start.bat 可以启动。'; exit 0 }

Info '启动服务…'
& (Join-Path $PSScriptRoot 'serve.ps1') -Port $Port -Background -NoBrowser
if ($LASTEXITCODE -ne 0) { Die '启动失败，看上面输出的日志。' }

Write-Host ''
Ok '完成。'
Write-Host "  地址   : http://127.0.0.1:$Port/v1"
Write-Host "  模型名 : bonsai2-27b"
Write-Host "  密钥   : 见 api-key.txt"
Write-Host "  停止   : stop.bat    状态：status.bat"
Write-Host ''

#!/usr/bin/env pwsh
# wsh.ps1 —— Windows 目标的 ssh 外壳（Windows / PowerShell 版）
#
# 用法：
#   wsh <host>                      # 交互登录
#   wsh <host> '<代码>'              # 用「远端默认 shell」执行（多行也行）
#   wsh -f <host> <本地脚本>         # 执行本地脚本文件
#   wsh -f <host> -                 # 从 stdin 读脚本
#   wsh --shell cmd <host> '<cmd>'   # 强制用 cmd.exe 执行（pwsh/ps5 同理）
#   wsh --shell ps5 <host> '<代码>'   # 强制用 Windows PowerShell 5.1 执行
#   wsh kind <host>                  # 查看缓存的默认解释器（--reset 重探）
#   wsh --direct <host> '<代码>'      # 强制一次性 ssh（默认走 sess）
#
# 解释器：auto（默认）= 远端默认 shell；pwsh = PowerShell 7+；ps5 = 5.1；cmd = cmd.exe。
#   首次用到某台主机时探测一次并存到 <缓存>/wsh/<host>.shell，之后零开销；
#   换了 DefaultShell 用 `wsh kind --reset <host>` 重探。
#   跨解释器走 `pwsh.exe|powershell.exe -NoProfile -EncodedCommand <UTF-16LE base64>`。
#   默认 shell 已是 PowerShell 时脚本 base64 后 `& ([scriptblock]::Create(...))`，不嵌套子进程。
#   默认 shell 是 PowerShell 时 cmd 命令被包成 `& cmd.exe /d /c '...'`（单引号自动加倍）；
#   默认是 cmd 时原样发送（含双引号的命令请改用 --shell pwsh/ps5）。
#
# 默认走 sess 常驻会话（远端 pwsh 启动 400ms 只付一次）；--direct 是干净的一次性 ssh。
# 远端默认 shell 是 cmd 时 sess 不可用，自动回落一次性 ssh。
#
# 与 POSIX 版 wsh 的差异：不需要 iconv（.NET 直接做 UTF-16LE 编码）；本地无 ssh-agent 自愈。
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$lib = Join-Path $PSScriptRoot 'sshkit-lib.ps1'
if (-not (Test-Path -LiteralPath $lib)) {
    [Console]::Error.WriteLine("wsh: 缺 $lib（请把 sshkit-lib.ps1 与 wsh.ps1 放在同一目录）")
    exit 2
}
. $lib
Initialize-ShkConsole

# 远端输出必须无条件 UTF-8：Windows 的默认输出码页是 437/936，中文在 437 下
# 会被编码成 '?'（CI 实测：ssh 通道上收到 3f 3f）。pwsh 7 也**不**自动用 UTF-8。
$PROLOGUE = @'
$ProgressPreference="SilentlyContinue"
$ErrorActionPreference="Continue"
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch {}
try { $OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch {}
try { if ($PSVersionTable.PSVersion.Major -ge 7) { $PSStyle.OutputRendering = "PlainText" } } catch {}
'@

$EPILOGUE = @'
$__ok = $?
$__code = $LASTEXITCODE
if (-not $__ok) {
    if ($__code -is [int] -and $__code -ne 0) { exit $__code }
    exit 1
}
exit 0
'@

$PS5_ENC = 'try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false; $OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch {}'

function Show-WshHelp {
    $n = 0
    foreach ($l in (Get-Content -LiteralPath $PSCommandPath)) {
        $n++
        if ($n -eq 1) { continue }
        if ($l -match '^# ?') { $l.Substring(1).TrimStart() }
        elseif ($l -notmatch '^#') { break }
    }
}

function Test-ShkNonAscii([string]$Text) {
    return ($Text -match '[^\x00-\x7F]')
}

function ConvertTo-CmdFlatten([string]$Text) {
    # cmd /c 只认第一条命令行：多行脚本折叠成 `a & b`
    $parts = @()
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line.Trim() -ne '') { $parts += $line }
    }
    return ($parts -join ' & ')
}

function New-PsWrapCmd([string]$Text) {
    $t = ConvertTo-CmdFlatten $Text
    if (Test-ShkNonAscii $t) { $t = 'chcp 65001>nul & ' + $t }
    $esc = $t.Replace("'", "''")
    return "& cmd.exe /d /c '$esc'"
}

function New-ScriptBlockExpr([string]$Text) {
    $b = ConvertTo-ShkB64 $Text
    return "& ([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$b'))))"
}

function New-EncodedCommand([string]$Exe, [string]$Text) {
    $b = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Text))
    return "$Exe -NoProfile -EncodedCommand $b"
}

function Get-WshShellCacheFile([string]$HostName) {
    $d = Get-ShkCache 'wsh'
    return (Join-Path $d ($HostName + '.shell'))
}

function Get-WshRemoteShellKind([string]$HostName) {
    $sf = Get-WshShellCacheFile $HostName
    if (Test-Path -LiteralPath $sf) {
        $k = (Get-Content -LiteralPath $sf -Raw).Trim()
        if ($k -in @('pwsh', 'ps5', 'cmd')) { return $k }
    }
    $r = Start-ShkProcess -File 'ssh' -ArgList @('-T', '-o', 'ConnectTimeout=10', $HostName,
        '$PSVersionTable.PSVersion.Major') -Capture -TimeoutSec 40
    $ver = ([string]$r.Out).Trim()
    if ($r.Code -eq 0 -and $ver -match '^7') {
        $k = 'pwsh'
    } elseif ($r.Code -eq 0 -and $ver -match '^[2345]') {
        $k = 'ps5'
    } else {
        $r2 = Start-ShkProcess -File 'ssh' -ArgList @('-T', '-o', 'ConnectTimeout=10', $HostName,
            'echo WSH_CMD_OK') -Capture -TimeoutSec 40
        if ($r2.Code -eq 0 -and ([string]$r2.Out).Contains('WSH_CMD_OK')) { $k = 'cmd' }
        else { return $null }
    }
    Set-Content -LiteralPath $sf -Value $k -Encoding ascii
    return $k
}

# ---- 参数 ----
$mode = 'arg'
$useSess = ($env:WSH_DIRECT -ne '1')
$shellSel = 'auto'
$i = 0
$a = @($args)
$parsing = $true
while ($i -lt $a.Count -and $parsing) {
    $x = [string]$a[$i]
    if ($x -eq '--') { $i++; break }
    elseif ($x -eq '-f') { $mode = 'file'; $i++ }
    elseif ($x -eq '-S' -or $x -eq '--sess') { $useSess = $true; $i++ }
    elseif ($x -eq '--direct' -or $x -eq '--no-sess') { $useSess = $false; $i++ }
    elseif ($x -eq '--shell') {
        if ($i + 1 -ge $a.Count) { [Console]::Error.WriteLine('wsh: --shell 需要参数（auto|pwsh|ps5|cmd）'); exit 2 }
        $shellSel = [string]$a[$i + 1]; $i += 2
    }
    elseif ($x.StartsWith('--shell=')) { $shellSel = $x.Substring(8); $i++ }
    elseif ($x -eq '--pwsh' -or $x -eq '--ps7') { $shellSel = 'pwsh'; $i++ }
    elseif ($x -eq '--ps5' -or $x -eq '--powershell') { $shellSel = 'ps5'; $i++ }
    elseif ($x -eq '--cmd') { $shellSel = 'cmd'; $i++ }
    elseif ($x -eq '-h' -or $x -eq '--help') { Show-WshHelp; exit 0 }
    elseif ($x.StartsWith('-')) { [Console]::Error.WriteLine("wsh: 未知选项 $x"); exit 2 }
    else { $parsing = $false }
}

switch -CaseSensitive ($shellSel) {
    'auto' { }
    'pwsh' { }
    'ps5' { }
    'cmd' { }
    'ps7' { $shellSel = 'pwsh' }
    'pwsh7' { $shellSel = 'pwsh' }
    '7' { $shellSel = 'pwsh' }
    'powershell' { $shellSel = 'ps5' }
    'powershell5' { $shellSel = 'ps5' }
    'ps51' { $shellSel = 'ps5' }
    '5' { $shellSel = 'ps5' }
    'cmd.exe' { $shellSel = 'cmd' }
    default {
        [Console]::Error.WriteLine("wsh: --shell 只接受 auto|pwsh|ps5|cmd（收到 $shellSel）")
        exit 2
    }
}

if ($i -lt $a.Count -and [string]$a[$i] -eq 'kind') {
    $i++
    $reset = $false
    if ($i -lt $a.Count -and [string]$a[$i] -eq '--reset') { $reset = $true; $i++ }
    if ($i -ge $a.Count) { [Console]::Error.WriteLine('wsh: kind 需要主机名'); exit 2 }
    $h = [string]$a[$i]
    if ($reset) { Remove-Item -LiteralPath (Get-WshShellCacheFile $h) -Force -ErrorAction SilentlyContinue }
    $k = Get-WshRemoteShellKind $h
    if ($null -eq $k) {
        [Console]::Error.WriteLine("wsh: 无法判断 $h 的默认 shell")
        exit 3
    }
    [Console]::Out.WriteLine($k)
    exit 0
}

if ($i -ge $a.Count) { Show-WshHelp; exit 2 }
$hostName = [string]$a[$i]
$i++
$body = $null

if ($mode -eq 'file') {
    if ($i -ge $a.Count) { [Console]::Error.WriteLine('wsh: -f 需要脚本路径（用 - 表示 stdin）'); exit 2 }
    $src = [string]$a[$i]
    if ($src -eq '-') {
        $bytes = Read-ShkStdinAll
    } else {
        if (-not (Test-Path -LiteralPath $src)) { [Console]::Error.WriteLine("wsh: 读不到 $src"); exit 2 }
        $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $src).ProviderPath)
    }
    $body = [Text.Encoding]::UTF8.GetString($bytes)
} elseif ($i -ge $a.Count) {
    # 交互
    exit (Start-ShkProcess -File 'ssh' -ArgList @('-t', $hostName) -Interactive)
} else {
    $body = ($a[$i..($a.Count - 1)] -join ' ')
}

Trace-ShkSess "wsh: detecting shell for $hostName"
$defKind = Get-WshRemoteShellKind $hostName
Trace-ShkSess "wsh: defKind=$defKind"
if ($null -eq $defKind) {
    [Console]::Error.WriteLine("wsh: 无法判断 $hostName 的默认 shell（既不是 PowerShell 也不是 cmd）")
    [Console]::Error.WriteLine("     可显式指定：wsh --shell cmd|pwsh|ps5 $hostName '<命令>'")
    exit 3
}
if ($shellSel -eq 'auto') { $target = $defKind } else { $target = $shellSel }

$runRaw = $false
$psCode = ''

switch ($target) {
    'cmd' {
        if ($defKind -eq 'cmd') { $runRaw = $true }
        else { $psCode = New-PsWrapCmd $body }
    }
    'pwsh' {
        if ($defKind -eq 'pwsh') { $psCode = $body }
        else { $psCode = New-EncodedCommand 'pwsh.exe' (($PROLOGUE.Trim()) + "`n" + $body) }
    }
    'ps5' {
        if ($defKind -eq 'ps5') { $psCode = ($PS5_ENC + "`n" + $body) }
        else { $psCode = New-EncodedCommand 'powershell.exe' (($PROLOGUE.Trim()) + "`n" + $body) }
    }
}

# 远端默认 shell 是 cmd 时，keeper 的常驻 loop（PowerShell）根本起不来
# （--shell pwsh 强制跨解释器也一样），只能一次性 ssh。
if ($defKind -eq 'cmd' -and $useSess) {
    [Console]::Error.WriteLine('wsh: 远端默认 shell 是 cmd，sess 协议不支持，回落一次性 ssh')
    $useSess = $false
}

if ($useSess -and $psCode -ne '') {
    exit (Invoke-ShkSessRun -HostName $hostName -Script $psCode)
}

if ($defKind -eq 'cmd') {
    # 远端登录 shell 是 cmd：只能交一条单行命令行给它。
    # 目标 cmd → 用户命令本身；目标 pwsh/ps5 → `xxx.exe -NoProfile -EncodedCommand <b64>`。
    if ($runRaw) { $raw = ConvertTo-CmdFlatten $body } else { $raw = $psCode }
    if (Test-ShkNonAscii $raw) { $raw = 'chcp 65001>nul & ' + $raw }
    if ($raw.Contains('"')) {
        [Console]::Error.WriteLine('wsh: 这条命令含双引号，而远端默认 shell 是 cmd；PowerShell 5.1 传原生参数会破坏它。')
        [Console]::Error.WriteLine('     改用：wsh --shell pwsh|ps5 ' + $hostName + " '<命令>'（或把命令写进 .cmd 再执行）")
        exit 2
    }
    exit (Start-ShkProcess -File 'ssh' -ArgList @('-T', $hostName, $raw))
}

$script = (($PROLOGUE.Trim()) + "`n" + $psCode + "`n" + ($EPILOGUE.Trim()))
exit (Start-ShkProcess -File 'ssh' -ArgList @('-T', $hostName, (New-ScriptBlockExpr $script)))

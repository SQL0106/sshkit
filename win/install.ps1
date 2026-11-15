#!/usr/bin/env pwsh
# install.ps1 —— 把 sshkit 的 PowerShell 版装进 Windows
#
#   pwsh -NoProfile -File win/install.ps1            # 装到 %LOCALAPPDATA%\sshkit
#   pwsh -NoProfile -File win/install.ps1 -NoPath    # 不改用户 PATH
#   pwsh -NoProfile -File win/install.ps1 -NoProfile # 不写 PowerShell profile
#   pwsh -NoProfile -File win/install.ps1 -WhatIf    # 只打印将要做什么
#
# 装三样东西：
#   1) 脚本本体 → <root>\win\{rsh,wsh,sess}.ps1 + sshkit-lib.ps1
#   2) cmd.exe 入口 → <root>\bin\{rsh,wsh,sess}.cmd（给不用 PowerShell 的调用方）
#   3) PowerShell 函数 → profile 里的 rsh/wsh/sess（推荐入口：不经 cmd，参数原样传递）
#
# 幂等：重复执行只覆盖自己的文件，profile 段落用标记包住、重装时整段替换。
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Dest = '',
    [switch]$NoPath,
    [switch]$NoProfile
)

$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot

function Get-DefaultRoot {
    if ($env:LOCALAPPDATA) { return (Join-Path $env:LOCALAPPDATA 'sshkit') }
    return (Join-Path $HOME '.local/share/sshkit')
}

if (-not $Dest) { $Dest = Get-DefaultRoot }
$winDir = Join-Path $Dest 'win'
$binDir = Join-Path $Dest 'bin'

$files = @('rsh.ps1', 'wsh.ps1', 'sess.ps1', 'sshkit-lib.ps1')
foreach ($f in $files) {
    if (-not (Test-Path -LiteralPath (Join-Path $src $f))) {
        [Console]::Error.WriteLine("install: 缺 $f（请从仓库的 win/ 目录运行）")
        exit 2
    }
}

if ($PSCmdlet.ShouldProcess($winDir, '复制脚本')) {
    New-Item -ItemType Directory -Force -Path $winDir | Out-Null
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    foreach ($f in $files) { Copy-Item -LiteralPath (Join-Path $src $f) -Destination (Join-Path $winDir $f) -Force }
    # 预编译的原生入口（库里带的 dist\sshkit.exe；没有就用 .cmd 入口）
    $exeSrc = Join-Path $src 'dist\sshkit.exe'
    if (Test-Path -LiteralPath $exeSrc) {
        Copy-Item -LiteralPath $exeSrc -Destination (Join-Path $binDir 'sshkit.exe') -Force
        [Console]::Out.WriteLine("已装原生入口: $(Join-Path $binDir 'sshkit.exe')")
    }
}

# ---- cmd.exe 入口 --------------------------------------------------------
$psExe = 'pwsh'
if ($PSVersionTable.PSVersion.Major -lt 6) { $psExe = 'powershell' } else {
    $cand = Join-Path $PSHOME 'pwsh.exe'
    if (Test-Path -LiteralPath $cand) { $psExe = '"' + $cand + '"' }
}
# 注意：%* 是 cmd 的原样转发，能保住引号；但 cmd 自己先解析了一遍重定向/管道。
# 复杂命令请用 PowerShell 函数入口，或 `pwsh -File rsh.ps1 ...`。
$shim = @(
    '@echo off',
    'rem sshkit 入口（cmd.exe）：复杂引号/多行命令请改用 PowerShell 里的 rsh 函数',
    "$psExe -NoProfile -ExecutionPolicy Bypass -File `"$winDir\rsh.ps1`" %*"
) -join "`r`n"

if ($PSCmdlet.ShouldProcess($binDir, '写 cmd 入口')) {
    foreach ($n in @('rsh', 'wsh', 'sess')) {
        $body = $shim.Replace('rsh.ps1', "$n.ps1")
        Set-Content -LiteralPath (Join-Path $binDir "$n.cmd") -Value $body -Encoding ascii
    }
}

# ---- 用户 PATH -----------------------------------------------------------
if (-not $NoPath) {
    $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $cur) { $cur = '' }
    $parts = @($cur -split ';' | Where-Object { $_ -ne '' })
    if ($parts -notcontains $binDir) {
        if ($PSCmdlet.ShouldProcess('用户 PATH', "加入 $binDir")) {
            $new = (@($parts) + $binDir) -join ';'
            [Environment]::SetEnvironmentVariable('Path', $new, 'User')
            [Console]::Out.WriteLine("已把 $binDir 加入用户 PATH（新开的终端生效）")
        }
    } else {
        [Console]::Out.WriteLine("用户 PATH 已包含 $binDir")
    }
}

# ---- PowerShell profile --------------------------------------------------
if (-not $NoProfile) {
    $profiles = @()
    try { if ($PROFILE.CurrentUserAllHosts) { $profiles += $PROFILE.CurrentUserAllHosts } } catch { }
    foreach ($p in $profiles) {
        if ($PSCmdlet.ShouldProcess($p, '写 rsh/wsh/sess 函数')) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
            $old = ''
            if (Test-Path -LiteralPath $p) { $old = [System.IO.File]::ReadAllText($p) }
            $old = [regex]::Replace($old, '(?s)# >>> sshkit >>>.*?# <<< sshkit <<<\r?\n?', '')
            $block = @(
                '# >>> sshkit >>>',
                '# 由 sshkit 的 install.ps1 生成；重装会整段替换，不要手改',
                '# 远程输出是 UTF-8：捕获输出时按 UTF-8 解码，中文才不乱码',
                'try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }',
                "function rsh { & `"$(Join-Path $winDir 'rsh.ps1')`" @args }",
                "function wsh { & `"$(Join-Path $winDir 'wsh.ps1')`" @args }",
                "function sess { & `"$(Join-Path $winDir 'sess.ps1')`" @args }",
                '# <<< sshkit <<<',
                ''
            ) -join "`r`n"
            [System.IO.File]::WriteAllText($p, $old.TrimEnd() + "`r`n`r`n" + $block)
            [Console]::Out.WriteLine("已写 profile: $p")
        }
    }
}

@'
装好了。新开一个终端后：

  rsh linux-host 'uname -a'         # POSIX 目标（单条命令）
  rsh --sess linux-host 'pwd'       # 需要保留 cd/变量时
  wsh win-host '$PSVersionTable'    # Windows 目标（默认走 sess）
  sess list / sess stop <host>      # 查看/关闭常驻会话

还需要两件外部准备（sshkit 不代劳）：
  1) ssh 客户端与主机别名：Windows 自带 OpenSSH Client；把别名写进 %USERPROFILE%\.ssh\config
  2) 私钥口令：Windows 用的是 ssh-agent 服务，需要时执行
       Get-Service ssh-agent | Set-Service -StartupType Automatic
       Start-Service ssh-agent
       ssh-add $env:USERPROFILE\.ssh\id_ed25519
  注意：Windows OpenSSH 客户端不支持 ControlMaster，复用连接靠 sess。

Windows 自带的 rsh.exe（Remote Shell，老协议）与本工具同名：在 PowerShell 里
函数优先；在 cmd.exe 里 `rsh` 会命中 PATH 更靠前的那个 —— 想确保用本工具就写
`%LOCALAPPDATA%\sshkit\bin\rsh.cmd` 或用完整路径。
'@ | Write-Output

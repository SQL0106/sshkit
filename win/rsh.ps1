#!/usr/bin/env pwsh
# rsh.ps1 —— POSIX 目标（Linux / macOS / Android）的 ssh 外壳（Windows / PowerShell 版）
#
# 用法：
#   rsh <host>                   # 交互登录（强制落到 bash -l）
#   rsh <host> <cmd> [args...]   # 直接执行；远端用 bash 解析
#   rsh -f <host> <本地脚本>      # 把脚本从 stdin 喂给远端 bash -s（零转义）
#   rsh -f <host> -              # 从 stdin 读脚本
#   rsh -s <host> <单条命令>      # 用 sudo -n 执行；复合命令（; && |）报错，请改用 -f
#   rsh -n <host> ...            # native：用远端登录 shell 自己执行（不改 shell）
#   rsh --sess <host> <cmd>      # 走常驻会话：cd/变量/函数跨命令保留
#   rsh --sess -f <host> <脚本>   # 同上，脚本整段送进常驻会话
#
# 与 POSIX 版 rsh 的差异（Windows 客户端）：
#   * 命令不拼进 ssh 的 argv：本地 base64 → 远端 `mktemp` 临时脚本 → 执行 → 删除。
#     这样 ssh 收到的参数里没有引号字符，PowerShell 5.1 的原生参数转义咬不到它，
#     同时 stdin 仍然属于用户命令（`echo x | rsh host 'cat'` 照常工作）。
#   * 不做远端 ssh-agent 自愈前导（那套是 Linux 客户端间的约定）；仍前置 ~/.local/bin。
#   * 不实现 droidspaces 容器包装（-C / -c / -R）；需要时用容器自己的 sshd 别名。
#   * 远端没有 bash 时退回 sh。
#
# 退出码原样透传；stdout/stderr 字节级直通（子进程继承句柄，不做编码转换）。
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$lib = Join-Path $PSScriptRoot 'sshkit-lib.ps1'
if (-not (Test-Path -LiteralPath $lib)) {
    [Console]::Error.WriteLine("rsh: 缺 $lib（请把 sshkit-lib.ps1 与 rsh.ps1 放在同一目录）")
    exit 2
}
. $lib
Initialize-ShkConsole

function Show-RshHelp {
    $n = 0
    foreach ($l in (Get-Content -LiteralPath $PSCommandPath)) {
        $n++
        if ($n -eq 1) { continue }
        if ($l -match '^# ?') { $l.Substring(1).TrimStart() }
        elseif ($l -notmatch '^#') { break }
    }
}

# ---- 参数（手工解析：PowerShell 的参数绑定会吞掉 -s / -f 这类开关）----
$mode = 'exec'
$sudoRun = $false
$native = $false
$useSess = $false
$i = 0
$a = @($args)
$parsing = $true
while ($i -lt $a.Count -and $parsing) {
    $x = [string]$a[$i]
    if ($x -eq '--') { $i++; break }
    elseif ($x -eq '-f') { $mode = 'file'; $i++ }
    elseif ($x -eq '-s') { $sudoRun = $true; $i++ }
    elseif ($x -eq '-n') { $native = $true; $i++ }
    elseif ($x -eq '-S' -or $x -eq '--sess') { $useSess = $true; $i++ }
    elseif ($x -eq '-H' -or $x -eq '--host-shell') { $i++ }
    elseif ($x -eq '-h' -or $x -eq '--help') { Show-RshHelp; exit 0 }
    elseif ($x -in @('-C', '--ctr')) {
        [Console]::Error.WriteLine('rsh: Windows 客户端暂不支持 droidspaces 容器包装（-C/-c）；请用容器自己的 ssh 别名。')
        exit 2
    }
    elseif ($x -in @('-c', '--container', '-R', '--refresh')) {
        [Console]::Error.WriteLine("rsh: Windows 客户端暂不支持 $x（容器包装）；请用容器自己的 ssh 别名。")
        exit 2
    }
    elseif ($x.StartsWith('-')) {
        [Console]::Error.WriteLine("rsh: 未知选项 $x")
        exit 2
    }
    else { $parsing = $false }
}

if ($i -ge $a.Count) { Show-RshHelp; exit 2 }
$hostName = [string]$a[$i]
$i++
$cmdWords = @()
if ($i -lt $a.Count) { $cmdWords = @($a[$i..($a.Count - 1)]) }

$pathPrelude = @'
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) if [ -d "$HOME/.local/bin" ]; then PATH="$HOME/.local/bin:$PATH"; export PATH; fi ;;
esac
'@

# sudoers 按命令路径授权：包一层 bash 必被拒；复合命令静默只给第一段加 sudo 更糟
function Test-SudoShape([string]$Text) {
    if ($Text.Contains("`n")) { return $false }
    if ($Text -match '&&|\||(^|[^\\]);') { return $false }
    return $true
}

function New-PosixRemoteCommand([string]$B64, [bool]$NativeShell) {
    # 全程无引号字符：本地 base64 → 远端 mktemp 脚本 → 执行 → 删除
    $head = 'f=$(mktemp 2>/dev/null || echo ${TMPDIR:-/tmp}/.sshkit.$$); printf %s ' + $B64 + ' | base64 -d > $f; '
    if ($NativeShell) {
        return $head + '. $f; __sshkit_rc=$?; rm -f $f; exit $__sshkit_rc'
    }
    return $head + 'if command -v bash >/dev/null 2>&1; then bash --noprofile --norc $f; else sh $f; fi; __sshkit_rc=$?; rm -f $f; exit $__sshkit_rc'
}

function Invoke-RshExec([string]$Text) {
    if ($sudoRun -and -not (Test-SudoShape $Text)) {
        [Console]::Error.WriteLine('rsh: -s 只支持单条命令（sudoers 按命令路径授权，不能包一层 bash）。')
        [Console]::Error.WriteLine('      复合命令（; && |）请改用：rsh -f <host> <脚本>，在脚本里对需要的行写 sudo -n')
        [Console]::Error.WriteLine('      （若只是参数里含这些字符，同样走 -f）')
        return 2
    }
    $body = $Text
    if ($sudoRun) { $body = 'sudo -n ' + $body }
    if (-not $native) { $body = ($pathPrelude.Trim()) + "`n" + $body }
    if ($useSess) {
        return (Invoke-ShkSessRun -HostName $hostName -Script $body)
    }
    $b64 = ConvertTo-ShkB64 $body
    $remote = New-PosixRemoteCommand $b64 $native
    return (Start-ShkProcess -File 'ssh' -ArgList @('-T', $hostName, $remote))
}

if ($mode -eq 'file') {
    if ($cmdWords.Count -lt 1) {
        [Console]::Error.WriteLine('rsh: -f 需要脚本路径（用 - 表示 stdin）')
        exit 2
    }
    $src = [string]$cmdWords[0]
    if ($sudoRun) {
        [Console]::Error.WriteLine('rsh: -f 模式下 -s 无效（脚本里请自己写 sudo -n）')
    }
    if ($src -eq '-') {
        $bytes = Read-ShkStdinAll
    } else {
        if (-not (Test-Path -LiteralPath $src)) {
            [Console]::Error.WriteLine("rsh: 读不到 $src")
            exit 2
        }
        $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $src).ProviderPath)
    }
    if ($useSess) {
        $text = [Text.Encoding]::UTF8.GetString($bytes)
        if (-not $native) { $text = ($pathPrelude.Trim()) + "`n" + $text }
        Exit-ShkProcess (Invoke-ShkSessRun -HostName $hostName -Script $text)
    }
    if ($native) { $interp = 'sh -s' }
    else { $interp = 'if command -v bash >/dev/null 2>&1; then exec bash --noprofile --norc -s; else exec sh -s; fi' }
    Exit-ShkProcess (Start-ShkProcess -File 'ssh' -ArgList @('-T', $hostName, $interp) -RedirectIn -StdinBytes $bytes)
}

if ($cmdWords.Count -eq 0) {
    if ($useSess) {
        [Console]::Error.WriteLine("rsh: --sess 是非交互会话，交互请直接 rsh $hostName")
        exit 2
    }
    if ($native) { Exit-ShkProcess (Start-ShkProcess -File 'ssh' -ArgList @('-t', $hostName) -Interactive) }
    Exit-ShkProcess (Start-ShkProcess -File 'ssh' -ArgList @('-t', $hostName,
        'if command -v bash >/dev/null 2>&1; then exec bash -l; else exec sh -l; fi') -Interactive)
}

Exit-ShkProcess (Invoke-RshExec ($cmdWords -join ' '))

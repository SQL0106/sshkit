#!/usr/bin/env pwsh
# smoke.ps1 —— PowerShell 版 sshkit 自测
#
#   pwsh -NoProfile -File win/tests/smoke.ps1                     # 只跑本机可离线验证的部分
#   pwsh -NoProfile -File win/tests/smoke.ps1 -HostName linux-host # 再加真机 ssh 用例
#
# 离线部分：命令构造（无引号/可解码）、PowerShell 常驻 loop 的协议握手。
# 联机部分：rsh 执行/退出码/stdin 透传/-f、sess 状态保持。
[CmdletBinding()]
param(
    # POSIX 目标（Linux/macOS/Android）：跑 rsh 用例
    [string]$HostName = '',
    # Windows 目标：跑 wsh + sess(windows loop) 用例
    [string]$WinHostName = '',
    [switch]$SkipSsh,
    # 跳过 sess 用例（只验一次性 ssh 路径）
    [switch]$NoSess
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# 远程输出是 UTF-8；调用方也必须是 UTF-8，否则中文会被码页解成 '??'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
. (Join-Path $root 'sshkit-lib.ps1')

$script:pass = 0
$script:fail = 0
function Check([string]$Name, [bool]$Cond, [string]$Detail = '') {
    if ($Cond) {
        $script:pass++
        [Console]::Out.WriteLine("PASS  $Name")
    } else {
        $script:fail++
        [Console]::Out.WriteLine("FAIL  $Name  $Detail")
    }
}

# ---------------------------------------------------------------- 离线：构造

$script = @'
echo "dq"; printf '%s\n' 中文
if [ 1 -eq 1 ]; then echo "if-ok"; fi
exit 7
'@
$b64 = ConvertTo-ShkB64 $script
$remote = 'f=$(mktemp 2>/dev/null || echo ${TMPDIR:-/tmp}/.sshkit.$$); printf %s ' + $b64 + ' | base64 -d > $f; if command -v bash >/dev/null 2>&1; then bash --noprofile --norc $f; else sh $f; fi; __sshkit_rc=$?; rm -f $f; exit $__sshkit_rc'

Check '远端正文字符串不含双引号' (-not $remote.Contains('"')) $remote
Check '远端正文字符串不含单引号' (-not $remote.Contains("'")) $remote
Check 'base64 可还原' ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) -eq $script)

$b = ConvertTo-ShkB64 'echo 1'
$expr = "& ([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$b'))))"
Check 'scriptblock 表达式不含双引号' (-not $expr.Contains('"')) $expr

$enc = 'pwsh.exe -NoProfile -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('"x"'))
Check 'EncodedCommand 不含引号' (-not $enc.Contains('"')) $enc

# ---------------------------------------------------------------- 离线：常驻 loop

function Test-PwshLoop {
    $lb = ConvertTo-ShkB64 $script:ShkPwshLoop
    $lexpr = "& ([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$lb'))))"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Get-ShkPowerShellExe
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($null -ne $psi.PSObject.Properties['ArgumentList']) {
        foreach ($x in @('-NoProfile', '-NonInteractive', '-Command', $lexpr)) { $psi.ArgumentList.Add($x) }
    } else {
        $psi.Arguments = '-NoProfile -NonInteractive -Command ' + '"' + $lexpr.Replace('"', '\"') + '"'
    }
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.NewLine = "`n"
    try {
        $ready = $p.StandardOutput.ReadLineAsync()
        if (-not $ready.Wait(15000)) { return $false }
        if ($ready.Result -ne '__READY__') { return $false }
        # 注意 `exit` 会直接杀掉常驻 shell（协议里没有机会写哨兵，rc=255），
        # 所以失败路径用异常验证（loop 的 catch 会把 rc 置 1）。
        foreach ($case in @(@('echo "hello"; 1+1', '0'), @('"中文"', '0'), @('throw "boom"', '1'))) {
            $tok = [Guid]::NewGuid().ToString('N').Substring(0, 8)
            $code = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$case[0]))
            $p.StandardInput.WriteLine($tok + ':' + $code)
            $p.StandardInput.Flush()
            $seen = $false
            for ($n = 0; $n -lt 200; $n++) {
                $ln = $p.StandardOutput.ReadLineAsync()
                if (-not $ln.Wait(5000)) { return $false }
                if ($null -eq $ln.Result) { return $false }
                if ($ln.Result -eq ("__END__" + $tok + ":" + $case[1])) { $seen = $true; break }
            }
            if (-not $seen) { return $false }
        }
        return $true
    } finally {
        try { $p.Kill() } catch { }
    }
}

Check 'PowerShell 常驻 loop 握手与执行' (Test-PwshLoop)

# ---------------------------------------------------------------- 联机

if ($WinHostName -and -not $SkipSsh) {
    $wsh = Join-Path $root 'wsh.ps1'
    $sess = Join-Path $root 'sess.ps1'
    $exe = Get-ShkPowerShellExe

    # 先测不依赖 sess 的一次性路径：sess 出问题时能立刻区分「wsh 本身坏了」
    $out = & $exe -NoProfile -File $wsh --direct $WinHostName 'echo "win-ok"' 2>&1
    Check 'wsh --direct 执行' (($out -join "`n") -match 'win-ok') ($out -join ' | ')

    $out = & $exe -NoProfile -File $wsh --direct $WinHostName '"中文-" + (1+1)' 2>&1
    Check 'wsh --direct 中文' (($out -join "`n") -match '中文-2') ($out -join ' | ')

    & $exe -NoProfile -File $wsh --direct $WinHostName 'exit 7' 2>&1 | Out-Null
    Check 'wsh 退出码 7' ($LASTEXITCODE -eq 7) "rc=$LASTEXITCODE"

    # stdin 透传：远端从 ssh 通道读一行（验证子进程 stdin 句柄没丢）
    $pi = New-Object System.Diagnostics.ProcessStartInfo
    $pi.FileName = $exe
    $pi.UseShellExecute = $false
    $pi.RedirectStandardInput = $true
    $pi.RedirectStandardOutput = $true
    $argList = @('-NoProfile', '-File', $wsh, '--direct', $WinHostName, '$x = [Console]::In.ReadLine(); "got=$x"')
    if ($null -ne $pi.PSObject.Properties['ArgumentList']) {
        foreach ($x in $argList) { $pi.ArgumentList.Add($x) }
    } else {
        $pi.Arguments = ($argList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    }
    $pp = [System.Diagnostics.Process]::Start($pi)
    $pp.StandardInput.NewLine = "`n"
    $pp.StandardInput.WriteLine('PIPED-WIN')
    $pp.StandardInput.Close()
    $stdinOut = $pp.StandardOutput.ReadToEnd()
    $pp.WaitForExit()
    Check 'wsh stdin 透传' ($stdinOut -match 'got=PIPED-WIN') $stdinOut

    if (-not $NoSess) {
        # 流式打印（不聚到变量里）：卡住时日志能看到最后的 trace 行
        $sessOut = @()
        & $exe -NoProfile -File $wsh $WinHostName '2+2' 2>&1 | ForEach-Object {
            $sessOut += [string]$_
            [Console]::Out.WriteLine("    sess| $_")
        }
        Check 'wsh 默认(sess) 执行' (($sessOut -join "`n") -match '4') ($sessOut -join ' | ')

        & $exe -NoProfile -File $sess run $WinHostName 'Set-Location $env:SystemRoot' 2>&1 | Out-Null
        $where = & $exe -NoProfile -File $sess run $WinHostName '(Get-Location).Path' 2>&1
        Check 'sess(windows) 状态保持' (($where -join '') -match [regex]::Escape($env:SystemRoot)) ($where -join ' ')
        & $exe -NoProfile -File $sess stop $WinHostName 2>&1 | Out-Null

        $lg = Join-Path (Get-ShkCache 'sess') ($WinHostName + '.v4.log')
        if (Test-Path -LiteralPath $lg) {
            [Console]::Out.WriteLine('--- sess 日志（尾部）---')
            Get-Content -LiteralPath $lg -Tail 10 | ForEach-Object { [Console]::Out.WriteLine("    $_") }
        }
    }
}

if ($HostName -and -not $SkipSsh) {
    $rsh = Join-Path $root 'rsh.ps1'
    $sess = Join-Path $root 'sess.ps1'

    $out = & (Get-ShkPowerShellExe) -NoProfile -File $rsh $HostName 'echo ssh-ok' 2>&1
    Check 'rsh 执行' (($out -join "`n") -match 'ssh-ok')

    & (Get-ShkPowerShellExe) -NoProfile -File $rsh $HostName 'exit 42' 2>&1 | Out-Null
    Check 'rsh 退出码 42' ($LASTEXITCODE -eq 42) "rc=$LASTEXITCODE"

    $pi = New-Object System.Diagnostics.ProcessStartInfo
    $pi.FileName = Get-ShkPowerShellExe
    $pi.UseShellExecute = $false
    $pi.RedirectStandardInput = $true
    $pi.RedirectStandardOutput = $true
    if ($null -ne $pi.PSObject.Properties['ArgumentList']) {
        foreach ($x in @('-NoProfile', '-File', $rsh, $HostName, 'read -r x; echo "got=$x"')) { $pi.ArgumentList.Add($x) }
    } else {
        $pi.Arguments = '-NoProfile -File "' + $rsh + '" ' + $HostName + ' "read -r x; echo got=$x"'
    }
    $pp = [System.Diagnostics.Process]::Start($pi)
    $pp.StandardInput.WriteLine('PIPED')
    $pp.StandardInput.Close()
    $stdinOut = $pp.StandardOutput.ReadToEnd()
    $pp.WaitForExit()
    Check 'rsh stdin 透传' ($stdinOut -match 'got=PIPED') $stdinOut

    & (Get-ShkPowerShellExe) -NoProfile -File $sess run $HostName 'cd /tmp' 2>&1 | Out-Null
    $pwd = & (Get-ShkPowerShellExe) -NoProfile -File $sess run $HostName 'pwd' 2>&1
    Check 'sess 状态保持' (($pwd -join '') -match '/tmp') ($pwd -join ' ')
    & (Get-ShkPowerShellExe) -NoProfile -File $sess stop $HostName 2>&1 | Out-Null
}

[Console]::Out.WriteLine('')
[Console]::Out.WriteLine(("{0} passed, {1} failed" -f $script:pass, $script:fail))
if ($script:fail -gt 0) { exit 1 }
exit 0

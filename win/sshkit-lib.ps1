# sshkit-lib.ps1 —— sshkit PowerShell 版共享实现（客户端侧）
#
# 被 rsh.ps1 / wsh.ps1 / sess.ps1 dot-source，不单独执行。
#
# 设计约束（Windows 客户端必须同时满足，见 README「Windows 客户端」）：
#   1) 绝不把用户命令拼进 ssh 的 argv —— PowerShell 5.1 对原生参数里的双引号
#      有已知的破坏性转义（Legacy 模式）。所有命令走 base64，ssh 的 argv 里只有
#      [A-Za-z0-9+/=] 与固定外壳字符，且**不含双引号**。
#   2) 子进程的 stdout/stderr 不重定向 —— 直接继承父进程句柄，字节级透传，
#      既没有编码转换（中文不乱码），也不会因两路管道互等而死锁。
#   3) 只有 -f（脚本从 stdin 进）才重定向 stdin；其余情形 stdin 留给用户命令。

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:ShkHome = $PSScriptRoot
$script:ShkSessProto = '.v4'

# 远端常驻循环：POSIX（bash/sh）。与 POSIX 版 sess 的 POSIX_LOOP 逐字一致。
$script:ShkPosixLoop = @'
while IFS= read -r __sess_line; do __sess_tok=${__sess_line%%:*}; __sess_b64=${__sess_line#*:}; __sess_src=$(printf "%s" "$__sess_b64" | base64 -d); eval "$__sess_src" </dev/null; __sess_rc=$?; printf "\n__END__%s:%d\n" "$__sess_tok" "$__sess_rc"; printf "\n__END__%s:%d\n" "$__sess_tok" "$__sess_rc" >&2; done
'@
$script:ShkPosixLoop = $script:ShkPosixLoop.Trim()

# 远端常驻循环：Windows PowerShell。与 POSIX 版 sess 的 PWSH_LOOP 逐字一致，
# 只多一行控制台编码（PS5.1 默认按代码页输出，中文会乱）。
$script:ShkPwshLoop = @'
$ProgressPreference = "SilentlyContinue"
try { $PSStyle.OutputRendering = "PlainText" } catch {}
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch {}
# Windows sshd 只在远端进程退出时才把 stderr 交给客户端（常驻会话 = 永远收不到），
# 所以这里把错误流并进 stdout，只发一路哨兵（详见 C# Reset() 的 pending）。
try { [Console]::SetError([Console]::Out) } catch {}
[Console]::Out.WriteLine("__READY__")
[Console]::Out.Flush()
while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }
    # Windows PowerShell 5.1 写管道时可能带 UTF-8 BOM，会粘在 token 前面
    $line = $line.TrimStart([char]0xFEFF)
    if ($line.Length -eq 0) { continue }
    $i = $line.IndexOf(":")
    $tok = $line.Substring(0, $i)
    $b64 = $line.Substring($i + 1)
    $code = 0
    $global:__sessOk = $true
    $global:__sessCode = 0
    $global:LASTEXITCODE = 0
    try {
        $src = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
        $src = $src + "`n" + '$global:__sessOk = $?; $global:__sessCode = $LASTEXITCODE'
        . ([scriptblock]::Create($src)) 2>&1
        if (-not $global:__sessOk) {
            if ($global:__sessCode -is [int] -and $global:__sessCode -ne 0) { $code = $global:__sessCode } else { $code = 1 }
        }
    } catch {
        [Console]::Error.WriteLine($_.ToString())
        $code = 1
    }
    [Console]::Out.Write("`n__END__" + $tok + ":" + $code + "`n")
    [Console]::Out.Flush()
}
'@
$script:ShkPwshLoop = $script:ShkPwshLoop.Trim()

# ---------------------------------------------------------------- 基础设施

function Test-ShkWindows {
    if (Test-Path variable:IsWindows) { return [bool]$IsWindows }
    return ([Environment]::OSVersion.Platform -eq 'Win32NT')
}

function Initialize-ShkConsole {
    # 让继承句柄的子进程输出按 UTF-8 解析（中文不乱码）。有异常就静默放弃：
    # 无控制台（服务/管道）时设置 OutputEncoding 可能失败，不影响字节透传。
    try {
        if (Test-ShkWindows) {
            [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
        }
    } catch { }
}

function Get-ShkCache([string]$Name) {
    if ($env:XDG_CACHE_HOME) { $base = $env:XDG_CACHE_HOME }
    else { $base = Join-Path $HOME '.cache' }
    $d = Join-Path $base $Name
    if (-not (Test-Path -LiteralPath $d)) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }
    return $d
}

function ConvertTo-ShkB64([string]$Text) {
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
}

function Read-ShkStdinAll {
    # 二进制读全 stdin（-f - 用）
    $si = [Console]::OpenStandardInput()
    $ms = New-Object System.IO.MemoryStream
    $buf = New-Object byte[] 65536
    while ($true) {
        $n = $si.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $ms.Write($buf, 0, $n)
    }
    return $ms.ToArray()
}

function ConvertTo-ShkArg([string]$Value) {
    # Windows 命令行参数的 MVC 转义（够用：我们保证 argv 里没有双引号）
    if ($Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    if ($Value.Contains('"')) {
        throw "sshkit: 内部参数含双引号（不应发生，命令应走 base64）: $Value"
    }
    return '"' + $Value + '"'
}

function Start-ShkProcess {
    <#
      启动一个进程并把退出码返回给调用方。
        -ArgList      参数数组（精确传递，不经 shell 解析）
        -RedirectIn   重定向 stdin（配合 -StdinBytes 写脚本）
        -StdinBytes   要写入 stdin 的字节；null 表示不写
        -Capture      捕获 stdout/stderr 并返回（用于探测）
        -Interactive  完全不重定向（交互式 ssh -t 需要真 TTY）
      默认：重定向 stdout/stderr 并**自己泵字节**到本进程的标准输出。
      为什么不能靠句柄继承：Windows 上 System.Diagnostics.Process 在没有任何
      重定向时不设置 bInheritHandles，子进程拿不到调用方（PowerShell 捕获用的）
      管道句柄，输出会直接丢掉（CI 实测：退出码正常、输出为空）。
    #>
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [string[]]$ArgList = @(),
        [switch]$RedirectIn,
        [byte[]]$StdinBytes = $null,
        [switch]$Capture,
        [switch]$Interactive,
        [int]$TimeoutSec = 0
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $hasArgList = $null -ne $psi.PSObject.Properties['ArgumentList']
    if ($hasArgList) {
        foreach ($a in $ArgList) { $psi.ArgumentList.Add($a) }
    } else {
        $psi.Arguments = (($ArgList | ForEach-Object { ConvertTo-ShkArg $_ }) -join ' ')
    }
    $streamMode = $false
    if ($RedirectIn) { $psi.RedirectStandardInput = $true }
    if ($Capture) {
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        if ($null -ne $psi.PSObject.Properties['StandardOutputEncoding']) {
            $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
            $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding $false
        }
    } elseif (-not $Interactive) {
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $streamMode = $true
    }
    $p = [System.Diagnostics.Process]::Start($psi)
    if ($RedirectIn) {
        $s = $p.StandardInput.BaseStream
        if ($null -ne $StdinBytes -and $StdinBytes.Length -gt 0) {
            $s.Write($StdinBytes, 0, $StdinBytes.Length)
        }
        try { $s.Flush() } catch { }
        try { $s.Close() } catch { }
    }
    if ($streamMode) {
        # 两路并发泵：只读一路会在另一路满缓冲时死锁
        $tOut = $p.StandardOutput.BaseStream.CopyToAsync([Console]::OpenStandardOutput())
        $tErr = $p.StandardError.BaseStream.CopyToAsync([Console]::OpenStandardError())
        $p.WaitForExit()
        # [void] 必须留：GetResult() 的返回值会混进函数输出，把 exit 码变成数组
        try { [void]$tOut.GetAwaiter().GetResult() } catch { }
        try { [void]$tErr.GetAwaiter().GetResult() } catch { }
        return $p.ExitCode
    }
    if ($Capture) {
        $out = $p.StandardOutput.ReadToEndAsync()
        $err = $p.StandardError.ReadToEndAsync()
        if ($TimeoutSec -gt 0) {
            if (-not $p.WaitForExit($TimeoutSec * 1000)) {
                try { $p.Kill() } catch { }
                return [pscustomobject]@{ Code = 124; Out = ''; Err = 'timeout' }
            }
        } else {
            $p.WaitForExit()
        }
        return [pscustomobject]@{ Code = $p.ExitCode; Out = $out.Result; Err = $err.Result }
    }
    $p.WaitForExit()
    return $p.ExitCode
}

function Get-ShkPowerShellExe {
    # keeper 用当前宿主解释器重新拉起自己：PS7 就是 pwsh.exe，PS5.1 是 powershell.exe
    try {
        $pp = [Environment]::ProcessPath
        if ($pp) { return $pp }
    } catch { }
    try {
        $p = Get-Process -Id $PID
        if ($p.Path) { return $p.Path }
    } catch { }
    if ($PSVersionTable.PSVersion.Major -ge 6) { return 'pwsh' }
    return 'powershell.exe'
}

# ---------------------------------------------------------------- sess 客户端

function Get-ShkSessPaths([string]$HostName) {
    $dir = Get-ShkCache 'sess'
    $safe = $HostName -replace '[^A-Za-z0-9._-]', '_'
    $p = $script:ShkSessProto
    return [pscustomobject]@{
        Dir  = $dir
        Port = Join-Path $dir ($safe + $p + '.port')
        Pid  = Join-Path $dir ($safe + $p + '.pid')
        Kind = Join-Path $dir ($safe + $p + '.kind')
        Sig  = Join-Path $dir ($safe + $p + '.sig')
        Log  = Join-Path $dir ($safe + $p + '.log')
        Lock = Join-Path $dir ($safe + $p + '.lock')
    }
}

function Get-ShkSessSig {
    # 源码指纹：sess.ps1 或 lib 任一改动 → 旧 keeper 退役
    $parts = @()
    foreach ($f in @('sess.ps1', 'sshkit-lib.ps1')) {
        $full = Join-Path $script:ShkHome $f
        if (Test-Path -LiteralPath $full) {
            $i = Get-Item -LiteralPath $full
            $parts += ('{0}:{1}' -f $i.LastWriteTimeUtc.Ticks, $i.Length)
        } else {
            $parts += 'missing'
        }
    }
    return ($parts -join '|')
}

function Test-ShkSessStale([string]$HostName) {
    $sp = Get-ShkSessPaths $HostName
    if (-not (Test-Path -LiteralPath $sp.Sig)) { return $true }
    try {
        $old = (Get-Content -LiteralPath $sp.Sig -Raw).Trim()
    } catch { return $true }
    return ($old -ne (Get-ShkSessSig))
}

function Get-ShkSessKind([string]$HostName, [switch]$Reset) {
    if ($env:SSHKIT_SESS_KIND) { return $env:SSHKIT_SESS_KIND }
    $sp = Get-ShkSessPaths $HostName
    if ($Reset) { Remove-Item -LiteralPath $sp.Kind -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $sp.Kind) {
        $k = (Get-Content -LiteralPath $sp.Kind -Raw).Trim()
        if ($k) { return $k }
    }
    $r = Start-ShkProcess -File 'ssh' -ArgList @('-T', '-o', 'ConnectTimeout=20', $HostName, 'uname -s') -Capture -TimeoutSec 90
    $out = [string]$r.Out
    if ($r.Code -eq 0 -and ($out -match 'Linux|Darwin|BSD')) {
        $kind = 'posix'
    } elseif ($out -match 'MINGW|MSYS|CYGWIN') {
        $kind = 'windows'
    } else {
        $r2 = Start-ShkProcess -File 'ssh' -ArgList @('-T', '-o', 'ConnectTimeout=20', $HostName,
            '"$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)"') -Capture -TimeoutSec 90
        $o2 = ([string]$r2.Out).Trim()
        if ($r2.Code -eq 0 -and $o2 -match '^\d') { $kind = 'windows' }
        else {
            $err = ([string]$r.Err).Trim()
            if (-not $err) { $err = '无输出' }
            throw ("sess: 无法判断 {0} 的类型（ssh rc={1}）：{2}" -f $HostName, $r.Code, $err)
        }
    }
    Set-Content -LiteralPath $sp.Kind -Value $kind -Encoding ascii
    return $kind
}

function Get-ShkSessRemoteCommand([string]$HostName, [string]$Kind) {
    if ($Kind -eq 'posix') {
        $loop = $script:ShkPosixLoop.Replace("'", "'\''")
        return "if command -v bash >/dev/null 2>&1; then exec bash --noprofile --norc -c '$loop'; else exec sh -c '$loop'; fi"
    }
    $b = ConvertTo-ShkB64 $script:ShkPwshLoop
    return "& ([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$b'))))"
}

function Read-ShkSessEndpoint([string]$HostName) {
    $sp = Get-ShkSessPaths $HostName
    if (-not (Test-Path -LiteralPath $sp.Port)) { return $null }
    try {
        $lines = Get-Content -LiteralPath $sp.Port
        if ($lines.Count -lt 2) { return $null }
        return [pscustomobject]@{ Port = [int]$lines[0]; Token = ([string]$lines[1]).Trim() }
    } catch { return $null }
}

function Start-ShkSessKeeper {
    param([string]$HostName, [string]$Kind = '')
    if (-not $Kind) { $Kind = Get-ShkSessKind $HostName }
    $remote = Get-ShkSessRemoteCommand $HostName $Kind
    Trace-ShkSess "spawn keeper exe=$(Get-ShkPowerShellExe) kind=$Kind"
    $sess = Join-Path $script:ShkHome 'sess.ps1'
    $exe = Get-ShkPowerShellExe
    $a = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $sess,
           '__keeper', $HostName, $Kind, (ConvertTo-ShkB64 $remote))
    # 拉起方式按平台分开，两边堵的坑正好相反：
    #   Windows：System.Diagnostics.Process 会 bInheritHandles=TRUE，keeper 继承
    #     调用方 stdout 管道写端 → 父进程永远等不到 EOF（实测子进程已 exit 仍挂住）。
    #     改用 Start-Process（ShellExecute，不继承句柄；-WindowStyle Hidden 不弹窗）。
    #   POSIX：Start-Process 直接 fork/exec 会继承 fd，同样挂住管道；必须用
    #     Process + RedirectStandardOutput/Error（.NET 给子进程新管道，天然 CLOEXEC）。
    if (Test-ShkWindows) {
        $argStr = (($a | ForEach-Object { ConvertTo-ShkArg $_ }) -join ' ')
        Start-Process -FilePath $exe -ArgumentList $argStr -WindowStyle Hidden | Out-Null
    } else {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        if ($null -ne $psi.PSObject.Properties['ArgumentList']) {
            foreach ($x in $a) { $psi.ArgumentList.Add($x) }
        } else {
            $psi.Arguments = (($a | ForEach-Object { ConvertTo-ShkArg $_ }) -join ' ')
        }
        [System.Diagnostics.Process]::Start($psi) | Out-Null
    }
    Trace-ShkSess 'keeper spawned'
    # 指纹由拉起方写：keeper 只负责跑协议，源码变更检测归客户端
    try { Set-Content -LiteralPath (Get-ShkSessPaths $HostName).Sig -Value (Get-ShkSessSig) -Encoding ascii } catch { }
}

function Connect-ShkSess {
    # 连上 keeper；必要时拉起一个。返回 @{Client=;Token=} 或 $null
    param([string]$HostName, [switch]$NoStart, [int]$TimeoutMs = 15000)
    if (-not $NoStart -and (Test-ShkSessStale $HostName)) {
        Stop-ShkSess -HostName $HostName -Quiet -Force
        Wait-ShkSessGone $HostName 5 | Out-Null
    }
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    $spawned = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        $ep = Read-ShkSessEndpoint $HostName
        if ($null -ne $ep) {
            $c = $null
            try {
                $c = New-Object System.Net.Sockets.TcpClient
                $c.NoDelay = $true
                $c.Connect('127.0.0.1', $ep.Port)
                return [pscustomobject]@{ Client = $c; Token = $ep.Token }
            } catch {
                if ($null -ne $c) { $c.Close() }
            }
        }
        if ($NoStart) { return $null }
        if (-not $spawned) {
            Trace-ShkSess 'no endpoint -> spawn'
            Start-ShkSessKeeper -HostName $HostName
            $spawned = $true
        }
        Start-Sleep -Milliseconds 100
    }
    return $null
}

function Wait-ShkSessGone([string]$HostName, [int]$TimeoutSec = 5) {
    $sp = Get-ShkSessPaths $HostName
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not (Test-Path -LiteralPath $sp.Port)) { return $true }
        Start-Sleep -Milliseconds 50
    }
    return $false
}

function Read-ShkExact($Stream, [byte[]]$Buf, [int]$Count) {
    $off = 0
    while ($off -lt $Count) {
        $n = $Stream.Read($Buf, $off, $Count - $off)
        if ($n -le 0) { return $off }
        $off += $n
    }
    return $off
}

function Send-ShkSessFrame($Stream, [byte]$Kind, [byte[]]$Data) {
    if ($null -eq $Data) { $Data = New-Object byte[] 0 }
    $hdr = New-Object byte[] 5
    $hdr[0] = $Kind
    $len = $Data.Length
    $hdr[1] = [byte](($len -shr 24) -band 0xff)
    $hdr[2] = [byte](($len -shr 16) -band 0xff)
    $hdr[3] = [byte](($len -shr 8) -band 0xff)
    $hdr[4] = [byte]($len -band 0xff)
    $Stream.Write($hdr, 0, 5)
    if ($len -gt 0) { $Stream.Write($Data, 0, $len) }
    $Stream.Flush()
}

function Read-ShkSessFrames($Stream, [int]$FirstByteTimeoutMs = 0) {
    # 读帧直到 R（退出码）；返回退出码，或 $null（连接断了/首字节超时）
    # 只有**首字节**受超时约束：命令本身可以长时间不输出，不能一刀切。
    # 超时用 Socket.Poll 实现（不用 ReadTimeout：它在 Windows 的 NetworkStream 上
    # 实测不生效，会让「探活」变成永久阻塞）。
    $stdout = [Console]::OpenStandardOutput()
    $stderr = [Console]::OpenStandardError()
    $armed = $FirstByteTimeoutMs -gt 0
    $hdr = New-Object byte[] 5
    while ($true) {
        if ($armed) {
            $sock = $null
            try { $sock = $Stream.Socket } catch { }
            if ($null -ne $sock -and -not $sock.Poll($FirstByteTimeoutMs * 1000, [System.Net.Sockets.SelectMode]::SelectRead)) {
                return $null
            }
            $armed = $false
        }
        $n = 0
        try { $n = Read-ShkExact $Stream $hdr 5 } catch { return $null }
        if ($n -lt 5) { return $null }
        $kind = [char]$hdr[0]
        $len = ([int]$hdr[1] -shl 24) -bor ([int]$hdr[2] -shl 16) -bor ([int]$hdr[3] -shl 8) -bor [int]$hdr[4]
        $buf = New-Object byte[] $len
        if ($len -gt 0) {
            $got = 0
            try { $got = Read-ShkExact $Stream $buf $len } catch { return $null }
            if ($got -lt $len) { return $null }
        }
        if ($kind -eq 'O') {
            $stdout.Write($buf, 0, $len); $stdout.Flush()
        } elseif ($kind -eq 'E') {
            $stderr.Write($buf, 0, $len); $stderr.Flush()
        } elseif ($kind -eq 'R') {
            if ($len -ge 4) {
                $b = @($buf[3], $buf[2], $buf[1], $buf[0])
                return [BitConverter]::ToInt32([byte[]]$b, 0)
            }
            return 1
        }
    }
}

function Test-ShkSessHealthy([string]$HostName) {
    # 独立连接发一条 `1` 探活：1.5s 内有 R 帧才算 keeper 活着。
    # 没有 port 文件 = keeper 没起，交给正常流程 spawn（返回 $true）。
    $conn = Connect-ShkSess -HostName $HostName -NoStart
    if ($null -eq $conn) { return $true }
    try {
        $s = $conn.Client.GetStream()
        Send-ShkSessScript $s $conn.Token '1'
        # 探活不能把输出打到调用方：临时接管 stdout 太脆，直接读帧并丢弃
        $rc = Read-ShkSessFramesQuiet $s 1500
        return ($null -ne $rc)
    } catch {
        return $false
    } finally {
        try { $conn.Client.Close() } catch { }
    }
}

function Read-ShkSessFramesQuiet($Stream, [int]$TimeoutMs) {
    $hdr = New-Object byte[] 5
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ($true) {
        $left = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
        if ($left -le 0) { return $null }
        $sock = $null
        try { $sock = $Stream.Socket } catch { }
        if ($null -ne $sock -and -not $sock.Poll($left * 1000, [System.Net.Sockets.SelectMode]::SelectRead)) { return $null }
        $n = 0
        try { $n = Read-ShkExact $Stream $hdr 5 } catch { return $null }
        if ($n -lt 5) { return $null }
        $kind = [char]$hdr[0]
        $len = ([int]$hdr[1] -shl 24) -bor ([int]$hdr[2] -shl 16) -bor ([int]$hdr[3] -shl 8) -bor [int]$hdr[4]
        $buf = New-Object byte[] $len
        if ($len -gt 0) {
            try { if ((Read-ShkExact $Stream $buf $len) -lt $len) { return $null } } catch { return $null }
        }
        if ($kind -eq 'R') {
            if ($len -ge 4) {
                $b = @($buf[3], $buf[2], $buf[1], $buf[0])
                return [BitConverter]::ToInt32([byte[]]$b, 0)
            }
            return 1
        }
    }
}

function Stop-ShkSess {
    param([string]$HostName, [switch]$Quiet, [switch]$Force)
    $sp = Get-ShkSessPaths $HostName
    # 先记下 pid：pid 文件可能在清理时先被删掉；再退一步从锁文件读（keeper 启动即写）
    $kp = 0
    if (Test-Path -LiteralPath $sp.Pid) {
        try { $kp = [int]((Get-Content -LiteralPath $sp.Pid -Raw).Trim()) } catch { }
    }
    if ($kp -eq 0 -and (Test-Path -LiteralPath $sp.Lock)) {
        try {
            $v = (Get-Content -LiteralPath $sp.Lock -Raw).Trim()
            if ($v) { $kp = [int]$v }
        } catch { }
    }
    $alive = $false
    if ($kp -gt 0) { $alive = $null -ne (Get-Process -Id $kp -ErrorAction SilentlyContinue) }
    if (-not $alive -and -not (Test-Path -LiteralPath $sp.Port)) {
        Remove-Item -LiteralPath $sp.Port, $sp.Pid, $sp.Sig, $sp.Lock -Force -ErrorAction SilentlyContinue
        if (-not $Quiet) { [Console]::Error.WriteLine("sess: $HostName 没有运行中的会话") }
        return
    }
    $closed = $false
    if (-not $Force) {
        $conn = Connect-ShkSess -HostName $HostName -NoStart
        if ($null -ne $conn) {
            try {
                $s = $conn.Client.GetStream()
                Send-ShkSessScript $s $conn.Token '__STOP__'
            } catch { }
            try { $conn.Client.Close() } catch { }
            $closed = Wait-ShkSessGone $HostName 5
        }
    }
    # 协议停不掉（keeper 卡死/旧版本）→ 退化为杀进程
    if (-not $closed) {
        if ($kp -gt 0) { Stop-Process -Id $kp -Force -ErrorAction SilentlyContinue }
        Wait-ShkSessGone $HostName 3 | Out-Null
    }
    Remove-Item -LiteralPath $sp.Port, $sp.Pid, $sp.Sig, $sp.Lock -Force -ErrorAction SilentlyContinue
    if (-not $Quiet) { [Console]::Out.WriteLine("sess: 已关闭 $HostName") }
}

function Send-ShkSessScript($Stream, [string]$Token, [string]$Text) {
    # v4 请求帧：<token>\n<字节数>\n<script 原始字节>（长度前缀，避免多行/分片歧义）
    $body = [Text.Encoding]::UTF8.GetBytes($Text.Replace("`r`n", "`n"))
    $head = [Text.Encoding]::ASCII.GetBytes($Token + "`n" + $body.Length + "`n")
    $Stream.Write($head, 0, $head.Length)
    $Stream.Write($body, 0, $body.Length)
    $Stream.Flush()
}

function Exit-ShkProcess([int]$Code) {
    # PowerShell 的 exit 在 Windows 上偶尔会被残留的进程/流资源拖住（实测：脚本已打印
    # "exiting rc=0" 但进程不退出，调用方管道永远等不到 EOF）。这里显式冲刷后硬退出，
    # 语义也更接近 POSIX 版的 exec。
    try { [Console]::Out.Flush() } catch { }
    try { [Console]::Error.Flush() } catch { }
    [Environment]::Exit($Code)
}

function Trace-ShkSess([string]$Msg) {
    # SSHKIT_SESS_TRACE=1 时打印带毫秒时间戳的阶段标记（排障用，平时零开销）
    if ($env:SSHKIT_SESS_TRACE -eq '1') {
        [Console]::Error.WriteLine(('sess[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $Msg))
    }
}

function Invoke-ShkSessRun {
    param([string]$HostName, [string]$Script, [switch]$New, [switch]$Verbose)
    Trace-ShkSess "run start host=$HostName"
    if ($New) {
        Stop-ShkSess -HostName $HostName -Quiet -Force
        Wait-ShkSessGone $HostName 5 | Out-Null
    }
    if (-not (Test-ShkSessHealthy $HostName)) {
        if ($Verbose) { [Console]::Error.WriteLine("sess: $HostName 会话无响应，重建") }
        Stop-ShkSess -HostName $HostName -Quiet -Force
        Wait-ShkSessGone $HostName 5 | Out-Null
    }
    Trace-ShkSess 'health ok, connecting'
    $conn = Connect-ShkSess -HostName $HostName
    Trace-ShkSess ('connect -> ' + $(if ($null -eq $conn) { 'null' } else { 'ok' }))
    if ($null -eq $conn) {
        [Console]::Error.WriteLine("sess: 连不上会话 $HostName（日志：$((Get-ShkSessPaths $HostName).Log)）")
        return 1
    }
    try {
        $s = $conn.Client.GetStream()
        try {
            Send-ShkSessScript $s $conn.Token $Script
        } catch {
            [Console]::Error.WriteLine("sess: 发送失败 $HostName")
            return 1
        }
        $fb = 120
        if ($env:SSHKIT_SESS_FIRST_BYTE) {
            try { $fb = [int]$env:SSHKIT_SESS_FIRST_BYTE } catch { }
        }
        Trace-ShkSess "sent, reading frames (first-byte timeout ${fb}s)"
        $rc = Read-ShkSessFrames $s ($fb * 1000)
        Trace-ShkSess "frames done rc=$rc"
        if ($null -eq $rc) {  # 无响应
            [Console]::Error.WriteLine("sess: $HostName 会话无响应（首字节 ${fb}s 超时或连接断开），可用 --new 重建；日志：$((Get-ShkSessPaths $HostName).Log)")
            return 1
        }
        return $rc
    } finally {
        try { $conn.Client.Close() } catch { }
        Trace-ShkSess 'connection closed'
    }
}

function Get-ShkSessSessions {
    $dir = Get-ShkCache 'sess'
    $suffix = $script:ShkSessProto + '.pid'
    $res = @()
    Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.EndsWith($suffix) } |
        ForEach-Object {
            $h = $_.Name.Substring(0, $_.Name.Length - $suffix.Length)
            $sp = Get-ShkSessPaths $h
            $alive = $false
            try {
                $kp = [int]((Get-Content -LiteralPath $sp.Pid -Raw).Trim())
                $alive = $null -ne (Get-Process -Id $kp -ErrorAction SilentlyContinue)
            } catch { }
            $k = '?'
            if (Test-Path -LiteralPath $sp.Kind) {
                try { $k = (Get-Content -LiteralPath $sp.Kind -Raw).Trim() } catch { }
            }
            $res += [pscustomobject]@{ Host = $h; Kind = $k; Alive = $alive; PidFile = $sp.Pid }
        }
    return $res
}

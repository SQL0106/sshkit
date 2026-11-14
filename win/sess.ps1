#!/usr/bin/env pwsh
# sess.ps1 —— 常驻远端 shell 会话（Windows / PowerShell 版）
#
# 用法：
#   sess run [--new] [-v] <host> '<命令>'   # 在常驻会话里执行（自动启动会话）
#   sess list                               # 列出会话
#   sess stop [<host>]                      # 关闭会话（省略=全部）
#   sess kind [--reset] <host>              # 查看远端类型（posix / windows）
#
# 协议（v4，与 POSIX 版 sess 的 v3 不互通，文件后缀也不同，可共存）：
#   客户端 → keeper：`<token>\n<字节数>\n<script 原始字节>`
#   keeper → 客户端：`<kind 1 字节><长度 4 字节大端><数据>`，kind ∈ O/E/R
#   远端：`<token>:<base64 脚本>\n`，执行完在 stdout/stderr 各写一份
#   `__END__<token>:<退出码>` 哨兵（两路都要到齐才算结束）。
#
# keeper 是独立进程（本脚本 __keeper 模式），用 Add-Type 现场编译下面的 C#：
# PowerShell 本身没有可靠的并发 I/O（两路管道 + 监听 socket 同时读），
# 交给 .NET 线程最稳；C# 代码保持 C# 5 语法，PS 5.1 的 CodeDom 也能编译。
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$lib = Join-Path $PSScriptRoot 'sshkit-lib.ps1'
if (-not (Test-Path -LiteralPath $lib)) {
    [Console]::Error.WriteLine("sess: 缺 $lib（请把 sshkit-lib.ps1 与 sess.ps1 放在同一目录）")
    exit 2
}
. $lib

$CSharpKeeper = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

public class SessKeeper
{
    private readonly string host;
    private readonly string kind;
    private readonly string remote;
    private readonly string portFile;
    private readonly string pidFile;
    private readonly string logFile;
    private readonly string token;

    private TcpListener srv;
    private Process proc;
    private Stream psin;

    private readonly object cmdLock = new object();
    private readonly object bufLock = new object();
    private readonly object qLock = new object();

    private Queue<object[]> q;
    private Dictionary<string, byte[]> bufs;
    private HashSet<string> pending;
    private bool outDone;
    private int rc;
    private byte[] tok;

    private volatile bool dead;
    private volatile bool killNow;
    private DateTime lastUsed;
    private FileStream lockStream;

    private const int IdleTimeoutSec = 1800;
    private const int ReadyTimeoutSec = 60;

    public SessKeeper(string host, string kind, string cacheDir, string remote)
    {
        this.host = host;
        this.kind = kind;
        this.remote = remote;
        this.portFile = Path.Combine(cacheDir, host + ".v4.port");
        this.pidFile = Path.Combine(cacheDir, host + ".v4.pid");
        this.logFile = Path.Combine(cacheDir, host + ".v4.log");
        this.token = Guid.NewGuid().ToString("N");
        this.lastUsed = DateTime.UtcNow;
    }

    private void Log(string m)
    {
        try
        {
            // 必须用 FileShare.ReadWrite：拉起方已经把同一个日志文件打开（重定向控制台），
            // File.AppendAllText 的默认共享模式会撞 sharing violation，日志整份丢失。
            byte[] b = Encoding.UTF8.GetBytes(DateTime.Now.ToString("HH:mm:ss.fff") + " " + m + "\n");
            using (FileStream fs = new FileStream(logFile, FileMode.Append, FileAccess.Write, FileShare.ReadWrite))
            {
                fs.Write(b, 0, b.Length);
            }
        }
        catch { }
    }

    public void Run()
    {
        // 单实例：同一 host 只允许一个 keeper 抢 port 文件（否则两个 keeper 轮流吃
        // 客户端，表现为 cd/环境变量莫名其妙丢失）。FileShare.None 是跨进程互斥锁。
        string lockPath = Path.Combine(Path.GetDirectoryName(portFile), host + ".v4.lock");
        try
        {
            // FileShare.Read：别的 keeper 拿不到写权限（互斥），但客户端/stop 能读 pid。
            lockStream = new FileStream(lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.Read);
            byte[] pidBytes = Encoding.ASCII.GetBytes(Process.GetCurrentProcess().Id.ToString() + "\n");
            lockStream.SetLength(0);
            lockStream.Write(pidBytes, 0, pidBytes.Length);
            lockStream.Flush();
        }
        catch (Exception)
        {
            Log("another keeper holds lock -> exit");
            return;
        }
        if (ExistingAlive())
        {
            Log("another keeper alive -> exit");
            try { lockStream.Close(); } catch { }
            return;
        }
        Log("run start kind=" + kind);
        srv = new TcpListener(IPAddress.Loopback, 0);
        srv.Start();
        Log("listening");
        int port = ((IPEndPoint)srv.LocalEndpoint).Port;
        File.WriteAllText(portFile, port.ToString() + "\n" + token + "\n");
        File.WriteAllText(pidFile, Process.GetCurrentProcess().Id.ToString() + "\n");
        Log("keeper up kind=" + kind + " port=" + port);
        try { Spawn(); }
        catch (Exception e) { Log("spawn failed: " + e.Message + " | " + e.StackTrace); throw; }
        Log("remote session ready");

        while (!killNow)
        {
            if (!srv.Server.Poll(250000, SelectMode.SelectRead))
            {
                if ((DateTime.UtcNow - lastUsed).TotalSeconds > IdleTimeoutSec)
                {
                    Log("idle timeout");
                    break;
                }
                continue;
            }
            TcpClient c = srv.AcceptTcpClient();
            lastUsed = DateTime.UtcNow;
            Thread t = new Thread(HandleClient);
            t.IsBackground = true;
            t.Start(c);
        }
        Shutdown();
    }

    private bool ExistingAlive()
    {
        try
        {
            if (!File.Exists(portFile)) return false;
            string[] lines = File.ReadAllLines(portFile);
            if (lines.Length < 1) return false;
            TcpClient c = new TcpClient();
            c.NoDelay = true;
            IAsyncResult ar = c.BeginConnect(IPAddress.Loopback, int.Parse(lines[0].Trim()), null, null);
            if (!ar.AsyncWaitHandle.WaitOne(500)) { c.Close(); return false; }
            c.EndConnect(ar);
            c.Close();
            return true;
        }
        catch { return false; }
    }

    private void HandleClient(object state)
    {
        TcpClient c = (TcpClient)state;
        try
        {
            NetworkStream ns = c.GetStream();
            ns.ReadTimeout = 60000;
            string got = ReadLine(ns);
            if (got == null || got != token) return;
            string lenLine = ReadLine(ns);
            if (lenLine == null) return;
            int len = int.Parse(lenLine.Trim());
            if (len < 0 || len > (4 << 20)) return;
            byte[] body = new byte[len];
            if (len > 0 && ReadExact(ns, body, len) < len) return;
            string script = Encoding.UTF8.GetString(body);
            if (script == "__STOP__")
            {
                killNow = true;
                return;
            }
            RunCommand(script, ns);
        }
        catch (Exception e)
        {
            Log("handle error: " + e.Message);
        }
        finally
        {
            try { c.Close(); } catch { }
        }
    }

    private static string ReadLine(NetworkStream ns)
    {
        MemoryStream ms = new MemoryStream();
        byte[] one = new byte[1];
        while (true)
        {
            int n = ns.Read(one, 0, 1);
            if (n <= 0) return null;
            if (one[0] == 10) break;
            if (one[0] != 13) ms.WriteByte(one[0]);
            if (ms.Length > (1 << 20)) return null;
        }
        return Encoding.UTF8.GetString(ms.ToArray());
    }

    private static int ReadExact(NetworkStream ns, byte[] buf, int count)
    {
        int off = 0;
        while (off < count)
        {
            int n = ns.Read(buf, off, count - off);
            if (n <= 0) break;
            off += n;
        }
        return off;
    }

    private void Spawn()
    {
        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = "ssh";
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardInput = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.Arguments = BuildSshArgs();
        proc = Process.Start(psi);
        psin = proc.StandardInput.BaseStream;
        Reset();

        bool[] ready = new bool[] { kind == "posix" };
        ManualResetEvent ev = new ManualResetEvent(ready[0]);

        Thread tout = new Thread(delegate ()
        {
            byte[] chunk = new byte[4096];
            MemoryStream head = new MemoryStream();
            try
            {
                while (true)
                {
                    int n = proc.StandardOutput.BaseStream.Read(chunk, 0, chunk.Length);
                    if (n <= 0) break;
                    if (!ready[0])
                    {
                        head.Write(chunk, 0, n);
                        byte[] h = head.ToArray();
                        int idx = IndexOf(h, Encoding.ASCII.GetBytes("__READY__"), 0);
                        if (idx < 0) continue;
                        ready[0] = true;
                        ev.Set();
                        int start = idx + 9;
                        while (start < h.Length && (h[start] == 13 || h[start] == 10)) start++;
                        if (start < h.Length) Feed("out", Sub(h, start, h.Length - start));
                        continue;
                    }
                    Feed("out", Sub(chunk, 0, n));
                }
            }
            catch { }
            OnOutDone();
        });
        tout.IsBackground = true;
        tout.Start();

        Thread terr = new Thread(delegate ()
        {
            byte[] chunk = new byte[4096];
            try
            {
                while (true)
                {
                    int n = proc.StandardError.BaseStream.Read(chunk, 0, chunk.Length);
                    if (n <= 0) break;
                    Feed("err", Sub(chunk, 0, n));
                }
            }
            catch { }
        });
        terr.IsBackground = true;
        terr.Start();

        if (kind != "posix")
        {
            if (!ev.WaitOne(ReadyTimeoutSec * 1000))
            {
                throw new Exception("远端会话未就绪: " + host);
            }
        }
        else
        {
            Thread.Sleep(150);
            if (proc.HasExited) throw new Exception("远端会话立刻退出: " + host);
        }
    }

    private string BuildSshArgs()
    {
        string[] a = new string[]
        {
            "-T", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
            "-o", "TCPKeepAlive=yes", host, remote
        };
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < a.Length; i++)
        {
            if (i > 0) sb.Append(' ');
            sb.Append(QuoteArg(a[i]));
        }
        return sb.ToString();
    }

    private static string QuoteArg(string s)
    {
        if (s.Length == 0) return "\"\"";
        bool need = false;
        for (int i = 0; i < s.Length; i++)
        {
            char ch = s[i];
            if (ch == ' ' || ch == '\t' || ch == '"') { need = true; break; }
        }
        if (!need) return s;
        return "\"" + s.Replace("\"", "\\\"") + "\"";
    }

    private void Reset()
    {
        bufs = new Dictionary<string, byte[]>();
        bufs["out"] = new byte[0];
        bufs["err"] = new byte[0];
        pending = new HashSet<string>();
        pending.Add("out");
        pending.Add("err");
        outDone = false;
        rc = 0;
    }

    private static byte[] NewTok()
    {
        byte[] b = new byte[8];
        new Random(Guid.NewGuid().GetHashCode()).NextBytes(b);
        return b;
    }

    private static string Hex(byte[] b)
    {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < b.Length; i++) sb.Append(b[i].ToString("x2"));
        return sb.ToString();
    }

    private void Push(object[] item)
    {
        lock (qLock)
        {
            if (q == null) return;
            q.Enqueue(item);
            Monitor.PulseAll(qLock);
        }
    }

    private object[] Take(int timeoutMs)
    {
        lock (qLock)
        {
            if (q.Count == 0)
            {
                if (timeoutMs < 0) { while (q.Count == 0) Monitor.Wait(qLock); }
                else { if (!Monitor.Wait(qLock, timeoutMs)) return null; }
            }
            return (object[])q.Dequeue();
        }
    }

    private void Feed(string stream, byte[] chunk)
    {
        byte[] marker = Encoding.ASCII.GetBytes("__END__" + Hex(tok) + ":");
        lock (bufLock)
        {
            if (q == null) return;
            byte[] buf = Concat(bufs[stream], chunk);
            int idx = IndexOf(buf, marker, 0);
            if (idx < 0)
            {
                int keep = marker.Length - 1;
                if (buf.Length > keep)
                {
                    byte[] emit = Sub(buf, 0, buf.Length - keep);
                    Push(new object[] { stream == "out" ? "O" : "E", emit });
                    buf = Sub(buf, buf.Length - keep, keep);
                }
                bufs[stream] = buf;
                return;
            }
            byte[] outb = Sub(buf, 0, idx);
            if (outb.Length >= 2 && outb[outb.Length - 2] == 13 && outb[outb.Length - 1] == 10)
                outb = Sub(outb, 0, outb.Length - 2);
            else if (outb.Length >= 1 && outb[outb.Length - 1] == 10)
                outb = Sub(outb, 0, outb.Length - 1);
            if (outb.Length > 0) Push(new object[] { stream == "out" ? "O" : "E", outb });

            int p = idx + marker.Length;
            int nl = IndexOf(buf, new byte[] { 10 }, p);
            if (nl < 0)
            {
                bufs[stream] = Sub(buf, idx, buf.Length - idx);
                return;
            }
            string codeS = Encoding.ASCII.GetString(Sub(buf, p, nl - p)).Trim();
            int code = 1;
            try { code = int.Parse(codeS); } catch { code = 1; }
            bufs[stream] = Sub(buf, nl + 1, buf.Length - nl - 1);
            if (stream == "out") { rc = code; outDone = true; }
            pending.Remove(stream);
            if (pending.Count == 0) Push(new object[] { "R", rc });
        }
    }

    private void OnOutDone()
    {
        dead = true;
        lock (bufLock)
        {
            if (q == null) return;
            foreach (string k in new string[] { "out", "err" })
            {
                byte[] b = bufs[k];
                if (b != null && b.Length > 0) Push(new object[] { k == "out" ? "O" : "E", b });
                bufs[k] = new byte[0];
            }
            Push(new object[] { "R", -1 });
        }
    }

    private void SendFrame(NetworkStream ns, byte kindB, byte[] data)
    {
        if (data == null) data = new byte[0];
        int len = data.Length;
        byte[] hdr = new byte[5];
        hdr[0] = kindB;
        hdr[1] = (byte)((len >> 24) & 0xff);
        hdr[2] = (byte)((len >> 16) & 0xff);
        hdr[3] = (byte)((len >> 8) & 0xff);
        hdr[4] = (byte)(len & 0xff);
        ns.Write(hdr, 0, 5);
        if (len > 0) ns.Write(data, 0, len);
        ns.Flush();
    }

    private static byte[] I32(int v)
    {
        return new byte[] { (byte)((v >> 24) & 0xff), (byte)((v >> 16) & 0xff), (byte)((v >> 8) & 0xff), (byte)(v & 0xff) };
    }

    private void RunCommand(string script, NetworkStream ns)
    {
        lock (cmdLock)
        {
            lastUsed = DateTime.UtcNow;
            bool sent = false;
            for (int attempt = 0; attempt < 2; attempt++)
            {
                if (dead)
                {
                    try { Spawn(); }
                    catch (Exception e) { Log("spawn failed: " + e.Message); dead = true; }
                }
                tok = NewTok();
                lock (bufLock) { q = new Queue<object[]>(); Reset(); }
                byte[] line = Encoding.ASCII.GetBytes(Hex(tok) + ":" +
                    Convert.ToBase64String(Encoding.UTF8.GetBytes(script)) + "\n");
                try
                {
                    psin.Write(line, 0, line.Length);
                    psin.Flush();
                    sent = true;
                    break;
                }
                catch (Exception e)
                {
                    Log("write failed (attempt " + attempt + "): " + e.Message + " -> respawn");
                    dead = true;
                    try { proc.Kill(); } catch { }
                }
            }
            if (!sent)
            {
                lock (bufLock) { q = null; }
                try { SendFrame(ns, (byte)'R', I32(1)); } catch { }
                return;
            }
            int code = 1;
            bool clientLost = false;
            try
            {
                while (true)
                {
                    // 1s 一跳：既给 stderr 哨兵留宽限，也用来发现「客户端已经走了」。
                    // 否则远端一条不回的命令会把 keeper 永久卡在 Take 里。
                    object[] item = Take(1000);
                    if (item == null)
                    {
                        if (ClientGone(ns)) { clientLost = true; break; }
                        lock (bufLock) { if (outDone) break; }
                        continue;
                    }
                    if ((string)item[0] == "R") { code = (int)item[1]; break; }
                    SendFrame(ns, (byte)(((string)item[0] == "O") ? 'O' : 'E'), (byte[])item[1]);
                }
            }
            catch (Exception e)
            {
                // 客户端断了：远端可能还在跑，杀掉会话避免协议错位
                Log("client gone -> kill session: " + e.Message);
                dead = true;
                try { proc.Kill(); } catch { }
                lock (bufLock) { q = null; }
                return;
            }
            lock (bufLock) { q = null; }
            if (clientLost)
            {
                // 客户端半途走了：远端可能还在跑，杀掉会话避免下一条命令错位
                Log("client gone -> kill session");
                dead = true;
                try { proc.Kill(); } catch { }
                return;
            }
            try { SendFrame(ns, (byte)'R', I32(code)); }
            catch { dead = true; try { proc.Kill(); } catch { } }
            lastUsed = DateTime.UtcNow;
        }
    }

    private void Shutdown()
    {
        Log("keeper down");
        try { psin.Close(); } catch { }
        try { proc.Kill(); } catch { }
        string mine = "";
        try { mine = Process.GetCurrentProcess().Id.ToString(); } catch { }
        try
        {
            if (File.Exists(pidFile) && File.ReadAllText(pidFile).Trim() != mine) return;
        }
        catch { }
        try { File.Delete(portFile); } catch { }
        try { File.Delete(pidFile); } catch { }
        try { lockStream.Close(); } catch { }
        try { File.Delete(Path.Combine(Path.GetDirectoryName(portFile), host + ".v4.lock")); } catch { }
    }

    private static byte[] Concat(byte[] a, byte[] b)
    {
        byte[] r = new byte[a.Length + b.Length];
        Array.Copy(a, 0, r, 0, a.Length);
        Array.Copy(b, 0, r, a.Length, b.Length);
        return r;
    }

    private static byte[] Sub(byte[] a, int start, int count)
    {
        byte[] r = new byte[count];
        Array.Copy(a, start, r, 0, count);
        return r;
    }

    private static bool ClientGone(NetworkStream ns)
    {
        try
        {
            // 可读但没数据 = 对端已关闭
            return ns.Socket.Poll(0, SelectMode.SelectRead) && ns.Socket.Available == 0;
        }
        catch { return true; }
    }

    private static int IndexOf(byte[] hay, byte[] needle, int from)
    {
        int last = hay.Length - needle.Length;
        for (int i = from; i <= last; i++)
        {
            bool ok = true;
            for (int j = 0; j < needle.Length; j++)
            {
                if (hay[i + j] != needle[j]) { ok = false; break; }
            }
            if (ok) return i;
        }
        return -1;
    }
}
'@

function Show-SessHelp {
    $lines = Get-Content -LiteralPath $PSCommandPath
    foreach ($l in $lines) {
        if ($l -match '^# ?') { $l.Substring(1).TrimStart() }
        elseif ($l -notmatch '^#') { break }
    }
}

function Get-ShkTail([object[]]$Arr, [int]$From) {
    # PowerShell 的切片在越界时行为不友好（$a[1..0] 会倒着取），统一在这里兜住
    if ($Arr.Count -le $From) { return @() }
    return @($Arr[$From..($Arr.Count - 1)])
}

$argv = @($args)
if ($argv.Count -eq 0 -or $argv[0] -in @('-h', '--help', 'help')) {
    Show-SessHelp
    exit 0
}

$op = [string]$argv[0]

if ($op -eq '__keeper') {
    if ($argv.Count -lt 4) { [Console]::Error.WriteLine('sess: __keeper 参数不全'); exit 2 }
    $kHost = [string]$argv[1]
    $kKind = [string]$argv[2]
    $kRemote = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$argv[3]))
    $kCache = Get-ShkCache 'sess'
    # 自己的控制台输出也落日志：keeper 的 stdout/stderr 由拉起的进程重定向，
    # 没人读，任何宿主输出都可能塞满缓冲区把 keeper 卡死。
    # 调试时 SSHKIT_SESS_DEBUG=1，保持前台输出（用于 CI/手工排查）。
    if ($env:SSHKIT_SESS_DEBUG -ne '1') {
        try {
            $kLogPath = Join-Path $kCache ($kHost + '.v4.log')
            $kFs = [System.IO.File]::Open($kLogPath, 'Append', 'Write', 'ReadWrite')
            $kSw = New-Object System.IO.StreamWriter($kFs)
            $kSw.AutoFlush = $true
            [Console]::SetOut($kSw)
            [Console]::SetError($kSw)
        } catch { }
    }
    Add-Type -TypeDefinition $CSharpKeeper -Language CSharp
    $k = New-Object SessKeeper -ArgumentList $kHost, $kKind, $kCache, $kRemote
    $k.Run()
    exit 0
}

if ($op -eq '__remote') {
    # 调试用：打印 kind 与 base64 后的远端命令（可直接喂给 __keeper）
    if ($argv.Count -lt 2) { [Console]::Error.WriteLine('sess: __remote 需要主机名'); exit 2 }
    $rHost = [string]$argv[1]
    $rKind = Get-ShkSessKind $rHost
    [Console]::Out.WriteLine($rKind)
    [Console]::Out.WriteLine((ConvertTo-ShkB64 (Get-ShkSessRemoteCommand $rHost $rKind)))
    exit 0
}

switch ($op) {
    'run' {
        $new = $false
        $verbose = $false
        $rest = Get-ShkTail $argv 1
        while ($rest.Count -gt 0 -and ([string]$rest[0]).StartsWith('-')) {
            if ($rest[0] -eq '--new') { $new = $true }
            elseif ($rest[0] -in @('-v', '--verbose')) { $verbose = $true }
            else { [Console]::Error.WriteLine("sess: 未知选项 $($rest[0])"); exit 2 }
            if ($rest.Count -le 1) { $rest = @() } else { $rest = @($rest[1..($rest.Count - 1)]) }
        }
        if ($rest.Count -lt 2) {
            [Console]::Error.WriteLine("用法: sess run [--new] <host> '<命令>'")
            exit 2
        }
        $h = [string]$rest[0]
        $script = (@($rest[1..($rest.Count - 1)]) -join ' ')
        exit (Invoke-ShkSessRun -HostName $h -Script $script -New:$new -Verbose:$verbose)
    }
    'list' {
        $ss = @(Get-ShkSessSessions)
        if ($ss.Count -eq 0) { [Console]::Out.WriteLine('（没有运行中的会话）'); exit 0 }
        foreach ($s in ($ss | Sort-Object Host)) {
            $state = if ($s.Alive) { '运行中' } else { '已死（残留文件）' }
            [Console]::Out.WriteLine(('{0,-16} {1,-8} {2}' -f $s.Host, $s.Kind, $state))
        }
        exit 0
    }
    'stop' {
        if ($argv.Count -gt 1) {
            Stop-ShkSess -HostName ([string]$argv[1])
        } else {
            $ss = @(Get-ShkSessSessions)
            if ($ss.Count -eq 0) { [Console]::Out.WriteLine('（没有运行中的会话）') }
            foreach ($s in $ss) { Stop-ShkSess -HostName $s.Host }
        }
        exit 0
    }
    'kind' {
        $rest = Get-ShkTail $argv 1
        $reset = $false
        if ($rest -contains '--reset') { $reset = $true; $rest = @($rest | Where-Object { $_ -ne '--reset' }) }
        if ($rest.Count -lt 1) { [Console]::Error.WriteLine('用法: sess kind [--reset] <host>'); exit 2 }
        $k = Get-ShkSessKind -HostName ([string]$rest[0]) -Reset:$reset
        [Console]::Out.WriteLine($k)
        exit 0
    }
    default {
        [Console]::Error.WriteLine("未知子命令: $op")
        exit 2
    }
}

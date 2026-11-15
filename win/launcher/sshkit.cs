// sshkit.exe —— sshkit 的原生启动器（C# 5 / .NET Framework 4.0，Windows 自带运行时）
//
//   sshkit.exe rsh  linux-host 'uname -a'
//   sshkit.exe wsh  win-host  '$PSVersionTable.PSVersion'
//   sshkit.exe sess list
//
// 它做的事只有一件：把子命令转发给同目录的 <verb>.ps1，用 pwsh（没有就用
// Windows PowerShell）跑起来，并原样透传退出码。**PowerShell 仍然在下面跑**，
// 所以省掉的是 ExecutionPolicy / "必须 .ps1" 的门槛，不是那 ~0.4s 启动开销。
//
// 把 exe 改名或做成硬链接（rsh.exe / wsh.exe / sess.exe）时，文件名即子命令，
// 可以当 `rsh.exe host 'cmd'` 这样用。
//
// 输出处理沿用 win/ 里那套踩坑结论：
//   * 父进程捕获输出（stdout 被重定向）时，必须自己重定向并泵字节——
//     .NET 在“不重定向”时 bInheritHandles=FALSE，子进程拿不到调用方的管道，
//     输出会整段丢失；
//   * 真控制台（交互）时不重定向，让 ssh 拿到真 TTY；
//   * 退出码用 Environment.ExitCode 返回，不用 PowerShell 的 exit 语义。
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

internal static class SshkitLauncher
{
    private static readonly string[] Verbs = new string[] { "rsh", "wsh", "sess" };

    private static int Main(string[] args)
    {
        string verb = null;
        string[] rest = args;

        // 以 exe 自己的名字判断子命令（rsh.exe / wsh.exe / sess.exe 的硬链接/副本）
        string self = Path.GetFileNameWithoutExtension(Environment.GetCommandLineArgs()[0]);
        if (self != null)
        {
            string s = self.ToLowerInvariant();
            foreach (string v in Verbs)
            {
                if (s == v) { verb = v; rest = args; break; }
            }
        }

        if (verb == null)
        {
            if (args.Length == 0 || args[0] == "-h" || args[0] == "--help" || args[0] == "/?")
            {
                Usage();
                return args.Length == 0 ? 2 : 0;
            }
            string first = args[0].ToLowerInvariant();
            bool known = false;
            foreach (string v in Verbs) { if (v == first) known = true; }
            if (!known)
            {
                Console.Error.WriteLine("sshkit: 未知子命令 '" + args[0] + "'（只支持 rsh / wsh / sess）");
                return 2;
            }
            verb = first;
            rest = new string[args.Length - 1];
            Array.Copy(args, 1, rest, 0, rest.Length);
        }

        string script = FindScript(verb);
        if (script == null)
        {
            Console.Error.WriteLine("sshkit: 找不到 " + verb + ".ps1");
            Console.Error.WriteLine("        把它放在 sshkit.exe 同目录、上一级 win\\ 目录，或设 SSHKIT_HOME 指向 win 目录");
            return 2;
        }

        string shell = FindPowerShell();
        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = shell;
        psi.UseShellExecute = false;
        StringBuilder cl = new StringBuilder();
        cl.Append("-NoProfile -ExecutionPolicy Bypass -File ").Append(Quote(script));
        for (int i = 0; i < rest.Length; i++) cl.Append(' ').Append(Quote(rest[i]));
        psi.Arguments = cl.ToString();

        bool pumpOut = Console.IsOutputRedirected;
        bool pumpIn = Console.IsInputRedirected;
        if (pumpOut)
        {
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
        }
        if (pumpIn) psi.RedirectStandardInput = true;

        Process p;
        try
        {
            p = Process.Start(psi);
        }
        catch (Exception e)
        {
            Console.Error.WriteLine("sshkit: 启动 " + shell + " 失败: " + e.Message);
            return 127;
        }
        if (p == null)
        {
            Console.Error.WriteLine("sshkit: 启动 " + shell + " 失败");
            return 127;
        }

        Thread tOut = null;
        Thread tErr = null;
        Thread tIn = null;
        Stream outDst = null;
        Stream errDst = null;

        if (pumpOut)
        {
            outDst = Console.OpenStandardOutput();
            errDst = Console.OpenStandardError();
            Stream so = p.StandardOutput.BaseStream;
            Stream se = p.StandardError.BaseStream;
            tOut = new Thread(delegate () { Copy(so, outDst); });
            tErr = new Thread(delegate () { Copy(se, errDst); });
            tOut.IsBackground = true;
            tErr.IsBackground = true;
            tOut.Start();
            tErr.Start();
        }
        if (pumpIn)
        {
            Stream si = Console.OpenStandardInput();
            Stream di = p.StandardInput.BaseStream;
            tIn = new Thread(delegate ()
            {
                Copy(si, di);
                try { di.Close(); } catch { }
            });
            tIn.IsBackground = true;
            tIn.Start();
        }

        p.WaitForExit();
        if (tOut != null) tOut.Join(5000);
        if (tErr != null) tErr.Join(5000);
        try { if (outDst != null) outDst.Flush(); } catch { }
        try { if (errDst != null) errDst.Flush(); } catch { }
        return p.ExitCode;
    }

    private static void Copy(Stream src, Stream dst)
    {
        try
        {
            byte[] buf = new byte[65536];
            while (true)
            {
                int n = src.Read(buf, 0, buf.Length);
                if (n <= 0) break;
                dst.Write(buf, 0, n);
                dst.Flush();
            }
        }
        catch { }
    }

    // 经典 Windows 命令行转义（MSVCRT 规则）
    private static string Quote(string s)
    {
        if (s.Length == 0) return "\"\"";
        bool need = false;
        for (int i = 0; i < s.Length; i++)
        {
            char c = s[i];
            if (c == ' ' || c == '\t' || c == '"' || c == '\n' || c == '\v') { need = true; break; }
        }
        if (!need) return s;
        StringBuilder sb = new StringBuilder();
        sb.Append('"');
        int bs = 0;
        for (int i = 0; i < s.Length; i++)
        {
            char c = s[i];
            if (c == '\\') { bs++; continue; }
            if (c == '"')
            {
                sb.Append('\\', bs * 2 + 1);
                sb.Append('"');
                bs = 0;
                continue;
            }
            if (bs > 0) { sb.Append('\\', bs); bs = 0; }
            sb.Append(c);
        }
        if (bs > 0) sb.Append('\\', bs * 2);
        sb.Append('"');
        return sb.ToString();
    }

    private static string FindScript(string verb)
    {
        string file = verb + ".ps1";
        string exeDir = Path.GetDirectoryName(Process.GetCurrentProcess().MainModule.FileName);
        string home = Environment.GetEnvironmentVariable("SSHKIT_HOME");
        string[] cand = new string[]
        {
            home == null ? null : Path.Combine(home, file),
            Path.Combine(exeDir, file),
            Path.Combine(Path.Combine(exeDir, "win"), file),
            Path.Combine(Path.Combine(Path.GetDirectoryName(exeDir), "win"), file),
            Path.Combine(Path.GetDirectoryName(exeDir), file),
        };
        for (int i = 0; i < cand.Length; i++)
        {
            if (cand[i] != null && File.Exists(cand[i])) return cand[i];
        }
        return null;
    }

    private static string FindPowerShell()
    {
        // 1) PATH 上的 pwsh（PowerShell 7）
        string path = Environment.GetEnvironmentVariable("PATH");
        if (path != null)
        {
            string[] parts = path.Split(';');
            for (int i = 0; i < parts.Length; i++)
            {
                string p = parts[i].Trim();
                if (p.Length == 0) continue;
                string c = Path.Combine(p, "pwsh.exe");
                if (File.Exists(c)) return c;
            }
        }
        // 2) 常见安装位置
        string pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        string c2 = Path.Combine(Path.Combine(pf, "PowerShell"), Path.Combine("7", "pwsh.exe"));
        if (File.Exists(c2)) return c2;
        // 3) 兜底：Windows PowerShell 5.1（Windows 10/11 必有）
        string win = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        string c3 = Path.Combine(win, @"System32\WindowsPowerShell\v1.0\powershell.exe");
        if (File.Exists(c3)) return c3;
        return "powershell.exe";
    }

    private static void Usage()
    {
        Console.WriteLine("sshkit.exe —— sshkit 的原生入口（转发给 rsh.ps1 / wsh.ps1 / sess.ps1）");
        Console.WriteLine();
        Console.WriteLine("  sshkit.exe rsh  <host> ['命令']      POSIX 目标（Linux/macOS/Android）");
        Console.WriteLine("  sshkit.exe wsh  <host> ['命令']      Windows 目标（pwsh / 5.1 / cmd）");
        Console.WriteLine("  sshkit.exe sess <run|list|stop|kind> 常驻会话");
        Console.WriteLine();
        Console.WriteLine("也可以把本程序复制/硬链接成 rsh.exe、wsh.exe、sess.exe 直接使用。");
        Console.WriteLine("脚本查找顺序：$SSHKIT_HOME → exe 同目录 → 同目录 win\\ → 上一级 win\\");
        Console.WriteLine("注意：本程序内部仍然启动 PowerShell，启动开销与直接跑 .ps1 相同。");
    }
}

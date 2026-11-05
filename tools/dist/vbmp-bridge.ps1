# VBMP 联机桥接：把游戏的联机文件通过 TCP 接到另一台电脑。
#
# 游戏里的 VBMP 把要发的包写进 Saved\VBMP_link_A2B.bin（房主）或 VBMP_link_B2A.bin（客户端），
# 从另一个文件读对方的包（帧格式：2 字节小端长度 + 内容）。这个脚本在每台电脑上运行一份：
# 把本机写出的帧发给对方，把收到的帧追加进本机的接收文件。只转发完整的帧。
#
#   房主：  vbmp-bridge.ps1 -Role host            （监听 TCP 端口，默认 27777）
#   客户端：vbmp-bridge.ps1 -Role client -HostAddr <房主的地址>
#
# 为什么不用 Steam：游戏自带的 SteamCore 插件里，SteamID 是没有反射字段的结构体，
# 经过 UE4SS 的 Lua 以后会变成 0，从 Lua 发不出 Steam P2P 包（2026-11-05 实测）。
param(
    [ValidateSet('host', 'client')][string]$Role = 'host',
    [string]$HostAddr,
    [int]$Port = 27777,
    [string]$Dir = (Join-Path $env:LOCALAPPDATA 'VOIDBREAKER\Saved')
)
$ErrorActionPreference = 'Stop'

$code = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Threading;

public static class VbmpBridge
{
    static string outPath, inPath;

    static void Log(string s) { Console.WriteLine(DateTime.Now.ToString("HH:mm:ss") + "  " + s); }

    static long FileLen(string p)
    {
        try { var fi = new FileInfo(p); return fi.Exists ? fi.Length : 0; } catch { return 0; }
    }

    static byte[] ReadRange(string p, long from, long count)
    {
        try
        {
            using (var fs = new FileStream(p, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                if (fs.Length < from + count) count = Math.Max(0, fs.Length - from);
                fs.Seek(from, SeekOrigin.Begin);
                var buf = new byte[count];
                int got = 0;
                while (got < count)
                {
                    int n = fs.Read(buf, got, (int)(count - got));
                    if (n <= 0) break;
                    got += n;
                }
                if (got < count) Array.Resize(ref buf, got);
                return buf;
            }
        }
        catch { return new byte[0]; }
    }

    static void Append(string p, byte[] data, int count)
    {
        for (int i = 0; i < 50; i++)
        {
            try
            {
                using (var fs = new FileStream(p, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete))
                    fs.Write(data, 0, count);
                return;
            }
            catch (IOException) { Thread.Sleep(2); }
        }
        Log("cannot write " + p);
    }

    // Length in bytes of the complete frames at the start of buf[0..len).
    static int CompleteFrames(byte[] buf, int len, out int frames)
    {
        int pos = 0; frames = 0;
        while (len - pos >= 2)
        {
            int n = buf[pos] | (buf[pos + 1] << 8);
            if (len - pos < 2 + n) break;
            pos += 2 + n; frames++;
        }
        return pos;
    }

    // Offset of the last frame boundary in the file: stale frames are skipped on connect, and
    // starting on a boundary keeps the stream aligned.
    static long LastBoundary(string p)
    {
        long len = FileLen(p);
        byte[] all = ReadRange(p, 0, len);
        int frames;
        return CompleteFrames(all, all.Length, out frames);
    }

    static void PrintAddresses(int port)
    {
        Log("房主地址（把其中一个告诉朋友，端口 " + port + "）：");
        try
        {
            foreach (var a in Dns.GetHostAddresses(Dns.GetHostName()))
            {
                if (IPAddress.IsLoopback(a)) continue;
                if (a.AddressFamily == AddressFamily.InterNetworkV6 && (a.IsIPv6LinkLocal || a.IsIPv6SiteLocal)) continue;
                Log("    " + a.ToString());
            }
        }
        catch (Exception e) { Log("    (读取本机地址失败：" + e.Message + ")"); }
        Log("  虚拟局域网（Tailscale 100.x / ZeroTier / Radmin 26.x）的地址也在上面。");
    }

    static TcpClient Connect(string host, int port)
    {
        host = host.Trim().Trim('[', ']');
        IPAddress addr;
        if (!IPAddress.TryParse(host, out addr))
        {
            var list = Dns.GetHostAddresses(host);
            if (list.Length == 0) throw new Exception("找不到地址 " + host);
            addr = list[0];
        }
        var c = new TcpClient(addr.AddressFamily);
        c.Connect(addr, port);
        return c;
    }

    static void Pump(TcpClient c)
    {
        var s = c.GetStream();
        long outOffset = LastBoundary(outPath);
        var pending = new List<byte>();
        byte[] rbuf = new byte[65536];
        byte[] inBuf = new byte[1 << 20];
        int inLen = 0;
        long framesOut = 0, framesIn = 0, bytesOut = 0, bytesIn = 0;
        DateTime report = DateTime.Now.AddSeconds(10);
        while (true)
        {
            bool idle = true;

            long len = FileLen(outPath);
            if (len < outOffset) { outOffset = 0; pending.Clear(); Log("游戏重新开始了联机（发送文件被清空）"); }
            if (len > outOffset)
            {
                byte[] data = ReadRange(outPath, outOffset, len - outOffset);
                outOffset += data.Length;
                pending.AddRange(data);
                byte[] arr = pending.ToArray();
                int frames;
                int whole = CompleteFrames(arr, arr.Length, out frames);
                if (whole > 0)
                {
                    s.Write(arr, 0, whole);
                    pending.RemoveRange(0, whole);
                    framesOut += frames; bytesOut += whole;
                }
                idle = false;
            }

            if (c.Client.Poll(0, SelectMode.SelectRead))
            {
                int n = s.Read(rbuf, 0, rbuf.Length);
                if (n <= 0) throw new IOException("对方断开了");
                if (inLen + n > inBuf.Length) Array.Resize(ref inBuf, Math.Max(inBuf.Length * 2, inLen + n));
                Buffer.BlockCopy(rbuf, 0, inBuf, inLen, n);
                inLen += n;
                int frames;
                int whole = CompleteFrames(inBuf, inLen, out frames);
                if (whole > 0)
                {
                    Append(inPath, inBuf, whole);
                    Buffer.BlockCopy(inBuf, whole, inBuf, 0, inLen - whole);
                    inLen -= whole;
                    framesIn += frames; bytesIn += whole;
                }
                idle = false;
            }

            if (DateTime.Now > report)
            {
                report = DateTime.Now.AddSeconds(10);
                Log(string.Format("已连接  发出 {0} 包 / {1} KB   收到 {2} 包 / {3} KB", framesOut, bytesOut / 1024, framesIn, bytesIn / 1024));
            }
            if (idle) Thread.Sleep(2);
        }
    }

    public static void Run(string role, string hostAddr, int port, string dir)
    {
        Directory.CreateDirectory(dir);
        outPath = Path.Combine(dir, role == "host" ? "VBMP_link_A2B.bin" : "VBMP_link_B2A.bin");
        inPath = Path.Combine(dir, role == "host" ? "VBMP_link_B2A.bin" : "VBMP_link_A2B.bin");
        Log("VBMP 联机桥接（" + (role == "host" ? "房主" : "客户端") + "）  文件夹 " + dir);
        TcpListener listener = null;
        if (role == "host")
        {
            listener = new TcpListener(IPAddress.IPv6Any, port);
            listener.Server.DualMode = true;
            listener.Start();
            PrintAddresses(port);
        }
        while (true)
        {
            TcpClient c = null;
            try
            {
                if (role == "host") { Log("等待朋友连接……"); c = listener.AcceptTcpClient(); }
                else { Log("正在连接 " + hostAddr + " 端口 " + port + " ……"); c = Connect(hostAddr, port); }
                c.NoDelay = true;
                c.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true);
                Log("已连上 " + c.Client.RemoteEndPoint + "。现在可以在游戏里开房 / 加入了（不要关这个窗口）");
                Pump(c);
            }
            catch (Exception e) { Log("连接中断：" + e.Message); }
            finally { if (c != null) c.Close(); }
            if (role == "client") { Log("2 秒后重连"); Thread.Sleep(2000); }
        }
    }
}
'@

if ($Role -eq 'client' -and -not $HostAddr) {
    $HostAddr = Read-Host '房主的地址（房主的桥接窗口里列出的那些，例如 100.101.102.103）'
}
Add-Type -TypeDefinition $code -Language CSharp
[Console]::Title = "VBMP 联机桥接 - $Role"
[VbmpBridge]::Run($Role, $HostAddr, $Port, $Dir)

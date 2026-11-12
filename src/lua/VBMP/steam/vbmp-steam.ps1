# VBMP Steam P2P 辅助进程：游戏里的 VBMP 开房 / 加入时自动启动（main.lua），不用手动运行。
#
# 为什么要单独一个进程：游戏自带的 SteamCore 插件里，SteamID 是没有反射字段的结构体，经过
# UE4SS 的 Lua 以后变成 0（2026-11-05 实测，docs/networking.md）。这里直接加载游戏自带的
# steam_api64.dll（Steamworks SDK 1.61），在同一个 Steam 账号、同一个 appid 下用真正的
# 64 位 SteamID 收发 P2P 包。和游戏之间用已经测通的通道文件交换（帧 = 2 字节小端长度 + 内容）：
#   房主写 VBMP_link_A2B.bin、读 VBMP_link_B2A.bin；客户端相反。
#
# Steam 接口（全部核对过 steam_api64.dll 的导出表和 Steamworks.NET 的签名）：
#   SteamInternal_SteamAPI_Init(versions, errmsg[1024]) / SteamAPI_ManualDispatch_*
#   SteamUser023.GetSteamID, SteamFriends017.{GetPersonaName, GetFriendCount, GetFriendByIndex,
#   GetFriendRelationship, GetFriendPersonaName, GetFriendRichPresence, SetRichPresence,
#   ClearRichPresence, GetFriendGamePlayed}, SteamNetworking006.{SendP2PPacket,
#   IsP2PPacketAvailable, ReadP2PPacket, AcceptP2PSessionWithUser, AllowP2PPacketRelay}
#   回调 P2PSessionRequest_t = 1202、P2PSessionConnectFail_t = 1203（k_iSteamNetworkingCallbacks 1200）
#
# 发现：房主设置 rich presence vbmp=host，客户端设置 vbmp=client。客户端在好友里找 vbmp=host 的人；
# 找不到时，如果只有一个好友正在玩 VOID/BREAKER（appid 2615540），就连他。
# 房主只接受好友（EFriendRelationship 3）的会话请求。所有包走可靠通道（和 TCP 桥接一样有序可靠）。
#
#   -Role probe   诊断：打印自己的 SteamID、好友数，给自己发一个包
#   -Role host / client -Token <t>   正常运行；Saved\VBMP_steam_session.txt 的内容不再是 "<Role> <t>"
#                                    或者游戏进程退出时，自动退出
param(
    [ValidateSet('host', 'client', 'probe', 'list')][string]$Role = 'probe',
    [string]$Token = '',
    [string]$Dir = (Join-Path $env:LOCALAPPDATA 'VOIDBREAKER\Saved'),
    [string]$HostId = '',
    [string]$Dll = '',
    # Steam app id the helper runs as: 480 (Spacewar, Steam's test app, usable by every account).
    # Under the game's own id (2615540) the helper shares P2P with the game process: with the
    # game running, a P2P packet the helper sent to itself never arrived (5 s), as 480 it arrived
    # in 1 s (2026-11-06); the first real two-account join got no answer at all under 2615540.
    # Both players must use the same id (rich presence and P2P are per app).
    [int]$AppId = 480
)
$ErrorActionPreference = 'Stop'

if (-not $Dll) {
    # <game>\VOIDBREAKER\Binaries\Win64\ue4ss\Mods\VBMP\steam\ -> <game>\Engine\Binaries\ThirdParty\Steamworks\
    $d = $PSScriptRoot
    for ($i = 0; $i -lt 9 -and $d; $i++) {
        $cand = Get-ChildItem (Join-Path $d 'Engine\Binaries\ThirdParty\Steamworks') -Recurse -Filter steam_api64.dll -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cand) { $Dll = $cand.FullName; break }
        $d = Split-Path $d
    }
}
if (-not $Dll -or -not (Test-Path $Dll)) { throw "steam_api64.dll not found (game folder)" }

$code = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class VbmpSteam
{
    const string D = "steam_api64.dll";
    [DllImport("kernel32", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr LoadLibrary(string path);

    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern int SteamInternal_SteamAPI_Init(byte[] versions, IntPtr errMsg);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern void SteamAPI_Shutdown();
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern int SteamAPI_GetHSteamPipe();
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern void SteamAPI_ManualDispatch_Init();
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern void SteamAPI_ManualDispatch_RunFrame(int pipe);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] static extern bool SteamAPI_ManualDispatch_GetNextCallback(int pipe, IntPtr msg);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern void SteamAPI_ManualDispatch_FreeLastCallback(int pipe);

    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr SteamAPI_SteamUser_v023();
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr SteamAPI_SteamFriends_v017();
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr SteamAPI_SteamNetworking_v006();

    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern ulong SteamAPI_ISteamUser_GetSteamID(IntPtr self);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr SteamAPI_ISteamFriends_GetPersonaName(IntPtr self);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern int SteamAPI_ISteamFriends_GetFriendCount(IntPtr self, int flags);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern ulong SteamAPI_ISteamFriends_GetFriendByIndex(IntPtr self, int i, int flags);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern int SteamAPI_ISteamFriends_GetFriendRelationship(IntPtr self, ulong id);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr SteamAPI_ISteamFriends_GetFriendPersonaName(IntPtr self, ulong id);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr SteamAPI_ISteamFriends_GetFriendRichPresence(IntPtr self, ulong id, byte[] key);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] static extern bool SteamAPI_ISteamFriends_SetRichPresence(IntPtr self, byte[] key, byte[] value);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern void SteamAPI_ISteamFriends_ClearRichPresence(IntPtr self);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] static extern bool SteamAPI_ISteamFriends_GetFriendGamePlayed(IntPtr self, ulong id, byte[] info24);

    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] static extern bool SteamAPI_ISteamNetworking_SendP2PPacket(IntPtr self, ulong to, byte[] data, uint len, int sendType, int channel);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] static extern bool SteamAPI_ISteamNetworking_IsP2PPacketAvailable(IntPtr self, out uint size, int channel);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] static extern bool SteamAPI_ISteamNetworking_ReadP2PPacket(IntPtr self, byte[] dest, uint cap, out uint size, out ulong from, int channel);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] static extern bool SteamAPI_ISteamNetworking_AcceptP2PSessionWithUser(IntPtr self, ulong id);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] static extern bool SteamAPI_ISteamNetworking_GetP2PSessionState(IntPtr self, ulong id, byte[] state20);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] static extern bool SteamAPI_ISteamNetworking_AllowP2PPacketRelay(IntPtr self, [MarshalAs(UnmanagedType.I1)] bool allow);

    const int FRIEND_IMMEDIATE = 0x04, REL_FRIEND = 3, SEND_RELIABLE = 2, APPID = 2615540;   // the game (appmanifest)
    public static int P2PAppId = APPID;   // what the helper initialises Steam as (-AppId)
    public static string Version = "";    // Mods/VBMP/version.txt; published as rich presence vbmpver (0.9.2+)
    const int CB_SESSION_REQUEST = 1202, CB_CONNECT_FAIL = 1203;
    const int MAX_PACKET = 60000;

    static IntPtr user, friends, net;
    static int pipe;
    static ulong me;
    static string myName = "";
    static string dir, statusPath, sessionPath, outPath, inPath, role, token;
    static readonly List<string> status = new List<string>();
    static readonly Dictionary<ulong, string> peers = new Dictionary<ulong, string>();
    static long framesOut, framesIn, bytesOut, bytesIn;

    static byte[] Z(string s) { return Encoding.UTF8.GetBytes(s + "\0"); }
    static string S(IntPtr p)
    {
        if (p == IntPtr.Zero) return "";
        int n = 0; while (Marshal.ReadByte(p, n) != 0) n++;
        var b = new byte[n]; Marshal.Copy(p, b, 0, n); return Encoding.UTF8.GetString(b);
    }
    static string logPath;
    static void Log(string s)
    {
        string line = DateTime.Now.ToString("HH:mm:ss") + "  " + s;
        Console.WriteLine(line);
        if (logPath != null) try { File.AppendAllText(logPath, line + "\r\n", new UTF8Encoding(false)); } catch { }
    }
    static string Name(ulong id) { return S(SteamAPI_ISteamFriends_GetFriendPersonaName(friends, id)); }

    static void WriteStatus(string state, string detail)
    {
        if (statusPath == null) return;
        var sb = new StringBuilder();
        sb.Append("state=").Append(state).Append('\n');
        sb.Append("detail=").Append(detail).Append('\n');
        sb.Append("me=").Append(myName).Append('\n');
        foreach (var kv in peers) sb.Append("peer=").Append(kv.Value).Append('\n');
        sb.Append(string.Format("traffic=out {0} / {1} KB, in {2} / {3} KB\n", framesOut, bytesOut / 1024, framesIn, bytesIn / 1024));
        try { File.WriteAllText(statusPath, sb.ToString(), new UTF8Encoding(false)); } catch { }
    }

    static bool Init()
    {
        Environment.SetEnvironmentVariable("SteamAppId", P2PAppId.ToString());
        Environment.SetEnvironmentVariable("SteamGameId", P2PAppId.ToString());
        SteamAPI_ManualDispatch_Init();
        IntPtr err = Marshal.AllocHGlobal(1024);
        Marshal.WriteByte(err, 0, 0);
        int r = SteamInternal_SteamAPI_Init(Encoding.ASCII.GetBytes("SteamUser023\0SteamFriends017\0SteamNetworking006\0\0"), err);
        string msg = S(err);
        Marshal.FreeHGlobal(err);
        if (r != 0) { Log("Steam 初始化失败（" + r + "）：" + msg); WriteStatus("error", "Steam 初始化失败：" + msg); return false; }
        user = SteamAPI_SteamUser_v023();
        friends = SteamAPI_SteamFriends_v017();
        net = SteamAPI_SteamNetworking_v006();
        pipe = SteamAPI_GetHSteamPipe();
        me = SteamAPI_ISteamUser_GetSteamID(user);
        myName = S(SteamAPI_ISteamFriends_GetPersonaName(friends));
        SteamAPI_ISteamNetworking_AllowP2PPacketRelay(net, true);
        Log("Steam 已初始化：" + myName + "（SteamID 共 " + me.ToString().Length + " 位，appid " + P2PAppId + "）");
        return true;
    }

    static int callbacksLogged = 0;
    static readonly HashSet<ulong> seenSenders = new HashSet<ulong>();
    static readonly HashSet<ulong> knocked = new HashSet<ulong>();
    static readonly byte[] KNOCK = new byte[] { 0xFF };   // 1 byte: never a valid frame (2-byte length + payload)
    static readonly byte[] BYE = KNOCK;   // client -> host: "I am leaving". 0xFF, because hosts before 0.9.1 ignore it (0xFE would land in their data stream)
    // Host: when each peer was last heard. A peer silent for PEER_TIMEOUT is forgotten, so the
    // same friend (or another) can join again. Before 0.9.1 a peer was never removed: after
    // leaving once, the friend could not rejoin until the host stopped hosting (2026-11-13: the
    // client sent 58 packets, got 0; the host had stopped knocking because its list was full).
    static readonly Dictionary<ulong, DateTime> heard = new Dictionary<ulong, DateTime>();
    const double PEER_TIMEOUT = 10;

    // Host, every 2 s: accept and knock on every friend whose presence says vbmp=client. Sending
    // to a user opens the session from our side, so this does not depend on the
    // P2PSessionRequest_t callback reaching this process (the game process runs SteamAPI for the
    // same app and user too; first real test 2026-11-06: the client sent 80+ packets, the host's
    // helper never reported anything).
    static void KnockOnJoiners()
    {
        int n = SteamAPI_ISteamFriends_GetFriendCount(friends, FRIEND_IMMEDIATE);
        for (int i = 0; i < n; i++)
        {
            ulong f = SteamAPI_ISteamFriends_GetFriendByIndex(friends, i, FRIEND_IMMEDIATE);
            if (S(SteamAPI_ISteamFriends_GetFriendRichPresence(friends, f, Z("vbmp"))) != "client") continue;
            SteamAPI_ISteamNetworking_AcceptP2PSessionWithUser(net, f);
            bool ok = SteamAPI_ISteamNetworking_SendP2PPacket(net, f, KNOCK, 1, SEND_RELIABLE, 0);
            if (knocked.Add(f)) Log("主动连接想加入的好友 " + Name(f) + "（发送" + (ok ? "成功" : "失败") + "）");
        }
    }

    static void IgnoreRequest(ulong remote) { }

    // P2PSessionState_t: uint8 active, connecting, error, usingRelay; int32 bytesQueued, packetsQueued;
    // uint32 remoteIP; uint16 remotePort (20 bytes)
    static string SessionState(ulong id)
    {
        var st = new byte[20];
        if (!SteamAPI_ISteamNetworking_GetP2PSessionState(net, id, st)) return "没有会话";
        return string.Format("活动 {0}，正在连接 {1}，错误 {2}，中继 {3}，排队 {4} 包", st[0], st[1], st[2], st[3], BitConverter.ToInt32(st, 8));
    }

    // Returns the remote ids of P2P session requests seen this frame (accepted or not).
    static void Dispatch(Action<ulong> onRequest)
    {
        SteamAPI_ManualDispatch_RunFrame(pipe);
        IntPtr msg = Marshal.AllocHGlobal(24);   // CallbackMsg_t: int user, int id, uint8* param, int size (pack 8)
        try
        {
            while (SteamAPI_ManualDispatch_GetNextCallback(pipe, msg))
            {
                int id = Marshal.ReadInt32(msg, 4);
                IntPtr param = Marshal.ReadIntPtr(msg, 8);
                if (callbacksLogged < 40) { callbacksLogged++; Log("Steam 回调 " + id); }
                if (id == CB_SESSION_REQUEST && param != IntPtr.Zero)
                {
                    ulong remote = (ulong)Marshal.ReadInt64(param, 0);
                    if (onRequest != null) onRequest(remote);
                }
                else if (id == CB_CONNECT_FAIL && param != IntPtr.Zero)
                {
                    ulong remote = (ulong)Marshal.ReadInt64(param, 0);
                    int e = Marshal.ReadByte(param, 8);
                    Log("P2P 连接失败：" + Name(remote) + "，错误 " + e);
                }
                SteamAPI_ManualDispatch_FreeLastCallback(pipe);
            }
        }
        finally { Marshal.FreeHGlobal(msg); }
    }

    // ---------------------------------------------------------------- link files

    static long FileLen(string p) { try { var fi = new FileInfo(p); return fi.Exists ? fi.Length : 0; } catch { return 0; } }
    static byte[] ReadRange(string p, long from, long count)
    {
        try
        {
            using (var fs = new FileStream(p, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                if (fs.Length < from + count) count = Math.Max(0, fs.Length - from);
                fs.Seek(from, SeekOrigin.Begin);
                var buf = new byte[count]; int got = 0;
                while (got < count) { int n = fs.Read(buf, got, (int)(count - got)); if (n <= 0) break; got += n; }
                if (got < count) Array.Resize(ref buf, got);
                return buf;
            }
        }
        catch { return new byte[0]; }
    }
    static void Append(string p, byte[] data, int off, int count)
    {
        for (int i = 0; i < 50; i++)
        {
            try { using (var fs = new FileStream(p, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete)) fs.Write(data, off, count); return; }
            catch (IOException) { Thread.Sleep(2); }
        }
        Log("写不进 " + p);
    }
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
    static long LastBoundary(string p)
    {
        byte[] all = ReadRange(p, 0, FileLen(p)); int f;
        return CompleteFrames(all, all.Length, out f);
    }

    static bool SessionWanted()
    {
        try { return File.ReadAllText(sessionPath).Trim() == role + " " + token; } catch { return false; }
    }
    static bool GameRunning()
    {
        return Process.GetProcessesByName("VOIDBREAKER-Win64-Shipping").Length > 0;
    }

    // ---------------------------------------------------------------- probe

    public static int Probe(string d)
    {
        if (!Init()) return 1;
        int n = SteamAPI_ISteamFriends_GetFriendCount(friends, FRIEND_IMMEDIATE);
        int inGame = 0, vbmp = 0;
        var info = new byte[24];
        for (int i = 0; i < n; i++)
        {
            ulong f = SteamAPI_ISteamFriends_GetFriendByIndex(friends, i, FRIEND_IMMEDIATE);
            if (SteamAPI_ISteamFriends_GetFriendGamePlayed(friends, f, info) && (BitConverter.ToUInt64(info, 0) & 0xFFFFFF) == APPID) inGame++;
            if (S(SteamAPI_ISteamFriends_GetFriendRichPresence(friends, f, Z("vbmp"))) != "") vbmp++;
        }
        Log("好友 " + n + " 个，正在玩 VOID/BREAKER 的 " + inGame + " 个，开着 VBMP 的 " + vbmp + " 个");
        bool rp = SteamAPI_ISteamFriends_SetRichPresence(friends, Z("vbmp"), Z("probe"));
        Log("设置 rich presence：" + rp + "，读回自己的：'" + S(SteamAPI_ISteamFriends_GetFriendRichPresence(friends, me, Z("vbmp"))) + "'");
        bool sent = SteamAPI_ISteamNetworking_SendP2PPacket(net, me, new byte[] { 86, 66, 1, 2, 3 }, 5, SEND_RELIABLE, 0);
        Log("给自己发包：" + sent);
        var buf = new byte[MAX_PACKET];
        var until = DateTime.Now.AddSeconds(5);
        bool got = false;
        while (DateTime.Now < until && !got)
        {
            Dispatch(delegate (ulong r) { Log("收到会话请求（来自自己：" + (r == me) + "）"); SteamAPI_ISteamNetworking_AcceptP2PSessionWithUser(net, r); });
            uint size;
            while (SteamAPI_ISteamNetworking_IsP2PPacketAvailable(net, out size, 0))
            {
                uint len; ulong from;
                if (SteamAPI_ISteamNetworking_ReadP2PPacket(net, buf, (uint)buf.Length, out len, out from, 0))
                { Log("收到 " + len + " 字节，来自自己：" + (from == me)); got = true; }
            }
            Thread.Sleep(20);
        }
        if (!got) Log("5 秒内没收到自己发的包");
        SteamAPI_ISteamFriends_ClearRichPresence(friends);
        SteamAPI_Shutdown();
        return 0;
    }

    // ---------------------------------------------------------------- list (main-menu panel)

    // Writes Saved\VBMP_steam_hosts.txt: "host\t<id>\t<name>" for friends hosting VBMP, then
    // "playing\t<id>\t<name>" for friends in VOID/BREAKER without VBMP; first line "ok" or "error\t<msg>".
    public static int List(string d)
    {
        string path = Path.Combine(d, "VBMP_steam_hosts.txt");
        string tmp = path + ".tmp";
        var sb = new StringBuilder();
        if (!Init()) { File.WriteAllText(path, "error\tSteam 初始化失败\n", new UTF8Encoding(false)); return 1; }
        sb.Append("ok\n");
        int n = SteamAPI_ISteamFriends_GetFriendCount(friends, FRIEND_IMMEDIATE);
        var info = new byte[24];
        var playing = new StringBuilder();
        for (int i = 0; i < n; i++)
        {
            ulong f = SteamAPI_ISteamFriends_GetFriendByIndex(friends, i, FRIEND_IMMEDIATE);
            string rp = S(SteamAPI_ISteamFriends_GetFriendRichPresence(friends, f, Z("vbmp")));
            string name = Name(f).Replace("\t", " ").Replace("\n", " ");
            if (rp == "host") sb.Append("host\t").Append(f).Append('\t').Append(name).Append('\n');
            else if (SteamAPI_ISteamFriends_GetFriendGamePlayed(friends, f, info) && (BitConverter.ToUInt64(info, 0) & 0xFFFFFF) == APPID)
                playing.Append("playing\t").Append(f).Append('\t').Append(name).Append('\n');
        }
        sb.Append(playing.ToString());
        File.WriteAllText(tmp, sb.ToString(), new UTF8Encoding(false));
        if (File.Exists(path)) File.Delete(path);
        File.Move(tmp, path);
        SteamAPI_Shutdown();
        return 0;
    }

    // ---------------------------------------------------------------- host / client

    static ulong FindHost(string fixedHost)
    {
        ulong fixedId;
        if (ulong.TryParse(fixedHost, out fixedId) && fixedId != 0) return fixedId;
        int n = SteamAPI_ISteamFriends_GetFriendCount(friends, FRIEND_IMMEDIATE);
        var playing = new List<ulong>();
        var info = new byte[24];
        for (int i = 0; i < n; i++)
        {
            ulong f = SteamAPI_ISteamFriends_GetFriendByIndex(friends, i, FRIEND_IMMEDIATE);
            if (S(SteamAPI_ISteamFriends_GetFriendRichPresence(friends, f, Z("vbmp"))) == "host") return f;
            if (SteamAPI_ISteamFriends_GetFriendGamePlayed(friends, f, info) && (BitConverter.ToUInt64(info, 0) & 0xFFFFFF) == APPID) playing.Add(f);
        }
        return playing.Count == 1 ? playing[0] : 0;
    }

    public static int Run(string r, string t, string d, string fixedHost)
    {
        role = r; token = t; dir = d;
        Directory.CreateDirectory(dir);
        logPath = Path.Combine(dir, "VBMP_steam.log");
        try { if (FileLen(logPath) > (1 << 20)) File.Delete(logPath); } catch { }
        Log("---- VBMP Steam " + role);
        statusPath = Path.Combine(dir, "VBMP_steam_status.txt");
        sessionPath = Path.Combine(dir, "VBMP_steam_session.txt");
        bool host = role == "host";
        outPath = Path.Combine(dir, host ? "VBMP_link_A2B.bin" : "VBMP_link_B2A.bin");
        inPath = Path.Combine(dir, host ? "VBMP_link_B2A.bin" : "VBMP_link_A2B.bin");
        if (!Init()) return 1;
        SteamAPI_ISteamFriends_SetRichPresence(friends, Z("vbmp"), Z(host ? "host" : "client"));
        if (Version != "") SteamAPI_ISteamFriends_SetRichPresence(friends, Z("vbmpver"), Z(Version));
        string hostVer = "";
        DateTime foundAt = DateTime.MinValue;
        WriteStatus(host ? "hosting" : "searching", host ? "等待好友加入" : "正在找开房的好友");
        Log(host ? "开房中：好友加入时会自动连上" : "正在好友里找开房的人……");

        long outOffset = LastBoundary(outPath);
        var pending = new List<byte>();
        var buf = new byte[1 << 20];
        var inBuf = new byte[1 << 20]; int inLen = 0;
        ulong hostId = 0;
        DateTime nextScan = DateTime.MinValue, nextCheck = DateTime.MinValue, nextReport = DateTime.Now.AddSeconds(10), nextStatus = DateTime.MinValue;
        ulong lastSender = 0;

        while (true)
        {
            if (DateTime.Now > nextCheck)
            {
                nextCheck = DateTime.Now.AddSeconds(1);
                if (!SessionWanted()) { Log("游戏结束了这次联机，退出"); break; }
                if (!GameRunning()) { Log("游戏已退出，退出"); break; }
                if (host)
                {
                    foreach (var p in new List<ulong>(peers.Keys))
                    {
                        DateTime seen;
                        if (heard.TryGetValue(p, out seen) && (DateTime.Now - seen).TotalSeconds > PEER_TIMEOUT)
                        {
                            Log(peers[p] + " " + PEER_TIMEOUT + " 秒没有消息，当作已离开");
                            peers.Remove(p); heard.Remove(p); knocked.Remove(p);
                            inLen = 0; lastSender = 0;
                        }
                    }
                }
            }
            bool idle = true;

            Dispatch(delegate (ulong remote)
            {
                if (host)
                {
                    if (SteamAPI_ISteamFriends_GetFriendRelationship(friends, remote) == REL_FRIEND)
                    {
                        SteamAPI_ISteamNetworking_AcceptP2PSessionWithUser(net, remote);
                        Log("接受了 " + Name(remote) + " 的连接");
                    }
                    else Log("拒绝了非好友的连接请求");
                }
                else if (remote == hostId) SteamAPI_ISteamNetworking_AcceptP2PSessionWithUser(net, remote);
            });

            if (host && peers.Count == 0 && DateTime.Now > nextScan)
            {
                nextScan = DateTime.Now.AddSeconds(2);
                try { KnockOnJoiners(); } catch (Exception e) { Log("主动连接出错：" + e.Message); }
            }

            if (!host && hostId == 0 && DateTime.Now > nextScan)
            {
                nextScan = DateTime.Now.AddSeconds(2);
                hostId = FindHost(fixedHost);
                if (hostId != 0)
                {
                    SteamAPI_ISteamNetworking_AcceptP2PSessionWithUser(net, hostId);
                    peers[hostId] = Name(hostId);
                    outOffset = LastBoundary(outPath); pending.Clear();
                    foundAt = DateTime.Now;
                    hostVer = S(SteamAPI_ISteamFriends_GetFriendRichPresence(friends, hostId, Z("vbmpver")));
                    Log("找到房主：" + peers[hostId] + "（房主的 VBMP " + (hostVer != "" ? hostVer : "是 0.9.1 或更早，没有版本信息") + "，我的 " + Version + "）");
                    WriteStatus("connecting", "找到房主 " + peers[hostId]);
                }
                else WriteStatus("searching", "没有找到开房的好友（房主要先开房；双方必须是 Steam 好友）");
            }

            // outgoing: whole frames from our link file, reliable, to the host / every client
            long len = FileLen(outPath);
            if (len < outOffset) { outOffset = 0; pending.Clear(); }
            if (len > outOffset)
            {
                byte[] data = ReadRange(outPath, outOffset, Math.Min(len - outOffset, 4 << 20));
                outOffset += data.Length;
                pending.AddRange(data);
                idle = false;
            }
            if (pending.Count > 0 && peers.Count > 0)
            {
                byte[] arr = pending.ToArray();
                int frames; int whole = CompleteFrames(arr, Math.Min(arr.Length, MAX_PACKET), out frames);
                if (whole == 0 && arr.Length >= 2) whole = CompleteFrames(arr, arr.Length, out frames) > 0 ? 2 + (arr[0] | (arr[1] << 8)) : 0;
                if (whole > 0)
                {
                    var pkt = new byte[whole]; Array.Copy(arr, pkt, whole);
                    foreach (var p in peers.Keys)
                        if (!SteamAPI_ISteamNetworking_SendP2PPacket(net, p, pkt, (uint)whole, SEND_RELIABLE, 0)) Log("发送失败");
                    pending.RemoveRange(0, whole);
                    framesOut += frames > 0 ? frames : 1; bytesOut += whole;
                }
            }
            else if (pending.Count > 0 && peers.Count == 0)
            {
                // nobody to send to yet: drop whole frames (HELLO is resent every second anyway)
                byte[] arr = pending.ToArray(); int f; int whole = CompleteFrames(arr, arr.Length, out f);
                pending.RemoveRange(0, whole);
            }

            // incoming
            uint size;
            while (SteamAPI_ISteamNetworking_IsP2PPacketAvailable(net, out size, 0))
            {
                if (size > buf.Length) buf = new byte[size];
                uint got; ulong from;
                if (!SteamAPI_ISteamNetworking_ReadP2PPacket(net, buf, (uint)buf.Length, out got, out from, 0)) break;
                idle = false;
                if (seenSenders.Add(from))
                    Log(string.Format("第一次收到 {0} 的包：{1} 字节，好友关系 {2}", Name(from), got,
                        SteamAPI_ISteamFriends_GetFriendRelationship(friends, from)));
                if (host && got == 1 && buf[0] == 0xFF)
                {
                    if (peers.ContainsKey(from)) { Log(peers[from] + " 离开了"); peers.Remove(from); heard.Remove(from); inLen = 0; lastSender = 0; }
                    knocked.Remove(from);
                    continue;
                }
                if (got == 1 && buf[0] == 0xFF)
                {
                    // the host's knock (see KnockOnJoiners): opens the session, carries no data
                    if (!host && from == hostId && knocked.Add(from)) Log("收到房主的连接");
                    continue;
                }
                if (host)
                {
                    if (!peers.ContainsKey(from))
                    {
                        int rel = SteamAPI_ISteamFriends_GetFriendRelationship(friends, from);
                        if (rel != REL_FRIEND) { if (knocked.Add(from)) Log("忽略非好友 " + Name(from) + " 的包（好友关系 " + rel + "）"); continue; }
                        if (peers.Count >= 1) { Log("已经有一个队友了，忽略 " + Name(from)); continue; }
                        peers[from] = Name(from);
                        outOffset = LastBoundary(outPath); pending.Clear();
                        inLen = 0;
                        Log(peers[from] + " 连上了");
                        WriteStatus("connected", peers[from] + " 已连上");
                    }
                }
                else
                {
                    if (from != hostId) { if (knocked.Add(from)) Log("忽略不是房主的 " + Name(from) + " 发来的包"); continue; }
                    if (lastSender != hostId) { Log("和房主连上了"); WriteStatus("connected", "已连上房主 " + peers[hostId]); }
                }
                lastSender = from;
                if (host) heard[from] = DateTime.Now;
                if (inLen + (int)got > inBuf.Length) Array.Resize(ref inBuf, Math.Max(inBuf.Length * 2, inLen + (int)got));
                Buffer.BlockCopy(buf, 0, inBuf, inLen, (int)got); inLen += (int)got;
                int frames; int whole = CompleteFrames(inBuf, inLen, out frames);
                if (whole > 0)
                {
                    Append(inPath, inBuf, 0, whole);
                    Buffer.BlockCopy(inBuf, whole, inBuf, 0, inLen - whole); inLen -= whole;
                    framesIn += frames; bytesIn += whole;
                }
            }

            if (DateTime.Now > nextStatus)
            {
                nextStatus = DateTime.Now.AddSeconds(2);
                string state = peers.Count > 0 && lastSender != 0 ? "connected" : (host ? "hosting" : (hostId != 0 ? "connecting" : "searching"));
                string detail = state == "connected" ? "已连上 " + string.Join("、", peers.Values) : (host ? "等待好友加入" : (hostId != 0 ? "正在连接房主 " + peers[hostId] : "没有找到开房的好友（房主要先开房；双方必须是 Steam 好友）"));
                if (state == "connecting" && bytesIn == 0 && (DateTime.Now - foundAt).TotalSeconds > 20)
                    detail = hostVer == ""
                        ? "房主 " + peers[hostId] + " 没有回应：他的 VBMP 是旧版本。请他重启游戏两次更新到最新版，再重新开房"
                        : "房主 " + peers[hostId] + " 没有回应：请他点 [离开联机] 再 [继续并开房]，然后你重新加入";
                WriteStatus(state, detail);
            }
            if (DateTime.Now > nextReport)
            {
                nextReport = DateTime.Now.AddSeconds(10);
                Log(string.Format("发出 {0} 包 / {1} KB   收到 {2} 包 / {3} KB", framesOut, bytesOut / 1024, framesIn, bytesIn / 1024)
                    + (!host && hostId != 0 && bytesIn == 0 ? "   会话：" + SessionState(hostId) : ""));
            }
            if (idle) Thread.Sleep(2);
        }
        // tell the host we are gone, so it can take us (or someone else) again at once
        if (!host && hostId != 0)
        {
            for (int i = 0; i < 3; i++) SteamAPI_ISteamNetworking_SendP2PPacket(net, hostId, BYE, 1, SEND_RELIABLE, 0);
            for (int i = 0; i < 25; i++) { Dispatch(new Action<ulong>(IgnoreRequest)); Thread.Sleep(20); }   // let it go out before shutdown
        }
        WriteStatus("stopped", "联机已结束");
        SteamAPI_ISteamFriends_ClearRichPresence(friends);
        SteamAPI_Shutdown();
        return 0;
    }

    public static void Load(string dll)
    {
        if (LoadLibrary(dll) == IntPtr.Zero) throw new Exception("LoadLibrary failed: " + dll + " (" + Marshal.GetLastWin32Error() + ")");
    }
}
'@

Add-Type -TypeDefinition $code -Language CSharp
[VbmpSteam]::Load($Dll)
[VbmpSteam]::P2PAppId = $AppId
$verFile = Join-Path (Split-Path $PSScriptRoot) 'version.txt'
if (Test-Path $verFile) { [VbmpSteam]::Version = (Get-Content $verFile -Raw).Trim() }
try { [Console]::Title = "VBMP Steam 联机 - $Role（不要关）" } catch { }
if ($Role -eq 'probe') { exit [VbmpSteam]::Probe($Dir) }
if ($Role -eq 'list') { exit [VbmpSteam]::List($Dir) }
exit [VbmpSteam]::Run($Role, $Token, $Dir, $HostId)

# Runs ON the gaming PC, in the desktop session (Steam lives there; see run_desktop.ps1).
# Read-only Steam check for a join that hangs: initialises Steam as app 480 (like the VBMP helper),
# then writes to -Out, for every friend with VBMP rich presence (or the one named -Friend):
# all rich presence keys, persona state, the app Steam says they are playing, and the
# ISteamNetworking P2P session state to them; plus our own vbmp presence.
# Sends nothing and sets no rich presence.
param(
    [string]$Friend = '',
    [string]$Out = (Join-Path $env:LOCALAPPDATA 'VOIDBREAKER\Saved\VBMP_steam_diag.txt'),
    [int]$AppId = 480
)
$ErrorActionPreference = 'Stop'
$dll = 'C:\D\steamapps\common\VOIDBREAKER\Engine\Binaries\ThirdParty\Steamworks'
$dll = (Get-ChildItem $dll -Recurse -Filter steam_api64.dll | Select-Object -First 1).FullName

$code = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
public static class SteamDiag
{
    const string D = "steam_api64.dll";
    [DllImport("kernel32", CharSet = CharSet.Unicode)] static extern IntPtr LoadLibrary(string p);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern int SteamInternal_SteamAPI_Init(byte[] v, IntPtr err);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern void SteamAPI_Shutdown();
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern int SteamAPI_GetHSteamPipe();
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern void SteamAPI_ManualDispatch_Init();
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern void SteamAPI_ManualDispatch_RunFrame(int pipe);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] static extern bool SteamAPI_ManualDispatch_GetNextCallback(int pipe, IntPtr msg);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern void SteamAPI_ManualDispatch_FreeLastCallback(int pipe);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr SteamAPI_SteamUser_v023();
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr SteamAPI_SteamFriends_v017();
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr SteamAPI_SteamNetworking_v006();
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern ulong SteamAPI_ISteamUser_GetSteamID(IntPtr s);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern int SteamAPI_ISteamFriends_GetFriendCount(IntPtr s, int f);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern ulong SteamAPI_ISteamFriends_GetFriendByIndex(IntPtr s, int i, int f);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr SteamAPI_ISteamFriends_GetFriendPersonaName(IntPtr s, ulong id);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern int SteamAPI_ISteamFriends_GetFriendPersonaState(IntPtr s, ulong id);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern int SteamAPI_ISteamFriends_GetFriendRelationship(IntPtr s, ulong id);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern void SteamAPI_ISteamFriends_RequestFriendRichPresence(IntPtr s, ulong id);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern int SteamAPI_ISteamFriends_GetFriendRichPresenceKeyCount(IntPtr s, ulong id);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr SteamAPI_ISteamFriends_GetFriendRichPresenceKeyByIndex(IntPtr s, ulong id, int i);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr SteamAPI_ISteamFriends_GetFriendRichPresence(IntPtr s, ulong id, byte[] key);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] static extern bool SteamAPI_ISteamFriends_GetFriendGamePlayed(IntPtr s, ulong id, byte[] info24);
    [DllImport(D, CallingConvention = CallingConvention.Cdecl)] [return: MarshalAs(UnmanagedType.I1)] static extern bool SteamAPI_ISteamNetworking_GetP2PSessionState(IntPtr s, ulong id, byte[] st20);

    static string S(IntPtr p) { if (p == IntPtr.Zero) return ""; int n = 0; while (Marshal.ReadByte(p, n) != 0) n++; var b = new byte[n]; Marshal.Copy(p, b, 0, n); return Encoding.UTF8.GetString(b); }
    static byte[] Z(string s) { return Encoding.UTF8.GetBytes(s + "\0"); }

    public static string Run(string dll, int appId, string only)
    {
        var o = new StringBuilder();
        LoadLibrary(dll);
        Environment.SetEnvironmentVariable("SteamAppId", appId.ToString());
        Environment.SetEnvironmentVariable("SteamGameId", appId.ToString());
        SteamAPI_ManualDispatch_Init();
        IntPtr err = Marshal.AllocHGlobal(1024); Marshal.WriteByte(err, 0, 0);
        int r = SteamInternal_SteamAPI_Init(Encoding.ASCII.GetBytes("SteamUser023\0SteamFriends017\0SteamNetworking006\0\0"), err);
        if (r != 0) return "init failed " + r + ": " + S(err);
        IntPtr user = SteamAPI_SteamUser_v023(), fr = SteamAPI_SteamFriends_v017(), net = SteamAPI_SteamNetworking_v006();
        int pipe = SteamAPI_GetHSteamPipe();
        ulong me = SteamAPI_ISteamUser_GetSteamID(user);
        int n = SteamAPI_ISteamFriends_GetFriendCount(fr, 4);
        for (int i = 0; i < n; i++) SteamAPI_ISteamFriends_RequestFriendRichPresence(fr, SteamAPI_ISteamFriends_GetFriendByIndex(fr, i, 4));
        IntPtr msg = Marshal.AllocHGlobal(24);
        for (int t = 0; t < 60; t++)
        {
            SteamAPI_ManualDispatch_RunFrame(pipe);
            while (SteamAPI_ManualDispatch_GetNextCallback(pipe, msg)) SteamAPI_ManualDispatch_FreeLastCallback(pipe);
            Thread.Sleep(50);
        }
        o.AppendLine("me: vbmp='" + S(SteamAPI_ISteamFriends_GetFriendRichPresence(fr, me, Z("vbmp"))) + "' friends=" + n);
        for (int i = 0; i < n; i++)
        {
            ulong f = SteamAPI_ISteamFriends_GetFriendByIndex(fr, i, 4);
            string name = S(SteamAPI_ISteamFriends_GetFriendPersonaName(fr, f));
            int kc = SteamAPI_ISteamFriends_GetFriendRichPresenceKeyCount(fr, f);
            bool vb = S(SteamAPI_ISteamFriends_GetFriendRichPresence(fr, f, Z("vbmp"))) != "";
            if (only != "" ? name != only : !vb) continue;
            o.AppendLine("friend '" + name + "' relationship=" + SteamAPI_ISteamFriends_GetFriendRelationship(fr, f) + " personaState=" + SteamAPI_ISteamFriends_GetFriendPersonaState(fr, f));
            for (int k = 0; k < kc; k++)
            {
                string key = S(SteamAPI_ISteamFriends_GetFriendRichPresenceKeyByIndex(fr, f, k));
                o.AppendLine("  rp " + key + " = " + S(SteamAPI_ISteamFriends_GetFriendRichPresence(fr, f, Z(key))));
            }
            var gi = new byte[24];
            if (SteamAPI_ISteamFriends_GetFriendGamePlayed(fr, f, gi)) o.AppendLine("  playing appid " + (BitConverter.ToUInt64(gi, 0) & 0xFFFFFF));
            else o.AppendLine("  playing nothing (per Steam)");
            var st = new byte[20];
            if (SteamAPI_ISteamNetworking_GetP2PSessionState(net, f, st))
                o.AppendLine(string.Format("  p2p (this process): active {0} connecting {1} error {2} relay {3} queuedBytes {4} queuedPackets {5}", st[0], st[1], st[2], st[3], BitConverter.ToInt32(st, 4), BitConverter.ToInt32(st, 8)));
            else o.AppendLine("  p2p (this process): no session");
        }
        SteamAPI_Shutdown();
        return o.ToString();
    }
}
'@
Add-Type -TypeDefinition $code -Language CSharp
$text = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "`r`n" + [SteamDiag]::Run($dll, $AppId, $Friend)
[IO.File]::WriteAllText($Out, $text, (New-Object Text.UTF8Encoding($false)))

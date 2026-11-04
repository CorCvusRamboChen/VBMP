# List every file path in the game's .pak and IoStore (.utoc) containers, read-only.
# Decrypts the pak full directory index and the utoc directory index with the key in
# %USERPROFILE%\vbmp\aes_key.txt and writes one "container<TAB>size<TAB>path" line per file
# to %USERPROFILE%\vbmp\filelist.tsv. Asset contents are never read.
$ErrorActionPreference = 'Stop'
$paks = 'C:\D\steamapps\common\VOIDBREAKER\VOIDBREAKER\Content\Paks'
$keyHex = (Get-Content (Join-Path $env:USERPROFILE 'vbmp\aes_key.txt') -Raw).Trim() -replace '^0x', ''
$key = New-Object byte[] 32
for ($i = 0; $i -lt 32; $i++) { $key[$i] = [Convert]::ToByte($keyHex.Substring($i * 2, 2), 16) }
$out = Join-Path $env:USERPROFILE 'vbmp\filelist.tsv'

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Security.Cryptography;

public class VbReader {
    byte[] b; public int P;
    public VbReader(byte[] data) { b = data; }
    public int I32() { int v = BitConverter.ToInt32(b, P); P += 4; return v; }
    public uint U32() { uint v = BitConverter.ToUInt32(b, P); P += 4; return v; }
    public long I64() { long v = BitConverter.ToInt64(b, P); P += 8; return v; }
    public void Skip(int n) { P += n; }
    public string FStr() {
        int len = I32();
        if (len == 0) return "";
        string s;
        // pak v12 (Utf8PakDirectory) strings carry no terminator, so read the full length and trim.
        if (len > 0) { s = Encoding.UTF8.GetString(b, P, len); P += len; }
        else { s = Encoding.Unicode.GetString(b, P, -len * 2); P += -len * 2; }
        return s.TrimEnd('\0');
    }
}

public static class VbList {
    public static byte[] Decrypt(byte[] key, byte[] data) {
        using (var aes = Aes.Create()) {
            aes.Mode = CipherMode.ECB; aes.Padding = PaddingMode.None; aes.Key = key;
            using (var t = aes.CreateDecryptor()) return t.TransformFinalBlock(data, 0, data.Length);
        }
    }

    static byte[] ReadAt(FileStream fs, long off, long size) {
        var buf = new byte[size];
        fs.Seek(off, SeekOrigin.Begin);
        int got = 0;
        while (got < size) { int n = fs.Read(buf, got, (int)(size - got)); if (n <= 0) throw new IOException("short read"); got += n; }
        return buf;
    }

    static long Align16(long n) { return (n + 15) & ~15L; }

    // .pak v12: footer -> primary index -> full directory index (dir -> file -> entry).
    public static List<string> Pak(string path, byte[] key) {
        var lines = new List<string>();
        using (var fs = File.OpenRead(path)) {
            var tail = ReadAt(fs, fs.Length - 400, 400);
            int m = -1;
            for (int i = 396; i >= 0; i--) if (tail[i] == 0xE1 && tail[i+1] == 0x12 && tail[i+2] == 0x6F && tail[i+3] == 0x5A) { m = i; break; }
            if (m < 0) throw new Exception("pak magic not found");
            bool enc = tail[m - 1] != 0;
            long idxOff = BitConverter.ToInt64(tail, m + 8), idxSize = BitConverter.ToInt64(tail, m + 16);
            var idx = ReadAt(fs, idxOff, idxSize);
            if (enc) idx = Decrypt(key, idx);
            var r = new VbReader(idx);
            string mount = r.FStr();
            int numEntries = r.I32();
            r.Skip(8);                       // PathHashSeed
            if (r.I32() != 0) r.Skip(8 + 8 + 20);   // path hash index
            if (r.I32() == 0) throw new Exception("pak has no full directory index");
            long dirOff = r.I64(), dirSize = r.I64();
            var dir = ReadAt(fs, dirOff, enc ? Align16(dirSize) : dirSize);
            if (enc) dir = Decrypt(key, dir);
            var d = new VbReader(dir);
            int nDirs = d.I32();
            for (int i = 0; i < nDirs; i++) {
                string dn = d.FStr();
                int nFiles = d.I32();
                for (int j = 0; j < nFiles; j++) {
                    string fn = d.FStr();
                    d.I32();
                    lines.Add("pak\t-\t" + (mount + dn + fn).Replace("../../../", "/"));
                }
            }
            lines.Insert(0, "#pak mount=" + mount + " entries=" + numEntries + " dirs=" + nDirs);
        }
        return lines;
    }

    // .utoc v8: header (144 bytes) -> skip tables -> directory index resource.
    public static List<string> Utoc(string path, string tag, byte[] key) {
        var lines = new List<string>();
        var all = File.ReadAllBytes(path);
        var h = new VbReader(all);
        h.P = 16; int version = all[16];
        h.P = 20;
        uint hdrSize = h.U32(), entryCount = h.U32(), cbCount = h.U32(), cbSize = h.U32();
        uint cmCount = h.U32(), cmLen = h.U32(); h.U32(); uint dirIdxSize = h.U32();
        byte flags = all[80];
        uint seedsCount = BitConverter.ToUInt32(all, 84);
        uint noPerfect = BitConverter.ToUInt32(all, 96);
        long p = hdrSize;
        long chunkIds = p; p += 12L * entryCount;
        long offLens = p; p += 10L * entryCount;
        if (version >= 4) p += 4L * seedsCount;
        if (version >= 5) p += 4L * noPerfect;
        p += (long)cbSize * cbCount;
        p += (long)cmCount * cmLen;
        if ((flags & 4) != 0) { int hs = BitConverter.ToInt32(all, (int)p); p += 4 + 2L * hs + 20L * cbCount; }
        if ((flags & 8) == 0 || dirIdxSize == 0) { lines.Add("#" + tag + " not indexed"); return lines; }
        var di = new byte[dirIdxSize];
        Array.Copy(all, p, di, 0, dirIdxSize);
        if ((flags & 2) != 0) di = Decrypt(key, di);
        var r = new VbReader(di);
        string mount = r.FStr();
        int nd = r.I32(); var dirs = new uint[nd, 4];
        for (int i = 0; i < nd; i++) for (int k = 0; k < 4; k++) dirs[i, k] = r.U32();
        int nf = r.I32(); var files = new uint[nf, 3];
        for (int i = 0; i < nf; i++) for (int k = 0; k < 3; k++) files[i, k] = r.U32();
        int ns = r.I32(); var strs = new string[ns];
        for (int i = 0; i < ns; i++) strs[i] = r.FStr();
        const uint NONE = 0xFFFFFFFF;
        var stack = new Stack<KeyValuePair<uint, string>>();
        stack.Push(new KeyValuePair<uint, string>(0, mount.Replace("../../../", "/")));
        while (stack.Count > 0) {
            var cur = stack.Pop();
            uint di0 = cur.Key; string basePath = cur.Value;
            for (uint f = dirs[di0, 3]; f != NONE; f = files[f, 1]) {
                uint toc = files[f, 2];
                long len = 0;
                if (toc < entryCount) {
                    long o = offLens + 10L * toc + 5;
                    for (int k = 0; k < 5; k++) len = (len << 8) | all[o + k];
                }
                lines.Add(tag + "\t" + len + "\t" + basePath + strs[files[f, 0]]);
            }
            for (uint c = dirs[di0, 1]; c != NONE; c = dirs[c, 2])
                stack.Push(new KeyValuePair<uint, string>(c, basePath + strs[dirs[c, 0]] + "/"));
        }
        lines.Insert(0, "#" + tag + " tocVersion=" + version + " flags=" + flags + " entries=" + entryCount + " mount=" + mount + " files=" + nf);
        return lines;
    }
}
'@

$lines = New-Object 'System.Collections.Generic.List[string]'
Get-ChildItem $paks -Filter *.pak | ForEach-Object { $lines.AddRange([VbList]::Pak($_.FullName, $key)) }
Get-ChildItem $paks -Filter *.utoc | ForEach-Object { $lines.AddRange([VbList]::Utoc($_.FullName, $_.BaseName, $key)) }
[IO.File]::WriteAllLines($out, $lines)
$lines | Where-Object { $_.StartsWith('#') }
"total lines: $($lines.Count) -> $out"

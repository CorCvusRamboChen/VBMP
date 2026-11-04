# Find the pak AES-256 key in the shipping exe and prove it by decrypting the pak index.
# UE bakes the key into a callback as eight `mov dword ptr [reg+N], imm32` (N = 0..0x1C);
# we collect those runs, then keep only a candidate that turns the encrypted index into a
# readable mount point. The key is written to %USERPROFILE%\vbmp\aes_key.txt (never the repo);
# only a short fingerprint is printed.
$ErrorActionPreference = 'Stop'
$root = 'C:\D\steamapps\common\VOIDBREAKER'
$exe = Join-Path $root 'VOIDBREAKER\Binaries\Win64\VOIDBREAKER-Win64-Shipping.exe'
$pak = Join-Path $root 'VOIDBREAKER\Content\Paks\VOIDBREAKER-Windows.pak'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Security.Cryptography;

public static class VbKey {
    static bool Decode(byte[] d, int i, out int reg, out int off, out int imm) {
        reg = -1; off = -1; imm = 0;
        if (i + 7 > d.Length || d[i] != 0xC7) return false;
        int modrm = d[i + 1];
        int mod = modrm >> 6, op = (modrm >> 3) & 7, rm = modrm & 7;
        if (op != 0 || rm == 4) return false;
        int rex = (i > 0 && (d[i - 1] & 0xF0) == 0x40) ? (d[i - 1] & 1) : 0;
        reg = rm + rex * 8;
        if (mod == 0) {
            if (rm == 5) return false;
            off = 0; imm = BitConverter.ToInt32(d, i + 2);
        } else if (mod == 1) {
            off = d[i + 2]; imm = BitConverter.ToInt32(d, i + 3);
        } else return false;
        return off <= 0x1C && off % 4 == 0;
    }

    public static List<byte[]> Candidates(byte[] d) {
        var result = new List<byte[]>();
        var seen = new HashSet<string>();
        for (int i = 1; i < d.Length - 8; i++) {
            int reg, off, imm;
            if (!Decode(d, i, out reg, out off, out imm) || off != 0) continue;
            var key = new byte[32];
            var have = new bool[8];
            int lo = Math.Max(1, i - 160), hi = Math.Min(d.Length - 8, i + 200);
            for (int j = lo; j < hi; j++) {
                int r2, o2, v2;
                if (!Decode(d, j, out r2, out o2, out v2) || r2 != reg || have[o2 / 4]) continue;
                have[o2 / 4] = true;
                Array.Copy(BitConverter.GetBytes(v2), 0, key, o2, 4);
            }
            if (Array.IndexOf(have, false) >= 0) continue;
            var distinct = new HashSet<byte>(key);
            if (distinct.Count < 16) continue;
            string hex = BitConverter.ToString(key);
            if (seen.Add(hex)) result.Add(key);
        }
        return result;
    }

    // Fallback for keys the compiler folded into SSE constants: every 4-aligned 32-byte
    // window that looks random is tried directly against the encrypted index block.
    public static byte[] BruteWindows(byte[] d, byte[] block, int minDistinct, out int tested) {
        tested = 0;
        var key = new byte[32];
        var counts = new int[256];
        using (var aes = Aes.Create()) {
            aes.Mode = CipherMode.ECB; aes.Padding = PaddingMode.None;
            for (int i = 0; i + 32 <= d.Length; i += 4) {
                Array.Clear(counts, 0, 256);
                int distinct = 0;
                for (int k = 0; k < 32; k++) if (counts[d[i + k]]++ == 0) distinct++;
                if (distinct < minDistinct) continue;
                Array.Copy(d, i, key, 0, 32);
                tested++;
                aes.Key = key;
                byte[] p;
                using (var t = aes.CreateDecryptor()) p = t.TransformFinalBlock(block, 0, 16);
                int len = BitConverter.ToInt32(p, 0);
                if (len > 0 && len < 512 && p[4] == 0x2E && p[5] == 0x2E && p[6] == 0x2F && p[7] == 0x2E) {
                    return (byte[])key.Clone();
                }
            }
        }
        return null;
    }

    // Keys emitted as two RIP-relative 16-byte SSE loads (movups/movaps/movdqu/movdqa xmmN,[rip+d])
    // or as four `movabs r64, imm64`. Both halves need not be adjacent in .rdata.
    public static List<byte[]> SseAndQwordCandidates(byte[] d) {
        var result = new List<byte[]>();
        var seen = new HashSet<string>();
        int pe = BitConverter.ToInt32(d, 0x3C);
        int nsec = BitConverter.ToUInt16(d, pe + 6);
        int opt = BitConverter.ToUInt16(d, pe + 20);
        int sec = pe + 24 + opt;
        var va = new long[nsec]; var vs = new long[nsec]; var rp = new long[nsec]; var rs = new long[nsec];
        for (int s = 0; s < nsec; s++) {
            int o = sec + s * 40;
            vs[s] = BitConverter.ToUInt32(d, o + 8); va[s] = BitConverter.ToUInt32(d, o + 12);
            rs[s] = BitConverter.ToUInt32(d, o + 16); rp[s] = BitConverter.ToUInt32(d, o + 20);
        }
        Func<long, long> offToRva = off => {
            for (int s = 0; s < nsec; s++) if (off >= rp[s] && off < rp[s] + rs[s]) return off - rp[s] + va[s];
            return -1;
        };
        Func<long, long> rvaToOff = rva => {
            for (int s = 0; s < nsec; s++) if (rva >= va[s] && rva < va[s] + Math.Min(vs[s], rs[s])) return rva - va[s] + rp[s];
            return -1;
        };

        // 1) SSE loads: collect (fileOffset, constOffset) for every RIP-relative 16-byte load.
        var loads = new List<long[]>();
        for (int i = 0; i + 8 < d.Length; i++) {
            int p = i, len;
            if (d[p] == 0x0F && (d[p + 1] == 0x10 || d[p + 1] == 0x28)) { p += 2; len = 2; }
            else if ((d[p] == 0xF3 || d[p] == 0x66) && d[p + 1] == 0x0F && d[p + 2] == 0x6F) { p += 3; len = 3; }
            else continue;
            int modrm = d[p];
            if ((modrm & 0xC7) != 0x05) continue;
            int disp = BitConverter.ToInt32(d, p + 1);
            long rva = offToRva(i);
            if (rva < 0) continue;
            long target = rvaToOff(rva + len + 5 + disp);
            if (target < 0 || target + 16 > d.Length) continue;
            loads.Add(new long[] { i, target });
        }
        for (int a = 0; a < loads.Count; a++) {
            for (int b = a + 1; b < loads.Count && loads[b][0] - loads[a][0] < 64; b++) {
                foreach (var order in new[] { new[] { a, b }, new[] { b, a } }) {
                    var key = new byte[32];
                    Array.Copy(d, loads[order[0]][1], key, 0, 16);
                    Array.Copy(d, loads[order[1]][1], key, 16, 16);
                    if (new HashSet<byte>(key).Count < 20) continue;
                    if (seen.Add(BitConverter.ToString(key))) result.Add(key);
                }
            }
        }

        // 2) movabs runs: four imm64 within 96 bytes, tried in every order.
        var imms = new List<long[]>();
        for (int i = 0; i + 10 < d.Length; i++) {
            if ((d[i] == 0x48 || d[i] == 0x49) && d[i + 1] >= 0xB8 && d[i + 1] <= 0xBF) {
                imms.Add(new long[] { i, BitConverter.ToInt64(d, i + 2) });
            }
        }
        var perms = new List<int[]>();
        for (int x = 0; x < 4; x++) for (int y = 0; y < 4; y++) for (int z = 0; z < 4; z++) for (int w = 0; w < 4; w++)
            if (x != y && x != z && x != w && y != z && y != w && z != w) perms.Add(new[] { x, y, z, w });
        for (int a = 0; a + 3 < imms.Count; a++) {
            if (imms[a + 3][0] - imms[a][0] > 96) continue;
            foreach (var pm in perms) {
                var key = new byte[32];
                for (int q = 0; q < 4; q++) Array.Copy(BitConverter.GetBytes(imms[a + pm[q]][1]), 0, key, q * 8, 8);
                if (new HashSet<byte>(key).Count < 20) continue;
                if (seen.Add(BitConverter.ToString(key))) result.Add(key);
            }
        }
        return result;
    }

    // Generalised imm32 stores: any base (incl. [rsp+disp] via SIB, [rbp+disp]) and any start
    // offset, as when the key is first built in a local array and then copied out.
    public static List<byte[]> StackCandidates(byte[] d) {
        var result = new List<byte[]>();
        var seen = new HashSet<string>();
        var pos = new List<int>(); var bas = new List<int>(); var dsp = new List<int>(); var val = new List<int>();
        for (int i = 1; i + 11 < d.Length; i++) {
            if (d[i] != 0xC7) continue;
            int modrm = d[i + 1];
            int mod = modrm >> 6, op = (modrm >> 3) & 7, rm = modrm & 7;
            if (op != 0 || mod == 3) continue;
            int rex = ((d[i - 1] & 0xF0) == 0x40) ? (d[i - 1] & 1) : 0;
            int p = i + 2, b = rm;
            if (rm == 4) { int sib = d[p]; if (((sib >> 3) & 7) != 4) continue; b = sib & 7; p++; }
            else if (mod == 0 && rm == 5) continue;
            int disp;
            if (mod == 0) disp = 0;
            else if (mod == 1) { disp = (sbyte)d[p]; p++; }
            else { disp = BitConverter.ToInt32(d, p); p += 4; }
            pos.Add(i); bas.Add(b + rex * 8 + (rm == 4 ? 100 : 0)); dsp.Add(disp); val.Add(BitConverter.ToInt32(d, p));
        }
        int lo = 0;
        for (int a = 0; a < pos.Count; a++) {
            while (pos[lo] < pos[a] - 300) lo++;
            var map = new Dictionary<int, int>();
            for (int j = lo; j < pos.Count && pos[j] < pos[a] + 300; j++)
                if (bas[j] == bas[a] && !map.ContainsKey(dsp[j])) map[dsp[j]] = val[j];
            int d0 = dsp[a];
            var key = new byte[32];
            bool ok = true;
            for (int k = 0; k < 8 && ok; k++) {
                int v;
                if (!map.TryGetValue(d0 + 4 * k, out v)) ok = false;
                else Array.Copy(BitConverter.GetBytes(v), 0, key, 4 * k, 4);
            }
            if (!ok || new HashSet<byte>(key).Count < 16) continue;
            if (seen.Add(BitConverter.ToString(key))) result.Add(key);
        }
        return result;
    }

    public static byte[] FirstValid(List<byte[]> keys, byte[] block) {
        foreach (var k in keys) {
            var p = Decrypt16(k, block);
            int len = BitConverter.ToInt32(p, 0);
            if (len > 0 && len < 512 && p[4] == 0x2E && p[5] == 0x2E && p[6] == 0x2F && p[7] == 0x2E) return k;
        }
        return null;
    }

    public static byte[] Decrypt16(byte[] key, byte[] block) {
        using (var aes = Aes.Create()) {
            aes.Mode = CipherMode.ECB; aes.Padding = PaddingMode.None; aes.Key = key;
            using (var t = aes.CreateDecryptor()) return t.TransformFinalBlock(block, 0, 16);
        }
    }
}
'@

# Pak footer -> encrypted index location.
$fs = [IO.File]::OpenRead($pak)
$n = 400
[void]$fs.Seek(-$n, 'End')
$tail = New-Object byte[] $n
[void]$fs.Read($tail, 0, $n)
$m = -1
for ($i = $n - 4; $i -ge 0; $i--) {
    if ($tail[$i] -eq 0xE1 -and $tail[$i+1] -eq 0x12 -and $tail[$i+2] -eq 0x6F -and $tail[$i+3] -eq 0x5A) { $m = $i; break }
}
if ($m -lt 0) { throw 'pak footer magic not found' }
$indexOffset = [BitConverter]::ToInt64($tail, $m + 8)
$indexSize = [BitConverter]::ToInt64($tail, $m + 16)
[void]$fs.Seek($indexOffset, 'Begin')
$block = New-Object byte[] 16
[void]$fs.Read($block, 0, 16)
$fs.Close()
Write-Output "pak index: offset=$indexOffset size=$indexSize"

Write-Output 'scanning exe for key-building code...'
$bytes = [IO.File]::ReadAllBytes($exe)
$cands = [VbKey]::Candidates($bytes)
Write-Output "mov-imm32 candidates: $($cands.Count)"
$more = [VbKey]::SseAndQwordCandidates($bytes)
Write-Output "sse/movabs candidates: $($more.Count)"
$cands.AddRange($more)
$stack = [VbKey]::StackCandidates($bytes)
Write-Output "stack/any-base imm32 candidates: $($stack.Count)"
$cands.AddRange($stack)

$good = [VbKey]::FirstValid($cands, $block)

if (-not $good) {
    Write-Output 'mov-imm candidates failed; trying high-entropy 32-byte windows...'
    $tested = 0
    $good = [VbKey]::BruteWindows($bytes, $block, 26, [ref]$tested)
    Write-Output "windows tested: $tested"
}

if (-not $good) {
    Write-Output 'NO candidate decrypted the pak index (key may be obfuscated; next step: dynamic dump at runtime).'
    exit 1
}

$hex = '0x' + (($good | ForEach-Object { $_.ToString('X2') }) -join '')
$dir = Join-Path $env:USERPROFILE 'vbmp'
New-Item -ItemType Directory -Force $dir | Out-Null
Set-Content -Path (Join-Path $dir 'aes_key.txt') -Value $hex -Encoding ascii
$sha = [Security.Cryptography.SHA256]::Create().ComputeHash($good)
$fp = (($sha[0..3] | ForEach-Object { $_.ToString('x2') }) -join '')
Write-Output "VERIFIED: key decrypts pak index to mount point '../../../' (len field=$([BitConverter]::ToInt32([VbKey]::Decrypt16($good, $block), 0)))"
Write-Output "saved to $dir\aes_key.txt  (sha256 fingerprint $fp)"

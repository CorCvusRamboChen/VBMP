-- VBMP wire format. Every packet: header + body, packed with string.pack (little endian).
--   header  "<c2BBi8"  magic "VB", protocol version, message type, sender SteamID64
-- The sender id travels in the header because SteamCore's ReadP2PPacket returns the remote
-- id as an opaque FSteamID that Lua cannot read (no reflected fields).
-- See docs/networking.md for the message list.

local M = {}

M.VERSION = 1
M.T = {
    HELLO = 1,    -- client -> host   "<I4s1"   build id, player name
    WELCOME = 2,  -- host -> client   "<s1"     host name
    REJECT = 3,   -- host -> client   "<s1"     reason
    STATE = 4,    -- any              "<dfffffB" sender clock, x, y, z, yaw, pitch, flags
    LEVEL = 5,    -- any              "<s2"     persistent level name
    PING = 6,     -- any              "<d"      sender clock
    PONG = 7,     -- any              "<d"      echoed clock
    BYE = 8,      -- any              ""
    -- UI (docs/ui-design.md): relayed by the host like STATE
    PLAYER_HP = 9,   -- any           "<ffB"    hp, maxHp, flags (bit0 downed, bit1 out)
    CURSOR = 10,     -- any           "<HHBBH"  x, y (0..65535), flags (bit0 inventory open,
                     --                         bit1 dragging), drag slot kind, drag slot index
    DRAG_ITEM = 11,  -- any           "<s1"     name of the item being dragged ("" = dropped)
    -- enemies (enemies.lua), host -> clients
    ENEMY_SPAWN = 12,   -- "<I4s2ffff"  net id, class path, x, y, z, yaw
    ENEMY_STATE = 13,   -- "<I4ffffff"  net id, x, y, z, yaw, hp, maxHp (20 Hz, unreliable)
    ENEMY_DESPAWN = 14, -- "<I4"        net id
    ENEMY_DEATH = 15,   -- "<I4"        net id (host saw hp reach 0; client plays the death)
    -- client -> host
    ENEMY_HIT = 16,     -- "<I4fs1fffs1" net id, damage, damage type class path, direction x/y/z, bone
    -- host -> the one client an enemy shot is aimed at
    ENEMY_SHOT = 17,    -- "<I4fffffB"  net id, muzzle x/y/z, pitch/yaw offset from "straight at the
                        --              target" (keeps spread and misses), Enum_EnemyProjectileType
    -- destruction (destruction.lua): either direction, the host relays
    DST_BREAK = 18,     -- "<s1fff"     actor name (contains the UAID), actor location x/y/z
    -- world sync (worldsync.lua): host -> joining client, the host's save file in chunks
    WORLD_SAVE = 19,    -- "<I4I4I4s2"  transfer id, total bytes, offset, chunk bytes
    -- damage forwarding (damagesync.lua)
    DST_HIT = 20,       -- "<s1ffffs1fff" client -> host: destructible name, its x/y/z, damage, damage
                        --                type class path, hit direction x/y/z
    RADIAL = 21,        -- "<BffffffffBBs1" either way: 0 ApplyRadialDamage / 1 ...WithFalloff, origin
                        --                x/y/z, base, min, inner, outer, falloff, full damage, channel,
                        --                damage type class path
    -- co-op rules (downed.lua)
    REVIVE = 22,        -- "<i8"        the downed player being revived (SteamID64); the host forwards
    TIMESTOP = 23,      -- "<f"         someone used time stop for this many seconds (timestop.lua)
    WIPE = 24,          -- ""           host -> clients: the whole team is down, the run fails (downed.lua)
    INTERACT = 25,      -- "<s1fffB"    someone used a chest/switch/lever/obelisk: exact class name,
                        --              its location, 1 = hold interaction (interact.lua)
    PLAYER_HIT = 26,    -- "<f"         host -> one client: damage an enemy dealt to your stand-in (melee)
    STORY = 27,         -- "<s1fffB"    a cutscene/dialogue container ran Switch/Activate: exact class name,
                        --              its location, code 1-4 (storysync.lua)
    REGION = 28,        -- "<s1ffffff"  a player entered a new map region first: region class, region
                        --              location, the player's location (regionsync.lua)
    TRAV = 29,          -- "<fffs2"     host -> client: the level a traversal area streamed in (area
                        --              location, package path) (traversal.lua)
    PLAYER_GEAR = 31,   -- "<s2"        the weapon a player holds: its UPDA_WeaponBase_C path (avatars.lua)
    PLAYER_FIRE = 32,   -- "<fffff"     a player fired one projectile: camera x, y, z, yaw, pitch (avatars.lua)
    MISSION = 30,       -- "<s1fffB"    stronghold / arena: class, location, 1 started (client -> host),
                        --              2 completed (host -> clients) (mission.lua)
}
M.NAMES = {}
for k, v in pairs(M.T) do M.NAMES[v] = k end

local HDR = "<c2BBi8"
local BODY = {
    [M.T.HELLO] = "<I4s1",
    [M.T.WELCOME] = "<s1",
    [M.T.REJECT] = "<s1",
    [M.T.STATE] = "<dfffffB",
    [M.T.LEVEL] = "<s2",
    [M.T.PING] = "<d",
    [M.T.PONG] = "<d",
    [M.T.BYE] = "",
    [M.T.PLAYER_HP] = "<ffB",
    [M.T.CURSOR] = "<HHBBH",
    [M.T.DRAG_ITEM] = "<s1",
    [M.T.ENEMY_SPAWN] = "<I4s2ffff",
    [M.T.ENEMY_STATE] = "<I4ffffff",
    [M.T.ENEMY_DESPAWN] = "<I4",
    [M.T.ENEMY_DEATH] = "<I4",
    [M.T.ENEMY_HIT] = "<I4fs1fffs1",
    [M.T.ENEMY_SHOT] = "<I4fffffB",
    [M.T.DST_BREAK] = "<s1fff",
    [M.T.WORLD_SAVE] = "<I4I4I4s2",
    [M.T.DST_HIT] = "<s1ffffs1fff",
    [M.T.RADIAL] = "<BffffffffBBs1",
    [M.T.REVIVE] = "<i8",
    [M.T.TIMESTOP] = "<f",
    [M.T.WIPE] = "",
    [M.T.INTERACT] = "<s1fffB",
    [M.T.PLAYER_HIT] = "<f",
    [M.T.STORY] = "<s1fffB",
    [M.T.REGION] = "<s1ffffff",
    [M.T.TRAV] = "<fffs2",
    [M.T.MISSION] = "<s1fffB",
    [M.T.PLAYER_GEAR] = "<s2",
    [M.T.PLAYER_FIRE] = "<fffff",
}

-- s1 strings hold at most 255 bytes.
local function clip(s, n)
    s = tostring(s or "")
    if #s > n then return s:sub(1, n) end
    return s
end

function M.encode(kind, sender, ...)
    local fmt = BODY[kind]
    local args = { ... }
    if kind == M.T.HELLO then args[2] = clip(args[2], 255)
    elseif kind == M.T.WELCOME or kind == M.T.REJECT or kind == M.T.DRAG_ITEM then args[1] = clip(args[1], 255)
    elseif kind == M.T.ENEMY_HIT then args[3] = clip(args[3], 255); args[7] = clip(args[7], 255)
    elseif kind == M.T.DST_BREAK then args[1] = clip(args[1], 255)
    elseif kind == M.T.DST_HIT then args[1] = clip(args[1], 255); args[6] = clip(args[6], 255)
    elseif kind == M.T.RADIAL then args[12] = clip(args[12], 255)
    elseif kind == M.T.INTERACT or kind == M.T.STORY or kind == M.T.REGION or kind == M.T.MISSION then args[1] = clip(args[1], 255) end
    local body = fmt ~= "" and string.pack(fmt, table.unpack(args, 1, select("#", ...))) or ""
    return string.pack(HDR, "VB", M.VERSION, kind, sender) .. body
end

-- Returns kind, sender, fields... or nil, reason.
function M.decode(bytes)
    if type(bytes) ~= "string" or #bytes < 12 then return nil, "short" end
    local ok, magic, ver, kind, sender, pos = pcall(string.unpack, HDR, bytes)
    if not ok or magic ~= "VB" then return nil, "magic" end
    if ver ~= M.VERSION then return nil, "version " .. tostring(ver) end
    local fmt = BODY[kind]
    if fmt == nil then return nil, "kind " .. tostring(kind) end
    if fmt == "" then return kind, sender end
    local fields = { pcall(string.unpack, fmt, bytes, pos) }
    if not fields[1] then return nil, "body" end
    table.remove(fields, 1)
    table.remove(fields)          -- trailing next-position from string.unpack
    return kind, sender, table.unpack(fields)
end

return M

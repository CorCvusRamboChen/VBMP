-- VBMP transports. Both expose: init() -> ok, err; selfId; send(toId, bytes, reliable);
-- poll(handler) where handler(bytes) gets each received packet.
--
-- steam: NOT USABLE FROM LUA (self-test 2026-11-05, build 26439385): FSteamID is an 8-byte
--   struct with no reflected fields, so UE4SS turns it into an empty Lua table and passes it
--   back as zeros: GetSteamID -> BreakSteamID gave "0", MakeSteamID(s) -> BreakSteamID gave
--   "0", a friend's id gave an empty name, SendP2PPacket returned false. Kept for reference;
--   the two-PC game uses localfile + TCP bridge instead.
-- steam: SteamCore plugin (shipped with the game), old ISteamNetworking P2P via Blueprint
--   UFunctions (build 23764881, SteamCore.hpp):
--   UNetworking  SendP2PPacket(FSteamID, TArray<uint8>, ESteamP2PSend, int32 Channel),
--                IsP2PPacketAvailable(out int32 MessageSize, int32 Channel) -> bool,
--                ReadP2PPacket(out TArray<uint8>, out FSteamID, int32 MessageSize, int32 Channel) -> bool,
--                AcceptP2PSessionWithUser(FSteamID), AllowP2PPacketRelay(bool)
--   UUser        GetSteamID() -> FSteamID
--   USteamUtilities MakeSteamID(FString) -> FSteamID, BreakSteamID(FSteamID) -> FString
--   UE4SS out params: pass a table; scalars come back as t[ParamName], arrays fill the table.
-- loopback: packets come straight back to this process after a fixed delay, from a fake peer.
--   Exercises codec + session + puppets on one machine (the old "ghost" test).

local M = {}

local CHANNEL = 0
local SEND_UNRELIABLE_NODELAY = 1   -- ESteamP2PSend
local SEND_RELIABLE = 2

local function valid(o) return o ~= nil and o:IsValid() end

local function toLuaString(v)
    if type(v) == "string" then return v end
    local ok, s = pcall(function() return v:ToString() end)
    if ok then return s end
    return tostring(v)
end

local function bytesToTable(s)
    local t = {}
    for i = 1, #s do t[i] = s:byte(i) end
    return t
end

local function tableToBytes(t)
    local ok, len = pcall(function() return t:GetArrayNum() end)   -- TArray userdata
    if ok then
        local parts = {}
        for i = 1, len do parts[i] = string.char(t[i]) end
        return table.concat(parts)
    end
    local parts = {}
    for i = 1, #t do parts[i] = string.char(t[i]) end
    return table.concat(parts)
end

---------------------------------------------------------------------------------------------

function M.steam(log)
    local T = { kind = "steam" }
    local net, user, utils
    local ids = {}                         -- int64 -> FSteamID userdata
    local stats = { sent = 0, recv = 0, sendFail = 0 }
    T.stats = stats

    function T.init()
        net = FindFirstOf("Networking")
        user = FindFirstOf("User")
        utils = StaticFindObject("/Script/SteamCore.Default__SteamUtilities")
        if not valid(net) then return false, "SteamCore Networking subsystem not found" end
        if not valid(user) then return false, "SteamCore User subsystem not found" end
        if not valid(utils) then return false, "SteamUtilities not found" end
        local me = user:GetSteamID()
        local s = toLuaString(utils:BreakSteamID(me))
        T.selfId = math.tointeger(tonumber(s))
        if not T.selfId or T.selfId == 0 then return false, "bad own SteamID '" .. tostring(s) .. "'" end
        ids[T.selfId] = me
        pcall(function() net:AllowP2PPacketRelay(true) end)
        return true
    end

    function T.steamId(id)
        local sid = ids[id]
        if sid == nil then
            sid = utils:MakeSteamID(tostring(id))
            ids[id] = sid
        end
        return sid
    end

    function T.accept(id)
        local ok, res = pcall(function() return net:AcceptP2PSessionWithUser(T.steamId(id)) end)
        return ok and res
    end

    function T.send(to, bytes, reliable)
        local ok, res = pcall(function()
            return net:SendP2PPacket(T.steamId(to), bytesToTable(bytes),
                reliable and SEND_RELIABLE or SEND_UNRELIABLE_NODELAY, CHANNEL)
        end)
        if ok and res ~= false then
            stats.sent = stats.sent + 1
        else
            stats.sendFail = stats.sendFail + 1
            if stats.sendFail <= 5 then log("send to " .. tostring(to) .. " failed: " .. tostring(res)) end
        end
    end

    function T.poll(handler)
        for _ = 1, 128 do
            local avail = {}
            local ok, has = pcall(function() return net:IsP2PPacketAvailable(avail, CHANNEL) end)
            if not ok or not has then return end
            local size = avail.MessageSize
            if not size or size <= 0 then return end
            local data, remote = {}, {}
            local okRead, got = pcall(function() return net:ReadP2PPacket(data, remote, size, CHANNEL) end)
            if not okRead or not got then return end
            stats.recv = stats.recv + 1
            handler(tableToBytes(data))
        end
    end

    return T
end

---------------------------------------------------------------------------------------------

function M.loopback(log, delaySeconds)
    local T = { kind = "loopback", selfId = 1, fakePeer = 2 }
    local queue = {}
    local now = 0
    local stats = { sent = 0, recv = 0, sendFail = 0 }
    T.stats = stats

    function T.init() return true end
    function T.accept() return true end
    function T.advance(dt) now = now + dt end

    -- Anything we send comes back as if the fake peer had sent it.
    function T.send(_, bytes)
        stats.sent = stats.sent + 1
        table.insert(queue, { at = now + delaySeconds, bytes = bytes })
    end

    function T.poll(handler)
        while #queue > 0 and queue[1].at <= now do
            local p = table.remove(queue, 1)
            stats.recv = stats.recv + 1
            handler(p.bytes)
        end
    end

    return T
end

---------------------------------------------------------------------------------------------
-- localfile: two game processes on the same PC (dual-instance testing). Each direction is an
-- append-only file of length-prefixed frames ("<s2"); the reader remembers its offset and only
-- consumes complete frames. Slot A is id 1, slot B is id 2 (fake SteamIDs).
-- The same files carry the two-PC game: tools/dist/vbmp-bridge.ps1 on each PC pipes the outgoing
-- file to the other PC over TCP and appends what arrives to the incoming file (frames whole).
-- dir: folder of the link files (default Saved\).

function M.localfile(log, slot, dir)
    local saved = dir or ((os.getenv("LOCALAPPDATA") or ".") .. "\\VOIDBREAKER\\Saved\\")
    local other = slot == "A" and "B" or "A"
    local T = {
        kind = "localfile",
        selfId = slot == "A" and 1 or 2,
        peerId = slot == "A" and 2 or 1,
    }
    local outPath = saved .. "VBMP_link_" .. slot .. "2" .. other .. ".bin"
    local inPath = saved .. "VBMP_link_" .. other .. "2" .. slot .. ".bin"
    local offset = 0
    local stats = { sent = 0, recv = 0, sendFail = 0 }
    T.stats = stats

    function T.init()
        -- Start our direction fresh; the reader resets its offset when the file shrinks.
        local f = io.open(outPath, "wb")
        if not f then return false, "cannot write " .. outPath .. "（先启动 VBMP 联机桥接）" end
        f:close()
        local i = io.open(inPath, "rb")
        if i then offset = i:seek("end"); i:close() end   -- ignore frames from an older run
        return true
    end

    function T.accept() return true end

    function T.send(_, bytes)
        local f = io.open(outPath, "ab")
        if not f then stats.sendFail = stats.sendFail + 1; return end
        f:write(string.pack("<s2", bytes))
        f:close()
        stats.sent = stats.sent + 1
    end

    function T.poll(handler)
        local f = io.open(inPath, "rb")
        if not f then return end
        local size = f:seek("end")
        if size < offset then offset = 0 end              -- the other side restarted its file
        if size == offset then f:close(); return end
        f:seek("set", offset)
        local data = f:read(size - offset)
        f:close()
        local pos = 1
        while pos + 1 <= #data do
            local n = string.unpack("<I2", data, pos)
            if pos + 1 + n > #data then break end            -- frame still being written
            local bytes = data:sub(pos + 2, pos + 1 + n)
            pos = pos + 2 + n
            stats.recv = stats.recv + 1
            handler(bytes)
        end
        offset = offset + pos - 1
    end

    return T
end

return M

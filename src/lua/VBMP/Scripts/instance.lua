-- Which game process is this? Lets two game instances run side by side on one PC (dual-instance
-- testing, docs/networking.md): each process claims slot "A" or "B" in Saved\VBMP_slots.txt.
-- The process key is the GI_LimaGameInstance_C object address: identical for every mod inside
-- one process, different between processes. VBDev reads the same file to find its slot.
-- Line format: <key>=<slot>@<os.time() of the last heartbeat>

local M = {}

local SAVED = (os.getenv("LOCALAPPDATA") or ".") .. "\\VOIDBREAKER\\Saved\\"
M.FILE = SAVED .. "VBMP_slots.txt"
local STALE = 10

local function readAll()
    local t = {}
    local f = io.open(M.FILE, "r")
    if not f then return t end
    for line in f:lines() do
        local k, s, ts = line:match("^(%w+)=(%u)@(%d+)$")
        if k then t[k] = { slot = s, at = tonumber(ts) } end
    end
    f:close()
    return t
end

local function writeAll(t)
    local f = io.open(M.FILE, "w")
    if not f then return end
    for k, v in pairs(t) do f:write(k, "=", v.slot, "@", v.at, "\n") end
    f:close()
end

-- Process key, or nil until the game instance exists. Must run on the game thread.
function M.key()
    local gi = FindFirstOf("GI_LimaGameInstance_C")
    if gi == nil or type(gi) ~= "userdata" or not gi:IsValid() then return nil end
    return string.format("%X", gi:GetAddress())
end

-- Claim (or refresh) this process's slot; returns "A" or "B" (nil if no key yet).
function M.claim()
    local key = M.key()
    if not key then return nil end
    local t, now = readAll(), os.time()
    for k, v in pairs(t) do
        if k ~= key and now - v.at > STALE then t[k] = nil end
    end
    local mine = t[key]
    if not mine then
        local used = {}
        for _, v in pairs(t) do used[v.slot] = true end
        mine = { slot = used.A and "B" or "A" }
        t[key] = mine
    end
    mine.at = now
    writeAll(t)
    return mine.slot
end

-- Slot of this process as recorded by VBMP, without claiming (for other mods).
function M.lookup()
    local key = M.key()
    if not key then return nil end
    local v = readAll()[key]
    return v and v.slot or nil
end

return M

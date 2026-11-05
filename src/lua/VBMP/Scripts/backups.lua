-- Save backups: whole copies of the real save (SaveGames\LimaSaveGame.sav) in Saved\, listed in
-- Saved\VBMP_backups.txt (newest last; Lua cannot list a folder). Made before every co-op
-- session, before carrying co-op gains back, and before a restore. Only the newest KEEP stay.

local M = {}

local SAVED = (os.getenv("LOCALAPPDATA") or ".") .. "\\VOIDBREAKER\\Saved\\"
M.REAL = SAVED .. "SaveGames\\LimaSaveGame.sav"
local INDEX = SAVED .. "VBMP_backups.txt"
local KEEP = 20

M.LABELS = {
    host = "开房前",
    client = "加入前",
    carryback = "带回联机收获前",
    restore = "恢复备份前",
}

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local d = f:read("a")
    f:close()
    return d
end

local function writeFile(path, data)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

M.readFile, M.writeFile = readFile, writeFile

-- { { file, kind, time } } oldest first
local function readIndex()
    local out = {}
    local f = io.open(INDEX, "r")
    if not f then return out end
    for line in f:lines() do
        local file, kind, time = line:match("^([^\t]+)\t([^\t]*)\t([^\t]*)$")
        if file then table.insert(out, { file = file, kind = kind, time = time }) end
    end
    f:close()
    return out
end

local function writeIndex(list)
    local f = io.open(INDEX, "w")
    if not f then return end
    for _, b in ipairs(list) do f:write(b.file, "\t", b.kind, "\t", b.time, "\n") end
    f:close()
end

-- Copy the real save into a new backup. Returns the backup's full path or nil.
function M.make(kind, log)
    local data = readFile(M.REAL)
    if not data then return nil end
    local stamp = os.date("%Y%m%d-%H%M%S")
    local file = SAVED .. "VBMP_backup_" .. kind .. "_" .. stamp .. ".sav"
    if not writeFile(file, data) then return nil end
    local list = readIndex()
    table.insert(list, { file = file, kind = kind, time = os.date("%m-%d %H:%M") })
    while #list > KEEP do
        os.remove(table.remove(list, 1).file)
    end
    writeIndex(list)
    if log then log("save backed up (" .. kind .. ") to " .. file) end
    return file
end

-- Newest first, only files that still exist.
function M.list()
    local out = {}
    local list = readIndex()
    for i = #list, 1, -1 do
        local f = io.open(list[i].file, "rb")
        if f then
            f:close()
            local b = list[i]
            b.label = (M.LABELS[b.kind] or b.kind) .. "  " .. b.time
            table.insert(out, b)
        end
    end
    return out
end

-- Put a backup back as the real save (the current one is backed up first). Main menu only:
-- in a level the game would overwrite it. Returns ok, err.
function M.restore(file, log)
    local data = readFile(file)
    if not data or data:sub(1, 4) ~= "GVAS" then return false, "备份文件读不了" end
    M.make("restore", log)
    if not writeFile(M.REAL, data) then return false, "写不了存档" end
    if log then log("save restored from " .. file) end
    return true
end

return M

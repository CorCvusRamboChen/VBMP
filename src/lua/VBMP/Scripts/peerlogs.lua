-- Logs swapped between players (user request 2026-11-13: "做一个能获取他的日志的").
-- When a join succeeds, the host asks the client for its logs and the client asks the host
-- (LOG_REQ 33); the answer comes a little later, after the world save, in LOG_CHUNK 34 pieces.
-- Received files land in Saved\VBMP_peer_<name>_<tag>.log; the one before is kept as
-- .prev.log. (No folders or listings: os.execute/io.popen start cmd.exe, which can flash a
-- console over the game.)
-- The logs are appended to across sessions, so an earlier failed attempt is in them too.
-- What is sent (tails only): the Steam helper log, the VBMP lines of UE4SS.log, the update log.
-- They hold Steam persona names and Windows paths; they only go to the player in the session.

local M = {}

local CHUNK = 30000            -- localfile frames are "<s2" (max 65535 bytes)
local MAX_EACH = 96 * 1024     -- bytes per file
local SCAN_UE4SS = 3 * 1024 * 1024
local SEND_DELAY = 15          -- seconds after the request: let the world save go first

local function readTail(path, max)
    local f = io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end")
    local from = math.max(0, size - max)
    f:seek("set", from)
    local data = f:read("a") or ""
    f:close()
    if from > 0 then data = data:gsub("^[^\n]*\n", "", 1) end   -- drop the cut first line
    return data
end

function M.new(log, saved)
    local L = { outbox = {}, inbox = {}, stats = { sent = 0, received = 0 } }

    function L.collect()
        local out = {}
        local steam = readTail(saved .. "VBMP_steam.log", MAX_EACH)
        if steam then table.insert(out, { "steam", steam }) end
        for _, p in ipairs({ "ue4ss\\UE4SS.log", "UE4SS.log" }) do
            local all = readTail(p, SCAN_UE4SS)
            if all then
                local lines = {}
                for line in all:gmatch("[^\n]+") do
                    if line:find("[VBMP", 1, true) or (line:find("[Lua]", 1, true) and line:find("rror", 1, true)) then
                        table.insert(lines, line)
                    end
                end
                local text = table.concat(lines, "\n")
                if #text > MAX_EACH then text = text:sub(-MAX_EACH):gsub("^[^\n]*\n", "", 1) end
                table.insert(out, { "game", text })
                break
            end
        end
        local upd = readTail(saved .. "VBMP_update.log", 16 * 1024)
        if upd then table.insert(out, { "update", upd }) end
        return out
    end

    -- A peer asked for our logs: send them SEND_DELAY seconds later (tick).
    function L.onRequest(peerId, now) L.outbox[peerId] = now + SEND_DELAY end

    -- send(peerId, tag, total, offset, bytes)
    function L.tick(now, send)
        for id, due in pairs(L.outbox) do
            if now >= due then
                L.outbox[id] = nil
                local ok, files = pcall(L.collect)
                if not ok then log("peerlogs: collect failed: " .. tostring(files)); files = {} end
                local bytes = 0
                for _, fl in ipairs(files) do
                    local tag, data = fl[1], fl[2]
                    if #data == 0 then send(id, tag, 0, 0, "") end
                    for off = 0, #data - 1, CHUNK do
                        send(id, tag, #data, off, data:sub(off + 1, math.min(off + CHUNK, #data)))
                    end
                    bytes = bytes + #data
                end
                L.stats.sent = L.stats.sent + 1
                log(string.format("peerlogs: sent %d log files (%d KB) to %s", #files, bytes // 1024, tostring(id)))
            end
        end
    end

    function L.onChunk(peerName, tag, total, offset, bytes)
        if type(tag) ~= "string" or not tag:match("^[%w_]+$") then return end
        local key = tostring(peerName) .. "/" .. tag
        local box = L.inbox[key]
        if offset == 0 or not box then box = { parts = {}, got = 0 }; L.inbox[key] = box end
        if not box.parts[offset] then
            box.parts[offset] = bytes
            box.got = box.got + #bytes
        end
        if box.got < total then return end
        L.inbox[key] = nil
        local offs = {}
        for o in pairs(box.parts) do table.insert(offs, o) end
        table.sort(offs)
        local chunks = {}
        for _, o in ipairs(offs) do table.insert(chunks, box.parts[o]) end
        local safe = tostring(peerName):gsub("[^%w%-_]", "_")
        local path = saved .. "VBMP_peer_" .. safe .. "_" .. tag .. ".log"
        local prev = saved .. "VBMP_peer_" .. safe .. "_" .. tag .. ".prev.log"
        os.remove(prev)
        os.rename(path, prev)
        local f = io.open(path, "wb")
        if not f then log("peerlogs: cannot write " .. path); return end
        f:write("-- " .. tostring(peerName) .. " " .. tag .. " log, received " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
        f:write(table.concat(chunks))
        f:close()
        L.stats.received = L.stats.received + 1
        log("peerlogs: got " .. tag .. " log from " .. tostring(peerName) .. " -> " .. path)
    end

    function L.clear() L.outbox, L.inbox = {}, {} end

    return L
end

return M

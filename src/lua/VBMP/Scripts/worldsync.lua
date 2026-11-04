-- World sync v1 (Phase 3.7): a joining client plays in the host's world by loading the host's save.
--
-- Evidence (self-test 2026-11-05, build 23764881; research/phase3-07-worldsync.md):
--   * The generated world is a function of the save: Continue twice on one save gave the same
--     sublevels at the same spots (GenerateWorld runs on load, AssignScenarios does not), and two
--     processes on one save had identical destructible names/locations.
--   * GI_LimaGameInstance_C.SlotName picks the slot; at the main menu, SlotName = X,
--     LoadGameData(false), then the Continue button loads world X.
--
-- Host: on a client's HELLO it saves (GI.SaveGameData(false)) and sends that slot file in
-- WORLD_SAVE chunks. Client: writes the bytes to the client slot (VBMP_client.sav - saveguard.lua
-- keeps the client on that slot), goes to the main menu and presses Continue.
-- v1 limit: the client then carries the host's character state too (weapons, mods, inventory),
-- only in its VBMP_client slot - its real save is untouched.

local M = {}

local SAVES = (os.getenv("LOCALAPPDATA") or ".") .. "\\VOIDBREAKER\\Saved\\SaveGames\\"
local CLIENT_SLOT = "VBMP_client"
local CHUNK = 30000          -- localfile frames are "<s2" (max 65535 bytes)
local MENU = "/Game/ProjectLima/Levels/Menu/LV_LimaMainMenu"
local CONTINUE = "BndEvt__WBP_PlayMenu_BTN_Continue_K2Node_ComponentBoundEvent_4_CommonButtonBaseClicked__DelegateSignature"
local STEP_TIMEOUT = 90

local function valid(o) return type(o) == "userdata" and o:IsValid() end
local inMenu = require("saveguard").inMenu

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local d = f:read("a")
    f:close()
    return d
end

function M.new(log)
    local W = {
        role = nil,
        nextId = 1,
        rx = nil,          -- client: { id, total, parts = { [offset] = bytes }, got }
        phase = nil,       -- client: nil | "menu" | "continue" | "loading" | "done"
        phaseAt = 0,
        lastLoaded = 0,    -- client: id of the last transfer loaded (the host numbers them)
        stats = { sentBytes = 0, recvBytes = 0, loads = 0 },
    }
    local now = 0

    function W.setRole(role)
        W.role, W.rx, W.phase, W.lastLoaded = role, nil, nil, 0
    end

    -- Host: save now and send the slot file to one client. sendTo(id, total, offset, bytes).
    function W.hostSendTo(sendTo)
        local gi = FindFirstOf("GI_LimaGameInstance_C")
        if not valid(gi) then log("worldsync: no game instance"); return end
        pcall(function() gi:SaveGameData(false) end)
        local slot = "LimaSaveGame"
        pcall(function() slot = gi.SlotName:ToString() end)
        local data = readFile(SAVES .. slot .. ".sav")
        if not data then log("worldsync: cannot read " .. slot .. ".sav"); return end
        local id = W.nextId
        W.nextId = id + 1
        for off = 0, #data - 1, CHUNK do
            sendTo(id, #data, off, data:sub(off + 1, math.min(off + CHUNK, #data)))
        end
        W.stats.sentBytes = W.stats.sentBytes + #data
        log(string.format("worldsync: sent the host save (%s, %d bytes) as transfer %d", slot, #data, id))
    end

    -- Client: one chunk from the host.
    function W.onChunk(id, total, offset, bytes)
        if W.role ~= "client" or id <= W.lastLoaded then return end
        if type(total) ~= "number" or total <= 0 or total > 64 * 1024 * 1024 then return end
        if not W.rx or W.rx.id ~= id then W.rx = { id = id, total = total, parts = {}, got = 0 } end
        local rx = W.rx
        if rx.parts[offset] then return end
        rx.parts[offset] = bytes
        rx.got = rx.got + #bytes
        W.stats.recvBytes = W.stats.recvBytes + #bytes
        if rx.got < rx.total then return end
        local offs = {}
        for o in pairs(rx.parts) do table.insert(offs, o) end
        table.sort(offs)
        local buf = {}
        for _, o in ipairs(offs) do table.insert(buf, rx.parts[o]) end
        local data = table.concat(buf)
        W.rx = nil
        if #data ~= total then log("worldsync: bad transfer size " .. #data .. "/" .. total); return end
        local f = io.open(SAVES .. CLIENT_SLOT .. ".sav", "wb")
        if not f then log("worldsync: cannot write " .. CLIENT_SLOT .. ".sav"); return end
        f:write(data)
        f:close()
        log(string.format("worldsync: got the host save (%d bytes), loading the host world", #data))
        W.lastLoaded = id
        W.phase, W.phaseAt, W.menuSent = "menu", now, nil
    end

    local function console(cmd)
        local pc = FindFirstOf("PC_LimaPlayerController_C") or FindFirstOf("PC_LimaMainMenuController_C")
        local k = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        if valid(pc) and valid(k) then k:ExecuteConsoleCommand(pc, cmd, pc) end
    end

    -- Own game-thread loop (main.lua): drives the reload through level changes.
    function W.tick(dt)
        now = now + dt
        if not W.phase or W.phase == "done" then return end
        if now - W.phaseAt > STEP_TIMEOUT then
            log("worldsync: step '" .. W.phase .. "' timed out")
            W.phase = "done"
            return
        end
        if W.phase == "menu" then
            if inMenu() then
                W.phase, W.phaseAt = "continue", now
            elseif not W.menuSent then
                W.menuSent = true
                console("open " .. MENU)
            end
        elseif W.phase == "continue" then
            -- the play menu on screen (an older instance can still exist)
            local menu = nil
            for _, w in ipairs(FindAllOf("WBP_PlayMenu_C") or {}) do
                local ok, shown = pcall(function() return w:IsInViewport() end)
                if valid(w) and (menu == nil or (ok and shown)) then menu = w end
            end
            local gi = FindFirstOf("GI_LimaGameInstance_C")
            if valid(menu) and valid(gi) then
                gi.SlotName = CLIENT_SLOT
                pcall(function() gi:LoadGameData(false) end)
                menu[CONTINUE](menu, menu.BTN_Continue)
                W.phase, W.phaseAt = "loading", now
                log("worldsync: Continue pressed on " .. CLIENT_SLOT)
            end
        elseif W.phase == "loading" then
            if not inMenu() and valid(FindFirstOf("PC_LimaPlayerController_C")) then
                W.phase = "done"
                W.menuSent = nil
                W.stats.loads = W.stats.loads + 1
                log("worldsync: in the host world")
            end
        end
    end

    function W.clear()
        W.role, W.rx = nil, nil
        if W.phase ~= "loading" then W.phase = nil end
    end

    return W
end

return M

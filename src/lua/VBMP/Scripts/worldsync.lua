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
-- v2: the client keeps its own character (weapons, mods, inventory, upgrades, currency): only the
-- layout properties below are taken from the host's save and spliced into the client's own
-- VBMP_client.sav (gvas.lua, whole top-level properties). Its real save is never touched.

local M = {}

local SAVES = (os.getenv("LOCALAPPDATA") or ".") .. "\\VOIDBREAKER\\Saved\\SaveGames\\"
local CLIENT_SLOT = "VBMP_client"
local CHUNK = 30000          -- localfile frames are "<s2" (max 65535 bytes)
local MENU = "/Game/ProjectLima/Levels/Menu/LV_LimaMainMenu"
local CONTINUE = "BndEvt__WBP_PlayMenu_BTN_Continue_K2Node_ComponentBoundEvent_4_CommonButtonBaseClicked__DelegateSignature"
local STEP_TIMEOUT = 90

local gvas = require("gvas")

-- Top-level BP_SaveGame_Lima_C properties that describe the world/run rather than the player
-- (names from the CXX dump BP_SaveGame_Lima.hpp). Everything else stays the client's own.
local LAYOUT = {}
for n in ([[Level CurrentBiome CurrentDifficultyTier CurrentMusicTier CurrentBiomeTier OverallTier PlayerStartTag
CurrentSavedLevel DestroyedActors SwitchedActors RunActors LastScenarioClear DisabledRunActors ExcludedLevels
ObjectSaveData DisabledRunIDActors CurrentMission IsInActiveRun? HasSavedRunProgress? HasPopulatedWorld?
HasInitiatedRun? HasEnteredABiome? SwitchedZone01? SwitchedZone02? StoryAct CurrentLoops CurrentSubLoops
LastTeleportedFrom LatestClearedGate LatestCollectedChip DesiredDeathStartTag HasCompletedZone01? HasCompletedZone02?
HasCompletedZone03? HasCompletedZone04? HasCompletedZone05? HasCompletedZone06? HasCompletedZone03b?
HasCompletedZone03c? DefeatedBoss01? Boss01CodeCombination MainDifficultySetting ChaosRating DIFF_SilentNight?
DIFF_CreditSuspension? DIFF_Inflation? DIFF_Frenzy? DIFF_AnomalySpike? DIFF_AnomalyFault? DIFF_UnluckyDay?
DIFF_ApexSurge? DIFF_EliteSurge? DIFF_StackThrottle? DIFF_RepeaterCap? DIFF_DeathLock? DIFF_Reinforcements?
DIFF_Vulnerable? DIFF_Lifeline? DIFF_SlimPickings? DIFF_Empowered? DIFF_FastRecovery?]]):gmatch("%S+") do
    LAYOUT[n] = true
end

-- v3 (user decision 2026-11-13): on the FIRST load of a session the client also takes the host's
-- backpack - the run's weapons, their slots and mods, body mods, inventory, credits - and the
-- story abilities / hack modules / integration keys the host's world already expects, so the
-- joiner starts at the host's progress. Later loads (host changed level, pull back) take only
-- LAYOUT: from then on each player's backpack is their own. Out-of-run progression (saveguard
-- META) and the player's own look (skins) and health always stay the client's. The real save is
-- not touched; saveguard carries only META back at the main menu.
local BACKPACK = {}
for n in ([[VoidCoins SelectedPrimary SelectedSecondary Weapon01NumberOfSlots Weapon02NumberOfSlots
Weapon01Mods Weapon02Mods Weapon01Slots Weapon02Slots Weapon01ProjectileSlot Weapon02ProjectileSlot
BodyMods InventorySlots PlayerCorruptionMods SelectedProjectileMod CurrentOptic SelectedFireMode
PlayerProjectileAmmo WorldLockedMods ConstructorLockedMods UnlockedDash? UnlockedGrapple? UnlockedThrow?
UnlockedWallRun? HasHackModule01? HasHackModule02? HasHackModule03? HasHackModule04? HasHackModule05?
HasHackModule06? IntegrationKeys]]):gmatch("%S+") do
    BACKPACK[n] = true
end
local JOIN_TAKE = {}
for n in pairs(LAYOUT) do JOIN_TAKE[n] = true end
for n in pairs(BACKPACK) do JOIN_TAKE[n] = true end
M.BACKPACK, M.LAYOUT = BACKPACK, LAYOUT

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
        W.backpackTaken = false
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
        -- Our own save (saveguard copied the real one to the client slot) + the host's layout,
        -- and on the first load of the session the host's backpack too (BACKPACK above).
        local base = readFile(SAVES .. CLIENT_SLOT .. ".sav")
        if base then
            local first = not W.backpackTaken
            local merged, kept, taken = gvas.splice(base, data, first and JOIN_TAKE or LAYOUT)
            if merged then
                if first then W.backpackTaken = true end
                log(string.format("worldsync: kept %d of our properties, took %d %s properties from the host", kept, taken,
                    first and "layout + backpack" or "layout"))
                data = merged
            else
                log("worldsync: splice failed (" .. tostring(kept) .. "), using the host save as is")
            end
        end
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

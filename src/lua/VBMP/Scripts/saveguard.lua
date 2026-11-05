-- Client save protection: while this game is a co-op client (and until it returns to the main
-- menu afterwards), the game saves to another slot, so the player's real save
-- (SaveGames\LimaSaveGame.sav) never receives a co-op run state.
--
-- Evidence (self-test 2026-11-05, build 23764881):
--   * GI_LimaGameInstance_C has `FString SlotName` (CXX dump, offset 0x290) = "LimaSaveGame".
--     Setting it to "VBMP_client" made SaveGameData(true) (the async save the game uses) write
--     VBMP_client.sav while LimaSaveGame.sav kept its timestamp.
--   * The async save does NOT pass through any hookable UFunction (hooks on
--     AsyncActionHandleSaveGame.AsyncSaveGameToSlot and GameplayStatics.SaveGameToSlot saw 0 calls
--     while the file was written), so the slot variable is the primary guard.
--   * The sync path GameplayStatics.SaveGameToSlot IS hookable, and changing its SlotName in the
--     pre-hook redirected the write (native-function parameter edits stick; Blueprint ones did
--     not). That and DeleteGameInSlot stay hooked as a second layer.
--   * Loads use the same slot variable: before switching we copy the real save to the client
--     slot, so the client keeps playing with its own progress.

-- Carrying gains back (coop-rules.md, user decision 2026-11-05: only out-of-run progression):
--   * clientStarted writes Saved\SaveGames\VBMP_client_pending.txt; clientStopped saves the
--     game into the client slot one last time.
--   * at the main menu afterwards (or at the next main menu after a crash/quit) the META
--     properties below are spliced from VBMP_client.sav into the real save (backed up first,
--     backups.lua) and the real save is reloaded. Everything else - the player's own run, level,
--     weapons, mods, backpack, VoidCoins - stays as it was before joining.
--   * META = out-of-run names in BP_SaveGame_Lima_C (CXX dump; classification as in
--     research/vbtools-01-difficulty-mods.md): Voidium, perma upgrades UPG_*, the six stats and
--     their *Ranks, unlock lists, research, skins, chaos missions/fragments, iteration records,
--     collected logs / viewed emails and the tutorial "HasShown*" flags. Deliberately NOT taken:
--     story abilities (UnlockedDash/Grapple/Throw/WallRun?), HasHackModule*, Decryptors,
--     IntegrationKeys, FoundWorldSchematics, InventorySchematics (tied to the host's world/run).

local gvas = require("gvas")
local backups = require("backups")

local M = {}

local META_EXACT = {}
for n in ([[Voidium Vitality Ergonomics Capacity Endurance Cognition Exponent CurrentPermaTierMaxPurchase
FullyUnlockedMods PurchasableMods UnlockedWeapons UnlockedBodyMods UnlockedWeaponMods UnlockedWeaponMasterMods
UnlockedPermaUpgrades UnlockedSchematics ResearchedSchematics ResearchData UnlockedSkins UnlockedChasis
ChaosFragments ChaosMissionAchieved_Act1 ChaosMissionAchieved_Act2 ChaosMissionAct1 ChaosMissionAct2
CollectedLogs ViewedEmails MaxIterationReachedOnNormal MaxIterationReachedOnHard MaxIterationReachedOnInsanity]]):gmatch("%S+") do
    META_EXACT[n] = true
end
function M.isMeta(name)
    return META_EXACT[name] == true or name:find("^UPG_") ~= nil or name:find("^HasShown") ~= nil
        or name:find("Ranks?$") ~= nil
end

local SAVES = (os.getenv("LOCALAPPDATA") or ".") .. "\\VOIDBREAKER\\Saved\\SaveGames\\"
local REAL_SLOT = "LimaSaveGame"
local CLIENT_SLOT = "VBMP_client"
-- { path, index of the SlotName parameter } (Engine.hpp in the dump)
local HOOKS = {
    { "/Script/Engine.GameplayStatics:SaveGameToSlot", 2 },
    { "/Script/Engine.GameplayStatics:DeleteGameInSlot", 1 },
}

local function valid(o) return type(o) == "userdata" and o:IsValid() end

-- Current level via the game instance (it outlives levels). FindFirstOf on menu classes is not
-- enough: a menu controller/widget from an earlier visit can still be found after the level
-- changed (dual test 2026-11-05).
function M.levelName()
    local gi = FindFirstOf("GI_LimaGameInstance_C")
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if not (gi and gi:IsValid() and gs and gs:IsValid()) then return nil end
    local ok, n = pcall(function() return gs:GetCurrentLevelName(gi, true):ToString() end)
    return ok and n or nil
end
function M.inMenu()
    local n = M.levelName()
    return n ~= nil and n:find("MainMenu", 1, true) ~= nil
end

local PENDING = SAVES .. "VBMP_client_pending.txt"

local function copyFile(from, to)
    local src = io.open(from, "rb")
    if not src then return false end
    local data = src:read("a")
    src:close()
    local dst = io.open(to, "wb")
    if not dst then return false end
    dst:write(data)
    dst:close()
    return true
end

function M.new(log)
    local G = { active = false, untilMenu = false, redirected = 0, hooked = false }

    local function gi() return FindFirstOf("GI_LimaGameInstance_C") end

    local function slotOf(g)
        local ok, s = pcall(function() return g.SlotName:ToString() end)
        return ok and s or nil
    end

    local function setSlot(name)
        local g = gi()
        if not valid(g) then return false end
        if slotOf(g) ~= name then
            g.SlotName = name
            log("saveguard: GI.SlotName = " .. tostring(slotOf(g)))
        end
        return slotOf(g) == name
    end

    local function onCall(fn, slotParam)
        if not G.active then return end
        local ok, name = pcall(function() return slotParam:get():ToString() end)
        if not ok or name ~= REAL_SLOT then return end
        local okSet, err = pcall(function() slotParam:set(CLIENT_SLOT) end)
        G.redirected = G.redirected + 1
        if G.redirected <= 5 or not okSet then
            log("saveguard: " .. fn .. " " .. REAL_SLOT .. " -> " .. CLIENT_SLOT ..
                (okSet and "" or (" FAILED: " .. tostring(err))))
        end
    end

    function G.install()
        if G.hooked then return end
        local n = 0
        for _, h in ipairs(HOOKS) do
            local path, idx = h[1], h[2]
            local fn = path:match(":([%w_]+)$")
            local ok, err = pcall(RegisterHook, path, function(_, a1, a2)
                pcall(onCall, fn, idx == 1 and a1 or a2)
            end)
            if ok then n = n + 1 else log("saveguard: hook " .. fn .. " failed: " .. tostring(err)) end
        end
        G.hooked = true
        log("saveguard: " .. n .. "/" .. #HOOKS .. " hooks")
    end

    -- Names of META properties whose bytes differ between two saves (for the toast/log).
    local function changedMeta(a, b)
        local pa, pb = gvas.parse(a), gvas.parse(b)
        if not pa or not pb then return {} end
        local function blobs(bytes, parsed)
            local t = {}
            for _, pr in ipairs(parsed.props) do
                if M.isMeta(pr.name) then t[pr.name] = bytes:sub(pr.from, pr.to) end
            end
            return t
        end
        local ba, bb = blobs(a, pa), blobs(b, pb)
        local out = {}
        for n, v in pairs(bb) do if ba[n] ~= v then table.insert(out, n) end end
        for n in pairs(ba) do if bb[n] == nil then table.insert(out, n) end end
        table.sort(out)
        return out
    end

    -- At the main menu after co-op: bring out-of-run gains from the client slot into the real save.
    function G.carryBack()
        local client = backups.readFile(SAVES .. CLIENT_SLOT .. ".sav")
        local real = backups.readFile(SAVES .. REAL_SLOT .. ".sav")
        os.remove(PENDING)
        if not client or not real then log("saveguard: carry-back skipped (a save is missing)"); return end
        local changed = changedMeta(real, client)
        if #changed == 0 then
            log("saveguard: carry-back - no out-of-run changes")
            if G.onCarried then G.onCarried(changed) end
            return
        end
        local merged, kept, taken = gvas.splice(real, client, M.isMeta)
        if not merged then log("saveguard: carry-back FAILED: " .. tostring(kept)); return end
        backups.make("carryback", log)
        if not backups.writeFile(SAVES .. REAL_SLOT .. ".sav", merged) then
            log("saveguard: carry-back FAILED: cannot write the real save"); return
        end
        log(string.format("saveguard: carried back %d out-of-run properties (kept %d): %s",
            taken, kept, table.concat(changed, ", ")))
        -- the game holds a save object in memory; reload it from the merged file
        local g = gi()
        if valid(g) then
            g.SlotName = REAL_SLOT
            pcall(function() g:LoadGameData(false) end)
        end
        if G.onCarried then G.onCarried(changed) end
    end

    -- A client session starts: protect the real save.
    function G.clientStarted()
        G.install()
        local pf = io.open(PENDING, "w")
        if pf then pf:write(os.date("%Y-%m-%d %H:%M:%S")); pf:close() end
        if not G.active then
            -- start from the slot this game is playing (normally LimaSaveGame)
            local from = REAL_SLOT
            local g = gi()
            if valid(g) then local cur = slotOf(g); if cur and cur ~= "" and cur ~= CLIENT_SLOT then from = cur end end
            local copied = copyFile(SAVES .. from .. ".sav", SAVES .. CLIENT_SLOT .. ".sav")
            log("saveguard: ON - saving to " .. CLIENT_SLOT .. ".sav (copy of " .. from .. ": " .. tostring(copied) .. ")")
        end
        G.active, G.untilMenu = true, false
        local ok = setSlot(CLIENT_SLOT)
        if not ok then log("saveguard: WARNING could not set GI.SlotName yet, retrying") end
    end

    -- The client session ended: the in-memory run state is still the co-op one, so stay on until
    -- the main menu (Continue then reloads the untouched real save from disk).
    function G.clientStopped()
        if G.active then
            -- Last save into the client slot so the carry-back sees everything collected.
            -- MasterSave, not SaveGameData: picked-up currency sits on the character and the
            -- GI until the game's MasterSave copies it into LatestSaveGame (self-test
            -- 2026-11-05: after PickedUpCurrency, SaveGameData wrote the old Voidium 336,
            -- MasterSave wrote 344). ChaosFragments did not reach the file either way.
            local g = gi()
            if valid(g) and slotOf(g) == CLIENT_SLOT and not M.inMenu() then
                local ok = pcall(function() g:MasterSave() end)
                log("saveguard: final MasterSave to " .. CLIENT_SLOT .. " " .. tostring(ok))
            end
            G.untilMenu = true
            log("saveguard: session over, still protecting until the main menu")
        end
    end

    -- Own loop: keep the slot switched; switch back at the main menu (M.inMenu).
    function G.tick()
        if not G.active then
            -- a co-op session ended without reaching the menu (game quit or crashed)
            if not G.pendingChecked and M.inMenu() then
                G.pendingChecked = true
                local pf = io.open(PENDING, "r")
                if pf then
                    pf:close()
                    log("saveguard: unfinished co-op session found, carrying gains back")
                    G.carryBack()
                end
            end
            return
        end
        if G.untilMenu then
            if M.inMenu() then
                G.active, G.untilMenu = false, false
                setSlot(REAL_SLOT)
                log("saveguard: OFF (main menu); the real save is in use again")
                G.carryBack()
                return
            end
        end
        setSlot(CLIENT_SLOT)
    end

    return G
end

return M

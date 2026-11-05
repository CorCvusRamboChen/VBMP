-- VBTools: single-player helpers (separate from the multiplayer mod).
-- Every feature is a plain function used by both the hotkeys below and the in-game panel
-- (ui.lua, shown inside the inventory screen).
--   Ctrl+F1  report boss state          Ctrl+F6  fuse the first triple of identical mods
--   Ctrl+F2  boss: unstick               Ctrl+F7  fusion report
--   Ctrl+F3  boss: advance one stage     Ctrl+F8  show/hide the inventory panel
--   Ctrl+F4  boss: kill (normal death path, rewards + save)
--   Ctrl+F5  boss: arena declares victory (last resort)
--
-- Game facts (build 23764881, CXXHeaderDump; see research/vbtools-01-difficulty-mods.md):
--   ACH_AI_Boss_C : ACH_AI_Base_C  Stage, NumberOfBossStages, ArenaOwner, ProgressBoss(),
--     InitiateDeathEvent(bool Bypass), ResumeIfFrozen(), RecoveredFromStun()
--   ACH_AI_Base_C  Health, MaxHealth, ShieldHealth, ArmourHealth, UnstuckImmunity?,
--     HasOneHitDeathProtection?, Frozen?, Staggered?, IsStaggered?
--   ABP_BossFightArena_Master_C  BossActor, Completed?, BossDefeated()
--   ACH_LimaCharacter_C  Weapon01Slots / Weapon02Slots : TArray<FSTR_StackInformation>,
--     PrimaryWeaponBase / SecondaryWeaponBase, RecalculateMods(bool RecalculateAll?)
--   ABP_Weapon_Base_C    CurrentlyAttachedMods : TArray<UAC_Mod_Master_C*>
--   UAC_Mod_Master_C     ModDetails, ExecutionSlotIndex, ExecutionFrequency, CalculateExecutions(Weapon)
--   UPDA_MasterDetails_C ModName (FText)
--   UGI_LimaGameInstance_C LatestSaveGame -> UBP_SaveGame_Lima_C.RunNumber

local BOSS_CLASSES = {
    "CH_AI_Boss_C", "CH_AI_BS_Boss_01_C", "CH_AI_BS_Boss_02_C", "CH_AI_Boss_03_C",
    "CH_AI_BS_Boss_04_C", "CH_AI_BS_Boss_05_C",
}
local ARENA_CLASSES = { "BP_BossFightArena_Master_C", "BP_BossFightArena_Master_Boss_01_C" }
local BOSS_BASE_PATH = "/Game/ProjectLima/Blueprints/Characters/Enemies/Boss/CH_AI_Boss.CH_AI_Boss_C"

-- UE4SS.log is truncated on every launch; VB_mods.log keeps all VB mods' lines across restarts.
local MODS_LOG = (os.getenv("LOCALAPPDATA") or ".") .. "\\VOIDBREAKER\\Saved\\VB_mods.log"

local function log(msg)
    print("[VBTools] " .. msg .. "\n")
    local f = io.open(MODS_LOG, "a")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S"), " [VBTools] ", msg, "\n"); f:close() end
end

local function valid(obj)
    return obj ~= nil and obj:IsValid()
end

local function isInstance(obj)
    return valid(obj) and not obj:GetFullName():find("Default__", 1, true)
end

-- Level sequences (boss intro/outro cinematics) carry their own copies of the boss actor,
-- e.g. .../LS_Biome05_Boss5_Intro:MovieScene_0.CH_AI_BS_Boss_05_C_UAID_... (self-test 2026-11-04).
local function isGameplayBoss(obj)
    return isInstance(obj) and not obj:GetFullName():find(":MovieScene", 1, true)
end

-- 0 when the value is neither a TArray nor a table: after the 2026-11-05 game update a weapon
-- slot array came back as a TrivialObject (unsupported property type) and `#arr` threw,
-- which disabled the whole inventory panel.
local function len(arr)
    local ok, n = pcall(function() return arr:GetArrayNum() end)
    if ok and type(n) == "number" then return n end
    local ok2, n2 = pcall(function() return #arr end)
    return (ok2 and type(n2) == "number") and n2 or 0
end

local function try(label, fn)
    local ok, err = pcall(fn)
    log(label .. (ok and " ok" or (" FAILED: " .. tostring(err))))
    return ok
end

-- The controller's pawn, not FindFirstOf("CH_LimaCharacter_C"): VBMP's aggro stand-ins are
-- CH_LimaCharacter_C actors too.
local function player()
    local pc = FindFirstOf("PC_LimaPlayerController_C")
    local char = nil
    if valid(pc) then pcall(function() char = pc.Pawn end) end
    if valid(char) then return char end
    return nil
end

---------------------------------------------------------------------------------------------
-- Boss rescue, escalating from gentle to forceful. Each action logs state before and after.

local function findBosses()
    local found, seen = {}, {}
    local function add(obj)
        if isGameplayBoss(obj) then
            local key = obj:GetFullName()
            if not seen[key] then
                seen[key] = true
                table.insert(found, obj)
            end
        end
    end
    for _, cls in ipairs(BOSS_CLASSES) do
        for _, b in ipairs(FindAllOf(cls) or {}) do add(b) end
    end
    for _, cls in ipairs(ARENA_CLASSES) do
        for _, a in ipairs(FindAllOf(cls) or {}) do
            if isInstance(a) then add(a.BossActor) end
        end
    end
    return found
end

-- ForEachUObject crashed the game twice (access violation, 2026-11-04), so there is no full
-- object scan any more: bosses are found by class name and through their arenas only.
local function findBossesDeep()
    return findBosses()
end

local function get(obj, prop)
    local ok, v = pcall(function() return obj[prop] end)
    if ok then return v end
    return "?"
end

local function bossSummary(boss)
    return string.format("stage %s/%s  hp %.0f/%.0f",
        tostring(get(boss, "Stage")), tostring(get(boss, "NumberOfBossStages")),
        tonumber(get(boss, "Health")) or -1, tonumber(get(boss, "MaxHealth")) or -1)
end

local function report(boss, tag)
    local arena = get(boss, "ArenaOwner")
    local arenaDone = valid(arena) and tostring(get(arena, "Completed?")) or "no arena"
    log(string.format(
        "%s %s | %s shield %.0f armour %.0f | unstuckImmunity=%s oneHitProtect=%s frozen=%s staggered=%s/%s | arena completed=%s",
        tag, boss:GetFullName(), bossSummary(boss),
        tonumber(get(boss, "ShieldHealth")) or -1, tonumber(get(boss, "ArmourHealth")) or -1,
        tostring(get(boss, "UnstuckImmunity?")), tostring(get(boss, "HasOneHitDeathProtection?")),
        tostring(get(boss, "Frozen?")), tostring(get(boss, "Staggered?")), tostring(get(boss, "IsStaggered?")),
        arenaDone))
end

local bossActions = {
    unstick = function(boss)
        try("clear UnstuckImmunity?", function() boss["UnstuckImmunity?"] = false end)
        try("clear HasOneHitDeathProtection?", function() boss["HasOneHitDeathProtection?"] = false end)
        try("ResumeIfFrozen", function() boss:ResumeIfFrozen() end)
        try("RecoveredFromStun", function() boss:RecoveredFromStun() end)
    end,
    stage = function(boss)
        try("ProgressBoss", function() boss:ProgressBoss() end)
    end,
    kill = function(boss)
        try("InitiateDeathEvent(false)", function() boss:InitiateDeathEvent(false) end)
    end,
    arena = function(boss)
        local arena = get(boss, "ArenaOwner")
        if valid(arena) then
            try("arena BossDefeated", function() arena:BossDefeated() end)
        else
            log("no ArenaOwner on this boss")
        end
    end,
}

-- Must run on the game thread.
local function bossAction(name)
    local bosses = findBossesDeep()
    log(name .. ": " .. #bosses .. " boss(es) found")
    for _, boss in ipairs(bosses) do
        report(boss, "before")
        if bossActions[name] then bossActions[name](boss) end
        report(boss, "after ")
    end
end

---------------------------------------------------------------------------------------------
-- Mod fusion: three identical mods on one weapon -> one mod that executes one extra time.
-- Rides on the game's repeater mechanic: every attached UAC_Mod_Master_C has
-- ExecutionFrequency, recomputed by CalculateExecutions(Weapon) on each mod recalculation and
-- then read by the effect functions. A post-hook on CalculateExecutions adds our bonus right
-- after the game's own count, so attached (stat) effects see it too.
-- Bonuses are keyed by weapon + mod asset and stored with the save's RunNumber, so a new run
-- starts clean even if it finds the same mod again.

local SLOT_FIELDS = { "Weapon01Slots", "Weapon02Slots" }
local WEAPON_FIELDS = { "PrimaryWeaponBase", "SecondaryWeaponBase" }
local F_DETAILS = "MasterDetails_20_02C613244058148ADEB15795ACD96292"
local F_FILLED = "Filled?_33_5C891A614487B4DFADEDEC96D8EB932C"
local F_STATE = "SlotState_36_BE62F19C4175C0B12D149C9ABACD7170"
local F_FREQ = "Frequency_39_1700236B4372FCDEF705FAB8AA0FC19A"
local F_REPEATER = "IsRepeaterHeader?_47_338167BE44EDD853323F96BB05903841"
local F_CHASSIS = "IsChassisMod?_49_70BE48DC4CAAD893AD959C9AF898B1E8"
local CALC_EXEC = "/Game/ProjectLima/Blueprints/Mods/Weapon/AC_Mod_Master.AC_Mod_Master_C:CalculateExecutions"
local SAVED_DIR = (os.getenv("LOCALAPPDATA") or ".") .. "\\VOIDBREAKER\\Saved"
local FUSE_FILE = SAVED_DIR .. "\\VBTools_fusion.txt"

local fusion = { run = nil, bonus = { {}, {} } }   -- bonus[weaponIndex][modFullName] = extra executions
local hookCalls = 0                                -- post-hook calls
local preCalls = 0

local function currentRun()
    local gi = FindFirstOf("GI_LimaGameInstance_C")
    if not valid(gi) then return nil end
    local save = gi.LatestSaveGame
    if not valid(save) then return nil end
    return tostring(save.RunNumber)
end

local function saveFusion()
    local f = io.open(FUSE_FILE, "w")
    if not f then log("cannot write " .. FUSE_FILE); return end
    f:write("run=" .. tostring(fusion.run) .. "\n")
    for w = 1, 2 do
        for name, n in pairs(fusion.bonus[w]) do f:write(w .. "|" .. name .. "|" .. n .. "\n") end
    end
    f:close()
end

local function loadFusion()
    fusion = { run = nil, bonus = { {}, {} } }
    local f = io.open(FUSE_FILE, "r")
    if not f then return end
    for line in f:lines() do
        local run = line:match("^run=(.*)$")
        if run then
            fusion.run = run
        else
            local w, name, n = line:match("^(%d)|(.+)|(%d+)$")
            if w then fusion.bonus[tonumber(w)][name] = tonumber(n) end
        end
    end
    f:close()
end

-- Drop bonuses from an earlier run; call before reading or changing them.
local function syncRun()
    local run = currentRun()
    if run == nil then return end
    if fusion.run ~= run then
        if fusion.run ~= nil then log("new run " .. run .. " (was " .. tostring(fusion.run) .. "), fusion bonuses cleared") end
        fusion = { run = run, bonus = { {}, {} } }
        saveFusion()
    end
end

local function weaponIndexOf(char, weapon)
    for w, field in ipairs(WEAPON_FIELDS) do
        local wb = char[field]
        if valid(wb) and wb:GetAddress() == weapon:GetAddress() then return w end
    end
    return nil
end

local function applyBonus(comp)
    if not valid(comp) then return end
    local char = comp.CharacterRef
    local details = comp.ModDetails
    if not valid(char) or not valid(details) then return end
    local owner = comp:GetOwner()
    if not valid(owner) then return end
    local w = weaponIndexOf(char, owner)
    if not w then return end
    local extra = fusion.bonus[w][details:GetFullName()]
    if extra and extra > 0 then
        comp.ExecutionFrequency = comp.ExecutionFrequency + extra
    end
end

-- Post-hook is the intended path. If this UE4SS build only fires the pre-hook for Blueprint
-- functions (hookCalls stays 0), fall back to bumping right after the current frame's work:
-- later than ideal for stat effects, still in time for per-shot effects. F7 shows which ran.
local function onPre(ctx)
    preCalls = preCalls + 1
    if hookCalls == 0 and preCalls > 3 then
        local comp = ctx:get()
        ExecuteInGameThreadWithDelay(0, function() pcall(applyBonus, comp) end)
    end
end

local function onPost(ctx)
    hookCalls = hookCalls + 1
    pcall(applyBonus, ctx:get())
end

local hookRegistered = false
local function tryRegisterHook()
    if hookRegistered then return true end
    local ok = pcall(function() RegisterHook(CALC_EXEC, onPre, onPost) end)
    if ok then
        hookRegistered = true
        log("hooked " .. CALC_EXEC)
    end
    return hookRegistered
end

-- Not registered while fusion is disabled (see FUSION_ENABLED): the hook would run on every
-- mod recalculation for nothing. When fusion comes back, register it from a game-thread loop
-- (LoopInGameThreadWithDelay), never LoopAsync.

local function modName(details)
    local ok, s = pcall(function() return details.ModName:ToString() end)
    if ok and s and s ~= "" then return s end
    return details:GetFName():ToString()
end

-- All fusable triples: { w, key, name, idx = {slot indices} } (first three of each group).
local function findTriples(char)
    local triples = {}
    for w, field in ipairs(SLOT_FIELDS) do
        local slots = char[field]
        local groups, order = {}, {}
        for i = 1, len(slots) do
            local s = slots[i]
            local details = s[F_DETAILS]
            local filled = s[F_FILLED] == true and valid(details)
            local special = s[F_REPEATER] == true or s[F_CHASSIS] == true
            if filled and not special then
                local key = details:GetFullName()
                if not groups[key] then groups[key] = { details = details, idx = {} }; table.insert(order, key) end
                table.insert(groups[key].idx, i)
            end
        end
        for _, key in ipairs(order) do
            local g = groups[key]
            if #g.idx >= 3 then
                table.insert(triples, { w = w, key = key, name = modName(g.details), idx = { g.idx[1], g.idx[2], g.idx[3] } })
            end
        end
    end
    return triples
end

local function emptyTemplate(slots)
    for i = 1, len(slots) do
        local s = slots[i]
        if s[F_FILLED] ~= true then return s end
    end
    return nil
end

local function clearSlot(s, template)
    if template then
        s[F_STATE] = template[F_STATE]
        s[F_FREQ] = template[F_FREQ]
    end
    s[F_FILLED] = false
    s[F_REPEATER] = false
    s[F_CHASSIS] = false
    local ok = pcall(function() s[F_DETAILS] = nil end)
    if not ok then s[F_DETAILS] = CreateInvalidObject() end
end

-- DISABLED (self-test 2026-11-04): calling RecalculateMods(true) from outside removed every
-- attached mod component (17 -> 0) without re-adding them, and RecalculateModsEvent afterwards
-- crashed the game. The game's repeaters also turned out to work by attaching extra copies of
-- a component (same ExecutionSlotIndex, ExecutionFrequency stays 1), not by raising
-- ExecutionFrequency. Redesign: attach one extra copy via BP_Weapon_Base_C.AttachMod after the
-- game's own recalculation finishes, verified on a throwaway save first.
local FUSION_ENABLED = false

-- Must run on the game thread.
local function fuse(char, t)
    if not FUSION_ENABLED then
        log("fuse is disabled until it is redesigned (see comment above fuse)")
        return
    end
    syncRun()
    local slots = char[SLOT_FIELDS[t.w]]
    local template = emptyTemplate(slots)
    clearSlot(slots[t.idx[2]], template)
    clearSlot(slots[t.idx[3]], template)
    fusion.bonus[t.w][t.key] = (fusion.bonus[t.w][t.key] or 0) + 1
    saveFusion()
    log(string.format("FUSED weapon %d: %s (slots %d+%d+%d) -> bonus +%d executions",
        t.w, t.key, t.idx[1], t.idx[2], t.idx[3], fusion.bonus[t.w][t.key]))
    char:RecalculateMods(true)
end

local function fusionBonus(w, key)
    return fusion.bonus[w][key] or 0
end

local function fusionReport()
    local char = player()
    if not char then log("fusion report: no player"); return end
    syncRun()
    log("fusion report: run " .. tostring(fusion.run) .. ", hook " .. (hookRegistered and "on" or "OFF") ..
        ", CalculateExecutions pre " .. preCalls .. " / post " .. hookCalls)
    for w, field in ipairs(WEAPON_FIELDS) do
        local weapon = char[field]
        if valid(weapon) then
            local mods = weapon.CurrentlyAttachedMods
            for i = 1, len(mods) do
                local m = mods[i]
                if valid(m) and valid(m.ModDetails) then
                    local name = m.ModDetails:GetFullName()
                    local b = fusionBonus(w, name)
                    log(string.format("  weapon %d slot %d  x%d%s  %s", w, m.ExecutionSlotIndex,
                        m.ExecutionFrequency, b > 0 and (" (fused +" .. b .. ")") or "", name))
                end
            end
        end
    end
end

---------------------------------------------------------------------------------------------
-- Save snapshot from inside the game: copies the last save the game wrote to disk into the
-- same slot folder the VBSaves.bat menu uses (restore stays outside the game).

local SAVE_FILE = SAVED_DIR .. "\\SaveGames\\LimaSaveGame.sav"
local SLOT_ROOT = (os.getenv("USERPROFILE") or ".") .. "\\vbmp\\save-slots"

local function saveSnapshot()
    local src = io.open(SAVE_FILE, "rb")
    if not src then log("snapshot: cannot read " .. SAVE_FILE); return nil end
    local data = src:read("a")
    src:close()
    local name = "ingame-" .. os.date("%Y%m%d-%H%M%S")
    local dir = SLOT_ROOT .. "\\" .. name
    os.execute('mkdir "' .. dir .. '" >nul 2>nul')
    local dst = io.open(dir .. "\\LimaSaveGame.sav", "wb")
    if not dst then log("snapshot: cannot write " .. dir); return nil end
    dst:write(data)
    dst:close()
    log("snapshot saved as slot '" .. name .. "' (" .. #data .. " bytes)")
    return name
end

---------------------------------------------------------------------------------------------
-- Out-of-run progression from inside a run: push the game's own menu widgets onto its menu
-- stack, exactly how its terminals open them (purchases go through the game's own logic).
--   UPL_GameStatics::GetRootWidget(PlayerController) -> UVB_RootWidget (game C++, UHT dump)
--   UVB_RootWidget::PushWidgetToMenuStack(TSubclassOf<UCommonActivatableWidget>)

local MENUS = {
    perma = "/Game/ProjectLima/UI/Widgets/Upgrades/PermaUpgrades/WBP_PermaUpgrades_02",
    research = "/Game/ProjectLima/UI/Widgets/Gameplay/WBP_Researcher_Main",
}

local function widgetClass(pkg)
    local name = pkg:match("([^/]+)$")
    local path = pkg .. "." .. name .. "_C"
    local c = StaticFindObject(path)
    if valid(c) then return c end
    -- Cooked builds only contain the generated class, so load it by its full class path
    -- (LoadAsset(package) loads nothing - self-test 2026-11-04).
    pcall(LoadAsset, path)
    c = StaticFindObject(path)
    if valid(c) then return c end
    return nil
end

-- Must run on the game thread.
local function openMenu(kind)
    local pkg = MENUS[kind]
    if not pkg then log("openMenu: unknown " .. tostring(kind)); return false end
    local cls = widgetClass(pkg)
    if not cls then log("openMenu: class not loadable " .. pkg); return false end
    local pc = FindFirstOf("PC_LimaPlayerController_C")
    local statics = StaticFindObject("/Script/VOIDBREAKER.Default__PL_GameStatics")
    if not valid(pc) or not valid(statics) then log("openMenu: no controller/statics"); return false end
    local root = statics:GetRootWidget(pc)
    if not valid(root) then log("openMenu: no root widget"); return false end
    local w = root:PushWidgetToMenuStack(cls)
    log("openMenu " .. kind .. ": " .. (valid(w) and w:GetFullName() or "push returned nothing"))
    return valid(w)
end

---------------------------------------------------------------------------------------------

loadFusion()

local function onGameThread(label, fn)
    return function()
        ExecuteInGameThread(function()
            local ok, err = pcall(fn)
            if not ok then log(label .. " FAILED: " .. tostring(err)) end
        end)
    end
end

RegisterKeyBindAsync(Key.F1, { ModifierKey.CONTROL }, onGameThread("report", function()
    local bosses = findBossesDeep()
    log("report: " .. #bosses .. " boss(es) found")
    for _, boss in ipairs(bosses) do report(boss, "state ") end
end))
RegisterKeyBindAsync(Key.F2, { ModifierKey.CONTROL }, onGameThread("unstick", function() bossAction("unstick") end))
RegisterKeyBindAsync(Key.F3, { ModifierKey.CONTROL }, onGameThread("stage", function() bossAction("stage") end))
RegisterKeyBindAsync(Key.F4, { ModifierKey.CONTROL }, onGameThread("kill", function() bossAction("kill") end))
RegisterKeyBindAsync(Key.F5, { ModifierKey.CONTROL }, onGameThread("arena", function() bossAction("arena") end))
RegisterKeyBindAsync(Key.F6, { ModifierKey.CONTROL }, onGameThread("fuse", function()
    local char = player()
    if not char then log("fuse: no player"); return end
    local triples = findTriples(char)
    if #triples == 0 then log("fuse: no weapon has three identical mods"); return end
    fuse(char, triples[1])
end))
RegisterKeyBindAsync(Key.F7, { ModifierKey.CONTROL }, onGameThread("fusion report", fusionReport))

local ui = require("ui")
ui.start({
    log = log,
    valid = valid,
    player = player,
    findBosses = findBosses,
    bossSummary = bossSummary,
    bossAction = bossAction,
    findTriples = findTriples,
    fuse = fuse,
    fusionBonus = fusionBonus,
    saveSnapshot = saveSnapshot,
    openMenu = openMenu,
})
RegisterKeyBindAsync(Key.F8, { ModifierKey.CONTROL }, function() ui.toggle() end)

-- Remote control for self-tests: Saved\VBTools_cmd.txt with one of the words below.
local REMOTE = {
    report = function()
        local bosses = findBossesDeep()
        log("report: " .. #bosses .. " boss(es) found")
        for _, boss in ipairs(bosses) do report(boss, "state ") end
    end,
    unstick = function() bossAction("unstick") end,
    stage = function() bossAction("stage") end,
    kill = function() bossAction("kill") end,
    arena = function() bossAction("arena") end,
    fusionreport = fusionReport,
    triples = function()
        local char = player()
        for _, t in ipairs(char and findTriples(char) or {}) do log("triple: weapon " .. t.w .. " " .. t.name) end
    end,
    perma = function() openMenu("perma") end,
    research = function() openMenu("research") end,
    snapshot = saveSnapshot,
}
LoopInGameThreadWithDelay(500, function()
    local path = SAVED_DIR .. "\\VBTools_cmd.txt"
    local f = io.open(path, "r")
    if not f then return end
    local cmd = (f:read("l") or ""):match("^%s*(%w+)")
    f:close()
    os.remove(path)
    log("command: " .. tostring(cmd))
    local fn = REMOTE[cmd]
    if fn then
        local ok, err = pcall(fn)
        if not ok then log("command " .. cmd .. " FAILED: " .. tostring(err)) end
    end
end)

log("loaded - Ctrl+F1..F5 boss, F6 fuse, F7 fusion report, F8 panel on/off; panel shows in the inventory")

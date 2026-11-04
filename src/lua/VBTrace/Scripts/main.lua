-- VBTrace: event probe + destruction record/replay (research tool, single player).
--
-- Probe: hooks every candidate sync entry point from docs/sync-design.md and only observes.
-- Every 10 s it logs how often each one fired; the first calls of each hook are logged with
-- their arguments; all events go to %LOCALAPPDATA%\VOIDBREAKER\Saved\VBTrace_events.log.
-- Native hooks (field system, geometry collection, GameplayStatics damage) catch every source
-- and show whether the Blueprint-level entry points miss anything.
--
-- Record / replay (Ctrl+F9 start/stop recording, Ctrl+F11 replay):
-- records every ChaosFromPool, per-object pre-destructible call (DestroyObject, DashDestroy,
-- MegaDestroy, WakeObject, PermanentlyDestroy) and SpawnTinyDST with timing, saved to
-- VBTrace_recording.lua so it survives a game restart. Replay re-issues the same calls with
-- the same arguments and timing; objects are found again by their stable UAID name.
--
-- Game facts (build 23764881, CXXHeaderDump; asset paths from the pak file list):
--   BP_ChaosPoolManager_C.ChaosFromPool(FTransform, float ExternalStrain, float InternalStrain,
--     Enum_ElementalType, bool RemoveAnchors?, float RadialMagnitude, Enum_ChaosDirectionType,
--     FVector VelocityDirection, bool WakeMega?, out ChaosActor)
--   BP_PreDestructibleItem_Master_C : AStaticMeshActor  DestroyObject(FVector, bool IsFieldExplosive?,
--     int32 FaceIndex), DashDestroy(FVector, double Size), MegaDestroy(FVector),
--     WakeObject(Enum_ElementalType, int32 HitIndex, bool FromDash?, FVector Origin), PermanentlyDestroy()
--   PC_LimaPlayerController_C.SpawnTinyDST(FVector)

local P = {
    pool = "/Game/ProjectLima/Blueprints/Components/BP_ChaosPoolManager.BP_ChaosPoolManager_C",
    pre = "/Game/ProjectLima/Blueprints/Chaos/DestructibleItems/BP_PreDestructibleItem_Master.BP_PreDestructibleItem_Master_C",
    gc = "/Game/ProjectLima/Blueprints/Chaos/DestructibleItems/BP_DestructibleItem_GC_Master.BP_DestructibleItem_GC_Master_C",
    fproj = "/Game/ProjectLima/Blueprints/Chaos/Fields/FS_ChaosField_Projectile_Master.FS_ChaosField_Projectile_Master_C",
    fdash = "/Game/ProjectLima/Blueprints/Chaos/Fields/FS_ChaosField_Continuous_Dash.FS_ChaosField_Continuous_Dash_C",
    fcont = "/Game/ProjectLima/Blueprints/Chaos/Fields/FS_ChaosField_Continuous_Master.FS_ChaosField_Continuous_Master_C",
    fmaster = "/Game/ProjectLima/Blueprints/Chaos/Fields/FS_MasterField_Chaos.FS_MasterField_Chaos_C",
    pc = "/Game/ProjectLima/Blueprints/Modes/PC_LimaPlayerController.PC_LimaPlayerController_C",
    char = "/Game/FirstPerson/Blueprints/CH_LimaCharacter.CH_LimaCharacter_C",
    weapon = "/Game/ProjectLima/Blueprints/Weapons/BP_Weapon_Base.BP_Weapon_Base_C",
    ai = "/Game/ProjectLima/Blueprints/Characters/Enemies/CH_AI_Base.CH_AI_Base_C",
    boss = "/Game/ProjectLima/Blueprints/Characters/Enemies/Boss/CH_AI_Boss.CH_AI_Boss_C",
    gm = "/Game/ProjectLima/Blueprints/Modes/GM_LimaGameMode.GM_LimaGameMode_C",
    gi = "/Game/ProjectLima/Blueprints/Modes/GI_LimaGameInstance.GI_LimaGameInstance_C",
    throwable = "/Game/ProjectLima/Blueprints/Chaos/DestructibleItems/BP_PreDestructibleItem_Master_Prop_Throwable.BP_PreDestructibleItem_Master_Prop_Throwable_C",
    itemChest = "/Game/ProjectLima/Blueprints/Pickups/BP_ItemChest_Master.BP_ItemChest_Master_C",
    lootChest = "/Game/ProjectLima/Blueprints/Pickups/BP_LootChest_Master.BP_LootChest_Master_C",
    pickupMod = "/Game/ProjectLima/Blueprints/Pickups/Masters/BP_Pickup_Mod_Weapon_Master.BP_Pickup_Mod_Weapon_Master_C",
    pickupConsumable = "/Game/ProjectLima/Blueprints/Pickups/Masters/BP_Pickup_Consumable_Once_Master.BP_Pickup_Consumable_Once_Master_C",
    shopUnit = "/Game/ProjectLima/Blueprints/Gameplay/Shop/BP_ShopUnit_Master.BP_ShopUnit_Master_C",
    lever = "/Game/ProjectLima/Blueprints/Gameplay/PuzzleObjects/BP_PuzzleLever.BP_PuzzleLever_C",
    digiDoor = "/Game/ProjectLima/Blueprints/Gameplay/PuzzleObjects/BP_DigiDoor_Switch.BP_DigiDoor_Switch_C",
    terminal = "/Game/ProjectLima/Blueprints/Gameplay/BP_Terminal.BP_Terminal_C",
    zipline = "/Game/ProjectLima/Blueprints/Environment/BP_ZipLine.BP_ZipLine_C",
    teleporter = "/Game/ProjectLima/Blueprints/Gameplay/Teleporter/BP_Teleporter.BP_Teleporter_C",
    mainLift = "/Game/ProjectLima/Blueprints/Gameplay/Teleporter/BP_MainLift.BP_MainLift_C",
    obelisk = "/Game/ProjectLima/Blueprints/Gameplay/Obelisks/BP_Interactable_Obelisk_Master.BP_Interactable_Obelisk_Master_C",
    corruptor = "/Game/ProjectLima/Blueprints/Gameplay/Corruptors/BP_Interactable_Corruptor_Master.BP_Interactable_Corruptor_Master_C",
    signalOps = "/Game/ProjectLima/Blueprints/Gameplay/PuzzleObjects/BP_SignalOperations.BP_SignalOperations_C",
}

-- { label, function path, record kind or nil }
local HOOKS = {
    { "chaos.ChaosFromPool", P.pool .. ":ChaosFromPool", "chaos" },
    { "dst.DestroyObject", P.pre .. ":DestroyObject", "dst" },
    { "dst.DashDestroy", P.pre .. ":DashDestroy", "dst" },
    { "dst.MegaDestroy", P.pre .. ":MegaDestroy", "dst" },
    { "dst.WakeObject", P.pre .. ":WakeObject", "dst" },
    { "dst.PermanentlyDestroy", P.pre .. ":PermanentlyDestroy", "dst" },
    { "dst.ReceiveAnyDamage", P.pre .. ":ReceiveAnyDamage" },
    { "dst.Swap", P.pre .. ":Swap" },
    { "dst.SpawnGC", P.pre .. ":SpawnGC" },
    { "dst.SpawnGC_Building", P.pre .. ":SpawnGC_Building" },
    { "gc.ForceObjectState", P.gc .. ":ForceObjectState" },
    { "tiny.SpawnTinyDST", P.pc .. ":SpawnTinyDST", "tiny" },
    { "field.Projectile.Detonate", P.fproj .. ":Detonate" },
    { "field.Projectile.Explosion", P.fproj .. ":Explosion" },
    { "field.Dash.Detonate", P.fdash .. ":Detonate" },
    { "field.Continuous.Detonate", P.fcont .. ":Detonate" },
    { "field.Master.CE_Trigger", P.fmaster .. ":CE_Trigger" },
    { "char.PlayMeleeSwipe", P.char .. ":PlayMeleeSwipe" },
    { "char.DashEnd", P.char .. ":DashEnd" },
    { "char.DealDamageToPlayer", P.char .. ":DealDamageToPlayer" },
    { "char.StartFire", P.char .. ":StartFire" },
    { "char.ThrowableHit", P.char .. ":ThrowableHit" },
    { "char.AddCurrency", P.char .. ":AddCurrency" },
    { "weapon.FireServerProjectile", P.weapon .. ":FireServerProjectile" },
    { "weapon.FireProjectileFake", P.weapon .. ":FireProjectileFake" },
    { "weapon.ShotFired", P.weapon .. ":ShotFired" },
    { "ai.ApplyDamage", P.ai .. ":ApplyDamage" },
    { "ai.DeathEvent", P.ai .. ":DeathEvent" },
    { "ai.SpawnEnemyImmediate", P.ai .. ":SpawnEnemyImmediate" },
    { "ai.PrimaryAttack", P.ai .. ":PrimaryAttack" },
    { "ai.SecondaryAttack", P.ai .. ":SecondaryAttack" },
    { "ai.SpawnMoney", P.ai .. ":SpawnMoney" },
    { "ai.ItemPickupSpawn", P.ai .. ":ItemPickupSpawn" },
    { "boss.ProgressBoss", P.boss .. ":ProgressBoss" },
    { "boss.DeathEvent", P.boss .. ":DeathEvent" },
    { "pc.FireProjectileFromPool", P.pc .. ":FireProjectileFromPool" },
    { "pc.FreezeTime", P.pc .. ":FreezeTime" },
    { "pc.SetLayerStatus", P.pc .. ":SetLayerStatus" },
    { "gm.GenerateWorld", P.gm .. ":GenerateWorld" },
    { "gm.AssignScenarios", P.gm .. ":AssignScenarios" },
    { "gm.AddEnemyPool", P.gm .. ":AddEnemyPool" },
    { "gm.RemoveFromEnemyPool", P.gm .. ":RemoveFromEnemyPool" },
    { "gm.SetGameLevel", P.gm .. ":SetGameLevel" },
    { "gm.TransitionBiome", P.gm .. ":TransitionBiome" },
    { "gi.SaveGameData", P.gi .. ":SaveGameData" },
    { "gi.SaveToSwitchActors", P.gi .. ":SaveToSwitchActors" },
    -- interactions (research/phase2-04-interactions.md)
    { "char.PickUpThrowable", P.char .. ":PickUpThrowable" },
    { "char.ThrowThrowable", P.char .. ":ThrowThrowable" },
    { "char.DropThrowable", P.char .. ":DropThrowable" },
    { "char.EnemyHitWithThrowable", P.char .. ":EnemyHitWithThrowable" },
    { "char.HandleInteractTether", P.char .. ":HandleInteractTether" },
    { "char.Melee_CheckPullEnemy", P.char .. ":Melee_CheckPullEnemy" },
    { "char.StartGrapple", P.char .. ":StartGrapple" },
    { "char.StopGrapple", P.char .. ":StopGrapple" },
    { "char.FireInteract", P.char .. ":FireInteract" },
    { "char.AbilityFire", P.char .. ":AbilityFire" },
    { "char.BeginWallRun", P.char .. ":BeginWallRun" },
    { "char.BeginSlide", P.char .. ":BeginSlide" },
    { "throwable.SetLaunchVector", P.throwable .. ":SetLaunchVector" },
    { "throwable.Primed?", P.throwable .. ":Primed?" },
    { "throwable.PrimeHit", P.throwable .. ":PrimeHit" },
    { "throwable.ProjectileStopped", P.throwable .. ":ProjectileStopped" },
    { "interact.ItemChest", P.itemChest .. ":InteractObjectQuick" },
    { "interact.LootChest", P.lootChest .. ":InteractObjectQuick" },
    { "interact.PickupMod", P.pickupMod .. ":InteractObjectQuick" },
    { "interact.PickupConsumable", P.pickupConsumable .. ":InteractObjectQuick" },
    { "interact.ShopUnit", P.shopUnit .. ":InteractObjectQuick" },
    { "interact.PuzzleLever", P.lever .. ":InteractObjectQuick" },
    { "interact.DigiDoorSwitch", P.digiDoor .. ":InteractObjectQuick" },
    { "interact.Terminal", P.terminal .. ":InteractObjectQuick" },
    { "interact.ZipLine", P.zipline .. ":InteractObjectQuick" },
    { "interact.Teleporter", P.teleporter .. ":InteractObjectQuick" },
    { "interact.MainLift", P.mainLift .. ":InteractObjectQuick" },
    { "interact.Obelisk", P.obelisk .. ":InteractObjectQuick" },
    { "interact.Corruptor", P.corruptor .. ":InteractObjectQuick" },
    { "chest.OpenChest", P.itemChest .. ":OpenChest" },
    { "zip.LandOnSpline", P.zipline .. ":LandOnSpline" },
    { "zip.ExitZipline", P.zipline .. ":ExitZipline" },
    { "signal.Lever.Switch", P.lever .. ":Switch" },
    { "signal.SignalOperations.Switch", P.signalOps .. ":Switch" },
    { "n.FieldSystem.ApplyPhysicsField", "/Script/FieldSystemEngine.FieldSystemComponent:ApplyPhysicsField" },
    { "n.FieldSystem.AddFieldCommand", "/Script/FieldSystemEngine.FieldSystemComponent:AddFieldCommand" },
    { "n.GC.ApplyPhysicsField", "/Script/GeometryCollectionEngine.GeometryCollectionComponent:ApplyPhysicsField" },
    { "n.GC.ApplyExternalStrain", "/Script/GeometryCollectionEngine.GeometryCollectionComponent:ApplyExternalStrain" },
    { "n.GC.CrumbleActiveClusters", "/Script/GeometryCollectionEngine.GeometryCollectionComponent:CrumbleActiveClusters" },
    { "n.GC.RemoveAllAnchors", "/Script/GeometryCollectionEngine.GeometryCollectionComponent:RemoveAllAnchors" },
    { "n.Statics.ApplyDamage", "/Script/Engine.GameplayStatics:ApplyDamage" },
    { "n.Statics.ApplyPointDamage", "/Script/Engine.GameplayStatics:ApplyPointDamage" },
    { "n.Statics.ApplyRadialDamage", "/Script/Engine.GameplayStatics:ApplyRadialDamage" },
    { "n.Statics.ApplyRadialDamageWithFalloff", "/Script/Engine.GameplayStatics:ApplyRadialDamageWithFalloff" },
}

local SUMMARY_MS = 10000
local DETAIL_PER_HOOK = 3         -- first N calls of each hook logged with arguments
local FILE_LINES_PER_WINDOW = 60  -- per hook per 10 s window, to keep the event file sane
local SAVED = (os.getenv("LOCALAPPDATA") or ".") .. "\\VOIDBREAKER\\Saved\\"
local EVENTS_FILE = SAVED .. "VBTrace_events.log"
local RECORDING_FILE = SAVED .. "VBTrace_recording.lua"

-- UE4SS.log is truncated on every launch; VB_mods.log keeps all VB mods' lines across restarts.
local function log(msg)
    print("[VBTrace] " .. msg .. "\n")
    local f = io.open(SAVED .. "VB_mods.log", "a")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S"), " [VBTrace] ", msg, "\n"); f:close() end
end

local function valid(obj)
    return obj ~= nil and obj:IsValid()
end

---------------------------------------------------------------------------------------------
-- argument helpers

local function unwrap(p)
    local ok, v = pcall(function() return p:get() end)
    if ok then return v end
    return p
end

local function shortName(obj)
    local ok, s = pcall(function() return obj:GetFName():ToString() end)
    if ok then return s end
    return "?"
end

local function vec(v)
    return { X = v.X, Y = v.Y, Z = v.Z }
end

local function str(p)
    local v = unwrap(p)
    local t = type(v)
    if t == "number" then return string.format("%.4g", v) end
    if t == "boolean" or t == "string" or t == "nil" then return tostring(v) end
    if t == "userdata" then
        local okv, isValid = pcall(function() return v:IsValid() end)
        if okv then return isValid and shortName(v) or "null" end
        local ok1, s1 = pcall(function() return string.format("(%.0f,%.0f,%.0f)", v.X, v.Y, v.Z) end)
        if ok1 then return s1 end
        local ok2, s2 = pcall(function()
            local tr = v.Translation
            return string.format("T(%.0f,%.0f,%.0f)", tr.X, tr.Y, tr.Z)
        end)
        if ok2 then return s2 end
        local ok3, s3 = pcall(function() return v:ToString() end)
        if ok3 then return s3 end
    end
    return "?"
end

-- Cached: this runs for every hooked event, hundreds of times a second in a fight.
local timeStatics, timeWorld = nil, nil
local function realTime()
    if not valid(timeStatics) then timeStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics") end
    if not valid(timeWorld) then timeWorld = FindFirstOf("PC_LimaPlayerController_C") end
    if valid(timeStatics) and valid(timeWorld) then
        local ok, t = pcall(function() return timeStatics:GetRealTimeSeconds(timeWorld) end)
        if ok and type(t) == "number" then return t end
    end
    return os.clock()
end

---------------------------------------------------------------------------------------------
-- probe

local stats = {}                  -- label -> { total, window, detailed, fileLines }
local fileBuffer = {}
local hooked = {}
local recording = false
local replaying = false
local events = {}                 -- current recording
local t0 = 0

for _, h in ipairs(HOOKS) do stats[h[1]] = { total = 0, window = 0, detailed = 0, fileLines = 0 } end

local function recordEvent(kind, label, self, args)
    local fn = label:match("%.(.+)$")
    local ev = { t = realTime() - t0, kind = kind, fn = fn }
    if kind == "chaos" then
        local xf = unwrap(args[1])
        local r, tr, sc = xf.Rotation, xf.Translation, xf.Scale3D
        ev.xf = {
            Rotation = { X = r.X, Y = r.Y, Z = r.Z, W = r.W },
            Translation = vec(tr),
            Scale3D = vec(sc),
        }
        ev.a = {
            unwrap(args[2]), unwrap(args[3]), unwrap(args[4]), unwrap(args[5]),
            unwrap(args[6]), unwrap(args[7]), vec(unwrap(args[8])), unwrap(args[9]),
        }
    elseif kind == "dst" then
        ev.name = shortName(self)
        ev.cls = self:GetClass():GetFName():ToString()
        ev.loc = vec(self:K2_GetActorLocation())
        ev.n = #args
        ev.a = {}
        for i, p in ipairs(args) do
            local v = unwrap(p)
            if type(v) == "userdata" then
                local ok, t = pcall(vec, v)
                v = ok and t or nil
            end
            ev.a[i] = v
        end
    elseif kind == "tiny" then
        ev.a = { vec(unwrap(args[1])) }
    end
    table.insert(events, ev)
end

local function onHook(h, ctx, ...)
    local label, kind = h[1], h[3]
    local st = stats[label]
    st.total = st.total + 1
    st.window = st.window + 1
    local args = { ... }
    local self = unwrap(ctx)

    local detail = nil
    if st.detailed < DETAIL_PER_HOOK or st.fileLines < FILE_LINES_PER_WINDOW then
        local parts = {}
        for i, p in ipairs(args) do parts[i] = str(p) end
        detail = string.format("%s self=%s args=[%s]%s", label, valid(self) and shortName(self) or "?",
            table.concat(parts, ", "), replaying and " (replay)" or "")
    end
    if st.detailed < DETAIL_PER_HOOK then
        st.detailed = st.detailed + 1
        log("first call: " .. detail)
    end
    if detail and st.fileLines < FILE_LINES_PER_WINDOW then
        st.fileLines = st.fileLines + 1
        table.insert(fileBuffer, string.format("%.3f %s", realTime(), detail))
    end

    if recording and not replaying and kind then
        local ok, err = pcall(recordEvent, kind, label, self, args)
        if not ok then log("record " .. label .. " FAILED: " .. tostring(err)) end
    end
end

local function tryHooks()
    local newly = 0
    for _, h in ipairs(HOOKS) do
        if not hooked[h[1]] then
            local ok = pcall(function()
                RegisterHook(h[2], function(ctx, ...) pcall(onHook, h, ctx, ...) end)
            end)
            if ok then
                hooked[h[1]] = true
                newly = newly + 1
            end
        end
    end
    if newly > 0 then
        local n = 0
        for _ in pairs(hooked) do n = n + 1 end
        log(string.format("hooked %d more (%d/%d)", newly, n, #HOOKS))
    end
end

local function summary()
    local active = {}
    for _, h in ipairs(HOOKS) do
        local st = stats[h[1]]
        if st.window > 0 then table.insert(active, string.format("%s=%d", h[1], st.window)) end
        st.window = 0
        st.fileLines = 0
    end
    if #active > 0 then log("last 10 s: " .. table.concat(active, "  ")) end
    if recording then log("recording: " .. #events .. " events so far") end
    if #fileBuffer > 0 then
        local f = io.open(EVENTS_FILE, "a")
        if f then
            f:write(table.concat(fileBuffer, "\n"), "\n")
            f:close()
        end
        fileBuffer = {}
    end
end

---------------------------------------------------------------------------------------------
-- recording file: a Lua chunk returning the event list

local function serialize(v)
    local t = type(v)
    if t == "number" then return string.format("%.17g", v) end
    if t == "boolean" then return tostring(v) end
    if t == "string" then return string.format("%q", v) end
    if t == "table" then
        local parts = {}
        for k, x in pairs(v) do
            local key = type(k) == "number" and ("[" .. k .. "]") or ("[" .. string.format("%q", k) .. "]")
            table.insert(parts, key .. "=" .. serialize(x))
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "nil"
end

local function saveRecording()
    local f = io.open(RECORDING_FILE, "w")
    if not f then log("cannot write " .. RECORDING_FILE); return end
    f:write("return {\n")
    for _, ev in ipairs(events) do f:write(serialize(ev), ",\n") end
    f:write("}\n")
    f:close()
    log("recording saved: " .. #events .. " events -> " .. RECORDING_FILE)
end

local function loadRecording()
    local chunk = loadfile(RECORDING_FILE)
    if not chunk then return nil end
    local ok, list = pcall(chunk)
    if ok and type(list) == "table" then return list end
    return nil
end

---------------------------------------------------------------------------------------------
-- replay

-- Index the recorded destructibles by FName (contains the UAID), looking them up through
-- FindAllOf on each recorded class; a name used by two instances of the same sublevel is
-- disambiguated by the recorded location. (ForEachUObject crashed the game, 2026-11-04.)
local function indexDestructibles(list)
    local byName, done = {}, {}
    for _, ev in ipairs(list) do
        if ev.kind == "dst" and ev.cls and not done[ev.cls] then
            done[ev.cls] = true
            for _, obj in ipairs(FindAllOf(ev.cls) or {}) do
                if valid(obj) and not obj:GetFullName():find("Default__", 1, true) then
                    local n = shortName(obj)
                    byName[n] = byName[n] or {}
                    table.insert(byName[n], obj)
                end
            end
        end
    end
    return byName
end

local function nearest(list, loc)
    local best, bestD = nil, math.huge
    for _, a in ipairs(list) do
        if valid(a) then
            local p = a:K2_GetActorLocation()
            local d = (p.X - loc.X) ^ 2 + (p.Y - loc.Y) ^ 2 + (p.Z - loc.Z) ^ 2
            if d < bestD then best, bestD = a, d end
        end
    end
    return best, math.sqrt(bestD)
end

local function firstInstance(className)
    for _, o in ipairs(FindAllOf(className) or {}) do
        if valid(o) and not o:GetFullName():find("Default__", 1, true) then return o end
    end
    return nil
end

local function replay()
    local list = loadRecording()
    if not list or #list == 0 then log("replay: no recording at " .. RECORDING_FILE); return end
    local byName = indexDestructibles(list)
    local pool = firstInstance("BP_ChaosPoolManager_C")
    local pc = firstInstance("PC_LimaPlayerController_C")
    local missing, far, ok = 0, 0, 0
    replaying = true
    log(string.format("replay: %d events, chaos pool %s", #list, valid(pool) and "found" or "MISSING"))

    for i, ev in ipairs(list) do
        local target = nil
        if ev.kind == "dst" then
            target = byName[ev.name] and nearest(byName[ev.name], ev.loc)
            if not target then
                missing = missing + 1
            else
                local p = target:K2_GetActorLocation()
                if (p.X - ev.loc.X) ^ 2 + (p.Y - ev.loc.Y) ^ 2 + (p.Z - ev.loc.Z) ^ 2 > 100 ^ 2 then far = far + 1 end
            end
        end
        local delay = math.max(0, math.floor(ev.t * 1000))
        ExecuteInGameThreadWithDelay(delay, function()
            local good, err = pcall(function()
                if ev.kind == "chaos" and valid(pool) then
                    local a = ev.a
                    pool:ChaosFromPool(ev.xf, a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], {})
                elseif ev.kind == "dst" and valid(target) then
                    target[ev.fn](target, table.unpack(ev.a, 1, ev.n or 0))
                elseif ev.kind == "tiny" and valid(pc) then
                    pc:SpawnTinyDST(ev.a[1])
                else
                    error("no target")
                end
            end)
            if good then ok = ok + 1 elseif i <= 5 then log("replay event " .. i .. " (" .. ev.kind .. "." .. ev.fn .. ") FAILED: " .. tostring(err)) end
            if i == #list then
                replaying = false
                log(string.format("replay done: %d/%d applied, %d destructibles not found, %d found >1 m away",
                    ok, #list, missing, far))
            end
        end)
    end
end

---------------------------------------------------------------------------------------------

-- Game-thread loops only: LoopAsync runs Lua on a worker thread while these 90 hooks run Lua
-- in the same state on the game thread - that race corrupted values and crashed (2026-11-04).
local hookLoop
hookLoop = LoopInGameThreadWithDelay(3000, function()
    tryHooks()
    local n = 0
    for _ in pairs(hooked) do n = n + 1 end
    if n == #HOOKS then CancelDelayedAction(hookLoop) end
end)

LoopInGameThreadWithDelay(SUMMARY_MS, summary)

local function toggleRecording()
    if not recording then
        events = {}
        t0 = realTime()
        recording = true
        log("RECORDING started - break things, Ctrl+F9 again to stop")
    else
        recording = false
        log("RECORDING stopped")
        saveRecording()
    end
end

local function startReplay()
    if recording then
        recording = false
        saveRecording()
    end
    local ok, err = pcall(replay)
    if not ok then
        replaying = false
        log("replay FAILED: " .. tostring(err))
    end
end

RegisterKeyBindAsync(Key.F9, { ModifierKey.CONTROL }, function() ExecuteInGameThread(toggleRecording) end)
RegisterKeyBindAsync(Key.F11, { ModifierKey.CONTROL }, function() ExecuteInGameThread(startReplay) end)

-- Remote control for self-tests: Saved\VBTrace_cmd.txt containing record | replay.
LoopInGameThreadWithDelay(500, function()
    local f = io.open(SAVED .. "VBTrace_cmd.txt", "r")
    if not f then return end
    local cmd = (f:read("l") or ""):match("^%s*(%w+)")
    f:close()
    os.remove(SAVED .. "VBTrace_cmd.txt")
    log("command: " .. tostring(cmd))
    if cmd == "record" then toggleRecording() elseif cmd == "replay" then startReplay() end
end)

log("loaded - probe active; Ctrl+F9 record destruction on/off, Ctrl+F11 replay recording")

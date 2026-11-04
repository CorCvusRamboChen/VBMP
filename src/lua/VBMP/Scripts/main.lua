-- VBMP: VOID/BREAKER multiplayer (Phase 2: players see each other move).
--
-- Modules: codec (wire format), transport (Steam P2P via the game's SteamCore plugin, or
-- in-process loopback), session (host/client/loopback roles), puppets (remote players).
-- Control: hotkeys below, or the VBTools inventory panel, which writes commands to
-- Saved\VBMP_cmd.txt and shows Saved\VBMP_status.txt (separate mods cannot share Lua state).
--   Ctrl+Shift+H  host           Ctrl+Shift+J  join a Steam friend who is hosting
--   Ctrl+Shift+L  leave          Ctrl+Shift+G  loopback test (yourself, 2 s late)
-- Optional Saved\VBMP.ini:  autostart=host|client|loopback   host=<SteamID64>   name=<display name>
--
-- Game facts (build 23764881): player CH_LimaCharacter_C (CapsuleComponent), controller
-- PC_LimaPlayerController_C (ReceiveTick, PlayerCameraManager, GetControlRotation).

local codec = require("codec")
local transport = require("transport")
local sessionLib = require("session")
local puppetLib = require("puppets")
local instance = require("instance")

local SAVED = (os.getenv("LOCALAPPDATA") or ".") .. "\\VOIDBREAKER\\Saved\\"
local MODS_LOG = SAVED .. "VB_mods.log"
local INI_FILE = SAVED .. "VBMP.ini"
local TICK_FN = "/Game/ProjectLima/Blueprints/Modes/PC_LimaPlayerController.PC_LimaPlayerController_C:ReceiveTick"
local NET_MS = 16
local LOOPBACK_DELAY = 2.0

-- Slot of this game process ("A"/"B", see instance.lua); nil until claimed. With one game
-- running it is "A", which also serves the legacy VBMP_cmd.txt / VBMP_status.txt used by the
-- VBTools panel.
local slot = nil

-- UE4SS.log is truncated on every launch; VB_mods.log keeps all VB mods' lines across restarts.
local function log(msg)
    local tag = slot and ("[VBMP " .. slot .. "] ") or "[VBMP] "
    print(tag .. msg .. "\n")
    local f = io.open(MODS_LOG, "a")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S"), " ", tag, msg, "\n"); f:close() end
end

-- type check first: a string once reached here and `o:IsValid()` blew up (self-test 2026-11-04)
local function valid(o) return type(o) == "userdata" and o:IsValid() end

---------------------------------------------------------------------------------------------
-- config

local function readIni()
    local cfg = {}
    local f = io.open(INI_FILE, "r")
    if not f then return cfg end
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k then cfg[k] = v end
    end
    f:close()
    return cfg
end

---------------------------------------------------------------------------------------------
-- time and local player

local statics, timeWorld = nil, nil
local function realTime()
    if not valid(statics) then statics = StaticFindObject("/Script/Engine.Default__GameplayStatics") end
    if not valid(timeWorld) then
        timeWorld = FindFirstOf("PC_LimaPlayerController_C")
        if not valid(timeWorld) then timeWorld = FindFirstOf("PC_LimaMainMenuController_C") end
    end
    if valid(statics) and valid(timeWorld) then
        local ok, t = pcall(function() return statics:GetRealTimeSeconds(timeWorld) end)
        if ok and type(t) == "number" then return t end
    end
    -- The main-menu controller of a level that was just left can still pass IsValid while the
    -- call fails; without this the net loop stalled forever (dual test 2026-11-05).
    timeWorld = nil
    return nil
end

-- Session clock. GetRealTimeSeconds counts from the CURRENT world's start, so it jumps back to
-- ~0 on every level change; after a reload the session's timers sat hundreds of seconds in the
-- negative and a client stopped sending (world-sync dual test 2026-11-05). Only forward steps
-- are accumulated.
local clock, lastRaw = 0, nil
local function monoTime()
    local raw = realTime()
    if not raw then return nil end
    if lastRaw and raw > lastRaw then clock = clock + math.min(raw - lastRaw, 0.5) end
    lastRaw = raw
    return clock
end

local player, pc, halfHeight = nil, nil, 88

local aggroLib = require("aggro")

local function localState()
    -- Looked up every time through the current world's controller: a cached pawn/controller from
    -- the previous level can still pass IsValid after a level change (world-sync test 2026-11-05),
    -- and FindFirstOf("CH_LimaCharacter_C") may return an aggro stand-in.
    local p = aggroLib.localPlayer()
    if not valid(p) then return nil end
    if p ~= player then
        player = p
        pcall(function() halfHeight = player.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
    end
    pc = aggroLib.localController()
    local loc = player:K2_GetActorLocation()
    local rot = player:K2_GetActorRotation()
    local pitch = 0
    if valid(pc) then
        local ok, cr = pcall(function() return pc:GetControlRotation() end)
        if ok and cr then pitch = cr.Pitch end
    end
    local level = nil
    pcall(function() level = player:GetWorld():GetFName():ToString() end)
    -- In this mod's Lua state `player.Health` came back as a function value (self-test
    -- 2026-11-04; the same read is a number from another mod's state), so use the game's own
    -- getter CH_LimaCharacter_C.GetPlayerHealth(out CurrentHealth, out MaxHealth) and accept
    -- numbers only.
    local hp, maxHp = nil, nil
    pcall(function()
        local o = {}
        player:GetPlayerHealth(o, o)
        if type(o.CurrentHealth) == "number" then hp = o.CurrentHealth end
        if type(o.MaxHealth) == "number" then maxHp = o.MaxHealth end
    end)
    return { x = loc.X, y = loc.Y, z = loc.Z, yaw = rot.Yaw, pitch = pitch, level = level, hp = hp, maxHp = maxHp }
end

---------------------------------------------------------------------------------------------
-- session lifecycle

local puppets = puppetLib.new(log)
-- Team HUD, toasts and inventory cursors (docs/ui-design.md). It runs its own 50 ms UI loop;
-- hud.frame() is deliberately NOT called from the ReceiveTick hook because its name tags
-- create widgets lazily, and creating objects inside that hook deadlocked the game thread.
local hud = require("hud")
hud.start({ log = log })
local enemies = require("enemies").new(log, hud)
local destruction = require("destruction").new(log)
local saveguard = require("saveguard").new(log)
local worldsync = require("worldsync").new(log)
local damagesync = require("damagesync").new(log)
local downed = require("downed").new(log, hud)
local session = nil
local lastNow = nil

local function stopSession()
    if session then
        if session.mode == "client" then pcall(saveguard.clientStopped) end
        pcall(session.stop)
        log("session stopped")
    end
    session = nil
    puppets.clear()
end

-- Insurance before any online session. Phase 2 worlds are still independent, so the save is
-- the player's own; once the host drives client worlds (Phase 3) clients must not save at all.
local function backupSave(mode)
    local src = io.open(SAVED .. "SaveGames\\LimaSaveGame.sav", "rb")
    if not src then return end
    local data = src:read("a")
    src:close()
    local name = SAVED .. "VBMP_backup_" .. mode .. "_" .. os.date("%Y%m%d-%H%M%S") .. ".sav"
    local dst = io.open(name, "wb")
    if dst then dst:write(data); dst:close(); log("save backed up to " .. name) end
end

-- via: "steam" (default) or "localfile" (two game processes on this PC, slot A <-> slot B)
local function startSession(mode, hostId, via)
    stopSession()
    if mode ~= "loopback" then pcall(backupSave, mode) end
    -- Before anything can save: a client must never write its real save (saveguard.lua).
    if mode == "client" then saveguard.clientStarted() end
    local tr
    if mode == "loopback" then
        tr = transport.loopback(log, LOOPBACK_DELAY)
    elseif via == "localfile" then
        if not slot then log("localfile: no instance slot yet"); return end
        tr = transport.localfile(log, slot)
        if mode == "client" then hostId = tr.peerId end
    else
        tr = transport.steam(log)
    end
    local ok, err = tr.init()
    if not ok then
        log("transport init failed: " .. tostring(err))
        session = { state = "failed", describe = function() return { "联机启动失败：" .. tostring(err) } end,
            update = function() end, stop = function() end }
        return
    end
    local cfg = readIni()
    session = sessionLib.new({
        log = log, transport = tr, puppets = puppets, hud = hud, mode = mode,
        enemies = (mode ~= "loopback") and enemies or nil,
        destruction = (mode ~= "loopback") and destruction or nil,
        worldsync = (mode ~= "loopback") and worldsync or nil,
        damagesync = (mode ~= "loopback") and damagesync or nil,
        downed = (mode ~= "loopback") and downed or nil,
        hostId = hostId or (cfg.host and math.tointeger(tonumber(cfg.host))) or nil,
        name = cfg.name,
    })
    session.start(monoTime() or 0)
end

local function command(cmd)
    log("command: " .. cmd)
    if cmd == "host" then startSession("host")
    elseif cmd == "join" then startSession("client")
    elseif cmd == "loopback" then startSession("loopback")
    elseif cmd == "lanhost" then startSession("host", nil, "localfile")
    elseif cmd == "lanjoin" then startSession("client", nil, "localfile")
    elseif cmd == "leave" then stopSession()
    elseif cmd == "hud" then hud.toggle()
    else log("unknown command " .. cmd) end
end

---------------------------------------------------------------------------------------------
-- loops

local statusTimer, cmdTimer, slotTimer = 0, 0, 2

-- Per-slot files (VBMP_status_A.txt, VBMP_cmd_B.txt, ...); slot A also keeps the legacy names.
local function slotFiles(base, ext)
    local names = {}
    if slot then table.insert(names, SAVED .. base .. "_" .. slot .. ext) end
    if slot == nil or slot == "A" then table.insert(names, SAVED .. base .. ext) end
    return names
end

local function writeStatus()
    local lines = session and session.describe() or { "未联机" }
    if slot then table.insert(lines, 1, "实例：" .. slot) end
    local text = ""
    for _, l in ipairs(lines) do text = text .. l .. "\n" end
    for _, path in ipairs(slotFiles("VBMP_status", ".txt")) do
        local f = io.open(path, "w")
        if f then f:write(text); f:close() end
    end
end

local function readCommand()
    for _, path in ipairs(slotFiles("VBMP_cmd", ".txt")) do
        local f = io.open(path, "r")
        if f then
            local cmd = (f:read("l") or ""):match("^%s*(%w+)")
            f:close()
            os.remove(path)
            if cmd then command(cmd) end
        end
    end
end

local function netStep()
    local now = monoTime()
    if not now then return end
    local dt = lastNow and math.min(now - lastNow, 0.5) or 0
    lastNow = now

    cmdTimer = cmdTimer + dt
    if cmdTimer >= 0.25 then
        cmdTimer = 0
        readCommand()
    end

    if session then
        session.update(now, dt, localState())
        if valid(player) then puppets.spawnPending({ now = now, world = player:GetWorld() }) end
        if enemies.role == "client" then
            local ok, err = pcall(enemies.clientTick, valid(player) and player:GetWorld() or nil)
            if not ok then log("enemies client tick failed: " .. tostring(err)) end
        end
    end

    statusTimer = statusTimer + dt
    if statusTimer >= 1 then statusTimer = 0; writeStatus() end
end

local function renderStep()
    if not session then return end
    local now = monoTime()
    if not now or not valid(player) then return end
    local cameraYaw = nil
    if valid(pc) then
        pcall(function() cameraYaw = pc.PlayerCameraManager:GetCameraRotation().Yaw end)
    end
    local level = nil
    pcall(function() level = player:GetWorld():GetFName():ToString() end)
    puppets.tick({ now = now, level = level, halfHeight = halfHeight, cameraYaw = cameraYaw })
    if enemies.role == "client" then enemies.clientRender(now) end
    -- Data only (no widget creation) - safe inside the tick hook.
    for id, p in pairs(puppets.peers) do
        if valid(p.actor) and not p.actor.bHidden then
            local l = p.actor:K2_GetActorLocation()
            hud.setTeammateWorldPos(id, l.X, l.Y, l.Z + 200)
        else
            hud.setTeammateWorldPos(id, nil)
        end
    end
end

local errors = 0
local function guarded(label, fn)
    local ok, err = pcall(fn)
    if not ok then
        errors = errors + 1
        if errors <= 10 then log(label .. " error: " .. tostring(err)) end
    end
end

-- All loops run ON THE GAME THREAD (LoopInGameThreadWithDelay). The first versions used
-- LoopAsync, which runs Lua on a worker thread while hooks run Lua in the same state on the
-- game thread; that data race corrupted values (numbers turning into strings/functions) and
-- crashed the game (self-test 2026-11-04).
LoopInGameThreadWithDelay(NET_MS, function() guarded("net", netStep) end)

-- Save guard on its own loop: the net loop pauses while levels change, and the slot must be
-- switched back as soon as the main menu shows (before the player can press Continue).
LoopInGameThreadWithDelay(250, function() guarded("saveguard", saveguard.tick) end)
-- World sync drives a client through menu -> Continue; it must keep running while levels load.
LoopInGameThreadWithDelay(100, function() guarded("worldsync", function() worldsync.tick(0.1) end) end)

-- Slot claim runs on its own: netStep needs the gameplay controller, but a second instance
-- sitting in the main menu must already be addressable (self-test 2026-11-04).
LoopInGameThreadWithDelay(2000, function()
    local ok, s = pcall(instance.claim)
    if ok and s and s ~= slot then slot = s; log("this game process is instance " .. s) end
end)

local hookLoop
hookLoop = LoopInGameThreadWithDelay(2000, function()
    if pcall(function() RegisterHook(TICK_FN, function() guarded("render", renderStep) end) end) then
        log("hooked " .. TICK_FN)
        CancelDelayedAction(hookLoop)
    end
end)

local CS = { ModifierKey.CONTROL, ModifierKey.SHIFT }
RegisterKeyBindAsync(Key.H, CS, function() ExecuteInGameThread(function() command("host") end) end)
RegisterKeyBindAsync(Key.J, CS, function() ExecuteInGameThread(function() command("join") end) end)
RegisterKeyBindAsync(Key.L, CS, function() ExecuteInGameThread(function() command("leave") end) end)
RegisterKeyBindAsync(Key.G, CS, function() ExecuteInGameThread(function() command("loopback") end) end)
RegisterKeyBindAsync(Key.U, CS, function() ExecuteInGameThread(function() hud.toggle() end) end)

---------------------------------------------------------------------------------------------
-- self-test: codec round trip for every message type (runs once at load, no game needed)

local function selfTest()
    local T = codec.T
    local cases = {
        { T.HELLO, 1, "测试 Player" },
        { T.WELCOME, "Host" },
        { T.REJECT, "why" },
        { T.STATE, 12.5, 100.25, -37754.5, 3645.75, 179.5, -10.25, 3 },
        { T.LEVEL, "LV_P_MainLevel_B05" },
        { T.PING, 1.5 },
        { T.PONG, 1.5 },
        { T.BYE },
        { T.PLAYER_HP, 75.5, 100, 1 },
        { T.CURSOR, 32768, 12345, 3, 0, 7 },
        { T.DRAG_ITEM, "冰冻弹" },
        { T.ENEMY_SPAWN, 7, "/Game/ProjectLima/Blueprints/Characters/Enemies/CH_AI_Grunt.CH_AI_Grunt_C", 1.5, -2.5, 300.25, 90 },
        { T.ENEMY_STATE, 7, 1.5, -2.5, 300.25, -45.5, 35.5, 70 },
        { T.ENEMY_DESPAWN, 7 },
        { T.ENEMY_DEATH, 7 },
        { T.ENEMY_HIT, 7, 12.5, "/Game/ProjectLima/Blueprints/Damage/DamageType_Normal.DamageType_Normal_C", 0.5, -0.25, 0, "head" },
        { T.ENEMY_SHOT, 7, 100.5, -2.25, 300, 1.5, -3.25, 0 },
        { T.WORLD_SAVE, 3, 200588, 30000, "GVAS\0\1\2" },
        { T.DST_HIT, "BP_DST_M25_4x4_Floor_C_UAID_X", 1.5, -2.5, 3.5, 50, "/Game/D.D_C", 0, 0, -1 },
        { T.RADIAL, 1, 10.5, 20.5, 30.5, 25, 20, 50, 225, 0, 0, 3, "/Game/E.E_C" },
        { T.REVIVE, 76561197960265730 },
        { T.DST_BREAK, "BP_DST_M25_4x4_Floor_C_UAID_D8BBC116F90D4F7102_c290eee8a16c5ac0_1466998180", -1192.5, -196694.5, 7165.75 },
    }
    local sender = 76561197960265729
    local fails = 0
    for _, c in ipairs(cases) do
        local kind = c[1]
        local bytes = codec.encode(kind, sender, table.unpack(c, 2))
        local got = { codec.decode(bytes) }
        local ok = got[1] == kind and got[2] == sender
        for i = 2, #c do
            local want, have = c[i], got[i + 1]
            if type(want) == "number" then ok = ok and type(have) == "number" and math.abs(want - have) < 0.01
            else ok = ok and want == have end
        end
        if not ok then
            fails = fails + 1
            log("selftest FAIL " .. codec.NAMES[kind] .. ": " .. table.concat((function()
                local s = {}
                for i, v in ipairs(got) do s[i] = tostring(v) end
                return s
            end)(), ", "))
        end
    end
    log(string.format("selftest: codec %d/%d ok", #cases - fails, #cases))
end

pcall(selfTest)
writeStatus()

local cfg = readIni()
if cfg.autostart and cfg.autostart ~= "" and cfg.autostart ~= "off" then
    log("autostart " .. cfg.autostart .. " in 15 s")
    ExecuteInGameThreadWithDelay(15000, function()
        command(cfg.autostart == "client" and "join" or cfg.autostart)
    end)
end

log("Phase 2 loaded - Ctrl+Shift+H host, J join, L leave, G loopback test")

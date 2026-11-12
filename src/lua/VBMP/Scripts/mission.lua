-- Strongholds / wave missions / boss arenas for the team (docs/coop-issues.md #3, MISSION 30).
--
-- Research (dual test 2026-11-05, build 26439385, BP_Stronghold_Frozen_C in Biome_05;
-- research/phase4-07-strongholds.md):
--   * A player entering the arena runs CALL_PlayerOverlappedStart(), which raises the shield
--     (ActivateShield?(true)) and starts the waves; each death runs CALL_EnemyDestroyed; after the
--     last wave StrongholdCompleted(GiveReward? = true) drops the loot (SpawnLoot), lowers the
--     shield (RemoveShieldAnimation, ActivateShield?(false)) and sets Completed?.
--   * In a client's world the arena starts too (its own player walked in), but the enemies it
--     spawns are removed (enemies live on the host) without CALL_EnemyDestroyed, so it never
--     completes: the client stays shut in. Calling StrongholdCompleted(true) on the client's copy
--     ran the same sequence there (loot, shield down, Completed? true).
--   * Aggro stand-ins no longer set off the host's triggers (aggro.lua), so a stronghold a
--     client enters first does not start on the host by itself.
--
-- Host -> clients, code 2: a stronghold / arena completed here -> complete the same one there.
-- Client -> host, code 1: a stronghold started here -> start the host's copy (it spawns the
-- enemies) unless it is already running or done.
-- Matching: exact class + location rounded to 100 units.
--
-- Extraction ("守点、把数据块塞进去", user report 2026-11-13; self-test the same day on a
-- BP_Mission_Extraction_C + BP_Extraction_DataBank_C + BP_Extraction_DataCube_C spawned in
-- Biome_05 - they found each other by themselves, FindBankAndCube):
--   * the cube going into the bank runs DataBank.CubeOverlapped(cube, 4) -> DataBank.StartDefence
--     -> Mission.StartingDefence -> StartExtractionTimer -> StartSpawner, cube ReleaseAndDestroy;
--   * the upload (CurrentPercent, TimerEvent) only advances while Mission."PlayerInZone?"; the
--     zone calls PlayerInZone / PlayerNotInZone as the player walks in and out. Calling
--     PlayerInZone() from script with nobody there made it advance (82.5 -> 100 %), then
--     UploadFinished -> MissionCompleted -> TimerCompleted, Completed? true.
--   * In co-op only the world of the player who did it saw either: the host's copy stayed "not
--     started" while the client's ran and completed.
--   * The zone that counts is DataBank.UploadSphere (radius 3000, off the bank's origin), not the
--     mission's MissionSphere (radius 7637).
-- Both ways: code 3 the cube went in here (hook DataBank.StartDefence) -> the other copy runs
-- CubeOverlapped with its own cube (or StartDefence); code 4 is a once-a-second "our player is in
-- the upload zone" heartbeat -> the other copy keeps PlayerInZone on while one arrives (code 5,
-- "left", is accepted but no longer sent). Host -> clients, code 6: the extraction failed.

local M = {}

local STRONGHOLD = "/Game/ProjectLima/Blueprints/AI/Waves/BP_Stronghold_Master.BP_Stronghold_Master_C"
local ARENA = "/Game/ProjectLima/Blueprints/AI/Waves/BP_BossFightArena_Master.BP_BossFightArena_Master_C"
local WAVES = "/Game/ProjectLima/Blueprints/AI/Waves/BP_Mission_WaveSpawner.BP_Mission_WaveSpawner_C"
local ELITE = "/Game/ProjectLima/Blueprints/AI/Waves/BP_Mission_EliteSpawner.BP_Mission_EliteSpawner_C"
local MINIBOSS = "/Game/ProjectLima/Blueprints/AI/Strongholds/BP_Mission_MiniBoss.BP_Mission_MiniBoss_C"
local EXTRACT = "/Game/ProjectLima/Blueprints/AI/Waves/BP_Mission_Extraction.BP_Mission_Extraction_C"
local BANK = "/Game/ProjectLima/Blueprints/GameplayObjectives/Extraction/BP_Extraction_DataBank.BP_Extraction_DataBank_C"
local MATCH = 300
local HOOK_EVERY = 2.0
local ZONE_EVERY = 1.0
local CODE_START, CODE_DONE, CODE_INSERT, CODE_IN, CODE_OUT, CODE_FAIL = 1, 2, 3, 4, 5, 6
local DONE_WAIT = 0.5
local REMOTE_HOLD = 3.0          -- a teammate counts as in an extraction zone this long after its last CODE_IN
-- A failed extraction (its countdown ran out: Failed? true) also runs StrongholdCompleted, so a
-- "completed" hook call on a failed mission is sent as CODE_FAIL (dual test 2026-11-13: the host's
-- failure was replayed as a success with loot on the client).

local function valid(o) return type(o) == "userdata" and o:IsValid() end
local function grid(v) return math.floor(v / 100 + 0.5) end

function M.new(log, opts)
    opts = opts or {}
    local S = { role = nil, out = {}, inbox = {}, stats = { started = 0, completed = 0, applied = 0, missing = 0 } }
    local hooked = {}
    local replaying = false
    local hookT = HOOK_EVERY
    local recent = {}          -- key -> time (one completion runs StrongholdCompleted on every class in the chain)
    local now = 0

    local function keyOf(cls, x, y, z, code) return string.format("%s@%d,%d,%d#%d", cls, grid(x), grid(y), grid(z), code) end

    -- Extraction zones are state, not events: every ZONE_EVERY s each side measures whether its own
    -- player stands in the upload zone (DataBank.UploadSphere, radius 3000 in the self-test) and,
    -- if so, sends CODE_IN; a copy that heard CODE_IN within REMOTE_HOLD s keeps PlayerInZone on.
    -- (The game's own PlayerInZone / PlayerNotInZone come from overlaps, which a teleport did not
    -- always fire, and an event sent before the other side's mission existed was lost - dual
    -- test 2026-11-13.)
    local remoteIn, forced = {}, {}    -- extraction key -> last CODE_IN time / true while we hold it on
    -- PlayerInZone is not idempotent: each call adds an upload timer. Our forced call plus the
    -- game's own (our player walking in) made the upload run at double speed (dual test
    -- 2026-11-13, 12.5 -> 85 % in 12 s), so when the game calls it while we hold the zone on,
    -- the zone loop resets it to one timer (PlayerNotInZone, PlayerInZone) and hands it back.
    local resetPending = {}
    -- Clients: an extraction's own spawner must not run - enemies live on the host, and the
    -- client removing what the mission just spawned crashed the game (access violation at the
    -- removal, dual test 2026-11-13). StopSpawner() once its defence has started.
    local spawnerStopped = {}
    local zoneT = 0

    local function localInside(a)
        local me = opts.localPlayer and opts.localPlayer()
        if not valid(me) then return false end
        local inside = false
        pcall(function()
            local s = a.DataBankRef.UploadSphere
            local c, p = s:K2_GetComponentLocation(), me:K2_GetActorLocation()
            local r = s:GetScaledSphereRadius()
            inside = (c.X - p.X) ^ 2 + (c.Y - p.Y) ^ 2 + (c.Z - p.Z) ^ 2 <= r * r
        end)
        return inside
    end

    local function queue(self, code)
        if replaying or not S.role then return end
        if code == CODE_DONE and S.role ~= "host" then return end
        if code == CODE_START and S.role ~= "client" then return end
        local a = self:get()
        if code == CODE_INSERT and valid(a) then a = a.MasterMission end   -- hooked on the bank
        if not valid(a) then return end
        local cls = a:GetClass():GetFName():ToString()
        local l = a:K2_GetActorLocation()
        local key = keyOf(cls, l.X, l.Y, l.Z, code)
        if recent[key] and now - recent[key] < 10 then return end
        recent[key] = now
        -- a completion waits DONE_WAIT s: a failing extraction runs StrongholdCompleted first and sets
        -- Failed? only afterwards (dual test 2026-11-13), so S.tick decides DONE or FAIL then
        local ev = { cls = cls, x = l.X, y = l.Y, z = l.Z, code = code }
        if code == CODE_DONE then ev.actor, ev.due = a, now + DONE_WAIT end
        if #S.out < 16 then table.insert(S.out, ev) end
    end

    local function tryHooks()
        -- Subclasses that declare their own copy of a function do not run a hook on the parent's
        -- (dual test: the wave spawner's CALL_PlayerOverlappedStart never reached the hook on
        -- BP_Stronghold_Master), so hook each declaring class (CXX dump).
        local list = {
            { STRONGHOLD .. ":StrongholdCompleted", CODE_DONE },
            { MINIBOSS .. ":StrongholdCompleted", CODE_DONE },
            { ARENA .. ":StrongholdCompleted", CODE_DONE },
            { STRONGHOLD .. ":CALL_PlayerOverlappedStart", CODE_START },
            { WAVES .. ":CALL_PlayerOverlappedStart", CODE_START },
            { ELITE .. ":CALL_PlayerOverlappedStart", CODE_START },
            { MINIBOSS .. ":CALL_PlayerOverlappedStart", CODE_START },
            { BANK .. ":StartDefence", CODE_INSERT },
        }
        for _, h in ipairs(list) do
            if not hooked[h[1]] then
                pcall(LoadAsset, h[1]:match("^([^:]+)"))
                local code = h[2]
                local ok = pcall(RegisterHook, h[1], function(self) pcall(queue, self, code) end)
                if ok then hooked[h[1]] = true; log("mission: hooked " .. h[1]:match("([%w_]+:[%w_]+)$")) end
            end
        end
        local pin = EXTRACT .. ":PlayerInZone"
        if not hooked[pin] then
            local ok = pcall(RegisterHook, pin, function(self)
                if replaying then return end
                pcall(function()
                    local a = self:get()
                    local l = a:K2_GetActorLocation()
                    local key = keyOf(a:GetClass():GetFName():ToString(), l.X, l.Y, l.Z, 0)
                    if forced[key] then resetPending[key] = true end
                end)
            end)
            if ok then hooked[pin] = true; log("mission: hooked BP_Mission_Extraction_C:PlayerInZone") end
        end
    end

    function S.setRole(role) S.role = role; S.out, S.inbox = {}, {}; remoteIn, forced, resetPending, spawnerStopped = {}, {}, {}, {} end

    function S.onRemote(cls, x, y, z, code, from)
        if #S.inbox < 16 then table.insert(S.inbox, { cls = cls, x = x, y = y, z = z, code = code, from = from }) end
    end

    local function find(ev)
        local best, bestD = nil, MATCH * MATCH
        for _, a in ipairs(FindAllOf(ev.cls) or {}) do
            if valid(a) and a:GetClass():GetFName():ToString() == ev.cls then
                local l = a:K2_GetActorLocation()
                local d = (l.X - ev.x) ^ 2 + (l.Y - ev.y) ^ 2 + (l.Z - ev.z) ^ 2
                if d < bestD then best, bestD = a, d end
            end
        end
        return best
    end

    local function apply(ev)
        local a = find(ev)
        if not a then return false, "missing" end
        local done = false
        pcall(function() done = a["Completed?"] == true end)
        if done then return true, (ev.code ~= CODE_IN and ev.code ~= CODE_OUT) and "already completed here" or nil end
        local l = a:K2_GetActorLocation()
        local zkey = keyOf(ev.cls, l.X, l.Y, l.Z, 0)
        if ev.code == CODE_IN then
            -- heartbeat, applied in S.tick's zone loop; quiet (one a second)
            local fresh = not remoteIn[zkey]
            remoteIn[zkey] = now
            return true, fresh and "teammate in the zone" or nil
        elseif ev.code == CODE_OUT then
            remoteIn[zkey] = nil          -- (0.12.0 sends none; the heartbeat just stops)
            return true, nil
        elseif ev.code == CODE_INSERT then
            local bank, cube = nil, nil
            pcall(function() bank = a.DataBankRef end)
            pcall(function() cube = a.DataCubeRef end)
            if not valid(bank) then return false, "no data bank" end
            local started = false
            pcall(function() started = bank["StartedDefence?"] == true end)
            if started then return true, "cube already in here" end
            replaying = true
            local ok, err
            if valid(cube) then
                -- the same call the game makes when the cube touches the bank (box 4)
                ok, err = pcall(function() bank:CubeOverlapped(cube, 4) end)
            else
                ok, err = pcall(function() bank:StartDefence() end)
            end
            if S.role == "client" then
                spawnerStopped[zkey] = true
                pcall(function() a:StopSpawner() end)   -- see spawnerStopped above
            end
            replaying = false
            return ok, ok and "cube put in here too" or tostring(err)
        end
        recent[keyOf(ev.cls, ev.x, ev.y, ev.z, ev.code)] = now
        replaying = true
        local ok, err
        if ev.code == CODE_FAIL then
            ok, err = pcall(function() a:StrongholdFailed() end)
            replaying = false
            return ok, ok and "failed here too" or tostring(err)
        elseif ev.code == CODE_DONE then
            -- strongholds take GiveReward? (the client gets its own loot); arenas take nothing
            ok, err = pcall(function() a:StrongholdCompleted(true) end)
            if not ok then ok, err = pcall(function() a:StrongholdCompleted() end) end
        else
            local active = false
            pcall(function() active = a["StrrongholdCurrentlyActive?"] == true end)
            if active then replaying = false; return true, "already running here" end
            ok, err = pcall(function() a:CALL_PlayerOverlappedStart() end)
        end
        replaying = false
        return ok, ok and (ev.code == CODE_DONE and "completed" or "started") or tostring(err)
    end

    -- Network loop. send(cls, x, y, z, code, exceptPeer): host -> clients, client -> host.
    function S.tick(dt, send)
        now = now + dt
        hookT = hookT + dt
        if hookT >= HOOK_EVERY then hookT = 0; tryHooks() end
        local out = S.out
        S.out = {}
        local WHAT = { "started", "completed", "got its cube", "has our player in its zone", "lost our player from its zone", "failed" }
        local ready = {}
        for _, ev in ipairs(out) do
            if ev.due and now < ev.due then
                table.insert(S.out, ev)
            else
                if ev.code == CODE_DONE and valid(ev.actor) then
                    local failed = false
                    pcall(function() failed = ev.actor["Failed?"] == true end)
                    if failed then ev.code = CODE_FAIL end
                end
                ev.actor = nil
                table.insert(ready, ev)
            end
        end
        for _, ev in ipairs(ready) do
            send(ev.cls, ev.x, ev.y, ev.z, ev.code, nil)
            if ev.code == CODE_DONE then S.stats.completed = S.stats.completed + 1
            elseif ev.code == CODE_START then S.stats.started = S.stats.started + 1 end
            log(string.format("mission: %s %s here, telling the %s", ev.cls, WHAT[ev.code] or tostring(ev.code),
                S.role == "host" and "clients" or "host"))
        end
        -- extraction zones (see remoteIn above)
        zoneT = zoneT + dt
        if zoneT >= ZONE_EVERY then
            zoneT = 0
            local seen = {}
            for _, a in ipairs(FindAllOf("BP_Mission_Extraction_C") or {}) do
                if valid(a) and not a:GetFullName():find("Default__", 1, true) then
                    local done, inZone = false, false
                    pcall(function() done = a["Completed?"] == true end)
                    pcall(function() inZone = a["PlayerInZone?"] == true end)
                    local cls = a:GetClass():GetFName():ToString()
                    local l = a:K2_GetActorLocation()
                    local key = keyOf(cls, l.X, l.Y, l.Z, 0)
                    seen[key] = true
                    if not done then
                        if S.role == "client" and not spawnerStopped[key] then
                            local defending = false
                            pcall(function() defending = a.DataBankRef["StartedDefence?"] == true end)
                            if defending then
                                spawnerStopped[key] = true
                                replaying = true
                                local ok = pcall(function() a:StopSpawner() end)
                                replaying = false
                                log("mission: " .. cls .. " - own spawner stopped (the host's enemies come instead) " .. tostring(ok))
                            end
                        end
                        local inside = localInside(a)
                        if inside then send(cls, l.X, l.Y, l.Z, CODE_IN, nil) end
                        local remote = remoteIn[key] and now - remoteIn[key] < REMOTE_HOLD
                        if resetPending[key] then
                            -- the game's own PlayerInZone came on top of ours: back to one timer
                            resetPending[key], forced[key] = nil, nil
                            replaying = true
                            pcall(function() a:PlayerNotInZone() end)
                            pcall(function() a:PlayerInZone() end)
                            replaying = false
                            log("mission: " .. cls .. " - our player came in too, one upload timer again")
                        elseif remote and not inZone then
                            replaying = true
                            local ok = pcall(function() a:PlayerInZone() end)
                            replaying = false
                            if ok and not forced[key] then log("mission: " .. cls .. " - a teammate is in the zone, the upload runs here too") end
                            forced[key] = true
                        elseif not remote and forced[key] then
                            forced[key] = nil
                            if inZone and not inside then
                                replaying = true
                                pcall(function() a:PlayerNotInZone() end)
                                replaying = false
                                log("mission: " .. cls .. " - nobody in the zone any more, the upload pauses here")
                            end
                        end
                    else
                        remoteIn[key], forced[key], resetPending[key] = nil, nil, nil
                    end
                end
            end
            for key in pairs(remoteIn) do if not seen[key] and now - remoteIn[key] > 30 then remoteIn[key] = nil end end
        end
        local inbox = S.inbox
        S.inbox = {}
        for _, ev in ipairs(inbox) do
            local ok, what = apply(ev)
            local quiet = ev.code == CODE_IN or ev.code == CODE_OUT
            if ok then
                S.stats.applied = S.stats.applied + 1
                if what then log("mission: teammate's " .. ev.cls .. " -> " .. tostring(what)) end
            elseif not quiet then
                S.stats.missing = S.stats.missing + 1
                if S.stats.missing <= 5 then log("mission: " .. ev.cls .. " not applied: " .. tostring(what)) end
            end
            -- the host passes completions and extraction events on to the other clients
            if S.role == "host" and ev.code ~= CODE_START then send(ev.cls, ev.x, ev.y, ev.z, ev.code, ev.from) end
        end
    end

    function S.clear() S.role = nil; S.out, S.inbox = {}, {}; remoteIn, forced, resetPending, spawnerStopped = {}, {}, {}, {} end

    return S
end

return M

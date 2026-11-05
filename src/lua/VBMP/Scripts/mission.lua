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

local M = {}

local STRONGHOLD = "/Game/ProjectLima/Blueprints/AI/Waves/BP_Stronghold_Master.BP_Stronghold_Master_C"
local ARENA = "/Game/ProjectLima/Blueprints/AI/Waves/BP_BossFightArena_Master.BP_BossFightArena_Master_C"
local WAVES = "/Game/ProjectLima/Blueprints/AI/Waves/BP_Mission_WaveSpawner.BP_Mission_WaveSpawner_C"
local ELITE = "/Game/ProjectLima/Blueprints/AI/Waves/BP_Mission_EliteSpawner.BP_Mission_EliteSpawner_C"
local MINIBOSS = "/Game/ProjectLima/Blueprints/AI/Strongholds/BP_Mission_MiniBoss.BP_Mission_MiniBoss_C"
local MATCH = 300
local HOOK_EVERY = 2.0
local CODE_START, CODE_DONE = 1, 2

local function valid(o) return type(o) == "userdata" and o:IsValid() end
local function grid(v) return math.floor(v / 100 + 0.5) end

function M.new(log)
    local S = { role = nil, out = {}, inbox = {}, stats = { started = 0, completed = 0, applied = 0, missing = 0 } }
    local hooked = {}
    local replaying = false
    local hookT = HOOK_EVERY
    local recent = {}          -- key -> time (one completion runs StrongholdCompleted on every class in the chain)
    local now = 0

    local function keyOf(cls, x, y, z, code) return string.format("%s@%d,%d,%d#%d", cls, grid(x), grid(y), grid(z), code) end

    local function queue(self, code)
        if replaying or not S.role then return end
        if code == CODE_DONE and S.role ~= "host" then return end
        if code == CODE_START and S.role ~= "client" then return end
        local a = self:get()
        if not valid(a) then return end
        local cls = a:GetClass():GetFName():ToString()
        local l = a:K2_GetActorLocation()
        local key = keyOf(cls, l.X, l.Y, l.Z, code)
        if recent[key] and now - recent[key] < 10 then return end
        recent[key] = now
        if #S.out < 16 then table.insert(S.out, { cls = cls, x = l.X, y = l.Y, z = l.Z, code = code }) end
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
        }
        for _, h in ipairs(list) do
            if not hooked[h[1]] then
                pcall(LoadAsset, h[1]:match("^([^:]+)"))
                local code = h[2]
                local ok = pcall(RegisterHook, h[1], function(self) pcall(queue, self, code) end)
                if ok then hooked[h[1]] = true; log("mission: hooked " .. h[1]:match("([%w_]+:[%w_]+)$")) end
            end
        end
    end

    function S.setRole(role) S.role = role; S.out, S.inbox = {}, {} end

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
        if done then return true, "already completed here" end
        recent[keyOf(ev.cls, ev.x, ev.y, ev.z, ev.code)] = now
        replaying = true
        local ok, err
        if ev.code == CODE_DONE then
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
        for _, ev in ipairs(out) do
            send(ev.cls, ev.x, ev.y, ev.z, ev.code, nil)
            if ev.code == CODE_DONE then S.stats.completed = S.stats.completed + 1 else S.stats.started = S.stats.started + 1 end
            log(string.format("mission: %s %s here, telling the %s", ev.cls, ev.code == CODE_DONE and "completed" or "started",
                S.role == "host" and "clients" or "host"))
        end
        local inbox = S.inbox
        S.inbox = {}
        for _, ev in ipairs(inbox) do
            local ok, what = apply(ev)
            if ok then
                S.stats.applied = S.stats.applied + 1
                log("mission: teammate's " .. ev.cls .. " -> " .. tostring(what))
            else
                S.stats.missing = S.stats.missing + 1
                if S.stats.missing <= 5 then log("mission: " .. ev.cls .. " not applied: " .. tostring(what)) end
            end
            -- the host passes a completion on to the other clients
            if S.role == "host" and ev.code == CODE_DONE then send(ev.cls, ev.x, ev.y, ev.z, ev.code, ev.from) end
        end
    end

    function S.clear() S.role = nil; S.out, S.inbox = {}, {} end

    return S
end

return M

-- Destruction sync v1 (Phase 3.5): "object X broke" events, both directions, host relays.
-- Evidence: research/phase3-06-destruction.md (build 23764881, single-instance trace 2026-11-05).
--
--   * Placed destructibles derive from BP_PreDestructibleItem_Master_C (StaticMeshActor) with
--     CurrentHealth (500 for a building tile). Bullets/explosions damage them through the normal
--     damage path (ReceiveAnyDamage); at 0 the object swaps itself for a fracturing Geometry
--     Collection. Chaos force fields (ChaosFromPool) do NOT break an intact object.
--   * "It broke" shows up as one of: Master.Swap / Master.CALL_InitialDestroyEffects (props and
--     building pieces), Building.BatchDestroyEvent (building pieces and glass),
--     Glass.DestroyGlassManual (glass never calls Swap and keeps its CurrentHealth).
--   * Reproducing a break: lethal ApplyPointDamage (DamageType_Normal_C) works for tiles and glass;
--     calling DestroyObject() directly did nothing.
--   * Objects live in runtime level instances (/_Generated_/<id>_LevelInstance_N), so the full
--     path is not a cross-machine id. Key = actor name (contains the UAID) + location (rounded);
--     the same sublevel placed twice has equal names but different locations.
--
-- Both sides send their own breaks (any cause: bullets, dash, explosions, enemies, replayed
-- shots); the host validates, applies and relays. A break is never sent back to where it came
-- from (known set). Hooks only queue; damage is applied in tick() (network loop).

local M = {}

local D = "/Game/ProjectLima/Blueprints/Chaos/DestructibleItems/"
local MASTER = D .. "BP_PreDestructibleItem_Master.BP_PreDestructibleItem_Master_C"
local BUILDING = D .. "BP_PreDestructibleItem_Master_Building.BP_PreDestructibleItem_Master_Building_C"
local GLASS = D .. "BP_PreDestructibleItem_Master_Building_Glass.BP_PreDestructibleItem_Master_Building_Glass_C"
local BREAK_HOOKS = {
    MASTER .. ":Swap",
    MASTER .. ":CALL_InitialDestroyEffects",
    BUILDING .. ":BatchDestroyEvent",
    GLASS .. ":DestroyGlassManual",
}
local DAMAGE_TYPE = "/Game/ProjectLima/Blueprints/Damage/DamageType_Normal.DamageType_Normal_C"

local GRID = 50             -- location rounding for keys (static actors: identical on every machine)
local MATCH_DIST = 150      -- receiver: same name within this distance is the same object
local RETRY_EVERY = 2.0     -- s between attempts for objects not loaded (streamed out) yet
local GIVE_UP = 300         -- s
local MAX_PER_TICK = 16     -- breaks applied per tick (a collapsing building is dozens at once)
local HOOK_EVERY = 1.0
local CLASS_CACHE = 2.0     -- s a FindAllOf result is reused

local function valid(o) return type(o) == "userdata" and o:IsValid() end
local function r(v) return math.floor(v / GRID + 0.5) end
local function keyOf(name, x, y, z) return string.format("%s@%d,%d,%d", name, r(x), r(y), r(z)) end

function M.new(log)
    local S = {
        role = nil,
        known = {},       -- key -> true: broken here or already applied (never re-sent)
        outbox = {},      -- our own breaks to send: { name, x, y, z }
        inbox = {},       -- breaks to apply: { name, x, y, z, from, at, nextTry }
        history = {},     -- host: every break this level, for players who join later
        stats = { sent = 0, received = 0, applied = 0, already = 0, missing = 0, relayed = 0 },
    }
    local now, hookT = 0, HOOK_EVERY
    local hooked = {}
    local classCache = {}   -- class name -> { at, list }
    local applying = false
    local level = nil

    local function onBreak(self)
        if not S.role then return end
        local a = self:get()
        if not valid(a) then return end
        local name = a:GetFName():ToString()
        local l = a:K2_GetActorLocation()
        local key = keyOf(name, l.X, l.Y, l.Z)
        if S.known[key] then return end         -- already sent, or it is a break we are applying
        S.known[key] = true
        if applying then return end             -- knock-on of a remote break: theirs, not ours
        table.insert(S.outbox, { name = name, x = l.X, y = l.Y, z = l.Z })
    end

    local function tryHooks()
        for _, path in ipairs(BREAK_HOOKS) do
            if not hooked[path] then
                local ok = pcall(RegisterHook, path, function(self) pcall(onBreak, self) end)
                if ok then hooked[path] = true; log("destruction: hooked " .. path:match("([%w_]+:[%w_]+)$")) end
            end
        end
    end

    function S.setRole(role)
        S.role = role
        S.known, S.outbox, S.inbox, S.history, classCache = {}, {}, {}, {}, {}
        tryHooks()
    end

    -- A break from the network (host: from a client, `from` = its id; client: from the host).
    function S.onRemote(name, x, y, z, from)
        if type(name) ~= "string" or #name == 0 or not name:find("_UAID_", 1, true) then return end
        S.stats.received = S.stats.received + 1
        table.insert(S.inbox, { name = name, x = x, y = y, z = z, from = from, at = now, nextTry = 0 })
    end

    local function candidates(cls)
        local c = classCache[cls]
        if c and now - c.at < CLASS_CACHE then return c.list end
        local list = FindAllOf(cls) or {}
        classCache[cls] = { at = now, list = list }
        return list
    end

    local function find(ev)
        local cls = ev.name:match("^(.-)_UAID_")
        if not cls then return nil end
        local best, bestD = nil, MATCH_DIST * MATCH_DIST
        for _, a in ipairs(candidates(cls)) do
            if valid(a) and a:GetFName():ToString() == ev.name then
                local l = a:K2_GetActorLocation()
                local d = (l.X - ev.x) ^ 2 + (l.Y - ev.y) ^ 2 + (l.Z - ev.z) ^ 2
                if d < bestD then best, bestD = a, d end
            end
        end
        return best
    end

    -- "broken" = swapped for its fracture geometry, or (glass) the break already ran here.
    local function apply(ev)
        local obj = find(ev)
        if not obj then return nil end
        local l = obj:K2_GetActorLocation()
        local key = keyOf(ev.name, l.X, l.Y, l.Z)
        if S.known[key] or obj["Swapped?"] == true then
            S.known[key] = true
            S.stats.already = S.stats.already + 1
            return "already"
        end
        S.known[key] = true                      -- before the damage: our break hooks must not echo it
        local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        local dt = StaticFindObject(DAMAGE_TYPE)
        if not valid(dt) then pcall(LoadAsset, DAMAGE_TYPE); dt = StaticFindObject(DAMAGE_TYPE) end
        local pc = FindFirstOf("PC_LimaPlayerController_C")
        local me = valid(pc) and pc.Pawn or nil
        local hp = obj.CurrentHealth
        if type(hp) ~= "number" or hp < 0 then hp = 0 end
        applying = true
        require("aggro").busy = true
        local ok, err = pcall(function()
            gs:ApplyPointDamage(obj, hp + 1, { X = 0, Y = 0, Z = -1 }, {}, valid(pc) and pc or nil, valid(me) and me or nil, dt)
        end)
        applying = false
        require("aggro").busy = false
        if not ok then log("destruction: applying " .. ev.name .. " failed: " .. tostring(err)) end
        S.stats.applied = S.stats.applied + 1
        if S.stats.applied <= 5 then log("destruction: applied " .. ev.name) end
        return "applied"
    end

    -- Network loop. send(name, x, y, z, exceptPeer) = host: to every client but exceptPeer;
    -- client: to the host.
    function S.tick(dt, send, levelName)
        now = now + dt
        hookT = hookT + dt
        if hookT >= HOOK_EVERY then hookT = 0; tryHooks() end
        if levelName and levelName ~= level then
            -- Only a change from one known level to another forgets: right after joining, the
            -- host's catch-up list can arrive before we know our level (dual test 2026-11-05).
            if level then
                log("destruction: new level, forgetting " .. #S.history .. " breaks")
                S.known, S.outbox, S.inbox, S.history, classCache = {}, {}, {}, {}, {}
            end
            level = levelName
        end

        local out = S.outbox
        S.outbox = {}
        for _, b in ipairs(out) do
            send(b.name, b.x, b.y, b.z, nil)
            S.stats.sent = S.stats.sent + 1
            if S.role == "host" then table.insert(S.history, b) end
            if S.stats.sent <= 5 then log("destruction: broke " .. b.name) end
        end

        local keep, done = {}, 0
        for _, ev in ipairs(S.inbox) do
            if done >= MAX_PER_TICK or now < ev.nextTry then
                table.insert(keep, ev)
            else
                local ok, res = pcall(apply, ev)
                if not ok then log("destruction: apply error " .. tostring(res)) end
                if ok and res then
                    done = done + 1
                    if S.role == "host" and res == "applied" then
                        send(ev.name, ev.x, ev.y, ev.z, ev.from)        -- to the other clients
                        S.stats.relayed = S.stats.relayed + 1
                        table.insert(S.history, ev)
                    end
                elseif now - ev.at < GIVE_UP then
                    ev.nextTry = now + RETRY_EVERY                  -- not streamed in yet
                    table.insert(keep, ev)
                else
                    S.stats.missing = S.stats.missing + 1
                    if S.stats.missing <= 5 then log("destruction: gave up on " .. ev.name) end
                end
            end
        end
        S.inbox = keep
    end

    -- Host: everything broken on this level so far, to one client that just joined.
    function S.hostSendAll(sendTo)
        for _, b in ipairs(S.history) do sendTo(b.name, b.x, b.y, b.z) end
        if #S.history > 0 then log("destruction: sent " .. #S.history .. " earlier breaks to a new player") end
    end

    function S.clear()
        S.role = nil
        S.known, S.outbox, S.inbox, S.history, classCache = {}, {}, {}, {}, {}
        level = nil
    end

    return S
end

return M

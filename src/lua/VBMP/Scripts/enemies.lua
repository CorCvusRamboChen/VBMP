-- Enemy sync v1 (Phase 3.1): the host owns every enemy; clients show mirrors.
--
-- Facts (build 23764881):
--   Enemies are spawned at runtime by scenarios/spawners (none are placed in levels: a census
--   of all 56 CH_AI_* classes found 0 placed instances), and every spawn registers itself with
--   GM_LimaGameMode_C:AddEnemyPool(AActor*) (VBTrace probe, 2026-11-04). RemoveFromEnemyPool
--   is the matching removal. ACH_AI_Base_C : ACharacter, possessed by AI_Controller_C.
--
-- Host: AddEnemyPool hook -> NetID -> ENEMY_SPAWN (reliable); ENEMY_STATE at 20 Hz;
--   ENEMY_DESPAWN when the actor is gone. A joining client gets the whole pool.
-- Client: spawns the same class, destroys its AI controller (no local brain) and moves it to
--   the host's interpolated transform. Enemies the client's own game spawns are destroyed.
-- Spawning/destroying never happens inside a hook callback (that deadlocked the game thread):
--   hooks only queue work, the network loop (a game-thread delayed action) does it.

local M = {}
local aggroLib = require("aggro")
local localPlayer = aggroLib.localPlayer   -- pc.Pawn: FindFirstOf may return an aggro stand-in

local GM_ADD = "/Game/ProjectLima/Blueprints/Modes/GM_LimaGameMode.GM_LimaGameMode_C:AddEnemyPool"
-- Player projectiles and hitscan end in these engine calls (VBTrace 2026-11-04:
-- ApplyPointDamage(target, 123.4, dir, HitResult, PC_LimaPlayerController_C, BP_Projectile_Shotgun_C /
-- BP_Weapon_SMG_C, DamageType_Normal_C)).
local POINT_DAMAGE = "/Script/Engine.GameplayStatics:ApplyPointDamage"
local ANY_DAMAGE = "/Script/Engine.GameplayStatics:ApplyDamage"
local MAX_HIT = 100000
-- Every basic enemy bullet goes through the player controller's pool (VBTrace 2026-11-04:
-- FireProjectileFromPool(Transform, Enum_EnemyProjectileType 0, AI_Controller_C)). A scripted call
-- with ActorResponsible = nil spawns a real bullet that hurts the local player through
-- DealDamageToPlayer (15 per hit; the enemy's own shots did 18.75 - its multiplier is not replayed).
local PC_FIRE = "/Game/ProjectLima/Blueprints/Modes/PC_LimaPlayerController.PC_LimaPlayerController_C:FireProjectileFromPool"
local MAX_SHOTS_QUEUED = 64
local DROPS_ON_CLIENTS = true

-- UE rotator <-> quaternion (roll 0), degrees.
local function quatToPY(q)
    local fx = 1 - 2 * (q.Y * q.Y + q.Z * q.Z)
    local fy = 2 * (q.X * q.Y + q.W * q.Z)
    local fz = 2 * (q.X * q.Z - q.W * q.Y)
    return math.deg(math.atan(fz, math.sqrt(fx * fx + fy * fy))), math.deg(math.atan(fy, fx))
end
local function pyToQuat(pitch, yaw)
    local hp, hy = math.rad(pitch) / 2, math.rad(yaw) / 2
    local sp, cp, sy, cy = math.sin(hp), math.cos(hp), math.sin(hy), math.cos(hy)
    return { X = sp * sy, Y = -sp * cy, Z = cp * sy, W = cp * cy }
end
local function lookAt(from, to)
    local dx, dy, dz = to.X - from.X, to.Y - from.Y, to.Z - from.Z
    return math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy))), math.deg(math.atan(dy, dx))
end
local function wrap(a) return (a + 540) % 360 - 180 end
local function dist2(a, b) local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z; return dx * dx + dy * dy + dz * dz end
local STATE_EVERY = 0.05
local INTERP_DELAY = 0.12
local KEEP = 1.0

local function valid(o) return type(o) == "userdata" and o:IsValid() end
local function lerp(a, b, t) return a + (b - a) * t end
local function lerpYaw(a, b, t) return a + ((b - a + 540) % 360 - 180) * t end

-- ACH_AI_Base_C::GetHealth(out double CurrentHealth, out double MaxHealth) (CXX dump);
-- UE4SS writes scalar out params into the table under the parameter names.
local function health(actor)
    local o = {}
    local ok = pcall(function() actor:GetHealth(o, o) end)
    if ok and type(o.CurrentHealth) == "number" then return o.CurrentHealth, o.MaxHealth end
    return nil, nil
end

local function objectPath(obj)
    local full = obj:GetFullName()                        -- "BlueprintGeneratedClass /Game/....X_C"
    return full:match("%s(%S+)$") or full
end
local function classPath(actor) return objectPath(actor:GetClass()) end

local function findClass(path)
    local c = StaticFindObject(path)
    if valid(c) then return c end
    pcall(LoadAsset, path)
    c = StaticFindObject(path)
    if valid(c) then return c end
    return nil
end

-- hud (optional): hud.applyEnemyHealth(enemy, { hp, maxHp }) redraws the game's own health bar.
function M.new(log, hud)
    local E = {
        role = nil,              -- "host" | "client" | nil
        byId = {},               -- id -> { actor, path, samples }
        idOf = {},               -- actor address -> id (host)
        nextId = 1,
        pendingAdds = {},        -- actors seen by the AddEnemyPool hook, not yet handled
        pendingSpawns = {},      -- client: { id, path, x, y, z, yaw }
        mirrors = {},            -- client: actor address -> net id (ours, keep them)
        pendingHits = {},        -- client: hit intents caught by the damage hooks, not yet sent
        hostHits = {},           -- host: hit intents received, applied in hostTick
        hostShots = {},          -- host: enemy bullets seen by the fire hook, routed in hostTick
        clientShots = {},        -- client: bullets aimed at us, replayed in clientTick
        stats = { spawned = 0, removed = 0, killedLocal = 0, hitsSent = 0, hitsApplied = 0, hitsRejected = 0,
                  shotsSent = 0, shotsReplayed = 0 },
    }
    local timer = 0
    local hooked, hitHooked, fireHooked, hostHitHooked = false, false, false, false

    -- Co-op scaling (coop-rules.md, user decision 2026-11-05: health x1.5 and count x1.5 for two
    -- players; VBMP.ini enemy_health= / enemy_count=). Factor for N players: 1 + (f - 1) * (N - 1).
    --   * health: MaxHealth/Health written directly (self-test 2026-11-05: a grunt written 70 -> 105
    --     kept 105 and took damage from it normally; HealthMultiplier + SpawnHealth() changed
    --     nothing). Clients follow through ENEMY_STATE.
    --   * count: for each new non-boss enemy, extra copies of its class spawn next to it
    --     (expected extras = factor - 1), capped. Extras never spawn extras.
    E.scaling = { health = 1.5, count = 1.5 }
    local extraAddrs = {}            -- address -> true for enemies we spawned as extras
    local extraTimes = {}            -- os.clock() of recent extra spawns (rate cap)
    local EXTRA_MAX_PER_10S, POOL_CAP = 8, 45
    E.stats.extras, E.stats.scaled = 0, 0
    -- Host: who each enemy is after (Phase 3.4b, aggro.lua).
    E.aggro = aggroLib.new(log, E)

    -- Host: an enemy fired a pooled bullet. Only read plain numbers here (hook callback).
    local function onFire(t, kind, resp)
        local c = resp:get()
        if not valid(c) then return end
        local pawn = c.Pawn
        if not valid(pawn) then return end
        local id = E.idOf[pawn:GetAddress()]
        E.aggro.onFire(id)                       -- marks the bullet this call activates
        if not id or #E.hostShots >= MAX_SHOTS_QUEUED then return end
        local tr = t:get()
        local l, q = tr.Translation, tr.Rotation
        table.insert(E.hostShots, { id = id, X = l.X, Y = l.Y, Z = l.Z,
            q = { X = q.X, Y = q.Y, Z = q.Z, W = q.W }, kind = kind:get() })
    end

    -- Client: a local shot/blow landed on a mirror. Only queue here (hook callback).
    local function onDamage(actor, dmg, dir, hit, dtype)
        if E.role ~= "client" then return end
        local a = actor:get()
        if not valid(a) then return end
        local id = E.mirrors[a:GetAddress()]
        if not id then return end
        local e = E.byId[id]
        if not e or e.dead or e.dieQueued then return end   -- shots into a corpse are not hits
        local amount = dmg:get()
        if type(amount) ~= "number" or amount <= 0 then return end
        local h = { id = id, dmg = amount, dtype = "", x = 0, y = 0, z = 0, bone = "" }
        pcall(function() local c = dtype:get(); if valid(c) then h.dtype = objectPath(c) end end)
        if dir then pcall(function() local v = dir:get(); h.x, h.y, h.z = v.X, v.Y, v.Z end) end
        if hit then pcall(function() h.bone = hit:get().BoneName:ToString() end) end
        table.insert(E.pendingHits, h)
    end

    -- Host: the host's own shots/blows on an enemy (for "it attacks whoever hit it last").
    -- applyHit's own ApplyPointDamage calls are skipped through E.applying.
    local function onHostDamage(actor)
        if E.role ~= "host" or E.applying then return end
        local a = actor:get()
        if not valid(a) then return end
        local id = E.idOf[a:GetAddress()]
        if id then E.aggro.noteHit(id, "host") end
    end

    local function tryHook()
        if not hooked then
            local ok = pcall(function()
                RegisterHook(GM_ADD, function(_, actor)
                    if not E.role then return end            -- no session: nothing to queue
                    local a = actor:get()
                    if valid(a) then table.insert(E.pendingAdds, a) end
                end)
            end)
            if ok then hooked = true; log("enemies: hooked AddEnemyPool") end
        end
        if not hitHooked and E.role == "client" then
            local ok1, e1 = pcall(RegisterHook, POINT_DAMAGE, function(_, actor, dmg, dir, hit, _inst, _causer, dtype)
                pcall(onDamage, actor, dmg, dir, hit, dtype)
            end)
            local ok2, e2 = pcall(RegisterHook, ANY_DAMAGE, function(_, actor, dmg, _inst, _causer, dtype)
                pcall(onDamage, actor, dmg, nil, nil, dtype)
            end)
            hitHooked = true
            log("enemies: hit hooks " .. (ok1 and "point ok" or ("point FAILED " .. tostring(e1))) ..
                ", " .. (ok2 and "any ok" or ("any FAILED " .. tostring(e2))))
        end
        if not hostHitHooked and E.role == "host" then
            local ok1 = pcall(RegisterHook, POINT_DAMAGE, function(_, actor) pcall(onHostDamage, actor) end)
            local ok2 = pcall(RegisterHook, ANY_DAMAGE, function(_, actor) pcall(onHostDamage, actor) end)
            hostHitHooked = true
            log("enemies: host hit hooks " .. tostring(ok1) .. "/" .. tostring(ok2))
        end
        if not fireHooked and E.role == "host" then
            local ok, err = pcall(RegisterHook, PC_FIRE, function(_, t, kind, resp)
                if E.role == "host" then pcall(onFire, t, kind, resp) end
            end)
            fireHooked = true
            log("enemies: fire hook " .. (ok and "ok" or ("FAILED " .. tostring(err))))
        end
    end

    function E.setRole(role)
        pcall(E.aggro.clear)
        E.role = role
        extraAddrs, extraTimes = {}, {}
        E.byId, E.idOf, E.pendingAdds, E.pendingSpawns, E.mirrors = {}, {}, {}, {}, {}
        E.pendingHits, E.hostHits, E.hostShots, E.clientShots = {}, {}, {}, {}
        tryHook()
    end

    ---------------------------------------------------------------------------------------
    -- host

    local function track(actor, send)
        local addr = actor:GetAddress()
        if E.idOf[addr] then return end
        local id = E.nextId
        E.nextId = id + 1
        local path = classPath(actor)
        E.idOf[addr] = id
        E.byId[id] = { actor = actor, path = path }
        local l, r = actor:K2_GetActorLocation(), actor:K2_GetActorRotation()
        send("ENEMY_SPAWN", true, id, path, l.X, l.Y, l.Z, r.Yaw)
        E.stats.spawned = E.stats.spawned + 1
        log(string.format("enemies: host tracks #%d %s", id, path:match("([^.]+)$") or path))
    end

    local function factor(f, players)
        f = tonumber(f) or 1
        if f <= 1 or players <= 1 then return 1 end
        return 1 + (f - 1) * (players - 1)
    end
    local function isBoss(path) return path:lower():find("boss", 1, true) ~= nil end

    -- Host, every tick while someone is connected: raise each tracked enemy's health once.
    -- Enemies alive before the first player joined are raised then (keeping their health ratio).
    function E.scaleHealth(players)
        local f = factor(E.scaling.health, players)
        if f <= 1 then return end
        for _, e in pairs(E.byId) do
            if not e.scaled and not e.dead and valid(e.actor) then
                e.scaled = true
                local hp, maxHp = health(e.actor)
                if type(hp) == "number" and type(maxHp) == "number" and hp > 0 and maxHp > 0 then
                    e.actor.MaxHealth = maxHp * f
                    e.actor.Health = hp * f
                    E.stats.scaled = E.stats.scaled + 1
                    if E.stats.scaled <= 3 then
                        log(string.format("enemies: health x%.2f %s %.0f -> %.0f", f, e.path:match("([^.]+)$") or e.path, maxHp, maxHp * f))
                    end
                end
            end
        end
    end

    -- Host: a new enemy entered the pool; maybe spawn extra copies of it next to it.
    function E.spawnExtras(actor, players)
        local addr = actor:GetAddress()
        if extraAddrs[addr] then return end
        local f = factor(E.scaling.count, players)
        if f <= 1 then return end
        local e = E.byId[E.idOf[addr]]
        if not e or isBoss(e.path) then return end
        local n = math.floor(f - 1)
        if math.random() < (f - 1) - n then n = n + 1 end
        if n <= 0 then return end
        local now = os.clock()
        local recent = {}
        for _, t in ipairs(extraTimes) do if now - t < 10 then table.insert(recent, t) end end
        extraTimes = recent
        local alive = 0
        for _, x in pairs(E.byId) do if not x.dead then alive = alive + 1 end end
        local cls = actor:GetClass()
        local world = actor:GetWorld()
        local l = actor:K2_GetActorLocation()
        local r = actor:K2_GetActorRotation()
        for _ = 1, n do
            if #extraTimes >= EXTRA_MAX_PER_10S or alive >= POOL_CAP then return end
            local ang = math.random() * 2 * math.pi
            local d = 140 + math.random() * 120
            local x = world:SpawnActor(cls, { X = l.X + math.cos(ang) * d, Y = l.Y + math.sin(ang) * d, Z = l.Z + 40 },
                { Pitch = 0, Yaw = r.Yaw, Roll = 0 })
            if valid(x) then
                extraAddrs[x:GetAddress()] = true
                pcall(function() x:SpawnEnemyImmediate(false) end)
                table.insert(extraTimes, now)
                alive = alive + 1
                E.stats.extras = E.stats.extras + 1
                if E.stats.extras <= 3 then log("enemies: extra " .. (e.path:match("([^.]+)$") or e.path) .. " for #" .. E.idOf[addr]) end
            end
        end
    end

    -- Everything already tracked, to one client that joins mid-fight (sendTo is bound to it).
    function E.hostSendAll(sendTo)
        for id, e in pairs(E.byId) do
            if valid(e.actor) then
                local l, r = e.actor:K2_GetActorLocation(), e.actor:K2_GetActorRotation()
                sendTo("ENEMY_SPAWN", true, id, e.path, l.X, l.Y, l.Z, r.Yaw)
            end
        end
    end

    function E.hostAdoptPool(send)
        local gm = FindFirstOf("GM_LimaGameMode_C")
        if not valid(gm) then return end
        local pool = gm.EnemyPool
        for i = 1, pool:GetArrayNum() do
            local a = pool[i]
            if valid(a) then track(a, send) end
        end
    end

    -- Client hit intent (session.lua, already checked to come from a known peer).
    function E.hostOnHit(sender, id, dmg, dtype, x, y, z, bone)
        table.insert(E.hostHits, { sender = sender, id = id, dmg = dmg, dtype = dtype, x = x, y = y, z = z, bone = bone })
    end

    local damageTypes = {}
    local function applyHit(h)
        local e = E.byId[h.id]
        if not e or e.dead or not valid(e.actor) then return false, "no such enemy" end
        if type(h.dmg) ~= "number" or h.dmg ~= h.dmg or h.dmg <= 0 or h.dmg > MAX_HIT then return false, "bad damage" end
        local dtc = nil
        if h.dtype ~= "" then
            if damageTypes[h.dtype] == nil then damageTypes[h.dtype] = findClass(h.dtype) or false end
            dtc = damageTypes[h.dtype] or nil
        end
        if not dtc then return false, "unknown damage type " .. tostring(h.dtype) end
        local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        local pc = FindFirstOf("PC_LimaPlayerController_C")
        local me = localPlayer()
        local hit = {}
        if h.bone ~= "" and h.bone ~= "None" then hit = { BoneName = FName(h.bone) } end
        -- The game's own path: TakeDamage -> ReceivePointDamage -> SetHealth (armour, crits) -> DeathEvent.
        E.applying = true
        local ok, err = pcall(function()
            gs:ApplyPointDamage(e.actor, h.dmg, { X = h.x, Y = h.y, Z = h.z }, hit,
                valid(pc) and pc or nil, valid(me) and me or nil, dtc)
        end)
        E.applying = false
        if not ok then return false, tostring(err) end
        E.aggro.noteHit(h.id, h.sender)
        return true
    end

    -- Each enemy bullet goes to the player the enemy is after (aggro.lua); without a choice, to
    -- the player nearest its muzzle. The enemy blueprint always aims at the host
    -- (GetPlayerCharacter(0)); when the target is a remote player, that client fires the same
    -- bullet at itself, keeping the shot's offset from "dead on", and aggro.lua re-aims the
    -- host's copy at the stand-in.
    local function routeShots(ctx)
        local shots = E.hostShots
        E.hostShots = {}
        if #shots == 0 or not ctx or not ctx.remote or #ctx.remote == 0 then return end
        local me = localPlayer()
        local hostPos = valid(me) and me:K2_GetActorLocation() or nil
        for _, s in ipairs(shots) do
            local best = nil
            local who = E.aggro.targetOf(s.id)
            if who then
                if who ~= "host" then
                    for _, r in ipairs(ctx.remote) do if r.id == who then best = r end end
                end
            else
                local bestD = hostPos and dist2(s, hostPos) or math.huge
                for _, r in ipairs(ctx.remote) do
                    local d = dist2(s, r.pos)
                    if d < bestD then best, bestD = r, d end
                end
            end
            if best then
                local dp, dy = 0, 0
                if hostPos then
                    local sp, sy = quatToPY(s.q)
                    local ap, ay = lookAt(s, hostPos)
                    dp, dy = sp - ap, wrap(sy - ay)
                end
                ctx.sendTo(best.id, "ENEMY_SHOT", false, s.id, s.X, s.Y, s.Z, dp, dy, s.kind or 0)
                E.stats.shotsSent = E.stats.shotsSent + 1
                if E.stats.shotsSent <= 3 then
                    log(string.format("enemies: shot of #%d routed to %s (offset %.1f/%.1f)", s.id, tostring(best.id), dp, dy))
                end
            end
        end
    end

    function E.hostTick(dt, send, ctx)
        tryHook()
        local okA, errA = pcall(E.aggro.tick, dt, ctx and ctx.remote or {})
        if not okA then log("enemies: aggro tick failed: " .. tostring(errA)) end
        -- damage that landed on a stand-in goes to its player (PLAYER_HIT)
        local hits = E.aggro.hits
        E.aggro.hits = {}
        for _, h in ipairs(hits) do
            if ctx and ctx.sendTo then
                ctx.sendTo(h.peer, "PLAYER_HIT", true, h.amount)
                log(string.format("enemies: %.1f damage on %s's stand-in sent to them", h.amount, tostring(h.peer)))
            end
        end
        if ctx and ctx.peers == 0 then return end     -- nobody to send to; aggro still tidies up
        local okR, errR = pcall(routeShots, ctx)
        if not okR then log("enemies: shot routing failed: " .. tostring(errR)) end
        local adds = E.pendingAdds
        E.pendingAdds = {}
        local players = 1 + ((ctx and ctx.peers) or 0)
        for _, a in ipairs(adds) do
            if valid(a) then
                local fresh = not E.idOf[a:GetAddress()]
                track(a, send)
                if fresh then
                    local ok, err = pcall(E.spawnExtras, a, players)
                    if not ok then log("enemies: extra spawn failed: " .. tostring(err)) end
                end
            end
        end
        local okS, errS = pcall(E.scaleHealth, players)
        if not okS then log("enemies: health scaling failed: " .. tostring(errS)) end

        local hits = E.hostHits
        E.hostHits = {}
        for _, h in ipairs(hits) do
            local ok, applied, why = pcall(applyHit, h)
            if ok and applied then
                E.stats.hitsApplied = E.stats.hitsApplied + 1
                if E.stats.hitsApplied <= 3 then
                    log(string.format("enemies: applied client hit #%d %.1f %s", h.id, h.dmg, h.dtype:match("([^.]+)$") or h.dtype))
                end
            else
                E.stats.hitsRejected = E.stats.hitsRejected + 1
                if E.stats.hitsRejected <= 5 then
                    log("enemies: client hit #" .. tostring(h.id) .. " not applied: " .. tostring(ok and why or applied))
                end
            end
        end

        timer = timer + dt
        if timer < STATE_EVERY then return end
        timer = 0
        for id, e in pairs(E.byId) do
            if valid(e.actor) then
                local l, r = e.actor:K2_GetActorLocation(), e.actor:K2_GetActorRotation()
                local hp, maxHp = health(e.actor)
                send("ENEMY_STATE", false, id, l.X, l.Y, l.Z, r.Yaw, hp or -1, maxHp or -1)
                if hp and hp <= 0 and not e.dead then
                    e.dead = true
                    send("ENEMY_DEATH", true, id)
                    log("enemies: host #" .. id .. " died")
                end
            else
                send("ENEMY_DESPAWN", true, id)
                E.byId[id] = nil
                E.stats.removed = E.stats.removed + 1
            end
        end
    end

    ---------------------------------------------------------------------------------------
    -- client

    function E.clientOnSpawn(id, path, x, y, z, yaw)
        if E.byId[id] then return end
        table.insert(E.pendingSpawns, { id = id, path = path, x = x, y = y, z = z, yaw = yaw })
    end

    function E.clientOnState(now, id, x, y, z, yaw, hp, maxHp)
        local e = E.byId[id]
        if not e then return end
        local s = e.samples
        table.insert(s, { t = now, X = x, Y = y, Z = z, Yaw = yaw })
        while #s > 2 and s[2].t < now - KEEP do table.remove(s, 1) end
        if hp and hp >= 0 then e.hostHp, e.hostMaxHp = hp, maxHp end
    end

    function E.clientOnShot(id, x, y, z, dp, dy, kind)
        if #E.clientShots >= MAX_SHOTS_QUEUED then return end
        table.insert(E.clientShots, { id = id, X = x, Y = y, Z = z, dp = dp, dy = dy, kind = kind })
    end

    -- Network loop: fire the routed bullets at our own player from the host muzzle position.
    local function replayShots()
        local shots = E.clientShots
        E.clientShots = {}
        if #shots == 0 then return end
        local me = localPlayer()
        local pc = FindFirstOf("PC_LimaPlayerController_C")
        if not valid(me) or not valid(pc) then return end
        local target = me:K2_GetActorLocation()
        for _, s in ipairs(shots) do
            local e = E.byId[s.id]
            if e and not e.dead and not e.dieQueued then
                local ap, ay = lookAt(s, target)
                local q = pyToQuat(ap + s.dp, ay + s.dy)
                local ok, err = pcall(function()
                    pc:FireProjectileFromPool({ Translation = { X = s.X, Y = s.Y, Z = s.Z }, Rotation = q,
                        Scale3D = { X = 1, Y = 1, Z = 1 } }, s.kind, nil)
                end)
                E.stats.shotsReplayed = E.stats.shotsReplayed + 1
                if E.stats.shotsReplayed <= 3 or not ok then
                    log("enemies: replayed shot of #" .. s.id .. (ok and "" or (" FAILED " .. tostring(err))))
                end
            end
        end
    end

    function E.clientOnDeath(id)
        local e = E.byId[id]
        if e then e.dieQueued = true end
    end

    function E.clientOnDespawn(id)
        local e = E.byId[id]
        if not e then return end
        E.byId[id] = nil
        if valid(e.actor) then
            E.mirrors[e.actor:GetAddress()] = nil
            pcall(function() e.actor:K2_DestroyActor() end)
        end
        E.stats.removed = E.stats.removed + 1
    end

    -- Network loop: send the hit intents the damage hooks queued (reliable: a lost hit is a
    -- lost kill).
    function E.clientFlushHits(send)
        if #E.pendingHits == 0 then return end
        local hits = E.pendingHits
        E.pendingHits = {}
        for _, h in ipairs(hits) do
            send("ENEMY_HIT", true, h.id, h.dmg, h.dtype, h.x, h.y, h.z, h.bone)
            E.stats.hitsSent = E.stats.hitsSent + 1
            if E.stats.hitsSent <= 3 then
                log(string.format("enemies: hit intent #%d %.1f %s", h.id, h.dmg, h.dtype:match("([^.]+)$") or h.dtype))
            end
        end
    end

    -- A mirror must never lose health or die from local damage: the host decides. With
    -- bCanBeDamaged off, APawn::TakeDamage ignores the hit (no ReceivePointDamage, no local
    -- SetHealth/DeathEvent/drops), while our ApplyPointDamage hook still sees it first.
    local function guard(actor)
        pcall(function() if actor.bCanBeDamaged ~= false then actor.bCanBeDamaged = false end end)
    end

    local function spawnMirror(world, p)
        local cls = findClass(p.path)
        if not cls then log("enemies: class not loadable " .. p.path); return end
        local actor = world:SpawnActor(cls, { X = p.x, Y = p.y, Z = p.z }, { Pitch = 0, Yaw = p.yaw, Roll = 0 })
        if not valid(actor) then log("enemies: spawn failed for #" .. p.id); return end
        E.mirrors[actor:GetAddress()] = p.id         -- before anything can call AddEnemyPool
        guard(actor)
        -- No local brain: the host's AI drives this enemy. Destroying the controller leaves a
        -- plain character we move ourselves; movement mode None stops gravity/walking fighting
        -- the teleports (EMovementMode::MOVE_None = 0).
        pcall(function()
            local c = actor.Controller
            if valid(c) then c:K2_DestroyActor() end
        end)
        pcall(function() actor.CharacterMovement:SetMovementMode(0, 0) end)
        E.byId[p.id] = { actor = actor, path = p.path, samples = {} }
        E.stats.spawned = E.stats.spawned + 1
        log(string.format("enemies: client mirror #%d %s", p.id, p.path:match("([^.]+)$") or p.path))
    end

    -- Network loop (game-thread task): spawn queued mirrors, remove the client's own enemies.
    function E.clientTick(world)
        tryHook()
        if valid(world) then
            local spawns = E.pendingSpawns
            E.pendingSpawns = {}
            for _, p in ipairs(spawns) do
                local ok, err = pcall(spawnMirror, world, p)
                if not ok then log("enemies: mirror #" .. p.id .. " failed: " .. tostring(err)) end
            end
        end
        -- The AI controller is attached after SpawnActor returns, so destroying it at spawn
        -- time did nothing (self-test 2026-11-04). Strip it whenever it shows up; UnPossess +
        -- K2_DestroyActor keeps it gone.
        for id, e in pairs(E.byId) do
            if valid(e.actor) then
                guard(e.actor)
                local c = nil
                pcall(function() c = e.actor.Controller end)
                if valid(c) then
                    pcall(function() c:UnPossess() end)
                    pcall(function() c:K2_DestroyActor() end)
                    pcall(function() e.actor.CharacterMovement:SetMovementMode(0, 0) end)
                    if not e.brainless then log("enemies: mirror #" .. id .. " AI controller removed") end
                    e.brainless = true
                end
                -- Host health -> mirror (and its bar); keep the mirror alive until the host
                -- says it died, so local damage alone never kills it.
                if e.hostHp and e.hostHp ~= e.shownHp and not e.dead then
                    e.shownHp = e.hostHp
                    local hp = math.max(e.hostHp, 1)
                    if hud and hud.applyEnemyHealth then
                        pcall(hud.applyEnemyHealth, e.actor, { hp = hp, maxHp = e.hostMaxHp })
                    end
                end
                if e.dieQueued and not e.dead then
                    e.dead = true
                    -- Co-op rule "everyone gets a copy" (user, 2026-11-05): the mirror drops loot in
                    -- this client's own world (DeathEvent(BypassDrops? = false)), so every player
                    -- picks up their own money/ammo/health. The host's enemy drops on the host.
                    local ok, err = pcall(function() e.actor:DeathEvent(not DROPS_ON_CLIENTS) end)
                    log("enemies: mirror #" .. id .. " death " .. (ok and "played" or ("FAILED: " .. tostring(err))))
                end
            end
        end

        local okS, errS = pcall(replayShots)
        if not okS then log("enemies: shot replay failed: " .. tostring(errS)) end

        local adds = E.pendingAdds
        E.pendingAdds = {}
        for _, a in ipairs(adds) do
            if valid(a) and not E.mirrors[a:GetAddress()] then
                pcall(function() a:K2_DestroyActor() end)
                E.stats.killedLocal = E.stats.killedLocal + 1
                log("enemies: removed a locally spawned enemy (host owns enemies)")
            end
        end
    end

    -- Per frame (ReceiveTick hook): transforms only, no spawning.
    function E.clientRender(now)
        local rt = now - INTERP_DELAY
        for _, e in pairs(E.byId) do
            local s = e.samples
            if valid(e.actor) and s and #s > 0 then
                local a, b = s[1], s[#s]
                if rt >= b.t then a = b
                else
                    for i = #s, 2, -1 do
                        if s[i - 1].t <= rt then a, b = s[i - 1], s[i]; break end
                    end
                end
                local x, y, z, yaw = a.X, a.Y, a.Z, a.Yaw
                if b ~= a and b.t > a.t then
                    local t = math.max(0, math.min(1, (rt - a.t) / (b.t - a.t)))
                    x, y, z, yaw = lerp(a.X, b.X, t), lerp(a.Y, b.Y, t), lerp(a.Z, b.Z, t), lerpYaw(a.Yaw, b.Yaw, t)
                end
                e.actor:K2_SetActorLocationAndRotation({ X = x, Y = y, Z = z }, { Pitch = 0, Yaw = yaw, Roll = 0 }, false, {}, true)
            end
        end
    end

    function E.clear()
        pcall(E.aggro.clear)
        if E.role == "client" then
            for _, e in pairs(E.byId) do
                if valid(e.actor) then pcall(function() e.actor:K2_DestroyActor() end) end
            end
        end
        E.byId, E.idOf, E.pendingAdds, E.pendingSpawns, E.mirrors = {}, {}, {}, {}, {}
        E.pendingHits, E.hostHits, E.hostShots, E.clientShots = {}, {}, {}, {}
        E.role = nil
    end

    function E.count()
        local n = 0
        for _ in pairs(E.byId) do n = n + 1 end
        return n
    end

    return E
end

return M

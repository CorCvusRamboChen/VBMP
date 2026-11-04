-- Split aggro (Phase 3.4b): host enemies may target and chase remote players.
-- Research and evidence: research/phase3-05-enemy-aggro.md (build 23764881, 2026-11-05).
--
-- Facts it relies on:
--   * An enemy's target lives in three CH_LimaCharacter_C* references: AI_Controller_C.LimaCharacter,
--     CH_AI_Base_C["As CH Lima Character"], blackboard key "Target". Movement/chase, focus and
--     PlayerActualLocation follow them.
--   * PawnSensing has bOnlySensePlayers = true (it never sees a pawn without a PlayerController),
--     and its SeePawn handler rewrites "Target" to whatever pawn it saw -> re-assert ours.
--   * Shots always aim at GameplayStatics.GetPlayerCharacter(0) = the host; nothing we can set
--     changes that. A bullet's ProjectileMovement.Velocity can be re-aimed one frame later.
--   * A second CH_LimaCharacter_C spawned without a controller is stable ("stand-in").
--   * UE4SS: no post-callbacks on Blueprint hooks, so overwrites are undone in pre-hooks of the
--     behaviour-tree nodes that read the target, and on a short timer.
--
-- Rules: spawning/destroying happens in tick() (network loop, game thread), never in a hook.

local M = {}

local CHAR_CLASS = "/Game/FirstPerson/Blueprints/CH_LimaCharacter.CH_LimaCharacter_C"
local AI = "/Game/ProjectLima/Blueprints/AI/"
-- Behaviour-tree nodes that read the target (paths: asset list; signatures: CXX dump
-- ReceiveExecuteAI(AAIController*, APawn*) / ReceiveTickAI(AAIController*, APawn*, float)).
local TARGET_READERS = {
    AI .. "Tasks/BTTask_PerformAttack.BTTask_PerformAttack_C:ReceiveExecuteAI",
    AI .. "Tasks/BTTask_MoveToLocation.BTTask_MoveToLocation_C:ReceiveExecuteAI",
    AI .. "Tasks/Looking/BTTask_FocusPlayer.BTTask_FocusPlayer_C:ReceiveExecuteAI",
    AI .. "Services/BTService_InRangeForChase.BTService_InRangeForChase_C:ReceiveTickAI",
}
-- Every enemy projectile class that declares ActivateProjectile?(bool, AController*) (CXX dump).
local PRJ = "/Game/ProjectLima/Blueprints/Projectiles/"
local ACTIVATE = {
    PRJ .. "BP_EnemyProjectile_Master.BP_EnemyProjectile_Master_C:ActivateProjectile?",
    PRJ .. "EnemyProjectiles/BP_PRJ_Enemy_Basic.BP_PRJ_Enemy_Basic_C:ActivateProjectile?",
    PRJ .. "EnemyProjectiles/BP_PRJ_Enemy_Bar.BP_PRJ_Enemy_Bar_C:ActivateProjectile?",
    PRJ .. "EnemyProjectiles/BP_PRJ_Enemy_Slow.BP_PRJ_Enemy_Slow_C:ActivateProjectile?",
    PRJ .. "EnemyProjectiles/BP_PRJ_Enemy_Twizzler.BP_PRJ_Enemy_Twizzler_C:ActivateProjectile?",
    PRJ .. "EnemyProjectiles/BP_PRJ_Enemy_HomingFast.BP_PRJ_Enemy_HomingFast_C:ActivateProjectile?",
    PRJ .. "EnemyProjectiles/BP_PRJ_Enemy_HomingStrong.BP_PRJ_Enemy_HomingStrong_C:ActivateProjectile?",
}

local PICK_EVERY = 0.5      -- s between target choices
local ENFORCE_EVERY = 0.1   -- s between re-asserting the chosen target
local HOOK_EVERY = 1.0      -- s between attempts to hook classes that were not loaded yet
local RESPAWN_EVERY = 1.0   -- s between stand-in spawn attempts per player
local HIT_MEMORY = 5.0      -- s an enemy stays on whoever hit it last
local HIT_RANGE = 4000      -- ... unless that player is farther away than this
local SWITCH_RATIO = 0.5    -- switch to a nearer player only if nearer by this factor
local HOLD = 4.0            -- s a choice is kept before distance may change it (a hit still can)
local AIM_Z = 20            -- re-aimed bullets go at the stand-in's centre + this

local function valid(o) return type(o) == "userdata" and o:IsValid() end
local function addr(o) return valid(o) and o:GetAddress() or nil end
local function dist2(a, b) local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z; return dx * dx + dy * dy + dz * dz end

-- The local player is the controller's pawn: with stand-ins alive, FindFirstOf("CH_LimaCharacter_C")
-- may return a stand-in.
-- The controller comes from the game instance's CURRENT world: after a level change
-- FindFirstOf can still return the previous world's controller (world-sync test 2026-11-05).
function M.localController()
    local gi = FindFirstOf("GI_LimaGameInstance_C")
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if valid(gi) and valid(gs) then
        local ok, pc = pcall(function() return gs:GetPlayerController(gi, 0) end)
        if ok and valid(pc) then return pc end
    end
    local pc = FindFirstOf("PC_LimaPlayerController_C")
    return valid(pc) and pc or nil
end

function M.localPlayer()
    local pc = M.localController()
    if valid(pc) then
        local p = nil
        pcall(function() p = pc.Pawn end)
        if valid(p) then return p end
    end
    return nil
end

-- Shared "a remote result is being applied" flag: damage hooks in other modules must not report
-- damage that we apply on someone else's behalf (destruction.lua sets it, damagesync.lua reads it).
M.busy = false

local function findClass(path)
    local c = StaticFindObject(path)
    if valid(c) then return c end
    pcall(LoadAsset, path)
    c = StaticFindObject(path)
    return valid(c) and c or nil
end

-- E = the enemies module state (byId: id -> { actor, ... }, idOf: actor address -> id).
function M.new(log, E)
    local A = {
        stands = {},     -- peer id -> { actor, nextSpawn }
        chars = {},      -- address -> true for host + stand-ins (what a "player" ref may point at)
        assigned = {},   -- enemy id -> "host" | peer id
        hitBy = {},      -- enemy id -> { who = "host" | peer id, at = time }
        redirects = {},  -- bullets to re-aim: { proj, id }
        since = {},      -- enemy id -> time of its last target change
        shifted = {},    -- enemy id -> the move point we last wrote
        stats = { stands = 0, toPeers = 0, switches = 0, redirected = 0, enforced = 0, shifted = 0 },
    }
    local now, pickT, enforceT, hookT = 0, 0, 0, HOOK_EVERY
    local hookedPaths = {}
    local fireId = nil   -- set by onFire (FireProjectileFromPool pre-hook), consumed by ActivateProjectile?
    local TARGET, MOVE_KEY = nil, nil
    local function key() if not TARGET then TARGET = FName("Target") end return TARGET end

    local function targetActor(who)
        if who == "host" then return M.localPlayer() end
        local s = A.stands[who]
        return s and valid(s.actor) and s.actor or nil
    end

    -- Point one enemy at `t`. `force` also rewrites a blackboard/focus that is empty or points at
    -- something else (used when a stand-in goes away). Safe inside hooks: property writes and
    -- native setters only.
    local function enforce(c, pawn, t, force)
        local ta = addr(t)
        if not ta then return end
        if addr(c.LimaCharacter) ~= ta then c.LimaCharacter = t end
        if addr(pawn["As CH Lima Character"]) ~= ta then pawn["As CH Lima Character"] = t end
        local bb = c.Blackboard
        if valid(bb) then
            local cur = bb:GetValueAsObject(key())
            local ca = addr(cur)
            -- Only replace a player reference: an empty Target means the enemy has not noticed
            -- anyone yet, and we must not wake it up.
            if ca ~= ta and ((ca and A.chars[ca]) or force) then
                bb:SetValueAsObject(key(), t)
                A.stats.enforced = A.stats.enforced + 1
            end
        end
        local f = c:GetFocusActor()
        local fa = addr(f)
        if fa and fa ~= ta and A.chars[fa] then c:K2_SetFocus(t) end
    end

    local function enforceId(id, force)
        local e = E.byId[id]
        local who = A.assigned[id]
        if not e or not who or not valid(e.actor) then return end
        local t = targetActor(who)
        if not t then return end
        local c = e.actor.Controller
        if valid(c) then enforce(c, e.actor, t, force) end
    end

    ---------------------------------------------------------------------------------------
    -- hooks (queue/assert only)

    -- The move point comes from an EQS query whose context is player 0 (the host): an enemy
    -- after a teammate still drifted toward the host (dual test 2026-11-05). Move the point by
    -- (target - host), keeping the game's tactical offset. Only in combat (a player Target), and
    -- only once per new point (the task may run again on the same value).
    local function shiftMove(c, id, t)
        local me = M.localPlayer()
        if not valid(me) or addr(me) == addr(t) then return end
        local bb = c.Blackboard
        if not valid(bb) or not A.chars[addr(bb:GetValueAsObject(key())) or 0] then return end
        if not MOVE_KEY then MOVE_KEY = FName("MoveToLocation") end
        local v = bb:GetValueAsVector(MOVE_KEY)
        if not v or (v.X == 0 and v.Y == 0 and v.Z == 0) then return end
        local last = A.shifted[id]
        if last and math.abs(v.X - last.X) < 1 and math.abs(v.Y - last.Y) < 1 and math.abs(v.Z - last.Z) < 1 then return end
        local h, s = me:K2_GetActorLocation(), t:K2_GetActorLocation()
        local w = { X = v.X + s.X - h.X, Y = v.Y + s.Y - h.Y, Z = v.Z + s.Z - h.Z }
        bb:SetValueAsVector(MOVE_KEY, w)
        A.shifted[id] = w
        A.stats.shifted = A.stats.shifted + 1
    end

    local function onTargetReader(ctrl, isMove)
        local c = ctrl:get()
        if not valid(c) then return end
        local pawn = c.Pawn
        if not valid(pawn) then return end
        local id = E.idOf[pawn:GetAddress()]
        if not id or not A.assigned[id] then return end
        local t = targetActor(A.assigned[id])
        if not t then return end
        enforce(c, pawn, t, false)
        if isMove then shiftMove(c, id, t) end
    end

    local function onActivate(self, on)
        if not fireId then return end
        local id = fireId
        fireId = nil
        if not on:get() then return end
        local p = self:get()
        if valid(p) and #A.redirects < 64 then table.insert(A.redirects, { proj = p, id = id }) end
    end

    local function tryHooks()
        for _, list in ipairs({ TARGET_READERS, ACTIVATE }) do
            for _, path in ipairs(list) do
                if not hookedPaths[path] then
                    local isActivate = (list == ACTIVATE)
                    local isMove = path:find("BTTask_MoveToLocation", 1, true) ~= nil
                    local ok = pcall(RegisterHook, path, function(self, a1)
                        if E.role ~= "host" then return end
                        if isActivate then pcall(onActivate, self, a1) else pcall(onTargetReader, a1, isMove) end
                    end)
                    if ok then
                        hookedPaths[path] = true
                        log("aggro: hooked " .. (path:match("([^/.]+_C:.+)$") or path))
                    end
                end
            end
        end
    end

    -- From enemies.lua's FireProjectileFromPool pre-hook: the next activated bullet is this enemy's.
    function A.onFire(id)
        local who = A.assigned[id]
        fireId = (who and who ~= "host") and id or nil
    end

    -- Someone damaged enemy `id` ("host" or a peer id).
    function A.noteHit(id, who)
        A.hitBy[id] = { who = who, at = now }
    end

    -- "host", a peer id, or nil (no choice made: enemies.lua falls back to the nearest player).
    function A.targetOf(id) return A.assigned[id] end

    ---------------------------------------------------------------------------------------
    -- stand-ins

    local function hideStand(a)
        pcall(function() a.bCanBeDamaged = false end)
        -- Not SetActorHiddenInGame: pawn perception skips hidden pawns, and the enemies never saw
        -- the stand-in (dual test 2026-11-05). Hide the components instead.
        pcall(function() a.RootComponent:SetVisibility(false, true) end)
        pcall(function() a:SetActorEnableCollision(false) end)
        pcall(function() a:SetActorTickEnabled(false) end)
        pcall(function() a.CharacterMovement:SetMovementMode(0, 0) end)   -- MOVE_None: no gravity
        pcall(function()
            local w = a.CurrentlyEquipedWeapon
            if valid(w) then w:SetActorHiddenInGame(true); w:SetActorEnableCollision(false) end
        end)
    end

    local function spawnStand(world, peer, pos)
        local cls = findClass(CHAR_CLASS)
        if not cls then log("aggro: player class not loadable"); return nil end
        local a = world:SpawnActor(cls, { X = pos.X, Y = pos.Y, Z = pos.Z }, { Pitch = 0, Yaw = 0, Roll = 0 })
        if not valid(a) then log("aggro: stand-in spawn failed for " .. tostring(peer)); return nil end
        hideStand(a)
        A.stats.stands = A.stats.stands + 1
        log(string.format("aggro: stand-in for %s: %s", tostring(peer), a:GetFName():ToString()))
        return a
    end

    -- Every enemy aimed at `peer` goes back to the host before its stand-in disappears.
    local function releasePeer(peer)
        for id, who in pairs(A.assigned) do
            if who == peer then
                A.assigned[id] = "host"
                pcall(enforceId, id, true)
            end
        end
        for id, h in pairs(A.hitBy) do if h.who == peer then A.hitBy[id] = nil end end
    end

    local function removeStand(peer, why)
        local s = A.stands[peer]
        if not s then return end
        releasePeer(peer)
        if valid(s.actor) then
            A.chars[s.actor:GetAddress()] = nil
            pcall(function() s.actor:K2_DestroyActor() end)
        end
        A.stands[peer] = nil
        log("aggro: stand-in for " .. tostring(peer) .. " removed (" .. why .. ")")
    end

    local function updateStands(remote, me)
        local present = {}
        for _, r in ipairs(remote) do
            present[r.id] = true
            local s = A.stands[r.id]
            if not s then s = { nextSpawn = 0 }; A.stands[r.id] = s end
            if not valid(s.actor) then
                if s.actor then                      -- destroyed under us (level change)
                    releasePeer(r.id)
                    s.actor = nil
                end
                if now >= s.nextSpawn and valid(me) then
                    s.nextSpawn = now + RESPAWN_EVERY
                    local ok, a = pcall(spawnStand, me:GetWorld(), r.id, r.pos)
                    if ok and valid(a) then s.actor = a else
                        if not ok then log("aggro: stand-in spawn error " .. tostring(a)) end
                    end
                end
            end
            if valid(s.actor) then
                A.chars[s.actor:GetAddress()] = true
                s.actor:K2_SetActorLocation({ X = r.pos.X, Y = r.pos.Y, Z = r.pos.Z }, false, {}, true)
            end
        end
        for peer in pairs(A.stands) do
            if not present[peer] then removeStand(peer, "left the level or the session") end
        end
    end

    ---------------------------------------------------------------------------------------
    -- target choice

    local function canSee(c, actor)
        local ok, v = pcall(function() return c:LineOfSightTo(actor, { X = 0, Y = 0, Z = 0 }, false) end)
        return ok and v == true
    end

    local function pick(me)
        local cands = { { who = "host", actor = me } }
        for peer, s in pairs(A.stands) do
            if valid(s.actor) then table.insert(cands, { who = peer, actor = s.actor }) end
        end
        if #cands < 2 then return end
        for id, e in pairs(E.byId) do
            if valid(e.actor) and not e.dead then
                local c = nil
                pcall(function() c = e.actor.Controller end)
                if valid(c) then
                    -- Let perception notice stand-ins (it only senses player-controlled pawns).
                    pcall(function()
                        local ps = c.PawnSensing
                        if valid(ps) and ps.bOnlySensePlayers then ps.bOnlySensePlayers = false end
                    end)
                    local el = e.actor:K2_GetActorLocation()
                    local byWho, best, bestD, bestSee = {}, nil, math.huge, false
                    for _, cd in ipairs(cands) do
                        cd.d = dist2(el, cd.actor:K2_GetActorLocation())
                        cd.see = canSee(c, cd.actor)
                        byWho[cd.who] = cd
                        if (cd.see and not bestSee) or (cd.see == bestSee and cd.d < bestD) then
                            best, bestD, bestSee = cd, cd.d, cd.see
                        end
                    end
                    local choice = best
                    local h = A.hitBy[id]
                    local fromHit = false
                    if h and now - h.at < HIT_MEMORY and byWho[h.who] and byWho[h.who].d < HIT_RANGE * HIT_RANGE then
                        choice, fromHit = byWho[h.who], true
                    end
                    local cur = byWho[A.assigned[id] or "host"]
                    -- Hysteresis: keep the current target unless the new one is clearly better.
                    if not fromHit and cur and choice ~= cur then
                        local better = (choice.see and not cur.see) or (choice.see == cur.see and choice.d < cur.d * SWITCH_RATIO * SWITCH_RATIO)
                        local held = A.assigned[id] and now - (A.since[id] or 0) < HOLD
                        if not better or held then choice = cur end
                    end
                    local before = A.assigned[id]
                    A.assigned[id] = choice.who
                    if before ~= choice.who then
                        A.since[id] = now
                        A.shifted[id] = nil
                        if before then A.stats.switches = A.stats.switches + 1 end
                        if A.stats.switches <= 10 or choice.who ~= "host" and A.stats.toPeers < 10 then
                            log(string.format("aggro: enemy #%d -> %s (%.0f u%s%s)", id, tostring(choice.who),
                                math.sqrt(choice.d), choice.see and ", visible" or "", fromHit and ", hit it" or ""))
                        end
                        if choice.who ~= "host" then A.stats.toPeers = A.stats.toPeers + 1 end
                        pcall(enforceId, id, false)
                    end
                end
            end
        end
        for id in pairs(A.assigned) do if not E.byId[id] then A.assigned[id], A.hitBy[id], A.since[id], A.shifted[id] = nil, nil, nil, nil end end
    end

    ---------------------------------------------------------------------------------------
    -- bullets: the host's copy of a shot at a stand-in flies at the stand-in, not the host

    local function redirect()
        local list = A.redirects
        A.redirects = {}
        for _, r in ipairs(list) do
            local who = A.assigned[r.id]
            local t = who and who ~= "host" and targetActor(who) or nil
            if t and valid(r.proj) then
                -- Homing bullets (Enum_EnemyProjectileType 5/6 = BP_PRJ_Enemy_HomingFast/Strong_C,
                -- self-test 2026-11-05) would steer back to player 0 = the host: switch homing off
                -- on the host's copy (SetHomingNone + ProjectileMovement.bIsHomingProjectile).
                -- The client's replayed copy homes on the client's own player, as intended.
                -- Not verified against a real homing enemy yet.
                pcall(function() r.proj:SetHomingNone() end)
                pcall(function() r.proj.ProjectileMovement.bIsHomingProjectile = false end)
                local ok, err = pcall(function()
                    local pm = r.proj.ProjectileMovement
                    local v = pm.Velocity
                    local speed = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
                    if speed < 1 then speed = pm.InitialSpeed end
                    local l, tl = r.proj:K2_GetActorLocation(), t:K2_GetActorLocation()
                    local dx, dy, dz = tl.X - l.X, tl.Y - l.Y, tl.Z + AIM_Z - l.Z
                    local m = math.sqrt(dx * dx + dy * dy + dz * dz)
                    if m < 1 then return end
                    pm.Velocity = { X = dx / m * speed, Y = dy / m * speed, Z = dz / m * speed }
                end)
                if ok then A.stats.redirected = A.stats.redirected + 1 end
                if not ok or A.stats.redirected <= 3 then
                    log("aggro: bullet of #" .. r.id .. " re-aimed at " .. tostring(who) .. (ok and "" or (" FAILED " .. tostring(err))))
                end
            end
        end
    end

    ---------------------------------------------------------------------------------------

    -- Network loop (game thread). remote = { { id, pos } } players on the host's level.
    function A.tick(dt, remote)
        now = now + dt
        hookT = hookT + dt
        if hookT >= HOOK_EVERY then hookT = 0; tryHooks() end
        local me = M.localPlayer()
        if valid(me) then A.chars[me:GetAddress()] = true end
        updateStands(remote or {}, me)
        pcall(redirect)
        if not valid(me) then return end
        pickT = pickT + dt
        if pickT >= PICK_EVERY then
            pickT = 0
            local ok, err = pcall(pick, me)
            if not ok then log("aggro: pick failed: " .. tostring(err)) end
        end
        enforceT = enforceT + dt
        if enforceT >= ENFORCE_EVERY then
            enforceT = 0
            for id in pairs(A.assigned) do pcall(enforceId, id, false) end
        end
    end

    function A.clear()
        for peer in pairs(A.stands) do removeStand(peer, "session ended") end
        A.stands, A.chars, A.assigned, A.hitBy, A.redirects, A.since, A.shifted = {}, {}, {}, {}, {}, {}, {}
        fireId = nil
    end

    function A.count()
        local n, toPeers = 0, 0
        for _, s in pairs(A.stands) do if valid(s.actor) then n = n + 1 end end
        for _, who in pairs(A.assigned) do if who ~= "host" then toPeers = toPeers + 1 end end
        return n, toPeers
    end

    return A
end

return M

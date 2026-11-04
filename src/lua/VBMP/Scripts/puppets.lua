-- Remote player puppets: one actor per remote player, driven by received STATE samples.
-- Samples are stamped with local receive time and shown INTERP_DELAY behind, interpolated,
-- so uneven packet arrival still gives smooth motion (the ghost experiment proved the
-- spawn/drive part; this adds per-peer buffers, name tags and host-side extras).
--
-- Game/engine facts (build 23764881, CXXHeaderDump):
--   puppet mesh  /Game/ConversationGesturesAnimationPack/Demo/Characters/Mannequins/Meshes/SKM_Quinn_Simple
--                (origin at the feet, faces +Y -> yaw - 90, drop by the player's capsule half height)
--   UTextRenderComponent SetText(FText), SetWorldSize(float), SetHorizontalAlignment(EHorizTextAligment)
--   AActor::AddComponentByClass(Class, bManualAttachment, RelativeTransform, bDeferredFinish)
--   UWorldPartitionStreamingSourceComponent EnableStreamingSource()   (host: keep the remote
--     player's surroundings loaded, the local player already has one: CH_LimaCharacter_C)
--   UNavigationSystemV1::RegisterNavigationInvoker(Actor, TileGenerationRadius, TileRemovalRadius)
--     (host: navmesh is generated around invokers only; CH_LimaCharacter_C has NavigationInvoker)

local M = {}

local INTERP_DELAY = 0.12        -- seconds behind the newest sample
local KEEP = 1.5                 -- seconds of samples kept
local MAX_EXTRAPOLATE = 0.25     -- hold position if packets stop for longer than this
local PUPPET_MESH = "/Game/ConversationGesturesAnimationPack/Demo/Characters/Mannequins/Meshes/SKM_Quinn_Simple.SKM_Quinn_Simple"
local FALLBACK_MESH = "/Engine/BasicShapes/Cylinder.Cylinder"
local MOVABLE = 2                -- EComponentMobility::Movable
local TEXT_CENTER = 1            -- EHorizTextAligment::EHTA_Center
local IDENTITY = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 }, Scale3D = { X = 1, Y = 1, Z = 1 } }

local function valid(o) return o ~= nil and o:IsValid() end

local function findOrLoad(path)
    local obj = StaticFindObject(path)
    if valid(obj) then return obj end
    pcall(LoadAsset, path)
    obj = StaticFindObject(path)
    if valid(obj) then return obj end
    return nil
end

local function lerp(a, b, t) return a + (b - a) * t end
local function lerpYaw(a, b, t) return a + ((b - a + 540) % 360 - 180) * t end

function M.new(log)
    local P = { peers = {}, isHost = false }

    local function spawnActor(world, className, at)
        local cls = StaticFindObject("/Script/Engine." .. className)
        if not valid(cls) then return nil end
        local ok, actor = pcall(function()
            return world:SpawnActor(cls, { X = at.X, Y = at.Y, Z = at.Z }, { Pitch = 0, Yaw = 0, Roll = 0 })
        end)
        if ok and valid(actor) then return actor end
        local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        local xf = { Rotation = IDENTITY.Rotation, Translation = { X = at.X, Y = at.Y, Z = at.Z }, Scale3D = IDENTITY.Scale3D }
        local deferred = statics:BeginDeferredActorSpawnFromClass(world, cls, xf, 1, nil, 0)
        if not valid(deferred) then return nil end
        return statics:FinishSpawningActor(deferred, xf, 0)
    end

    local function addNameTag(actor, name)
        local cls = StaticFindObject("/Script/Engine.TextRenderComponent")
        local ok, comp = pcall(function() return actor:AddComponentByClass(cls, false, IDENTITY, false) end)
        if not ok or not valid(comp) then log("name tag failed: " .. tostring(comp)); return nil end
        pcall(function()
            comp:SetText(FText(name))
            comp:SetWorldSize(28)
            comp:SetHorizontalAlignment(TEXT_CENTER)
            comp:K2_SetRelativeLocation({ X = 0, Y = 0, Z = 205 }, false, {}, true)
        end)
        return comp
    end

    -- Host only: the host simulates the world around every player, so a remote player needs
    -- the same streaming source and navmesh invoker the local character carries.
    local function addHostExtras(actor)
        local cls = StaticFindObject("/Script/Engine.WorldPartitionStreamingSourceComponent")
        local ok, comp = pcall(function() return actor:AddComponentByClass(cls, false, IDENTITY, false) end)
        if ok and valid(comp) then
            pcall(function() comp:EnableStreamingSource() end)
            log("host extra: streaming source on " .. actor:GetFName():ToString())
        else
            log("host extra: streaming source FAILED: " .. tostring(comp))
        end
        local nav = StaticFindObject("/Script/NavigationSystem.Default__NavigationSystemV1")
        local okNav, err = pcall(function() nav:RegisterNavigationInvoker(actor, 3000, 5000) end)
        log("host extra: navigation invoker " .. (okNav and "registered" or ("FAILED: " .. tostring(err))))
    end

    local function spawnPuppet(peer, world, at)
        local mesh = findOrLoad(PUPPET_MESH)
        local actor
        if valid(mesh) then
            actor = spawnActor(world, "SkeletalMeshActor", at)
            if valid(actor) then
                actor.SkeletalMeshComponent:SetMobility(MOVABLE)
                actor.SkeletalMeshComponent:SetSkeletalMeshAsset(mesh)
                peer.kind = "mannequin"
            end
        end
        if not valid(actor) then
            local cyl = findOrLoad(FALLBACK_MESH)
            actor = spawnActor(world, "StaticMeshActor", at)
            if not valid(actor) or not valid(cyl) then return nil end
            actor.StaticMeshComponent:SetMobility(MOVABLE)
            actor.StaticMeshComponent:SetStaticMesh(cyl)
            actor:SetActorScale3D({ X = 0.7, Y = 0.7, Z = 1.8 })
            peer.kind = "cylinder"
        end
        actor:SetActorEnableCollision(false)
        peer.tag = addNameTag(actor, peer.name or "?")
        if P.isHost then addHostExtras(actor) end
        log(string.format("puppet for %s (%s): %s", peer.name or "?", peer.kind, actor:GetFullName()))
        return actor
    end

    local function peerOf(id)
        local p = P.peers[id]
        if not p then
            -- ASCII default: TextRenderComponent's engine font may not cover CJK.
            p = { id = id, samples = {}, name = "Player" .. tostring(id):sub(-4), level = nil }
            P.peers[id] = p
        end
        return p
    end

    function P.setName(id, name)
        local p = peerOf(id)
        p.name = name
        if valid(p.tag) then pcall(function() p.tag:SetText(FText(name)) end) end
    end

    function P.setLevel(id, level) peerOf(id).level = level end

    function P.push(id, now, x, y, z, yaw, pitch)
        local s = peerOf(id).samples
        table.insert(s, { t = now, X = x, Y = y, Z = z, Yaw = yaw, Pitch = pitch })
        local cutoff = now - KEEP
        while #s > 2 and s[2].t < cutoff do table.remove(s, 1) end
    end

    function P.remove(id)
        local p = P.peers[id]
        if p and valid(p.actor) then pcall(function() p.actor:K2_DestroyActor() end) end
        P.peers[id] = nil
    end

    function P.clear()
        for id in pairs(P.peers) do P.remove(id) end
    end

    local function sampleAt(s, rt)
        local n = #s
        if n == 0 then return nil end
        if rt >= s[n].t then return s[n] end
        if rt <= s[1].t then return s[1] end
        for i = n, 2, -1 do
            local a, b = s[i - 1], s[i]
            if a.t <= rt then
                local t = (b.t == a.t) and 1 or (rt - a.t) / (b.t - a.t)
                return { X = lerp(a.X, b.X, t), Y = lerp(a.Y, b.Y, t), Z = lerp(a.Z, b.Z, t), Yaw = lerpYaw(a.Yaw, b.Yaw, t) }
            end
        end
        return s[1]
    end

    -- Spawning (asset load + SpawnActor + AddComponentByClass) must not run inside the
    -- ReceiveTick hook: doing it there froze the game thread (deadlock, 2026-11-04). It runs
    -- from the network loop (a plain ExecuteInGameThread task), like the working 1a ghost.
    -- ctx: { now, world }
    function P.spawnPending(ctx)
        for _, p in pairs(P.peers) do
            if p.wantSpawn and not valid(p.actor) and valid(ctx.world) then
                p.actor = spawnPuppet(p, ctx.world, p.wantSpawn)
                p.wantSpawn = nil
            end
        end
    end

    -- Per-frame, from the ReceiveTick hook: only moves puppets that already exist.
    -- ctx: { now, level, halfHeight, cameraYaw }
    function P.tick(ctx)
        for _, p in pairs(P.peers) do
            local s = sampleAt(p.samples, ctx.now - INTERP_DELAY)
            local sameLevel = (p.level == nil or ctx.level == nil or p.level == ctx.level)
            if s and sameLevel then
                if not valid(p.actor) then p.wantSpawn = { X = s.X, Y = s.Y, Z = s.Z } end
                if valid(p.actor) then
                    local z, yaw = s.Z, s.Yaw
                    if p.kind == "mannequin" then z, yaw = z - ctx.halfHeight, yaw - 90 end
                    p.actor:SetActorHiddenInGame(false)
                    p.actor:K2_SetActorLocationAndRotation({ X = s.X, Y = s.Y, Z = z }, { Pitch = 0, Yaw = yaw, Roll = 0 }, false, {}, true)
                    if valid(p.tag) and ctx.cameraYaw then
                        p.tag:K2_SetWorldRotation({ Pitch = 0, Yaw = ctx.cameraYaw + 180, Roll = 0 }, false, {}, true)
                    end
                    p.stale = (ctx.now - p.samples[#p.samples].t) > MAX_EXTRAPOLATE + INTERP_DELAY
                end
            elseif valid(p.actor) then
                p.actor:SetActorHiddenInGame(true)
            end
        end
    end

    return P
end

return M

-- Damage forwarding beyond enemy hits (Phase 3.8). Engine signatures: Engine.hpp in the dump.
--
--   1. client -> host  DST_HIT   the local player's point damage on a destructible (partial damage
--      adds up on the host; the break itself is synced by destruction.lua)
--   2. client -> host  RADIAL    radial damage the local player caused (explosions): the host
--      applies it at the same spot - hits real enemies and destructibles there
--   3. host -> client  RADIAL    enemy radial damage (ground damage fields BP_DamageField_C:
--      ApplyRadialDamageWithFalloff(25, 20, origin, 50, 225, 0, DamageType_Enemy_C, ..., AI_Controller,
--      3), VBTrace 2026-11-04) sent to clients near it; they apply it locally (no instigator), so it
--      hurts their own player only (mirrors are bCanBeDamaged = false)
-- Hooks only queue; everything is applied/sent from the network loop. Our own Apply* calls are
-- skipped by the hooks through `applying`.

local M = {}

local GS = "/Script/Engine.GameplayStatics:"
local MASTER = "/Game/ProjectLima/Blueprints/Chaos/DestructibleItems/BP_PreDestructibleItem_Master.BP_PreDestructibleItem_Master_C"
local FORWARD_MARGIN = 600      -- host: forward an enemy radial to clients within outer radius + this
local MAX_QUEUE = 64

local function valid(o) return type(o) == "userdata" and o:IsValid() end
local function objectPath(o) local f = o:GetFullName(); return f:match("%s(%S+)$") or f end

function M.new(log)
    local D = {
        role = nil,
        out = {},        -- queued for sending: { kind = "hit" | "radial", ... }
        inbox = {},      -- received, to apply
        stats = { hitsSent = 0, hitsApplied = 0, radialSent = 0, radialApplied = 0, radialForwarded = 0 },
    }
    local applying = false
    local hooked = false
    local masterClass = nil
    local damageTypes = {}

    local aggro = require("aggro")
    local function localPC() return aggro.localController() end

    local function isDestructible(a)
        if not valid(masterClass) then masterClass = StaticFindObject(MASTER) end
        if not valid(masterClass) then return false end
        local ok, r = pcall(function() return a:IsA(masterClass) end)
        return ok and r == true
    end

    local function classOf(path)
        if path == "" then return nil end
        if damageTypes[path] == nil then
            local c = StaticFindObject(path)
            if not valid(c) then pcall(LoadAsset, path); c = StaticFindObject(path) end
            damageTypes[path] = valid(c) and c or false
        end
        return damageTypes[path] or nil
    end

    -- client: the local player's point damage on a destructible
    local function onPoint(actor, dmg, dir, inst, dtype)
        if D.role ~= "client" or applying or aggro.busy or #D.out >= MAX_QUEUE then return end
        local a = actor:get()
        if not valid(a) or not isDestructible(a) then return end
        local i = inst:get()
        local pc = localPC()
        if not valid(i) or not valid(pc) or i:GetAddress() ~= pc:GetAddress() then return end
        local amount = dmg:get()
        if type(amount) ~= "number" or amount <= 0 then return end
        local l = a:K2_GetActorLocation()
        local v = { X = 0, Y = 0, Z = -1 }
        pcall(function() local x = dir:get(); v = { X = x.X, Y = x.Y, Z = x.Z } end)
        local dt = ""
        pcall(function() local c = dtype:get(); if valid(c) then dt = objectPath(c) end end)
        table.insert(D.out, { kind = "hit", name = a:GetFName():ToString(), x = l.X, y = l.Y, z = l.Z, dmg = amount, dtype = dt, dir = v })
    end

    -- both: radial damage. fields = { kind 0/1, origin, base, min, inner, outer, falloff, full, channel, dtype, inst }
    local function onRadial(r)
        if applying or aggro.busy or #D.out >= MAX_QUEUE then return end
        local i = r.inst
        local pc = localPC()
        local mine = valid(i) and valid(pc) and i:GetAddress() == pc:GetAddress()
        local enemy = valid(i) and i:GetFullName():find("AI_Controller", 1, true) ~= nil
        if D.role == "client" and mine then
            r.forward = false
            table.insert(D.out, r)
        elseif D.role == "host" and enemy then
            r.forward = true
            table.insert(D.out, r)
        end
    end

    local function dtPath(p)
        local s = ""
        pcall(function() local c = p:get(); if valid(c) then s = objectPath(c) end end)
        return s
    end

    function D.install()
        if hooked then return end
        hooked = true
        pcall(RegisterHook, GS .. "ApplyPointDamage", function(_, actor, dmg, dir, _hit, inst, _causer, dtype)
            pcall(onPoint, actor, dmg, dir, inst, dtype)
        end)
        pcall(RegisterHook, GS .. "ApplyRadialDamage", function(_, _w, base, origin, radius, dtype, _ign, _causer, inst, full, chan)
            pcall(function()
                local o = origin:get()
                onRadial({ kind = 0, x = o.X, y = o.Y, z = o.Z, base = base:get(), min = 0, inner = radius:get(),
                    outer = radius:get(), falloff = 0, full = full:get() and 1 or 0, channel = chan:get(),
                    dtype = dtPath(dtype), inst = inst:get() })
            end)
        end)
        pcall(RegisterHook, GS .. "ApplyRadialDamageWithFalloff", function(_, _w, base, min, origin, inner, outer, falloff, dtype, _ign, _causer, inst, chan)
            pcall(function()
                local o = origin:get()
                onRadial({ kind = 1, x = o.X, y = o.Y, z = o.Z, base = base:get(), min = min:get(), inner = inner:get(),
                    outer = outer:get(), falloff = falloff:get(), full = 0, channel = chan:get(),
                    dtype = dtPath(dtype), inst = inst:get() })
            end)
        end)
        log("damagesync: hooked point/radial damage")
    end

    function D.setRole(role)
        D.role = role
        D.out, D.inbox = {}, {}
        if role then D.install() end
    end

    function D.onHit(name, x, y, z, dmg, dtype, dx, dy, dz)
        if D.role ~= "host" or #D.inbox >= MAX_QUEUE then return end
        table.insert(D.inbox, { kind = "hit", name = name, x = x, y = y, z = z, dmg = dmg, dtype = dtype, dir = { X = dx, Y = dy, Z = dz } })
    end

    function D.onRadial(kind, x, y, z, base, min, inner, outer, falloff, full, channel, dtype)
        if #D.inbox >= MAX_QUEUE then return end
        table.insert(D.inbox, { kind = "radial", rk = kind, x = x, y = y, z = z, base = base, min = min, inner = inner,
            outer = outer, falloff = falloff, full = full, channel = channel, dtype = dtype })
    end

    local function findDestructible(ev)
        local cls = ev.name:match("^(.-)_UAID_")
        if not cls then return nil end
        for _, a in ipairs(FindAllOf(cls) or {}) do
            if valid(a) and a:GetFName():ToString() == ev.name then
                local l = a:K2_GetActorLocation()
                if (l.X - ev.x) ^ 2 + (l.Y - ev.y) ^ 2 + (l.Z - ev.z) ^ 2 < 150 * 150 then return a end
            end
        end
        return nil
    end

    local function apply(ev)
        local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        local dt = classOf(ev.dtype)
        if not dt then return false, "unknown damage type " .. tostring(ev.dtype) end
        if ev.kind == "hit" then
            local obj = findDestructible(ev)
            if not obj then return false, "not loaded " .. ev.name end
            if type(ev.dmg) ~= "number" or ev.dmg <= 0 or ev.dmg > 100000 then return false, "bad damage" end
            local pc = localPC()
            local me = aggro.localPlayer()
            applying = true
            local ok, err = pcall(function() gs:ApplyPointDamage(obj, ev.dmg, ev.dir, {}, pc, me, dt) end)
            applying = false
            if ok then D.stats.hitsApplied = D.stats.hitsApplied + 1 end
            return ok, err
        end
        -- radial: on the host it is a client's explosion (must not hurt the host player);
        -- on a client it is an enemy field (must hurt only our own player - mirrors are immune).
        local world = aggro.localController() or FindFirstOf("GI_LimaGameInstance_C")
        local me = aggro.localPlayer()
        local shield = (D.role == "host") and valid(me)
        if shield then me.bCanBeDamaged = false end
        local pc = (D.role == "host") and aggro.localController() or nil
        applying = true
        local ok, err = pcall(function()
            local o = { X = ev.x, Y = ev.y, Z = ev.z }
            if ev.rk == 1 then
                gs:ApplyRadialDamageWithFalloff(world, ev.base, ev.min, o, ev.inner, ev.outer, ev.falloff, dt, {}, nil, pc, ev.channel)
            else
                gs:ApplyRadialDamage(world, ev.base, o, ev.outer, dt, {}, nil, pc, ev.full == 1, ev.channel)
            end
        end)
        applying = false
        if shield then me.bCanBeDamaged = true end
        if ok then D.stats.radialApplied = D.stats.radialApplied + 1 end
        return ok, err
    end

    -- Network loop. ctx: client: sendHost(kind, ...); host: remote = { { id, pos } }, sendTo(id, kind, ...)
    function D.tick(ctx)
        local out = D.out
        D.out = {}
        for _, ev in ipairs(out) do
            if ev.kind == "hit" and D.role == "client" then
                ctx.sendHost("DST_HIT", ev.name, ev.x, ev.y, ev.z, ev.dmg, ev.dtype, ev.dir.X, ev.dir.Y, ev.dir.Z)
                D.stats.hitsSent = D.stats.hitsSent + 1
            elseif ev.kind == 0 or ev.kind == 1 then
                local args = { ev.kind, ev.x, ev.y, ev.z, ev.base, ev.min, ev.inner, ev.outer, ev.falloff, ev.full, ev.channel or 0, ev.dtype }
                if D.role == "client" then
                    ctx.sendHost("RADIAL", table.unpack(args))
                    D.stats.radialSent = D.stats.radialSent + 1
                elseif ev.forward and ctx.remote then
                    local reach = (ev.outer or 0) + FORWARD_MARGIN
                    for _, r in ipairs(ctx.remote) do
                        local p = r.pos
                        if (p.X - ev.x) ^ 2 + (p.Y - ev.y) ^ 2 + (p.Z - ev.z) ^ 2 <= reach * reach then
                            ctx.sendTo(r.id, "RADIAL", table.unpack(args))
                            D.stats.radialForwarded = D.stats.radialForwarded + 1
                        end
                    end
                end
            end
        end
        local inbox = D.inbox
        D.inbox = {}
        for _, ev in ipairs(inbox) do
            local ok, a, b = pcall(apply, ev)
            if not ok or not a then
                local n = D.stats.hitsApplied + D.stats.radialApplied
                if n < 5 then log("damagesync: not applied: " .. tostring(ok and b or a)) end
            end
        end
    end

    function D.clear() D.role = nil; D.out, D.inbox = {}, {} end

    return D
end

return M

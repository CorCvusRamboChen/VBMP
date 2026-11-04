-- Co-op rule "downed + teammate revive" (docs/coop-rules.md), Phase 4.1.
--
-- Evidence (self-test 2026-11-05, build 23764881): damage to the player ends in
-- CH_LimaCharacter_C.DealDamageToPlayer(double); with Debug_GodMode = true the player's health
-- does not drop (also DEBUG_TempGodMode? and bCanBeDamaged = false). Hits closer together than
-- ~1 s are ignored by the game anyway (invulnerability window).
--
-- While at least one teammate is connected, a hit that would kill the local player turns on
-- Debug_GodMode in the DealDamageToPlayer pre-hook instead: the player is downed (slow, still
-- able to shoot) and is revived when a teammate holds interact within REVIVE_DIST for
-- REVIVE_TIME seconds (REVIVE message). The run fails only when the whole team is down: the host
-- then sends WIPE and everyone's normal death runs (docs/coop-rules.md).

local M = {}

local CHAR = "/Game/FirstPerson/Blueprints/CH_LimaCharacter.CH_LimaCharacter_C"
local ENEMY_DAMAGE = "/Game/ProjectLima/Blueprints/Damage/DamageType_Enemy.DamageType_Enemy_C"
local REVIVE_DIST = 250
local REVIVE_TIME = 3
local REVIVE_HEAL = 0.3        -- of max health
local DOWNED_SPEED = 150

local function valid(o) return type(o) == "userdata" and o:IsValid() end

function M.new(log, hud)
    local D = { downed = false, bleed = 0, active = false, stats = { downs = 0, revivedBy = 0, revives = 0, bleedOuts = 0 } }
    local aggro = require("aggro")
    local hooked = false
    local pending = false
    local savedSpeed = nil
    local reviving = {}         -- teammate id -> seconds spent next to them
    local function H(fn, ...) if hud and hud[fn] then pcall(hud[fn], ...) end end

    local function health(p)
        local o = {}
        local ok = pcall(function() p:GetPlayerHealth(o, o) end)
        if ok and type(o.CurrentHealth) == "number" then return o.CurrentHealth, o.MaxHealth end
        return nil, nil
    end

    local function onDamage(self, d)
        if not D.active or D.downed or pending then return end
        local p = self:get()
        local me = aggro.localPlayer()
        if not valid(p) or not valid(me) or p:GetAddress() ~= me:GetAddress() then return end
        local dmg = d:get()
        local hp = health(p)
        if type(dmg) ~= "number" or not hp then return end
        if hp - dmg <= 0.5 then
            p.Debug_GodMode = true            -- this hit (and later ones) does nothing
            pending = true
        end
    end

    function D.install()
        if hooked then return end
        local ok, err = pcall(RegisterHook, CHAR .. ":DealDamageToPlayer", function(self, d) pcall(onDamage, self, d) end)
        hooked = true
        log("downed: hook " .. (ok and "ok" or ("FAILED " .. tostring(err))))
    end

    local function setSpeed(p, speed)
        pcall(function()
            local cm = p.CharacterMovement
            if speed then
                if not savedSpeed then savedSpeed = cm.MaxWalkSpeed end
                cm.MaxWalkSpeed = speed
            elseif savedSpeed then
                cm.MaxWalkSpeed = savedSpeed
                savedSpeed = nil
            end
        end)
    end

    local function getUp(p, heal)
        D.downed, pending = false, false
        if valid(p) then
            p.Debug_GodMode = false
            setSpeed(p, nil)
            if heal then
                local _, maxHp = health(p)
                pcall(function() p:AddHealth((maxHp or 100) * REVIVE_HEAL) end)
            end
        end
        H("setLocalDown", nil)
    end

    -- A teammate revived us.
    function D.onRevived(byName)
        if not D.downed then return end
        D.stats.revivedBy = D.stats.revivedBy + 1
        getUp(aggro.localPlayer(), true)
        log("downed: revived by " .. tostring(byName))
        H("notify", "被 " .. tostring(byName) .. " 救起")
    end

    local function die(me, why)
        D.stats.bleedOuts = D.stats.bleedOuts + 1
        log("downed: " .. why .. " - the game's own death runs")
        getUp(me, false)
        local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        local dmgType = StaticFindObject(ENEMY_DAMAGE)
        local hp = health(me) or 1
        pcall(function() gs:ApplyPointDamage(me, hp + 1000, { X = 1, Y = 0, Z = 0 }, {}, nil, nil, dmgType) end)
    end

    -- Everyone is down (the host decided): the run fails for all.
    function D.onWipe()
        local me = aggro.localPlayer()
        if valid(me) and (D.downed or pending) then die(me, "whole team down") end
    end

    -- Revive key held: the game's interact key E or gamepad X (IsInputKeyDown on the controller,
    -- self-test 2026-11-05), or the "revivehold" test command.
    D.forceHold = false
    local KEYS = { "E", "Gamepad_FaceButton_Left" }
    local function holding()
        if D.forceHold then return true end
        local pc = aggro.localController()
        if not valid(pc) then return false end
        for _, k in ipairs(KEYS) do
            local ok, down = pcall(function() return pc:IsInputKeyDown({ KeyName = FName(k) }) end)
            if ok and down then return true end
        end
        return false
    end

    -- Network loop. ctx.teammates = { [id] = { name, pos, downed } } (same level),
    -- ctx.sendRevive(id), ctx.isHost, ctx.sendWipe().
    function D.tick(dt, ctx)
        local nTeam, allDown = 0, true
        for _, t in pairs(ctx.teammates) do
            nTeam = nTeam + 1
            if not t.downed then allDown = false end
        end
        D.active = nTeam > 0
        if D.active then D.install() end
        local me = aggro.localPlayer()
        if not valid(me) then return end

        if pending and not D.downed then
            D.downed = true
            D.stats.downs = D.stats.downs + 1
            setSpeed(me, DOWNED_SPEED)
            H("setLocalDown", {})
            log("downed: down, waiting for a teammate")
        end

        if D.downed then
            me.Debug_GodMode = true
            -- Rule (docs/coop-rules.md): the run only fails when the whole team is down. The host
            -- sees everyone's flag; nobody left in the session also means death.
            if not D.active then
                die(me, "no teammate left")
            elseif ctx.isHost and allDown then
                ctx.sendWipe()
                die(me, "whole team down")
            end
        end

        -- Reviving teammates: hold interact next to a downed one for REVIVE_TIME seconds.
        local action, hint = nil, nil
        if not D.downed then
            local l = me:K2_GetActorLocation()
            local held = holding()
            for id, t in pairs(ctx.teammates) do
                if t.downed and t.pos and (t.pos.X - l.X) ^ 2 + (t.pos.Y - l.Y) ^ 2 + (t.pos.Z - l.Z) ^ 2 <= REVIVE_DIST * REVIVE_DIST then
                    if held then
                        reviving[id] = (reviving[id] or 0) + dt
                        action = { name = t.name, progress = math.min(1, reviving[id] / REVIVE_TIME) }
                        if reviving[id] >= REVIVE_TIME then
                            ctx.sendRevive(id)
                            D.stats.revives = D.stats.revives + 1
                            log("downed: revived " .. tostring(t.name))
                            reviving[id] = nil
                        end
                    else
                        reviving[id] = nil
                        hint = t.name
                    end
                else
                    reviving[id] = nil
                end
            end
        end
        if action then H("setReviveAction", action.name, action.progress) else H("setReviveAction", nil) end
        H("setReviveHint", (not action) and hint or nil)
    end

    -- Session over: never leave the player invulnerable.
    function D.clear()
        if D.downed or pending then getUp(aggro.localPlayer(), false) end
        D.active = false
        reviving = {}
    end

    return D
end

return M

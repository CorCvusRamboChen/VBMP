-- Boss health bar for clients (user report 2026-11-13: "boss开打了我看不到血条").
-- The boss lives on the host; a client only has a mirror without the boss logic, and the boss
-- itself makes its bar (CH_AI_Boss."WBP Boss Health Bar", WBP_BossHealthBar_C). So the host
-- hooks the bar's own calls and clients replay them on a bar of their own (BOSS_BAR 35).
-- Calls (CXX dump WBP_BossHealthBar.hpp): InitiateHealthBar(Health, TotalHealth, Name, HasShield?,
-- HasArmour?, Stages), SetHealthBar(NewHealth, TotalHealth, ReceivingDamage?, DamageReceived,
-- ShieldType, CriticalElement?, StaggerHealth, StaggerMaxHealth), RemoveStage(NewStage),
-- DestroyHealthBarEvent().
-- Message "<Bffffs1BH": op, a, b, c, d, name, flags, stages
--   1 init     a health, b total, name, flags 1 shield 2 armour, stages
--   2 set      a health, b total, c stagger, d stagger max, flags 1 receiving damage
--   3 stage    stages = the new stage
--   4 destroy

local M = {}

local CLASS = "/Game/ProjectLima/UI/Widgets/Health/WBP_BossHealthBar.WBP_BossHealthBar_C"
local SET_EVERY = 0.1

local function valid(o) return type(o) == "userdata" and o:IsValid() end

function M.new(log, opts)
    local B = { role = nil, out = {}, inbox = {}, stats = { sent = 0, shown = 0 } }
    local hooked, replaying = false, false
    local pendingSet, setT = nil, 0
    local bar = nil          -- client: our own bar widget
    local pc = opts.playerController

    local function f(param) local ok, v = pcall(function() return param:get() end); return ok and v or nil end

    local function tryHooks()
        if hooked then return end
        pcall(LoadAsset, CLASS)
        local ok1 = pcall(RegisterHook, CLASS .. ":InitiateHealthBar", function(_, h, t, name, shield, armour, stages)
            if replaying or B.role ~= "host" then return end
            local nm = ""
            pcall(function() nm = name:get():ToString() end)
            local flags = ((f(shield) and 1) or 0) + ((f(armour) and 2) or 0)
            table.insert(B.out, { 1, f(h) or 0, f(t) or 0, 0, 0, nm, flags, f(stages) or 0 })
        end)
        local ok2 = pcall(RegisterHook, CLASS .. ":SetHealthBar", function(_, h, t, receiving, _dmg, _shield, _crit, st, stMax)
            if replaying or B.role ~= "host" then return end
            pendingSet = { 2, f(h) or 0, f(t) or 0, f(st) or 0, f(stMax) or 0, "", f(receiving) and 1 or 0, 0 }
        end)
        local ok3 = pcall(RegisterHook, CLASS .. ":RemoveStage", function(_, stage)
            if replaying or B.role ~= "host" then return end
            table.insert(B.out, { 3, 0, 0, 0, 0, "", 0, f(stage) or 0 })
        end)
        local ok4 = pcall(RegisterHook, CLASS .. ":DestroyHealthBarEvent", function()
            if replaying or B.role ~= "host" then return end
            pendingSet = nil
            table.insert(B.out, { 4, 0, 0, 0, 0, "", 0, 0 })
        end)
        hooked = ok1 and ok2 and ok3 and ok4
        log(string.format("bossbar: hooks init %s set %s stage %s destroy %s", tostring(ok1), tostring(ok2), tostring(ok3), tostring(ok4)))
    end

    function B.setRole(role) B.role = role; B.out, B.inbox, pendingSet = {}, {}, nil end

    function B.onRemote(op, a, b, c, d, name, flags, stages)
        if B.role == "client" and #B.inbox < 32 then table.insert(B.inbox, { op, a, b, c, d, name, flags, stages }) end
    end

    local function makeBar()
        if valid(bar) then return bar end
        local cls = StaticFindObject(CLASS)
        if not valid(cls) then pcall(LoadAsset, CLASS); cls = StaticFindObject(CLASS) end
        local owner = pc()
        if not valid(cls) or not valid(owner) then return nil end
        local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        local w = lib:Create(owner, cls, owner)
        if not valid(w) then return nil end
        w:AddToViewport(10)
        bar = w
        log("bossbar: made our own boss bar")
        return bar
    end

    local function apply(ev)
        local op = ev[1]
        replaying = true
        local ok, err = pcall(function()
            if op == 1 then
                local w = makeBar()
                if w then
                    w:InitiateHealthBar(ev[2], ev[3], FText(ev[6]), (ev[7] & 1) ~= 0, (ev[7] & 2) ~= 0, ev[8])
                    B.stats.shown = B.stats.shown + 1
                    log(string.format("bossbar: %s %.0f/%.0f, %d stages", ev[6], ev[2], ev[3], ev[8]))
                end
            elseif op == 2 then
                local w = valid(bar) and bar or nil
                if w then w:SetHealthBar(ev[2], ev[3], (ev[7] & 1) ~= 0, 0, 0, false, ev[4], ev[5]) end
            elseif op == 3 then
                if valid(bar) then bar:RemoveStage(ev[8]) end
            elseif op == 4 then
                if valid(bar) then
                    bar:DestroyHealthBarEvent()
                    local w = bar
                    bar = nil
                    ExecuteInGameThreadWithDelay(3000, function() pcall(function() if w:IsValid() then w:RemoveFromParent() end end) end)
                    log("bossbar: boss bar removed")
                end
            end
        end)
        replaying = false
        if not ok then log("bossbar: op " .. tostring(op) .. " failed: " .. tostring(err)) end
    end

    -- send(op, a, b, c, d, name, flags, stages): host -> clients
    function B.tick(dt, send)
        tryHooks()
        if B.role == "host" then
            setT = setT + dt
            local out = B.out
            B.out = {}
            for _, ev in ipairs(out) do send(table.unpack(ev)); B.stats.sent = B.stats.sent + 1 end
            if pendingSet and setT >= SET_EVERY then
                setT = 0
                send(table.unpack(pendingSet))
                pendingSet = nil
                B.stats.sent = B.stats.sent + 1
            end
        elseif B.role == "client" then
            local inbox = B.inbox
            B.inbox = {}
            for _, ev in ipairs(inbox) do apply(ev) end
        end
    end

    function B.clear()
        if valid(bar) then pcall(function() bar:RemoveFromParent() end) end
        bar = nil
        B.role, B.out, B.inbox, pendingSet = nil, {}, {}, nil
    end

    return B
end

return M

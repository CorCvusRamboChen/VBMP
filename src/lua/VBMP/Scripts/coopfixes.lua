-- Single-player behaviour that must change while a co-op session runs (docs/coop-issues.md).
--
-- #1 Pause: the pause menu, terminals (upgrades / difficulty / skins / mail) and tutorial pop-ups
--    call GameplayStatics.SetGamePaused(WorldContext, true) - 19 blueprints per the object dump
--    (CallFunc_SetGamePaused locals; no blueprint calls PlayerController.SetPause). A paused host
--    freezes every enemy for the teammate too, so during a session the bPaused argument is turned
--    into false in a native pre-hook (native parameter edits stick: CLAUDE.md, SaveGameToSlot).
--    Engine.hpp: void SetGamePaused(const UObject* WorldContextObject, bool bPaused).
-- #7 Global slow motion: CH_LimaCharacter (2 calls) and PC_LimaPlayerController (1) call
--    GameplayStatics.SetGlobalTimeDilation (CallFunc_SetGlobalTimeDilation locals in their event
--    graphs; what triggers them is not readable from the dump). A host slowing its world slows
--    the enemies the teammate fights, a client slowing its own puts its world out of step with
--    the host's. During a session the value is kept at 1 the same way; the requested value is
--    logged so the triggers can be identified in play. (Time stop is a different mechanism -
--    FreezeTime per actor, synced by timestop.lua.)
--    Engine.hpp: void SetGlobalTimeDilation(const UObject* WorldContextObject, float TimeDilation).

local M = {}

local PAUSE_FN = "/Script/Engine.GameplayStatics:SetGamePaused"
local DILATION_FN = "/Script/Engine.GameplayStatics:SetGlobalTimeDilation"

function M.new(log)
    local C = { active = false, stats = { pausesBlocked = 0, dilationsBlocked = 0 } }
    local pauseHooked, dilationHooked = false, false

    function C.install()
        if not dilationHooked then
            local okD, errD = pcall(RegisterHook, DILATION_FN, function(_, _ctx, value)
                if not C.active then return end
                local okGet, v = pcall(function() return value:get() end)
                if okGet and type(v) == "number" and math.abs(v - 1) > 0.001 then
                    local okSet = pcall(function() value:set(1.0) end)
                    C.stats.dilationsBlocked = C.stats.dilationsBlocked + 1
                    if C.stats.dilationsBlocked <= 20 then
                        log(string.format("coop: global slow motion %.3f kept at 1 (%s)", v, okSet and "ok" or "set FAILED"))
                    end
                end
            end)
            dilationHooked = okD
            log("coop: time dilation hook " .. (okD and "ok" or ("FAILED " .. tostring(errD))))
        end
        if pauseHooked then return end
        local ok, err = pcall(RegisterHook, PAUSE_FN, function(_, _ctx, paused)
            if not C.active then return end
            local okGet, v = pcall(function() return paused:get() end)
            if okGet and v == true then
                local okSet = pcall(function() paused:set(false) end)
                C.stats.pausesBlocked = C.stats.pausesBlocked + 1
                if C.stats.pausesBlocked <= 5 then
                    log("coop: pause request kept the world running (" .. (okSet and "ok" or "set FAILED") .. ")")
                end
            end
        end)
        pauseHooked = ok
        log("coop: pause hook " .. (ok and "ok" or ("FAILED " .. tostring(err))))
    end

    -- main.lua: on while a host/client session exists.
    function C.setActive(on)
        C.install()
        if C.active ~= on then log("coop: single-player fixes " .. (on and "ON" or "OFF")) end
        C.active = on
        if on then
            -- already paused when the session started (e.g. joined from a terminal): resume
            pcall(function()
                local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
                local pc = FindFirstOf("PC_LimaPlayerController_C")
                if gs and gs:IsValid() and pc and pc:IsValid() and gs:IsGamePaused(pc) then
                    gs:SetGamePaused(pc, false)
                    log("coop: the world was paused - resumed")
                end
            end)
        end
    end

    return C
end

return M

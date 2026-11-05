-- Single-player behaviour that must change while a co-op session runs (docs/coop-issues.md).
--
-- #1 Pause: the pause menu, terminals (upgrades / difficulty / skins / mail) and tutorial pop-ups
--    call GameplayStatics.SetGamePaused(WorldContext, true) - 19 blueprints per the object dump
--    (CallFunc_SetGamePaused locals; no blueprint calls PlayerController.SetPause). A paused host
--    freezes every enemy for the teammate too, so during a session the bPaused argument is turned
--    into false in a native pre-hook (native parameter edits stick: CLAUDE.md, SaveGameToSlot).
--    Engine.hpp: void SetGamePaused(const UObject* WorldContextObject, bool bPaused).

local M = {}

local PAUSE_FN = "/Script/Engine.GameplayStatics:SetGamePaused"

function M.new(log)
    local C = { active = false, stats = { pausesBlocked = 0 } }
    local pauseHooked = false

    function C.install()
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

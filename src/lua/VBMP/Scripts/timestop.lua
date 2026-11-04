-- Co-op rule "time stop affects everyone" (docs/coop-rules.md), Phase 4.2.
--
-- Evidence (self-test 2026-11-05, build 23764881): the ability entry is
-- PC_LimaPlayerController_C.ABL_ActivateChronoHold?(bool Activate?, double duration). Called with
-- (true, 3) it runs FreezeTime + FreezeBH at once and ResumeTime + ResumeBH 3 s later; the global
-- time dilation stays 1.0 (the game freezes things itself).
--
-- A local activation is sent (TIMESTOP); the host applies it - freezing the real enemies - and
-- forwards it to the other clients; receivers call the same function with the same duration.

local M = {}

local PC_FN = "/Game/ProjectLima/Blueprints/Modes/PC_LimaPlayerController.PC_LimaPlayerController_C:ABL_ActivateChronoHold?"

function M.new(log)
    local T = { out = {}, inbox = {}, stats = { sent = 0, applied = 0 } }
    local aggro = require("aggro")
    local hooked, replaying = false, false

    function T.install()
        if hooked then return end
        local ok, err = pcall(RegisterHook, PC_FN, function(_, on, dur)
            if replaying then return end
            pcall(function()
                if on:get() and #T.out < 8 then table.insert(T.out, dur:get()) end
            end)
        end)
        hooked = true
        log("timestop: hook " .. (ok and "ok" or ("FAILED " .. tostring(err))))
    end

    function T.onRemote(duration, from)
        if type(duration) == "number" and duration > 0 and duration < 60 and #T.inbox < 8 then
            table.insert(T.inbox, { d = duration, from = from })
        end
    end

    -- Network loop. send(duration, exceptPeer): host -> all clients but one; client -> host.
    function T.tick(send, isHost)
        T.install()
        local out = T.out
        T.out = {}
        for _, d in ipairs(out) do
            send(d, nil)
            T.stats.sent = T.stats.sent + 1
            log(string.format("timestop: ours, %.1f s, sent", d))
        end
        local inbox = T.inbox
        T.inbox = {}
        for _, ev in ipairs(inbox) do
            local pc = aggro.localController()
            if pc then
                replaying = true
                local ok, err = pcall(function() pc["ABL_ActivateChronoHold?"](pc, true, ev.d) end)
                replaying = false
                T.stats.applied = T.stats.applied + 1
                log(string.format("timestop: teammate's, %.1f s %s", ev.d, ok and "applied" or ("FAILED " .. tostring(err))))
                if ok and isHost then send(ev.d, ev.from) end      -- to the other clients
            end
        end
    end

    function T.clear() T.out, T.inbox = {}, {} end

    return T
end

return M

-- Story sync: cutscenes and dialogue play for everyone (message STORY 27).
--
-- Research (self-test 2026-11-05, build 26439385, Biome_05):
--   * Story sequences live in "sequence container" actors that hold SequenceToPlay (ULevelSequence)
--     and play it when their Switch(On?) / Activate(Activate?) runs (the BPI switch interface that
--     levers and triggers also use). Level triggers chain into them: BP_PlayerTrigger (box overlap)
--     -> OutputSignals -> BP_SignalOps_DoOnce -> container:Switch(true).
--   * Calling container:Switch(true) from script played LS_0500_Entrance with its voice line and
--     subtitle ("1473：快点。我们快到第二座尖塔了。"); the native MovieSceneSequencePlayer:Play hook
--     saw it. Containers named "..._Dialogue_C_UAID..." in this level are BP_SequenceContainer_C.
--   * Container classes (object dump): BP_SequenceContainer, _NormalUse, _Dialogue (Triggers/),
--     _RandomTable (Cinematics/), BP_TriggerDialogueSequence (Audio/).
--
-- When a container runs Switch/Activate in one player's world (and it was not us replaying), every
-- other world calls the same function on its copy (exact class + location rounded to 50 units),
-- so the game's own sequence logic - subtitles, story flags, one-shot "Triggered?" - runs
-- everywhere. A key that already played (sent or applied) within REPEAT seconds is not sent or
-- applied again, so two players walking into the same trigger hear it once.
-- Not synced: personal lines (pickups, terminals, 1473 scout logs), boss-arena intros.

local M = {}

local CLASSES = {
    "/Game/ProjectLima/Blueprints/Gameplay/Triggers/BP_SequenceContainer.BP_SequenceContainer_C",
    "/Game/ProjectLima/Blueprints/Gameplay/Triggers/BP_SequenceContainer_NormalUse.BP_SequenceContainer_NormalUse_C",
    "/Game/ProjectLima/Blueprints/Gameplay/Triggers/BP_SequenceContainer_Dialogue.BP_SequenceContainer_Dialogue_C",
    "/Game/ProjectLima/Blueprints/Cinematics/BP_SequenceContainer_RandomTable.BP_SequenceContainer_RandomTable_C",
    "/Game/ProjectLima/Blueprints/Audio/BP_TriggerDialogueSequence.BP_TriggerDialogueSequence_C",
}
-- fn codes on the wire: 1 Switch(true), 2 Switch(false), 3 Activate(true), 4 Activate(false)
local FNS = { { "Switch", true }, { "Switch", false }, { "Activate", true }, { "Activate", false } }
local MATCH = 150
local REPEAT = 30
local HOOK_EVERY = 2.0

local function valid(o) return type(o) == "userdata" and o:IsValid() end
local function grid(v) return math.floor(v / 50 + 0.5) end

function M.new(log)
    local S = { role = nil, out = {}, inbox = {}, stats = { sent = 0, applied = 0, missing = 0, relayed = 0, skipped = 0 } }
    local hooked = {}
    local replaying = false
    local hookT = HOOK_EVERY
    local played = {}       -- key -> time it last played here (ours or applied)
    local now = 0

    local function keyOf(cls, x, y, z, code)
        return string.format("%s@%d,%d,%d#%d", cls, grid(x), grid(y), grid(z), code)
    end

    local function seqName(a)
        local ok, n = pcall(function() return a.SequenceToPlay:GetFName():ToString() end)
        return ok and n or "?"
    end

    local function onCall(self, fnName, onParam)
        if replaying or not S.role or #S.out >= 32 then return end
        local a = self:get()
        if not valid(a) then return end
        local on = true
        pcall(function() on = onParam:get() == true end)
        local code = (fnName == "Switch" and 1 or 3) + (on and 0 or 1)
        local cls = a:GetClass():GetFName():ToString()
        local l = a:K2_GetActorLocation()
        local key = keyOf(cls, l.X, l.Y, l.Z, code)
        if played[key] and now - played[key] < REPEAT then return end
        played[key] = now
        table.insert(S.out, { cls = cls, x = l.X, y = l.Y, z = l.Z, code = code, seq = seqName(a) })
    end

    local function tryHooks()
        for _, path in ipairs(CLASSES) do
            if not hooked[path] then
                pcall(LoadAsset, path)
                local okS = pcall(RegisterHook, path .. ":Switch", function(self, on) pcall(onCall, self, "Switch", on) end)
                local okA = pcall(RegisterHook, path .. ":Activate", function(self, on) pcall(onCall, self, "Activate", on) end)
                if okS or okA then
                    hooked[path] = true
                    log("story: hooked " .. path:match("([%w_]+)$"))
                end
            end
        end
    end

    function S.setRole(role) S.role = role; S.out, S.inbox = {}, {} end

    function S.onRemote(cls, x, y, z, code, from)
        if #S.inbox < 32 then table.insert(S.inbox, { cls = cls, x = x, y = y, z = z, code = code, from = from }) end
    end

    local function apply(ev)
        local fn = FNS[ev.code]
        if not fn then return false, "bad code" end
        local key = keyOf(ev.cls, ev.x, ev.y, ev.z, ev.code)
        if played[key] and now - played[key] < REPEAT then return true, "already played here" end
        local best, bestD = nil, MATCH * MATCH
        for _, a in ipairs(FindAllOf(ev.cls) or {}) do
            if valid(a) and a:GetClass():GetFName():ToString() == ev.cls then
                local l = a:K2_GetActorLocation()
                local d = (l.X - ev.x) ^ 2 + (l.Y - ev.y) ^ 2 + (l.Z - ev.z) ^ 2
                if d < bestD then best, bestD = a, d end
            end
        end
        if not best then return false, "missing" end
        played[key] = now
        replaying = true
        local ok, err = pcall(function() best[fn[1]](best, fn[2]) end)
        replaying = false
        if not ok then return false, tostring(err) end
        return true, seqName(best)
    end

    -- Network loop. send(cls, x, y, z, code, exceptPeer): host -> clients, client -> host.
    function S.tick(dt, send)
        now = now + dt
        hookT = hookT + dt
        if hookT >= HOOK_EVERY then hookT = 0; tryHooks() end
        local out = S.out
        S.out = {}
        for _, ev in ipairs(out) do
            send(ev.cls, ev.x, ev.y, ev.z, ev.code, nil)
            S.stats.sent = S.stats.sent + 1
            log(string.format("story: ours, %s %s (%s)", ev.cls, FNS[ev.code][1], ev.seq))
        end
        local inbox = S.inbox
        S.inbox = {}
        for _, ev in ipairs(inbox) do
            local ok, what = apply(ev)
            if ok then
                if what == "already played here" then
                    S.stats.skipped = S.stats.skipped + 1
                else
                    S.stats.applied = S.stats.applied + 1
                    log("story: teammate's, " .. ev.cls .. " played " .. tostring(what))
                end
                if S.role == "host" then send(ev.cls, ev.x, ev.y, ev.z, ev.code, ev.from); S.stats.relayed = S.stats.relayed + 1 end
            else
                S.stats.missing = S.stats.missing + 1
                if S.stats.missing <= 5 then log("story: " .. ev.cls .. " not applied: " .. tostring(what)) end
            end
        end
    end

    function S.clear() S.role = nil; S.out, S.inbox = {}, {} end

    return S
end

return M

-- World-changing interactions (Phase 4.4): chests, switches, levers, obelisks.
-- Research: research/phase2-04-interactions.md; class list and overrides from the CXX dump
-- (BPI_Interact implementers; subclasses without their own InteractObjectQuick run the base
-- class function, so hooking the base covers them - BP_ItemChest_MiniBoss/Specific/Utility,
-- BP_LootChest_Fire/Ice/Optics/Rare/Voltaic/Encrypted, BP_Monitor_Switch_Zone2/3).
--
-- When the local player interacts with one of these, every other player's copy of the same object
-- (exact class + location rounded to 50 units: chests are spawned at runtime, so names differ
-- between machines) gets the same InteractObjectQuick/Hold call. Chests open everywhere and each
-- player gets their own loot (rule "everyone gets a copy"); a lever or door switch moves for all;
-- an obelisk event runs on the host, where enemies live.
-- Not replayed (personal or travel): pickups, terminals, shops, crafter, recycler, researcher,
-- corruptors (the corruption goes to the interacting player), teleporters, lifts, map
-- connectors, zip lines.

local M = {}

local P = "/Game/ProjectLima/Blueprints/"
local CLASSES = {
    P .. "Pickups/BP_ItemChest_Master.BP_ItemChest_Master_C",
    P .. "Pickups/BP_Voidium_ItemChest.BP_Voidium_ItemChest_C",
    P .. "Pickups/BP_LootChest_Master.BP_LootChest_Master_C",
    P .. "Gameplay/PuzzleObjects/BP_Monitor_Switch.BP_Monitor_Switch_C",
    P .. "Gameplay/PuzzleObjects/BP_Monitor_Switch_Zone.BP_Monitor_Switch_Zone_C",
    P .. "Gameplay/PuzzleObjects/BP_DigiDoor_Switch.BP_DigiDoor_Switch_C",
    P .. "Gameplay/PuzzleObjects/BP_PuzzleLever.BP_PuzzleLever_C",
    P .. "Gameplay/Interactables/BP_SwitchAct.BP_SwitchAct_C",
    P .. "Gameplay/Interactables/BP_SwitchAct_01.BP_SwitchAct_01_C",
    P .. "Gameplay/Obelisks/BP_Interactable_Obelisk_Master.BP_Interactable_Obelisk_Master_C",
    P .. "Gameplay/Obelisks/ObeliskActors/BP_Obelisk_Corrupted.BP_Obelisk_Corrupted_C",
    P .. "Gameplay/Obelisks/ObeliskActors/BP_Obelisk_GoldRush.BP_Obelisk_GoldRush_C",
    P .. "Gameplay/Obelisks/ObeliskActors/BP_Obelisk_DoubleOrNothing.BP_Obelisk_DoubleOrNothing_C",
}
local MATCH = 150
local HOOK_EVERY = 2.0

local function valid(o) return type(o) == "userdata" and o:IsValid() end
local function grid(v) return math.floor(v / 50 + 0.5) end

function M.new(log)
    local I = { role = nil, out = {}, inbox = {}, stats = { sent = 0, applied = 0, missing = 0, relayed = 0 } }
    local hooked = {}
    local replaying = false
    local hookT = HOOK_EVERY
    local recent = {}       -- key -> time, so one press is not sent twice (two hooked classes)
    local now = 0

    local function onInteract(self, hold)
        if replaying or not I.role or #I.out >= 32 then return end
        local a = self:get()
        if not valid(a) then return end
        local cls = a:GetClass():GetFName():ToString()
        local l = a:K2_GetActorLocation()
        local key = string.format("%s@%d,%d,%d,%d", cls, grid(l.X), grid(l.Y), grid(l.Z), hold and 1 or 0)
        if recent[key] and now - recent[key] < 0.3 then return end
        recent[key] = now
        table.insert(I.out, { cls = cls, x = l.X, y = l.Y, z = l.Z, hold = hold and 1 or 0 })
    end

    local function tryHooks()
        for _, path in ipairs(CLASSES) do
            if not hooked[path] then
                pcall(LoadAsset, path)
                local okQ = pcall(RegisterHook, path .. ":InteractObjectQuick", function(self) pcall(onInteract, self, false) end)
                local okH = pcall(RegisterHook, path .. ":InteractObjectHold", function(self) pcall(onInteract, self, true) end)
                if okQ or okH then
                    hooked[path] = true
                    log("interact: hooked " .. path:match("([%w_]+)$"))
                end
            end
        end
    end

    function I.setRole(role) I.role = role; I.out, I.inbox = {}, {} end

    function I.onRemote(cls, x, y, z, hold, from)
        if #I.inbox < 32 then table.insert(I.inbox, { cls = cls, x = x, y = y, z = z, hold = hold, from = from }) end
    end

    local function apply(ev)
        local best, bestD = nil, MATCH * MATCH
        for _, a in ipairs(FindAllOf(ev.cls) or {}) do
            if valid(a) and a:GetClass():GetFName():ToString() == ev.cls then
                local l = a:K2_GetActorLocation()
                local d = (l.X - ev.x) ^ 2 + (l.Y - ev.y) ^ 2 + (l.Z - ev.z) ^ 2
                if d < bestD then best, bestD = a, d end
            end
        end
        if not best then return false end
        replaying = true
        local ok, err = pcall(function()
            if ev.hold == 1 then best:InteractObjectHold()
            else best:InteractObjectQuick(best:K2_GetActorLocation(), nil) end
        end)
        replaying = false
        if not ok then log("interact: replay of " .. ev.cls .. " failed: " .. tostring(err)) end
        return ok
    end

    -- Network loop. send(cls, x, y, z, hold, exceptPeer): host -> clients, client -> host.
    function I.tick(dt, send)
        now = now + dt
        hookT = hookT + dt
        if hookT >= HOOK_EVERY then hookT = 0; tryHooks() end
        local out = I.out
        I.out = {}
        for _, ev in ipairs(out) do
            send(ev.cls, ev.x, ev.y, ev.z, ev.hold, nil)
            I.stats.sent = I.stats.sent + 1
            log(string.format("interact: ours, %s (%s)", ev.cls, ev.hold == 1 and "hold" or "quick"))
        end
        local inbox = I.inbox
        I.inbox = {}
        for _, ev in ipairs(inbox) do
            if apply(ev) then
                I.stats.applied = I.stats.applied + 1
                log("interact: teammate's, " .. ev.cls .. " applied")
                if I.role == "host" then send(ev.cls, ev.x, ev.y, ev.z, ev.hold, ev.from); I.stats.relayed = I.stats.relayed + 1 end
            else
                I.stats.missing = I.stats.missing + 1
                if I.stats.missing <= 5 then log("interact: no " .. ev.cls .. " near the spot here") end
            end
        end
    end

    function I.clear() I.role = nil; I.out, I.inbox = {}, {} end

    return I
end

return M

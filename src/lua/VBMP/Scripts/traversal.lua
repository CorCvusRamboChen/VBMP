-- Same connecting terrain for everyone (docs/coop-issues.md, message TRAV 29).
--
-- Research (self-test 2026-11-05, build 26439385, Biome_05; research/phase4-06-regions.md):
--   * The stretches between map regions are BP_TraversalArea_C actors. On BeginPlay each runs
--     PickRandomInstance(out ChosenLevel), which takes a random row of a data table
--     (CallFunc_Array_Random in the object dump, no seed), and streams that level in:
--     LevelInstance : ULevelStreamingDynamic, PackageNameToLoad e.g.
--     /Game/ProjectLima/Levels/TransitionRegions/B05/LV_TRS_B05_01..04.
--   * So every game process picks its own: host and client had different terrain in 5 of 6
--     areas; the host, teleported to where the client stood, fell through.
--   * Fix verified on the client: old:SetShouldBeVisible(false), SetShouldBeLoaded(false),
--     SetIsRequestingUnloadAndRemoval(true); then
--     LevelStreamingDynamic.LoadLevelInstance(area, hostPackage, old.LevelTransform.Translation,
--     area rotation, out bOutSuccess, "", nil, false) -> success, and the same spot then behaved
--     the same in both worlds.
--
-- Host: sends (area location, package) for every area to a joining client and again after its
-- own level changes. Client: for 120 s after the last list, every second, swaps any area whose
-- level differs from the host's.

local M = {}

local MATCH = 100
local APPLY_FOR = 120

local function valid(o) return type(o) == "userdata" and o:IsValid() end

local function areas()
    local out = {}
    for _, a in ipairs(FindAllOf("BP_TraversalArea_C") or {}) do
        if valid(a) and not a:GetFullName():find("Default__", 1, true) then table.insert(out, a) end
    end
    return out
end

local function packageOf(area)
    local ok, v = pcall(function() return area.LevelInstance.PackageNameToLoad:ToString() end)
    if ok and type(v) == "string" and v ~= "" and v ~= "None" then return v end
    return nil
end

function M.new(log)
    local T = { role = nil, list = {}, until_ = 0, stats = { sent = 0, swapped = 0, same = 0 } }
    local now = 0
    local timer = 0

    function T.setRole(role) T.role = role; T.list = {}; T.until_ = 0 end

    -- Host: every area to one client. sendTo(x, y, z, package).
    function T.hostSendAll(sendTo)
        local n = 0
        for _, a in ipairs(areas()) do
            local pkg = packageOf(a)
            if pkg then
                local l = a:K2_GetActorLocation()
                sendTo(l.X, l.Y, l.Z, pkg)
                n = n + 1
            end
        end
        T.stats.sent = T.stats.sent + n
        log("traversal: sent " .. n .. " area levels")
    end

    -- Client: one area from the host.
    function T.onRemote(x, y, z, pkg)
        if T.role ~= "client" or type(pkg) ~= "string" or pkg == "" then return end
        for _, e in ipairs(T.list) do
            if math.abs(e.x - x) < MATCH and math.abs(e.y - y) < MATCH then e.pkg = pkg; T.until_ = now + APPLY_FOR; return end
        end
        table.insert(T.list, { x = x, y = y, z = z, pkg = pkg })
        T.until_ = now + APPLY_FOR
    end

    local function swap(area, pkg)
        local old = area.LevelInstance
        local tr = old.LevelTransform
        local at = { X = tr.Translation.X, Y = tr.Translation.Y, Z = tr.Translation.Z }
        pcall(function() old:SetShouldBeVisible(false) end)
        pcall(function() old:SetShouldBeLoaded(false) end)
        pcall(function() old:SetIsRequestingUnloadAndRemoval(true) end)
        local lsd = StaticFindObject("/Script/Engine.Default__LevelStreamingDynamic")
        local res = {}
        local new = lsd:LoadLevelInstance(area, pkg, at, area:K2_GetActorRotation(), res, "", nil, false)
        if valid(new) then area.LevelInstance = new end
        return valid(new)
    end

    -- Own loop (main.lua), also while levels load.
    function T.tick(dt)
        now = now + dt
        -- No time limit: a reload (worldsync) re-rolls our areas long after the list arrived.
        -- Entries from an earlier level match no area here and cost nothing.
        if T.role ~= "client" or #T.list == 0 then return end
        timer = timer + dt
        if timer < 1 then return end
        timer = 0
        for _, a in ipairs(areas()) do
            local l = a:K2_GetActorLocation()
            for _, e in ipairs(T.list) do
                if math.abs(e.x - l.X) < MATCH and math.abs(e.y - l.Y) < MATCH then
                    local mine = packageOf(a)
                    if mine and mine ~= e.pkg then
                        local ok, res = pcall(swap, a, e.pkg)
                        T.stats.swapped = T.stats.swapped + ((ok and res) and 1 or 0)
                        log(string.format("traversal: area at %.0f,%.0f %s -> %s %s", l.X, l.Y,
                            mine:match("([^/]+)$") or mine, e.pkg:match("([^/]+)$") or e.pkg, (ok and res) and "ok" or ("FAILED " .. tostring(res))))
                    end
                end
            end
        end
    end

    function T.clear() T.role = nil; T.list = {}; T.until_ = 0 end

    return T
end

return M

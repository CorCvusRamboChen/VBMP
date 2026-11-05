-- Region progression for the team (docs/coop-issues.md #2, message REGION 28).
--
-- Research (self-test 2026-11-05, build 26439385, Biome_05; research/phase4-06-regions.md):
--   * The run is a chain of map regions, BP_Scenario_Master_C subclasses (_Red, _Orange, _Boss;
--     class /Game/ProjectLima/Voxel/BP_Scenario_Master). Each has a big RunProgressor sphere
--     (radius ~11400). A character entering it fires
--     BndEvt__BP_Scenario_Master_RunProgressor_..._ComponentBeginOverlapSignature(OverlappedComponent,
--     OtherActor, ...), and the region runs ProgressWall() + ProgressScenario() - the previous
--     region is walled off behind the player.
--   * Teleporting the player into the sphere fires that overlap too.
--   * In the host's world a teammate's aggro stand-in is a CH_LimaCharacter_C as well, so it can
--     set this off while the host is still behind.
--
-- Rule (2026-11-05): when a player's own character enters a new region, everyone else gets a
-- toast and, TELEPORT_DELAY later, is teleported next to them; in their world the arrival enters
-- the same sphere, so the game advances and walls off there as well. Entries by a stand-in are
-- not announced (that teammate's own world announces it). A region is announced once.

local M = {}

local MASTER = "/Game/ProjectLima/Voxel/BP_Scenario_Master.BP_Scenario_Master_C"
local OVERLAP = "BndEvt__BP_Scenario_Master_RunProgressor_K2Node_ComponentBoundEvent_1_ComponentBeginOverlapSignature__DelegateSignature"
local TELEPORT_DELAY = 3.0
local NEAR = 1500                -- already this close to the leader: no teleport
local MATCH = 300
local HOOK_EVERY = 2.0
-- Self-test 2026-11-05: the ground where the teammate stood took more than 8 s to stream in
-- after the arrival (it was there a few seconds later), so wait up to this long.
local HOVER_MAX = 25

local function valid(o) return type(o) == "userdata" and o:IsValid() end
local function grid(v) return math.floor(v / 100 + 0.5) end

function M.new(log, hud, localPlayer)
    local R = { role = nil, out = {}, inbox = {}, pending = nil,
                stats = { entered = 0, ignoredStandIn = 0, teleported = 0, received = 0 } }
    local hooked = false
    local hookT = HOOK_EVERY
    local announced = {}           -- region key -> true
    local now = 0

    local function keyOf(cls, x, y, z) return string.format("%s@%d,%d,%d", cls, grid(x), grid(y), grid(z)) end

    local function onEnter(self, other)
        if not R.role then return end
        local region = self:get()
        if not valid(region) then return end
        local who = other:get()
        local me = localPlayer()
        if not valid(who) or not valid(me) then return end
        if who:GetAddress() ~= me:GetAddress() then
            R.stats.ignoredStandIn = R.stats.ignoredStandIn + 1
            return
        end
        local cls = region:GetClass():GetFName():ToString()
        local l = region:K2_GetActorLocation()
        local key = keyOf(cls, l.X, l.Y, l.Z)
        if announced[key] or #R.out >= 8 then return end
        announced[key] = true
        local p = me:K2_GetActorLocation()
        table.insert(R.out, { cls = cls, x = l.X, y = l.Y, z = l.Z, px = p.X, py = p.Y, pz = p.Z })
    end

    local function tryHook()
        if hooked then return end
        local ok, err = pcall(RegisterHook, MASTER .. ":" .. OVERLAP, function(self, _comp, other)
            pcall(onEnter, self, other)
        end)
        hooked = ok
        log("region: hook " .. (ok and "ok" or ("FAILED " .. tostring(err))))
    end

    function R.setRole(role) R.role = role; R.out, R.inbox, R.pending = {}, {}, nil; announced = {} end

    function R.onRemote(cls, x, y, z, px, py, pz, from)
        if #R.inbox < 8 then table.insert(R.inbox, { cls = cls, x = x, y = y, z = z, px = px, py = py, pz = pz, from = from }) end
    end

    local function teleport(ev)
        local me = localPlayer()
        if not valid(me) then return false end
        local l = me:K2_GetActorLocation()
        local d = math.sqrt((l.X - ev.px) ^ 2 + (l.Y - ev.py) ^ 2 + (l.Z - ev.pz) ^ 2)
        if d < NEAR then log(string.format("region: already %.0f from the teammate, no teleport", d)); return true end
        local ang = math.random() * 2 * math.pi
        local ok = pcall(function()
            me:K2_SetActorLocation({ X = ev.px + math.cos(ang) * 150, Y = ev.py + math.sin(ang) * 150, Z = ev.pz + 60 }, false, {}, true)
        end)
        R.stats.teleported = R.stats.teleported + (ok and 1 or 0)
        log(string.format("region: teleported %.0f to the teammate in %s %s", d, ev.cls, ok and "ok" or "FAILED"))
        -- Hover (gravity off) until a downward trace finds ground: the spot may not be streamed
        -- in yet here (self-test: a player dropped there fell 5000 units in 2 s, then the game's
        -- fall recovery put him back where he came from).
        if ok then
            pcall(function()
                local cm = me.CharacterMovement
                R.hover = { me = me, cm = cm, g = cm.GravityScale, untilT = now + HOVER_MAX }
                cm.GravityScale = 0
                cm.Velocity = { X = 0, Y = 0, Z = 0 }
            end)
            pcall(hud.notify, "正在加载新区域…", nil, 4)
        end
        return ok
    end

    local function groundBelow(me)
        local ks = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        local l = me:K2_GetActorLocation()
        local okT, hit = pcall(function()
            return ks:LineTraceSingle(me, { X = l.X, Y = l.Y, Z = l.Z }, { X = l.X, Y = l.Y, Z = l.Z - 3000 }, 0, false, {}, 0, {}, true,
                { R = 0, G = 0, B = 0, A = 0 }, { R = 0, G = 0, B = 0, A = 0 }, 0)
        end)
        return okT and hit == true
    end

    local function hoverTick()
        local h = R.hover
        if not h then return end
        if not valid(h.me) or not valid(h.cm) then R.hover = nil; return end
        h.cm.Velocity = { X = 0, Y = 0, Z = 0 }
        local landed = groundBelow(h.me)
        if landed or now >= h.untilT then
            h.cm.GravityScale = h.g
            R.hover = nil
            log("region: " .. (landed and "ground found, dropping" or ("no ground after " .. HOVER_MAX .. " s, dropping anyway")))
        end
    end

    -- Network loop. send(cls, x, y, z, px, py, pz, exceptPeer): host -> clients, client -> host.
    function R.tick(dt, send)
        now = now + dt
        hookT = hookT + dt
        if hookT >= HOOK_EVERY then hookT = 0; tryHook() end
        local out = R.out
        R.out = {}
        for _, ev in ipairs(out) do
            send(ev.cls, ev.x, ev.y, ev.z, ev.px, ev.py, ev.pz, nil)
            R.stats.entered = R.stats.entered + 1
            log(string.format("region: we entered %s first, teammates follow", ev.cls))
        end
        local inbox = R.inbox
        R.inbox = {}
        for _, ev in ipairs(inbox) do
            R.stats.received = R.stats.received + 1
            local key = keyOf(ev.cls, ev.x, ev.y, ev.z)
            if R.role == "host" then send(ev.cls, ev.x, ev.y, ev.z, ev.px, ev.py, ev.pz, ev.from) end
            if not announced[key] then
                announced[key] = true          -- our own arrival there must not pull them back
                R.pending = { at = now + TELEPORT_DELAY, ev = ev }
                pcall(hud.notify, "队友进入了新区域，" .. math.floor(TELEPORT_DELAY) .. " 秒后把你传送到他身边", nil, TELEPORT_DELAY + 1)
                log("region: teammate entered " .. ev.cls .. ", teleport in " .. TELEPORT_DELAY .. " s")
            end
        end
        if R.pending and now >= R.pending.at then
            local ev = R.pending.ev
            R.pending = nil
            teleport(ev)
        end
        pcall(hoverTick)
    end

    function R.clear()
        if R.hover then pcall(function() R.hover.cm.GravityScale = R.hover.g end); R.hover = nil end
        R.role = nil; R.out, R.inbox, R.pending = {}, {}, nil
    end

    return R
end

return M

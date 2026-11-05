-- VBMP session: host / client / loopback roles on top of a transport.
-- Star topology: clients talk only to the host; the host relays player STATE/LEVEL between
-- clients with the original sender id kept in the header.
-- Authority (docs/architecture.md): each player owns their own position; everything else
-- (world, enemies, destruction) will be host-owned in later phases.
--
-- Discovery and session accept use Steam rich presence through SteamCore UFriends
-- (build 23764881): host sets vbmp=host, client sets vbmp=client. The client picks a friend
-- whose vbmp is "host"; the host accepts P2P sessions from friends whose vbmp is "client"
-- (old ISteamNetworking holds packets from a new peer until AcceptP2PSessionWithUser).
--   UFriends GetFriendCount(TArray<ESteamFriendFlags>), GetFriendByIndex(int32, flags) -> FSteamID,
--            GetFriendRichPresence(FSteamID, FString) -> FString, GetFriendPersonaName(FSteamID),
--            SetRichPresence(FString, FString), ClearRichPresence(), GetPersonaName()
--   ESteamFriendFlags::Immediate = 3 (SteamCore enum index)

local codec = require("codec")
local T = codec.T

local M = {}

M.MOD_BUILD = 4                  -- bump when the protocol or sync behaviour changes (2: 0.3.0, messages 12-26; 3: 0.6.0, STORY 27; 4: 0.7.0, REGION 28, TRAV 29)
local SEND_RATE = 1 / 30
local HELLO_EVERY = 1.0
local HELLO_GIVE_UP = 30.0
local PING_EVERY = 2.0
local LEVEL_EVERY = 5.0
local ACCEPT_SCAN_EVERY = 2.0
local TIMEOUT = 45.0        -- level loads stall the game thread (and our loops) for many seconds
local FRIEND_IMMEDIATE = 3

local function valid(o) return o ~= nil and o:IsValid() end
local function str(v)
    if type(v) == "string" then return v end
    local ok, s = pcall(function() return v:ToString() end)
    return ok and s or tostring(v)
end

function M.new(opts)
    local log, tr, puppets = opts.log, opts.transport, opts.puppets
    local S = {
        mode = opts.mode,               -- "host" | "client" | "loopback"
        state = "starting",
        hostId = opts.hostId,
        peers = {},                     -- id -> { name, lastSeen, level, rtt }
        selfName = opts.name or "Player",
        error = nil,
    }
    local timers = { send = 0, hello = 0, ping = 0, level = 0, scan = 0, hp = 0, hpForce = 0, cursor = 0, status = 0 }
    local started = nil
    local lastLevelSent = nil
    local lastHp = nil
    local lastCursor = nil            -- { x, y, flags, kind, index } last CURSOR sent
    local lastDragItem = ""
    local dragItems = {}              -- id -> item name from DRAG_ITEM

    -- Enemy sync (enemies.lua) is optional too; loopback does not use it.
    local enemies = opts.enemies
    -- Destruction sync (destruction.lua), optional as well.
    local destruction = opts.destruction
    -- World sync (worldsync.lua): the joining client loads the host's save.
    local worldsync = opts.worldsync
    local worldResendAt = nil
    -- Point/radial damage forwarding (damagesync.lua).
    local damagesync = opts.damagesync
    -- Downed + revive (downed.lua).
    local downed = opts.downed
    -- Time stop for everyone (timestop.lua).
    local timestop = opts.timestop
    -- Chests, switches, levers, obelisks (interact.lua).
    local interact = opts.interact
    -- Cutscenes and dialogue for everyone (storysync.lua).
    local storysync = opts.storysync
    -- New map regions pull the team together (regionsync.lua).
    local regionsync = opts.regionsync
    -- Same connecting terrain for everyone (traversal.lua).
    local traversal = opts.traversal
    local lastDownFlag = 0

    -- HUD (hud.lua) is optional; every call is guarded so a UI error never breaks networking.
    local hud = opts.hud
    local function H(fn, ...)
        if hud and hud[fn] then
            local ok, err = pcall(hud[fn], ...)
            if not ok then log("hud." .. fn .. " failed: " .. tostring(err)) end
        end
    end

    local function friends() return FindFirstOf("Friends") end
    local function utils() return StaticFindObject("/Script/SteamCore.Default__SteamUtilities") end

    -- Only the in-Lua Steam transport (unusable, see transport.lua) uses SteamCore presence; the
    -- Steam helper process (steam/vbmp-steam.ps1) sets its own and must not be overwritten.
    local function setPresence(value)
        if tr.kind ~= "steam" then return end
        local f = friends()
        if valid(f) then pcall(function() f:SetRichPresence("vbmp", value) end) end
    end

    -- { {id, name, presence} } for friends whose vbmp presence matches want (nil = any vbmp)
    local function scanFriends(want)
        local out = {}
        local f, u = friends(), utils()
        if not valid(f) or not valid(u) then return out end
        local okCount, n = pcall(function() return f:GetFriendCount({ FRIEND_IMMEDIATE }) end)
        if not okCount or type(n) ~= "number" then return out end
        for i = 0, n - 1 do
            pcall(function()
                local fid = f:GetFriendByIndex(i, { FRIEND_IMMEDIATE })
                local rp = str(f:GetFriendRichPresence(fid, "vbmp"))
                if rp ~= "" and (want == nil or rp == want) then
                    table.insert(out, {
                        id = math.tointeger(tonumber(str(u:BreakSteamID(fid)))),
                        name = str(f:GetFriendPersonaName(fid)),
                        presence = rp,
                    })
                end
            end)
        end
        return out
    end

    local function send(to, kind, reliable, ...)
        tr.send(to, codec.encode(kind, tr.selfId, ...), reliable)
    end

    local function sendRaw(to, bytes, reliable) tr.send(to, bytes, reliable) end

    local function addPeer(id, name)
        local p = S.peers[id]
        if not p then
            p = { name = name, lastSeen = S.now }
            S.peers[id] = p
            log(string.format("peer joined: %s (%s)", tostring(name), tostring(id)))
            H("notify", tostring(name or "玩家") .. " 加入了")
        end
        p.name = name or p.name
        p.lastSeen = S.now
        puppets.setName(id, p.name or "?")
        H("setTeammate", id, { name = p.name or ("Player" .. tostring(id):sub(-4)), connected = true })
        return p
    end

    local function dropPeer(id, why)
        if S.peers[id] then
            log(string.format("peer left: %s (%s) - %s", tostring(S.peers[id].name), tostring(id), why))
            H("notify", tostring(S.peers[id].name) .. " 离开了（" .. why .. "）")
        end
        S.peers[id] = nil
        dragItems[id] = nil
        puppets.remove(id)
        H("removeTeammate", id)
    end

    local function fail(reason)
        S.state = "failed"
        S.error = reason
        H("notify", reason, nil, 8)
    end

    local function relay(sender, bytes, reliable)
        if S.mode ~= "host" then return end
        for id in pairs(S.peers) do if id ~= sender then sendRaw(id, bytes, reliable) end end
    end

    local function knownPeer(sender)
        return S.peers[sender] or (S.mode == "client" and addPeer(sender, nil)) or nil
    end

    -----------------------------------------------------------------------------------------

    function S.start(now)
        S.now = now
        started = now
        local f = friends()
        if valid(f) then
            local ok, n = pcall(function() return str(f:GetPersonaName()) end)
            if ok and n ~= "" and not opts.name then S.selfName = n end
        end
        puppets.isHost = (S.mode == "host")
        if S.mode == "host" then
            setPresence("host")
            S.state = "hosting"
            log("hosting as " .. S.selfName .. " (" .. tostring(tr.selfId) .. ")")
            if enemies then
                enemies.setRole("host")
                pcall(enemies.hostAdoptPool, function() end)   -- ids for enemies already alive
            end
            if destruction then destruction.setRole("host") end
            if worldsync then worldsync.setRole("host") end
            if damagesync then damagesync.setRole("host") end
            if interact then interact.setRole("host") end
            if storysync then storysync.setRole("host") end
            if regionsync then regionsync.setRole("host") end
            if traversal then traversal.setRole("host") end
        elseif S.mode == "client" then
            setPresence("client")
            if not S.hostId then
                local hosts = scanFriends("host")
                if #hosts > 0 then
                    S.hostId = hosts[1].id
                    log(string.format("found host via Steam friends: %s (%s)", hosts[1].name, tostring(hosts[1].id)))
                end
            end
            if not S.hostId then
                S.state = "failed"
                S.error = "没有找到正在开房的 Steam 好友"
                log("join: no friend is hosting")
                return
            end
            S.state = "connecting"
            log("connecting to " .. tostring(S.hostId))
            if enemies then enemies.setRole("client") end
            if destruction then destruction.setRole("client") end
            if worldsync then worldsync.setRole("client") end
            if damagesync then damagesync.setRole("client") end
            if interact then interact.setRole("client") end
            if storysync then storysync.setRole("client") end
            if regionsync then regionsync.setRole("client") end
            if traversal then traversal.setRole("client") end
        elseif S.mode == "loopback" then
            addPeer(tr.fakePeer, "Loopback")
            S.state = "loopback"
            log("loopback: your own state comes back as a remote player 2 s later")
        end
    end

    function S.stop()
        for id in pairs(S.peers) do
            if S.mode ~= "loopback" then send(id, T.BYE, true) end
            dropPeer(id, "session stopped")
        end
        if tr.kind == "steam" then
            local f = friends()
            if valid(f) then pcall(function() f:ClearRichPresence() end) end
        end
        S.state = "stopped"
        if enemies then pcall(enemies.clear) end
        if destruction then pcall(destruction.clear) end
        if worldsync then pcall(worldsync.clear) end
        if downed then pcall(downed.clear) end
        if timestop then pcall(timestop.clear) end
        if interact then pcall(interact.clear) end
        if storysync then pcall(storysync.clear) end
        if regionsync then pcall(regionsync.clear) end
        if traversal then pcall(traversal.clear) end
        if damagesync then pcall(damagesync.clear) end
        H("setStatus", nil)
        H("clear")
    end

    -- Own health (PLAYER_HP) and inventory cursor (CURSOR / DRAG_ITEM), see docs/ui-design.md.
    local function sendUi(localState, dt, targets)
        if #targets == 0 then return end
        timers.hp = timers.hp + dt
        timers.hpForce = timers.hpForce + dt
        if localState and type(localState.hp) == "number" and timers.hp >= 0.1 then
            local downFlag = (downed and downed.downed) and 1 or 0
            local changed = lastHp == nil or math.abs(localState.hp - lastHp) >= 1 or downFlag ~= lastDownFlag
            if changed or timers.hpForce >= 2 then
                timers.hp, timers.hpForce = 0, 0
                lastHp, lastDownFlag = localState.hp, downFlag
                local maxHp = type(localState.maxHp) == "number" and localState.maxHp or 0
                local bytes = codec.encode(T.PLAYER_HP, tr.selfId, localState.hp, maxHp, downFlag)
                -- reliable when the downed flag is in it: a lost "downed" would strand the player
                for _, id in ipairs(targets) do sendRaw(id, bytes, downFlag == 1) end
            end
        end

        timers.cursor = timers.cursor + dt
        if not hud or timers.cursor < 0.066 then return end
        timers.cursor = 0
        local okC, c = pcall(hud.getLocalCursor)
        if not okC or not c then return end
        local item = (c.open and c.drag and c.drag.item) or ""
        if item ~= lastDragItem then
            lastDragItem = item
            local bytes = codec.encode(T.DRAG_ITEM, tr.selfId, item)
            for _, id in ipairs(targets) do sendRaw(id, bytes, true) end
        end
        local cur
        if c.open and c.x then
            local flags = 1 | (c.drag and 2 or 0)
            cur = { math.floor(c.x * 65535), math.floor(c.y * 65535), flags,
                c.drag and c.drag.kind or 0, c.drag and c.drag.index or 0 }
        elseif lastCursor and lastCursor[3] ~= 0 then
            cur = { 0, 0, 0, 0, 0 }           -- inventory closed: tell everyone once, reliably
        end
        if cur and (not lastCursor or cur[1] ~= lastCursor[1] or cur[2] ~= lastCursor[2]
                or cur[3] ~= lastCursor[3] or cur[4] ~= lastCursor[4] or cur[5] ~= lastCursor[5]) then
            lastCursor = cur
            local bytes = codec.encode(T.CURSOR, tr.selfId, table.unpack(cur))
            for _, id in ipairs(targets) do sendRaw(id, bytes, cur[3] == 0) end
        end
    end

    -----------------------------------------------------------------------------------------

    local function onPacket(bytes)
        local kind, sender, a, b, c, d, e, f, g, h, i, j, k, l = codec.decode(bytes)
        if not kind then
            log("bad packet: " .. tostring(sender))
            return
        end
        if S.mode == "loopback" then sender = tr.fakePeer end
        if sender == tr.selfId then return end
        -- Any packet keeps a peer alive (a host in the main menu or a loading screen sends no STATE).
        local seen = S.peers[sender]
        if seen then seen.lastSeen = S.now end

        if kind == T.HELLO and S.mode == "host" then
            if a ~= M.MOD_BUILD then
                send(sender, T.REJECT, true, "mod build mismatch: host " .. M.MOD_BUILD .. ", you " .. tostring(a))
                log("rejected " .. tostring(b) .. ": mod build " .. tostring(a))
                return
            end
            tr.accept(sender)
            addPeer(sender, b)
            send(sender, T.WELCOME, true, S.selfName)
            if lastLevelSent then send(sender, T.LEVEL, true, lastLevelSent) end
            if enemies then
                pcall(enemies.hostSendAll, function(kind, reliable, ...) send(sender, T[kind], reliable, ...) end)
            end
            if destruction then
                pcall(destruction.hostSendAll, function(n, x, y, z) send(sender, T.DST_BREAK, true, n, x, y, z) end)
            end
            if traversal then
                pcall(traversal.hostSendAll, function(x, y, z, pkg) send(sender, T.TRAV, true, x, y, z, pkg) end)
            end
            if worldsync then
                local ok, err = pcall(worldsync.hostSendTo, function(id, total, off, bytes)
                    send(sender, T.WORLD_SAVE, true, id, total, off, bytes)
                end)
                if not ok then log("worldsync send failed: " .. tostring(err)) end
            end
        elseif kind == T.WELCOME and S.mode == "client" then
            if S.state ~= "connected" then log("connected to host " .. tostring(a)) end
            S.state = "connected"
            addPeer(sender, a)
            if lastLevelSent then send(sender, T.LEVEL, true, lastLevelSent) end
        elseif kind == T.REJECT then
            fail("被房主拒绝：" .. tostring(a))
            log("rejected by host: " .. tostring(a))
        elseif kind == T.STATE then
            local p = S.peers[sender] or (S.mode == "client" and addPeer(sender, nil)) or nil
            if not p then return end
            p.lastSeen = S.now
            p.pos = { X = b, Y = c, Z = d }          -- enemies.lua picks shot targets from these
            puppets.push(sender, S.now, b, c, d, e, f)
            if S.mode == "host" then
                for id in pairs(S.peers) do if id ~= sender then sendRaw(id, bytes, false) end end
            end
        elseif kind == T.LEVEL then
            local p = S.peers[sender] or (S.mode == "client" and addPeer(sender, nil)) or nil
            if not p then return end
            if p.level ~= a then log(string.format("%s is in %s", tostring(p.name), tostring(a))) end
            p.level = a
            puppets.setLevel(sender, a)
            H("setTeammate", sender, { otherLevel = (lastLevelSent ~= nil and a ~= lastLevelSent) })
            relay(sender, bytes, true)
        elseif kind == T.PLAYER_HP then
            if not knownPeer(sender) then return end
            H("setTeammate", sender, { hp = a, maxHp = b, downed = ((c or 0) & 1) ~= 0 })
            local pp = S.peers[sender]
            if pp then pp.downed = ((c or 0) & 1) ~= 0 end
            relay(sender, bytes, false)
        elseif kind == T.CURSOR then
            if not knownPeer(sender) then return end
            local flags = c or 0
            local drag = nil
            if (flags & 2) ~= 0 then drag = { kind = d, index = e, item = dragItems[sender] } end
            H("setRemoteCursor", sender, a / 65535, b / 65535, (flags & 1) ~= 0, drag)
            relay(sender, bytes, (flags & 1) == 0)
        elseif kind == T.DRAG_ITEM then
            if not knownPeer(sender) then return end
            dragItems[sender] = a
            relay(sender, bytes, true)
        elseif kind == T.ENEMY_SPAWN or kind == T.ENEMY_STATE or kind == T.ENEMY_DESPAWN or kind == T.ENEMY_DEATH
            or kind == T.ENEMY_SHOT then
            if S.mode ~= "client" or sender ~= S.hostId or not enemies then return end
            if kind == T.ENEMY_SPAWN then enemies.clientOnSpawn(a, b, c, d, e, f)
            elseif kind == T.ENEMY_STATE then enemies.clientOnState(S.now, a, b, c, d, e, f, g)
            elseif kind == T.ENEMY_DEATH then enemies.clientOnDeath(a)
            elseif kind == T.ENEMY_SHOT then enemies.clientOnShot(a, b, c, d, e, f, g)
            else enemies.clientOnDespawn(a) end
        elseif kind == T.ENEMY_HIT then
            -- client hit intent: the host applies it through the game's own damage path
            if S.mode ~= "host" or not knownPeer(sender) or not enemies then return end
            enemies.hostOnHit(sender, a, b, c, d, e, f, g)
        elseif kind == T.DST_HIT then
            if damagesync and S.mode == "host" and knownPeer(sender) then damagesync.onHit(a, b, c, d, e, f, g, h, i) end
        elseif kind == T.RADIAL then
            if not damagesync then return end
            if (S.mode == "host" and knownPeer(sender)) or (S.mode == "client" and sender == S.hostId) then
                damagesync.onRadial(a, b, c, d, e, f, g, h, i, j, k, l)
            end
        elseif kind == T.PLAYER_HIT then
            if damagesync and S.mode == "client" and sender == S.hostId then damagesync.onPlayerHit(a) end
        elseif kind == T.INTERACT then
            if not interact then return end
            if (S.mode == "host" and knownPeer(sender)) or (S.mode == "client" and sender == S.hostId) then
                interact.onRemote(a, b, c, d, e, sender)
            end
        elseif kind == T.STORY then
            if not storysync then return end
            if (S.mode == "host" and knownPeer(sender)) or (S.mode == "client" and sender == S.hostId) then
                storysync.onRemote(a, b, c, d, e, sender)
            end
        elseif kind == T.REGION then
            if not regionsync then return end
            if (S.mode == "host" and knownPeer(sender)) or (S.mode == "client" and sender == S.hostId) then
                regionsync.onRemote(a, b, c, d, e, f, g, sender)
            end
        elseif kind == T.TRAV then
            if traversal and S.mode == "client" and sender == S.hostId then traversal.onRemote(a, b, c, d) end
        elseif kind == T.WIPE then
            if downed and S.mode == "client" and sender == S.hostId then downed.onWipe() end
        elseif kind == T.TIMESTOP then
            if not timestop then return end
            if (S.mode == "host" and knownPeer(sender)) or (S.mode == "client" and sender == S.hostId) then
                timestop.onRemote(a, sender)
            end
        elseif kind == T.REVIVE then
            if not downed or not knownPeer(sender) then return end
            if a == tr.selfId then
                downed.onRevived(S.peers[sender] and S.peers[sender].name)
            elseif S.mode == "host" and S.peers[a] then
                sendRaw(a, bytes, true)                       -- client revives client: forward
            end
        elseif kind == T.WORLD_SAVE then
            if worldsync and S.mode == "client" and sender == S.hostId then worldsync.onChunk(a, b, c, d) end
        elseif kind == T.DST_BREAK then
            if not destruction then return end
            if S.mode == "host" and knownPeer(sender) then destruction.onRemote(a, b, c, d, sender)
            elseif S.mode == "client" and sender == S.hostId then destruction.onRemote(a, b, c, d, nil) end
        elseif kind == T.PING then
            send(sender, T.PONG, false, a)
        elseif kind == T.PONG then
            local p = S.peers[sender]
            if p then
                p.rtt = (S.now - a) * 1000
                H("setTeammate", sender, { ping = p.rtt })
            end
        elseif kind == T.BYE then
            dropPeer(sender, "said bye")
        end
    end

    -- local: { x, y, z, yaw, pitch, level } or nil when there is no player (menus, loading)
    function S.update(now, dt, localState)
        S.now = now
        if tr.advance then tr.advance(dt) end
        tr.poll(onPacket)

        if S.state == "failed" or S.state == "stopped" then return end

        if localState and localState.level ~= lastLevelSent then
            -- Host moved from one level to another: clients follow by reloading the new save,
            -- a few seconds later so the game has saved the new level itself (worldsync.lua).
            if S.mode == "host" and worldsync and lastLevelSent then worldResendAt = now + 3 end
            lastLevelSent = localState.level
            timers.level = LEVEL_EVERY      -- send right away
        end
        if worldResendAt and now >= worldResendAt then
            worldResendAt = nil
            for id in pairs(S.peers) do
                if traversal then
                    pcall(traversal.hostSendAll, function(x, y, z, pkg) send(id, T.TRAV, true, x, y, z, pkg) end)
                end
                local ok, err = pcall(worldsync.hostSendTo, function(tid, total, off, bytes)
                    send(id, T.WORLD_SAVE, true, tid, total, off, bytes)
                end)
                if not ok then log("worldsync resend failed: " .. tostring(err)) end
            end
        end

        if S.mode == "client" and S.state == "connecting" then
            timers.hello = timers.hello + dt
            if timers.hello >= HELLO_EVERY then
                timers.hello = 0
                send(S.hostId, T.HELLO, true, M.MOD_BUILD, S.selfName)
            end
            if now - started > (opts.helloGiveUp or HELLO_GIVE_UP) then
                fail("连接超时（房主没有回应）")
                log("join: host did not answer in " .. (opts.helloGiveUp or HELLO_GIVE_UP) .. " s")
            end
            return
        end

        if S.mode == "host" and tr.kind == "steam" then
            timers.scan = timers.scan + dt
            if timers.scan >= ACCEPT_SCAN_EVERY then
                timers.scan = 0
                for _, fr in ipairs(scanFriends("client")) do
                    if fr.id and not S.peers[fr.id] then tr.accept(fr.id) end
                end
            end
        end

        local targets = {}
        for id in pairs(S.peers) do table.insert(targets, id) end

        timers.send = timers.send + dt
        if localState and timers.send >= SEND_RATE then
            timers.send = 0
            local bytes = codec.encode(T.STATE, tr.selfId, now, localState.x, localState.y, localState.z,
                localState.yaw, localState.pitch, 0)
            for _, id in ipairs(targets) do sendRaw(id, bytes, false) end
        end

        sendUi(localState, dt, targets)

        if enemies and S.mode == "host" then
            -- Remote players on the host's level: aggro stand-ins and enemy shot targeting.
            -- Runs with no peers too, so stand-ins of players who left are removed.
            local remote = {}
            for id, p in pairs(S.peers) do
                if p.pos and (not lastLevelSent or p.level == lastLevelSent) then
                    table.insert(remote, { id = id, pos = p.pos })
                end
            end
            local ok, err = pcall(enemies.hostTick, dt, function(kind, reliable, ...)
                local bytes = codec.encode(T[kind], tr.selfId, ...)
                for _, id in ipairs(targets) do sendRaw(id, bytes, reliable) end
            end, {
                remote = remote,
                peers = #targets,
                sendTo = function(id, kind, reliable, ...) send(id, T[kind], reliable, ...) end,
            })
            if not ok then log("enemies host tick failed: " .. tostring(err)) end
        end
        if destruction and (S.mode == "host" or (S.mode == "client" and S.hostId)) then
            local ok, err = pcall(destruction.tick, dt, function(n, x, y, z, except)
                if S.mode == "host" then
                    for _, id in ipairs(targets) do
                        if id ~= except then send(id, T.DST_BREAK, true, n, x, y, z) end
                    end
                else
                    send(S.hostId, T.DST_BREAK, true, n, x, y, z)
                end
            end, lastLevelSent)
            if not ok then log("destruction tick failed: " .. tostring(err)) end
        end
        if interact and (S.mode == "host" or (S.mode == "client" and S.hostId)) then
            local ok, err = pcall(interact.tick, dt, function(cls, x, y, z, hold, except)
                if S.mode == "host" then
                    for _, id in ipairs(targets) do if id ~= except then send(id, T.INTERACT, true, cls, x, y, z, hold) end end
                else
                    send(S.hostId, T.INTERACT, true, cls, x, y, z, hold)
                end
            end)
            if not ok then log("interact tick failed: " .. tostring(err)) end
        end
        if storysync and (S.mode == "host" or (S.mode == "client" and S.hostId)) then
            local ok, err = pcall(storysync.tick, dt, function(cls, x, y, z, code, except)
                if S.mode == "host" then
                    for _, id in ipairs(targets) do if id ~= except then send(id, T.STORY, true, cls, x, y, z, code) end end
                else
                    send(S.hostId, T.STORY, true, cls, x, y, z, code)
                end
            end)
            if not ok then log("story tick failed: " .. tostring(err)) end
        end
        if regionsync and (S.mode == "host" or (S.mode == "client" and S.hostId)) then
            local ok, err = pcall(regionsync.tick, dt, function(cls, x, y, z, px, py, pz, except)
                if S.mode == "host" then
                    for _, id in ipairs(targets) do if id ~= except then send(id, T.REGION, true, cls, x, y, z, px, py, pz) end end
                else
                    send(S.hostId, T.REGION, true, cls, x, y, z, px, py, pz)
                end
            end)
            if not ok then log("region tick failed: " .. tostring(err)) end
        end
        if timestop and (S.mode == "host" or (S.mode == "client" and S.hostId)) then
            local ok, err = pcall(timestop.tick, function(d, except)
                if S.mode == "host" then
                    for _, id in ipairs(targets) do if id ~= except then send(id, T.TIMESTOP, true, d) end end
                else
                    send(S.hostId, T.TIMESTOP, true, d)
                end
            end, S.mode == "host")
            if not ok then log("timestop tick failed: " .. tostring(err)) end
        end
        if downed and S.mode ~= "loopback" then
            local mates = {}
            for id, p in pairs(S.peers) do
                if not lastLevelSent or p.level == lastLevelSent then
                    mates[id] = { name = p.name, pos = p.pos, downed = p.downed }
                end
            end
            local ok, err = pcall(downed.tick, dt, {
                teammates = mates,
                isHost = (S.mode == "host"),
                sendWipe = function() for _, id in ipairs(targets) do send(id, T.WIPE, true) end end,
                sendRevive = function(id)
                    if S.mode == "host" then send(id, T.REVIVE, true, id)
                    elseif S.hostId then send(S.hostId, T.REVIVE, true, id) end
                end,
            })
            if not ok then log("downed tick failed: " .. tostring(err)) end
        end
        if damagesync and (S.mode == "host" or (S.mode == "client" and S.hostId)) then
            local near = {}
            for id, p in pairs(S.peers) do
                if p.pos and (not lastLevelSent or p.level == lastLevelSent) then table.insert(near, { id = id, pos = p.pos }) end
            end
            local ok, err = pcall(damagesync.tick, {
                remote = near,
                sendTo = function(id, kind, ...) send(id, T[kind], true, ...) end,
                sendHost = function(kind, ...) if S.hostId then send(S.hostId, T[kind], true, ...) end end,
            })
            if not ok then log("damagesync tick failed: " .. tostring(err)) end
        end
        if enemies and S.mode == "client" and S.hostId then
            local ok, err = pcall(enemies.clientFlushHits, function(kind, reliable, ...)
                send(S.hostId, T[kind], reliable, ...)
            end)
            if not ok then log("enemies hit flush failed: " .. tostring(err)) end
        end

        timers.status = timers.status + dt
        if timers.status >= 1 then
            timers.status = 0
            local label = ({ host = "房主", client = "客户端", loopback = "本机回环" })[S.mode] or S.mode
            H("setStatus", string.format("VBMP %s · %d 人", label, #targets + 1))
        end

        timers.level = timers.level + dt
        if lastLevelSent and timers.level >= LEVEL_EVERY then
            timers.level = 0
            for _, id in ipairs(targets) do send(id, T.LEVEL, true, lastLevelSent) end
        end

        timers.ping = timers.ping + dt
        if timers.ping >= PING_EVERY and S.mode ~= "loopback" then
            timers.ping = 0
            for _, id in ipairs(targets) do send(id, T.PING, false, now) end
        end

        if S.mode ~= "loopback" then
            for id, p in pairs(S.peers) do
                if now - p.lastSeen > TIMEOUT then dropPeer(id, "timed out") end
            end
            if S.mode == "client" and S.state == "connected" and not S.peers[S.hostId] then
                fail("与房主断开")
            end
        end
    end

    function S.describe()
        local lines = {}
        local label = ({ host = "房主", client = "客户端", loopback = "本机回环" })[S.mode] or S.mode
        table.insert(lines, string.format("模式：%s　状态：%s", label, S.state))
        if S.error then table.insert(lines, "错误：" .. S.error) end
        table.insert(lines, string.format("我：%s（%s）", S.selfName, tostring(tr.selfId)))
        for id, p in pairs(S.peers) do
            table.insert(lines, string.format("  %s　延迟 %s　关卡 %s", tostring(p.name),
                p.rtt and string.format("%.0f ms", p.rtt) or "-", tostring(p.level or "?")))
        end
        if enemies and enemies.role then
            local es = enemies.stats
            table.insert(lines, string.format("敌人：%d　（生成 %d　移除 %d　删除本地 %d）",
                enemies.count(), es.spawned, es.removed, es.killedLocal) ..
                string.format("　命中 发%d 收%d　子弹 转%d 放%d", es.hitsSent or 0, es.hitsApplied or 0,
                    es.shotsSent or 0, es.shotsReplayed or 0) ..
                ((S.mode == "host") and string.format("　加强 血%d 额外%d", es.scaled or 0, es.extras or 0) or ""))
            if enemies.role == "host" and enemies.aggro then
                local n, toPeers = enemies.aggro.count()
                local as = enemies.aggro.stats
                table.insert(lines, string.format("仇恨：替身 %d　追队友 %d　切换 %d　子弹改向 %d", n, toPeers,
                    as.switches, as.redirected))
            end
        end
        if destruction and destruction.role then
            local ds = destruction.stats
            table.insert(lines, string.format("破坏：发 %d　收 %d　应用 %d　已破 %d　转发 %d　找不到 %d　等待 %d",
                ds.sent, ds.received, ds.applied, ds.already, ds.relayed, ds.missing, #destruction.inbox))
        end
        local st = tr.stats
        if st then table.insert(lines, string.format("包：发 %d　收 %d　失败 %d", st.sent, st.recv, st.sendFail)) end
        return lines
    end

    return S
end

return M

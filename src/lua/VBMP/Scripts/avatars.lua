-- Teammates as their own first-person arms and current gun, plus their shots as visible bullets
-- (messages PLAYER_GEAR 31, PLAYER_FIRE 32).
--
-- Research (self-test 2026-11-12, build 26439385; research/phase4-08-avatars.md):
--   * CH_LimaCharacter_C carries FirstPersonArms (SK_RashguardSleevesA) and SK_Gloves2B, both
--     bOnlyOwnerSee = true; the gun is a child actor (PrimaryGun -> BP_Weapon_*_C, Weapon_Mesh).
--   * A spawned, unpossessed CH_LimaCharacter_C with SetOnlyOwnerSee(false) on arms and gloves
--     shows them from outside; GiveWeapons(WeaponData, nil) (the weapon's UPDA_WeaponBase_C)
--     puts the gun in its hands and the arms take the gun's holding pose (screenshot).
--   * Making that avatar's weapon fire (FireProjectile) is not usable: the weapon logic works on
--     the local player (its ammo and camera). FireProjectileFake only spawns a motionless
--     BP_Projectile_Debug_C.
--   * A cosmetic bullet works: StaticMeshActor + NiagaraComponent with the player shot's trail
--     (NS_PRJ_StandardShot_v2, BP_Projectile_Master.ParticleSystemToUse) + a
--     ProjectileMovementComponent (gravity 0), collision off, SetLifeSpan: it flew straight and
--     was destroyed on time, the trail visible as the game's white shot.
--
-- Host: the teammate's aggro stand-in (aggro.lua, already a hidden CH_LimaCharacter_C) is shown
-- as the avatar, so enemies sense one pawn per teammate; this module moves it every frame
-- instead of aggro's 10 Hz jumps. Clients: a separate avatar per teammate (no AI there).
-- The old mannequin puppet stays for the name tag and streaming source, its mesh hidden.

local M = {}

local CHAR = "/Game/FirstPerson/Blueprints/CH_LimaCharacter.CH_LimaCharacter_C"
local TRAIL = "/Game/ProjectLima/FX/Projectiles/MainProjectiles/NS_PRJ_StandardShot_v2.NS_PRJ_StandardShot_v2"
local WEAPON_FN = "/Game/ProjectLima/Blueprints/Weapons/BP_Weapon_Base.BP_Weapon_Base_C:FireProjectile"
local BULLET_SPEED = 25000
local BULLET_RANGE = 20000
local MAX_SHOTS_QUEUED = 24
local IDENTITY = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 }, Scale3D = { X = 1, Y = 1, Z = 1 } }

local function valid(o) return type(o) == "userdata" and o:IsValid() end
local function findOrLoad(path)
    local o = StaticFindObject(path)
    if not valid(o) then pcall(LoadAsset, path); o = StaticFindObject(path) end
    return valid(o) and o or nil
end
local function dirOf(yaw, pitch)
    local y, p = math.rad(yaw), math.rad(pitch)
    return { X = math.cos(p) * math.cos(y), Y = math.cos(p) * math.sin(y), Z = math.sin(p) }
end

function M.new(log, opts)
    local V = { role = nil, peers = {}, shotsOut = {}, shotsIn = {}, myGear = nil,
                stats = { avatars = 0, shotsSent = 0, shotsShown = 0, gearSent = 0 } }
    local localPlayer, aggro = opts.localPlayer, opts.aggro
    local fireHooked = false

    local function peer(id)
        local v = V.peers[id]
        if not v then v = { id = id }; V.peers[id] = v end
        return v
    end

    -- arms + gloves (+ gun) visible from outside; the camera stops following a controller.
    local function showArms(a)
        for _, c in ipairs({ a.FirstPersonArms, a.SK_Gloves2B }) do
            pcall(function() c:SetOnlyOwnerSee(false) end)
            pcall(function() c:SetVisibility(true, false) end)
        end
        pcall(function() a.FirstPersonCamera.bUsePawnControlRotation = false end)
        pcall(function()
            local w = a.PrimaryGun.ChildActor
            if valid(w) then
                w.Weapon_Mesh:SetOnlyOwnerSee(false)
                w.Weapon_Mesh:SetVisibility(true, true)
            end
        end)
    end

    -- An avatar is a full CH_LimaCharacter_C: it makes its own HUD (PlayerIcons, ...) in our
    -- viewport, drawn over ours, and GiveWeapons writes its gun and ammo there (self-test
    -- 2026-11-12: a shotgun on the avatar showed "6" over our "45" and the shotgun icon).
    local HUD_FIELDS = { "PlayerIcons", "MissionHUD" }
    local function hideHud(v)
        local me = localPlayer()
        for _, f in ipairs(HUD_FIELDS) do
            pcall(function()
                local w = v.actor[f]
                if not valid(w) then return end
                local mine = valid(me) and me[f]
                if valid(mine) and mine:GetAddress() == w:GetAddress() then return end
                if w:GetVisibility() ~= 1 then
                    w:SetVisibility(1)
                    if not v.hudLogged then log("avatars: hid " .. tostring(v.id) .. "'s " .. f) end
                end
            end)
        end
        v.hudLogged = true
    end

    -- Arms and gun hang in front of the avatar's eyes: standing inside each other (both load at
    -- the same save spot) puts the teammate's gun over ours (self-test 2026-11-12), so an
    -- avatar closer than NEAR_HIDE to us is hidden.
    local NEAR_HIDE = 120
    -- checks the real state every tick: GiveWeapons makes a new, visible gun
    local function setShown(v, shown)
        v.shown = shown
        local a = v.actor
        for _, c in ipairs({ a.FirstPersonArms, a.SK_Gloves2B }) do
            pcall(function() if c:IsVisible() ~= shown then c:SetVisibility(shown, false) end end)
        end
        pcall(function()
            local m = a.PrimaryGun.ChildActor.Weapon_Mesh
            if m:IsVisible() ~= shown then m:SetVisibility(shown, true) end
        end)
    end
    local function nearMe(a)
        local me = localPlayer()
        if not valid(me) then return false end
        local ok, d = pcall(function()
            local x, y = a:K2_GetActorLocation(), me:K2_GetActorLocation()
            return math.sqrt((x.X - y.X) ^ 2 + (x.Y - y.Y) ^ 2 + (x.Z - y.Z) ^ 2)
        end)
        return ok and d < NEAR_HIDE
    end

    local function giveGear(v)
        if not valid(v.actor) or not v.gear or v.gearOn == v.gear then return end
        local data = findOrLoad(v.gear)
        if not data then v.gearOn = v.gear; log("avatars: weapon data not found " .. v.gear); return end
        local ok, err = pcall(function() v.actor:GiveWeapons(data, nil) end)
        v.gearOn = v.gear
        showArms(v.actor)
        v.shown = true
        log("avatars: " .. tostring(v.id) .. " holds " .. (v.gear:match("([^.]+)$") or v.gear) .. (ok and "" or (" FAILED " .. tostring(err))))
    end

    local function spawnAvatar(world, at)
        local cls = findOrLoad(CHAR)
        if not cls then return nil end
        local a = world:SpawnActor(cls, at, { Pitch = 0, Yaw = 0, Roll = 0 })
        if not valid(a) then return nil end
        pcall(function() a.bCanBeDamaged = false end)
        pcall(function() a.Debug_GodMode = true end)
        pcall(function() a:SetActorEnableCollision(false) end)
        pcall(function() a.CapsuleComponent:SetGenerateOverlapEvents(false) end)
        pcall(function() a:SetActorTickEnabled(false) end)
        pcall(function() a.CharacterMovement:SetMovementMode(0, 0) end)
        showArms(a)
        return a
    end

    function V.setRole(role) V.role = role; V.shotsOut, V.shotsIn = {}, {} end

    -------------------------------------------------------------------------------------------
    -- network side

    -- What we hold now (weapon data asset path) or nil.
    function V.currentGear()
        local me = localPlayer()
        if not valid(me) then return nil end
        local ok, path = pcall(function() return me.CurrentlyEquipedWeapon.WeaponData:GetFullName():match("%S+$") end)
        return ok and path or nil
    end

    function V.onGear(id, path) if type(path) == "string" and path ~= "" then peer(id).gear = path end end
    function V.onFire(id, x, y, z, yaw, pitch)
        if #V.shotsIn < MAX_SHOTS_QUEUED then table.insert(V.shotsIn, { id = id, x = x, y = y, z = z, yaw = yaw, pitch = pitch }) end
    end

    local function onLocalFire(weapon)
        V.stats.fireHooks = (V.stats.fireHooks or 0) + 1
        if not V.role or #V.shotsOut >= MAX_SHOTS_QUEUED then return end
        local w = weapon:get()
        local me = localPlayer()
        if not valid(w) or not valid(me) then return end
        -- the gun child actor has no Owner (self-test 2026-11-12): compare with what we hold
        local mine = me.CurrentlyEquipedWeapon
        if not valid(mine) or mine:GetAddress() ~= w:GetAddress() then return end
        local cam = me.Controller.PlayerCameraManager
        local l, r = cam:GetCameraLocation(), cam:GetCameraRotation()
        table.insert(V.shotsOut, { x = l.X, y = l.Y, z = l.Z, yaw = r.Yaw, pitch = r.Pitch })
    end

    local function spawnBullet(world, from, to)
        local trail = findOrLoad(TRAIL)
        local dx, dy, dz = to.X - from.X, to.Y - from.Y, to.Z - from.Z
        local len = math.sqrt(dx * dx + dy * dy + dz * dz)
        if len < 1 then return end
        local a = world:SpawnActor(StaticFindObject("/Script/Engine.StaticMeshActor"), from,
            { Pitch = math.deg(math.asin(dz / len)), Yaw = math.deg(math.atan(dy, dx)), Roll = 0 })
        if not valid(a) then return end
        a.StaticMeshComponent:SetMobility(2)
        a:SetActorEnableCollision(false)
        if trail then
            local nc = a:AddComponentByClass(StaticFindObject("/Script/Niagara.NiagaraComponent"), false, IDENTITY, false)
            nc:SetAsset(trail, true)
            -- The player shot's trail is culled by distance (made to be seen from the shooter's
            -- eyes): 15 m from the side it did not draw at all, at any scale. Without scalability
            -- culling it shows (self-test 2026-11-13, screenshots 72/73).
            pcall(function() nc:SetAllowScalability(false) end)
            pcall(function() nc:SetWorldScale3D({ X = 2, Y = 2, Z = 2 }) end)
            nc:Activate(true)
        end
        local pm = a:AddComponentByClass(StaticFindObject("/Script/Engine.ProjectileMovementComponent"), false, IDENTITY, false)
        pm.ProjectileGravityScale = 0
        pm:SetUpdatedComponent(a.StaticMeshComponent)
        pm.Velocity = { X = dx / len * BULLET_SPEED, Y = dy / len * BULLET_SPEED, Z = dz / len * BULLET_SPEED }
        a:SetLifeSpan(math.max(0.05, math.min(len, BULLET_RANGE) / BULLET_SPEED))
    end

    -- Network loop (not a hook callback: it spawns actors). sendGear(path), sendFire(x,y,z,yaw,pitch).
    -- ctx: { world, puppets }
    function V.tick(dt, ctx, sendGear, sendFire)
        if not fireHooked then
            fireHooked = pcall(RegisterHook, WEAPON_FN, function(self) pcall(onLocalFire, self) end)
            log("avatars: fire hook " .. tostring(fireHooked))
        end
        -- our gear
        V.gearTimer = (V.gearTimer or 0) + dt
        local g = V.currentGear()
        if g and (g ~= V.myGear or V.gearTimer > 10) then
            V.myGear, V.gearTimer = g, 0
            sendGear(g)
            V.stats.gearSent = V.stats.gearSent + 1
        end
        -- our shots
        local out = V.shotsOut
        V.shotsOut = {}
        for _, s in ipairs(out) do sendFire(s.x, s.y, s.z, s.yaw, s.pitch); V.stats.shotsSent = V.stats.shotsSent + 1 end

        -- avatars
        local world = ctx.world
        if not valid(world) then return end
        for id, p in pairs(ctx.puppets.peers) do
            local v = peer(id)
            if V.role == "host" then
                local s = aggro and aggro.stands[id]
                local a = s and s.actor
                if valid(a) and (not valid(v.actor) or v.actor:GetAddress() ~= a:GetAddress()) then
                    v.actor, v.gearOn, v.shown = a, nil, true
                    showArms(a)
                    V.stats.avatars = V.stats.avatars + 1
                    log("avatars: showing " .. tostring(id) .. "'s stand-in as their arms and gun")
                end
            elseif not valid(v.actor) and p.cur then
                v.actor = spawnAvatar(world, { X = p.cur.X, Y = p.cur.Y, Z = p.cur.Z })
                v.gearOn, v.shown, v.hudLogged = nil, true, nil
                if valid(v.actor) then V.stats.avatars = V.stats.avatars + 1; log("avatars: spawned for " .. tostring(id)) end
            end
            giveGear(v)
            if valid(v.actor) then
                hideHud(v)
                setShown(v, not nearMe(v.actor))
            end
            p.avatarUp = valid(v.actor)
        end
        -- their shots
        local inbox = V.shotsIn
        V.shotsIn = {}
        for _, s in ipairs(inbox) do
            local v = V.peers[s.id]
            local d = dirOf(s.yaw, s.pitch)
            local to = { X = s.x + d.X * BULLET_RANGE, Y = s.y + d.Y * BULLET_RANGE, Z = s.z + d.Z * BULLET_RANGE }
            local from = { X = s.x + d.X * 60, Y = s.y + d.Y * 60, Z = s.z + d.Z * 60 - 15 }
            pcall(function()
                local w = v and valid(v.actor) and v.actor.PrimaryGun.ChildActor
                if valid(w) then
                    local m = w:K2_GetActorLocation()
                    from = { X = m.X + d.X * 40, Y = m.Y + d.Y * 40, Z = m.Z + d.Z * 40 }
                end
            end)
            local ok, err = pcall(spawnBullet, world, from, to)
            if ok then V.stats.shotsShown = V.stats.shotsShown + 1
            elseif (V.badShots or 0) < 3 then V.badShots = (V.badShots or 0) + 1; log("avatars: bullet failed " .. tostring(err)) end
        end
    end

    -- Every frame (ReceiveTick hook): only moves existing avatars to the interpolated puppet pose.
    function V.frame(puppets)
        for id, v in pairs(V.peers) do
            local p = puppets.peers[id]
            if valid(v.actor) and p and p.cur then
                local c = p.cur
                pcall(function()
                    v.actor:K2_SetActorLocationAndRotation({ X = c.X, Y = c.Y, Z = c.Z }, { Pitch = 0, Yaw = c.Yaw, Roll = 0 }, false, {}, true)
                    v.actor.FirstPersonCamera:K2_SetRelativeRotation({ Pitch = c.Pitch or 0, Yaw = 0, Roll = 0 }, false, {}, true)
                end)
            end
        end
    end

    function V.remove(id)
        local v = V.peers[id]
        if v and V.role ~= "host" and valid(v.actor) then pcall(function() v.actor:K2_DestroyActor() end) end
        V.peers[id] = nil
    end

    function V.clear()
        for id in pairs(V.peers) do V.remove(id) end
        V.role, V.shotsOut, V.shotsIn, V.myGear = nil, {}, {}, nil
    end

    return V
end

return M

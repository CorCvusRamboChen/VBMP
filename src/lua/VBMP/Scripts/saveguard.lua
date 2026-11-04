-- Client save protection: while this game is a co-op client (and until it returns to the main
-- menu afterwards), the game saves to another slot, so the player's real save
-- (SaveGames\LimaSaveGame.sav) never receives a co-op run state.
--
-- Evidence (self-test 2026-11-05, build 23764881):
--   * GI_LimaGameInstance_C has `FString SlotName` (CXX dump, offset 0x290) = "LimaSaveGame".
--     Setting it to "VBMP_client" made SaveGameData(true) (the async save the game uses) write
--     VBMP_client.sav while LimaSaveGame.sav kept its timestamp.
--   * The async save does NOT pass through any hookable UFunction (hooks on
--     AsyncActionHandleSaveGame.AsyncSaveGameToSlot and GameplayStatics.SaveGameToSlot saw 0 calls
--     while the file was written), so the slot variable is the primary guard.
--   * The sync path GameplayStatics.SaveGameToSlot IS hookable, and changing its SlotName in the
--     pre-hook redirected the write (native-function parameter edits stick; Blueprint ones did
--     not). That and DeleteGameInSlot stay hooked as a second layer.
--   * Loads use the same slot variable: before switching we copy the real save to the client
--     slot, so the client keeps playing with its own progress.

local M = {}

local SAVES = (os.getenv("LOCALAPPDATA") or ".") .. "\\VOIDBREAKER\\Saved\\SaveGames\\"
local REAL_SLOT = "LimaSaveGame"
local CLIENT_SLOT = "VBMP_client"
-- { path, index of the SlotName parameter } (Engine.hpp in the dump)
local HOOKS = {
    { "/Script/Engine.GameplayStatics:SaveGameToSlot", 2 },
    { "/Script/Engine.GameplayStatics:DeleteGameInSlot", 1 },
}

local function valid(o) return type(o) == "userdata" and o:IsValid() end

-- Current level via the game instance (it outlives levels). FindFirstOf on menu classes is not
-- enough: a menu controller/widget from an earlier visit can still be found after the level
-- changed (dual test 2026-11-05).
function M.levelName()
    local gi = FindFirstOf("GI_LimaGameInstance_C")
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if not (gi and gi:IsValid() and gs and gs:IsValid()) then return nil end
    local ok, n = pcall(function() return gs:GetCurrentLevelName(gi, true):ToString() end)
    return ok and n or nil
end
function M.inMenu()
    local n = M.levelName()
    return n ~= nil and n:find("MainMenu", 1, true) ~= nil
end

local function copyFile(from, to)
    local src = io.open(from, "rb")
    if not src then return false end
    local data = src:read("a")
    src:close()
    local dst = io.open(to, "wb")
    if not dst then return false end
    dst:write(data)
    dst:close()
    return true
end

function M.new(log)
    local G = { active = false, untilMenu = false, redirected = 0, hooked = false }

    local function gi() return FindFirstOf("GI_LimaGameInstance_C") end

    local function slotOf(g)
        local ok, s = pcall(function() return g.SlotName:ToString() end)
        return ok and s or nil
    end

    local function setSlot(name)
        local g = gi()
        if not valid(g) then return false end
        if slotOf(g) ~= name then
            g.SlotName = name
            log("saveguard: GI.SlotName = " .. tostring(slotOf(g)))
        end
        return slotOf(g) == name
    end

    local function onCall(fn, slotParam)
        if not G.active then return end
        local ok, name = pcall(function() return slotParam:get():ToString() end)
        if not ok or name ~= REAL_SLOT then return end
        local okSet, err = pcall(function() slotParam:set(CLIENT_SLOT) end)
        G.redirected = G.redirected + 1
        if G.redirected <= 5 or not okSet then
            log("saveguard: " .. fn .. " " .. REAL_SLOT .. " -> " .. CLIENT_SLOT ..
                (okSet and "" or (" FAILED: " .. tostring(err))))
        end
    end

    function G.install()
        if G.hooked then return end
        local n = 0
        for _, h in ipairs(HOOKS) do
            local path, idx = h[1], h[2]
            local fn = path:match(":([%w_]+)$")
            local ok, err = pcall(RegisterHook, path, function(_, a1, a2)
                pcall(onCall, fn, idx == 1 and a1 or a2)
            end)
            if ok then n = n + 1 else log("saveguard: hook " .. fn .. " failed: " .. tostring(err)) end
        end
        G.hooked = true
        log("saveguard: " .. n .. "/" .. #HOOKS .. " hooks")
    end

    -- A client session starts: protect the real save.
    function G.clientStarted()
        G.install()
        if not G.active then
            local copied = copyFile(SAVES .. REAL_SLOT .. ".sav", SAVES .. CLIENT_SLOT .. ".sav")
            log("saveguard: ON - saving to " .. CLIENT_SLOT .. ".sav (copy of the real save: " .. tostring(copied) .. ")")
        end
        G.active, G.untilMenu = true, false
        local ok = setSlot(CLIENT_SLOT)
        if not ok then log("saveguard: WARNING could not set GI.SlotName yet, retrying") end
    end

    -- The client session ended: the in-memory run state is still the co-op one, so stay on until
    -- the main menu (Continue then reloads the untouched real save from disk).
    function G.clientStopped()
        if G.active then
            G.untilMenu = true
            log("saveguard: session over, still protecting until the main menu")
        end
    end

    -- Own loop: keep the slot switched; switch back at the main menu (M.inMenu).
    function G.tick()
        if not G.active then return end
        if G.untilMenu then
            if M.inMenu() then
                G.active, G.untilMenu = false, false
                setSlot(REAL_SLOT)
                log("saveguard: OFF (main menu); the real save is in use again")
                return
            end
        end
        setSlot(CLIENT_SLOT)
    end

    return G
end

return M

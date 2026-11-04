-- VBDev: remote Lua console for self-testing (development only, never packaged for players).
-- tools/dev.ps1 drops Lua code into Saved\VBDev_cmd.lua; it runs once on the game thread and
-- everything passed to out() plus the chunk's return values land in Saved\VBDev_out.txt.
-- Helpers available to the chunk: out, find, all, player, pc, world, console, screenshot, functions.
-- Never read every property of an object blindly (ForEachProperty + obj[name]): some property
-- types are not supported by this UE4SS build (log: FObjectPtrProperty) and reading them crashed
-- the game with an access violation (2026-11-04). Read only fields verified in the dumps.

local SAVED = (os.getenv("LOCALAPPDATA") or ".") .. "\\VOIDBREAKER\\Saved\\"
local CMD_FILE = SAVED .. "VBDev_cmd.lua"
local OUT_FILE = SAVED .. "VBDev_out.txt"

local function valid(o) return o ~= nil and o:IsValid() end

local function instance(className)
    for _, o in ipairs(FindAllOf(className) or {}) do
        if valid(o) and not o:GetFullName():find("Default__", 1, true) then return o end
    end
    return nil
end

local function fmt(v)
    local t = type(v)
    if t == "userdata" then
        local ok, s = pcall(function() return v:GetFullName() end)
        if ok then return s end
        local ok2, s2 = pcall(function() return v:ToString() end)
        if ok2 then return s2 end
        local ok3, s3 = pcall(function() return string.format("(%.1f, %.1f, %.1f)", v.X, v.Y, v.Z) end)
        if ok3 then return s3 end
    elseif t == "table" then
        local parts = {}
        for k, x in pairs(v) do table.insert(parts, tostring(k) .. "=" .. fmt(x)) end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(v)
end

local function run(code, outFile)
    local lines = {}
    local function out(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = fmt((select(i, ...))) end
        table.insert(lines, table.concat(parts, "  "))
    end
    local env = setmetatable({
        out = out,
        find = instance,
        all = function(c) return FindAllOf(c) or {} end,
        -- controller pawn first: VBMP aggro stand-ins are CH_LimaCharacter_C too
        player = function()
            local c = instance("PC_LimaPlayerController_C")
            local p = nil
            if c then pcall(function() p = c.Pawn end) end
            if type(p) == "userdata" and p:IsValid() then return p end
            return instance("CH_LimaCharacter_C")
        end,
        pc = function() return instance("PC_LimaPlayerController_C") or instance("PC_LimaMainMenuController_C") end,
        world = function()
            local p = instance("PC_LimaPlayerController_C") or instance("PC_LimaMainMenuController_C")
            return p and p:GetWorld() or nil
        end,
        console = function(cmd)
            local p = instance("PC_LimaPlayerController_C") or instance("PC_LimaMainMenuController_C")
            local k = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
            k:ExecuteConsoleCommand(p, cmd, p)
        end,
    }, { __index = _G })
    -- "shot showui" includes UMG (HighResShot captures the 3D scene only)
    env.screenshot = function() env.console("shot showui") end
    env.functions = function(obj, pattern)
        local names = {}
        local cls = obj:GetClass()
        while cls and cls:IsValid() do
            cls:ForEachFunction(function(fn)
                local n = fn:GetFName():ToString()
                if not pattern or n:lower():find(pattern:lower(), 1, true) then table.insert(names, n) end
            end)
            local ok, super = pcall(function() return cls:GetSuperStruct() end)
            if not ok or not super or not super:IsValid() or super:GetFName():ToString():find("^UserWidget") then break end
            cls = super
        end
        return names
    end

    local id = code:match("^%-%- id: (%S+)") or "?"
    local chunk, err = load(code, "VBDev", "t", env)
    if not chunk then
        table.insert(lines, "COMPILE ERROR: " .. tostring(err))
    else
        local res = { pcall(chunk) }
        if not res[1] then
            table.insert(lines, "RUNTIME ERROR: " .. tostring(res[2]))
        else
            for i = 2, #res do table.insert(lines, "return: " .. fmt(res[i])) end
        end
    end
    local f = io.open(outFile or OUT_FILE, "w")
    if f then
        f:write("-- id: ", id, "\n", table.concat(lines, "\n"), "\n-- end\n")
        f:close()
    end
end

-- Dual-instance testing: this process's slot ("A"/"B") as claimed by VBMP in VBMP_slots.txt
-- (key = GI_LimaGameInstance_C address, see src/lua/VBMP/Scripts/instance.lua).
local slot = nil
-- Game-thread loops only (LoopAsync raced with game-thread hooks in other states' mods and
-- corrupted values, 2026-11-04).
LoopInGameThreadWithDelay(2000, function()
    local gi = FindFirstOf("GI_LimaGameInstance_C")
    if type(gi) ~= "userdata" or not gi:IsValid() then return end
    local key = string.format("%X", gi:GetAddress())
    local f = io.open(SAVED .. "VBMP_slots.txt", "r")
    if not f then return end
    for line in f:lines() do
        local k, s = line:match("^(%w+)=(%u)@")
        if k == key then slot = s end
    end
    f:close()
end)

local function serve(cmdFile, outFile)
    local f = io.open(cmdFile, "r")
    if not f then return end
    local code = f:read("a")
    f:close()
    os.remove(cmdFile)
    local ok, err = pcall(run, code, outFile)
    if not ok then
        local o = io.open(outFile, "w")
        if o then o:write("-- id: ?\nVBDev failure: ", tostring(err), "\n-- end\n"); o:close() end
    end
end

LoopInGameThreadWithDelay(300, function()
    -- Legacy single-instance files belong to slot A (or to whoever runs before slots exist).
    if slot == nil or slot == "A" then serve(CMD_FILE, OUT_FILE) end
    if slot then serve(SAVED .. "VBDev_cmd_" .. slot .. ".lua", SAVED .. "VBDev_out_" .. slot .. ".txt") end
end)

print("[VBDev] remote console ready\n")

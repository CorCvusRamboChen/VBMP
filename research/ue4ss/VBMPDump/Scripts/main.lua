-- VBMPDump: one-shot reflection dumps for VOID/BREAKER research (Phase 0).
-- Stage 1 runs on its own shortly after launch (main menu); stage 2 is Ctrl+F9 once inside a
-- level, so the gameplay Blueprint classes are loaded too. Each stage writes a .done marker
-- next to the game exe so the collect script can tell what finished.

local function log(msg)
    print("[VBMPDump] " .. msg .. "\n")
end

local running = false

local function runDumps(stage)
    if running then
        log("a dump is already running, ignoring")
        return
    end
    running = true
    log("stage " .. stage .. " starting - the game may freeze for a few minutes, do not close it")
    local steps = {
        { "DumpUSMAP", function() DumpUSMAP() end },
        { "GenerateUHTCompatibleHeaders", function() GenerateUHTCompatibleHeaders() end },
        { "GenerateSDK", function() GenerateSDK() end },
        { "DumpAllObjects", function() DumpAllObjects() end },
    }
    for _, step in ipairs(steps) do
        local ok, err = pcall(step[2])
        log(step[1] .. (ok and " ok" or (" FAILED: " .. tostring(err))))
    end
    local f = io.open("VBMPDump_stage" .. stage .. ".done", "w")
    if f then
        f:write(os.date("!%Y-%m-%dT%H:%M:%SZ"))
        f:close()
    end
    log("stage " .. stage .. " DONE")
    running = false
end

log("loaded - stage 1 starts in 90 s; inside a level press Ctrl+F9 for stage 2")
ExecuteWithDelay(90000, function() runDumps(1) end)
RegisterKeyBindAsync(Key.F9, { ModifierKey.CONTROL }, function() runDumps(2) end)

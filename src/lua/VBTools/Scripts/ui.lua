-- VBTools in-game panel: injected into the inventory screen while it is open.
-- Built at runtime from plain UMG widgets (Border / VerticalBox / HorizontalBox / TextBlock /
-- Button) inside the inventory widget's own WidgetTree. Button clicks are detected by polling
-- IsPressed/IsHovered, which avoids binding dynamic delegates from Lua.
--
-- Game facts (build 23764881):
--   UWBP_PlayerInventoryMain_C : UVB_CommonActivatableWidget (CommonUI, IsActivated())
--     InventoryWidget : UWBP_PlayerBackpack_C, which has VoidiumText : UTextBlock (font source,
--     the game ships zh-Hans-CN so its fonts cover Chinese)

local M = {}

local POLL_MS = 50
local REFRESH_TICKS = 10          -- rebuild content check every ~0.5 s
local INVENTORY_CLASS = "WBP_PlayerInventoryMain_C"

local HALIGN_RIGHT = 3
local VALIGN_CENTER = 2
local VIS_VISIBLE = 0
local VIS_COLLAPSED = 1

local api
local enabled = true
local inv = nil
local panel = nil                 -- our Border
local body = nil                  -- VerticalBox inside it
local buttons = {}                -- { widget, onClick, wasPressed }
local signature = nil
local status = ""
local ticks = 0
local counter = 0
local classes = {}
local font = nil

local function cls(name)
    if not classes[name] then classes[name] = StaticFindObject("/Script/UMG." .. name) end
    return classes[name]
end

local function new(className)
    counter = counter + 1
    return StaticConstructObject(cls(className), inv.WidgetTree, FName("VBTools_" .. className .. "_" .. counter))
end

local function gameFont()
    if font == nil then
        local ok, f = pcall(function() return inv.InventoryWidget.VoidiumText.Font end)
        font = ok and f or false
    end
    return font or nil
end

-- The game's font is applied to our own TextBlock first and only that copy is resized, so
-- the game's widget is never touched.
local function text(str, size)
    local t = new("TextBlock")
    t:SetText(FText(str))
    local f = gameFont()
    if f then
        pcall(function()
            t:SetFont(f)
            local own = t.Font
            own.Size = size or 16
            t:SetFont(own)
        end)
    end
    return t
end

local function pad(slot, l, t, r, b)
    pcall(function() slot:SetPadding({ Left = l, Top = t, Right = r, Bottom = b }) end)
end

local function addRow(widgets)
    local row = new("HorizontalBox")
    for _, w in ipairs(widgets) do
        local s = row:AddChildToHorizontalBox(w)
        pad(s, 0, 0, 10, 0)
        pcall(function() s:SetVerticalAlignment(VALIGN_CENTER) end)
    end
    local s = body:AddChildToVerticalBox(row)
    pad(s, 0, 3, 0, 3)
    return row
end

local function addLine(str, size)
    local s = body:AddChildToVerticalBox(text(str, size))
    pad(s, 0, 4, 0, 2)
end

local function button(label, onClick)
    local b = new("Button")
    b:SetContent(text(label, 14))
    pcall(function() b:SetBackgroundColor({ R = 0.25, G = 0.55, B = 1.0, A = 1.0 }) end)
    table.insert(buttons, { widget = b, onClick = onClick, wasPressed = false })
    return b
end

local function isOpen(w)
    local ok, v = pcall(function() return w:IsActivated() end)
    return ok and v == true
end

-- The game keeps more than one inventory widget alive (a pre-created inactive one plus the one
-- actually pushed when the inventory opens), so prefer the activated instance.
local function findInventory()
    local fallback = nil
    for _, w in ipairs(FindAllOf(INVENTORY_CLASS) or {}) do
        if api.valid(w) and not w:GetFullName():find("Default__", 1, true) then
            if isOpen(w) then return w end
            fallback = fallback or w
        end
    end
    return fallback
end

local function attach()
    local root = inv.WidgetTree.RootWidget
    panel = new("Border")
    pcall(function() panel:SetBrushColor({ R = 0.02, G = 0.03, B = 0.06, A = 0.85 }) end)
    pcall(function() panel:SetPadding({ Left = 14, Top = 10, Right = 14, Bottom = 12 }) end)
    body = new("VerticalBox")
    panel:SetContent(body)

    local rootClass = root:GetClass():GetFName():ToString()
    if rootClass == "CanvasPanel" then
        -- Top centre, between the weapon grid (left) and the backpack grid (right); the first
        -- placement (right edge) covered the backpack, which becomes the shared inventory.
        local s = root:AddChildToCanvas(panel)
        s:SetAnchors({ Minimum = { X = 0.5, Y = 0 }, Maximum = { X = 0.5, Y = 0 } })
        s:SetAlignment({ X = 0.5, Y = 0 })
        s:SetPosition({ X = 0, Y = 150 })
        s:SetAutoSize(true)
        s:SetZOrder(1000)
    elseif rootClass == "Overlay" then
        local s = root:AddChildToOverlay(panel)
        s:SetHorizontalAlignment(HALIGN_RIGHT)
        s:SetVerticalAlignment(VALIGN_CENTER)
        pad(s, 0, 0, 40, 0)
    else
        root:AddChild(panel)
    end
    api.log("panel attached to inventory root (" .. rootClass .. ")")
end

-- VBMP (multiplayer) runs in its own Lua state; it publishes its status to a file and reads
-- commands from another (see src/lua/VBMP/Scripts/main.lua).
local SAVED = (os.getenv("LOCALAPPDATA") or ".") .. "\\VOIDBREAKER\\Saved\\"

local function mpStatus()
    local f = io.open(SAVED .. "VBMP_status.txt", "r")
    if not f then return nil end
    local lines = {}
    for line in f:lines() do if line ~= "" then table.insert(lines, line) end end
    f:close()
    return lines
end

local function mpCommand(cmd)
    local f = io.open(SAVED .. "VBMP_cmd.txt", "w")
    if f then f:write(cmd, "\n"); f:close() end
end

local function computeState()
    local char = api.player()
    local triples = char and api.findTriples(char) or {}
    local bosses = api.findBosses()
    local parts = {}
    -- Counters and ping change every second; rebuilding that often would eat button clicks
    -- (a click is a press and a release on the same widget), so they stay out of the signature.
    for _, l in ipairs(mpStatus() or {}) do
        if not l:find("^包：") then table.insert(parts, (l:gsub("%d+ ms", ""))) end
    end
    for _, t in ipairs(triples) do table.insert(parts, t.w .. t.key) end
    for _, b in ipairs(bosses) do table.insert(parts, api.bossSummary(b)) end
    table.insert(parts, status)
    return char, triples, bosses, table.concat(parts, "|")
end

local function rebuild(char, triples, bosses)
    body:ClearChildren()
    buttons = {}

    addLine("VBTools", 20)

    local mp = mpStatus()
    if mp then
        addLine("联机（VBMP）", 16)
        for _, l in ipairs(mp) do addLine("  " .. l, 14) end
        addRow({
            button("开房", function() mpCommand("host"); status = "已请求开房" end),
            button("加入好友", function() mpCommand("join"); status = "正在寻找开房的好友…" end),
            button("离开", function() mpCommand("leave"); status = "已离开联机" end),
            button("本机回环", function() mpCommand("loopback"); status = "回环测试：2 秒后你会看到自己" end),
        })
    end

    addLine("模组合成（3 个相同 → 1 个触发两次）", 16)
    if #triples == 0 then
        addLine("  同一把武器上没有 3 个相同的模组", 14)
    end
    for _, t in ipairs(triples) do
        local label = string.format("  武器%d  %s ×3", t.w, t.name)
        local bonus = api.fusionBonus(t.w, t.key)
        if bonus > 0 then label = label .. string.format("（已合成 +%d）", bonus) end
        -- Fusion is disabled until redesigned (see fuse() in main.lua); list only.
        addRow({ text(label .. "　（合成功能修复中）", 14) })
    end

    if #bosses > 0 then
        addLine("Boss 救援", 16)
        for _, b in ipairs(bosses) do addLine("  " .. api.bossSummary(b), 14) end
        addRow({
            button("解除卡死", function() api.bossAction("unstick"); status = "已尝试解除卡死" end),
            button("下一阶段", function() api.bossAction("stage"); status = "已推进阶段" end),
            button("击杀", function() api.bossAction("kill"); status = "已触发击杀" end),
            button("场地判胜", function() api.bossAction("arena"); status = "已让场地判胜" end),
        })
    end

    addLine("局外成长", 16)
    addRow({
        button("永久升级", function()
            status = api.openMenu("perma") and "已打开永久升级" or "打开失败，见日志"
        end),
        button("研究所", function()
            status = api.openMenu("research") and "已打开研究所" or "打开失败，见日志"
        end),
    })

    addLine("存档", 16)
    addRow({ button("存档快照", function()
        local name = api.saveSnapshot()
        status = name and ("已存为槽 " .. name) or "快照失败，见日志"
    end) })

    if status ~= "" then addLine(status, 14) end
end

local function pollButtons()
    for _, b in ipairs(buttons) do
        if api.valid(b.widget) then
            local pressed = b.widget:IsPressed()
            if b.wasPressed and not pressed and b.widget:IsHovered() then
                local ok, err = pcall(b.onClick)
                if not ok then
                    api.log("panel action FAILED: " .. tostring(err))
                    status = "操作失败，见日志"
                end
                signature = nil       -- force a rebuild with fresh state
            end
            b.wasPressed = pressed
        end
    end
end

local function hide()
    if api.valid(panel) then panel:SetVisibility(VIS_COLLAPSED) end
end

local function tick()
    ticks = ticks + 1
    if not enabled then hide(); return end

    if not api.valid(inv) or (not isOpen(inv) and ticks % 5 == 0) then
        local found = findInventory()
        if found ~= nil and (not api.valid(inv) or found:GetAddress() ~= inv:GetAddress()) then
            hide()
            inv = found
            panel = nil
            font = nil
        end
        if not api.valid(inv) then return end
    end
    if not isOpen(inv) then hide(); return end

    if not api.valid(panel) then
        attach()
        signature = nil
    end
    panel:SetVisibility(VIS_VISIBLE)

    pollButtons()

    if signature == nil or ticks % REFRESH_TICKS == 0 then
        local char, triples, bosses, sig = computeState()
        if sig ~= signature then
            rebuild(char, triples, bosses)
            signature = sig
        end
    end
end

function M.start(a)
    api = a
    -- Game-thread loop (LoopAsync raced with game-thread hooks in the same Lua state).
    LoopInGameThreadWithDelay(POLL_MS, function()
        local ok, err = pcall(tick)
        if not ok then
            api.log("panel error: " .. tostring(err) .. " - panel disabled, Ctrl+F8 to retry")
            enabled = false
            pcall(hide)
        end
    end)
end

function M.toggle()
    enabled = not enabled
    if enabled then
        panel = nil
        inv = nil
    end
    api.log("panel " .. (enabled and "ON" or "OFF"))
end

return M

-- Main-menu co-op panel: injected into the play menu (WBP_PlayMenu_C, the widget with the
-- Continue button that worldsync.lua presses) while the main menu level is up.
--   * [继续并开房]  presses Continue, then starts hosting once the level is loaded
--   * friends hosting VBMP (Steam helper "list" mode) with a [加入] button each, plus
--     [自动加入] (first friend found)
--   * the newest save backups with [恢复] (two clicks: the first asks to confirm)
--   * the last carry-back result (saveguard.lua)
-- Built like VBTools' inventory panel (src/lua/VBTools/Scripts/ui.lua): plain UMG widgets made
-- with StaticConstructObject inside the menu's own WidgetTree, clicks found by polling
-- IsPressed/IsHovered (no delegates from Lua).
-- WBP_PlayMenu_C is not in the CXX dump (taken in a level); its root is checked at runtime.

local M = {}

local POLL_MS = 50
local REFRESH_TICKS = 10
local MENU_CLASS = "WBP_PlayMenu_C"
local FONT_PATHS = {
    "/Game/ProjectLima/UI/Fonts/Revx/FNT_RevxNeue.FNT_RevxNeue",
    "/Game/ProjectLima/UI/Fonts/Teko/UI_Font_Teko.UI_Font_Teko",
}
local VALIGN_CENTER = 2
local VIS_VISIBLE, VIS_COLLAPSED = 0, 1

local api
local host, panel, body = nil, nil, nil
local buttons = {}
local signature = nil
local status = ""
local ticks, counter = 0, 0
local classes = {}
local fontObj = nil
local confirmFile = nil
local enabled = true

local function valid(o) return type(o) == "userdata" and o:IsValid() end

local function cls(name)
    if not classes[name] then classes[name] = StaticFindObject("/Script/UMG." .. name) end
    return classes[name]
end

local function new(className)
    counter = counter + 1
    return StaticConstructObject(cls(className), host.WidgetTree, FName("VBMP_Menu_" .. className .. "_" .. counter))
end

local function font()
    if fontObj == nil then
        fontObj = false
        for _, p in ipairs(FONT_PATHS) do
            local f = StaticFindObject(p)
            if not valid(f) then pcall(function() f = LoadAsset(p) end) end
            if valid(f) then fontObj = f; api.log("menu: font " .. p); break end
        end
    end
    return fontObj or nil
end

local function text(str, size)
    local t = new("TextBlock")
    t:SetText(FText(str))
    pcall(function()
        local own = t.Font
        local f = font()
        if f then own.FontObject = f end
        own.Size = size or 16
        t:SetFont(own)
    end)
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
    pad(body:AddChildToVerticalBox(row), 0, 3, 0, 3)
end

local function addLine(str, size)
    pad(body:AddChildToVerticalBox(text(str, size)), 0, 4, 0, 2)
end

local function button(label, onClick, color)
    local b = new("Button")
    b:SetContent(text(label, 15))
    pcall(function() b:SetBackgroundColor(color or { R = 0.25, G = 0.55, B = 1.0, A = 1.0 }) end)
    table.insert(buttons, { widget = b, onClick = onClick, wasPressed = false })
    return b
end

-- the play menu on screen (an older instance can still exist, as in worldsync.lua)
local function findMenu()
    local best = nil
    for _, w in ipairs(FindAllOf(MENU_CLASS) or {}) do
        if valid(w) and not w:GetFullName():find("Default__", 1, true) then
            local ok, shown = pcall(function() return w:IsInViewport() end)
            if ok and shown then return w end
            best = best or w
        end
    end
    return best
end

local function attach()
    local root = host.WidgetTree.RootWidget
    panel = new("Border")
    pcall(function() panel:SetBrushColor({ R = 0.02, G = 0.03, B = 0.06, A = 0.88 }) end)
    pcall(function() panel:SetPadding({ Left = 16, Top = 12, Right = 16, Bottom = 14 }) end)
    body = new("VerticalBox")
    panel:SetContent(body)
    local rootClass = root:GetClass():GetFName():ToString()
    if rootClass == "CanvasPanel" then
        local s = root:AddChildToCanvas(panel)
        -- screen centre: the left column holds the game's buttons, the right one its news boxes
        -- (screenshot 2026-11-05)
        s:SetAnchors({ Minimum = { X = 0.47, Y = 0.5 }, Maximum = { X = 0.47, Y = 0.5 } })
        s:SetAlignment({ X = 0.5, Y = 0.5 })
        s:SetPosition({ X = 0, Y = 0 })
        s:SetAutoSize(true)
        s:SetZOrder(1000)
    elseif rootClass == "Overlay" then
        local s = root:AddChildToOverlay(panel)
        s:SetHorizontalAlignment(3)
        s:SetVerticalAlignment(VALIGN_CENTER)
        pad(s, 0, 0, 60, 0)
    else
        root:AddChild(panel)
    end
    api.log("menu: panel attached to " .. MENU_CLASS .. " root (" .. rootClass .. ")")
end

local function computeSignature()
    local v, upd = api.version()
    local parts = { status, tostring(confirmFile), api.carryMessage() or "", tostring(v), tostring(upd and upd.state), tostring(upd and upd.detail) }
    for _, l in ipairs(api.sessionLines()) do table.insert(parts, (l:gsub("%d+", ""))) end
    local fr = api.friends()
    table.insert(parts, fr.state or "")
    for _, f in ipairs(fr.hosts or {}) do table.insert(parts, "h" .. f.id) end
    for _, f in ipairs(fr.playing or {}) do table.insert(parts, "p" .. f.id) end
    for _, b in ipairs(api.backups()) do table.insert(parts, b.file) end
    local eo, ep = api.exportResult()
    table.insert(parts, tostring(eo) .. tostring(ep))
    return table.concat(parts, "|")
end

local function rebuild()
    body:ClearChildren()
    buttons = {}
    local v, upd = api.version()
    addLine("VBMP 联机" .. (v and ("  v" .. v) or "  (开发版)"), 22)
    if upd and upd.state == "updated" then addLine("  " .. tostring(upd.detail), 15)
    elseif upd and upd.state == "error" then addLine("  " .. tostring(upd.detail), 13)
    elseif upd and (upd.state == "checking" or upd.state == "downloading") then addLine("  正在检查更新…", 13) end

    local lines = api.sessionLines()
    if #lines > 0 then
        for i = 1, math.min(#lines, 4) do addLine("  " .. lines[i], 14) end
        addRow({ button("离开联机", function() api.leave(); status = "已离开联机" end, { R = 0.8, G = 0.3, B = 0.3, A = 1 }) })
    else
        addRow({
            button("继续并开房", function() api.hostAfterContinue(); status = "正在进入你的世界，进去后自动开房…" end),
            button("自动加入好友", function() api.join(nil); status = "正在找开房的好友…" end),
        })
    end

    local fr = api.friends()
    addRow({ text("开房中的 Steam 好友", 16), button("刷新", function() api.refreshFriends(); status = "" end) })
    if fr.state == "loading" then
        addLine("  正在读取好友列表…", 14)
    elseif fr.state == "error" then
        addLine("  " .. (fr.error or "读取失败"), 14)
    elseif fr.state == "ok" then
        if #fr.hosts == 0 then addLine("  （没有好友在开房）", 14) end
        for _, f in ipairs(fr.hosts) do
            addRow({ text("  " .. f.name, 15), button("加入", function()
                api.join(f.id); status = "正在加入 " .. f.name .. "…"
            end) })
        end
        for i = 1, math.min(#fr.playing, 4) do
            addLine("  " .. fr.playing[i].name .. "  在玩，但没有开房", 13)
        end
    end

    local carry = api.carryMessage()
    if carry then addLine(carry, 14) end

    addLine("存档备份（联机前自动备份）", 16)
    local list = api.backups()
    if #list == 0 then addLine("  （还没有备份）", 14) end
    for i = 1, math.min(#list, 4) do
        local b = list[i]
        local asking = confirmFile == b.file
        addRow({ text("  " .. b.label, 14), button(asking and "确认恢复？" or "恢复", function()
            if confirmFile ~= b.file then confirmFile = b.file; return end
            confirmFile = nil
            local ok, err = api.restore(b.file)
            status = ok and ("已恢复：" .. b.label .. "（恢复前的存档也备份了）") or ("恢复失败：" .. tostring(err))
        end, asking and { R = 0.9, G = 0.5, B = 0.1, A = 1 } or nil) })
    end

    addRow({ text("联机出问题时", 15), button("打包日志", function()
        api.exportLogs()
        status = "正在打包日志…"
    end, { R = 0.35, G = 0.35, B = 0.4, A = 1 }) })
    local eo, ep = api.exportResult()
    if eo == true then
        addLine("  日志已打包到桌面：" .. (tostring(ep):match("[^\\]+$") or tostring(ep)) .. "，发给开发者即可", 13)
        if status == "正在打包日志…" then status = "" end
    elseif eo == false then
        addLine("  打包日志失败：" .. tostring(ep), 13)
        if status == "正在打包日志…" then status = "" end
    end

    if status ~= "" then addLine(status, 14) end
end

local function pollButtons()
    for _, b in ipairs(buttons) do
        if valid(b.widget) then
            local pressed = b.widget:IsPressed()
            if b.wasPressed and not pressed and b.widget:IsHovered() then
                local ok, err = pcall(b.onClick)
                if not ok then
                    api.log("menu action FAILED: " .. tostring(err))
                    status = "操作失败，见日志"
                end
                signature = nil
            end
            b.wasPressed = pressed
        end
    end
end

-- The play menu and our panel are destroyed with the menu level; a kept reference then reads as
-- a TrivialObject ("attempt to call a TrivialObject value (method 'SetVisibility')", logs
-- 2026-11-05 and 2026-11-11), so calls are guarded and references dropped outside the menu.
local function hide()
    if not pcall(function() if valid(panel) then panel:SetVisibility(VIS_COLLAPSED) end end) then
        panel = nil
    end
end

local function tick()
    ticks = ticks + 1
    if not enabled then return end
    if not api.inMenu() then
        if host or panel then hide(); host, panel, buttons = nil, nil, {} end
        return
    end
    if not valid(host) or ticks % 20 == 0 then
        local found = findMenu()
        if found and (not valid(host) or found:GetAddress() ~= host:GetAddress()) then
            hide()
            host, panel = found, nil
            api.refreshFriends()
        end
        if not valid(host) then return end
    end
    if not valid(panel) then
        attach()
        signature = nil
    end
    panel:SetVisibility(VIS_VISIBLE)
    pollButtons()
    if signature == nil or ticks % REFRESH_TICKS == 0 then
        local sig = computeSignature()
        if sig ~= signature then
            rebuild()
            signature = sig
        end
    end
end

function M.start(a)
    api = a
    LoopInGameThreadWithDelay(POLL_MS, function()
        local ok, err = pcall(tick)
        if not ok then
            api.log("menu panel error: " .. tostring(err) .. " - panel off")
            enabled = false
            pcall(hide)
        end
    end)
end

return M

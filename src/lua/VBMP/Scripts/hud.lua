-- VBMP HUD: multiplayer UI built at runtime from plain UMG widgets (same technique as the
-- VBTools inventory panel, src/lua/VBTools/Scripts/ui.lua). Pure presentation plus local
-- sampling: this module never sends or receives packets; main.lua/session.lua push state in
-- through the setters below and read the local cursor out. Design: docs/ui-design.md.
--
--   always-on HUD   teammate rows (name, HP, ping, status, revive bar), local downed/revive
--                   prompt, toasts, status line, screen-space teammate name tags
--   inventory       remote teammates' cursors and the shared-backpack slot they are dragging
--   enemies         applyEnemyHealth(): write host values into an enemy and refresh its bar
--
-- Our widgets live in one CanvasPanel "layer" per host widget, set HitTestInvisible so they
-- never take clicks or drag-drop away from the game.
--
-- Game/engine facts (build 23764881; CXX = CXXHeaderDump, UHT = UHTHeaderDump):
--   ACH_LimaCharacter_C.PlayerIcons : UWBP_PlayerIcons_C              CXX CH_LimaCharacter.hpp:247
--   UWBP_PlayerIcons_C  MainCanvas : UCanvasPanel, VoidCoins : UTextBlock (font source)
--     instance outer is GI_LimaGameInstance_C (UE4SS_ObjectDump), so it survives level changes
--   UWBP_PlayerInventoryMain_C  IsActivated(), InventoryWidget.VoidiumText (font),
--     WeaponSlotWidget : UWBP_WeaponSlot_C                             CXX WBP_PlayerInventoryMain.hpp
--   UWBP_WeaponSlot_C  InventorySlotArray / Weapon01SlotArray / Weapon02SlotArray :
--     TArray<UWBP_Button_InventorySlot_C*>                             CXX WBP_WeaponSlot.hpp:30-33
--   UWBP_Button_InventorySlot_C.SlotInformation : FSTR_StackInformation
--     .MasterDetails_20_02C613244058148ADEB15795ACD96292 -> UPDA_MasterDetails_C.ModName (FText)
--   ACH_AI_Base_C  Health, MaxHealth, ShieldHealth, ArmourHealth, StaggerHealth (double),
--     ShowingHealthBar? (bool), ShowHealthBar(), SetHealthBar(), SetShieldBar(), SetStaggerBar()
--                                                                      CXX CH_AI_Base.hpp
--   UWidgetLayoutLibrary  GetMousePositionOnViewport(Ctx) -> FVector2D, GetViewportSize(Ctx)
--     -> FVector2D, GetViewportScale(Ctx) -> float, ProjectWorldLocationToWidgetPosition(PC,
--     WorldLocation, ScreenPosition&, bPlayerViewportRelative) -> bool  UHT UMG/Public/WidgetLayoutLibrary.h
--   UWidgetBlueprintLibrary  IsDragDropping() -> bool, GetDragDroppingContent() -> UDragDropOperation*
--                                                                      UHT UMG/Public/WidgetBlueprintLibrary.h
--   UDragDropOperation.Payload : UObject*                              UHT UMG/Public/DragDropOperation.h
--   USlateBlueprintLibrary  LocalToAbsolute(Geometry, Local), GetAbsoluteSize(Geometry),
--     AbsoluteToLocal(Geometry, Absolute)                              UHT UMG/Public/SlateBlueprintLibrary.h
--   UWidget.GetCachedGeometry() -> FGeometry                           UHT UMG/Public/Widget.h:295
--   UMG setters (CXX UMG.hpp): CanvasPanel.AddChildToCanvas, CanvasPanelSlot.SetAnchors/
--     SetAlignment/SetPosition/SetSize/SetAutoSize/SetZOrder, VerticalBox.AddChildToVerticalBox,
--     HorizontalBox.AddChildToHorizontalBox, *Slot.SetPadding/SetHorizontalAlignment/
--     SetVerticalAlignment, ContentWidget.SetContent, PanelWidget.ClearChildren,
--     Border.SetBrushColor/SetPadding, SizeBox.SetWidthOverride/SetHeightOverride,
--     ProgressBar.SetPercent/SetFillColorAndOpacity, TextBlock.SetText/SetFont/
--     SetColorAndOpacity(FSlateColor), Widget.SetVisibility/SetRenderOpacity/RemoveFromParent
--   ESlateVisibility Visible 0, Collapsed 1, HitTestInvisible 3        CXX UMG_enums.hpp:48
--   ESlateColorStylingMode UseColor_Specified 0                        CXX SlateCore_enums.hpp:216
-- Unverified in game (docs/ui-design.md section 6): drag Payload class, FGeometry round trip,
-- side effects of the enemy bar refresh events.

local M = {}

local POLL_MS = 50
local DT = POLL_MS / 1000
local HUD_CLASS = "WBP_PlayerIcons_C"
local INVENTORY_CLASS = "WBP_PlayerInventoryMain_C"
local SLOT_CLASS = "WBP_Button_InventorySlot_C"
local F_DETAILS = "MasterDetails_20_02C613244058148ADEB15795ACD96292"
local SLOT_ARRAYS = { [0] = "InventorySlotArray", [1] = "Weapon01SlotArray", [2] = "Weapon02SlotArray" }
local KIND_BACKPACK = 0

local VIS_VISIBLE = 0
local VIS_COLLAPSED = 1
local VIS_HIT_TEST_INVISIBLE = 3
local HALIGN_CENTER = 2
local VALIGN_CENTER = 2
local LAYER_Z = 900

local BAR_WIDTH = 220
local TAG_HEAD_OFFSET = 100       -- cm above the reported (actor) location
local TAG_EDGE = 48               -- off-screen tags stick this far inside the screen edge
local TOAST_MAX = 5
local TOAST_SECONDS = 5
local CURSOR_LERP = 0.5

local function rgba(r, g, b, a) return { R = r, G = g, B = b, A = a or 1 } end
M.COLOR = {
    white = rgba(0.92, 0.94, 0.97),
    grey = rgba(0.5, 0.52, 0.56),
    green = rgba(0.35, 0.9, 0.45),
    yellow = rgba(1.0, 0.8, 0.25),
    red = rgba(1.0, 0.28, 0.25),
    blue = rgba(0.35, 0.65, 1.0),
}
local C = M.COLOR
local PALETTE = { rgba(0.3, 0.85, 1.0), rgba(1.0, 0.6, 0.2), rgba(0.55, 1.0, 0.4), rgba(1.0, 0.45, 0.9) }
local BG = rgba(0.02, 0.03, 0.06, 0.7)

local api
local enabled = true
local ticks = 0
local framedAt = -100              -- tick of the last M.frame() call
local counter = 0
local classes = {}
local libs = {}
local warned = {}

-- state pushed in by main/session ---------------------------------------------------------
local mates = {}                   -- id -> fields (see M.setTeammate) + color, order
local nextOrder = 0
local cursors = {}                 -- id -> { x, y, tx, ty, visible, drag }
local worldPos = {}                -- id -> { x, y, z }
local localDown = nil              -- { reviver, progress, out }
local reviveAction = nil           -- { name, progress }
local reviveHint = nil             -- teammate name
local toasts = {}                  -- { text, color, born, life }
local toastSerial = 0
local statusText = nil

-- widgets ---------------------------------------------------------------------------------
local H = {}                       -- always-on HUD (host = WBP_PlayerIcons_C)
local I = {}                       -- inventory (host = WBP_PlayerInventoryMain_C)
local dragCache = { addr = nil, info = nil }

local function valid(o) return o ~= nil and o:IsValid() end
local function log(msg) if api then api.log("hud: " .. msg) end end
local function warnOnce(key, msg)
    if not warned[key] then warned[key] = true; log(msg) end
end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function now() return ticks * DT end

local function cls(name)
    if not valid(classes[name]) then classes[name] = StaticFindObject("/Script/UMG." .. name) end
    return classes[name]
end

local function lib(name)
    if not valid(libs[name]) then libs[name] = StaticFindObject("/Script/UMG.Default__" .. name) end
    return libs[name]
end

local function len(arr)
    local ok, n = pcall(function() return arr:GetArrayNum() end)
    if ok then return n end
    return #arr
end

local function same(a, b)
    return valid(a) and valid(b) and a:GetAddress() == b:GetAddress()
end

local function className(o)
    local ok, n = pcall(function() return o:GetClass():GetFName():ToString() end)
    return ok and n or "?"
end

local function liveInstance(className_)
    for _, w in ipairs(FindAllOf(className_) or {}) do
        if valid(w) and not w:GetFullName():find("Default__", 1, true) then return w end
    end
    return nil
end

local function playerController()
    if not valid(H.pc) then H.pc = FindFirstOf("PC_LimaPlayerController_C") end
    return valid(H.pc) and H.pc or nil
end

local function localPlayer()
    if not valid(H.player) then H.player = require("aggro").localPlayer() end   -- stand-ins share the class
    return valid(H.player) and H.player or nil
end

---------------------------------------------------------------------------------------------
-- widget helpers (ctx = H or I: { host, font })

local function new(ctx, className_)
    counter = counter + 1
    return StaticConstructObject(cls(className_), ctx.host.WidgetTree, FName("VBMP_" .. className_ .. "_" .. counter))
end

local function setColor(tb, color)
    pcall(function() tb:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 }) end)
end

-- Cached text: { w, s, color }; SetText/SetColorAndOpacity only run when the value changes.
local function text(ctx, str, size, color)
    local t = new(ctx, "TextBlock")
    t:SetText(FText(str))
    if ctx.font then
        pcall(function()
            t:SetFont(ctx.font)
            local own = t.Font
            own.Size = size or 16
            t:SetFont(own)
        end)
    end
    local obj = { w = t, s = str, color = nil }
    if color then setColor(t, color); obj.color = color end
    return obj
end

local function setText(obj, str, color)
    if str ~= obj.s then obj.w:SetText(FText(str)); obj.s = str end
    if color and color ~= obj.color then setColor(obj.w, color); obj.color = color end
end

local function bar(ctx, width, height, color)
    local box = new(ctx, "SizeBox")
    box:SetWidthOverride(width)
    box:SetHeightOverride(height)
    local b = new(ctx, "ProgressBar")
    box:SetContent(b)
    b:SetPercent(0)
    b:SetFillColorAndOpacity(color)
    return { box = box, w = b, pct = 0, color = color }
end

local function setBar(obj, pct, color)
    pct = clamp(pct or 0, 0, 1)
    if math.abs(pct - obj.pct) > 0.002 then obj.w:SetPercent(pct); obj.pct = pct end
    if color and color ~= obj.color then obj.w:SetFillColorAndOpacity(color); obj.color = color end
end

-- Visibility with a cache (widget -> last value) so hidden rows cost nothing per tick.
local visCache = setmetatable({}, { __mode = "k" })
local function show(w, on)
    local v = on and VIS_VISIBLE or VIS_COLLAPSED
    if visCache[w] ~= v then w:SetVisibility(v); visCache[w] = v end
end

local function setLayerVis(layer, v)
    if valid(layer) and visCache[layer] ~= v then layer:SetVisibility(v); visCache[layer] = v end
end

local function border(ctx, color, l, t, r, b)
    local bd = new(ctx, "Border")
    pcall(function() bd:SetBrushColor(color) end)
    pcall(function() bd:SetPadding({ Left = l or 10, Top = t or 6, Right = r or 10, Bottom = b or 6 }) end)
    return bd
end

local function pad(slot, l, t, r, b)
    pcall(function() slot:SetPadding({ Left = l, Top = t, Right = r, Bottom = b }) end)
end

local function vadd(box, w, l, t, r, b, center)
    local s = box:AddChildToVerticalBox(w)
    pad(s, l or 0, t or 0, r or 0, b or 0)
    if center then pcall(function() s:SetHorizontalAlignment(HALIGN_CENTER) end) end
    return s
end

local function hadd(box, w, l, t, r, b)
    local s = box:AddChildToHorizontalBox(w)
    pad(s, l or 0, t or 0, r or 0, b or 0)
    pcall(function() s:SetVerticalAlignment(VALIGN_CENTER) end)
    return s
end

-- Canvas child with a single-point anchor; returns the CanvasPanelSlot.
local function place(canvas, w, ax, ay, alx, aly, px, py, z)
    local s = canvas:AddChildToCanvas(w)
    s:SetAnchors({ Minimum = { X = ax, Y = ay }, Maximum = { X = ax, Y = ay } })
    s:SetAlignment({ X = alx, Y = aly })
    s:SetPosition({ X = px or 0, Y = py or 0 })
    s:SetAutoSize(true)
    if z then s:SetZOrder(z) end
    return s
end

-- The host's full-screen CanvasPanel: WidgetTree.RootWidget if it is one, else MainCanvas
-- (WBP_PlayerIcons_C only).
local function hostCanvas(host)
    local root = host.WidgetTree.RootWidget
    if valid(root) and className(root) == "CanvasPanel" then return root, "RootWidget" end
    local ok, mc = pcall(function() return host.MainCanvas end)
    if ok and valid(mc) then return mc, "MainCanvas" end
    return nil, className(root)
end

-- Our own CanvasPanel stretched over the host canvas, HitTestInvisible (children inherit it).
local function makeLayer(ctx)
    local canvas, how = hostCanvas(ctx.host)
    if not canvas then
        warnOnce("nocanvas" .. className(ctx.host), "no CanvasPanel to attach to in " .. className(ctx.host) .. " (root is " .. tostring(how) .. ")")
        return nil
    end
    local layer = new(ctx, "CanvasPanel")
    local s = canvas:AddChildToCanvas(layer)
    s:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 1, Y = 1 } })
    s:SetAlignment({ X = 0, Y = 0 })
    s:SetPosition({ X = 0, Y = 0 })      -- stretched anchors: Position/Size are the margins
    s:SetSize({ X = 0, Y = 0 })
    s:SetZOrder(LAYER_Z)
    layer:SetVisibility(VIS_HIT_TEST_INVISIBLE)
    log("layer attached to " .. className(ctx.host) .. "." .. how)
    return layer
end

local function fontFrom(fn)
    local ok, f = pcall(fn)
    if ok and f then return f end
    return nil
end

---------------------------------------------------------------------------------------------
-- teammate rows

local function sortedMates()
    local ids = {}
    for id in pairs(mates) do table.insert(ids, id) end
    table.sort(ids, function(a, b) return mates[a].order < mates[b].order end)
    return ids
end

local function rebuildTeam()
    H.team:ClearChildren()
    H.rows = {}
    local ids = sortedMates()
    for _, id in ipairs(ids) do
        local m = mates[id]
        local row = {}
        local v = new(H, "VerticalBox")
        local top = new(H, "HorizontalBox")
        row.name = text(H, m.name or "?", 16, m.color)
        row.hp = text(H, "", 13, C.white)
        row.ping = text(H, "-", 13, C.grey)
        hadd(top, row.name.w, 0, 0, 10, 0)
        hadd(top, row.hp.w, 0, 0, 10, 0)
        hadd(top, row.ping.w)
        vadd(v, top)
        row.bar = bar(H, BAR_WIDTH, 8, C.green)
        vadd(v, row.bar.box, 0, 2, 0, 0)
        row.status = text(H, "", 13, C.yellow)
        vadd(v, row.status.w, 0, 2, 0, 0)
        row.revive = bar(H, BAR_WIDTH, 5, C.blue)
        vadd(v, row.revive.box, 0, 2, 0, 0)
        vadd(H.team, v, 0, 4, 0, 6)
        H.rows[id] = row
    end
    show(H.teamBorder, #ids > 0)
end

local function pingColor(ms)
    if not ms then return C.grey end
    if ms > 300 then return C.red end
    if ms > 150 then return C.yellow end
    return C.white
end

local function statusOf(m)
    if m.connected == false then return "掉线", C.grey end
    if m.out then return "出局", C.grey end
    if m.downed then
        if m.reviveProgress then
            return string.format("倒地 · %s 正在复活 %d%%", m.reviver or "队友", math.floor(m.reviveProgress * 100 + 0.5)), C.blue
        end
        return "倒地 · 等待复活", C.red
    end
    if m.otherLevel then return "在其他区域", C.grey end
    if m.inInventory then return "背包中", C.grey end
    return "", C.yellow
end

local function updateTeam()
    for id, row in pairs(H.rows) do
        local m = mates[id]
        if m then
            local gone = m.connected == false or m.out
            setText(row.name, m.name or "?", gone and C.grey or m.color)
            local hp, maxHp = m.hp, m.maxHp
            if hp and maxHp and maxHp > 0 then
                setText(row.hp, string.format("%d/%d", math.floor(hp + 0.5), math.floor(maxHp + 0.5)))
                local pct = hp / maxHp
                local color = gone and C.grey or m.downed and C.red or (pct < 0.3 and C.yellow or C.green)
                setBar(row.bar, m.downed and 1 or pct, color)
            else
                setText(row.hp, "")
                setBar(row.bar, 0, C.grey)
            end
            setText(row.ping, m.ping and string.format("%d ms", math.floor(m.ping + 0.5)) or "-", pingColor(m.ping))
            local st, stColor = statusOf(m)
            setText(row.status, st, stColor)
            show(row.status.w, st ~= "")
            local reviving = m.downed and m.reviveProgress ~= nil and not gone
            show(row.revive.box, reviving)
            if reviving then setBar(row.revive, m.reviveProgress) end
        end
    end
end

-- Plain string building: `return table.concat(parts, ",")` here failed in the game with
-- "bad argument #3 to 'concat' (number expected, got function)" (self-test 2026-11-04,
-- not reproducible in another mod's Lua state); avoid the library call and the tail call.
local function teamSignature()
    local sig = ""
    for _, id in ipairs(sortedMates()) do sig = sig .. tostring(id) .. "," end
    return sig
end

---------------------------------------------------------------------------------------------
-- center prompt (local downed / reviving / hint), toasts, status line

local function updateCenter()
    local big, sub, prog, color = nil, nil, nil, C.white
    if localDown then
        if localDown.out then
            big, sub, color = "你已出局", "等待队友完成这一局", C.grey
        else
            big, color = "你倒地了", C.red
            if localDown.reviver then
                sub = localDown.reviver .. " 正在复活你"
                prog = localDown.progress or 0
            else
                sub = "等待队友复活"
            end
        end
    elseif reviveAction then
        big, prog, color = "正在复活 " .. reviveAction.name, reviveAction.progress or 0, C.blue
    elseif reviveHint then
        sub = "按住 [交互] 复活 " .. reviveHint
    end
    show(H.center, big ~= nil or sub ~= nil)
    if big then setText(H.big, big, color) end
    show(H.big.w, big ~= nil)
    if sub then setText(H.sub, sub) end
    show(H.sub.w, sub ~= nil)
    show(H.centerBar.box, prog ~= nil)
    if prog then setBar(H.centerBar, prog) end
end

local function rebuildToasts()
    H.toastBox:ClearChildren()
    H.toastWidgets = {}
    for i, t in ipairs(toasts) do
        local bd = border(H, BG, 10, 4, 10, 4)
        local tb = text(H, t.text, 15, t.color or C.white)
        bd:SetContent(tb.w)
        vadd(H.toastBox, bd, 0, 0, 0, 4)
        H.toastWidgets[i] = bd
    end
end

local function updateToasts()
    local t = now()
    local changed = false
    for i = #toasts, 1, -1 do
        if t - toasts[i].born > toasts[i].life then table.remove(toasts, i); changed = true end
    end
    local sig = #toasts > 0 and (toasts[1].serial .. ":" .. #toasts) or ""
    if changed or sig ~= H.toastSig then rebuildToasts(); H.toastSig = sig end
    for i, w in ipairs(H.toastWidgets or {}) do
        local left = toasts[i].life - (t - toasts[i].born)
        local a = left < 1 and clamp(left, 0, 1) or 1
        if a < 1 then pcall(function() w:SetRenderOpacity(a) end) end
    end
end

local function updateStatus()
    show(H.status.w, statusText ~= nil)
    if statusText then setText(H.status, statusText) end
end

---------------------------------------------------------------------------------------------
-- screen-space name tags

local function screenSize()
    local pc = playerController()
    if not pc then return nil end
    if not H.screen or ticks - (H.screenAt or -100) > 20 then
        local w = lib("WidgetLayoutLibrary")
        local ok, vp, sc = pcall(function() return w:GetViewportSize(pc), w:GetViewportScale(pc) end)
        if ok and vp and sc and sc > 0 and vp.X > 0 then
            H.screen = { w = vp.X / sc, h = vp.Y / sc }
            H.screenAt = ticks
        end
    end
    return H.screen
end

local function ensureTag(id)
    local tag = H.tags[id]
    if tag then return tag end
    local bd = border(H, BG, 6, 2, 6, 2)
    local tb = text(H, "", 14, C.white)
    bd:SetContent(tb.w)
    tag = { border = bd, text = tb, slot = place(H.layer, bd, 0, 0, 0.5, 1, 0, 0, 10) }
    H.tags[id] = tag
    return tag
end

local function updateTags()
    if not valid(H.layer) then return end
    local pc = playerController()
    local scr = screenSize()
    local me = localPlayer()
    local wll = lib("WidgetLayoutLibrary")
    for id, tag in pairs(H.tags) do
        if not mates[id] then tag.border:RemoveFromParent(); H.tags[id] = nil end
    end
    if not pc or not scr or not valid(wll) then return end
    local myLoc = nil
    if me then pcall(function() myLoc = me:K2_GetActorLocation() end) end
    for id, m in pairs(mates) do
        local p = worldPos[id]
        local usable = p and m.connected ~= false and not m.otherLevel and not m.out
        local x, y, onScreen = 0, 0, false
        if usable then
            local out = {}
            local ok, res = pcall(function()
                return wll:ProjectWorldLocationToWidgetPosition(pc, { X = p.x, Y = p.y, Z = p.z + TAG_HEAD_OFFSET }, out, false)
            end)
            -- UE4SS fills an out struct into the table itself; accept t[paramName] as well.
            local sp = (out.X and out) or out.ScreenPosition
            if ok and sp and sp.X then
                x, y, onScreen = sp.X, sp.Y, res == true
            else
                usable = false
                if not ok then warnOnce("project", "ProjectWorldLocationToWidgetPosition failed: " .. tostring(res)) end
            end
        end
        local inside = onScreen and x >= 0 and y >= 0 and x <= scr.w and y <= scr.h
        local visible = usable and (inside or m.downed)
        local tag = (visible or H.tags[id]) and ensureTag(id)
        if tag then
            show(tag.border, visible)
            if visible then
                if not inside then
                    if not onScreen then x, y = scr.w - x, scr.h end    -- behind the camera: mirror
                    x = clamp(x, TAG_EDGE, scr.w - TAG_EDGE)
                    y = clamp(y, TAG_EDGE, scr.h - TAG_EDGE)
                end
                local label = m.name or "?"
                local color = m.color
                if m.downed then
                    local dist = ""
                    if myLoc then
                        local dx, dy, dz = p.x - myLoc.X, p.y - myLoc.Y, p.z - myLoc.Z
                        dist = string.format(" %dm", math.floor(math.sqrt(dx * dx + dy * dy + dz * dz) / 100 + 0.5))
                    end
                    label, color = "倒地！" .. label .. dist, C.red
                end
                setText(tag.text, label, color)
                tag.slot:SetPosition({ X = x, Y = y })
            end
        end
    end
end

---------------------------------------------------------------------------------------------
-- always-on HUD host

local function findHud()
    local me = localPlayer()
    if me then
        local ok, w = pcall(function() return me.PlayerIcons end)
        if ok and valid(w) then return w end
    end
    return liveInstance(HUD_CLASS)
end

local function attachHud()
    H.font = fontFrom(function() return H.host.VoidCoins.Font end)
    H.layer = makeLayer(H)
    if not H.layer then return false end
    H.tags = {}

    H.teamBorder = border(H, BG, 10, 6, 10, 6)
    H.team = new(H, "VerticalBox")
    H.teamBorder:SetContent(H.team)
    place(H.layer, H.teamBorder, 0, 0.36, 0, 0, 24, 0, 20)
    H.rows = {}
    H.sig = nil

    H.center = new(H, "VerticalBox")
    H.big = text(H, "", 30, C.red)
    H.sub = text(H, "", 18, C.white)
    H.centerBar = bar(H, 320, 10, C.blue)
    vadd(H.center, H.big.w, 0, 0, 0, 4, true)
    vadd(H.center, H.sub.w, 0, 0, 0, 6, true)
    vadd(H.center, H.centerBar.box, 0, 0, 0, 0, true)
    place(H.layer, H.center, 0.5, 0.66, 0.5, 0.5, 0, 0, 30)

    H.toastBox = new(H, "VerticalBox")
    place(H.layer, H.toastBox, 0, 0.2, 0, 0, 24, 0, 25)
    H.toastWidgets = {}
    H.toastSig = nil

    H.status = text(H, "", 13, C.grey)
    place(H.layer, H.status.w, 1, 0, 1, 0, -16, 8, 25)
    return true
end

local function tickHud()
    -- PlayerIcons can be replaced when the character respawns; re-check every 2 s.
    if valid(H.host) and ticks % 40 == 0 then
        local cur = findHud()
        if cur and not same(cur, H.host) then
            if valid(H.layer) then pcall(function() H.layer:RemoveFromParent() end) end
            H.host = nil
        end
    end
    if not valid(H.host) then
        if ticks % 10 ~= 0 then return end
        H.player, H.pc = nil, nil
        H.host = findHud()
        H.layer = nil
        if not H.host then return end
    end
    if not valid(H.layer) then
        if not attachHud() then H.host = nil; return end
    end

    local sig = teamSignature()
    if sig ~= H.sig then rebuildTeam(); H.sig = sig end
    updateTeam()
    updateCenter()
    updateToasts()
    updateStatus()
    if ticks - framedAt > 2 then updateTags() end     -- main.lua is not calling M.frame()
end

---------------------------------------------------------------------------------------------
-- inventory: remote cursors and drag highlight

local function isOpen(w)
    local ok, v = pcall(function() return w:IsActivated() end)
    return ok and v == true
end

-- The game keeps a pre-created, never-activated inventory widget next to the one it pushes
-- when the inventory opens (self-test 2026-11-04), so prefer the activated instance.
local function activeInventory()
    local fallback = nil
    for _, w in ipairs(FindAllOf(INVENTORY_CLASS) or {}) do
        if valid(w) and not w:GetFullName():find("Default__", 1, true) then
            if isOpen(w) then return w end
            fallback = fallback or w
        end
    end
    return fallback
end

local function attachInventory()
    I.font = fontFrom(function() return I.host.InventoryWidget.VoidiumText.Font end)
    I.layer = makeLayer(I)
    I.cursors = {}
    return I.layer ~= nil
end

local function ensureCursor(id)
    local w = I.cursors[id]
    if w then return w end
    local m = mates[id]
    local color = m and m.color or C.white
    local h = new(I, "HorizontalBox")
    local dotBox = new(I, "SizeBox")
    dotBox:SetWidthOverride(12)
    dotBox:SetHeightOverride(12)
    local dot = new(I, "Border")
    pcall(function() dot:SetBrushColor(color) end)
    dotBox:SetContent(dot)
    hadd(h, dotBox, 0, 0, 4, 0)
    local label = text(I, m and m.name or "?", 14, color)
    hadd(h, label.w)
    local hl = new(I, "Border")
    pcall(function() hl:SetBrushColor(rgba(color.R, color.G, color.B, 0.35)) end)
    local hlSlot = I.layer:AddChildToCanvas(hl)
    hlSlot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } })
    hlSlot:SetAlignment({ X = 0, Y = 0 })
    hlSlot:SetAutoSize(false)
    hlSlot:SetZOrder(5)
    w = { root = h, label = label, slot = place(I.layer, h, 0, 0, 0, 0, 0, 0, 10), hl = hl, hlSlot = hlSlot, ax = -1, ay = -1 }
    I.cursors[id] = w
    return w
end

-- Rect of a backpack slot in layer coordinates, or nil. Disables itself on the first error
-- (the FGeometry round trip through UE4SS is unverified).
local function slotRect(index)
    if I.geometryBroken then return nil end
    local ok, res = pcall(function()
        local arr = I.host.WeaponSlotWidget[SLOT_ARRAYS[KIND_BACKPACK]]
        if index < 1 or index > len(arr) then return nil end
        local slot = arr[index]
        if not valid(slot) then return nil end
        local sbl = lib("SlateBlueprintLibrary")
        local sg = slot:GetCachedGeometry()
        local absTL = sbl:LocalToAbsolute(sg, { X = 0, Y = 0 })
        local absSize = sbl:GetAbsoluteSize(sg)
        if absSize.X < 2 or absSize.Y < 2 then return nil end          -- not laid out / scrolled away
        local lg = I.layer:GetCachedGeometry()
        local tl = sbl:AbsoluteToLocal(lg, absTL)
        local br = sbl:AbsoluteToLocal(lg, { X = absTL.X + absSize.X, Y = absTL.Y + absSize.Y })
        local r = { x = tl.X, y = tl.Y, w = br.X - tl.X, h = br.Y - tl.Y }
        -- layer not painted yet: zero-scale geometry gives NaN/inf
        if not (r.w >= 2 and r.h >= 2 and r.w < 1e5 and r.h < 1e5 and r.x == r.x and r.y == r.y) then return nil end
        return r
    end)
    if not ok then
        I.geometryBroken = true
        log("drag highlight disabled: " .. tostring(res))
        return nil
    end
    return res
end

local function tickInventory()
    if not valid(I.host) or (not isOpen(I.host) and ticks % 10 == 0) then
        local found = activeInventory()
        if found and (not valid(I.host) or found:GetAddress() ~= I.host:GetAddress()) then
            setLayerVis(I.layer, VIS_COLLAPSED)
            I.host = found
            I.layer = nil
        end
        if not valid(I.host) then return end
    end
    if not isOpen(I.host) then setLayerVis(I.layer, VIS_COLLAPSED); return end
    if not valid(I.layer) then
        if not attachInventory() then I.host = nil; return end
    end
    setLayerVis(I.layer, VIS_HIT_TEST_INVISIBLE)

    for id, w in pairs(I.cursors) do
        if not mates[id] or not cursors[id] then
            w.root:RemoveFromParent(); w.hl:RemoveFromParent(); I.cursors[id] = nil
        end
    end
    for id, c in pairs(cursors) do
        local m = mates[id]
        if m then
            local w = ensureCursor(id)
            local on = c.visible and m.connected ~= false
            show(w.root, on)
            local rect = nil
            if on then
                c.x = c.x + (c.tx - c.x) * CURSOR_LERP
                c.y = c.y + (c.ty - c.y) * CURSOR_LERP
                if math.abs(c.x - w.ax) > 0.0005 or math.abs(c.y - w.ay) > 0.0005 then
                    w.slot:SetAnchors({ Minimum = { X = c.x, Y = c.y }, Maximum = { X = c.x, Y = c.y } })
                    w.ax, w.ay = c.x, c.y
                end
                local d = c.drag
                local label = m.name or "?"
                if d and d.item and d.item ~= "" then label = label .. "  拖着：" .. d.item end
                setText(w.label, label)
                if d and d.kind == KIND_BACKPACK and (d.index or 0) > 0 then rect = slotRect(d.index) end
            end
            show(w.hl, rect ~= nil)
            if rect then
                w.hlSlot:SetPosition({ X = rect.x, Y = rect.y })
                w.hlSlot:SetSize({ X = rect.w, Y = rect.h })
            end
        end
    end
end

---------------------------------------------------------------------------------------------
-- loop

local function hideAll()
    setLayerVis(H.layer, VIS_COLLAPSED)
    setLayerVis(I.layer, VIS_COLLAPSED)
end

local function tick()
    ticks = ticks + 1
    if not enabled then hideAll(); return end
    setLayerVis(H.layer, VIS_HIT_TEST_INVISIBLE)
    tickHud()
    tickInventory()
end

---------------------------------------------------------------------------------------------
-- public API

-- api = { log = function(msg) } (valid is optional). Starts the 50 ms UI loop.
function M.start(a)
    api = a or { log = print }
    -- Game-thread loop (LoopAsync raced with game-thread hooks in the same Lua state).
    LoopInGameThreadWithDelay(POLL_MS, function()
        local ok, err = pcall(tick)
        if not ok then
            log("error: " .. tostring(err) .. " - HUD disabled, hud.toggle() to retry")
            enabled = false
            pcall(hideAll)
        end
    end)
    log("started")
end

-- Per-frame update of the screen-space name tags; call from the ReceiveTick render hook.
-- Without it tags still update at 20 Hz from the UI loop.
function M.frame()
    if not enabled or not valid(H.layer) then return end
    framedAt = ticks
    local ok, err = pcall(updateTags)
    if not ok then warnOnce("frame", "frame error: " .. tostring(err)) end
end

function M.toggle()
    enabled = not enabled
    if enabled then
        H.host, I.host = nil, nil        -- rebuild everything on the next tick
        warned = {}
        I.geometryBroken = nil
    end
    log(enabled and "ON" or "OFF")
end

-- Merge fields into a teammate row. Either hud.setTeammate(id, { ... }) or the positional
-- form hud.setTeammate(id, name, hp, maxHp, downed, reviveProgress).
-- Fields: name, hp, maxHp, ping (ms), downed (bool), out (bool, eliminated),
--   reviveProgress (0..1), reviver (name of whoever is reviving), connected (bool),
--   otherLevel (bool), inInventory (bool). Pass false to clear reviveProgress/reviver/ping.
function M.setTeammate(id, a, hp, maxHp, downed, reviveProgress)
    local f = type(a) == "table" and a or {
        name = a, hp = hp, maxHp = maxHp, downed = downed and true or false, reviveProgress = reviveProgress or false,
    }
    local m = mates[id]
    if not m then
        nextOrder = nextOrder + 1
        m = { order = nextOrder, color = PALETTE[(nextOrder - 1) % #PALETTE + 1], connected = true }
        mates[id] = m
    end
    for k, v in pairs(f) do
        if v == false and (k == "reviveProgress" or k == "reviver" or k == "ping") then m[k] = nil
        else m[k] = v end
    end
end

function M.removeTeammate(id)
    mates[id] = nil
    cursors[id] = nil
    worldPos[id] = nil
end

function M.clear()
    mates, cursors, worldPos = {}, {}, {}
    localDown, reviveAction, reviveHint, statusText = nil, nil, nil, nil
end

-- x, y: 0..1 of the sender's screen. drag = { kind = 0 backpack | 1 weapon 1 | 2 weapon 2,
-- index = 1-based slot index (0 = unknown), item = name } or nil.
function M.setRemoteCursor(id, x, y, visible, drag)
    local c = cursors[id]
    if not c then
        c = { x = x or 0, y = y or 0 }
        cursors[id] = c
    end
    c.tx, c.ty = clamp(x or c.tx or 0, 0, 1), clamp(y or c.ty or 0, 0, 1)
    if not c.visible and visible then c.x, c.y = c.tx, c.ty end    -- appear in place, no slide
    c.visible = visible and true or false
    c.drag = drag
    if mates[id] then mates[id].inInventory = c.visible end
end

-- World location of a teammate (puppet actor location); x = nil hides the tag.
function M.setTeammateWorldPos(id, x, y, z)
    if x == nil then worldPos[id] = nil; return end
    local p = worldPos[id]
    if not p then p = {}; worldPos[id] = p end
    p.x, p.y, p.z = x, y, z
end

-- Local player downed state: nil = standing; { reviver = name|nil, progress = 0..1, out = bool }.
function M.setLocalDown(t) localDown = t end

-- The local player is reviving someone: name|nil, progress 0..1.
function M.setReviveAction(name, progress)
    reviveAction = name and { name = name, progress = progress } or nil
end

-- The local player is close to a downed teammate (not holding the key yet): name|nil.
function M.setReviveHint(name) reviveHint = name end

-- Corner status line (top right), nil hides it.
function M.setStatus(textOrNil) statusText = textOrNil end

function M.notify(msg, color, seconds)
    toastSerial = toastSerial + 1
    table.insert(toasts, { text = tostring(msg), color = color, born = now(), life = seconds or TOAST_SECONDS, serial = toastSerial })
    while #toasts > TOAST_MAX do table.remove(toasts, 1) end
end

-- Local cursor for the CURSOR message. Returns { open = false } when the inventory is closed,
-- else { open = true, x, y (0..1 of the screen), drag = { kind, index, item } | nil }.
-- kind 255 = dragging something that is not an inventory slot (or the Payload is unexpected).
local function localDrag(host)
    local wbl = lib("WidgetBlueprintLibrary")
    if not wbl:IsDragDropping() then dragCache.addr = nil; return nil end
    local op = wbl:GetDragDroppingContent()
    if not valid(op) then return nil end
    local payload = op.Payload
    if not valid(payload) then return { kind = 255, index = 0, item = "" } end
    local addr = payload:GetAddress()
    if dragCache.addr == addr then return dragCache.info end
    local info = { kind = 255, index = 0, item = "" }
    local pc = className(payload)
    if pc ~= SLOT_CLASS then
        warnOnce("payload" .. pc, "drag payload is " .. pc .. ", expected " .. SLOT_CLASS)
    else
        pcall(function()
            local n = payload.SlotInformation[F_DETAILS].ModName:ToString()
            if n then info.item = n end
        end)
        local ws = host.WeaponSlotWidget
        for kind = 0, 2 do
            local arr = ws[SLOT_ARRAYS[kind]]
            for i = 1, len(arr) do
                if same(arr[i], payload) then info.kind, info.index = kind, i; break end
            end
            if info.index > 0 then break end
        end
    end
    dragCache.addr, dragCache.info = addr, info
    return info
end

function M.getLocalCursor()
    local host = I.host
    if not valid(host) or not isOpen(host) then host = activeInventory() end
    if not host or not isOpen(host) then return { open = false } end
    local pc = playerController()
    if not pc then return { open = false } end
    local wll = lib("WidgetLayoutLibrary")
    local ok, res = pcall(function()
        local mouse = wll:GetMousePositionOnViewport(pc)
        local vp = wll:GetViewportSize(pc)
        local sc = wll:GetViewportScale(pc)
        if not (vp and vp.X > 0 and vp.Y > 0 and sc and sc > 0) then return nil end
        return { open = true, x = clamp(mouse.X * sc / vp.X, 0, 1), y = clamp(mouse.Y * sc / vp.Y, 0, 1) }
    end)
    if not ok or not res then
        if not ok then warnOnce("mouse", "mouse sampling failed: " .. tostring(res)) end
        return { open = true }
    end
    local okDrag, drag = pcall(localDrag, host)
    if okDrag then res.drag = drag else warnOnce("drag", "drag sampling failed: " .. tostring(drag)) end
    return res
end

-- Client side of ENEMY_HP: write the host's values into a local enemy and push them to its
-- health bar (the bar widget has no Tick, so writing fields alone does not redraw it).
-- t = { hp, maxHp, shield, armour, stagger } (any subset). hp is kept above 0: death comes
-- from its own message, never from the bar. Returns true when every step succeeded.
function M.applyEnemyHealth(enemy, t)
    if not valid(enemy) or not t then return false end
    local allOk = true
    local function step(key, fn)
        local ok, err = pcall(fn)
        if not ok then
            allOk = false
            warnOnce("enemy" .. key, "applyEnemyHealth " .. key .. " failed: " .. tostring(err))
        end
    end
    step("fields", function()
        if t.maxHp then enemy.MaxHealth = t.maxHp end
        if t.hp then enemy.Health = math.max(t.hp, 0.001) end
        if t.shield then enemy.ShieldHealth = t.shield end
        if t.armour then enemy.ArmourHealth = t.armour end
        if t.stagger then enemy.StaggerHealth = t.stagger end
    end)
    step("ShowHealthBar", function()
        if enemy["ShowingHealthBar?"] ~= true then enemy:ShowHealthBar() end
    end)
    if t.hp or t.maxHp then step("SetHealthBar", function() enemy:SetHealthBar() end) end
    if t.shield or t.armour then step("SetShieldBar", function() enemy:SetShieldBar() end) end
    if t.stagger then step("SetStaggerBar", function() enemy:SetStaggerBar() end) end
    return allOk
end

return M

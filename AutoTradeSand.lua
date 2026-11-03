--[[
AutoTradeSand (1.12 port) - fills the trade window with Hourglass Sand.
Vanilla 1.12 / Lua 5.0 compatible, works with or without ClassicAPI.
Minimap button: left click = toggle auto trade, right click = config, drag = move.
]]

local DEFAULT_ITEM_ID = 19183 -- Hourglass Sand (change with /ats id <number> or in the config window)
local MAX_SLOTS = 6           -- tradable slots in the player's trade window
local ICON = "Interface\\Icons\\INV_Misc_PocketWatch_01"

local tradeOpen = false
local refreshing = false
local ConfigFrame, MinimapButton
local pending = nil
local cfgCheck, cfgSlider, cfgEdit
local RefreshConfig, UpdateMinimapButton, ToggleConfig, UpdateSandIcon

local function Msg(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cFFFF1C1C[ATS]|r " .. text)
end

----------------------------------------------------------------
-- Bag / trade helpers
----------------------------------------------------------------
local function GetItemIDFromBag(bag, slot)
    local link = GetContainerItemLink(bag, slot)
    if not link then return nil end
    local _, _, id = string.find(link, "item:(%d+)")
    return tonumber(id)
end

-- Returns the stack size of a bag slot. Handles both the vanilla return
-- (texture, count, ...) and the table form some API backports use.
local function GetStackCount(bag, slot)
    local a, b = GetContainerItemInfo(bag, slot)
    if type(a) == "table" then
        return a.stackCount or a.count
    end
    return b
end

local function FirstFreeTradeSlot()
    for i = 1, MAX_SLOTS do
        if not GetTradePlayerItemInfo(i) then
            return i
        end
    end
    return nil
end

local function ClearTrade()
    pending = nil
    for i = 1, MAX_SLOTS do
        if GetTradePlayerItemInfo(i) then
            ClearCursor()
            ClickTradeButton(i)
            ClearCursor()
        end
    end
    ClearCursor()
end

-- Trade fill state machine.
-- Vanilla trade always moves the WHOLE stack of the bag slot you click, so to
-- trade only N items we first split N off into a free bag slot, wait for the
-- server to confirm, and then trade that small stack.
local timer = CreateFrame("Frame")
timer:Hide()

local function FindEmptySlot()
    for bag = 0, 4 do
        for slot = 1, GetContainerNumSlots(bag) do
            if not GetContainerItemLink(bag, slot) then
                return bag, slot
            end
        end
    end
    return nil
end

local function ScanStacks(itemID, used)
    local list = {}
    for bag = 0, 4 do
        for slot = 1, GetContainerNumSlots(bag) do
            if not used[bag .. ":" .. slot] and GetItemIDFromBag(bag, slot) == itemID then
                table.insert(list, { bag = bag, slot = slot, count = GetStackCount(bag, slot) or 1 })
            end
        end
    end
    return list
end

local function StopPending()
    pending = nil
    timer:Hide()
end

local function PlaceInTrade(s)
    ClearCursor()
    PickupContainerItem(s.bag, s.slot)
    if CursorHasItem() then
        ClickTradeButton(pending.slot)
        pending.slot = pending.slot + 1
        pending.used[s.bag .. ":" .. s.slot] = true
        ClearCursor()
        return true
    end
    ClearCursor()
    return false
end

local function Step()
    if not pending then return end
    if not tradeOpen then StopPending() return end

    local remaining = pending.remaining

    local function Done()
        Msg("Added " .. pending.total .. " sand to the trade")
        StopPending()
    end

    local stacks = ScanStacks(ATS_DB.ItemID, pending.used)

    if ATS_DB.Debug then
        Msg("step: remaining=" .. remaining .. " stacks=" .. table.getn(stacks) .. " tries=" .. pending.tries)
    end

    -- 1) a stack of exactly the wanted size
    for i = 1, table.getn(stacks) do
        local s = stacks[i]
        if s.count == remaining and pending.slot <= MAX_SLOTS then
            if PlaceInTrade(s) then
                pending.remaining = 0
                Done()
                return
            end
        end
    end

    -- 2) stacks smaller than what we still need: trade them whole
    for i = 1, table.getn(stacks) do
        local s = stacks[i]
        if s.count < remaining and pending.slot <= MAX_SLOTS then
            if PlaceInTrade(s) then
                remaining = remaining - s.count
            end
        end
    end
    pending.remaining = remaining
    if remaining <= 0 then
        Done()
        return
    end

    if pending.slot > MAX_SLOTS then
        Msg("Trade window is full")
        StopPending()
        return
    end

    -- 3) split what we need out of a bigger stack into a free bag slot
    if pending.tries >= 4 then
        Msg("Could not split the stack (tried " .. pending.tries .. " times)")
        StopPending()
        return
    end

    local source
    stacks = ScanStacks(ATS_DB.ItemID, pending.used)
    for i = 1, table.getn(stacks) do
        if stacks[i].count > remaining then
            source = stacks[i]
            break
        end
    end
    if not source then
        Msg("Not enough sand! Wanted " .. pending.total .. ", could add " .. (pending.total - remaining))
        StopPending()
        return
    end

    local eb, es = FindEmptySlot()
    if not eb then
        Msg("No free bag slot to split the stack - free one slot and try again")
        StopPending()
        return
    end

    ClearCursor()
    SplitContainerItem(source.bag, source.slot, remaining)
    if not CursorHasItem() then
        Msg("Split failed")
        StopPending()
        return
    end
    PickupContainerItem(eb, es)
    ClearCursor()

    if ATS_DB.Debug then
        Msg("split " .. remaining .. " from bag " .. source.bag .. " slot " .. source.slot ..
            " (count " .. source.count .. ") into bag " .. eb .. " slot " .. es)
    end

    pending.tries = pending.tries + 1
    pending.waiting = true
    pending.elapsed = 0
    timer:Show()
end

timer:SetScript("OnUpdate", function()
    if not pending then
        this:Hide()
        return
    end
    if pending.waiting then
        pending.elapsed = pending.elapsed + arg1
        if pending.elapsed >= 0.5 then
            pending.waiting = false
            Step()
        end
    end
end)

local function FillTrade()
    if not tradeOpen then
        Msg("No trade in progress")
        return
    end

    local slot = FirstFreeTradeSlot()
    if not slot then
        Msg("Trade window is full")
        return
    end

    pending = {
        total = ATS_DB.SandCount,
        remaining = ATS_DB.SandCount,
        slot = slot,
        used = {},
        tries = 0,
        elapsed = 0,
        waiting = false,
    }
    Step()
end

----------------------------------------------------------------
-- Settings helpers
----------------------------------------------------------------
local function SetAutoFill(value)
    ATS_DB.AutoFill = value
    if value then Msg("Auto trade |cFF00FF00ON|r") else Msg("Auto trade |cFFFF0000OFF|r") end
    UpdateMinimapButton()
    RefreshConfig()
end

local function SetCount(n)
    ATS_DB.SandCount = n
    RefreshConfig()
end

local function SetItemID(n)
    ATS_DB.ItemID = n
    ATS_DB.IconTexture = nil
    if UpdateSandIcon then UpdateSandIcon() end
    RefreshConfig()
end

----------------------------------------------------------------
-- Minimap button
----------------------------------------------------------------
local function UpdateMinimapPosition()
    local a = math.rad(ATS_DB.MinimapAngle or 200)
    MinimapButton:ClearAllPoints()
    MinimapButton:SetPoint("TOPLEFT", Minimap, "TOPLEFT", 52 - 80 * math.cos(a), 80 * math.sin(a) - 52)
end

local function MinimapDragUpdate()
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local s = Minimap:GetEffectiveScale()
    px, py = px / s, py / s
    ATS_DB.MinimapAngle = math.deg(math.atan2(py - my, px - mx))
    UpdateMinimapPosition()
end

UpdateMinimapButton = function()
    if not MinimapButton then return end
    local icon = MinimapButton.icon
    if ATS_DB.AutoFill then
        icon:SetVertexColor(1, 1, 1)
        if icon.SetDesaturated then icon:SetDesaturated(nil) end
    else
        icon:SetVertexColor(0.5, 0.5, 0.5)
        if icon.SetDesaturated then icon:SetDesaturated(1) end
    end
end

-- Use the real icon of the configured item (Hourglass Sand) on the button.
UpdateSandIcon = function()
    if not MinimapButton then return end
    local tex

    -- 1) item cache (9th return value of GetItemInfo in 1.12)
    local _, _, _, _, _, _, _, _, t = GetItemInfo(ATS_DB.ItemID)
    if type(t) == "string" then tex = t end

    -- 2) the icon of a matching item sitting in the bags
    if not tex then
        for bag = 0, 4 do
            for slot = 1, GetContainerNumSlots(bag) do
                if not tex and GetItemIDFromBag(bag, slot) == ATS_DB.ItemID then
                    local a = GetContainerItemInfo(bag, slot)
                    if type(a) == "string" then tex = a end
                end
            end
        end
    end

    if tex then
        ATS_DB.IconTexture = tex
    else
        tex = ATS_DB.IconTexture or ICON -- 3) remembered icon, else a generic one
    end
    MinimapButton.icon:SetTexture(tex)
end

local function CreateMinimapButton()
    local b = CreateFrame("Button", "ATS_MinimapButton", Minimap)
    b:SetWidth(31)
    b:SetHeight(31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local icon = b:CreateTexture("ATS_MinimapIcon", "BACKGROUND")
    icon:SetTexture(ICON)
    icon:SetWidth(20)
    icon:SetHeight(20)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    icon:SetPoint("TOPLEFT", b, "TOPLEFT", 6, -5)
    b.icon = icon

    local border = b:CreateTexture("ATS_MinimapBorder", "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetWidth(53)
    border:SetHeight(53)
    border:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)

    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")

    b:SetScript("OnClick", function()
        if arg1 == "RightButton" then
            ToggleConfig()
        else
            SetAutoFill(not ATS_DB.AutoFill)
        end
    end)

    b:SetScript("OnDragStart", function()
        this:LockHighlight()
        this:SetScript("OnUpdate", MinimapDragUpdate)
    end)

    b:SetScript("OnDragStop", function()
        this:SetScript("OnUpdate", nil)
        this:UnlockHighlight()
    end)

    b:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:AddLine("AutoTradeSand")
        if ATS_DB.AutoFill then
            GameTooltip:AddLine("Auto trade: |cFF00FF00ON|r", 1, 1, 1)
        else
            GameTooltip:AddLine("Auto trade: |cFFFF0000OFF|r", 1, 1, 1)
        end
        GameTooltip:AddLine("Sand per trade: " .. ATS_DB.SandCount, 1, 1, 1)
        GameTooltip:AddLine("Left click: enable / disable", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Right click: config", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Drag: move button", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)

    b:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    MinimapButton = b
    UpdateMinimapPosition()
    UpdateSandIcon()
    UpdateMinimapButton()
end

----------------------------------------------------------------
-- Config window
----------------------------------------------------------------
RefreshConfig = function()
    if not ConfigFrame then return end
    refreshing = true
    if ATS_DB.AutoFill then cfgCheck:SetChecked(1) else cfgCheck:SetChecked(nil) end
    cfgSlider:SetValue(ATS_DB.SandCount)
    getglobal("ATS_CountSliderText"):SetText("Sand per trade: " .. ATS_DB.SandCount)
    cfgEdit:SetText(tostring(ATS_DB.ItemID))
    refreshing = false
end

ToggleConfig = function()
    if ConfigFrame:IsVisible() then
        ConfigFrame:Hide()
    else
        ConfigFrame:Show()
    end
end

local function ApplyItemEdit(edit)
    local n = tonumber(edit:GetText())
    if n and n > 0 then
        n = math.floor(n)
        SetItemID(n)
        Msg("Item ID set to " .. n)
    else
        RefreshConfig()
    end
end

local function CreateConfig()
    local f = CreateFrame("Frame", "ATS_ConfigFrame", UIParent)
    f:SetWidth(280)
    f:SetHeight(250)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    f:SetScript("OnDragStart", function() this:StartMoving() end)
    f:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
    f:SetScript("OnShow", function() RefreshConfig() end)
    f:Hide()

    local title = f:CreateFontString("ATS_ConfigTitle", "ARTWORK", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -18)
    title:SetText("AutoTradeSand")

    local close = CreateFrame("Button", "ATS_ConfigClose", f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

    -- Auto trade checkbox
    cfgCheck = CreateFrame("CheckButton", "ATS_AutoCheck", f, "UICheckButtonTemplate")
    cfgCheck:SetPoint("TOPLEFT", f, "TOPLEFT", 24, -45)
    getglobal("ATS_AutoCheckText"):SetText("Auto trade enabled")
    cfgCheck:SetScript("OnClick", function()
        if refreshing then return end
        if this:GetChecked() then SetAutoFill(true) else SetAutoFill(false) end
    end)

    -- Sand count slider
    cfgSlider = CreateFrame("Slider", "ATS_CountSlider", f, "OptionsSliderTemplate")
    cfgSlider:SetWidth(200)
    cfgSlider:SetPoint("TOP", f, "TOP", 0, -100)
    cfgSlider:SetMinMaxValues(1, 20)
    cfgSlider:SetValueStep(1)
    getglobal("ATS_CountSliderLow"):SetText("1")
    getglobal("ATS_CountSliderHigh"):SetText("20")
    cfgSlider:SetScript("OnValueChanged", function()
        if refreshing then return end
        local v = math.floor(this:GetValue() + 0.5)
        ATS_DB.SandCount = v
        getglobal("ATS_CountSliderText"):SetText("Sand per trade: " .. v)
    end)

    -- Item ID edit box
    local label = f:CreateFontString("ATS_ItemLabel", "ARTWORK", "GameFontNormal")
    label:SetPoint("TOPLEFT", f, "TOPLEFT", 28, -132)
    label:SetText("Item ID:")

    cfgEdit = CreateFrame("EditBox", "ATS_ItemEdit", f, "InputBoxTemplate")
    cfgEdit:SetWidth(90)
    cfgEdit:SetHeight(20)
    cfgEdit:SetPoint("LEFT", label, "RIGHT", 14, 0)
    cfgEdit:SetAutoFocus(false)
    cfgEdit:SetMaxLetters(8)
    cfgEdit:SetScript("OnEnterPressed", function()
        ApplyItemEdit(this)
        this:ClearFocus()
    end)
    cfgEdit:SetScript("OnEscapePressed", function()
        this:ClearFocus()
        RefreshConfig()
    end)
    cfgEdit:SetScript("OnEditFocusLost", function()
        if not refreshing then ApplyItemEdit(this) end
    end)

    -- Buttons
    local fill = CreateFrame("Button", "ATS_FillButton", f, "UIPanelButtonTemplate")
    fill:SetWidth(105)
    fill:SetHeight(22)
    fill:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 24, 40)
    fill:SetText("Fill now")
    fill:SetScript("OnClick", function()
        if tradeOpen then FillTrade() else Msg("Trade window is not open") end
    end)

    local clear = CreateFrame("Button", "ATS_ClearButton", f, "UIPanelButtonTemplate")
    clear:SetWidth(105)
    clear:SetHeight(22)
    clear:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -24, 40)
    clear:SetText("Clear trade")
    clear:SetScript("OnClick", function()
        if tradeOpen then ClearTrade() Msg("Trade cleared") else Msg("Trade window is not open") end
    end)

    local hint = f:CreateFontString("ATS_ConfigHint", "ARTWORK", "GameFontHighlightSmall")
    hint:SetPoint("BOTTOM", f, "BOTTOM", 0, 20)
    hint:SetText("Minimap icon: left click = on/off, right click = config")

    ConfigFrame = f
    tinsert(UISpecialFrames, "ATS_ConfigFrame")
end

----------------------------------------------------------------
-- Events
----------------------------------------------------------------
local function OnAddonLoaded()
    if not ATS_DB then ATS_DB = {} end
    if not ATS_DB.SandCount then ATS_DB.SandCount = 1 end
    if not ATS_DB.ItemID then ATS_DB.ItemID = DEFAULT_ITEM_ID end
    if ATS_DB.AutoFill == nil then ATS_DB.AutoFill = true end
    if not ATS_DB.MinimapAngle then ATS_DB.MinimapAngle = 200 end
    CreateConfig()
    CreateMinimapButton()
    Msg("AutoTradeSand loaded. Type /ats help")
end

local function OnTradeShow()
    tradeOpen = true
    if ATS_DB.AutoFill then
        FillTrade()
    end
end

local function OnTradeClosed()
    tradeOpen = false
    pending = nil
end

----------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------
local function ShowHelp()
    Msg("/ats config - open the config window")
    Msg("/ats toggle - enable / disable auto trade")
    Msg("/ats fill - fill the trade window with sand")
    Msg("/ats clear - clear your side of the trade")
    Msg("/ats <number> - sand per trade (e.g. /ats 2)")
    Msg("/ats id <itemID> - set the item ID (default 19183)")
    Msg("/ats status - show settings")
end

local function SlashHandler(text)
    local cmd = string.lower(text or "")
    local _, _, word, rest = string.find(cmd, "^(%S*)%s*(.-)$")
    word = word or ""

    if word == "" or word == "help" then
        ShowHelp()
    elseif word == "config" or word == "options" then
        ToggleConfig()
    elseif word == "toggle" or word == "auto" then
        SetAutoFill(not ATS_DB.AutoFill)
    elseif word == "fill" then
        if tradeOpen then FillTrade() else Msg("Trade window is not open") end
    elseif word == "clear" then
        if tradeOpen then ClearTrade() Msg("Trade cleared") else Msg("Trade window is not open") end
    elseif word == "id" then
        local n = tonumber(rest)
        if n then
            SetItemID(math.floor(n))
            Msg("Item ID set to " .. math.floor(n))
        else
            Msg("Usage: /ats id <itemID>")
        end
    elseif word == "debug" then
        ATS_DB.Debug = not ATS_DB.Debug
        if ATS_DB.Debug then Msg("Debug ON") else Msg("Debug OFF") end
    elseif word == "status" then
        local a = "OFF"
        if ATS_DB.AutoFill then a = "ON" end
        Msg("Auto trade: " .. a .. ", count: " .. ATS_DB.SandCount .. ", item ID: " .. ATS_DB.ItemID)
    elseif tonumber(word) then
        local n = math.floor(tonumber(word))
        if n >= 1 then
            SetCount(n)
            Msg("Sand count set to " .. n)
        else
            Msg("Count must be at least 1")
        end
    else
        Msg("Unknown command. /ats help")
    end
end

SLASH_AUTOTRADESAND1 = "/ats"
SLASH_AUTOTRADESAND2 = "/autotradesand"
SlashCmdList["AUTOTRADESAND"] = SlashHandler

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("TRADE_SHOW")
frame:RegisterEvent("TRADE_CLOSED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function()
    -- vanilla passes event data through the globals "event" and "arg1"
    if event == "ADDON_LOADED" and arg1 and string.lower(arg1) == "autotradesand" then
        OnAddonLoaded()
    elseif event == "PLAYER_ENTERING_WORLD" then
        if ATS_DB and UpdateSandIcon then UpdateSandIcon() end
    elseif event == "TRADE_SHOW" then
        if ATS_DB then OnTradeShow() end
    elseif event == "TRADE_CLOSED" then
        OnTradeClosed()
    end
end)

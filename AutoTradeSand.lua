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
local tradeName, snap, closedSnap
local cfgCheck, cfgSlider, cfgEdit, cfgZone
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

-- Does the OTHER player currently offer the configured item in their trade slots?
local function TargetOffersItem()
    for i = 1, MAX_SLOTS do
        local link = GetTradeTargetItemLink(i)
        if link then
            local _, _, id = string.find(link, "item:(%d+)")
            if tonumber(id) == ATS_DB.ItemID then
                return true
            end
        end
    end
    return false
end

-- Takes the configured item back out of OUR side of the trade (other items stay).
-- Also cancels a fill in progress. Returns true if something was removed or cancelled.
local function ClearOwnItem()
    local did = (pending ~= nil)
    StopPending()
    for i = 1, MAX_SLOTS do
        local link = GetTradePlayerItemLink(i)
        if link then
            local _, _, id = string.find(link, "item:(%d+)")
            if tonumber(id) == ATS_DB.ItemID then
                ClearCursor()
                ClickTradeButton(i)
                ClearCursor()
                did = true
            end
        end
    end
    ClearCursor()
    return did
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

    if TargetOffersItem() then
        Msg("The other player is already offering it - not adding yours")
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
    if cfgZone then
        if ATS_DB.PromptReset ~= false then cfgZone:SetChecked(1) else cfgZone:SetChecked(nil) end
        getglobal("ATS_ZoneCheckText"):SetText("Ask to reset history in " .. (ATS_DB.ResetZone or "Blackwing Lair"))
    end
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

----------------------------------------------------------------
-- History (who got how much sand) + tabs
-- Stored in ATS_DB.History (saved variable), so it survives logout / reload.
-- Per player: sand = sent, used = uses seen in the combat log, back = traded back.
----------------------------------------------------------------
local HIST_ROWS = 40
local HIST_PER_COL = 20
local DEFAULT_RESET_ZONE = "Blackwing Lair"
local DEFAULT_SPELL = "Hourglass Sand"

local COLKEY = { "name", "sent", "used", "back", "left" }
local COLNAME = { "Player", "Sent", "Used", "Back", "Left" }
local COLX = { 0, 86, 118, 150, 182 }
local COLW = { 84, 30, 30, 30, 30 }
local COLCOL = { false, { 1, 1, 1 }, { 0.4, 1, 0.4 }, { 0.5, 0.8, 1 }, { 1, 0.6, 0.2 } }

local histRows = {}
local histSummary
local settingsW, histW = {}, {}
local tabBtnS, tabBtnH
local activeTab = "settings"
local RefreshHistory

local function Num(v)
    return v or 0
end

local function Outstanding(h)
    local left = Num(h.sand) - Num(h.used) - Num(h.back)
    if left < 0 then left = 0 end
    return left
end

local function HistoryTotals()
    local players, sent, used, back, left = 0, 0, 0, 0, 0
    if ATS_DB.History then
        for _, h in pairs(ATS_DB.History) do
            players = players + 1
            sent = sent + Num(h.sand)
            used = used + Num(h.used)
            back = back + Num(h.back)
            left = left + Outstanding(h)
        end
    end
    return players, sent, used, back, left
end

----------------------------------------------------------------
-- Trade snapshot: sand on our side (given) and on their side (given back)
----------------------------------------------------------------
local function CountSandInTrade(getLink, getInfo)
    local n = 0
    for i = 1, MAX_SLOTS do
        local link = getLink(i)
        if link then
            local _, _, id = string.find(link, "item:(%d+)")
            if tonumber(id) == ATS_DB.ItemID then
                local _, _, num = getInfo(i)
                n = n + (num or 1)
            end
        end
    end
    return n
end

local function SnapshotTrade()
    if not tradeOpen then return end
    snap = {
        name = tradeName,
        sand = CountSandInTrade(GetTradePlayerItemLink, GetTradePlayerItemInfo),
        back = CountSandInTrade(GetTradeTargetItemLink, GetTradeTargetItemInfo),
    }
end

----------------------------------------------------------------
-- Recording
----------------------------------------------------------------
local function RecordTrade(name, sand)
    if not ATS_DB.History then ATS_DB.History = {} end
    local h = ATS_DB.History[name]
    if not h then
        h = { sand = 0, trades = 0, used = 0, back = 0 }
        ATS_DB.History[name] = h
    end
    h.sand = Num(h.sand) + sand
    h.trades = Num(h.trades) + 1
    h.last = time()
    if ATS_DB.Debug then Msg("history: " .. name .. " received " .. sand .. " sand") end
    if RefreshHistory then RefreshHistory() end
end

-- They handed sand back to us in a trade.
local function RecordReturn(name, n)
    local h = ATS_DB.History and ATS_DB.History[name]
    if not h then return end
    h.back = Num(h.back) + n
    h.last = time()
    if ATS_DB.Debug then Msg("history: " .. name .. " gave back " .. n .. " sand") end
    if RefreshHistory then RefreshHistory() end
end

-- We saw them use one sand (combat log). Only counted while they still hold some of ours.
local function RecordUse(name)
    local h = ATS_DB.History and ATS_DB.History[name]
    if not h then return end
    if Outstanding(h) <= 0 then return end
    h.used = Num(h.used) + 1
    h.last = time()
    if ATS_DB.Debug then Msg("history: " .. name .. " used 1 sand") end
    if RefreshHistory then RefreshHistory() end
end

-- Called when the client reports "Trade complete."
local function OnTradeComplete()
    local s = snap or closedSnap
    if s and s.name then
        if s.sand and s.sand > 0 then RecordTrade(s.name, s.sand) end
        if s.back and s.back > 0 then RecordReturn(s.name, s.back) end
    end
    snap = nil
    closedSnap = nil
end

local function EscapePattern(s)
    return (string.gsub(s, "(%W)", "%%%1"))
end

-- Combat log lines such as "Bob casts Hourglass Sand." (other players) .
local function OnSpellMessage(msg)
    if not msg then return end
    local spell = ATS_DB.SpellName or DEFAULT_SPELL
    if not string.find(msg, spell, 1, true) then return end
    if ATS_DB.Debug then Msg("sand log: " .. msg) end
    local esc = EscapePattern(spell)
    local _, _, who = string.find(msg, "^(.-) casts " .. esc)
    if not who then
        _, _, who = string.find(msg, "^(.-) uses " .. esc)
    end
    if who and who ~= "" then RecordUse(who) end
end

----------------------------------------------------------------
-- Reset / undo + Blackwing Lair prompt
----------------------------------------------------------------
local function ResetHistory()
    ATS_DB.PrevHistory = ATS_DB.History
    ATS_DB.History = {}
    RefreshHistory()
    Msg("History reset (type /ats undo to restore it)")
end

local function UndoReset()
    if not ATS_DB.PrevHistory then
        Msg("Nothing to restore")
        return
    end
    ATS_DB.History = ATS_DB.PrevHistory
    ATS_DB.PrevHistory = nil
    RefreshHistory()
    Msg("History restored")
end

StaticPopupDialogs["ATS_RESET_HISTORY"] = {
    text = "You entered %s.\n\nReset the AutoTradeSand history (%s)?",
    button1 = "Reset",
    button2 = "Keep",
    OnAccept = function() ResetHistory() end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
}

local function CheckZone()
    if not ATS_DB then return end
    local zone = GetRealZoneText()
    if not zone or zone == "" then zone = GetZoneText() end
    if not zone or zone == "" then return end

    local target = ATS_DB.ResetZone or DEFAULT_RESET_ZONE
    if string.lower(zone) == string.lower(target) then
        if not ATS_DB.InResetZone then
            ATS_DB.InResetZone = true
            local players, sent = HistoryTotals()
            if ATS_DB.PromptReset ~= false and players > 0 then
                StaticPopup_Show("ATS_RESET_HISTORY", zone, players .. " players, " .. sent .. " sand")
            end
        end
    else
        ATS_DB.InResetZone = false
    end
end

-- The zone name is not always ready right on the loading screen, so check twice.
local zoneTimer = CreateFrame("Frame")
zoneTimer:Hide()
zoneTimer.t = 0
zoneTimer:SetScript("OnUpdate", function()
    this.t = this.t + arg1
    if this.t >= 2 then
        this:Hide()
        CheckZone()
    end
end)

local function ScheduleZoneCheck()
    CheckZone()
    zoneTimer.t = 0
    zoneTimer:Show()
end

----------------------------------------------------------------
-- History tab rendering
----------------------------------------------------------------
local function Cell(v)
    if v and v > 0 then return tostring(v) end
    return "-"
end

RefreshHistory = function()
    if not ConfigFrame then return end
    local list = {}
    if ATS_DB.History then
        for name, h in pairs(ATS_DB.History) do
            table.insert(list, {
                name = name,
                sent = Num(h.sand),
                used = Num(h.used),
                back = Num(h.back),
                left = Outstanding(h),
            })
        end
    end
    table.sort(list, function(a, b)
        if a.sent ~= b.sent then return a.sent > b.sent end
        return a.name < b.name
    end)
    local i
    for i = 1, HIST_ROWS do
        local row = histRows[i]
        local e = list[i]
        if e then
            row.name:SetText(e.name)
            row.sent:SetText(Cell(e.sent))
            row.used:SetText(Cell(e.used))
            row.back:SetText(Cell(e.back))
            row.left:SetText(Cell(e.left))
        else
            row.name:SetText("")
            row.sent:SetText("")
            row.used:SetText("")
            row.back:SetText("")
            row.left:SetText("")
        end
    end
    local players, sent, used, back, left = HistoryTotals()
    local txt = players .. " players - sent " .. sent .. ", used " .. used .. ", back " .. back .. ", left " .. left
    if players > HIST_ROWS then txt = txt .. " (top " .. HIST_ROWS .. ")" end
    histSummary:SetText(txt)
end

local function ShowTab(name)
    activeTab = name
    local i
    for i = 1, table.getn(settingsW) do
        if name == "settings" then settingsW[i]:Show() else settingsW[i]:Hide() end
    end
    for i = 1, table.getn(histW) do
        if name == "history" then histW[i]:Show() else histW[i]:Hide() end
    end
    if name == "history" then
        ConfigFrame:SetWidth(480)
        ConfigFrame:SetHeight(405)
        tabBtnH:Disable()
        tabBtnS:Enable()
    else
        ConfigFrame:SetWidth(390)
        ConfigFrame:SetHeight(315)
        tabBtnS:Disable()
        tabBtnH:Enable()
    end
end

local function CreateConfig()
    local f = CreateFrame("Frame", "ATS_ConfigFrame", UIParent)
    f:SetWidth(390)
    f:SetHeight(315)
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
    f:SetScript("OnShow", function()
        ShowTab(activeTab)
        RefreshConfig()
        RefreshHistory()
    end)
    f:Hide()
    ConfigFrame = f

    local title = f:CreateFontString("ATS_ConfigTitle", "ARTWORK", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -18)
    title:SetText("AutoTradeSand")

    local close = CreateFrame("Button", "ATS_ConfigClose", f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

    -- Tabs
    tabBtnS = CreateFrame("Button", "ATS_TabSettings", f, "UIPanelButtonTemplate")
    tabBtnS:SetWidth(90)
    tabBtnS:SetHeight(22)
    tabBtnS:SetPoint("TOPLEFT", f, "TOPLEFT", 22, -40)
    tabBtnS:SetText("Settings")
    tabBtnS:SetScript("OnClick", function() ShowTab("settings") end)

    tabBtnH = CreateFrame("Button", "ATS_TabHistory", f, "UIPanelButtonTemplate")
    tabBtnH:SetWidth(90)
    tabBtnH:SetHeight(22)
    tabBtnH:SetPoint("LEFT", tabBtnS, "RIGHT", 4, 0)
    tabBtnH:SetText("History")
    tabBtnH:SetScript("OnClick", function() ShowTab("history") end)

    ------------------------------------------------------------
    -- Settings tab
    ------------------------------------------------------------
    cfgCheck = CreateFrame("CheckButton", "ATS_AutoCheck", f, "UICheckButtonTemplate")
    cfgCheck:SetPoint("TOPLEFT", f, "TOPLEFT", 40, -78)
    getglobal("ATS_AutoCheckText"):SetText("Auto trade enabled")
    cfgCheck:SetScript("OnClick", function()
        if refreshing then return end
        if this:GetChecked() then SetAutoFill(true) else SetAutoFill(false) end
    end)
    table.insert(settingsW, cfgCheck)

    cfgSlider = CreateFrame("Slider", "ATS_CountSlider", f, "OptionsSliderTemplate")
    cfgSlider:SetWidth(220)
    cfgSlider:SetPoint("TOP", f, "TOP", 0, -130)
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
    table.insert(settingsW, cfgSlider)

    local label = f:CreateFontString("ATS_ItemLabel", "ARTWORK", "GameFontNormal")
    label:SetPoint("TOPLEFT", f, "TOPLEFT", 60, -165)
    label:SetText("Item ID:")
    table.insert(settingsW, label)

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
    table.insert(settingsW, cfgEdit)

    cfgZone = CreateFrame("CheckButton", "ATS_ZoneCheck", f, "UICheckButtonTemplate")
    cfgZone:SetPoint("TOPLEFT", f, "TOPLEFT", 40, -192)
    getglobal("ATS_ZoneCheckText"):SetText("Ask to reset history in " .. DEFAULT_RESET_ZONE)
    cfgZone:SetScript("OnClick", function()
        if refreshing then return end
        if this:GetChecked() then ATS_DB.PromptReset = true else ATS_DB.PromptReset = false end
    end)
    table.insert(settingsW, cfgZone)

    local fill = CreateFrame("Button", "ATS_FillButton", f, "UIPanelButtonTemplate")
    fill:SetWidth(110)
    fill:SetHeight(22)
    fill:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 60, 50)
    fill:SetText("Fill now")
    fill:SetScript("OnClick", function()
        if tradeOpen then FillTrade() else Msg("Trade window is not open") end
    end)
    table.insert(settingsW, fill)

    local clear = CreateFrame("Button", "ATS_ClearButton", f, "UIPanelButtonTemplate")
    clear:SetWidth(110)
    clear:SetHeight(22)
    clear:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -60, 50)
    clear:SetText("Clear trade")
    clear:SetScript("OnClick", function()
        if tradeOpen then ClearTrade() Msg("Trade cleared") else Msg("Trade window is not open") end
    end)
    table.insert(settingsW, clear)

    local hint = f:CreateFontString("ATS_ConfigHint", "ARTWORK", "GameFontHighlightSmall")
    hint:SetPoint("BOTTOM", f, "BOTTOM", 0, 24)
    hint:SetText("Minimap icon: left click = on/off, right click = config")
    table.insert(settingsW, hint)

    ------------------------------------------------------------
    -- History tab: 2 columns x 20 rows = 40 players at a glance
    ------------------------------------------------------------
    local col, k
    for col = 0, 1 do
        for k = 1, 5 do
            local hd = f:CreateFontString("ATS_HistHead" .. COLNAME[k] .. col, "ARTWORK", "GameFontNormalSmall")
            hd:SetPoint("TOPLEFT", f, "TOPLEFT", 22 + col * 224 + COLX[k], -70)
            hd:SetWidth(COLW[k])
            if k == 1 then hd:SetJustifyH("LEFT") else hd:SetJustifyH("RIGHT") end
            hd:SetText(COLNAME[k])
            table.insert(histW, hd)
        end
    end

    local i
    for i = 1, HIST_ROWS do
        local c = 0
        if i > HIST_PER_COL then c = 1 end
        local rr = math.mod(i - 1, HIST_PER_COL)
        local x0 = 22 + c * 224
        local y = -86 - rr * 13
        local row = {}
        for k = 1, 5 do
            local tpl = "GameFontNormalSmall"
            if k == 1 then tpl = "GameFontHighlightSmall" end
            local fs = f:CreateFontString("ATS_Hist" .. COLNAME[k] .. i, "ARTWORK", tpl)
            fs:SetPoint("TOPLEFT", f, "TOPLEFT", x0 + COLX[k], y)
            fs:SetWidth(COLW[k])
            fs:SetHeight(12)
            if k == 1 then fs:SetJustifyH("LEFT") else fs:SetJustifyH("RIGHT") end
            if COLCOL[k] then
                fs:SetTextColor(COLCOL[k][1], COLCOL[k][2], COLCOL[k][3])
            end
            row[COLKEY[k]] = fs
            table.insert(histW, fs)
        end
        histRows[i] = row
    end

    histSummary = f:CreateFontString("ATS_HistSummary", "ARTWORK", "GameFontHighlightSmall")
    histSummary:SetPoint("BOTTOM", f, "BOTTOM", 0, 52)
    table.insert(histW, histSummary)

    local clearHist = CreateFrame("Button", "ATS_ClearHistory", f, "UIPanelButtonTemplate")
    clearHist:SetWidth(130)
    clearHist:SetHeight(22)
    clearHist:SetPoint("BOTTOM", f, "BOTTOM", -70, 24)
    clearHist:SetText("Reset history")
    clearHist:SetScript("OnClick", function()
        if IsShiftKeyDown() then
            ResetHistory()
        else
            Msg("Hold Shift and click to reset the history")
        end
    end)
    table.insert(histW, clearHist)

    local undoHist = CreateFrame("Button", "ATS_UndoHistory", f, "UIPanelButtonTemplate")
    undoHist:SetWidth(130)
    undoHist:SetHeight(22)
    undoHist:SetPoint("BOTTOM", f, "BOTTOM", 70, 24)
    undoHist:SetText("Undo reset")
    undoHist:SetScript("OnClick", function() UndoReset() end)
    table.insert(histW, undoHist)

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
    if not ATS_DB.History then ATS_DB.History = {} end
    if ATS_DB.PromptReset == nil then ATS_DB.PromptReset = true end
    CreateConfig()
    CreateMinimapButton()
    Msg("AutoTradeSand loaded. Type /ats help")
end

local function OnTradeShow()
    tradeOpen = true
    tradeName = UnitName("NPC")
    if (not tradeName or tradeName == "") and TradeFrameRecipientNameText then
        tradeName = TradeFrameRecipientNameText:GetText()
    end
    closedSnap = nil
    snap = { name = tradeName, sand = 0 }
    if ATS_DB.AutoFill then
        FillTrade()
    end
end

local function OnTradeClosed()
    tradeOpen = false
    pending = nil
    closedSnap = snap
    snap = nil
end

----------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------
local function ShowHelp()
    Msg("/ats config - open the config window")
    Msg("/ats toggle - enable / disable auto trade")
    Msg("/ats history - show who you traded sand to")
    Msg("/ats undo - restore the history after a reset")
    Msg("/ats zone <name> - zone that asks to reset the history")
    Msg("/ats fill - fill the trade window with sand")
    Msg("/ats clear - clear your side of the trade")
    Msg("/ats <number> - sand per trade (e.g. /ats 2)")
    Msg("/ats id <itemID> - set the item ID (default 19183)")
    Msg("/ats status - show settings")
end

local function SlashHandler(text)
    local _, _, word, rest = string.find(text or "", "^(%S*)%s*(.-)$")
    word = string.lower(word or "")

    if word == "" or word == "help" then
        ShowHelp()
    elseif word == "config" or word == "options" then
        ToggleConfig()
    elseif word == "history" then
        if not ConfigFrame:IsVisible() then ConfigFrame:Show() end
        ShowTab("history")
    elseif word == "undo" then
        UndoReset()
    elseif word == "zone" then
        if rest and rest ~= "" then
            ATS_DB.ResetZone = rest
            ATS_DB.InResetZone = false
            RefreshConfig()
            Msg("History reset prompt zone set to: " .. rest)
        else
            Msg("Prompt zone: " .. (ATS_DB.ResetZone or DEFAULT_RESET_ZONE) .. " (usage: /ats zone <zone name>)")
        end
    elseif word == "spell" then
        if rest and rest ~= "" then
            ATS_DB.SpellName = rest
            Msg("Sand spell name set to: " .. rest)
        else
            Msg("Sand spell name: " .. (ATS_DB.SpellName or DEFAULT_SPELL) .. " (usage: /ats spell <spell name>)")
        end
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
frame:RegisterEvent("TRADE_ACCEPT_UPDATE")
frame:RegisterEvent("TRADE_PLAYER_ITEM_CHANGED")
frame:RegisterEvent("TRADE_TARGET_ITEM_CHANGED")
frame:RegisterEvent("UI_INFO_MESSAGE")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("CHAT_MSG_SPELL_SELF_BUFF")
frame:RegisterEvent("CHAT_MSG_SPELL_PARTY_BUFF")
frame:RegisterEvent("CHAT_MSG_SPELL_FRIENDLYPLAYER_BUFF")
frame:SetScript("OnEvent", function()
    -- vanilla passes event data through the globals "event" and "arg1"
    if event == "ADDON_LOADED" and arg1 and string.lower(arg1) == "autotradesand" then
        OnAddonLoaded()
    elseif event == "PLAYER_ENTERING_WORLD" then
        if ATS_DB and UpdateSandIcon then UpdateSandIcon() end
        if ATS_DB then ScheduleZoneCheck() end
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        if ATS_DB then ScheduleZoneCheck() end
    elseif event == "CHAT_MSG_SPELL_SELF_BUFF" or event == "CHAT_MSG_SPELL_PARTY_BUFF"
        or event == "CHAT_MSG_SPELL_FRIENDLYPLAYER_BUFF" then
        if ATS_DB then OnSpellMessage(arg1) end
    elseif event == "TRADE_SHOW" then
        if ATS_DB then OnTradeShow() end
    elseif event == "TRADE_CLOSED" then
        OnTradeClosed()
    elseif event == "TRADE_TARGET_ITEM_CHANGED" then
        -- the other player put the item in THEIR side: they are giving it to us, so take ours back
        if ATS_DB and tradeOpen and TargetOffersItem() then
            if ClearOwnItem() then
                Msg((tradeName or "The other player") .. " is offering it - removed yours from the trade")
            end
        end
    elseif event == "TRADE_ACCEPT_UPDATE" or event == "TRADE_PLAYER_ITEM_CHANGED" then
        if ATS_DB and tradeOpen then SnapshotTrade() end
    elseif event == "UI_INFO_MESSAGE" then
        if ATS_DB and arg1 and arg1 == (ERR_TRADE_COMPLETE or "Trade complete.") then
            OnTradeComplete()
        end
    end
end)

local ADDON, ns = ...

-- Raid-fanen i hovedvinduet: opprett raid, meld på med rolle, vert godkjenner,
-- og «Mine raids»-oversikt. Selvstendig (egne små UI-hjelpere).

local BACKDROP_TPL = BackdropTemplateMixin and "BackdropTemplate" or nil
local GREY, GREEN, RED, YELLOW, WHITE, BLUE =
    "|cff888888", "|cff55ff55", "|cffff5555", "|cffffd100", "|cffffffff", "|cff82c5ff"
local ROLE_TEX = {
    tank   = "Interface\\Icons\\INV_Shield_06",
    healer = "Interface\\Icons\\Spell_Holy_Renew",
    dps    = "Interface\\Icons\\INV_Sword_27",
}
local STATUS_TEXT = {
    pending  = YELLOW .. "Avventer|r",
    accepted = GREEN .. "Godkjent|r",
    declined = RED .. "Avslått|r",
}

StaticPopupDialogs = StaticPopupDialogs or {}
StaticPopupDialogs["GUILDKOMPASS_RAIDCANCEL"] = {
    text = "Avlyse %s? Alle påmeldinger forsvinner.",
    button1 = "Avlys", button2 = "Behold",
    OnAccept = function(self, data) if data and data.rid then ns.CancelRaid(data.rid) end end,
    timeout = 0, whileDead = true, hideOnEscape = true, showAlert = true,
}

local function SetBD(frame, bg, edge, edgeSize, inset)
    if not frame.SetBackdrop then return end
    frame:SetBackdrop({ bgFile = bg, edgeFile = edge, tile = true, tileSize = 32, edgeSize = edgeSize,
        insets = { left = inset, right = inset, top = inset, bottom = inset } })
end
local function Inset(parent)
    local f = CreateFrame("Frame", nil, parent, BACKDROP_TPL)
    SetBD(f, "Interface\\Tooltips\\UI-Tooltip-Background", "Interface\\Tooltips\\UI-Tooltip-Border", 14, 3)
    if f.SetBackdropColor then f:SetBackdropColor(0, 0, 0, 0.6); f:SetBackdropBorderColor(0.8, 0.65, 0.3, 0.9) end
    return f
end
local function Label(parent, text, font)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormalSmall")
    fs:SetText(text); return fs
end
local function Button(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, h or 22); b:SetText(text); return b
end
local function EditBox(parent, w, numeric)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(w, 20); e:SetAutoFocus(false)
    if numeric then e:SetNumeric(true) end
    e:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    e:SetScript("OnEnterPressed", function(s) s:ClearFocus() end)
    return e
end
local function ClassHex(class)
    local c = class and (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS or {})[class]
    if not c then return "ffffffff" end
    return string.format("ff%02x%02x%02x", c.r * 255, c.g * 255, c.b * 255)
end
local function Colored(name) return "|c" .. ClassHex(ns.ClassOf(name)) .. ns.Short(name) .. "|r" end
local function RoleIcon(role, size) return "|T" .. (ROLE_TEX[role] or ROLE_TEX.dps) .. ":" .. (size or 14) .. "|t" end

local function WhenText(when)
    if not when or when == 0 then return GREY .. "tid ikke satt|r" end
    local now = GetServerTime()
    local t = date("*t", when)
    local day = (ns.DAYS and ns.DAYS[t.wday]) or "?"
    local s = day:sub(1, 1):upper() .. day:sub(2) .. " " .. date("%d.%m %H:%M", when)
    if when > now then return s .. GREY .. "  (om " .. ns.FormatDuration(when - now) .. ")|r" end
    return YELLOW .. s .. " – nå!|r"
end

local function NextWeekday(wday, hour)
    local now = GetServerTime()
    local t = date("*t", now)
    local days = (wday - t.wday) % 7
    local target = now - (t.hour * 3600 + t.min * 60 + t.sec) + days * 86400 + hour * 3600
    if target <= now then target = target + 7 * 86400 end
    return target
end

---------------------------------------------------------------------------
-- Opprett raid-dialog
---------------------------------------------------------------------------
local createFrame
local function BuildCreate()
    if createFrame then return createFrame end
    local f = CreateFrame("Frame", "GuildKompassRaidCreate", UIParent, BACKDROP_TPL)
    f:SetSize(380, 320); f:SetFrameStrata("DIALOG"); f:SetToplevel(true); f:EnableMouse(true); f:SetMovable(true)
    f:RegisterForDrag("LeftButton"); f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetPoint("CENTER")
    SetBD(f, "Interface\\DialogFrame\\UI-DialogBox-Background", "Interface\\DialogFrame\\UI-DialogBox-Border", 32, 11)
    -- IKKE i UISpecialFrames (taint). Lukk med Avbryt/X.
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"); title:SetPoint("TOP", 0, -16); title:SetText("Opprett raid")
    CreateFrame("Button", nil, f, "UIPanelCloseButton"):SetPoint("TOPRIGHT", -4, -4)

    local l1 = Label(f, "Navn:"); l1:SetPoint("TOPLEFT", 20, -52)
    f.titleBox = EditBox(f, 230); f.titleBox:SetPoint("LEFT", l1, "RIGHT", 10, 0); f.titleBox:SetText("Molten Core")

    local l2 = Label(f, "Dag:"); l2:SetPoint("TOPLEFT", 20, -86)
    f.dayButtons = {}; f.selectedDay = 0
    local SHORT = { "I dag", "Søn", "Man", "Tir", "Ons", "Tor", "Fre", "Lør" }
    local function selDay(idx)
        f.selectedDay = idx
        for i, b in ipairs(f.dayButtons) do if (i - 1) == idx then b:LockHighlight() else b:UnlockHighlight() end end
    end
    for i = 0, 7 do
        local b = Button(f, SHORT[i + 1], 46, 20)
        if i == 0 then b:SetPoint("TOPLEFT", 54, -82)
        elseif i == 4 then b:SetPoint("TOPLEFT", 54, -104)
        else b:SetPoint("LEFT", f.dayButtons[i], "RIGHT", 2, 0) end
        b:SetScript("OnClick", function() selDay(i) end)
        f.dayButtons[i + 1] = b
    end
    local l3 = Label(f, "kl."); l3:SetPoint("TOPLEFT", 20, -132)
    f.hourBox = EditBox(f, 40, true); f.hourBox:SetPoint("LEFT", l3, "RIGHT", 8, 0); f.hourBox:SetText("20")
    Label(f, "(time 0–23)", "GameFontDisableSmall"):SetPoint("LEFT", f.hourBox, "RIGHT", 6, 0)

    local l4 = Label(f, "Størrelse:"); l4:SetPoint("TOPLEFT", 20, -164)
    f.sizeBox = EditBox(f, 40, true); f.sizeBox:SetPoint("LEFT", l4, "RIGHT", 10, 0); f.sizeBox:SetText("40")
    Label(f, "spillere", "GameFontDisableSmall"):SetPoint("LEFT", f.sizeBox, "RIGHT", 6, 0)

    local l5 = Label(f, "Notat:"); l5:SetPoint("TOPLEFT", 20, -196)
    f.noteBox = EditBox(f, 230); f.noteBox:SetPoint("LEFT", l5, "RIGHT", 10, 0)

    Label(f, "Alle i guilden ser raiden og kan melde seg på med rolle. Du godkjenner hvem som blir med.", "GameFontDisableSmall")
        :SetPoint("TOPLEFT", 20, -226)
    local hintW = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")   -- for wrap
    f:GetRegions()
    selDay(0)

    local make = Button(f, "|cff55ff55Opprett|r", 120, 24); make:SetPoint("BOTTOMLEFT", 24, 18)
    make:SetScript("OnClick", function()
        local when = 0
        if f.selectedDay ~= 0 then
            when = NextWeekday(f.selectedDay, math.max(0, math.min(23, tonumber(f.hourBox:GetText()) or 20)))
        else
            -- "I dag" kl. angitt time
            local hour = math.max(0, math.min(23, tonumber(f.hourBox:GetText()) or 20))
            local t = date("*t"); local now = GetServerTime()
            when = now - (t.hour * 3600 + t.min * 60 + t.sec) + hour * 3600
            if when < now then when = when + 86400 end
        end
        ns.CreateRaid(f.titleBox:GetText(), when, tonumber(f.sizeBox:GetText()) or 40, f.noteBox:GetText())
        f:Hide()
    end)
    local cancel = Button(f, "Avbryt", 90, 24); cancel:SetPoint("BOTTOMRIGHT", -24, 18)
    cancel:SetScript("OnClick", function() f:Hide() end)
    createFrame = f
    return f
end

---------------------------------------------------------------------------
-- Administrer-popup (vert godkjenner/avslår)
---------------------------------------------------------------------------
local manageFrame
local function BuildManage()
    if manageFrame then return manageFrame end
    local f = CreateFrame("Frame", "GuildKompassRaidManage", UIParent, BACKDROP_TPL)
    f:SetSize(420, 440); f:SetFrameStrata("DIALOG"); f:SetToplevel(true); f:EnableMouse(true); f:SetMovable(true)
    f:RegisterForDrag("LeftButton"); f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetPoint("CENTER")
    SetBD(f, "Interface\\DialogFrame\\UI-DialogBox-Background", "Interface\\DialogFrame\\UI-DialogBox-Border", 32, 11)
    -- IKKE i UISpecialFrames (taint). Lukk med Avbryt/X.
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"); f.title:SetPoint("TOP", 0, -16)
    CreateFrame("Button", nil, f, "UIPanelCloseButton"):SetPoint("TOPRIGHT", -4, -4)
    f.counts = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); f.counts:SetPoint("TOP", 0, -40)
    local inset = Inset(f); inset:SetPoint("TOPLEFT", 16, -58); inset:SetPoint("BOTTOMRIGHT", -16, 16)
    f.rows = {}
    for i = 1, 15 do
        local row = CreateFrame("Frame", nil, inset); row:SetHeight(24)
        row:SetPoint("TOPLEFT", 8, -8 - (i - 1) * 25); row:SetPoint("RIGHT", -8, 0)
        row.icon = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); row.icon:SetPoint("LEFT", 2, 0)
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); row.name:SetPoint("LEFT", 24, 0); row.name:SetWidth(150); row.name:SetJustifyH("LEFT")
        row.status = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); row.status:SetPoint("LEFT", 176, 0); row.status:SetWidth(80); row.status:SetJustifyH("LEFT")
        row.ok = Button(row, "✓", 26, 20); row.ok:SetPoint("RIGHT", -62, 0)
        row.no = Button(row, "✗", 26, 20); row.no:SetPoint("RIGHT", -32, 0)
        row:Hide(); f.rows[i] = row
    end
    f.empty = inset:CreateFontString(nil, "OVERLAY", "GameFontDisable"); f.empty:SetPoint("CENTER", 0, 0); f.empty:SetText("Ingen påmeldte ennå.")
    manageFrame = f
    return f
end

local function RefreshManage()
    local f = manageFrame
    if not f or not f:IsShown() or not f.rid then return end
    local r = ns.db and ns.db.raids[f.rid]
    if not r then f:Hide(); return end
    f.title:SetText("Administrer: " .. (r.title or "Raid"))
    local c = ns.RaidCounts(f.rid)
    f.counts:SetText(string.format("%s%d|r  %s%d|r  %s%d|r   ·   %s godkjent / %d påmeldt",
        RoleIcon("tank"), c.tank, RoleIcon("healer"), c.healer, RoleIcon("dps"), c.dps, GREEN .. c.accepted, c.total))
    local sign = ns.RaidSignups(f.rid)
    for i, row in ipairs(f.rows) do
        local s = sign[i]
        if s then
            row.icon:SetText(RoleIcon(s.role, 16))
            row.name:SetText(Colored(s.name))
            row.status:SetText(STATUS_TEXT[s.status or "pending"] or "")
            row.ok:SetScript("OnClick", function() ns.SetRaidDecision(f.rid, s.name, true); RefreshManage() end)
            row.no:SetScript("OnClick", function() ns.SetRaidDecision(f.rid, s.name, false); RefreshManage() end)
            row:Show()
        else row:Hide() end
    end
    f.empty:SetShown(#sign == 0)
end

local function OpenManage(rid)
    local f = BuildManage()
    f.rid = rid
    f:Show()
    RefreshManage()
end

---------------------------------------------------------------------------
-- Raid-fanen
---------------------------------------------------------------------------
local RAID_SLOTS = 3
local panelRef

function ns.BuildRaidPanel(parent, anchor)
    if panelRef then return panelRef end
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetPoint("TOPLEFT", anchor, "TOPLEFT", 6, -6)
    panel:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", -6, 6)
    panel:Hide()
    panelRef = panel

    local create = Button(panel, "|cff55ff55+ Opprett raid|r", 150, 24); create:SetPoint("TOPLEFT", 4, -4)
    create:SetScript("OnClick", function() BuildCreate():Show() end)
    Label(panel, "Meld deg på med rolle – verten godkjenner, og raiden havner i «Mine raids».", "GameFontDisableSmall")
        :SetPoint("LEFT", create, "RIGHT", 12, 0)

    -- Venstre: kommende raids
    Label(panel, "Kommende raids", "GameFontNormal"):SetPoint("TOPLEFT", 6, -40)
    local inset = Inset(panel); inset:SetPoint("TOPLEFT", 4, -60); inset:SetWidth(560); inset:SetPoint("BOTTOM", panel, "BOTTOM", 0, 4)
    panel.cards = {}
    for i = 1, RAID_SLOTS do
        local card = CreateFrame("Frame", nil, inset, BACKDROP_TPL)
        card:SetPoint("TOPLEFT", 8, -8 - (i - 1) * 118); card:SetPoint("RIGHT", inset, "RIGHT", -8, 0); card:SetHeight(110)
        SetBD(card, "Interface\\Tooltips\\UI-Tooltip-Background", "Interface\\Tooltips\\UI-Tooltip-Border", 12, 3)
        if card.SetBackdropColor then card:SetBackdropColor(0.1, 0.08, 0.06, 0.8); card:SetBackdropBorderColor(0.6, 0.5, 0.3, 0.8) end
        card.title = card:CreateFontString(nil, "OVERLAY", "GameFontNormal"); card.title:SetPoint("TOPLEFT", 10, -8); card.title:SetPoint("RIGHT", card, "RIGHT", -10, 0); card.title:SetJustifyH("LEFT"); card.title:SetWordWrap(false)
        card.when = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); card.when:SetPoint("TOPLEFT", 10, -26); card.when:SetJustifyH("LEFT")
        card.counts = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); card.counts:SetPoint("TOPLEFT", 10, -44); card.counts:SetJustifyH("LEFT")
        card.mystatus = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"); card.mystatus:SetPoint("TOPLEFT", 10, -62); card.mystatus:SetJustifyH("LEFT")
        -- påmeldings-knapper
        card.tank = Button(card, "Tank", 60, 20); card.tank:SetPoint("BOTTOMLEFT", 8, 8)
        card.heal = Button(card, "Healer", 64, 20); card.heal:SetPoint("LEFT", card.tank, "RIGHT", 4, 0)
        card.dps = Button(card, "DPS", 54, 20); card.dps:SetPoint("LEFT", card.heal, "RIGHT", 4, 0)
        card.leave = Button(card, "Meld av", 72, 20); card.leave:SetPoint("LEFT", card.dps, "RIGHT", 10, 0)
        card.manage = Button(card, "Administrer", 90, 20); card.manage:SetPoint("BOTTOMRIGHT", -8, 8)
        card.cancel = Button(card, "Avlys", 58, 20); card.cancel:SetPoint("RIGHT", card.manage, "LEFT", -6, 0)
        card:Hide(); panel.cards[i] = card
    end
    panel.more = inset:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"); panel.more:SetPoint("BOTTOM", 0, 6)
    panel.empty = inset:CreateFontString(nil, "OVERLAY", "GameFontDisable"); panel.empty:SetPoint("CENTER", 0, 10)
    panel.empty:SetText("Ingen raids ennå.\nTrykk «+ Opprett raid».")

    -- Høyre: Mine raids (kalender)
    Label(panel, "|cffffd100Mine raids|r", "GameFontNormal"):SetPoint("TOPLEFT", inset, "TOPRIGHT", 16, 14)
    local myInset = Inset(panel); myInset:SetPoint("TOPLEFT", inset, "TOPRIGHT", 16, -4); myInset:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -2, 4)
    panel.myRows = {}
    for i = 1, 10 do
        local row = CreateFrame("Frame", nil, myInset); row:SetHeight(34)
        row:SetPoint("TOPLEFT", 8, -8 - (i - 1) * 36); row:SetPoint("RIGHT", -8, 0)
        local bg = row:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetColorTexture(1, 0.82, 0, (i % 2 == 0) and 0.05 or 0)
        row.title = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); row.title:SetPoint("TOPLEFT", 4, -2); row.title:SetJustifyH("LEFT")
        row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"); row.sub:SetPoint("TOPLEFT", 4, -17); row.sub:SetJustifyH("LEFT")
        row:Hide(); panel.myRows[i] = row
    end
    panel.myEmpty = myInset:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"); panel.myEmpty:SetPoint("CENTER", 0, 0)
    panel.myEmpty:SetText("Du er ikke påmeldt noen raids.")
    return panel
end

function ns.UpdateRaidPanel()
    local panel = panelRef
    if not panel or not panel:IsShown() then return end
    ns.EnsureRaids()
    local me = ns.PlayerName()
    local list = ns.RaidList()
    for i, card in ipairs(panel.cards) do
        local r = list[i]
        if r then
            local canManage = ns.IsMe(r.host) or ns.IsOfficer(me)
            local canCancel = ns.IsMe(r.host) or ns.IsGM(me)
            card.title:SetText(YELLOW .. (r.title ~= "" and r.title or "Raid") .. "|r"
                .. GREY .. "  · vert " .. ns.Short(r.host) .. (r.size and r.size > 0 and ("  · " .. r.size .. " plasser") or "") .. "|r")
            card.when:SetText(WhenText(r.when) .. (r.note and r.note ~= "" and (GREY .. "   · " .. r.note .. "|r") or ""))
            local c = ns.RaidCounts(r.rid)
            card.counts:SetText(string.format("%s%d  %s%d  %s%d    %s%d godkjent|r %s/ %d påmeldt|r",
                RoleIcon("tank"), c.tank, RoleIcon("healer"), c.healer, RoleIcon("dps"), c.dps,
                GREEN, c.accepted, GREY, c.total))
            local mine = ns.MyRaidSign(r.rid)
            if mine and mine.joined then
                card.mystatus:SetText("Du: " .. RoleIcon(mine.role, 12) .. " " .. (ns.RAID_ROLE_LABEL[mine.role] or mine.role)
                    .. "  —  " .. (STATUS_TEXT[mine.status or "pending"] or ""))
            else
                card.mystatus:SetText(GREY .. "Ikke påmeldt – velg rolle:|r")
            end
            local function mk(btn, role)
                btn:SetScript("OnClick", function() ns.SignRaid(r.rid, role) end)
                if mine and mine.joined and mine.role == role then btn:LockHighlight() else btn:UnlockHighlight() end
            end
            mk(card.tank, "tank"); mk(card.heal, "healer"); mk(card.dps, "dps")
            card.leave:SetShown(mine and mine.joined)
            card.leave:SetScript("OnClick", function() ns.UnsignRaid(r.rid) end)
            card.manage:SetShown(canManage)
            card.manage:SetScript("OnClick", function() OpenManage(r.rid) end)
            card.cancel:SetShown(canCancel)
            card.cancel:SetScript("OnClick", function()
                StaticPopup_Show("GUILDKOMPASS_RAIDCANCEL", r.title ~= "" and r.title or "raiden", nil, { rid = r.rid })
            end)
            card:Show()
        else
            card:Hide()
        end
    end
    panel.empty:SetShown(#list == 0)
    panel.more:SetText(#list > RAID_SLOTS and (GREY .. "+ " .. (#list - RAID_SLOTS) .. " flere raids|r") or "")

    -- Mine raids
    local mine = ns.MyRaids()
    for i, row in ipairs(panel.myRows) do
        local it = mine[i]
        if it then
            row.title:SetText(YELLOW .. (it.raid.title ~= "" and it.raid.title or "Raid") .. "|r")
            local st = STATUS_TEXT[it.sign.status or "pending"] or ""
            row.sub:SetText(RoleIcon(it.sign.role, 12) .. " " .. st .. GREY .. "  ·  " .. WhenText(it.raid.when) .. "|r")
            row:Show()
        else row:Hide() end
    end
    panel.myEmpty:SetShown(#mine == 0)
    if manageFrame and manageFrame:IsShown() then RefreshManage() end
end

function ns.ShowRaidPanel(show)
    if not panelRef then return end
    panelRef:SetShown(show)
    if show then ns.UpdateRaidPanel() end
end

local ADDON, ns = ...

-- Death Roll-arena (eget popup-vindu) + Events-fanen i hovedvinduet.
local A = ns.Anim

local BACKDROP_TPL = BackdropTemplateMixin and "BackdropTemplate" or nil
local GREY, GREEN, RED, YELLOW, WHITE = "|cff888888", "|cff55ff55", "|cffff5555", "|cffffd100", "|cffffffff"
local BLUE = "|cff82c5ff"
local TEX_SKULL = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8"
local TEX_CROWN = "Interface\\GroupFrame\\UI-Group-LeaderIcon"
local TEX_CLASSES = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes"

---------------------------------------------------------------------------
-- Felleshjelpere
---------------------------------------------------------------------------
local function SetBD(frame, bg, edge, edgeSize, inset)
    if not frame.SetBackdrop then return end
    frame:SetBackdrop({ bgFile = bg, edgeFile = edge, tile = true, tileSize = 32, edgeSize = edgeSize,
        insets = { left = inset, right = inset, top = inset, bottom = inset } })
end

local function ClassHex(class)
    local c = class and (CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS)[class]
    if not c then return "ffffffff" end
    return string.format("ff%02x%02x%02x", math.floor(c.r * 255), math.floor(c.g * 255), math.floor(c.b * 255))
end

local function ClassIcon(class, size)
    local c = class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
    if not c then return "" end
    return string.format("|T%s:%d:%d:0:0:256:256:%d:%d:%d:%d|t", TEX_CLASSES, size, size,
        math.floor(c[1] * 256 + 0.5), math.floor(c[2] * 256 + 0.5), math.floor(c[3] * 256 + 0.5), math.floor(c[4] * 256 + 0.5))
end

local function Colored(name)
    return "|c" .. ClassHex(ns.ClassOf(name)) .. ns.Short(name) .. "|r"
end

local function Gold(copper) return ns.FormatMoney(copper) end

-- Ren tekst uten mynt-ikoner, til redigeringsfelt (f.eks. "10g50s")
local function PlainMoney(copper)
    copper = math.floor(copper or 0)
    local g = math.floor(copper / 10000)
    local s = math.floor(copper / 100) % 100
    local c = copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "g" end
    if s > 0 then parts[#parts + 1] = s .. "s" end
    if c > 0 then parts[#parts + 1] = c .. "c" end
    return #parts > 0 and table.concat(parts) or "0"
end

local function Inset(parent)
    local f = CreateFrame("Frame", nil, parent, BACKDROP_TPL)
    SetBD(f, "Interface\\Tooltips\\UI-Tooltip-Background", "Interface\\Tooltips\\UI-Tooltip-Border", 14, 3)
    if f.SetBackdropColor then
        f:SetBackdropColor(0, 0, 0, 0.65)
        f:SetBackdropBorderColor(0.8, 0.65, 0.3, 0.9)
    end
    return f
end

local function Label(parent, text, font)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormalSmall")
    fs:SetText(text)
    return fs
end

local function EditBox(parent, w, numeric)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(w, 20)
    e:SetAutoFocus(false)
    if numeric then e:SetNumeric(true) end
    e:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    e:SetScript("OnEnterPressed", function(s) s:ClearFocus() end)
    return e
end

local function Button(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, h or 22)
    b:SetText(text)
    return b
end

local function WhenText(e)
    if not e.when or e.when == 0 then return GREY .. "når som helst|r" end
    local now = GetServerTime()
    local t = date("*t", e.when)
    local day = ns.DAYS[t.wday] or "?"
    local s = day:sub(1, 1):upper() .. day:sub(2) .. " " .. date("%H:%M", e.when)
    if e.when > now then
        return s .. GREY .. "  (om " .. ns.FormatDuration(e.when - now) .. ")|r"
    end
    return YELLOW .. s .. " – pågår nå!|r"
end

---------------------------------------------------------------------------
-- Enkel tabell (brukes til toppliste/historikk)
---------------------------------------------------------------------------
local function MakeTable(parent, cols, topOffset, rows, rowH)
    rows = rows or 15; rowH = rowH or 20
    local inset = Inset(parent)
    inset:SetPoint("TOPLEFT", 0, -topOffset)
    inset:SetPoint("BOTTOMRIGHT", 0, 0)
    local t = { inset = inset, cols = cols, rows = {}, offset = 0, data = {}, ROWS = rows }
    local x = 8
    for _, c in ipairs(cols) do
        local h = inset:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h:SetPoint("TOPLEFT", x, -8)
        h:SetWidth(c.w - 6)
        h:SetJustifyH(c.right and "RIGHT" or "LEFT")
        h:SetText(c.title)
        c.x = x
        x = x + c.w
    end
    local line = inset:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 0.82, 0, 0.3)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", 6, -24); line:SetPoint("TOPRIGHT", -6, -24)
    for i = 1, rows do
        local row = CreateFrame("Frame", nil, inset)
        row:SetHeight(rowH)
        row:SetPoint("TOPLEFT", 4, -28 - (i - 1) * rowH)
        row:SetPoint("RIGHT", -4, 0)
        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(1, 0.82, 0, (i % 2 == 0) and 0.045 or 0)
        row.bg = bg
        row.cells = {}
        for j, c in ipairs(cols) do
            local fs = row:CreateFontString(nil, "OVERLAY", c.big and "GameFontHighlight" or "GameFontHighlightSmall")
            fs:SetPoint("LEFT", c.x - 4, 0)
            fs:SetWidth(c.w - 6)
            fs:SetJustifyH(c.right and "RIGHT" or "LEFT")
            fs:SetWordWrap(false)
            row.cells[j] = fs
        end
        t.rows[i] = row
    end
    inset:EnableMouseWheel(true)
    inset:SetScript("OnMouseWheel", function(_, delta)
        t.offset = math.max(0, math.min(math.max(0, #t.data - rows), t.offset - delta * 3))
        t:Render()
    end)
    t.empty = inset:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
    t.empty:SetPoint("CENTER", 0, -10)
    function t:Render()
        if self.offset > math.max(0, #self.data - self.ROWS) then self.offset = math.max(0, #self.data - self.ROWS) end
        for i = 1, self.ROWS do
            local row = self.rows[i]
            local item = self.data[i + self.offset]
            if item then
                for j, c in ipairs(self.cols) do row.cells[j]:SetText(c.text(item, i + self.offset)) end
                if item.highlight then row.bg:SetColorTexture(0.3, 0.6, 1, 0.15)
                else row.bg:SetColorTexture(1, 0.82, 0, (i % 2 == 0) and 0.045 or 0) end
                row:Show()
            else
                row:Hide()
            end
        end
        self.empty:SetShown(#self.data == 0)
    end
    return t
end

local RANK_COLORS = { "|cffffd100", "|cffc0c0c0", "|cffcd7f32" }

local function LeaderboardCols(compact)
    local cols = {
        { title = "#", w = 30, text = function(s, i)
            local c = RANK_COLORS[i] or WHITE
            return (i == 1 and ("|T" .. TEX_CROWN .. ":12|t") or "") .. c .. i .. "|r"
          end },
        { title = "Spiller", w = compact and 120 or 150, big = true, text = function(s)
            return ClassIcon(ns.ClassOf(s.name), 14) .. " " .. Colored(s.name)
          end },
        { title = compact and "1v1" or "1v1 (S/T)", w = compact and 52 or 74, right = true, text = function(s)
            return GREEN .. (s.w1 or 0) .. "|r" .. GREY .. "/|r" .. RED .. (s.l1 or 0) .. "|r"
          end },
        { title = compact and "Turn." or "Turn. (S/T)", w = compact and 52 or 82, right = true, text = function(s)
            return GREEN .. (s.wt or 0) .. "|r" .. GREY .. "/|r" .. RED .. (s.lt or 0) .. "|r"
          end },
        { title = "Netto", w = compact and 84 or 110, right = true, text = function(s)
            if s.net == 0 then return GREY .. "–|r" end
            return (s.net > 0 and GREEN .. "+" or RED) .. Gold(s.net) .. "|r"
          end },
    }
    if not compact then
        table.insert(cols, { title = "Vunnet", w = 90, right = true, text = function(s) return s.won > 0 and Gold(s.won) or (GREY .. "–|r") end })
        table.insert(cols, { title = "Største", w = 88, right = true, text = function(s) return s.best > 0 and Gold(s.best) or (GREY .. "–|r") end })
    end
    return cols
end

---------------------------------------------------------------------------
-- Invitasjon (popup)
---------------------------------------------------------------------------
StaticPopupDialogs["GUILDKOMPASS_DR_INVITE"] = {
    text = "%s",
    button1 = "Godta",
    button2 = "Avslå",
    OnAccept = function(self, data) ns.Accept(data) end,
    OnCancel = function(self, data, reason) if reason == "clicked" or reason == "timeout" then ns.Decline(data) end end,
    timeout = 60, whileDead = true, hideOnEscape = true, showAlert = true, preferredIndex = 3,
}

function ns.ShowInvite(d)
    local txt = string.format("|cffff4040DEATH ROLL!|r\n\n%s utfordrer deg om |cffffd100%s|r\n(start på %d)",
        Colored(d.a), d.amount > 0 and Gold(d.amount) or "ære og berømmelse", d.start)
    StaticPopup_Show("GUILDKOMPASS_DR_INVITE", txt, nil, d.id)
    ns.Sound("IG_PLAYER_INVITE")
end

function ns.HideInvite() StaticPopup_Hide("GUILDKOMPASS_DR_INVITE") end

-- Velg buy-in når turneringen startes
local function getEB(self) return self.editBox or (self.GetEditBox and self:GetEditBox()) end
local function doStart(data, text)
    local copper = ns.ParseMoney(text or "") or 0
    ns.StartTournament(data.eventId, math.max(0, copper))
end
StaticPopupDialogs["GUILDKOMPASS_TSTART"] = {
    text = "Buy-in per spiller  (f.eks. 10g, 50s eller 10g50s)\nVinneren tar hele potten.",
    button1 = "Start turnering",
    button2 = "Avbryt",
    hasEditBox = true,
    maxLetters = 16,
    OnShow = function(self, data)
        local eb = getEB(self)
        if eb then eb:SetText(PlainMoney((data and data.copper) or 0)); eb:HighlightText(); eb:SetFocus() end
    end,
    OnAccept = function(self, data)
        local eb = getEB(self)
        doStart(data, eb and eb:GetText())
    end,
    EditBoxOnEnterPressed = function(self)
        local parent = self:GetParent()
        doStart(parent.data, self:GetText())
        parent:Hide()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs["GUILDKOMPASS_RESETWEEK"] = {
    text = "Nullstille UKES-toppliste for hele guilden?\n(Sesongtabellen beholdes.)",
    button1 = "Nullstill uke", button2 = "Avbryt",
    OnAccept = function() ns.ResetWeek() end,
    timeout = 0, whileDead = true, hideOnEscape = true, showAlert = true, preferredIndex = 3,
}
StaticPopupDialogs["GUILDKOMPASS_RESETSEASON"] = {
    text = "Starte NY SESONG? Hele topplista nullstilles for alle.",
    button1 = "Ny sesong", button2 = "Avbryt",
    OnAccept = function() ns.ResetSeason() end,
    timeout = 0, whileDead = true, hideOnEscape = true, showAlert = true, preferredIndex = 3,
}

---------------------------------------------------------------------------
-- ARENA-VINDU
---------------------------------------------------------------------------
local Arena = {}
ns.Arena = Arena

local function Plate(parent)
    local p = CreateFrame("Frame", nil, parent, BACKDROP_TPL)
    p:SetSize(190, 70)
    SetBD(p, "Interface\\Tooltips\\UI-Tooltip-Background", "Interface\\Tooltips\\UI-Tooltip-Border", 14, 3)
    if p.SetBackdropColor then p:SetBackdropColor(0.08, 0.05, 0.05, 0.9) end
    p.glow = p:CreateTexture(nil, "BACKGROUND", nil, 2)
    p.glow:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    p.glow:SetBlendMode("ADD")
    p.glow:SetPoint("TOPLEFT", 4, -4); p.glow:SetPoint("BOTTOMRIGHT", -4, 4)
    p.glow:SetVertexColor(1, 0.8, 0.2)
    p.glow:Hide()
    p.name = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    p.name:SetPoint("TOP", 0, -12)
    p.sub = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.sub:SetPoint("TOP", p.name, "BOTTOM", 0, -6)
    return p
end

function Arena:CreateArena(f)
    local panel = CreateFrame("Frame", nil, f)
    panel:SetPoint("TOPLEFT", 16, -40)
    panel:SetPoint("BOTTOMRIGHT", -16, 14)
    self.panels.arena = panel
    self.arena = panel

    -- (Ingen invitér-/opprett-rad her: nye kamper lages via «+ Lag event».
    --  Match-visningen er bare selve rullen.)

    local stage = Inset(panel)
    stage:SetPoint("TOPLEFT", 0, -6); stage:SetPoint("BOTTOMRIGHT", 0, 6)
    panel.stage = stage
    local bg = stage:CreateTexture(nil, "BACKGROUND", nil, 1)
    bg:SetTexture(TEX_SKULL); bg:SetSize(220, 220); bg:SetPoint("CENTER", 0, 10); bg:SetAlpha(0.05)

    panel.left = Plate(stage);  panel.left:SetPoint("LEFT", 24, 40)
    panel.right = Plate(stage); panel.right:SetPoint("RIGHT", -24, 40)

    local numFrame = CreateFrame("Frame", nil, stage); numFrame:SetSize(200, 90); numFrame:SetPoint("CENTER", 0, 50)
    panel.numFrame = numFrame
    local num = numFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    local font = GameFontNormalHuge and GameFontNormalHuge:GetFont()
    if font then num:SetFont(font, 54, "THICKOUTLINE") end
    num:SetPoint("CENTER"); num:SetText("–")
    panel.num = num
    local maxLbl = stage:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    maxLbl:SetPoint("TOP", numFrame, "BOTTOM", 0, 2)
    panel.maxLbl = maxLbl
    local vs = stage:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    vs:SetPoint("BOTTOM", numFrame, "TOP", 0, 2); vs:SetText("VS"); vs:SetTextColor(0.8, 0.2, 0.2)
    local status = stage:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    status:SetPoint("TOP", maxLbl, "BOTTOM", 0, -14)
    panel.status = status
    local roll = Button(stage, "|cffffd100ROLL!|r", 180, 38); roll:SetPoint("TOP", status, "BOTTOM", 0, -12)
    local rfs = roll:GetFontString(); if rfs and font then rfs:SetFont(font, 20, "OUTLINE") end
    roll:SetScript("OnClick", function() ns.DoRoll() end); roll:Hide()
    panel.roll = roll
    local give = Button(stage, "Gi opp", 80, 20); give:SetPoint("BOTTOMRIGHT", -10, 10)
    give:SetScript("OnClick", function() ns.Forfeit() end); give:Hide()
    panel.give = give
    local joinb = Button(stage, "|cff55ff55Bli med!|r", 180, 38); joinb:SetPoint("TOP", status, "BOTTOM", 0, -12)
    local jfs = joinb:GetFontString(); if jfs and font then jfs:SetFont(font, 20, "OUTLINE") end
    joinb:SetScript("OnClick", function()
        local d = Arena:CurrentDuel()
        if d then ns.JoinOpen(d.id) end
    end); joinb:Hide()
    panel.joinBtn = joinb
    local chain = stage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    chain:SetPoint("BOTTOMLEFT", 14, 14); chain:SetPoint("RIGHT", give, "LEFT", -10, 0)
    chain:SetJustifyH("LEFT"); chain:SetWordWrap(false)
    panel.chain = chain
    -- (Ingen gjeld/annonse-rad her lenger – det bor i Death Roll-fanen.)
end

local function ChainText(d)
    if not d then return "" end
    local parts = { GREY .. d.start .. "|r" }
    for _, r in ipairs(d.rolls) do
        local c = "|c" .. ClassHex(ns.ClassOf(r.who))
        local v = (r.value <= 1) and (RED .. "1|r") or (c .. r.value .. "|r")
        parts[#parts + 1] = v .. (r.verified and "" or GREY .. "*|r")
    end
    local s = table.concat(parts, GREY .. "  →  |r")
    if #s > 400 then s = "… " .. s:sub(-400) end
    return s
end

-- Hvilket rom (duell) vises nå
function Arena:CurrentDuel()
    local function live(x)
        return x and (x.state == "invite" or x.state == "active" or x.state == "open"
            or (x.state == "done" and GetTime() - (x.lastAct or 0) < 25))
    end
    -- det eksplisitt valgte rommet har forrang (så man kan se på en bestemt kamp)
    local d = self.selectedDuelId and ns.duels[self.selectedDuelId]
    if live(d) then return d end
    -- ellers min egen pågående kamp
    local mine = ns.MyActiveDuel()
    if mine then self.selectedDuelId = mine.id; return mine end
    -- ingen valgt og ingen egen kamp → tomt (IKKE vis en gammel/annens kamp)
    self.selectedDuelId = nil
    return nil
end

-- Rom-bytter fjernet: man er låst til rommet man gikk inn på. For å se et annet,
-- går man ut og inn via det aktuelle eventet.
function Arena:RenderRooms()
    local bar = self.arena.roomBar
    if bar then
        for _, b in ipairs(bar.btns or {}) do b:Hide() end
        bar:Hide()
    end
end

function Arena:UpdateArena()
    local p = self.arena
    self:RenderRooms()
    local d = self:CurrentDuel()
    local mine = d and (ns.IsMe(d.a) or ns.IsMe(d.b))

    if not d then
        p.left.name:SetText(GREY .. "?|r"); p.left.sub:SetText("")
        p.right.name:SetText(GREY .. "?|r"); p.right.sub:SetText("")
        if not p.num.spinTween then p.num:SetText("–"); p.num:SetTextColor(1, 0.82, 0) end
        p.maxLbl:SetText("")
        p.status:SetText(GREY .. "Ingen aktiv kamp. Lag en i Death Roll-fanen.|r")
        p.roll:Hide(); p.give:Hide(); p.joinBtn:Hide(); p.chain:SetText("")
        p.left.glow:Hide(); p.right.glow:Hide()
    else
        local isOpen = d.state == "open"
        local waiting = (d.state == "invite") or isOpen
        p.left.name:SetText(ClassIcon(ns.ClassOf(d.a), 18) .. " " .. Colored(d.a))
        if not d.b then
            p.right.name:SetText(GREY .. "venter på motstander …|r")
        elseif waiting then
            p.right.name:SetText(GREY .. "venter på " .. ns.Short(d.b) .. " …|r")
        else
            p.right.name:SetText(Colored(d.b) .. " " .. ClassIcon(ns.ClassOf(d.b), 18))
        end
        p.left.sub:SetText(ns.IsMe(d.a) and YELLOW .. "deg|r" or "")
        p.right.sub:SetText((d.b and ns.IsMe(d.b)) and YELLOW .. "deg|r" or "")
        local active = d.state == "active"
        p.left.glow:SetShown(active and ns.Key(d.turn) == ns.Key(d.a))
        p.right.glow:SetShown(active and d.b and ns.Key(d.turn) == ns.Key(d.b))
        if not p.num.spinTween and not p.holdNumber then
            local last = d.rolls[#d.rolls]
            p.num:SetText(last and tostring(last.value) or tostring(d.start))
            if d.max <= 10 and active then p.num:SetTextColor(1, 0.25, 0.25) else p.num:SetTextColor(1, 0.82, 0) end
        end
        p.maxLbl:SetText(active and ("neste kast: 1 – " .. d.max) or ("innsats " .. (d.amount > 0 and Gold(d.amount) or "ingen")))
        p.chain:SetText(ChainText(d))
        local myTurn = active and ns.IsMe(d.turn)
        if isOpen then
            p.status:SetText(ns.IsMe(d.a)
                and (YELLOW .. "Åpen 1v1 – venter på motstander …|r")
                or (Colored(d.a) .. " har åpnet en 1v1 – bli med!"))
        elseif d.state == "invite" then
            p.status:SetText(ns.IsMe(d.a) and ("Venter på at " .. Colored(d.b) .. " godtar …")
                or (Colored(d.a) .. " utfordrer " .. Colored(d.b) .. " …"))
        elseif myTurn then
            p.status:SetText(YELLOW .. "DIN TUR!|r")
        elseif active then
            p.status:SetText("Venter på " .. Colored(d.turn) .. " …")
        elseif d.state == "done" and not p.holdNumber then
            p.status:SetText(Colored(d.winner) .. YELLOW .. " vant " .. (d.amount > 0 and Gold(d.amount) or "") .. "!|r"
                .. (d.forfeit and (GREY .. "  (" .. ns.Short(d.loser) .. " ga opp)|r") or ""))
        elseif d.state == "declined" then
            p.status:SetText(GREY .. (d.b and ns.Short(d.b) or "Motstander") .. " avslo.|r")
        elseif d.state == "cancelled" then
            p.status:SetText(GREY .. "Utfordringen ble trukket tilbake.|r")
        end
        p.roll:SetShown(myTurn and not p.num.spinTween)
        -- «Bli med» når det er en åpen kamp jeg ikke har laget
        p.joinBtn:SetShown(isOpen and not ns.IsMe(d.a) and not ns.MyActiveDuel())
        if myTurn then A.StartPulse(p.status, 0.4, 1, 6) else A.StopPulse(p.status) end
        p.give:SetShown(mine and (d.state == "active" or d.state == "invite" or isOpen))
        p.give:SetText((d.state == "invite" or isOpen) and "Trekk" or "Gi opp")
    end
end

-- Animasjons-kroker (fra Core/DeathRoll)
function ns.OnDuelStart(d)
    local mineInvolved = ns.IsMe(d.a) or ns.IsMe(d.b)
    -- Velg rommet bare hvis det er min egen kamp, eller jeg ikke alt følger en
    -- pågående kamp (så en 1v1 ikke overstyrer turneringskampen du ser på).
    local cur = Arena.selectedDuelId and ns.duels[Arena.selectedDuelId]
    local curLive = cur and (cur.state == "active" or cur.state == "invite")
    if mineInvolved or not curLive then Arena.selectedDuelId = d.id end
    local shown = Arena.frame and Arena.frame:IsShown()
    -- Åpne automatisk hvis det er min kamp, arenaen alt er oppe, eller «se på» er
    -- på for en turneringskamp (og jeg ikke alt følger en annen pågående kamp).
    local watch = ns.global and ns.global.watch
    if mineInvolved or shown or (watch and d.tid and not curLive) then
        ns.ShowMatch(d.id)
        if Arena:CurrentDuel() == d and Arena.arena then A.Pop(Arena.arena.numFrame, 2.2) end
        ns.Sound("READY_CHECK")
    end
    if Arena.frame and Arena.frame:IsShown() then Arena:Update() end
end

-- Vis rulle-visningen låst til én bestemt kamp (gjen-inngang).
function ns.FocusArenaDuel(duelId)
    ns.ShowMatch(duelId)
end

-- Åpne arenaen fokusert på den gjeldende turneringskampen (start eller tilskuer).
function ns.OpenArenaOnTournament(tid)
    if not ns.db or not ns.db.tournaments[tid] then return end
    local id = ns.CurrentTournamentDuelId and ns.CurrentTournamentDuelId(tid)
    ns.FocusArenaDuel(id)
end

function ns.OnRoll(d, who, value, max)
    if not Arena.frame or not Arena.frame:IsShown() or Arena:CurrentDuel() ~= d then Arena:Update() return end
    local p = Arena.arena
    p.holdNumber = true
    p.roll:Hide()
    p.num:SetTextColor(1, 0.82, 0)
    A.Spin(p.num, max, value, value <= 1 and 1.9 or 1.2, function()
        p.holdNumber = false
        A.Pop(p.numFrame, value <= 1 and 2.6 or 1.7)
        if value <= 1 then
            p.num:SetTextColor(1, 0.15, 0.15); A.Shake(Arena.frame, 10, 0.6)
        elseif value <= 10 then
            p.num:SetTextColor(1, 0.25, 0.25); A.Shake(Arena.frame, 5, 0.35); ns.Sound("RAID_WARNING")
        else
            p.num:SetTextColor(1, 0.82, 0)
        end
        if p.pendingFinish then
            local fd = p.pendingFinish; p.pendingFinish = nil
            Arena:FinishVisuals(fd)
        end
        Arena:Update()
    end)
end

function ns.OnFinish(d)
    if not Arena.frame or not Arena.frame:IsShown() or Arena:CurrentDuel() ~= d then
        if Arena.frame and Arena.frame:IsShown() then Arena:Update() end
        return
    end
    if Arena.arena.holdNumber then Arena.arena.pendingFinish = d else Arena:FinishVisuals(d) end
end

function Arena:FinishVisuals(d)
    local p = self.arena
    local winPlate = ns.Key(d.winner) == ns.Key(d.a) and p.left or p.right
    local losePlate = winPlate == p.left and p.right or p.left
    A.Skull(p.stage, losePlate, 90)
    A.Coins(p.stage, d.amount > 0 and 30 or 14, winPlate)
    A.Pop(winPlate, 1.4)
    if d.amount > 0 then A.FloatText(p.stage, winPlate, "+" .. math.floor(d.amount / 10000) .. "g", 1, 0.82, 0) end
    if ns.IsMe(d.winner) then
        ns.Sound("LOOT_WINDOW_COIN_SOUND"); A.FloatText(p.stage, p.numFrame, "VINNER!", 0.3, 1, 0.3)
    elseif ns.IsMe(d.loser) then
        ns.Sound("RAID_WARNING"); A.FloatText(p.stage, p.numFrame, "DØD!", 1, 0.2, 0.2)
    end
    self:Update()
end

---------------------------------------------------------------------------
-- Match-visning: et lite eget vindu med BARE rullen. Åpnes når du spiller
-- eller ser en kamp. Oppretting av kamper skjer i Death Roll-fanen.
---------------------------------------------------------------------------
function Arena:Mount()
    if self.frame then return end
    local f = CreateFrame("Frame", "GuildKompassMatch", UIParent, BACKDROP_TPL)
    self.frame = f
    f:SetSize(560, 420)
    f:SetScale((ns.global and ns.global.arenaScale) or 1)
    f:SetFrameStrata("HIGH"); f:SetToplevel(true); f:SetMovable(true); f:EnableMouse(true)
    f:SetClampedToScreen(true); f:RegisterForDrag("LeftButton")
    local pos = ns.global and ns.global.arenaPos
    if pos then f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else f:SetPoint("CENTER", 60, 40) end
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(s)
        s:StopMovingOrSizing()
        local p, _, rp, x, y = s:GetPoint()
        if ns.global then ns.global.arenaPos = { p, rp, x, y } end
    end)
    -- MERK: vi legger IKKE vinduet i UISpecialFrames. Å skrive til den tabellen
    -- fra addon-kode tainter ESC-håndteringen (SpellStopCasting/SpellStopTargeting)
    -- og gir «blocked»-popup. Vinduet lukkes med X-knappen i stedet.
    SetBD(f, "Interface\\DialogFrame\\UI-DialogBox-Background", "Interface\\DialogFrame\\UI-DialogBox-Border", 32, 11)
    local rock = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    rock:SetTexture("Interface\\FrameGeneral\\UI-Background-Rock", "REPEAT", "REPEAT")
    rock:SetHorizTile(true); rock:SetVertTile(true)
    rock:SetPoint("TOPLEFT", 11, -12); rock:SetPoint("BOTTOMRIGHT", -12, 11)
    rock:SetVertexColor(0.42, 0.33, 0.33); rock:SetAlpha(0.85)
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -16)
    title:SetText("|T" .. TEX_SKULL .. ":14|t  |cffff4040Death|r Roll  |T" .. TEX_SKULL .. ":14|t")
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", -4, -4)
    self.panels = {}
    self:CreateArena(f)
    f:Hide()
end

function Arena:Update()
    if self.frame and self.frame:IsShown() and ns.db then self:UpdateArena() end
end

-- /dr uten argument: åpne Death Roll-fanen (navet)
function Arena:Toggle() if ns.UI and ns.UI.OpenTab then ns.UI:OpenTab("events") end end
function Arena:Open() if ns.UI and ns.UI.OpenTab then ns.UI:OpenTab("events") end end

-- Vis rulle-vinduet for en bestemt kamp (fungerer uansett hvilken fane man er på)
function ns.ShowMatch(duelId)
    Arena:Mount()
    if not Arena.frame then return end
    if duelId and ns.duels[duelId] then Arena.selectedDuelId = duelId end
    Arena.frame:Show()
    Arena:UpdateArena()
end

function ns.HideMatch()
    if Arena.frame then Arena.frame:Hide() end
    if ns.UpdateEventsPanel then ns.UpdateEventsPanel() end
end

function ns.OpenArenaForEvent(e)
    Arena.selectedDuelId = nil
    ns.ShowMatch(nil)
end

---------------------------------------------------------------------------
-- LAG EVENT-dialog
---------------------------------------------------------------------------
local createFrame
local function BuildCreateDialog()
    if createFrame then return createFrame end
    local f = CreateFrame("Frame", "GuildKompassEventCreate", UIParent, BACKDROP_TPL)
    f:SetSize(380, 372)
    f:SetFrameStrata("DIALOG"); f:SetToplevel(true); f:EnableMouse(true); f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetPoint("CENTER")
    SetBD(f, "Interface\\DialogFrame\\UI-DialogBox-Background", "Interface\\DialogFrame\\UI-DialogBox-Border", 32, 11)
    -- IKKE i UISpecialFrames (taint). Lukk med Avbryt/X.
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16); title:SetText("Lag event")
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton"); close:SetPoint("TOPRIGHT", -4, -4)

    local l1 = Label(f, "Tittel:"); l1:SetPoint("TOPLEFT", 20, -50)
    local titleBox = EditBox(f, 210); titleBox:SetPoint("LEFT", l1, "RIGHT", 10, 0); titleBox:SetText("Death Roll")
    f.titleBox = titleBox

    -- Modus: 1v1 eller turnering
    local lm = Label(f, "Type:"); lm:SetPoint("TOPLEFT", 20, -82)
    f.mode = "1v1"
    local updMake   -- forward-deklarert (settes etter at knappen er laget)
    local b1v1 = Button(f, "1v1", 70, 20); b1v1:SetPoint("LEFT", lm, "RIGHT", 10, 0)
    local btourn = Button(f, "Turnering", 90, 20); btourn:SetPoint("LEFT", b1v1, "RIGHT", 6, 0)
    local function selMode(m)
        f.mode = m
        if m == "1v1" then b1v1:LockHighlight(); btourn:UnlockHighlight()
        else btourn:LockHighlight(); b1v1:UnlockHighlight() end
        if f.stakeLbl then f.stakeLbl:SetText(m == "tournament" and "Buy-in:" or "Innsats:") end
        local is1 = (m == "1v1")
        if f.inviteLbl then f.inviteLbl:SetShown(is1) end
        if f.inviteBox then f.inviteBox:SetShown(is1) end
        if f.hint then
            if is1 then
                f.hint:SetText("1v1: skriv @navn for å invitere én, eller la det stå tomt for å åpne for alle (bare én blir med). Beløp: 10g, 50s, 10g50s.")
            else
                f.hint:SetText("Turnering: single-elimination bracket, vinneren tar hele potten (buy-in velges ved start). Beløp: 10g, 50s, 10g50s.")
            end
        end
        if updMake then updMake() end
    end
    b1v1:SetScript("OnClick", function() selMode("1v1") end)
    btourn:SetScript("OnClick", function() selMode("tournament") end)

    local l2 = Label(f, "Når:"); l2:SetPoint("TOPLEFT", 20, -118)
    f.dayButtons = {}
    f.selectedDay = 0   -- 0 = nå
    local SHORT = { "Nå", "Søn", "Man", "Tir", "Ons", "Tor", "Fre", "Lør" }
    local function selDay(idx)
        f.selectedDay = idx
        for i, b in ipairs(f.dayButtons) do
            if (i - 1) == idx then b:LockHighlight() else b:UnlockHighlight() end
        end
        f.hourBox:SetShown(idx ~= 0)
        f.hourLbl:SetShown(idx ~= 0)
        if updMake then updMake() end
    end
    for i = 0, 7 do
        local b = Button(f, SHORT[i + 1], 42, 20)
        if i == 0 then b:SetPoint("TOPLEFT", 54, -114)
        elseif i == 4 then b:SetPoint("TOPLEFT", 54, -136)
        else b:SetPoint("LEFT", f.dayButtons[i], "RIGHT", 2, 0) end
        b:SetScript("OnClick", function() selDay(i) end)
        f.dayButtons[i + 1] = b
    end
    f.hourLbl = Label(f, "kl."); f.hourLbl:SetPoint("TOPLEFT", 20, -162)
    f.hourBox = EditBox(f, 40, true); f.hourBox:SetPoint("LEFT", f.hourLbl, "RIGHT", 8, 0); f.hourBox:SetText("20")
    local hourHint = Label(f, "(time 0–23)", "GameFontDisableSmall"); hourHint:SetPoint("LEFT", f.hourBox, "RIGHT", 6, 0)

    f.stakeLbl = Label(f, "Innsats:"); f.stakeLbl:SetPoint("TOPLEFT", 20, -194)
    local stakeBox = EditBox(f, 74, false); stakeBox:SetPoint("LEFT", f.stakeLbl, "RIGHT", 10, 0); stakeBox:SetText("10g")
    f.stakeBox = stakeBox
    local l4 = Label(f, "Start:"); l4:SetPoint("LEFT", stakeBox, "RIGHT", 16, 0)
    local startBox = EditBox(f, 56, true); startBox:SetPoint("LEFT", l4, "RIGHT", 8, 0); startBox:SetText("1000")
    f.startBox = startBox

    local l5 = Label(f, "Notat:"); l5:SetPoint("TOPLEFT", 20, -226)
    local noteBox = EditBox(f, 210); noteBox:SetPoint("LEFT", l5, "RIGHT", 10, 0)
    f.noteBox = noteBox

    -- Inviter (kun 1v1): fyll inn @navn for å invitere direkte, eller la stå tomt
    -- for å åpne for hele guilden (bare én kan bli med).
    f.inviteLbl = Label(f, "Inviter @:"); f.inviteLbl:SetPoint("TOPLEFT", 20, -256)
    local inviteBox = EditBox(f, 200); inviteBox:SetPoint("LEFT", f.inviteLbl, "RIGHT", 10, 0)
    inviteBox:SetScript("OnTextChanged", function() if updMake then updMake() end end)
    f.inviteBox = inviteBox

    local hint = Label(f, "", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", 20, -284); hint:SetWidth(340); hint:SetJustifyH("LEFT")
    f.hint = hint

    selMode("1v1")

    local function NextWeekday(wday, hour)
        local now = GetServerTime()
        local t = date("*t", now)
        local days = (wday - t.wday) % 7
        local target = now - (t.hour * 3600 + t.min * 60 + t.sec) + days * 86400 + hour * 3600
        if target <= now then target = target + 7 * 86400 end
        return target
    end

    local make = Button(f, "|cff55ff55Lag event|r", 120, 24); make:SetPoint("BOTTOMLEFT", 24, 18)
    make:SetScript("OnClick", function()
        local startVal = math.max(2, tonumber(f.startBox:GetText()) or 1000)
        local whenEpoch = 0
        if f.selectedDay ~= 0 then
            local hour = math.max(0, math.min(23, tonumber(f.hourBox:GetText()) or 20))
            whenEpoch = NextWeekday(f.selectedDay, hour)   -- selectedDay 1..7 = søn..lør = date wday
        end
        local stake = ns.ParseMoney(f.stakeBox:GetText()) or 0
        local invited = (f.mode == "1v1") and (f.inviteBox:GetText() or ""):gsub("^%s*@?%s*", ""):gsub("%s+$", "") or nil
        ns.CreateEvent(f.titleBox:GetText(), whenEpoch, stake, startVal, f.noteBox:GetText(), f.mode, invited)
        f:Hide()
    end)
    local cancel = Button(f, "Avbryt", 90, 24); cancel:SetPoint("BOTTOMRIGHT", -24, 18)
    cancel:SetScript("OnClick", function() f:Hide() end)

    f.make = make
    updMake = function()
        if f.mode == "1v1" and f.selectedDay == 0 then
            local inv = (f.inviteBox:GetText() or ""):gsub("^%s*@?%s*", ""):gsub("%s+$", "")
            make:SetText(inv ~= "" and "|cff55ff55Inviter|r" or "|cff55ff55Åpne for alle|r")
        else
            make:SetText("|cff55ff55Lag event|r")
        end
    end

    selDay(0)
    updMake()
    createFrame = f
    return f
end

function ns.ShowCreateEvent()
    local f = BuildCreateDialog()
    f:Show()
end

---------------------------------------------------------------------------
-- EVENTS-FANE i hovedvinduet
---------------------------------------------------------------------------
local EVENT_SLOTS = 3
local eventsPanel

function ns.BuildEventsPanel(parent, anchor)
    if eventsPanel then return eventsPanel end
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetPoint("TOPLEFT", anchor, "TOPLEFT", 6, -6)
    panel:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", -6, 6)
    panel:Hide()
    eventsPanel = panel

    -- Toppknapper
    local create = Button(panel, "|cff55ff55+ Lag event|r", 130, 24)
    create:SetPoint("TOPLEFT", 4, -4)
    create:SetScript("OnClick", function() ns.ShowCreateEvent() end)
    -- Av/på for varsel-banner når noen lager et nytt event
    panel.warnCB = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    panel.warnCB:SetSize(24, 24)
    panel.warnCB:SetPoint("LEFT", create, "RIGHT", 16, 0)
    panel.warnCB:SetScript("OnClick", function(self)
        if ns.global then ns.global.eventWarnings = self:GetChecked() and true or false end
    end)
    local warnLbl = Label(panel, "Varsle om nye events", "GameFontHighlightSmall")
    warnLbl:SetPoint("LEFT", panel.warnCB, "RIGHT", 2, 0)
    -- Venstre: kommende events
    local evHdr = Label(panel, "Kommende events", "GameFontNormal")
    evHdr:SetPoint("TOPLEFT", 6, -40)
    local evInset = Inset(panel)
    evInset:SetPoint("TOPLEFT", 4, -60)
    evInset:SetWidth(470)
    evInset:SetPoint("BOTTOM", panel, "BOTTOM", 0, 4)
    panel.evInset = evInset

    panel.cards = {}
    for i = 1, EVENT_SLOTS do
        local card = CreateFrame("Frame", nil, evInset, BACKDROP_TPL)
        card:SetPoint("TOPLEFT", 8, -8 - (i - 1) * 96)
        card:SetPoint("RIGHT", evInset, "RIGHT", -8, 0)
        card:SetHeight(90)
        SetBD(card, "Interface\\Tooltips\\UI-Tooltip-Background", "Interface\\Tooltips\\UI-Tooltip-Border", 12, 3)
        if card.SetBackdropColor then card:SetBackdropColor(0.1, 0.08, 0.06, 0.8); card:SetBackdropBorderColor(0.7, 0.55, 0.25, 0.8) end
        card.title = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        card.title:SetPoint("TOPLEFT", 10, -8); card.title:SetPoint("RIGHT", card, "RIGHT", -120, 0); card.title:SetJustifyH("LEFT"); card.title:SetWordWrap(false)
        card.when = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        card.when:SetPoint("TOPRIGHT", -10, -8); card.when:SetJustifyH("RIGHT")
        card.info = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        card.info:SetPoint("TOPLEFT", 10, -28); card.info:SetPoint("RIGHT", card, "RIGHT", -10, 0); card.info:SetJustifyH("LEFT"); card.info:SetWordWrap(false)
        card.signups = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        card.signups:SetPoint("TOPLEFT", 10, -46); card.signups:SetPoint("RIGHT", card, "RIGHT", -10, 0); card.signups:SetJustifyH("LEFT")
        card.signups:SetWordWrap(false)
        card.join = Button(card, "Meld på", 84, 22); card.join:SetPoint("BOTTOMLEFT", 8, 8)
        card.open = Button(card, "Arena", 124, 22); card.open:SetPoint("LEFT", card.join, "RIGHT", 6, 0)
        card.cancel = Button(card, "Avlys", 58, 22); card.cancel:SetPoint("BOTTOMRIGHT", -8, 8)
        card:Hide()
        panel.cards[i] = card
    end
    panel.more = evInset:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    panel.more:SetPoint("BOTTOM", 0, 6)
    panel.evEmpty = evInset:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    panel.evEmpty:SetPoint("CENTER", 0, 10)
    panel.evEmpty:SetText("Ingen events ennå.\nTrykk «+ Lag event».")

    -- Høyre: toppliste
    local lbHdr = Label(panel, "Toppliste", "GameFontNormal")
    lbHdr:SetPoint("TOPLEFT", evInset, "TOPRIGHT", 14, 14)
    local week = Button(panel, "Uke", 60, 20); week:SetPoint("TOPLEFT", evInset, "TOPRIGHT", 150, 16)
    local season = Button(panel, "Sesong", 70, 20); season:SetPoint("LEFT", week, "RIGHT", 4, 0)
    week:SetScript("OnClick", function() panel.period = "week"; ns.UpdateEventsPanel() end)
    season:SetScript("OnClick", function() panel.period = "season"; ns.UpdateEventsPanel() end)
    panel.week, panel.season, panel.period = week, season, "week"
    -- GM: nullstill-knapper (vises bare for guildmaster) – egen rad, høyrejustert
    local gmSeason = Button(panel, "|cffff8080Ny sesong|r", 96, 20)
    gmSeason:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -8, -68)
    gmSeason:SetScript("OnClick", function() StaticPopup_Show("GUILDKOMPASS_RESETSEASON") end)
    local gmWeek = Button(panel, "|cffffd100Nullstill uke|r", 104, 20)
    gmWeek:SetPoint("RIGHT", gmSeason, "LEFT", -6, 0)
    gmWeek:SetScript("OnClick", function() StaticPopup_Show("GUILDKOMPASS_RESETWEEK") end)
    panel.gmWeek, panel.gmSeason = gmWeek, gmSeason
    local lbWrap = CreateFrame("Frame", nil, panel)
    lbWrap:SetPoint("TOPLEFT", evInset, "TOPRIGHT", 14, -30)
    lbWrap:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -2, 4)
    panel.board = MakeTable(lbWrap, LeaderboardCols(true), 30, 13, 20)
    panel.board.empty:SetText("Ingen dueller ennå.")

    -- Bygg rulle-vinduet (eget lite vindu som åpnes under en kamp)
    Arena:Mount()

    return panel
end

function ns.UpdateEventsPanel()
    local panel = eventsPanel
    if not panel or not panel:IsShown() then return end
    ns.EnsureDR()
    if panel.warnCB then panel.warnCB:SetChecked(ns.global and ns.global.eventWarnings) end
    local me = ns.PlayerName()
    -- events
    local list = ns.EventList()
    for i, card in ipairs(panel.cards) do
        local e = list[i]
        if not e then
            card.e = nil
            card:Hide()
        else
            card.e = e
            local isT = e.mode == "tournament"
            local t = isT and ns.EventTournament(e) or nil
            local canManage = ns.IsMe(e.host) or ns.IsGM(me)
            local typeTag = isT and (BLUE .. "Turnering|r") or (GREY .. "1v1|r")
            card.title:SetText(YELLOW .. (e.title ~= "" and e.title or "Death Roll") .. "|r  " .. typeTag
                .. GREY .. "  · vert " .. ns.Short(e.host) .. "|r")

            if t and t.finished then
                card.when:SetText(GREEN .. "Ferdig|r")
                local pot = (t.stake or 0) * math.max(0, #t.part)
                card.info:SetText("|T" .. TEX_SKULL .. ":12|t Vinner: " .. Colored(t.champion or "?")
                    .. (pot > 0 and (GREY .. "  ·  pott " .. YELLOW .. Gold(pot) .. "|r") or ""))
                card.signups:SetText(GREY .. #t.part .. " deltakere  ·  se topplista til høyre|r")
                card.join:Hide()
                card.open:Hide()
                card.cancel:Hide()

            elseif t then
                local b = ns.ComputeBracket(t.part, t.winners)
                local m = b.current and b.matches[b.current]
                local totalM = math.max(0, #t.part - 1)
                local played = #t.winners
                local roundNo = (m and m.round) or #b.rounds
                card.when:SetText(YELLOW .. "Pågår|r" .. GREY .. "  · runde " .. roundNo .. "/" .. #b.rounds
                    .. "  · kamp " .. math.min(played + 1, totalM) .. "/" .. totalM .. "|r")
                if m then
                    local mine = (ns.Key(m.a) == ns.Key(me) or ns.Key(m.b) == ns.Key(me))
                    card.info:SetText((mine and ("|cffffd100» din tur: |r") or ("Nå: "))
                        .. Colored(m.a) .. GREY .. " vs |r" .. Colored(m.b))
                else
                    card.info:SetText(GREY .. "Venter på neste kamp …|r")
                end
                -- hvem er fortsatt med (ikke tapt noen kamp)
                local outp = {}
                for i = 1, #b.matches do
                    local mm = b.matches[i]
                    if mm.winner then
                        local lo = (ns.Key(mm.winner) == ns.Key(mm.a)) and mm.b or mm.a
                        if lo and lo ~= ns.BYE then outp[ns.Key(lo)] = true end
                    end
                end
                local remain = {}
                for _, p in ipairs(t.part) do if not outp[ns.Key(p)] then remain[#remain + 1] = ns.Short(p) end end
                card.signups:SetText(GREY .. "igjen: " .. table.concat(remain, ", ") .. "|r")
                card.join:Show(); card.join:SetEnabled(true); card.join:SetText("Bracket")
                card.join:SetScript("OnClick", function() if ns.ShowBracket then ns.ShowBracket(t.tid) end end)
                local inMatch = m and (ns.Key(m.a) == ns.Key(me) or ns.Key(m.b) == ns.Key(me))
                if inMatch then
                    -- begge spillerne i kampen kan starte den (og gå inn igjen)
                    card.open:Show(); card.open:SetEnabled(true); card.open:SetText("|cffffd100Spill kampen|r")
                    card.open:SetScript("OnClick", function() ns.PlayTournamentMatch(t.tid) end)
                elseif m then
                    -- tilskuer: gå inn og se kampen som pågår
                    card.open:Show(); card.open:SetEnabled(true); card.open:SetText("Se kampen")
                    card.open:SetScript("OnClick", function() ns.OpenArenaOnTournament(t.tid) end)
                else
                    card.open:Hide()
                end
                card.cancel:SetShown(canManage); card.cancel:SetText("Avlys")
                card.cancel:SetScript("OnClick", function() ns.CancelEvent(e.id) end)

            elseif (not isT) and e.duelId and ns.duels[e.duelId] then
                -- 1v1 med tilknyttet duell: event-kort du kan gå inn/ut av
                local d = ns.duels[e.duelId]
                local st = d.state
                local meIn = ns.IsMe(d.a) or (d.b and ns.IsMe(d.b))
                local live = (st == "open" or st == "invite" or st == "active")
                if st == "done" then
                    card.when:SetText(GREEN .. "Ferdig|r")
                    card.info:SetText("|T" .. TEX_SKULL .. ":12|t Vinner: " .. Colored(d.winner or "?")
                        .. ((d.amount or 0) > 0 and (GREY .. "  ·  " .. YELLOW .. Gold(d.amount) .. "|r") or ""))
                elseif st == "open" then
                    card.when:SetText(YELLOW .. "Åpen – venter|r")
                    card.info:SetText(Colored(d.a) .. GREY .. " vs (hvem som helst)|r")
                elseif st == "invite" then
                    card.when:SetText(YELLOW .. "Venter på svar|r")
                    card.info:SetText(Colored(d.a) .. GREY .. " vs |r" .. (d.b and Colored(d.b) or (GREY .. "?|r")))
                else
                    card.when:SetText(YELLOW .. "Pågår|r")
                    card.info:SetText(Colored(d.a) .. GREY .. " vs |r" .. (d.b and Colored(d.b) or (GREY .. "?|r")))
                end
                card.signups:SetText(GREY .. ((d.amount or 0) > 0 and ("innsats " .. ns.MoneyText(d.amount)) or "ingen innsats")
                    .. "  ·  start " .. (d.start or 1000) .. "|r")
                card.join:Hide()
                if live and (meIn or ns.IsMe(e.host)) then
                    card.open:Show(); card.open:SetEnabled(true)
                    if st == "invite" and d.b and ns.IsMe(d.b) then
                        card.open:SetText("|cff55ff55Godta & gå inn|r")
                        card.open:SetScript("OnClick", function() ns.Accept(e.duelId); ns.FocusArenaDuel(e.duelId) end)
                    else
                        card.open:SetText("|cffffd100Gå inn|r")
                        card.open:SetScript("OnClick", function() ns.FocusArenaDuel(e.duelId) end)
                    end
                elseif st == "open" and not meIn then
                    card.open:Show(); card.open:SetEnabled(true); card.open:SetText("|cff55ff55Bli med|r")
                    card.open:SetScript("OnClick", function() ns.JoinOpen(e.duelId); ns.FocusArenaDuel(e.duelId) end)
                elseif live then
                    -- tilskuer: kan alltid se på (men ikke gå inn i en invitert/full kamp)
                    card.open:Show(); card.open:SetEnabled(true); card.open:SetText("Se kampen")
                    card.open:SetScript("OnClick", function() ns.FocusArenaDuel(e.duelId) end)
                else
                    card.open:Hide()
                end
                card.cancel:SetShown(canManage); card.cancel:SetText("Avlys")
                card.cancel:SetScript("OnClick", function() ns.CancelEvent(e.id) end)

            else
                -- påmelding (planlagt 1v1, eller turnering som ikke er startet)
                card.when:SetText(WhenText(e))
                local info = "|T" .. TEX_SKULL .. ":12|t " .. (isT and "Turnering" or "Death Roll")
                if e.stake and e.stake > 0 then
                    info = info .. GREY .. "  ·  " .. (isT and "pott/pers " or "innsats ") .. "|r" .. YELLOW .. Gold(e.stake) .. "|r"
                else
                    info = info .. GREY .. "  ·  ingen innsats|r"
                end
                info = info .. GREY .. "  ·  start " .. (e.start or 1000) .. "|r"
                if e.note and e.note ~= "" then info = info .. GREY .. "  ·  " .. e.note .. "|r" end
                card.info:SetText(info)
                local names = ns.SignupList(e.id)
                local cnt = #names
                local shown = {}
                for j = 1, math.min(5, cnt) do shown[j] = names[j] end
                card.signups:SetText(GREEN .. cnt .. " påmeldt" .. (cnt == 1 and "" or "e") .. "|r"
                    .. (cnt > 0 and (GREY .. ": " .. table.concat(shown, ", ") .. (cnt > 5 and " …" or "") .. "|r") or ""))
                card.join:Show()
                if ns.AmSignedUp(e.id) then
                    card.join:SetText("Meld av"); card.join:SetScript("OnClick", function() ns.LeaveEvent(e.id) end)
                else
                    card.join:SetText("|cff55ff55Meld på|r"); card.join:SetScript("OnClick", function() ns.JoinEvent(e.id) end)
                end
                card.open:Show()
                if isT then
                    card.open:SetText("|cff55ff55Start turnering|r")
                    card.open:SetEnabled(canManage and cnt >= 2)
                    card.open:SetScript("OnClick", function()
                        StaticPopup_Show("GUILDKOMPASS_TSTART", nil, nil,
                            { eventId = e.id, copper = e.stake or 0 })
                    end)
                else
                    card.open:SetText("Arena"); card.open:SetEnabled(true)
                    card.open:SetScript("OnClick", function() ns.OpenArenaForEvent(e) end)
                end
                card.cancel:SetShown(canManage); card.cancel:SetText("Avlys")
                card.cancel:SetScript("OnClick", function() ns.CancelEvent(e.id) end)
            end
            card:Show()
        end
    end
    panel.evEmpty:SetShown(#list == 0)
    panel.more:SetText(#list > EVENT_SLOTS and (GREY .. "+ " .. (#list - EVENT_SLOTS) .. " flere events|r") or "")

    -- toppliste
    if panel.period == "week" then panel.week:LockHighlight(); panel.season:UnlockHighlight()
    else panel.season:LockHighlight(); panel.week:UnlockHighlight() end
    local isGM = ns.IsGM(me)
    if panel.gmWeek then panel.gmWeek:SetShown(isGM) end
    if panel.gmSeason then panel.gmSeason:SetShown(isGM) end
    local data = ns.Leaderboard(panel.period)
    for _, s in ipairs(data) do s.highlight = ns.IsMe(s.name) end
    panel.board.data = data
    panel.board:Render()
end

function ns.ShowEventsPanel(show)
    if not eventsPanel then return end
    eventsPanel:SetShown(show)
    if show then ns.UpdateEventsPanel() end
end

---------------------------------------------------------------------------
-- Bracket-vindu (turneringstre) + lykkehjul for bye
---------------------------------------------------------------------------
local function MatchLine(m)
    if m.bye then
        return Colored(m.winner) .. GREY .. "  (fri)|r"
    end
    local an = m.a and ns.Short(m.a) or "?"
    local bn = m.b and ns.Short(m.b) or "?"
    local a = m.a and Colored(m.a) or (GREY .. "?|r")
    local b = m.b and Colored(m.b) or (GREY .. "?|r")
    if m.winner then
        local crown = "|T" .. TEX_CROWN .. ":12|t"
        if ns.Key(m.winner) == ns.Key(m.a) then
            a = crown .. a; b = GREY .. bn .. "|r"
        else
            b = crown .. b; a = GREY .. an .. "|r"
        end
    elseif m.current then
        a = YELLOW .. ">> |r" .. a
    end
    return a .. GREY .. "  vs  |r" .. b
end

function ns.ShowBracket(tid)
    local t = ns.db and ns.db.tournaments and ns.db.tournaments[tid]
    if not t then return end
    local f = ns.BracketFrame
    if not f then
        f = CreateFrame("Frame", "GuildKompassBracket", UIParent, BACKDROP_TPL)
        f:SetSize(620, 400)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        f:SetToplevel(true)
        SetBD(f, "Interface\\DialogFrame\\UI-DialogBox-Background", "Interface\\DialogFrame\\UI-DialogBox-Border", 24, 5)
        f:EnableMouse(true); f:SetMovable(true); f:SetClampedToScreen(true); f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", function(s) s:StartMoving() end)
        f:SetScript("OnDragStop", function(s) s:StopMovingOrSizing() end)
        f:SetScript("OnHide", function(s) s:StopMovingOrSizing() end)
        f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        f.title:SetPoint("TOP", 0, -16)
        f.sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        f.sub:SetPoint("TOP", f.title, "BOTTOM", 0, -4)
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -4, -4)
        f.cols = {}
        ns.BracketFrame = f
    end
    f:Show()
    f.tid = tid
    local b = ns.ComputeBracket(t.part, t.winners)
    local nR = #b.rounds
    f.title:SetText("|cffffd100Turnering – bracket|r")
    if b.finished and b.champion then
        f.sub:SetText("|T" .. TEX_CROWN .. ":16|t  Vinner: " .. Colored(b.champion))
    elseif b.current and b.matches[b.current] then
        local m = b.matches[b.current]
        f.sub:SetText(GREY .. "Pågår nå: |r" .. Colored(m.a) .. GREY .. " vs |r" .. Colored(m.b))
    else
        f.sub:SetText(GREY .. #t.part .. " spillere · " .. nR .. " runder|r")
    end
    local colW = math.max(130, math.floor(576 / math.max(1, nR)))
    for i = 1, math.max(nR, #f.cols) do
        local col = f.cols[i]
        if i <= nR then
            if not col then
                col = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                col:SetJustifyH("LEFT"); col:SetJustifyV("TOP")
                f.cols[i] = col
            end
            col:ClearAllPoints()
            col:SetPoint("TOPLEFT", 22 + (i - 1) * colW, -74)
            col:SetWidth(colW - 8)
            local rname = (i == nR) and "Finale" or (i == nR - 1 and "Semifinale" or ("Runde " .. i))
            local lines = { YELLOW .. rname .. "|r", "" }
            for _, m in ipairs(b.rounds[i]) do
                lines[#lines + 1] = MatchLine(m)
                lines[#lines + 1] = ""
            end
            col:SetText(table.concat(lines, "\n"))
            col:Show()
        elseif col then
            col:Hide()
        end
    end
end

-- Lykkehjul: spinner gjennom navnene og lander på den/de som får bye.
function ns.ShowByeWheel(t)
    if not t or not t.part then return end
    local S = 1; while S < #t.part do S = S * 2 end
    local byes = S - #t.part
    if byes <= 0 then return end
    local lucky = {}
    for i = 1, byes do lucky[i] = ns.Short(t.part[i]) end
    local f = ns.WheelFrame
    if not f then
        f = CreateFrame("Frame", "GuildKompassWheel", UIParent, BACKDROP_TPL)
        f:SetSize(340, 130); f:SetPoint("CENTER", 0, 140); f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:SetToplevel(true)
        SetBD(f, "Interface\\DialogFrame\\UI-DialogBox-Background", "Interface\\DialogFrame\\UI-DialogBox-Border", 24, 5)
        f.hdr = f:CreateFontString(nil, "OVERLAY", "GameFontNormal"); f.hdr:SetPoint("TOP", 0, -16)
        f.name = f:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge"); f.name:SetPoint("CENTER", 0, -8)
        ns.WheelFrame = f
    end
    f.hdr:SetText("|cffffd100Lykkehjulet|r – hvem slipper første kamp?")
    f.name:SetText("")
    f:Show()
    local names = {}
    for _, p in ipairs(t.part) do names[#names + 1] = ns.Short(p) end
    local spins, i = 0, 0
    local function step()
        i = (i % #names) + 1
        f.name:SetText(WHITE .. names[i] .. "|r")
        if ns.Sound then ns.Sound("IG_MAINMENU_OPTION") end
        spins = spins + 1
        if spins < 20 then
            C_Timer.After(0.06 + spins * 0.012, step)
        else
            f.name:SetText(GREEN .. table.concat(lucky, ", ") .. "|r")
            if ns.Sound then ns.Sound("READY_CHECK") end
            if ns.Anim and ns.Anim.Banner then
                ns.Anim.Banner("FRIKAMP!", table.concat(lucky, ", ") .. " slipper første runde")
            end
            C_Timer.After(3.0, function() f:Hide() end)
        end
    end
    step()
end

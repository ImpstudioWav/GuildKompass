local ADDON, ns = ...

-- Guild Quests: felles mål for guilden med en gullfarget framdriftsbar.
-- Offiserer lager/justerer mål, alle ser dem. Synk via GQNEW/GQHI (rev-basert,
-- samme mønster som events). Transport/DB/roller gjenbrukes fra addonen.

local Handlers = ns.Handlers

local GREY, GREEN, GOLD, WHITE = "|cff888888", "|cff55ff55", "|cffffd100", "|cffffffff"
local PURPLE = "|cffc080ff"
local BACKDROP_TPL = BackdropTemplateMixin and "BackdropTemplate" or nil

local function clean(s)
    s = tostring(s or "")
    return (s:gsub("[;%^,\n\r]", " "))
end

local function split(s, sep)
    local out = {}
    for part in (tostring(s or "")):gmatch("[^" .. sep .. "]+") do out[#out + 1] = part end
    return out
end

local function now() return GetServerTime() end

---------------------------------------------------------------------------
-- Database
---------------------------------------------------------------------------
local function GQ()
    if not ns.db then return nil end
    local g = ns.db.gquests
    if not g then g = { goals = {}, seq = 0 }; ns.db.gquests = g end
    g.goals = g.goals or {}
    g.seq = g.seq or 0
    return g
end
ns.EnsureGQ = GQ

local function newId()
    return string.format("gq%x%x", now() % 0x7fffffff, math.random(0, 0xffffff))
end

-- Sortert liste (nyeste øverst, ferdige nederst)
function ns.GQ_Goals()
    local g = GQ(); if not g then return {} end
    local list = {}
    for _, goal in pairs(g.goals) do
        if not goal.deleted then list[#list + 1] = goal end
    end
    table.sort(list, function(a, b)
        local ad = ns.GQ_GoalDone(a) and 1 or 0
        local bd = ns.GQ_GoalDone(b) and 1 or 0
        if ad ~= bd then return ad < bd end          -- uferdige først
        -- manuelle mål først, så level-mål gruppert nivå → antall
        local al = (a.kind == "level") and 1 or 0
        local bl = (b.kind == "level") and 1 or 0
        if al ~= bl then return al < bl end
        if al == 1 then
            if (a.levelReq or 0) ~= (b.levelReq or 0) then return (a.levelReq or 0) < (b.levelReq or 0) end
            return (a.target or 0) < (b.target or 0)
        end
        return (a.createdAt or 0) < (b.createdAt or 0)
    end)
    return list
end

---------------------------------------------------------------------------
-- Auto-sporing: tell hvor mange "folk" (Battle.net-kontoer) i guilden som har
-- nådd et visst level eller høyere. Rosteret er likt for alle pålogget, så
-- alle klienter teller likt. Alts grupperes under samme konto via addon-data.
---------------------------------------------------------------------------
function ns.GQ_CountAtLevel(minLevel)
    if not ns.db then return 0 end
    local accMax, loose = {}, {}
    local function record(full, lvl)
        lvl = lvl or 0
        local rec = ns.db.members[full]
        local key = rec and rec.bnetKey
        if key then
            accMax[key] = math.max(accMax[key] or 0, lvl)
        else
            loose[full] = math.max(loose[full] or 0, lvl)
        end
    end
    for full, r in pairs(ns.roster or {}) do record(full, r.level) end
    for full, rec in pairs(ns.db.members) do
        if not (ns.roster and ns.roster[full]) then record(full, rec.level) end
    end
    local n = 0
    for _, mx in pairs(accMax) do if mx >= minLevel then n = n + 1 end end
    for _, lvl in pairs(loose) do if lvl >= minLevel then n = n + 1 end end
    return n
end

-- Nåværende framdrift for et mål (manuelt eller auto-level)
function ns.GQ_GoalCur(goal)
    if goal.kind == "level" then
        return math.min(goal.target or 0, ns.GQ_CountAtLevel(goal.levelReq or 0))
    end
    return goal.cur or 0
end

function ns.GQ_GoalDone(goal)
    if goal.deleted then return false end
    local target = goal.target or 0
    return target > 0 and ns.GQ_GoalCur(goal) >= target
end

---------------------------------------------------------------------------
-- Guild-nivå / XP: hvert fullført mål gir guilden XP. Nivået er en ren
-- funksjon av antall fullførte mål, så alle klienter regner likt (ingen
-- egen teller å synke, ingen dobbelttelling).
---------------------------------------------------------------------------
local XP_PER_QUEST = 100
local function needFor(level) return level * 200 end   -- XP for å gå fra `level` til neste

-- XP-belønning for et level-mål: avhenger av nivå OG antall folk som kreves
local function levelXP(levelReq, target)
    local base = (tonumber(target) or 10) <= 5 and 30 or 50
    local per  = (tonumber(target) or 10) <= 5 and 3 or 5
    return base + math.max(0, (tonumber(levelReq) or 20) - 20) * per
end

-- XP-belønning for et mål (vanskeligere mål gir mer)
function ns.GQ_GoalXP(goal)
    if goal.xp and goal.xp > 0 then return goal.xp end
    if goal.kind == "level" then return levelXP(goal.levelReq, goal.target) end
    return XP_PER_QUEST
end

-- returnerer: nivå, xp inn i nivået, xp som trengs til neste, total-xp, antall fullførte
function ns.GQ_GuildXP()
    local g = GQ()
    local count, total = 0, 0
    if g then
        for _, goal in pairs(g.goals) do
            if not goal.deleted and ns.GQ_GoalDone(goal) then
                count = count + 1
                total = total + ns.GQ_GoalXP(goal)
            end
        end
    end
    -- prestasjoner gir også guild-XP
    if ns.GQ_AchievementXP then
        local axp, acnt = ns.GQ_AchievementXP()
        total = total + axp
        count = count + acnt
    end
    local level, into, need = 1, total, needFor(1)
    while into >= need do
        into = into - need
        level = level + 1
        need = needFor(level)
    end
    return level, into, need, total, count
end

local shownLevel, gqReady
-- Felles feiring (banner + mynt-regn + lyd). Brukes ved fullført mål og av testknappen.
function ns.GQ_Celebrate(sub)
    if ns.Anim and ns.Anim.Cheer then
        ns.Anim.Cheer("HURRA!", sub or "")            -- festlig banner + mynt-regn + lyd
    else
        if ns.Anim and ns.Anim.Banner then ns.Anim.Banner("HURRA!", sub or "") end
        if ns.Sound then ns.Sound("LEVELUP") end
    end
end

-- Felles hurra når et felles mål fullføres (for alle som er pålogget)
local goalCelebrated = {}
local function checkGoalDone()
    local g = GQ(); if not g then return end
    for id, goal in pairs(g.goals) do
        if not goal.deleted and ns.GQ_GoalDone(goal) then
            if not goalCelebrated[id] then
                goalCelebrated[id] = true
                if gqReady then ns.GQ_Celebrate(goal.title .. " – fullført!") end
            end
        else
            goalCelebrated[id] = nil     -- kan feires på nytt om det fullføres igjen
        end
    end
end

local function checkLevelUp()
    checkGoalDone()
    local level = ns.GQ_GuildXP()
    if not gqReady then shownLevel = level; return end
    if level > (shownLevel or level) then
        if ns.Anim and ns.Anim.Banner then
            ns.Anim.Banner("GUILDEN GIKK OPP I NIVÅ!", "Guild nivå " .. level)
        end
        if ns.Sound then ns.Sound("LEVELUP") end
    end
    shownLevel = level
end
ns.GQ_CheckLevelUp = checkLevelUp

---------------------------------------------------------------------------
-- Synk
---------------------------------------------------------------------------
local function encode(goal)
    return table.concat({ clean(goal.id), clean(goal.title), goal.target or 0, goal.cur or 0,
        clean(goal.unit or "gull"), goal.done and 1 or 0, goal.createdAt or 0, goal.rev or 1,
        goal.deleted and 1 or 0, clean(goal.by or ""), clean(goal.kind or "manual"), goal.levelReq or 0,
        goal.xp or 100 }, ";")
end

local function decode(s)
    local x = split(s, ";")
    if #x < 8 or x[1] == "" then return nil end
    return {
        id = x[1], title = x[2] or "", target = tonumber(x[3]) or 0, cur = tonumber(x[4]) or 0,
        unit = (x[5] and x[5] ~= "") and x[5] or "gull", done = x[6] == "1",
        createdAt = tonumber(x[7]) or 0, rev = tonumber(x[8]) or 1,
        deleted = x[9] == "1", by = x[10] or "",
        kind = (x[11] and x[11] ~= "") and x[11] or "manual", levelReq = tonumber(x[12]) or 0,
        xp = tonumber(x[13]) or 100,
    }
end

-- Lagre innkommende mål hvis nyere. Returnerer "changed","done" eller nil.
local function merge(goal)
    local g = GQ(); if not g or not goal then return nil end
    local old = g.goals[goal.id]
    if old and (old.rev or 1) >= (goal.rev or 1) then return nil end
    local wasDone = old and old.done
    g.goals[goal.id] = goal
    if goal.done and not wasDone and not goal.deleted then return "done" end
    return "changed"
end

local function broadcast(goal)
    if not IsInGuild() or not ns.db then return end
    ns.Send("GQNEW", encode(goal), "GUILD")
end
ns.GQ_Broadcast = broadcast

Handlers.GQNEW = function(from, data)
    local goal = decode(data)
    if not goal then return end
    local res = merge(goal)
    if res then checkLevelUp() end   -- checkGoalDone() inni gir «HURRA!» ved fullført mål
    if res and ns.RefreshUI then ns.RefreshUI() end
    if res and ns.UpdateQuestsPanel then ns.UpdateQuestsPanel() end
end

-- Login-hello: send liste over id:rev jeg har; andre sender det jeg mangler.
function ns.GQ_SendHello()
    local g = GQ(); if not g or not IsInGuild() then return end
    local ids = {}
    for id, goal in pairs(g.goals) do ids[#ids + 1] = id .. ":" .. (goal.rev or 1) end
    ns.Send("GQHI", table.concat(ids, ","), "GUILD")
end

Handlers.GQHI = function(from, data)
    local g = GQ(); if not g then return end
    local have = {}
    for _, pair in ipairs(split(data, ",")) do
        local id, rev = pair:match("^(.-):(%d+)$")
        if id then have[id] = tonumber(rev) end
    end
    local missing = {}
    for id, goal in pairs(g.goals) do
        if (have[id] or 0) < (goal.rev or 1) then missing[#missing + 1] = goal end
    end
    if #missing == 0 then return end
    C_Timer.After(1 + math.random() * 4, function()
        for _, goal in ipairs(missing) do broadcast(goal) end
    end)
end

function ns.GQ_OnLogin()
    GQ()
    if IsInGuild() then
        ns.GQ_SendHello()
        if ns.GQ_BroadcastClaims then ns.GQ_BroadcastClaims() end
        if ns.GQ_ScanMine then C_Timer.After(10, function() ns.GQ_ScanMine(false) end) end
        -- jevnlig sjekk som sikkerhetsnett (fanger skill-ups API-et ikke varsler om)
        if not ns.gqAchTicker then ns.gqAchTicker = C_Timer.NewTicker(120, function() ns.GQ_ScanMine(true) end) end
    end
    -- unngå nivå-banner ved innlogging: sett "sett-nivå" etter at sync har landet
    C_Timer.After(20, function() shownLevel = (ns.GQ_GuildXP()); gqReady = true end)
end

---------------------------------------------------------------------------
-- Offiser-handlinger (bare offiserer kan lage/endre)
---------------------------------------------------------------------------
local function canEdit()
    return ns.IsOfficer and ns.IsOfficer(ns.PlayerName())
end
ns.GQ_CanEdit = canEdit

local function bump(goal)
    goal.rev = (goal.rev or 1) + 1
    goal.done = (goal.target or 0) > 0 and (goal.cur or 0) >= goal.target
    broadcast(goal)
    checkLevelUp()
    if ns.RefreshUI then ns.RefreshUI() end
    if ns.UpdateQuestsPanel then ns.UpdateQuestsPanel() end
end

function ns.GQ_New(title, target, unit, kind, levelReq, fixedId, xp)
    if not canEdit() then return end
    local g = GQ(); if not g then return end
    -- med fast id: lag ikke hvis den allerede finnes (verken aktiv eller slettet)
    if fixedId and g.goals[fixedId] then return g.goals[fixedId].id end
    g.seq = (g.seq or 0) + 1
    local goal = {
        id = fixedId or newId(), title = (title and title ~= "" and title) or "Nytt mål",
        target = math.max(1, tonumber(target) or 100), cur = 0, unit = unit or "gull",
        done = false, createdAt = now(), rev = 1, by = ns.PlayerName(),
        kind = kind or "manual", levelReq = tonumber(levelReq) or 0,
        xp = math.max(1, tonumber(xp) or 100),
    }
    g.goals[goal.id] = goal
    broadcast(goal)
    if ns.RefreshUI then ns.RefreshUI() end
    if ns.UpdateQuestsPanel then ns.UpdateQuestsPanel() end
    return goal.id
end

-- Auto-sporende level-mål: «X stykker i level N (eller høyere)».
-- Fast id per nivå ("gqlvlN") → kan aldri dupliseres på tvers av klienter.
-- Vanskeligere nivå gir mer XP.
function ns.GQ_NewLevel(levelReq, target)
    levelReq = tonumber(levelReq) or 60
    target = math.max(1, tonumber(target) or 10)
    local id = "gqlv" .. levelReq .. "x" .. target        -- fast id per nivå+antall
    return ns.GQ_New(target .. " stykker i level " .. levelReq, target, "personer", "level", levelReq, id, levelXP(levelReq, target))
end

function ns.GQ_AddProgress(id, delta)
    if not canEdit() then return end
    local g = GQ(); local goal = g and g.goals[id]; if not goal then return end
    goal.cur = math.max(0, math.min(goal.target or 0, (goal.cur or 0) + delta))
    bump(goal)
end

function ns.GQ_SetProgress(id, value)
    if not canEdit() then return end
    local g = GQ(); local goal = g and g.goals[id]; if not goal then return end
    goal.cur = math.max(0, math.min(goal.target or 0, tonumber(value) or 0))
    bump(goal)
end

function ns.GQ_SetTarget(id, value)
    if not canEdit() then return end
    local g = GQ(); local goal = g and g.goals[id]; if not goal then return end
    goal.target = math.max(1, tonumber(value) or 1)
    goal.cur = math.min(goal.cur or 0, goal.target)
    bump(goal)
end

function ns.GQ_SetTitle(id, title)
    if not canEdit() or not title or title == "" then return end
    local g = GQ(); local goal = g and g.goals[id]; if not goal then return end
    goal.title = title
    bump(goal)
end

function ns.GQ_Delete(id)
    if not canEdit() then return end
    local g = GQ(); local goal = g and g.goals[id]; if not goal then return end
    goal.deleted = true
    bump(goal)
end

-- Seed startmål (offiser). 100-gull-målet lages hvis det ikke finnes noe mål
-- ennå; level-målene (30/40/50/60) lages om de mangler – men slettede mål blir
-- ikke gjenopplivet.
function ns.GQ_SeedDefault()
    if not canEdit() then return end
    local g = GQ(); if not g then return end
    -- Rydd opp level-mål med feil/utdatert id (tilfeldige, eller gammelt skjema
    -- uten antall). Riktig id er "gqlv<nivå>x<antall>". Resten slettes.
    for id, goal in pairs(g.goals) do
        if goal.kind == "level" and not goal.deleted then
            local want = "gqlv" .. (goal.levelReq or 0) .. "x" .. (goal.target or 0)
            if id ~= want then
                goal.deleted = true
                goal.rev = (goal.rev or 1) + 1
                broadcast(goal)
            end
        end
    end
    -- 100-gull-målet: bare hvis det ikke finnes noe aktivt mål i det hele tatt
    local hasActive = false
    for _, goal in pairs(g.goals) do if not goal.deleted then hasActive = true break end end
    if not hasActive then
        ns.GQ_New("Samle 100 gull – åpne guildbank", 100, "gull")
    end
    -- Level-målene: 5 og 10 stykker for hvert nivå (faste id-er dedupe automatisk)
    for _, lv in ipairs({ 30, 40, 50, 60 }) do
        ns.GQ_NewLevel(lv, 5)
        ns.GQ_NewLevel(lv, 10)
    end
end

---------------------------------------------------------------------------
-- Panel-UI (egen fane, samme stil som Death Roll / Raid)
---------------------------------------------------------------------------
local function PSetBD(frame, bg, edge, edgeSize, inset)
    if not frame.SetBackdrop then return end
    frame:SetBackdrop({ bgFile = bg, edgeFile = edge, tile = true, tileSize = 16, edgeSize = edgeSize,
        insets = { left = inset, right = inset, top = inset, bottom = inset } })
end

local function PButton(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, h or 22); b:SetText(text)
    return b
end

-- Tall-/tekst-popup (gjenbrukes til navn, mål og framdrift)
local function mkPopup(key, prompt, numeric, onAccept)
    StaticPopupDialogs[key] = {
        text = prompt, button1 = OKAY or "OK", button2 = CANCEL or "Avbryt",
        hasEditBox = true, timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
        OnShow = function(self)
            local eb = self.editBox or (self.GetEditBox and self:GetEditBox())
            if eb then eb:SetNumeric(numeric and true or false); eb:SetText(""); eb:SetFocus() end
        end,
        OnAccept = function(self, data)
            local eb = self.editBox or (self.GetEditBox and self:GetEditBox())
            onAccept(eb and eb:GetText() or "", data)
        end,
        EditBoxOnEnterPressed = function(self)
            local parent = self:GetParent()
            onAccept(self:GetText() or "", parent.data)
            parent:Hide()
        end,
    }
end

mkPopup("GUILDKOMPASS_GQ_NEW", "Navn på det nye målet:", false, function(txt)
    ns.GQ_New(txt, 100, "gull")
end)
mkPopup("GUILDKOMPASS_GQ_NAME", "Nytt navn på målet:", false, function(txt, id)
    ns.GQ_SetTitle(id, txt)
end)
mkPopup("GUILDKOMPASS_GQ_TARGET", "Sett måltall:", true, function(txt, id)
    ns.GQ_SetTarget(id, tonumber(txt))
end)
mkPopup("GUILDKOMPASS_GQ_SET", "Sett framdrift (hvor mye samlet inn):", true, function(txt, id)
    ns.GQ_SetProgress(id, tonumber(txt))
end)
mkPopup("GUILDKOMPASS_GQ_LEVEL", "Level-mål: skriv nivået (f.eks. 60). Teller 10 stykker som har nådd det:", true, function(txt)
    ns.GQ_NewLevel(tonumber(txt), 10)
end)

local GOAL_SLOTS = 28
local CARD_H, CARD_VGAP, CARD_HGAP = 84, 8, 10   -- kompakte kort, to i bredden
local qpanel

function ns.BuildQuestsPanel(parent, anchor)
    if qpanel then return qpanel end
    local panel = CreateFrame("Frame", nil, parent)
    panel:SetPoint("TOPLEFT", anchor, "TOPLEFT", 6, -6)
    panel:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", -6, 6)
    panel:Hide()
    qpanel = panel

    -- Guild-nivå + XP-bar øverst
    panel.glevel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    panel.glevel:SetPoint("TOPLEFT", 10, -10)
    panel.glevel:SetTextColor(1, 0.82, 0)

    panel.gxpInfo = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.gxpInfo:SetPoint("LEFT", panel.glevel, "RIGHT", 10, 0)

    local gframe = CreateFrame("Frame", nil, panel, BACKDROP_TPL)
    gframe:SetPoint("TOPLEFT", 10, -36)
    gframe:SetPoint("RIGHT", panel, "RIGHT", -10, 0)
    gframe:SetHeight(26)
    PSetBD(gframe, "Interface\\Tooltips\\UI-Tooltip-Background", "Interface\\Tooltips\\UI-Tooltip-Border", 10, 3)
    if gframe.SetBackdropColor then
        gframe:SetBackdropColor(0, 0, 0, 0.85)
        gframe:SetBackdropBorderColor(0.6, 0.4, 0.8, 1)
    end
    local gbar = CreateFrame("StatusBar", nil, gframe)
    gbar:SetPoint("TOPLEFT", 4, -4); gbar:SetPoint("BOTTOMRIGHT", -4, 4)
    gbar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    gbar:SetStatusBarColor(0.64, 0.19, 0.85)       -- lilla (XP/erfaring)
    gbar:SetMinMaxValues(0, 1); gbar:SetValue(0)
    panel.gbar = gbar
    panel.gbarText = gbar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    panel.gbarText:SetPoint("CENTER")
    panel.gbarText:SetShadowColor(0, 0, 0, 1); panel.gbarText:SetShadowOffset(1, -1)

    local sep = panel:CreateTexture(nil, "ARTWORK")
    sep:SetColorTexture(0.8, 0.65, 0.3, 0.4)
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", gframe, "BOTTOMLEFT", 0, -8)
    sep:SetPoint("RIGHT", panel, "RIGHT", -10, 0)

    -- Modus-bryter: Mål / Prestasjoner
    panel.mode = "goals"
    panel.modeBtns = {}
    local function mkMode(label, key, anchorTo)
        local b = PButton(panel, label, 130, 20)
        if anchorTo then b:SetPoint("LEFT", anchorTo, "RIGHT", 4, 0)
        else b:SetPoint("TOPLEFT", sep, "BOTTOMLEFT", 2, -6) end
        b:SetScript("OnClick", function() panel.mode = key; ns.UpdateQuestsPanel() end)
        panel.modeBtns[key] = b
        return b
    end
    local mGoals = mkMode("Felles quest", "goals")
    local mAch   = mkMode("Solo tittel-quest", "ach", mGoals)

    -- Filter-knapper: Alle / Ikke fullført / Fullført
    panel.filter = "open"
    panel.filterBtns = {}
    local function mkFilter(label, key, anchorTo)
        local b = PButton(panel, label, 96, 20)
        if anchorTo then b:SetPoint("LEFT", anchorTo, "RIGHT", 4, 0)
        else b:SetPoint("LEFT", mAch, "RIGHT", 18, 0) end
        b:SetScript("OnClick", function()
            panel.filter = key
            ns.UpdateQuestsPanel()
        end)
        panel.filterBtns[key] = b
        return b
    end
    local fAll  = mkFilter("Alle", "all")
    local fOpen = mkFilter("Ikke fullført", "open", fAll)
    local fDone = mkFilter("Fullført", "done", fOpen)

    -- rullbart område for målene
    local scroll = CreateFrame("ScrollFrame", "GuildKompassQuestScroll", panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", mGoals, "BOTTOMLEFT", -2, -6)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -28, 4)
    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(10, GOAL_SLOTS * 104)
    scroll:SetScrollChild(child)
    panel.scroll, panel.child = scroll, child
    scroll:SetScript("OnSizeChanged", function(_, w) child:SetWidth(w) end)

    panel.empty = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
    panel.empty:SetPoint("TOP", scroll, "TOP", 0, -40)
    panel.empty:SetText("Ingen felles mål ennå.")

    panel.cards = {}
    for i = 1, GOAL_SLOTS do
        local card = CreateFrame("Frame", nil, child, BACKDROP_TPL)
        card:SetHeight(CARD_H)
        PSetBD(card, "Interface\\Tooltips\\UI-Tooltip-Background", "Interface\\Tooltips\\UI-Tooltip-Border", 12, 4)
        if card.SetBackdropColor then
            card:SetBackdropColor(0.09, 0.07, 0.04, 0.9)
            card:SetBackdropBorderColor(0.85, 0.68, 0.28, 1)
        end

        card.title = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        card.title:SetPoint("TOPLEFT", 10, -8)
        card.title:SetPoint("RIGHT", card, "RIGHT", -86, 0)
        card.title:SetJustifyH("LEFT"); card.title:SetWordWrap(false)
        card.title:SetTextColor(1, 0.82, 0)

        card.amount = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        card.amount:SetPoint("TOPRIGHT", -10, -9)
        card.amount:SetJustifyH("RIGHT")

        -- Gullfarget framdriftsbar (XP-stil) med ramme
        local frame = CreateFrame("Frame", nil, card, BACKDROP_TPL)
        frame:SetPoint("TOPLEFT", 10, -26)
        frame:SetPoint("RIGHT", card, "RIGHT", -10, 0)
        frame:SetHeight(20)
        PSetBD(frame, "Interface\\Tooltips\\UI-Tooltip-Background", "Interface\\Tooltips\\UI-Tooltip-Border", 9, 3)
        if frame.SetBackdropColor then
            frame:SetBackdropColor(0, 0, 0, 0.8)
            frame:SetBackdropBorderColor(0.7, 0.55, 0.2, 1)
        end
        local bar = CreateFrame("StatusBar", nil, frame)
        bar:SetPoint("TOPLEFT", 3, -3); bar:SetPoint("BOTTOMRIGHT", -3, 3)
        bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
        bar:SetStatusBarColor(1, 0.82, 0)          -- gull
        bar:SetMinMaxValues(0, 100); bar:SetValue(0)
        card.bar = bar
        card.barText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        card.barText:SetPoint("CENTER")
        card.barText:SetShadowColor(0, 0, 0, 1); card.barText:SetShadowOffset(1, -1)

        -- liten merkelapp for auto-mål
        card.autoTag = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        card.autoTag:SetPoint("BOTTOMLEFT", 10, 11)
        card.autoTag:SetText("|cff80c0ffAuto – teller level|r")

        card:Hide()
        panel.cards[i] = card
    end

    return panel
end

function ns.UpdateQuestsPanel()
    if not qpanel or not qpanel:IsShown() then return end
    local edit = canEdit()
    local goalsMode = (qpanel.mode ~= "ach")
    for key, b in pairs(qpanel.modeBtns) do
        if key == qpanel.mode then b:LockHighlight() else b:UnlockHighlight() end
    end

    checkLevelUp()   -- fanger level-mål som fullføres mens man ser på
    -- guild-nivå / XP-bar
    local level, into, need, total, count = ns.GQ_GuildXP()
    local pct = need > 0 and math.floor(into / need * 100 + 0.5) or 0
    qpanel.glevel:SetText("Guild nivå " .. level)
    qpanel.gxpInfo:SetText(GREY .. count .. (count == 1 and " mål fullført" or " mål fullført") .. "|r")
    qpanel.gbar:SetMinMaxValues(0, need > 0 and need or 1)
    qpanel.gbar:SetValue(into)
    qpanel.gbarText:SetText(into .. " / " .. need .. " XP  (" .. pct .. "%)")

    -- filtrering: alle / ikke fullført / fullført
    local all = ns.GQ_DisplayList()
    local wantAch = (qpanel.mode == "ach")
    local goals = {}
    for _, goal in ipairs(all) do
        local isAch = goal.ach and true or false
        local d = ns.GQ_GoalDone(goal)
        if isAch == wantAch and (qpanel.filter == "all" or (qpanel.filter == "done" and d) or (qpanel.filter == "open" and not d)) then
            goals[#goals + 1] = goal
        end
    end
    for key, b in pairs(qpanel.filterBtns) do
        if key == qpanel.filter then b:LockHighlight() else b:UnlockHighlight() end
    end
    qpanel.empty:SetShown(#goals == 0)
    qpanel.empty:SetText(#all == 0 and "Ingen felles mål ennå."
        or (qpanel.filter == "done" and "Ingen fullførte mål ennå."
        or (qpanel.filter == "open" and "Alle mål er fullført!" or "Ingen mål.")))

    -- to kort i bredden: regn ut kolonne-bredde og høyde på scroll-barnet
    local childW = qpanel.scroll:GetWidth()
    if not childW or childW < 10 then childW = 840 end
    local colW = (childW - CARD_HGAP) / 2
    local rows = math.ceil(#goals / 2)
    qpanel.child:SetHeight(math.max(10, rows * (CARD_H + CARD_VGAP)))

    for i, card in ipairs(qpanel.cards) do
        local goal = goals[i]
        if goal then
            card.goalId = goal.id
            local col = (i - 1) % 2
            local row = math.floor((i - 1) / 2)
            card:ClearAllPoints()
            card:SetPoint("TOPLEFT", qpanel.child, "TOPLEFT", col * (colW + CARD_HGAP), -row * (CARD_H + CARD_VGAP))
            card:SetWidth(colW)
            local isLevel = (goal.kind == "level")
            local isAch = goal.ach
            local cur = ns.GQ_GoalCur(goal)
            local done = ns.GQ_GoalDone(goal)
            local tag = done and ("  |TInterface\\RaidFrame\\ReadyCheck-Ready:14|t") or ""
            card.title:SetText(goal.title .. tag)
            if isAch then
                -- prestasjon: vis tittel-belønning + hvilken konto som vant
                card.amount:SetText("|cffffd100" .. (goal.reward or "") .. "|r")
                card.bar:SetMinMaxValues(0, 1); card.bar:SetValue(done and 1 or 0)
                card.bar:SetStatusBarColor(done and 1 or 0.35, done and 0.82 or 0.3, 0)
                if goal.holder then
                    card.barText:SetText(GOLD .. "Vunnet av " .. goal.holder .. "|r")
                else
                    local leader = ns.GQ_AchLeader and ns.GQ_AchLeader(goal.achId)
                    card.barText:SetText(leader and (GREY .. "Leder: |r" .. WHITE .. leader .. "|r") or (GREY .. "Ingen på vei ennå|r"))
                end
                card.autoTag:SetText("|cffffcf80Prestasjon|r " .. PURPLE .. "+" .. (goal.xp or 0) .. " XP til guilden|r")
                card.autoTag:Show()
            else
                local pct = goal.target > 0 and math.floor((cur / goal.target) * 100 + 0.5) or 0
                card.amount:SetText(PURPLE .. "+" .. ns.GQ_GoalXP(goal) .. " XP|r")
                card.bar:SetMinMaxValues(0, goal.target > 0 and goal.target or 1)
                card.bar:SetValue(cur)
                if done then card.bar:SetStatusBarColor(0.3, 1, 0.3) else card.bar:SetStatusBarColor(1, 0.82, 0) end
                card.barText:SetText(cur .. " / " .. goal.target .. " " .. (goal.unit or "") .. "  (" .. pct .. "%)")
                card.autoTag:SetText("|cff80c0ffAuto – teller level|r")
                card.autoTag:SetShown(isLevel)
            end
            card:Show()
        else
            card:Hide()
        end
    end
end

function ns.ShowQuestsPanel(show)
    if not qpanel then return end
    qpanel:SetShown(show)
    if show then
        if canEdit() then ns.GQ_SeedDefault() end
        ns.UpdateQuestsPanel()
    end
end

---------------------------------------------------------------------------
-- PRESTASJONER: "første til ..."-titler, låst til Battle.net-konto.
-- Helautomatisk: egen klient hevder milepæler for sin egen konto med
-- tidsstempel (servertid). Tidligst = førstemann. Titlene vises ved navnet
-- på Medlemmer-siden (hver kan velge hvilken av sine titler som vises).
---------------------------------------------------------------------------
local PROF_MAX = 300

local ACH = {
    { id = "a60_1", mid = "lvl60",            place = 1, title = "BigSiggma",          label = "Første til level 60", xp = 500 },
    { id = "a60_2", mid = "lvl60",            place = 2, title = "Close but no Siggar", label = "Andre til level 60",  xp = 250 },
    { id = "skin",  mid = "prof:Skinning",     place = 1, title = "SkinniSigg",         label = "Første til max Skinning",      xp = 200 },
    { id = "ench",  mid = "prof:Enchanting",   place = 1, title = "LacedSigg",          label = "Første til max Enchanting",    xp = 200 },
    { id = "herb",  mid = "prof:Herbalism",    place = 1, title = "GanjaSigg",          label = "Første til max Herbalism",     xp = 200 },
    { id = "alch",  mid = "prof:Alchemy",      place = 1, title = "Drink and Sigg",     label = "Første til max Alchemy",       xp = 200 },
    { id = "fish",  mid = "prof:Fishing",      place = 1, title = "StinkySigg",         label = "Første til max Fishing",       xp = 200 },
    { id = "bs",    mid = "prof:Blacksmithing",place = 1, title = "BlackSiggar",        label = "Første til max Blacksmithing", xp = 200 },
    { id = "lw",    mid = "prof:Leatherworking",place= 1, title = "GummiSigg",          label = "Første til max Leatherworking",xp = 200 },
    { id = "tail",  mid = "prof:Tailoring",    place = 1, title = "Rullings",           label = "Første til max Tailoring",     xp = 200 },
    { id = "fa",    mid = "prof:First Aid",    place = 1, title = "KreftfriSigg",       label = "Første til max First Aid",     xp = 150 },
    { id = "cook",  mid = "prof:Cooking",      place = 1, title = "BakedSigg",          label = "Første til max Cooking",       xp = 150 },
    { id = "pois",  mid = "prof:Poisons",      place = 1, title = "FarligSigg",         label = "Første til max Poisons",       xp = 150 },
    { id = "eng",   mid = "prof:Engineering",  place = 1, title = "Cobber Pipe Sigg",   label = "Første til max Engineering",   xp = 200 },
    { id = "lock",  mid = "prof:Lockpicking",  place = 1, title = "PikkSigg",           label = "Første til max Lockpicking",   xp = 150 },
}
ns.GQ_ACH = ACH

-- Test-titler: alltid tilgjengelige å velge (for utprøving). Fjern senere.
ns.GQ_TEST_TITLES = { "SiggFather" }

-- databaser (lat init)
local function claimsDB()
    local g = GQ(); if not g then return nil end
    ns.db.gqclaims = ns.db.gqclaims or {}
    ns.db.gqtitle  = ns.db.gqtitle  or {}     -- key -> valgt tittel
    ns.db.gqtitleA = ns.db.gqtitleA or {}     -- key -> tidsstempel for valget
    return ns.db
end

local function claimListSorted(mid)
    local db = claimsDB(); if not db then return {} end
    local m = db.gqclaims[mid]; if not m then return {} end
    local list = {}
    for key, c in pairs(m) do list[#list + 1] = { key = key, at = c.at or 0, by = c.by, name = c.name } end
    table.sort(list, function(a, b) if a.at ~= b.at then return a.at < b.at end return a.key < b.key end)
    return list
end

function ns.GQ_AchHolder(achId)
    for _, a in ipairs(ACH) do
        if a.id == achId then
            local c = claimListSorted(a.mid)[a.place]
            if c then return { key = c.key, name = c.name } end
            return nil
        end
    end
end

-- Titler en konto har oppnådd
function ns.GQ_EarnedTitles(key)
    local out = {}
    if not key then return out end
    for _, a in ipairs(ACH) do
        local h = ns.GQ_AchHolder(a.id)
        if h and h.key == key then out[#out + 1] = a.title end
    end
    for _, t in ipairs(ns.GQ_TEST_TITLES or {}) do out[#out + 1] = t end
    return out
end

-- Tittelen en konto har valgt å vise (validert mot oppnådde)
function ns.GQ_AchTitleOf(key)
    local db = claimsDB(); if not db or not key then return nil end
    local chosen = db.gqtitle[key]
    if not chosen or chosen == "" then return nil end
    for _, t in ipairs(ns.GQ_EarnedTitles(key)) do
        if t == chosen then return chosen end
    end
    return nil
end

-- kontonavn (bnetName) for en nøkkel
local function accName(key)
    if ns.db then
        for _, rec in pairs(ns.db.members) do
            if rec.bnetKey == key and rec.bnetName and rec.bnetName ~= "" then return rec.bnetName end
        end
    end
    return key
end

local function myKey() return ns.AccountInfo and ns.AccountInfo() end
local function myName()
    local k = myKey()
    local n = k and accName(k)
    if n and n ~= k then return n end
    return (ns.Short and ns.Short(ns.PlayerName())) or ns.PlayerName()
end

---------------------------------------------------------------------------
-- Ledertavle: hvem leder hittil (for prestasjoner som ikke er vunnet ennå)
---------------------------------------------------------------------------
-- Kontoer sortert etter høyeste level (per Battle.net-konto)
function ns.GQ_LevelRanking()
    if not ns.db then return {} end
    local accMax, loose = {}, {}
    local function consider(full, lvl)
        lvl = lvl or 0
        local m = ns.db.members[full]
        local key = m and m.bnetKey
        if key then
            if lvl > (accMax[key] or -1) then accMax[key] = lvl end
        else
            loose[#loose + 1] = { name = (ns.Short and ns.Short(full)) or full, level = lvl }
        end
    end
    for full, r in pairs(ns.roster or {}) do consider(full, r.level) end
    for full, m in pairs(ns.db.members) do if not (ns.roster and ns.roster[full]) then consider(full, m.level) end end
    local list = {}
    for key, lvl in pairs(accMax) do list[#list + 1] = { name = accName(key), level = lvl } end
    for _, x in ipairs(loose) do list[#list + 1] = x end
    table.sort(list, function(a, b) if a.level ~= b.level then return a.level > b.level end return (a.name or "") < (b.name or "") end)
    return list
end

-- Høyeste skill-rank i en profesjon
function ns.GQ_ProfLeader(prof)
    if not ns.db then return nil end
    local best
    for full, m in pairs(ns.db.members) do
        if m.profs then
            for _, p in ipairs(m.profs) do
                if p[1] == prof and (p[2] or 0) > 0 and (not best or p[2] > best.rank) then
                    local nm = (m.bnetKey and accName(m.bnetKey)) or (ns.Short and ns.Short(full)) or full
                    best = { name = nm, rank = p[2] }
                end
            end
        end
    end
    return best
end

-- Leder-tekst for en prestasjon som ikke er vunnet ennå
function ns.GQ_AchLeader(achId)
    for _, a in ipairs(ACH) do
        if a.id == achId then
            if a.mid == "lvl60" then
                local who = ns.GQ_LevelRanking()[a.place]
                if who and (who.level or 0) > 0 then return who.name .. " (lvl " .. who.level .. ")" end
            else
                local prof = a.mid:match("^prof:(.+)$")
                local l = prof and ns.GQ_ProfLeader(prof)
                if l then return l.name .. " (" .. l.rank .. "/" .. PROF_MAX .. ")" end
            end
            return nil
        end
    end
end

---------------------------------------------------------------------------
-- Synk av krav (claims) og tittelvalg
---------------------------------------------------------------------------
local function encodeClaims()
    local db = claimsDB(); if not db then return "" end
    local recs = {}
    for mid, m in pairs(db.gqclaims) do
        for key, c in pairs(m) do
            recs[#recs + 1] = mid .. "~" .. key .. "~" .. (c.at or 0) .. "~" .. clean(c.by or "") .. "~" .. clean(c.name or "")
        end
    end
    return table.concat(recs, ",")
end

local function mergeClaim(mid, key, at, by, name)
    local db = claimsDB(); if not db or not mid or not key then return false end
    db.gqclaims[mid] = db.gqclaims[mid] or {}
    local cur = db.gqclaims[mid][key]
    if cur and (cur.at or 0) <= at then return false end
    db.gqclaims[mid][key] = { at = at, by = by, name = name }
    return true
end

function ns.GQ_BroadcastClaims()
    if not IsInGuild() or not ns.db then return end
    ns.Send("GQAH", encodeClaims(), "GUILD")
end

Handlers.GQAH = function(from, data)
    local changed = false
    for _, rec in ipairs(split(data or "", ",")) do
        local mid, key, at, by, name = rec:match("^(.-)~(.-)~(%d+)~(.-)~(.*)$")
        if mid and key then
            if mergeClaim(mid, key, tonumber(at) or 0, by, name) then changed = true end
        end
    end
    if changed then
        if ns.RefreshUI then ns.RefreshUI() end
        if ns.UpdateQuestsPanel then ns.UpdateQuestsPanel() end
    end
end

-- Tittelvalg
function ns.GQ_SetMyTitle(title)
    local db = claimsDB(); local k = myKey(); if not db or not k then return end
    db.gqtitle[k] = title or ""
    db.gqtitleA[k] = GetServerTime()
    ns.Send("GQTT", k .. "~" .. db.gqtitleA[k] .. "~" .. clean(title or ""), "GUILD")
    if ns.RefreshUI then ns.RefreshUI() end
end

Handlers.GQTT = function(from, data)
    local db = claimsDB(); if not db then return end
    local key, at, title = data:match("^(.-)~(%d+)~(.*)$")
    if not key then return end
    at = tonumber(at) or 0
    if at >= (db.gqtitleA[key] or 0) then
        db.gqtitle[key] = title or ""
        db.gqtitleA[key] = at
        if ns.RefreshUI then ns.RefreshUI() end
    end
end

---------------------------------------------------------------------------
-- Egen deteksjon: hevd milepæler for min konto
---------------------------------------------------------------------------
local function mySkillRanks()
    local out = {}
    local profs = ns.CollectProfessions and ns.CollectProfessions() or {}
    for _, p in ipairs(profs) do
        local nm, rk = p[1], p[2] or 0
        if nm then out[nm] = math.max(out[nm] or 0, rk) end
    end
    if GetNumSkillLines and GetSkillLineInfo then
        if ExpandSkillHeader then pcall(ExpandSkillHeader, 0) end
        local ok, n = pcall(GetNumSkillLines)
        if ok and n then
            for i = 1, n do
                local nm, isHeader, _, rank = GetSkillLineInfo(i)
                if nm and not isHeader then
                    if nm == "Lock Picking" then nm = "Lockpicking" end
                    out[nm] = math.max(out[nm] or 0, rank or 0)
                end
            end
        end
    end
    return out
end

local achShown
function ns.GQ_ScanMine(announce)
    local db = claimsDB(); if not db or not IsInGuild() then return end
    local k = myKey(); if not k then return end
    local nm = myName()
    local function claim(mid)
        db.gqclaims[mid] = db.gqclaims[mid] or {}
        if db.gqclaims[mid][k] then return false end
        db.gqclaims[mid][k] = { at = GetServerTime(), by = ns.PlayerName(), name = nm }
        return true
    end
    local changed = false
    if (UnitLevel("player") or 0) >= 60 then if claim("lvl60") then changed = true end end
    local ranks = mySkillRanks()
    for _, a in ipairs(ACH) do
        local prof = a.mid:match("^prof:(.+)$")
        if prof and (ranks[prof] or 0) >= PROF_MAX then
            if claim(a.mid) then changed = true end
        end
    end
    if changed then ns.GQ_BroadcastClaims() end
    -- (ingen «NY TITTEL»-varsel – tittelen dukker bare stille opp i dropdownen)
    if ns.RefreshUI then ns.RefreshUI() end
    if ns.UpdateQuestsPanel then ns.UpdateQuestsPanel() end
end

-- Hendelser som kan utløse ny milepæl
local achFrame = CreateFrame("Frame")
achFrame:RegisterEvent("PLAYER_LEVEL_UP")
if pcall(function() achFrame:RegisterEvent("SKILL_LINES_CHANGED") end) then end
achFrame:RegisterEvent("CHAT_MSG_SKILL")
achFrame:SetScript("OnEvent", function()
    if C_Timer then C_Timer.After(1, function() ns.GQ_ScanMine(true) end) end
end)

-- Samlet XP (og antall) fra oppnådde prestasjoner → teller mot guild-nivå
function ns.GQ_AchievementXP()
    local total, cnt = 0, 0
    for _, a in ipairs(ACH) do
        if ns.GQ_AchHolder(a.id) then
            total = total + (a.xp or 0)
            cnt = cnt + 1
        end
    end
    return total, cnt
end

-- Liste til visning: ekte mål + prestasjons-kort
function ns.GQ_DisplayList()
    local list = ns.GQ_Goals()
    for _, a in ipairs(ACH) do
        local holder = ns.GQ_AchHolder(a.id)
        list[#list + 1] = {
            ach = true, achId = a.id, kind = "ach", title = a.label, reward = a.title,
            holder = holder and holder.name or nil,
            target = 1, cur = holder and 1 or 0, unit = "", xp = a.xp or 0,
        }
    end
    return list
end

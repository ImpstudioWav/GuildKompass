local ADDON, ns = ...

local f = CreateFrame("Frame")
ns.eventFrame = f
ns.roster = {}

---------------------------------------------------------------------------
-- Hjelpefunksjoner
---------------------------------------------------------------------------
function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ccffGuildKompass|r: " .. tostring(msg))
end

function ns.Realm()
    local r = GetNormalizedRealmName and GetNormalizedRealmName()
    if not r or r == "" then
        r = (GetRealmName() or ""):gsub("[%s%-]", "")
    end
    return r
end

-- Navn uten realm: alt før SISTE bindestrek (fornavn + etternavn beholdes)
function ns.Short(name)
    if not name then return "?" end
    return name:match("^(.+)%-[^%-]*$") or name
end

-- Navnenøkkel brukt OVERALT. I WoW: Forever bytter serveren internt
-- realm-navn fra økt til økt (f.eks. CAMWOWEU4Realm6PvP / CAMWOWEU5Realm8PvP),
-- så samme karakter fikk ulike navn hos ulike spillere. Derfor brukes navnet
-- UTEN realm som nøkkel.
function ns.FullName(name)
    if not name or name == "" then return nil end
    return ns.Short(name)
end

-- Mitt navn i SAMME format som guildlista, money log og addon-meldinger.
-- I WoW: Forever har karakterer fornavn + etternavn, og UnitName("player")
-- gir ikke nødvendigvis hele navnet. Derfor finner vi oss selv i guildlista
-- (matchet på GUID) og bruker navnet derfra.
function ns.PlayerName()
    return ns.myRosterName or ns.FullName(UnitName("player"))
end

-- Alle navn som kan være "meg" (brukes for å kjenne igjen egne meldinger)
function ns.IsMe(full)
    return full ~= nil and (full == ns.myRosterName or full == ns.FullName(UnitName("player")))
end

-- Finn et guildmedlem fra et navn skrevet i chat (store/små bokstaver spiller ingen rolle)
function ns.FindMember(input)
    if not input or input == "" then return nil end
    local lower = input:gsub("^%s*@?%s*", ""):gsub("%s+$", ""):lower()
    if lower == "" then return nil end
    -- 1) live roster
    for full in pairs(ns.roster or {}) do
        if full:lower() == lower or ns.Short(full):lower() == lower then
            return full
        end
    end
    -- 2) lagrede medlemmer (roster er ofte ustabil/ufullstendig på Forever)
    if ns.db and ns.db.members then
        for full in pairs(ns.db.members) do
            if full:lower() == lower or ns.Short(full):lower() == lower then
                return full
            end
        end
    end
    return nil
end

function ns.FormatDuration(sec)
    sec = math.max(0, math.floor(sec or 0))
    local d = math.floor(sec / 86400)
    local h = math.floor((sec % 86400) / 3600)
    local m = math.floor((sec % 3600) / 60)
    if d > 0 then return string.format("%dd %dt", d, h) end
    if h > 0 then return string.format("%dt %dm", h, m) end
    return string.format("%dm", m)
end

function ns.FormatMoney(copper)
    copper = math.floor(copper or 0)
    if copper == 0 then return "0" end
    local neg = copper < 0
    local fn = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString) or GetCoinTextureString
    local text = fn and fn(math.abs(copper))
    if not text or text == "" then
        local a = math.abs(copper)
        text = string.format("%dg %ds %dc", math.floor(a / 10000), math.floor(a / 100) % 100, a % 100)
    end
    return neg and ("-" .. text) or text
end

-- Ren tekst uten mynt-ikoner, egnet for guildchat (f.eks. "10g50s", "10s")
function ns.MoneyText(copper)
    copper = math.floor(copper or 0)
    local neg = copper < 0
    local a = math.abs(copper)
    local g, s, c = math.floor(a / 10000), math.floor(a / 100) % 100, a % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "g" end
    if s > 0 then parts[#parts + 1] = s .. "s" end
    if c > 0 then parts[#parts + 1] = c .. "c" end
    local text = #parts > 0 and table.concat(parts) or "0"
    return neg and ("-" .. text) or text
end

-- Gjenbrukbar størrelse-kontroll: [Størrelse] [–] [=slider=] [+] [NN%]
-- cfg = { min, max, step, width, get=function() end, set=function(v) end }
function ns.MakeScaleControl(parent, cfg)
    local MIN, MAX, STEP = cfg.min or 0.6, cfg.max or 1.4, cfg.step or 0.05
    local W = cfg.width or 150
    local function round(v) return math.floor((v - MIN) / STEP + 0.5) * STEP + MIN end
    local function clamp(v) return math.max(MIN, math.min(MAX, round(v))) end

    local h = CreateFrame("Frame", nil, parent)
    h:SetSize(W + 170, 24)
    local title = h:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    title:SetPoint("LEFT", 0, 0); title:SetText("Størrelse"); title:SetJustifyH("LEFT")

    local minus = CreateFrame("Button", nil, h, "UIPanelButtonTemplate")
    minus:SetSize(24, 22); minus:SetText("–"); minus:SetPoint("LEFT", title, "RIGHT", 6, 0)

    local slider = CreateFrame("Slider", nil, h)
    slider:SetOrientation("HORIZONTAL"); slider:SetSize(W, 16)
    slider:SetPoint("LEFT", minus, "RIGHT", 8, 0)
    slider:SetMinMaxValues(MIN, MAX); slider:SetValueStep(STEP)
    if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
    slider:SetHitRectInsets(0, 0, -8, -8)          -- lettere å treffe
    slider:EnableMouseWheel(true)
    local thumb = slider:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    thumb:SetSize(28, 28); slider:SetThumbTexture(thumb)
    local track = slider:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("LEFT", 2, 0); track:SetPoint("RIGHT", -2, 0); track:SetHeight(8)
    track:SetColorTexture(0.7, 0.58, 0.32, 0.55)

    local plus = CreateFrame("Button", nil, h, "UIPanelButtonTemplate")
    plus:SetSize(24, 22); plus:SetText("+"); plus:SetPoint("LEFT", slider, "RIGHT", 8, 0)

    local pct = h:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pct:SetPoint("LEFT", plus, "RIGHT", 8, 0); pct:SetWidth(46); pct:SetJustifyH("LEFT")
    pct:SetTextColor(1, 0.82, 0)

    local applying = false
    local function setPct(v) pct:SetText(string.format("%d%%", math.floor(v * 100 + 0.5))) end
    local function apply(v)
        v = clamp(v)
        applying = true; slider:SetValue(v); applying = false
        setPct(v)
        if cfg.set then cfg.set(v) end
    end
    slider:SetScript("OnValueChanged", function(_, v) if not applying then apply(v) end end)
    slider:SetScript("OnMouseWheel", function(_, d) apply((cfg.get and cfg.get() or 1) + d * STEP) end)
    minus:SetScript("OnClick", function() apply((cfg.get and cfg.get() or 1) - STEP) end)
    plus:SetScript("OnClick", function() apply((cfg.get and cfg.get() or 1) + STEP) end)

    function h:Refresh()
        local v = clamp(cfg.get and cfg.get() or 1)
        applying = true; slider:SetValue(v); applying = false
        setPct(v)
    end
    h:Refresh()
    return h
end

-- "10g50s", "10g", "50s", "10" (= 10 gull), "-5g" for korrigering
function ns.ParseMoney(s)
    if not s or s == "" then return nil end
    s = s:lower():gsub("%s", "")
    local neg = false
    if s:sub(1, 1) == "-" then neg = true; s = s:sub(2) end
    local total = 0
    if s:match("^%d+$") then
        total = tonumber(s) * 10000
    else
        local found = false
        for num, unit in s:gmatch("(%d+)([gsc])") do
            found = true
            num = tonumber(num)
            if unit == "g" then total = total + num * 10000
            elseif unit == "s" then total = total + num * 100
            else total = total + num end
        end
        if not found then return nil end
    end
    if neg then total = -total end
    return total
end

function ns.SecondsUntilWeeklyReset()
    -- GM-innstilt vedlikeholdsdag (1=søndag) overstyrer alt annet
    local dr = ns.db and ns.db.dr
    local manualWday = dr and dr.resetWday and dr.resetWday >= 1 and dr.resetWday or nil
    if not manualWday and C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset then
        local s = C_DateAndTime.GetSecondsUntilWeeklyReset()
        if s and s > 0 then return s end
    end
    local resetWday, resetHour
    if manualWday then
        resetWday, resetHour = manualWday - 1, (dr.resetHour or 4)   -- 1=søndag → 0=søndag
    else
        -- Reserve: EU onsdag 04:00 UTC, US tirsdag 15:00 UTC
        local region = (GetCurrentRegion and GetCurrentRegion()) or 3
        resetWday, resetHour = 3, 4
        if region == 1 then resetWday, resetHour = 2, 15 end
    end
    local now = GetServerTime()
    local t = date("!*t", now)
    local secToday = t.hour * 3600 + t.min * 60 + t.sec
    local wday = t.wday - 1 -- 0 = søndag
    local s = ((resetWday - wday) % 7) * 86400 + resetHour * 3600 - secToday
    if s <= 0 then s = s + 7 * 86400 end
    return s
end

function ns.WeekStart()
    local base = GetServerTime() + ns.SecondsUntilWeeklyReset() - 7 * 86400
    -- manuell GM-nullstilling kan flytte ukestart fremover
    local dr = ns.db and ns.db.dr
    if dr and (dr.weekReset or 0) > base then base = dr.weekReset end
    return base
end

---------------------------------------------------------------------------
-- Database (lagres per guild)
---------------------------------------------------------------------------
function ns.InitDB()
    GuildKompassDB = GuildKompassDB or {}
    local g = GuildKompassDB
    g.guilds  = g.guilds or {}
    g.minimap = g.minimap or { angle = 200, hide = false }
    g.announce = g.announce or false          -- death roll: annonser seire i guildchat
    if g.watch == nil then g.watch = true end -- death roll: åpne arenaen når andres duell starter
    g.arenaScale = g.arenaScale or 1          -- death roll: størrelse på arena-vinduet
    if g.eventWarnings == nil then g.eventWarnings = true end  -- varsel når noen lager nytt event
    ns.global = g
end

-- Slår sammen gamle data lagret under "Guild-Realm" (ett sett per realm-navn
-- serveren har brukt) til ett sett under guildnavnet, og fjerner realm fra
-- alle navn. Samme karakter under flere realm-navn blir én (nyeste vinner).
function ns.MergeGuildData(gname)
    local guilds = ns.global.guilds
    local sources = {}
    for k, g in pairs(guilds) do
        if type(g) == "table" and (k == gname or k:sub(1, #gname + 1) == gname .. "-") then
            sources[#sources + 1] = g
            guilds[k] = nil
        end
    end
    if #sources == 0 then return end
    local S = ns.Short
    local out = { members = {}, tributes = {}, config = nil, myChars = {}, epoch = { t = 0, by = "" } }
    for _, g in ipairs(sources) do
        for name, rec in pairs(g.members or {}) do
            local s = S(name)
            local old = out.members[s]
            if not old or (old.updated or 0) < (rec.updated or 0) then
                rec.name = s
                out.members[s] = rec
            end
        end
        for id, e in pairs(g.tributes or {}) do
            if e.from then e.from = S(e.from) end
            if e.banker then e.banker = S(e.banker) end
            out.tributes[id] = out.tributes[id] or e
        end
        for name, lvl in pairs(g.myChars or {}) do
            local s = S(name)
            out.myChars[s] = math.max(out.myChars[s] or 0, tonumber(lvl) or 0)
        end
        if g.config and (not out.config or (g.config.updated or 0) > (out.config.updated or 0)) then
            out.config = g.config
        end
        if g.epoch and (g.epoch.t or 0) > out.epoch.t then out.epoch = g.epoch end
        if g.bank and (not out.bank or (g.bank.time or 0) > (out.bank.time or 0)) then out.bank = g.bank end
        if g.snap and (not out.snap or (g.snap.t or 0) > (out.snap.t or 0)) then out.snap = g.snap end
        if g.myMain and g.myMain ~= "" then out.myMain = S(g.myMain) end
        for k, v in pairs(g) do
            if out[k] == nil then out[k] = v end
        end
    end
    if out.config and out.config.bankers then
        local b = {}
        for n, v in pairs(out.config.bankers) do b[S(n)] = v end
        out.config.bankers = b
    end
    if out.config and out.config.by then out.config.by = S(out.config.by) end
    if out.epoch.by then out.epoch.by = S(out.epoch.by) end
    guilds[gname] = out
end

function ns.SetGuild()
    if not ns.global then return end
    local gname = GetGuildInfo("player")
    if not gname then return end
    local key = gname   -- uten realm (realm-navnet skifter i Forever)
    if ns.guildKey == key and ns.db then return end
    ns.MergeGuildData(key)
    local g = ns.global.guilds[key] or {}
    ns.global.guilds[key] = g
    g.members  = g.members or {}
    g.tributes = g.tributes or {}
    g.config   = g.config or {}
    local c = g.config
    c.bankers     = c.bankers or {}
    c.officerRank = c.officerRank or 1
    c.updated     = c.updated or 0
    g.epoch = g.epoch or { t = 0, by = "" }
    if not c.openRaids then
        c.openRaids = {}
        for _, r in ipairs(ns.RAIDS) do c.openRaids[r.key] = r.open end
    end
    ns.db = g
    ns.guildKey = key
    if ns.EnsureDR then ns.EnsureDR() end       -- death roll / events-data
    if ns.EnsureRaids then ns.EnsureRaids() end -- raid-påmeldinger
end

---------------------------------------------------------------------------
-- Guild-roster
---------------------------------------------------------------------------
function ns.RequestRoster()
    if not IsInGuild() then return end
    if SetGuildRosterShowOffline then SetGuildRosterShowOffline(true) end
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    elseif GuildRoster then
        GuildRoster()
    end
end

function ns.UpdateRoster()
    if not IsInGuild() then wipe(ns.roster); return end
    local n = GetNumGuildMembers()
    if not n or n == 0 then return end
    wipe(ns.roster)
    local myGuid = UnitGUID("player")
    for i = 1, n do
        local name, rankName, rankIndex, level, _, zone, _, _, online, _, classFile,
              _, _, _, _, _, guid = GetGuildRosterInfo(i)
        if name then
            local full = ns.FullName(name)
            if guid and myGuid and guid == myGuid then ns.SetMyRosterName(full) end
            local y, m, d, h = GetGuildRosterLastOnline(i)
            ns.roster[full] = {
                rank = rankName, rankIndex = rankIndex, level = level, class = classFile,
                online = online, zone = zone, lastY = y, lastM = m, lastD = d, lastH = h,
            }
        end
    end
    ns.RefreshUI()
end

-- Fant meg selv i guildlista. Flytt data lagret under det gamle navnet.
function ns.SetMyRosterName(full)
    if not full or full == ns.myRosterName then return end
    local old = ns.PlayerName()
    ns.myRosterName = full
    if ns.db and old and old ~= full then
        if ns.db.members[old] then
            ns.db.members[full] = ns.db.members[old]
            ns.db.members[full].name = full
            ns.db.members[old] = nil
        end
        if ns.db.myChars and ns.db.myChars[old] then
            ns.db.myChars[full] = ns.db.myChars[old]
            ns.db.myChars[old] = nil
        end
        if ns.db.myMain == old then ns.db.myMain = full end
        for _, e in pairs(ns.db.tributes) do
            if e.banker == old then e.banker = full end
            if e.from == old then e.from = full end
        end
        ns.tribCache = nil
        C_Timer.After(1, function() ns.UpdateSelf(true) end)
    end
end

-- Finn rankIndex for et navn: live roster først, så lagrede medlemsdata
-- (roster kan være ustabil på Forever – fallbacken sikrer lokale rolle-sjekker).
local function RankOf(full)
    if not full then return nil end
    local fn = ns.FullName(full)
    local r = ns.roster and (ns.roster[fn] or ns.roster[full])
    if r and r.rankIndex ~= nil then return r.rankIndex end
    if ns.db and ns.db.members then
        local key = ns.Key(full)
        for name, rec in pairs(ns.db.members) do
            if rec.rankIndex ~= nil and ns.Key(name) == key then return rec.rankIndex end
        end
    end
    return nil
end
ns.RankOf = RankOf

function ns.IsOfficer(full)
    if not ns.db or not full then return false end
    local rank = RankOf(full)
    return rank ~= nil and rank <= ns.db.config.officerRank
end

function ns.IsBanker(full)
    return (ns.db and full and ns.db.config.bankers[full]) and true or false
end

function ns.IsGM(full)
    if not full then return false end
    return RankOf(full) == 0
end

-- Sammenligningsnøkkel: navn uten realm, små bokstaver (for death roll o.l.)
function ns.Key(name)
    return ns.Short(name or "?"):lower()
end

-- Klassen til et navn (fra guildlista, ellers fra lagrede medlemsdata)
function ns.ClassOf(name)
    if not name then return nil end
    local r = ns.roster[ns.FullName(name)]
    if r and r.class then return r.class end
    local rec = ns.db and ns.db.members[ns.Short(name)]
    return rec and rec.class
end

function ns.Sound(kit)
    if SOUNDKIT and SOUNDKIT[kit] then pcall(PlaySound, SOUNDKIT[kit]) end
end

---------------------------------------------------------------------------
-- Egne data
---------------------------------------------------------------------------
local lastSig, broadcastPending, updatePending

function ns.UpdateSelf(force)
    if not ns.db then return end
    local rec = ns.CollectSelf()
    if not rec then return end
    local saved = rec.updated
    rec.updated = 0
    local sig = ns.EncodeRecord(rec)
    rec.updated = saved

    -- Sammenlign med det jeg har lagret (også etter /reload eller ny innlogging)
    local old = ns.db.members[rec.name]
    if not lastSig and old then
        local ou = old.updated
        old.updated = 0
        lastSig = ns.EncodeRecord(old)
        old.updated = ou
    end
    local changed = (sig ~= lastSig)
    -- Uendret: behold gammelt tidsstempel, så synken ikke tror det er nye data
    if changed or force or not old then
        ns.db.members[rec.name] = rec
    end
    if force or changed then
        lastSig = sig
        if not broadcastPending then
            broadcastPending = true
            C_Timer.After(force and 1 or 3, function()
                broadcastPending = false
                ns.BroadcastSelf()
            end)
        end
    end
    ns.RefreshUI()
end

function ns.ScheduleSelfUpdate()
    if updatePending then return end
    updatePending = true
    C_Timer.After(2, function()
        updatePending = false
        ns.UpdateSelf()
    end)
end

function ns.RefreshUI()
    if ns.UI and ns.UI.Update then ns.UI:Update() end
end

---------------------------------------------------------------------------
-- Konfig (bankere, åpne raids) – endres av offiserer og synkes
---------------------------------------------------------------------------
function ns.ConfigChanged()
    local c = ns.db.config
    c.updated = GetServerTime()
    c.by = ns.PlayerName()
    ns.Send("CFG", ns.EncodeConfig(c), "GUILD")
    ns.RefreshUI()
end

---------------------------------------------------------------------------
-- Slash-kommandoer
---------------------------------------------------------------------------
local HELP = {
    "|cffffd100/gk|r – åpne/lukke vinduet",
    "|cffffd100/gk synk|r – synk alle data mellom alle i guilden som er pålogget",
    "|cffffd100/gk reset|r – (offiser, test) nullstill alle data for hele guilden",
    "|cffffd100/gk logg|r – (ved guild banken) vis bankens money log og sammenlign med addonen",
    "|cffffd100/gk status|r – hvem addonen hører fra, og om alle er synkronisert",
    "|cffffd100/gk spec|r – vis talentene addonen leser",
    "|cffffd100/gk gull <navn> <beløp>|r – (offiser) før/korriger bidrag manuelt, f.eks. 25g eller -5g",
    "|cffffd100/gk offiserrang <tall>|r – (guildmaster) høyeste rangnummer som regnes som offiser (0 = GM)",
    "|cffffd100/gk main <navn>|r – velg main blant dine egne karakterer (eller høyreklikk i vinduet)",
    "|cffffd100/gk main|r – tilbake til automatisk (høyest level)",
    "|cffffd100/gk mine|r – vis karakterene på Battle.net-kontoen din",
    "|cffffd100/gk skala <0.6–1.4>|r – gjør vinduet mindre eller større (standard 1)",
    "|cffffd100/gk minimap|r – vis/skjul minimap-knappen",
}

local function RequireOfficer()
    if ns.IsOfficer(ns.PlayerName()) then return true end
    ns.Print("Bare offiserer kan gjøre dette.")
    return false
end

function ns.HandleSlash(msg)
    msg = msg or ""
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()

    if cmd == "" then
        ns.UI:Toggle()
        return
    end
    if cmd == "skala" or cmd == "scale" then
        local n = tonumber((rest or ""):gsub(",", ".") .. "")
        if not n or n < 0.6 or n > 1.4 then ns.Print("Bruk: /gk skala 0.9   (fra 0.6 til 1.4)") return end
        ns.global.scale = n
        if ns.UI.frame then ns.UI.frame:SetScale(n) end
        if ns.UI.scaleCtl then ns.UI.scaleCtl:Refresh() end
        ns.Print("Skala satt til " .. n .. ".")
        return
    end
    if cmd == "varsel" then
        ns.global.eventWarnings = not ns.global.eventWarnings
        ns.Print("Varsel om nye events: " .. (ns.global.eventWarnings and "PÅ" or "AV"))
        ns.RefreshUI()
        return
    end
    if not ns.db then ns.Print("Du er ikke i en guild (eller guilden er ikke lastet ennå).") return end

    if cmd == "synk" or cmd == "sync" then
        ns.RequestRoster()
        ns.UpdateSelf(true)
        if ns.StartSync(true) then
            ns.Print("Synker med alle i guilden som er pålogget …")
        end

    elseif cmd == "status" then
        ns.PrintStatus()

    elseif cmd == "test" then
        ns.SelfTest()

    elseif cmd == "spec" then
        ns.PrintSpec()
        ns.UpdateSelf(true)

    elseif cmd == "logg" or cmd == "log" then
        ns.DumpMoneyLog()

    elseif cmd == "reset" or cmd == "nullstill" then
        if not RequireOfficer() then return end
        StaticPopup_Show("GUILDKOMPASS_RESET")

    elseif cmd == "gull" or cmd == "gold" then
        if not RequireOfficer() then return end
        local name, amount = rest:match("^(%S+)%s+(.+)$")
        local full = ns.FindMember(name)
        local copper = ns.ParseMoney(amount)
        if not full or not copper then
            ns.Print("Bruk: /gk gull <navn> <beløp>   f.eks. /gk gull Thrall 25g50s")
            return
        end
        ns.RecordTribute(full, copper, "manuell")
        ns.Print(string.format("Registrerte %s fra %s.", ns.FormatMoney(copper), ns.Short(full)))

    elseif cmd == "offiserrang" then
        local r = ns.roster[ns.PlayerName()]
        if not r or r.rankIndex ~= 0 then ns.Print("Bare guildmaster kan endre dette.") return end
        local n = tonumber(rest)
        if not n or n < 0 then ns.Print("Bruk: /gk offiserrang <tall>") return end
        ns.db.config.officerRank = n
        ns.Print("Rang 0–" .. n .. " regnes nå som offiserer.")
        ns.ConfigChanged()

    elseif cmd == "main" then
        if rest == "" then ns.SetMain(nil) return end
        local full = ns.FindMember(rest)
        if not full then ns.Print("Fant ikke '" .. rest .. "' i guilden.") return end
        ns.SetMain(full)

    elseif cmd == "mine" then
        local _, accName = ns.AccountInfo()
        local names = {}
        for _, n in ipairs(ns.MyChars()) do
            names[#names + 1] = ns.Short(n) .. ((ns.db.myMain == n) and " (main)" or "")
        end
        ns.Print("Battle.net: " .. (accName ~= "" and accName or "ukjent") .. " – " .. table.concat(names, ", "))

    elseif cmd == "minimap" then
        ns.global.minimap.hide = not ns.global.minimap.hide
        ns.UpdateMinimapButton()

    elseif cmd == "arena" then
        if ns.Arena then ns.Arena:Toggle() end

    elseif cmd == "event" or cmd == "events" then
        if ns.UI.OpenTab then ns.UI:OpenTab("events") end

    elseif cmd == "roll" then
        if ns.DoRoll then ns.DoRoll() end

    else
        for _, line in ipairs(HELP) do DEFAULT_CHAT_FRAME:AddMessage(line) end
    end
end

StaticPopupDialogs["GUILDKOMPASS_RESET"] = {
    text = "|cffff5555Nullstille ALLE GuildKompass-data for hele guilden?|r\n\n"
        .. "Medlemsdata, gullbidrag og bankbeholdning slettes hos alle – også de som er avlogget "
        .. "(de nullstilles neste gang de logger inn).\n\nDette kan ikke angres.",
    button1 = YES or "Ja",
    button2 = NO or "Nei",
    OnAccept = function() ns.GuildReset() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    showAlert = true,
    preferredIndex = 3,
}

SLASH_GUILDKOMPASS1 = "/gk"
SLASH_GUILDKOMPASS2 = "/guildkompass"
SlashCmdList.GUILDKOMPASS = function(msg) ns.HandleSlash(msg) end

-- /dr og /deathroll: åpne Death Roll-arenaen (eller utfordre direkte: /dr Navn 10)
SLASH_GKDEATHROLL1 = "/dr"
SLASH_GKDEATHROLL2 = "/deathroll"
SlashCmdList.GKDEATHROLL = function(msg)
    if ns.HandleDeathRollSlash then ns.HandleDeathRollSlash(msg) end
end

---------------------------------------------------------------------------
-- Hendelser
---------------------------------------------------------------------------
-- Alt som kan endre mine data. Hver av dem fører til at jeg sjekker meg selv,
-- og sender til hele guilden hvis noe faktisk er endret.
local SELF_EVENTS = {
    -- level
    PLAYER_LEVEL_UP = true, PLAYER_LEVEL_CHANGED = true,
    -- utstyr
    PLAYER_EQUIPMENT_CHANGED = true,
    -- profesjoner ("Your skill in X has increased to Y", lære/glemme profesjon)
    CHAT_MSG_SKILL = true, SKILL_LINES_CHANGED = true, TRADE_SKILL_LIST_UPDATE = true,
    LEARNED_SPELL_IN_TAB = true, TRADE_SKILL_SHOW = true,
    -- talenter/spec
    CHARACTER_POINTS_CHANGED = true, PLAYER_SPECIALIZATION_CHANGED = true,
    TRAIT_CONFIG_UPDATED = true, ACTIVE_TALENT_GROUP_CHANGED = true,
    -- Battle.net
    BN_INFO_CHANGED = true,
}
local BANK_EVENTS = {
    GUILDBANK_UPDATE_MONEY = true,
    PLAYER_INTERACTION_MANAGER_FRAME_SHOW = true, PLAYER_INTERACTION_MANAGER_FRAME_HIDE = true,
    GUILDBANKFRAME_OPENED = true, GUILDBANKFRAME_CLOSED = true, GUILDBANKLOG_UPDATE = true,
    GUILDBANKBAGSLOTS_CHANGED = true, GUILDBANK_UPDATE_TABS = true,
}

-- pcall: hendelser som ikke finnes i denne klienten hoppes over i stedet for å gi feil
local function Reg(e) pcall(f.RegisterEvent, f, e) end
Reg("ADDON_LOADED")
Reg("PLAYER_LOGIN")
Reg("GUILD_ROSTER_UPDATE")
Reg("PLAYER_GUILD_UPDATE")
Reg("CHAT_MSG_ADDON")
Reg("GET_ITEM_INFO_RECEIVED")
for e in pairs(SELF_EVENTS) do Reg(e) end
for e in pairs(BANK_EVENTS) do Reg(e) end

f:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == ADDON then ns.InitDB() end
        -- Blizzards guild bank-vindu lastes først når banken åpnes første gang
        if name == "Blizzard_GuildBankUI" then ns.HookGuildBankFrame() end

    elseif event == "PLAYER_LOGIN" then
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(ns.PREFIX)
        elseif RegisterAddonMessagePrefix then
            RegisterAddonMessagePrefix(ns.PREFIX)
        end
        ns.SetGuild()
        ns.RequestRoster()
        ns.CreateMinimapButton()
        ns.HookGuildBank()
        ns.HookGuildBankFrame()
        C_Timer.After(5, function()
            ns.SetGuild()
            ns.ScheduleSelfUpdate()
        end)
        -- Automatisk synk ved innlogging: henter alt du gikk glipp av mens du var borte
        C_Timer.After(12, function() ns.StartSync(false) end)
        -- Death roll / events: hent historikk og kommende events, vis event-dag-banner
        C_Timer.After(10, function() if ns.DR_OnLogin then ns.DR_OnLogin() end end)
        -- Sikkerhetsnett: sjekk meg selv hvert minutt. Sender bare hvis noe er
        -- endret, så en tapt hendelse forsinker en oppdatering med maks ~1 min.
        C_Timer.NewTicker(60, function()
            ns.RequestRoster()
            ns.ScheduleSelfUpdate()
        end)

    elseif event == "GUILD_ROSTER_UPDATE" or event == "PLAYER_GUILD_UPDATE" then
        ns.SetGuild()
        ns.UpdateRoster()

    elseif event == "CHAT_MSG_ADDON" then
        ns.OnAddonMessage(...)

    elseif event == "GET_ITEM_INFO_RECEIVED" then
        if ns.ilvlPending then ns.ScheduleSelfUpdate() end

    elseif SELF_EVENTS[event] then
        ns.ScheduleSelfUpdate()

    elseif BANK_EVENTS[event] then
        ns.OnBankEvent(event, ...)
    end
end)

-- Midlertidig diagnostikk (v1.22.1): fang forbudte/blokkerte handlinger og vis
-- funksjonsnavnet, så vi finner akkurat hva som trigger taint-popupen.
do
    local diag = CreateFrame("Frame")
    diag:RegisterEvent("ADDON_ACTION_FORBIDDEN")
    diag:RegisterEvent("ADDON_ACTION_BLOCKED")
    diag:SetScript("OnEvent", function(_, ev, addon, func)
        if addon == "GuildKompass" then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff3030[GK-DIAG]|r " .. tostring(ev)
                .. "  funksjon = |cffffff00" .. tostring(func) .. "|r")
        end
    end)
end

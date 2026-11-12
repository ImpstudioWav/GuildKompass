local ADDON, ns = ...

local UI = {}
ns.UI = UI

---------------------------------------------------------------------------
-- Mål og oppsett
---------------------------------------------------------------------------
local WIDTH, HEIGHT = 920, 540
local SIDE = 16
local TOP_INSET, BOTTOM_INSET = 86, 46
local HEADER_H, ROW_H = 24, 20
local SCROLL_W = 26
local LIST_W = WIDTH - SIDE * 2 - SCROLL_W - 8
local NUM_ROWS = math.floor((HEIGHT - TOP_INSET - BOTTOM_INSET - HEADER_H - 10) / ROW_H)
local MAX_COLS = 10

local TABS = {
    { id = "overview", label = "Medlemmer" },
    { id = "profs",    label = "Profesjoner" },
    { id = "quests",   label = "Guild Quests" },
    { id = "gold",     label = "Gullbidrag" },
    { id = "log",      label = "Gull-logg" },
    { id = "raid",     label = "Raid" },
    { id = "events",   label = "Death Roll" },
}

local currentTab = "overview"
local sortState = {
    overview = { col = 4, asc = false },
    profs    = { col = 1, asc = true },
    gold     = { col = 2, asc = false },
    log      = { col = 1, asc = false },
    raid     = { col = 1, asc = true },
    events   = { col = 1, asc = true },
    quests   = { col = 1, asc = true },
}
local searchText = ""
local onlyAddon = false
local hideAlts = false

---------------------------------------------------------------------------
-- Farger, ikoner og tekst-hjelpere
---------------------------------------------------------------------------
local GREY, GREEN, RED, YELLOW = "|cff888888", "|cff55ff55", "|cffff5555", "|cffffd100"
local ORANGE, PURPLE, WHITE, LEGEND = "|cffff9933", "|cffa335ee", "|cffffffff", "|cffff8000"

local TEX_CLASSES  = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes"
local BNET_BLUE    = "|cff82c5ff"

local PROF_ICONS = {
    ["Alchemy"]        = "Interface\\Icons\\Trade_Alchemy",
    ["Blacksmithing"]  = "Interface\\Icons\\Trade_BlackSmithing",
    ["Enchanting"]     = "Interface\\Icons\\Trade_Engraving",
    ["Engineering"]    = "Interface\\Icons\\Trade_Engineering",
    ["Herbalism"]      = "Interface\\Icons\\Spell_Nature_NatureTouchGrow",
    ["Leatherworking"] = "Interface\\Icons\\INV_Misc_ArmorKit_17",
    ["Mining"]         = "Interface\\Icons\\Trade_Mining",
    ["Skinning"]       = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01",
    ["Tailoring"]      = "Interface\\Icons\\Trade_Tailoring",
    ["Cooking"]        = "Interface\\Icons\\INV_Misc_Food_15",
    ["First Aid"]      = "Interface\\Icons\\Spell_Holy_SealOfSacrifice",
    ["Fishing"]        = "Interface\\Icons\\Trade_Fishing",
    ["Lockpicking"]    = "Interface\\Icons\\INV_Misc_Key_03",
    ["Poisons"]        = "Interface\\Icons\\Trade_BrewPoison",
}

local function Tex(path, size)
    return "|T" .. path .. ":" .. size .. ":" .. size .. "|t"
end

-- Ikon med avskåret kant (som i spellbook)
local function IconTex(path, size)
    return "|T" .. path .. ":" .. size .. ":" .. size .. ":0:0:64:64:5:59:5:59|t"
end

local function ClassIcon(class, size)
    local c = class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
    if not c then return "" end
    return string.format("|T%s:%d:%d:0:0:256:256:%d:%d:%d:%d|t", TEX_CLASSES, size, size,
        math.floor(c[1] * 256 + 0.5), math.floor(c[2] * 256 + 0.5),
        math.floor(c[3] * 256 + 0.5), math.floor(c[4] * 256 + 0.5))
end

local function ClassHex(class, dim)
    local colors = CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS
    local c = class and colors and colors[class]
    local r, g, b = 1, 1, 1
    if c then r, g, b = c.r, c.g, c.b end
    if dim then r, g, b = r * 0.55, g * 0.55, b * 0.55 end
    return string.format("ff%02x%02x%02x", math.floor(r * 255), math.floor(g * 255), math.floor(b * 255))
end

local function ClassName(class)
    return (class and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]) or class or "?"
end

local function Strip(s)
    s = tostring(s or "")
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", "")
    return s
end

local function Sound(kit)
    if SOUNDKIT and SOUNDKIT[kit] then PlaySound(SOUNDKIT[kit]) end
end

---------------------------------------------------------------------------
-- Celle-tekster
---------------------------------------------------------------------------
-- Navn + Battle.net-kontonavn etter, i Battle.net-blått
local function NameText(m)
    local offline = m.last ~= nil and not m.online
    local s = ClassIcon(m.class, 16) .. " |c" .. ClassHex(m.class, offline) .. m.short .. "|r"
    if m.bnet and m.bnet ~= "" then
        s = s .. "  " .. BNET_BLUE .. m.bnet .. "|r"
    end
    return s
end

local function LastOnline(m)
    if m.online then return GREEN .. "Pålogget|r" end
    local r = m.last
    if not r or r.lastY == nil then return GREY .. "-|r" end
    if (r.lastY or 0) > 0 then return GREY .. r.lastY .. " år|r" end
    if (r.lastM or 0) > 0 then return GREY .. r.lastM .. " mnd|r" end
    if (r.lastD or 0) > 0 then return r.lastD .. " d" end
    if (r.lastH or 0) > 0 then return r.lastH .. " t" end
    return "< 1 t"
end

local function LastOnlineSort(m)
    if m.online then return 0 end
    local r = m.last
    if not r or r.lastY == nil then return 1e9 end
    return (r.lastY or 0) * 8760 + (r.lastM or 0) * 730 + (r.lastD or 0) * 24 + (r.lastH or 0) + 0.5
end

local function GetProf(rec, which)
    -- which: 1 eller 2 = første/andre hovedprofesjon, ellers navnet på en sekundær
    if not rec or not rec.profs then return nil end
    local n = 0
    for _, p in ipairs(rec.profs) do
        if type(which) == "number" then
            if ns.PROFESSIONS[p[1]] ~= "secondary" then
                n = n + 1
                if n == which then return p end
            end
        elseif p[1] == which then
            return p
        end
    end
end

local function ProfText(p, showName)
    if not p then return GREY .. "-|r" end
    local color = WHITE
    if p[3] > 0 and p[2] >= p[3] then color = (p[3] >= 300) and LEGEND or GREEN end
    local icon = PROF_ICONS[p[1]] and (IconTex(PROF_ICONS[p[1]], 15) .. " ") or ""
    local skill = color .. p[2] .. "|r" .. GREY .. "/" .. p[3] .. "|r"
    if showName then return icon .. p[1] .. "  " .. skill end
    return icon .. skill
end

local function MainText(m)
    if m.main then return GREY .. "Alt|r" end
    if m.rec and m.rec.bnetKey then return YELLOW .. "Main|r" end
    return GREY .. "-|r"
end

-- Karakter under en kontooverskrift: innrykk, krone for main, ingen kontonavn
local TEX_CROWN = "Interface\\GroupFrame\\UI-Group-LeaderIcon"

-- Ikon per transaksjonstype i Gull-loggen
local KIND_ICON = {
    deposit        = "Interface\\Icons\\INV_Misc_Coin_01",
    depositSummary = "Interface\\Icons\\INV_Misc_Coin_01",
    withdraw       = "Interface\\Icons\\INV_Misc_Coin_02",
    withdrawForTab = "Interface\\Icons\\INV_Misc_Coin_02",
    repair         = "Interface\\Icons\\Trade_BlackSmithing",
    buyTab         = "Interface\\Icons\\INV_Misc_Bag_08",
}
local function KindIcon(kind, out)
    local tex = KIND_ICON[kind or "deposit"]
        or (out and "Interface\\Icons\\INV_Misc_Coin_02" or "Interface\\Icons\\INV_Misc_Coin_01")
    return IconTex(tex, 16)
end

local function ChildNameText(m)
    local offline = m.last ~= nil and not m.online
    local mark = (not m.main and m.rec and m.rec.bnetKey) and (Tex(TEX_CROWN, 12) .. " ") or "      "
    return "    " .. mark .. ClassIcon(m.class, 16) .. " |c" .. ClassHex(m.class, offline) .. m.short .. "|r"
end

-- Overskriftsrad for en Battle.net-konto
local function HeaderText(g)
    if g.none then
        return GREY .. "Uten addon / ukjent konto|r" .. GREY .. "   ·   " .. g.count .. " karakterer|r"
    end
    local s = BNET_BLUE .. g.short .. "|r"
    local title = ns.GQ_AchTitleOf and ns.GQ_AchTitleOf(g.key)
    if title then s = s .. "  |cffffd100«" .. title .. "»|r" end
    if g.mine then s = s .. GREY .. " (deg)|r" end
    s = s .. GREY .. "   ·   " .. g.count .. (g.count == 1 and " karakter" or " karakterer") .. "|r"
    return s
end

local function Age(ts)
    if not ts or ts == 0 then return GREY .. "-|r" end
    return GREY .. ns.FormatDuration(GetServerTime() - ts) .. " siden|r"
end

-- Guild-rang: GM i gull, offiserer i blått, resten hvitt
local function RankText(m)
    if not m.rank or m.rank == "" then return GREY .. "-|r" end
    if m.rankIndex == 0 then return YELLOW .. m.rank .. "|r" end
    local offRank = (ns.db and ns.db.config and ns.db.config.officerRank) or 1
    if m.rankIndex and m.rankIndex <= offRank then return BNET_BLUE .. m.rank .. "|r" end
    return WHITE .. m.rank .. "|r"
end
local function RankSort(m) return m.rankIndex or 99 end

---------------------------------------------------------------------------
-- Kolonner per fane  (big = større skrift i cellen)
---------------------------------------------------------------------------
local function Columns(tab)
    if tab == "overview" then
        return {
            { title = "Battle.net  /  Karakter", w = 184, big = true, text = ChildNameText, sort = function(m) return m.short end },
            { title = "Klasse",      w = 70,  text = function(m) return ClassName(m.class) end },
            { title = "Spec",        w = 120, text = function(m)
                  local txt = ns.SpecText(m.rec)
                  if not txt then return GREY .. "-|r" end
                  local icon = ns.SpecIcon(m.rec, m.class)
                  return (icon and (IconTex(tostring(icon), 16) .. " ") or "") .. txt
              end, sort = function(m) return ns.SpecText(m.rec) or "~" end },
            { title = "Lvl",         w = 34,  text = function(m) return m.level or "?" end, sort = function(m) return m.level or 0 end },
            { title = "Ilvl",        w = 38,  text = function(m) return m.rec and string.format("%.0f", m.rec.ilvl or 0) or GREY .. "-|r" end,
              sort = function(m) return m.rec and m.rec.ilvl or 0 end },
            { title = "Epics",       w = 46,  text = function(m)
                  if not m.rec or m.rec.epics == nil then return GREY .. "-|r" end
                  return PURPLE .. m.rec.epics .. "|r" .. GREY .. "/" .. ns.GEAR_SLOTS .. "|r"
              end, sort = function(m) return m.rec and m.rec.epics or -1 end },
            { title = "Rang",        w = 96,  text = RankText, sort = RankSort },
            { title = "Main/alt",    w = 88,  text = MainText, sort = function(m) return m.main and 1 or 0 end },
            { title = "Sist online", w = 72,  text = LastOnline, sort = LastOnlineSort },
            { title = "Versjon",     w = 92,  text = function(m)
                  if not m.rec then return RED .. "Mangler addon|r" end
                  local v = m.rec.version
                  if not v or v == "" then return GREY .. "ukjent|r" end
                  return ((v == ns.VERSION) and GREEN or YELLOW) .. v .. "|r"
              end,
              sort = function(m) return m.rec and (m.rec.version or "") or "" end },
        }
    elseif tab == "profs" then
        return {
            { title = "Battle.net  /  Karakter", w = 186, big = true, text = ChildNameText, sort = function(m) return m.short end },
            { title = "Lvl",         w = 34,  text = function(m) return m.level or "?" end, sort = function(m) return m.level or 0 end },
            { title = "Profesjon 1", w = 152, text = function(m) return ProfText(GetProf(m.rec, 1), true) end,
              sort = function(m) local p = GetProf(m.rec, 1) return p and p[1] or "~" end },
            { title = "Profesjon 2", w = 152, text = function(m) return ProfText(GetProf(m.rec, 2), true) end,
              sort = function(m) local p = GetProf(m.rec, 2) return p and p[1] or "~" end },
            { title = "Cooking",     w = 78,  text = function(m) return ProfText(GetProf(m.rec, "Cooking")) end,
              sort = function(m) local p = GetProf(m.rec, "Cooking") return p and -p[2] or 1 end },
            { title = "First Aid",   w = 78,  text = function(m) return ProfText(GetProf(m.rec, "First Aid")) end,
              sort = function(m) local p = GetProf(m.rec, "First Aid") return p and -p[2] or 1 end },
            { title = "Fishing",     w = 78,  text = function(m) return ProfText(GetProf(m.rec, "Fishing")) end,
              sort = function(m) local p = GetProf(m.rec, "Fishing") return p and -p[2] or 1 end },
            { title = "Lockpicking", w = 86,  text = function(m) return ProfText(GetProf(m.rec, "Lockpicking")) end,
              sort = function(m) local p = GetProf(m.rec, "Lockpicking") return p and -p[2] or 1 end },
        }
    elseif tab == "gold" then
        return {
            { title = "Battle.net-konto", w = 220, big = true, text = function(a)
                  if a.noAddon then return WHITE .. a.short .. "|r" .. GREY .. "  (uten addon)|r" end
                  return BNET_BLUE .. a.short .. "|r" .. (a.mine and (GREY .. "  (deg)|r") or "")
              end, sort = function(a) return a.short:lower() end },
            { title = "Totalt",       w = 160, text = function(a) return a.trib.total ~= 0 and ns.FormatMoney(a.trib.total) or (GREY .. "-|r") end,
              sort = function(a) return a.trib.total end },
            { title = "Denne uka",    w = 160, text = function(a) return a.trib.week ~= 0 and ns.FormatMoney(a.trib.week) or (GREY .. "-|r") end,
              sort = function(a) return a.trib.week end },
            { title = "Siste bidrag", w = 170, text = function(a)
                  if a.trib.last == 0 then return GREY .. "aldri|r" end
                  return date("%d.%m.%Y", a.trib.last) .. GREY .. "  (" .. ns.FormatDuration(GetServerTime() - a.trib.last) .. " siden)|r"
              end, sort = function(a) return a.trib.last end },
            { title = "Antall",       w = 60,  text = function(a) return a.trib.count end, sort = function(a) return a.trib.count end },
        }
    elseif tab == "log" then
        return {
            { title = "Tid",           w = 130, text = function(e)
                  if e.approx then return date("%d.%m.%y", e.time) .. GREY .. " ca. " .. date("%H", e.time) .. ":00|r" end
                  return date("%d.%m.%y %H:%M", e.time)
              end, sort = function(e) return e.time end },
            { title = "",              w = 24, text = function(e) return KindIcon(e.kind, e.out) end },
            { title = "Konto / karakter", w = 230, big = true, text = function(e)
                  if e.noAddon then return WHITE .. e.short .. "|r" .. GREY .. "  (uten addon)|r" end
                  local s = BNET_BLUE .. e.short .. "|r"
                  if e.char and e.char ~= "" and e.char ~= e.short then s = s .. GREY .. "  (" .. e.char .. ")|r" end
                  return s
              end,
              sort = function(e) return e.short:lower() end },
            { title = "Beløp",         w = 170, text = function(e)
                  if e.out then return RED .. "–  |r" .. ns.FormatMoney(e.amount) end
                  return GREEN .. "+  |r" .. ns.FormatMoney(e.amount)
              end, sort = function(e) return e.out and -e.amount or e.amount end },
            { title = "Type",          w = 150, text = function(e)
                  if e.via == "manuell" then return GREY .. "Manuelt av |r" .. WHITE .. ns.Short(e.banker) .. "|r" end
                  local k = ns.LOG_KINDS[e.kind or "deposit"]
                  local label = k and k.label or (e.kind or "?")
                  return (e.out and RED or GREEN) .. label .. "|r"
              end, sort = function(e) return e.kind or "" end },
        }
    elseif tab == "attendance" then
        return {
            { title = "Spiller / konto", w = 230, big = true, text = NameText, sort = function(m) return m.short end },
            { title = "Rang",        w = 110, text = RankText, sort = RankSort },
            { title = "Events",      w = 120, text = function(m)
                  if (m.att and m.att.events or 0) == 0 then return GREY .. "-|r" end
                  return GREEN .. m.att.events .. "|r" .. GREY .. " påmeldt|r"
              end, sort = function(m) return m.att and m.att.events or 0 end },
            { title = "Dueller",     w = 110, text = function(m)
                  if (m.att and m.att.duels or 0) == 0 then return GREY .. "-|r" end
                  return YELLOW .. m.att.duels .. "|r"
              end, sort = function(m) return m.att and m.att.duels or 0 end },
            { title = "Siste aktivitet", w = 150, text = function(m)
                  local t = m.att and m.att.last or 0
                  if t == 0 then return GREY .. "aldri|r" end
                  return GREY .. ns.FormatDuration(GetServerTime() - t) .. " siden|r"
              end, sort = function(m) return m.att and m.att.last or 0 end },
            { title = "Sist online", w = 90, text = LastOnline, sort = LastOnlineSort },
        }
    end
    return {}
end

---------------------------------------------------------------------------
-- Rader
---------------------------------------------------------------------------
local function MemberItems()
    local items = {}
    if not ns.db then return items end
    local totals = ns.TributeTotals()
    -- Union av guild-rosteret og alle vi har lagret data om. Slik vises også
    -- nye medlemmer vi nettopp har mottatt data fra, selv om vårt eget
    -- guild-roster ikke er oppdatert med dem ennå.
    local seen, order = {}, {}
    for full in pairs(ns.roster) do if not seen[full] then seen[full] = true; order[#order + 1] = full end end
    for full in pairs(ns.db.members) do if not seen[full] then seen[full] = true; order[#order + 1] = full end end
    for _, full in ipairs(order) do
        local r = ns.roster[full]
        local rec = ns.db.members[full]
        local m = {
            full = full, short = ns.Short(full), rec = rec,
            class = (r and r.class) or (rec and rec.class),
            level = (r and r.level) or (rec and rec.level) or 0,
            trib = (rec and rec.bnetKey and totals[rec.bnetKey]) or totals["char:" .. full]
                or { total = 0, week = 0, count = 0, last = 0 },
        }
        if r then
            m.rank, m.rankIndex, m.online, m.last = r.rank, r.rankIndex, r.online, r
        end
        if rec and (rec.level or 0) > (m.level or 0) then m.level = rec.level end
        m.bnet = rec and rec.bnetName
        m.mine = ns.IsMine(full)
        m.alts = {}
        items[#items + 1] = m
    end

    -- Grupper karakterer per Battle.net-konto
    local byName, groups = {}, {}
    for _, m in ipairs(items) do
        byName[m.full] = m
        local key = m.rec and m.rec.bnetKey
        if key then
            groups[key] = groups[key] or {}
            table.insert(groups[key], m)
        end
    end
    for _, list in pairs(groups) do
        if #list > 1 then
            -- Nyeste data fra kontoen bestemmer valgt main (tom = automatisk)
            local newest = list[1]
            for _, m in ipairs(list) do
                if (m.rec.updated or 0) > (newest.rec.updated or 0) then newest = m end
            end
            local mainName = newest.rec.main
            local valid = false
            for _, m in ipairs(list) do if m.full == mainName then valid = true end end
            if not valid then
                -- Automatisk: høyest level, så alfabetisk
                local best = list[1]
                for _, m in ipairs(list) do
                    if (m.level or 0) > (best.level or 0)
                        or ((m.level or 0) == (best.level or 0) and m.full < best.full) then
                        best = m
                    end
                end
                mainName = best.full
            end
            for _, m in ipairs(list) do
                if m.full ~= mainName then
                    m.main = mainName
                    table.insert(byName[mainName].alts, m.full)
                end
            end
            table.sort(byName[mainName].alts)
        end
    end
    return items
end

-- Én rad per Battle.net-konto: alle kontoer i guilden (med addon) + alle som har gitt
local function AccountItems()
    local items, byKey = {}, {}
    if not ns.db then return items end
    local myKey = ns.AccountInfo()
    local function Add(key, name)
        if byKey[key] then return byKey[key] end
        local a = { key = key, short = name, mine = (key == myKey), noAddon = (key:sub(1, 5) == "char:"),
                    trib = { total = 0, week = 0, count = 0, last = 0 } }
        byKey[key] = a
        items[#items + 1] = a
        return a
    end
    for full, rec in pairs(ns.db.members) do
        if rec.bnetKey then
            local a = Add(rec.bnetKey, (rec.bnetName and rec.bnetName ~= "") and rec.bnetName or "Ukjent konto")
            -- foretrekk et ekte navn hvis en annen karakter har det
            if a.short == "Ukjent konto" and rec.bnetName and rec.bnetName ~= "" then a.short = rec.bnetName end
        end
    end
    for key, t in pairs(ns.TributeTotals()) do
        local a = Add(key, t.name)
        a.trib = t
    end
    return items
end

local function LogItems()
    local items = {}
    if not ns.db then return items end
    for _, e in ipairs(ns.TributeEvents()) do
        local key, name = ns.CharAccount(e.from)
        items[#items + 1] = {
            time = e.time, amount = e.amount, via = e.via, banker = e.banker, short = name, approx = e.approx,
            char = ns.Short(e.from), kind = e.kind, out = (ns.LOG_KINDS[e.kind or "deposit"] or {}).sign == -1,
            noAddon = (key:sub(1, 5) == "char:"),
        }
    end
    return items
end

-- Oppmøte: tell events påmeldt og dueller spilt per spiller
local function AttendanceStats()
    local by = {}
    local function S(name)
        local k = ns.Key(name)
        local s = by[k]
        if not s then s = { events = 0, duels = 0, last = 0 }; by[k] = s end
        return s
    end
    if ns.db then
        for id, e in pairs(ns.db.events or {}) do
            for _, su in pairs((ns.db.signups and ns.db.signups[id]) or {}) do
                if su.joined then
                    local s = S(su.name)
                    s.events = s.events + 1
                    s.last = math.max(s.last, (e.when and e.when > 0) and e.when or (e.created or 0))
                end
            end
        end
        for _, r in pairs((ns.db.dr and ns.db.dr.results) or {}) do
            if r.kind ~= "tpot" then
                local sa, sb = S(r.a), S(r.b)
                sa.duels = sa.duels + 1; sa.last = math.max(sa.last, r.t or 0)
                sb.duels = sb.duels + 1; sb.last = math.max(sb.last, r.t or 0)
            end
        end
    end
    return by
end

local function AttendanceItems()
    local by = AttendanceStats()
    local items = MemberItems()
    for _, m in ipairs(items) do
        m.att = by[ns.Key(m.full)] or { events = 0, duels = 0, last = 0 }
    end
    return items
end

local function Matches(item)
    local memberTab = currentTab == "overview" or currentTab == "profs"
    if onlyAddon and memberTab and not item.rec then return false end
    if hideAlts and memberTab and item.main then return false end
    if searchText == "" then return true end
    local hay = { item.short or "", ClassName(item.class), item.rank or "",
                  item.main and ns.Short(item.main) or "", ns.SpecText(item.rec) or "", item.bnet or "" }
    if item.rec and item.rec.profs then
        for _, p in ipairs(item.rec.profs) do hay[#hay + 1] = p[1] end
    end
    return table.concat(hay, " "):lower():find(searchText, 1, true) ~= nil
end

-- Medlemmer gruppert per Battle.net-konto:
--   [konto] -> main, alts (etter level) -> [neste konto] ...
-- Kontoene sorteres etter valgt kolonne (målt på mainen), "Uten addon" alltid nederst.
local function BuildGroupedRows(cols)
    local myKey = ns.AccountInfo()
    local groups, list = {}, {}
    for _, m in ipairs(MemberItems()) do
        local key = (m.rec and m.rec.bnetKey) or "~none"
        local g = groups[key]
        if not g then
            g = { isHeader = true, key = key, none = (key == "~none"), mine = (key == myKey),
                  short = "Ukjent konto", members = {}, count = 0, online = 0 }
            groups[key] = g
            list[#list + 1] = g
        end
        if m.bnet and m.bnet ~= "" then g.short = m.bnet end
        g.members[#g.members + 1] = m
        g.count = g.count + 1
        if m.online then g.online = g.online + 1 end
    end
    if groups["~none"] then groups["~none"].short = "Uten addon" end

    -- Innad i kontoen: main først, så alts etter level, så navn
    for _, g in ipairs(list) do
        table.sort(g.members, function(a, b)
            if not g.none then
                local am, bm = a.main == nil, b.main == nil
                if am ~= bm then return am end
            end
            if (a.level or 0) ~= (b.level or 0) then return (a.level or 0) > (b.level or 0) end
            return a.short < b.short
        end)
    end

    -- Sorter kontoene
    local st = sortState[currentTab]
    local col = cols[st.col] or cols[1]
    local key = col.sort or function(m) return Strip(col.text(m)):lower() end
    for _, g in ipairs(list) do
        if st.col == 1 then g._k = g.short:lower() else g._k = key(g.members[1]) end
    end
    table.sort(list, function(a, b)
        if a.none ~= b.none then return b.none end
        local ka, kb = a._k, b._k
        if type(ka) ~= type(kb) then ka, kb = tostring(ka), tostring(kb) end
        if ka == kb then return a.short:lower() < b.short:lower() end
        if st.asc then return ka < kb else return ka > kb end
    end)

    -- Bygg radene (søk på kontonavn viser hele kontoen)
    local rows = {}
    for _, g in ipairs(list) do
        local accountHit = searchText ~= "" and not g.none and g.short:lower():find(searchText, 1, true)
        local visible = {}
        for _, m in ipairs(g.members) do
            local pass = true
            if onlyAddon and not m.rec then pass = false end
            if hideAlts and m.main then pass = false end
            if pass and (accountHit or Matches(m)) then visible[#visible + 1] = m end
        end
        if #visible > 0 then
            rows[#rows + 1] = g
            for _, m in ipairs(visible) do rows[#rows + 1] = m end
        end
    end
    return rows
end

local function BuildRows(cols)
    if currentTab == "overview" or currentTab == "profs" then return BuildGroupedRows(cols) end
    local source = (currentTab == "log") and LogItems()
        or (currentTab == "gold") and AccountItems()
        or (currentTab == "attendance") and AttendanceItems()
        or MemberItems()
    local rows = {}
    for _, it in ipairs(source) do
        if Matches(it) then rows[#rows + 1] = it end
    end
    local st = sortState[currentTab]
    local col = cols[st.col] or cols[1]
    local key = col.sort or function(m) return Strip(col.text(m)):lower() end
    for _, r in ipairs(rows) do r._k = key(r) end
    table.sort(rows, function(a, b)
        local ka, kb = a._k, b._k
        if type(ka) ~= type(kb) then ka, kb = tostring(ka), tostring(kb) end
        if ka == kb then return (a.short or "") < (b.short or "") end
        if st.asc then return ka < kb else return ka > kb end
    end)
    return rows
end

---------------------------------------------------------------------------
-- Infolinje over listen
---------------------------------------------------------------------------
local function Stat(label, value)
    return YELLOW .. label .. "|r " .. WHITE .. value .. "|r"
end

local function InfoText()
    if not ns.db then return RED .. "Du er ikke i en guild.|r" end
    local SEP = GREY .. "   ·   |r"
    if currentTab == "overview" then
        return ""   -- «Min tittel»-dropdownen ligger her nå
    elseif currentTab == "profs" then
        return GREY .. "Søk «alch» for å finne alle alchemists|r"
    elseif currentTab == "gold" or currentTab == "log" then
        local wIn, wOut = ns.BankFlow(ns.WeekStart())
        local bank = ns.db.bank
        local bankText = bank and (ns.FormatMoney(bank.money) .. GREY .. " (" .. ns.Short(bank.by or "?")
                .. ", " .. ns.FormatDuration(GetServerTime() - bank.time) .. " siden)|r")
            or (GREY .. "ukjent – noen med addonen må åpne guild banken|r")
        return YELLOW .. "Guild bank|r " .. bankText .. SEP .. YELLOW .. "Denne uka|r  "
            .. GREEN .. "inn|r " .. ns.FormatMoney(wIn) .. "   " .. RED .. "ut|r " .. ns.FormatMoney(wOut)
    elseif currentTab == "attendance" then
        return YELLOW .. "Oppmøte|r " .. GREY .. "– hvor aktiv hver spiller er i events og dueller. "
            .. "Events telles mens de ligger i lista (~7 dager), dueller hele sesongen.|r"
    end
    return ""
end

---------------------------------------------------------------------------
-- Tooltip
---------------------------------------------------------------------------
local function ShowTooltip(line)
    local m = line.item
    if not m or currentTab == "log" then return end
    GameTooltip:SetOwner(line, "ANCHOR_RIGHT")
    if m.isHeader then
        GameTooltip:AddLine(m.none and "Uten addon / ukjent konto" or (BNET_BLUE .. m.short .. "|r"))
        for _, c in ipairs(m.members) do
            local tag = c.main and "" or ((not m.none) and (GREY .. "  main|r") or "")
            GameTooltip:AddDoubleLine(ClassIcon(c.class, 14) .. " |c" .. ClassHex(c.class) .. c.short .. "|r" .. tag,
                "Level " .. (c.level or "?"), 1, 1, 1, 0.8, 0.8, 0.8)
        end
        if not m.none and m.members[1] and m.members[1].trib and m.members[1].trib.count > 0 then
            local t = m.members[1].trib
            GameTooltip:AddLine(" ")
            GameTooltip:AddDoubleLine("Gullbidrag totalt", ns.FormatMoney(t.total), 1, 0.82, 0, 1, 1, 1)
            GameTooltip:AddDoubleLine("Denne uka", ns.FormatMoney(t.week), 1, 0.82, 0, 1, 1, 1)
        end
        GameTooltip:Show()
        return
    end
    if currentTab == "gold" then
        GameTooltip:AddLine(BNET_BLUE .. m.short .. "|r")
        GameTooltip:AddDoubleLine("Totalt", ns.FormatMoney(m.trib.total), 1, 0.82, 0, 1, 1, 1)
        GameTooltip:AddDoubleLine("Denne uka", ns.FormatMoney(m.trib.week), 1, 0.82, 0, 1, 1, 1)
        GameTooltip:AddDoubleLine("Antall innskudd", m.trib.count, 1, 0.82, 0, 1, 1, 1)
        if m.trib.last > 0 then
            GameTooltip:AddDoubleLine("Siste", date("%d.%m.%Y %H:%M", m.trib.last), 1, 0.82, 0, 1, 1, 1)
        end
        GameTooltip:Show()
        return
    end
    GameTooltip:AddLine(ClassIcon(m.class, 20) .. " |c" .. ClassHex(m.class) .. m.short .. "|r")
    GameTooltip:AddLine(string.format("Level %s %s", m.level or "?", ClassName(m.class)), 1, 1, 1)
    if m.rank then GameTooltip:AddLine("<" .. m.rank .. ">", 0.25, 1, 0.25) end
    if m.bnet and m.bnet ~= "" then
        GameTooltip:AddDoubleLine("Battle.net", m.bnet, 1, 0.82, 0, 0.51, 0.77, 1)
    end
    local rec = m.rec
    if not rec then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Har ikke addonen (eller har ikke synket ennå).", 1, 0.4, 0.4)
    else
        local spec = ns.SpecText(rec)
        if spec then
            local icon = ns.SpecIcon(rec, m.class)
            GameTooltip:AddDoubleLine("Spec", (icon and (IconTex(tostring(icon), 14) .. " ") or "") .. spec,
                1, 0.82, 0, 1, 1, 1)
        end
        GameTooltip:AddDoubleLine("Item level", string.format("%.1f", rec.ilvl or 0), 1, 0.82, 0, 1, 1, 1)
        if rec.epics then
            GameTooltip:AddDoubleLine("Epics", rec.epics .. "/" .. ns.GEAR_SLOTS, 1, 0.82, 0, 0.64, 0.21, 0.93)
        end
        if m.main then
            GameTooltip:AddDoubleLine("Alt av", ns.Short(m.main), 1, 0.82, 0, 0.8, 0.8, 0.8)
        elseif m.alts and #m.alts > 0 then
            local names = {}
            for _, a in ipairs(m.alts) do names[#names + 1] = ns.Short(a) end
            GameTooltip:AddDoubleLine("Alts", table.concat(names, ", "), 1, 0.82, 0, 0.8, 0.8, 0.8)
        end
        if rec.profs and #rec.profs > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Profesjoner", 1, 0.82, 0)
            for _, p in ipairs(rec.profs) do
                local icon = PROF_ICONS[p[1]] and (IconTex(PROF_ICONS[p[1]], 14) .. " ") or ""
                GameTooltip:AddDoubleLine(icon .. p[1], p[2] .. "/" .. p[3], 1, 1, 1, 1, 1, 1)
            end
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Data oppdatert " .. Strip(Age(rec.updated)), 0.5, 0.5, 0.5)
    end
    if m.trib and m.trib.count > 0 then
        GameTooltip:AddDoubleLine("Gullbidrag (kontoen)", ns.FormatMoney(m.trib.total), 1, 0.82, 0, 1, 1, 1)
    end
    if m.mine then
        GameTooltip:AddLine(" ")
        if ns.db.myMain == m.full then
            GameTooltip:AddLine("Valgt som main. Høyreklikk: velg automatisk", 0, 1, 0)
        else
            GameTooltip:AddLine("Høyreklikk: sett som main", 0, 1, 0)
        end
    end
    GameTooltip:Show()
end

---------------------------------------------------------------------------
-- Byggeklosser
---------------------------------------------------------------------------
local BACKDROP_TPL = BackdropTemplateMixin and "BackdropTemplate" or nil

local function SetBD(frame, bg, edge, edgeSize, inset)
    if not frame.SetBackdrop then return end
    frame:SetBackdrop({
        bgFile = bg, edgeFile = edge, tile = true, tileSize = 32, edgeSize = edgeSize,
        insets = { left = inset, right = inset, top = inset, bottom = inset },
    })
end

-- Kolonneoverskrift i samme stil som Who-lista
local function CreateHeader(parent)
    local h = CreateFrame("Button", nil, parent)
    h:SetHeight(HEADER_H)
    local tex = "Interface\\FriendsFrame\\WhoFrame-ColumnTabs"
    local l = h:CreateTexture(nil, "BACKGROUND")
    l:SetTexture(tex); l:SetTexCoord(0, 0.078125, 0, 0.75)
    l:SetPoint("TOPLEFT"); l:SetPoint("BOTTOMLEFT"); l:SetWidth(5)
    local r = h:CreateTexture(nil, "BACKGROUND")
    r:SetTexture(tex); r:SetTexCoord(0.90625, 0.96875, 0, 0.75)
    r:SetPoint("TOPRIGHT"); r:SetPoint("BOTTOMRIGHT"); r:SetWidth(4)
    local mid = h:CreateTexture(nil, "BACKGROUND")
    mid:SetTexture(tex); mid:SetTexCoord(0.078125, 0.90625, 0, 0.75)
    mid:SetPoint("TOPLEFT", l, "TOPRIGHT"); mid:SetPoint("BOTTOMRIGHT", r, "BOTTOMLEFT")
    local fs = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("LEFT", 8, 0)
    fs:SetPoint("RIGHT", -4, 0)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    h.fs = fs
    h:SetHighlightTexture("Interface\\PaperDollInfoFrame\\UI-Character-Tab-Highlight", "ADD")
    return h
end

-- Faner under vinduet, som i Character-vinduet. Faller tilbake til vanlige knapper.
local function CreateTab(parent, index)
    local name = parent:GetName() .. "Tab" .. index
    for _, tpl in ipairs({ "PanelTabButtonTemplate", "CharacterFrameTabButtonTemplate" }) do
        local ok, b = pcall(CreateFrame, "Button", name, parent, tpl)
        if ok and b and b.GetFontString and b:GetFontString() then return b, true end
    end
    return CreateFrame("Button", name, parent, "UIPanelButtonTemplate"), false
end

UI.offset = 0

local function ScrollBy(delta)
    if UI.slider then UI.slider:SetValue(UI.offset - delta * 3) end
end

---------------------------------------------------------------------------
-- Vinduet
---------------------------------------------------------------------------
function UI:SelectTab(index)
    currentTab = TABS[index].id
    self.frame.selectedTab = index
    if self.lvlInfoPanel then self.lvlInfoPanel:Hide() end
    if self.panelTabs and PanelTemplates_SetTab then
        PanelTemplates_SetTab(self.frame, index)
    else
        for i, b in ipairs(self.tabs) do
            if i == index then b:LockHighlight() else b:UnlockHighlight() end
        end
    end
    self.offset = 0
    self.updating = true
    self.slider:SetValue(0)
    self.updating = false
    self:Update()
end

function UI:Create()
    if self.frame then return end

    local f = CreateFrame("Frame", "GuildKompassFrame", UIParent, BACKDROP_TPL)
    self.frame = f
    f:SetSize(WIDTH, HEIGHT)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScale(ns.global and ns.global.scale or 1)
    local pos = ns.global and ns.global.framePos
    if pos then f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else f:SetPoint("CENTER", 0, 40) end
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(s)
        s:StopMovingOrSizing()
        local p, _, rp, x, y = s:GetPoint()
        if ns.global then ns.global.framePos = { p, rp, x, y } end
    end)
    f:SetScript("OnShow", function() Sound("IG_CHARACTER_INFO_OPEN"); UI:Update() end)
    f:SetScript("OnHide", function() Sound("IG_CHARACTER_INFO_CLOSE") end)
    -- IKKE i UISpecialFrames: taint av ESC-håndteringen på denne klienten. Lukk med X.

    -- Steinramme + mørk bakgrunn
    SetBD(f, "Interface\\DialogFrame\\UI-DialogBox-Background", "Interface\\DialogFrame\\UI-DialogBox-Border", 32, 11)
    local rock = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    rock:SetTexture("Interface\\FrameGeneral\\UI-Background-Rock", "REPEAT", "REPEAT")
    rock:SetHorizTile(true)
    rock:SetVertTile(true)
    rock:SetPoint("TOPLEFT", 11, -12)
    rock:SetPoint("BOTTOMRIGHT", -12, 11)
    rock:SetVertexColor(0.45, 0.42, 0.38)
    rock:SetAlpha(0.85)

    -- Gullbanner med tittel
    local banner = f:CreateTexture(nil, "ARTWORK")
    banner:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
    banner:SetSize(380, 64)
    banner:SetPoint("TOP", 0, 12)
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", banner, "TOP", 0, -14)
    title:SetText("GuildKompass")

    self.guildText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    self.guildText:SetPoint("TOP", 0, -32)
    -- MORPHEUS er WoWs "episke" quest-font; fall tilbake til standard om den mangler
    if not self.guildText:SetFont("Fonts\\MORPHEUS.ttf", 23, "OUTLINE") then
        self.guildText:SetFont(select(1, GameFontNormalLarge:GetFont()), 22, "OUTLINE")
    end
    self.guildText:SetTextColor(1, 0.82, 0)                 -- gull
    self.guildText:SetShadowColor(1, 0.55, 0.05, 0.9)       -- varm glød
    self.guildText:SetShadowOffset(0, 0)

    -- Guild-nivå + mini XP-bar under guild-navnet (synlig på alle faner)
    self.guildLvl = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    self.guildLvl:SetPoint("TOP", self.guildText, "BOTTOM", 0, 0)
    self.guildLvl:SetTextColor(0.8, 0.7, 1)
    local gxf = CreateFrame("Frame", nil, f, BACKDROP_TPL)
    gxf:SetSize(190, 11)
    gxf:SetPoint("TOP", self.guildLvl, "BOTTOM", 0, -1)
    SetBD(gxf, "Interface\\Tooltips\\UI-Tooltip-Background", "Interface\\Tooltips\\UI-Tooltip-Border", 7, 2)
    if gxf.SetBackdropColor then gxf:SetBackdropColor(0, 0, 0, 0.8); gxf:SetBackdropBorderColor(0.55, 0.4, 0.75, 1) end
    local gxbar = CreateFrame("StatusBar", nil, gxf)
    gxbar:SetPoint("TOPLEFT", 3, -3); gxbar:SetPoint("BOTTOMRIGHT", -3, 3)
    gxbar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    gxbar:SetStatusBarColor(0.64, 0.19, 0.85)
    gxbar:SetMinMaxValues(0, 1); gxbar:SetValue(0)
    self.guildXpBar = gxbar

    -- Liten "?"-knapp ved siden av guild-nivået: viser hva som skjer på hvert nivå
    local lvlInfo = CreateFrame("Button", nil, f, BACKDROP_TPL)
    lvlInfo:SetSize(15, 15)
    lvlInfo:SetPoint("LEFT", self.guildLvl, "RIGHT", 5, 0)
    SetBD(lvlInfo, "Interface\\Tooltips\\UI-Tooltip-Background", "Interface\\Tooltips\\UI-Tooltip-Border", 7, 2)
    if lvlInfo.SetBackdropColor then lvlInfo:SetBackdropColor(0.1, 0.1, 0.16, 0.95); lvlInfo:SetBackdropBorderColor(0.55, 0.4, 0.75, 1) end
    lvlInfo:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    local qmark = lvlInfo:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    qmark:SetPoint("CENTER", 0, 0); qmark:SetText("?"); qmark:SetTextColor(0.85, 0.75, 1)
    self.lvlInfoBtn = lvlInfo

    -- Panel med liste over hva som skjer på hvert guild-nivå
    local info = CreateFrame("Frame", nil, f, BACKDROP_TPL)
    info:SetFrameStrata("DIALOG")
    info:SetPoint("TOP", lvlInfo, "BOTTOM", 0, -4)
    info:SetSize(230, 60)
    SetBD(info, "Interface\\Tooltips\\UI-Tooltip-Background", "Interface\\Tooltips\\UI-Tooltip-Border", 14, 4)
    if info.SetBackdropColor then info:SetBackdropColor(0, 0, 0, 0.96); info:SetBackdropBorderColor(0.55, 0.4, 0.75, 1) end
    info:EnableMouse(true)
    info:Hide()
    info.title = info:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    info.title:SetPoint("TOPLEFT", 12, -10)
    info.title:SetText("|cffc0a0ffGuild-nivåer|r")
    info.rows = {}
    self.lvlInfoPanel = info
    lvlInfo:SetScript("OnClick", function()
        if info:IsShown() then info:Hide() else UI:FillLevelInfo(); info:Show() end
    end)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)

    -- Søk
    local search = CreateFrame("EditBox", "GuildKompassSearch", f, "InputBoxTemplate")
    search:SetSize(170, 20)
    search:SetPoint("TOPRIGHT", -SIDE - 8, -56)
    search:SetAutoFocus(false)
    search:SetScript("OnTextChanged", function(s)
        searchText = (s:GetText() or ""):lower()
        UI.searchHint:SetShown(searchText == "" and not s:HasFocus())
        UI:Update()
    end)
    search:SetScript("OnEditFocusGained", function() UI.searchHint:Hide() end)
    search:SetScript("OnEditFocusLost", function(s) UI.searchHint:SetShown((s:GetText() or "") == "") end)
    search:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
    search:SetScript("OnEnterPressed", function(s) s:ClearFocus() end)
    self.searchHint = search:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    self.searchHint:SetPoint("LEFT", 2, 0)
    self.searchHint:SetText(Tex("Interface\\Common\\UI-Searchbox-Icon", 12) .. " Søk navn, klasse, profesjon …")

    -- Info
    self.info = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.info:SetPoint("TOPLEFT", SIDE + 6, -61)
    self.info:SetPoint("RIGHT", search, "LEFT", -20, 0)
    self.info:SetJustifyH("LEFT")
    self.info:SetWordWrap(false)

    local divider = f:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(1, 0.82, 0, 0.3)
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", SIDE + 2, -79)
    divider:SetPoint("TOPRIGHT", -SIDE - 2, -79)

    -- Innfelt liste
    local inset = CreateFrame("Frame", nil, f, BACKDROP_TPL)
    inset:SetPoint("TOPLEFT", SIDE, -TOP_INSET)
    inset:SetPoint("BOTTOMRIGHT", -SIDE, BOTTOM_INSET)
    SetBD(inset, "Interface\\Tooltips\\UI-Tooltip-Background", "Interface\\Tooltips\\UI-Tooltip-Border", 14, 3)
    if inset.SetBackdropColor then
        inset:SetBackdropColor(0, 0, 0, 0.65)
        inset:SetBackdropBorderColor(0.8, 0.65, 0.3, 0.9)
    end
    inset:EnableMouseWheel(true)
    inset:SetScript("OnMouseWheel", function(_, d) ScrollBy(d) end)
    self.inset = inset

    self.headers = {}
    for c = 1, MAX_COLS do
        local h = CreateHeader(inset)
        h:SetScript("OnClick", function()
            local st = sortState[currentTab]
            if st.col == c then st.asc = not st.asc else st.col = c; st.asc = true end
            Sound("IG_MAINMENU_OPTION_CHECKBOX_ON")
            UI:Update()
        end)
        self.headers[c] = h
    end

    -- Egen scrollbar i klassisk slider-stil (fungerer i alle klientversjoner)
    local slider = CreateFrame("Slider", nil, inset, BACKDROP_TPL)
    slider:SetOrientation("VERTICAL")
    slider:SetWidth(16)
    slider:SetPoint("TOPRIGHT", -6, -(4 + HEADER_H + 4))
    slider:SetPoint("BOTTOMRIGHT", -6, 8)
    SetBD(slider, "Interface\\Buttons\\UI-SliderBar-Background", "Interface\\Buttons\\UI-SliderBar-Border", 8, 3)
    slider:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    local thumb = slider:GetThumbTexture()
    if thumb then thumb:SetSize(18, 24) end
    slider:SetMinMaxValues(0, 0)
    slider:SetValueStep(1)
    if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
    slider:SetValue(0)
    slider:EnableMouseWheel(true)
    slider:SetScript("OnMouseWheel", function(_, d) ScrollBy(d) end)
    slider:SetScript("OnValueChanged", function(_, v)
        if UI.updating then return end
        local nv = math.floor(v + 0.5)
        if nv ~= UI.offset then
            UI.offset = nv
            UI:Update()
        end
    end)
    self.slider = slider

    self.lines = {}
    for i = 1, NUM_ROWS do
        local line = CreateFrame("Button", nil, inset)
        line:SetFrameLevel(inset:GetFrameLevel() + 2)
        line:SetSize(LIST_W, ROW_H)
        line:SetPoint("TOPLEFT", inset, "TOPLEFT", 4, -(4 + HEADER_H + (i - 1) * ROW_H))
        local bg = line:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        line.bg = bg
        line.zebra = (i % 2 == 0)
        if line.zebra then bg:SetColorTexture(1, 0.82, 0, 0.045) else bg:SetColorTexture(0, 0, 0, 0) end
        -- tynn blå linje øverst på kontooverskrifter
        local top = line:CreateTexture(nil, "BORDER")
        top:SetColorTexture(0.51, 0.77, 1, 0.35)
        top:SetHeight(1)
        top:SetPoint("TOPLEFT")
        top:SetPoint("TOPRIGHT")
        top:Hide()
        line.topLine = top
        local hl = line:CreateTexture(nil, "HIGHLIGHT")
        hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        hl:SetBlendMode("ADD")
        hl:SetAllPoints()
        hl:SetAlpha(0.6)
        line.cells = {}
        for c = 1, MAX_COLS do
            local fs = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetJustifyH("LEFT")
            fs:SetWordWrap(false)
            line.cells[c] = fs
        end
        line:EnableMouseWheel(true)
        line:SetScript("OnMouseWheel", function(_, d) ScrollBy(d) end)
        line:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        line:SetScript("OnClick", function(s, button)
            local m = s.item
            local memberTab = currentTab == "overview" or currentTab == "profs"
            if button ~= "RightButton" or not m or not memberTab or not m.mine or not m.full then return end
            if ns.db.myMain == m.full then ns.SetMain(nil) else ns.SetMain(m.full) end
            Sound("IG_MAINMENU_OPTION_CHECKBOX_ON")
            ShowTooltip(s)
        end)
        line:SetScript("OnEnter", ShowTooltip)
        line:SetScript("OnLeave", function() GameTooltip:Hide() end)
        self.lines[i] = line
    end

    self.empty = inset:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
    self.empty:SetPoint("CENTER", 0, -10)

    -- Bunnlinje
    local sync = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    sync:SetSize(100, 22)
    sync:SetPoint("BOTTOMLEFT", SIDE + 2, 15)
    sync:SetText("Synk")
    sync:SetScript("OnClick", function() ns.HandleSlash("synk") end)

    local function Check(anchor, label, onClick)
        local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
        cb:SetSize(24, 24)
        cb:SetPoint("LEFT", anchor, "RIGHT", 14, 0)
        cb:SetScript("OnClick", function(s)
            Sound(s:GetChecked() and "IG_MAINMENU_OPTION_CHECKBOX_ON" or "IG_MAINMENU_OPTION_CHECKBOX_OFF")
            onClick(s:GetChecked() and true or false)
            UI:Update()
        end)
        local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("LEFT", cb, "RIGHT", 1, 0)
        fs:SetText(label)
        return fs
    end
    local l1 = Check(sync, "Bare de med addon", function(v) onlyAddon = v end)
    local l2 = Check(l1, "Skjul alts", function(v) hideAlts = v end)

    sync:SetScript("OnEnter", function(s)
        GameTooltip:SetOwner(s, "ANCHOR_TOP")
        GameTooltip:AddLine("Synk")
        GameTooltip:AddLine("Alle i guilden som er pålogget oppdaterer sine data og deler alt de har, "
            .. "så alle ender opp med det samme.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    sync:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Midlertidig testknapp (bare offiserer ser den)
    local reset = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    reset:SetSize(140, 22)
    reset:SetPoint("LEFT", l2, "RIGHT", 24, 0)
    reset:SetText("|cffff7070Nullstill (test)|r")
    reset:SetScript("OnClick", function() StaticPopup_Show("GUILDKOMPASS_RESET") end)
    reset:SetScript("OnEnter", function(s)
        GameTooltip:SetOwner(s, "ANCHOR_TOP")
        GameTooltip:AddLine("Nullstill alle data", 1, 0.4, 0.4)
        GameTooltip:AddLine("Sletter medlemsdata, gullbidrag og bankbeholdning for HELE guilden. "
            .. "Midlertidig knapp for testing – bare offiserer ser den.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    reset:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.resetBtn = reset

    -- "Pålogget X" i footeren (der tittel-dropdownen pleide å stå)
    self.onlineText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    self.onlineText:SetPoint("LEFT", reset, "RIGHT", 16, 0)

    -- Tittel-velger (din egen Battle.net-konto) – øverst på Medlemmer-fanen
    local titleLbl = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    titleLbl:SetPoint("TOPLEFT", SIDE + 6, -58)
    titleLbl:SetText("Min tittel:")
    local drop = CreateFrame("Frame", "GuildKompassTitleDrop", f, "UIDropDownMenuTemplate")
    drop:SetPoint("LEFT", titleLbl, "RIGHT", -6, -2)
    UIDropDownMenu_SetWidth(drop, 130)
    UIDropDownMenu_Initialize(drop, function(_, level)
        local key = ns.AccountInfo and ns.AccountInfo()
        local earned = (ns.GQ_EarnedTitles and key) and ns.GQ_EarnedTitles(key) or {}
        local info = UIDropDownMenu_CreateInfo()
        info.text = "(Ingen tittel)"; info.notCheckable = true
        info.func = function() ns.GQ_SetMyTitle(""); UIDropDownMenu_SetText(drop, "(Ingen)") end
        UIDropDownMenu_AddButton(info)
        for _, t in ipairs(earned) do
            local i2 = UIDropDownMenu_CreateInfo()
            i2.text = t; i2.notCheckable = true
            i2.func = function() ns.GQ_SetMyTitle(t); UIDropDownMenu_SetText(drop, t) end
            UIDropDownMenu_AddButton(i2)
        end
        if #earned == 0 then
            local i3 = UIDropDownMenu_CreateInfo()
            i3.text = "Ingen titler ennå"; i3.disabled = true; i3.notCheckable = true
            UIDropDownMenu_AddButton(i3)
        end
    end)
    self.titleLbl, self.titleDrop = titleLbl, drop

    self.footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    self.footer:SetPoint("BOTTOMRIGHT", -SIDE - 6, 21)

    -- Størrelse-kontroll øverst til venstre
    self.scaleCtl = ns.MakeScaleControl(f, {
        width = 90,
        get = function() return (ns.global and ns.global.scale) or 1 end,
        set = function(v) if ns.global then ns.global.scale = v end; f:SetScale(v) end,
    })
    self.scaleCtl:SetPoint("TOPLEFT", SIDE + 2, -12)

    -- Faner
    self.tabs = {}
    self.panelTabs = true
    for i, t in ipairs(TABS) do
        local b, real = CreateTab(f, i)
        if not real then self.panelTabs = false end
        b:SetText(t.label)
        b:SetID(i)
        if real then
            if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, b, 0) end
        else
            b:SetSize(110, 24)
        end
        if i == 1 then
            b:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 14, real and 7 or -2)
        else
            b:SetPoint("LEFT", self.tabs[i - 1], "RIGHT", real and -14 or 4, 0)
        end
        b:SetScript("OnClick", function()
            Sound("IG_CHARACTER_INFO_TAB")
            UI:SelectTab(i)
        end)
        self.tabs[i] = b
    end
    f.numTabs = #TABS
    if self.panelTabs and PanelTemplates_SetNumTabs then PanelTemplates_SetNumTabs(f, #TABS) end

    -- Events-fanen (death roll): egen panel oppå listeområdet
    if ns.BuildEventsPanel then
        self.eventsPanel = ns.BuildEventsPanel(f, self.inset)
    end
    if ns.BuildRaidPanel then
        self.raidPanel = ns.BuildRaidPanel(f, self.inset)
    end
    if ns.BuildQuestsPanel then
        self.questsPanel = ns.BuildQuestsPanel(f, self.inset)
    end

    f:Hide()
    self:SelectTab(1)
end

function UI:OpenTab(id)
    self:Create()
    self.frame:Show()
    for i, t in ipairs(TABS) do
        if t.id == id then self:SelectTab(i); return end
    end
end

function UI:Toggle()
    self:Create()
    if self.frame:IsShown() then self.frame:Hide() else self.frame:Show() end
end

-- Fyll "Guild-nivåer"-panelet med listen fra GuildQuests (markerer nåværende nivå)
function UI:FillLevelInfo()
    local info = self.lvlInfoPanel
    if not info then return end
    local curLvl = (ns.GQ_GuildXP and select(1, ns.GQ_GuildXP())) or 1
    local list = ns.GQ_LEVEL_INFO or {}
    local y = -34
    for i, entry in ipairs(list) do
        local row = info.rows[i]
        if not row then
            row = info:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row:SetPoint("TOPLEFT", 14, 0)
            row:SetPoint("RIGHT", info, "RIGHT", -12, 0)
            row:SetJustifyH("LEFT")
            info.rows[i] = row
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 14, y)
        row:SetPoint("RIGHT", info, "RIGHT", -12, 0)
        local reached = curLvl >= entry.level
        local hereTag = (curLvl == entry.level) and "  |cff80ff80(her nå)|r" or ""
        local lvlCol  = reached and "|cffffd100" or "|cff808080"
        local txtCol  = reached and "|cffffffff" or "|cffb0b0b0"
        row:SetText(lvlCol .. "Nivå " .. entry.level .. ":|r " .. txtCol .. entry.text .. "|r" .. hereTag)
        row:Show()
        y = y - 18
    end
    for i = #list + 1, #info.rows do info.rows[i]:Hide() end
    info:SetHeight(math.max(50, 34 + #list * 18 + 10))
end

function UI:Update()
    if not self.frame or not self.frame:IsShown() then return end

    local gname = GetGuildInfo("player")
    -- Små gylne ornamenter rundt navnet for litt ekstra piff
    self.guildText:SetText(gname and ("|cffb8860b•|r  " .. gname .. "  |cffb8860b•|r") or "")

    -- Guild-nivå + mini XP-bar under navnet
    if self.guildXpBar and ns.GQ_GuildXP then
        local lvl, into, need = ns.GQ_GuildXP()
        self.guildLvl:SetText("|cffc0a0ffGuild nivå " .. lvl .. "|r |cff808080(" .. into .. "/" .. need .. " XP)|r")
        self.guildXpBar:SetMinMaxValues(0, need > 0 and need or 1)
        self.guildXpBar:SetValue(into)
    end

    self.resetBtn:SetShown(ns.IsOfficer(ns.PlayerName()) and currentTab ~= "events" and currentTab ~= "raid" and currentTab ~= "quests")

    -- Tittel-velger bare på Medlemmer-fanen; vis gjeldende valg
    if self.titleDrop then
        local show = (currentTab == "overview")
        self.titleLbl:SetShown(show)
        self.titleDrop:SetShown(show)
        if show then
            local key = ns.AccountInfo and ns.AccountInfo()
            local cur = (ns.GQ_AchTitleOf and key) and ns.GQ_AchTitleOf(key) or nil
            UIDropDownMenu_SetText(self.titleDrop, cur or "(Ingen)")
        end
    end

    -- "Pålogget X" i footeren på Medlemmer/Profesjoner
    if self.onlineText then
        local show = (currentTab == "overview" or currentTab == "profs")
        self.onlineText:SetShown(show)
        if show then
            local on = 0
            for _, r in pairs(ns.roster) do if r.online then on = on + 1 end end
            self.onlineText:SetText(YELLOW .. "Pålogget|r " .. GREEN .. on .. "|r")
        end
    end

    -- Events-, Raid- og Quests-fanene: egne paneler, skjul den vanlige lista
    if currentTab == "events" or currentTab == "raid" or currentTab == "quests" then
        for c = 1, MAX_COLS do self.headers[c]:Hide() end
        for i = 1, NUM_ROWS do self.lines[i]:Hide() end
        self.slider:Hide()
        self.empty:Hide()
        if currentTab == "events" then
            self.info:SetText(YELLOW .. "Death Roll|r " .. GREY .. "– lag event, spill 1v1 og turneringer|r")
            if ns.ShowEventsPanel then ns.ShowEventsPanel(true) end
            if ns.ShowRaidPanel then ns.ShowRaidPanel(false) end
            if ns.ShowQuestsPanel then ns.ShowQuestsPanel(false) end
        elseif currentTab == "raid" then
            self.info:SetText(YELLOW .. "Raid|r " .. GREY .. "– opprett raid, meld deg på med rolle, verten godkjenner|r")
            if ns.ShowRaidPanel then ns.ShowRaidPanel(true) end
            if ns.ShowEventsPanel then ns.ShowEventsPanel(false) end
            if ns.ShowQuestsPanel then ns.ShowQuestsPanel(false) end
        else
            self.info:SetText(YELLOW .. "Guild Quests|r " .. GREY .. "– felles mål for guilden|r")
            if ns.ShowQuestsPanel then ns.ShowQuestsPanel(true) end
            if ns.ShowEventsPanel then ns.ShowEventsPanel(false) end
            if ns.ShowRaidPanel then ns.ShowRaidPanel(false) end
        end
        local q = ns.QueueSize and ns.QueueSize() or 0
        self.footer:SetText((q > 0 and ("|cffffd100Sender data … (" .. q .. ")|r  ·  ") or "")
            .. "GuildKompass " .. ns.VERSION)
        return
    else
        if ns.ShowEventsPanel then ns.ShowEventsPanel(false) end
        if ns.ShowRaidPanel then ns.ShowRaidPanel(false) end
        if ns.ShowQuestsPanel then ns.ShowQuestsPanel(false) end
    end

    local cols = Columns(currentTab)
    -- siste kolonne fyller resten av bredden
    local used = 0
    for c = 1, #cols - 1 do used = used + cols[c].w end
    if #cols > 0 then cols[#cols].w = math.max(cols[#cols].w, LIST_W - used) end

    local st = sortState[currentTab]
    local x = 0
    for c = 1, MAX_COLS do
        local h = self.headers[c]
        local col = cols[c]
        if col then
            h:ClearAllPoints()
            h:SetPoint("TOPLEFT", self.inset, "TOPLEFT", 4 + x, -4)
            h:SetWidth(col.w)
            local arrow = ""
            if st.col == c then
                arrow = st.asc and " |TInterface\\Buttons\\Arrow-Up-Up:12:12:0:-2|t"
                    or " |TInterface\\Buttons\\Arrow-Down-Up:12:12:0:2|t"
            end
            h.fs:SetText(col.title .. arrow)
            h:Show()
            for i = 1, NUM_ROWS do
                local fs = self.lines[i].cells[c]
                fs:ClearAllPoints()
                fs:SetPoint("LEFT", self.lines[i], "LEFT", x + 8, 0)
                fs:SetWidth(col.w - 10)
                fs:SetFontObject(col.big and GameFontHighlight or GameFontHighlightSmall)
            end
            x = x + col.w
        else
            h:Hide()
        end
    end

    local rows = BuildRows(cols)
    self.info:SetText(InfoText())
    local q = ns.QueueSize and ns.QueueSize() or 0
    local shown = 0
    for _, r in ipairs(rows) do if not r.isHeader then shown = shown + 1 end end
    self.footer:SetText((q > 0 and ("|cffffd100Sender data … (" .. q .. ")|r  ·  ") or "")
        .. string.format("Viser %d  ·  GuildKompass %s", shown, ns.VERSION))

    if #rows == 0 then
        self.empty:SetText(not ns.db and "Du er ikke i en guild"
            or ((searchText ~= "" or ((onlyAddon or hideAlts) and (currentTab == "overview" or currentTab == "profs"))) and "Ingen treff"
            or (currentTab == "log" or currentTab == "gold") and "Ingen har lagt gull i guild banken ennå"
            or "Venter på data fra guilden …"))
        self.empty:Show()
    else
        self.empty:Hide()
    end

    local maxOffset = math.max(0, #rows - NUM_ROWS)
    if self.offset > maxOffset then self.offset = maxOffset end
    self.updating = true
    self.slider:SetMinMaxValues(0, maxOffset)
    self.slider:SetValue(self.offset)
    self.updating = false
    self.slider:SetShown(maxOffset > 0)
    local offset = self.offset
    for i = 1, NUM_ROWS do
        local line = self.lines[i]
        local item = rows[i + offset]
        if item and item.isHeader then
            -- Kontooverskrift: én tekst over hele bredden
            line.item = item
            line.bg:SetColorTexture(0.25, 0.45, 0.8, item.none and 0.08 or 0.2)
            line.topLine:Show()
            for c = 1, MAX_COLS do
                local fs = line.cells[c]
                if c == 1 then
                    fs:SetWidth(LIST_W - 16)
                    fs:SetFontObject(GameFontNormal)
                    fs:SetText(HeaderText(item))
                    fs:Show()
                else
                    fs:Hide()
                end
            end
            line:Show()
        elseif item then
            line.item = item
            if line.zebra then line.bg:SetColorTexture(1, 0.82, 0, 0.045) else line.bg:SetColorTexture(0, 0, 0, 0) end
            line.topLine:Hide()
            for c = 1, MAX_COLS do
                local fs = line.cells[c]
                if cols[c] then
                    if c == 1 then
                        fs:SetWidth(cols[1].w - 10)
                        fs:SetFontObject(cols[1].big and GameFontHighlight or GameFontHighlightSmall)
                    end
                    fs:SetText(tostring(cols[c].text(item) or ""))
                    fs:Show()
                else
                    fs:Hide()
                end
            end
            line:Show()
        else
            line.item = nil
            line:Hide()
        end
    end
end

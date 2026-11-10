local ADDON, ns = ...

-- Death Roll + guild-events, bygget oppå GuildKompass sin transport (ns.Send,
-- ns.Handlers, ns.PREFIX) og database (ns.db). Death roll- og event-meldinger
-- har egne typer (DR*, EV*) og slipper forbi nullstillings-sperren i Comm.lua.

local INVITE_TIMEOUT = 60

ns.duels   = ns.duels or {}        -- id -> aktiv/nylig duell
ns.drSeen  = ns.drSeen or {}       -- kast sett i systemmeldinger (verifisering)

local function DPrint(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffff4040Death Roll|r: " .. tostring(msg))
end
ns.DPrint = DPrint

local function clean(s) return (tostring(s or ""):gsub("[|;/%^:]", "")) end
local split = ns.Split   -- fra Comm.lua

local function H(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return string.format("%08x", h)
end

---------------------------------------------------------------------------
-- Database: alt ligger under ns.db (per guild), satt opp av ns.EnsureDR
---------------------------------------------------------------------------
function ns.EnsureDR()
    local g = ns.db
    if not g then return end
    g.dr = g.dr or {}
    local d = g.dr
    d.results  = d.results or {}
    d.season   = d.season or 0
    d.eventDay = d.eventDay or 4          -- 4 = onsdag (1 = søndag)
    d.cfgTime  = d.cfgTime or 0
    d.resetWday = d.resetWday or 0        -- vedlikeholdsdag for uke-reset (1=søndag); 0 = auto
    d.resetHour = d.resetHour or 4        -- klokketime (UTC) for uke-reset
    d.weekReset = d.weekReset or 0        -- tidspunkt for siste manuelle uke-nullstilling
    g.events      = g.events or {}
    g.signups     = g.signups or {}
    g.tournaments = g.tournaments or {}
    -- Rydd bort gamle events og foreldreløse påmeldinger
    local now = GetServerTime()
    for id, e in pairs(g.events) do
        local dead = e.when and e.when > 0 and now > e.when + 7 * 86400
        if dead or (e.cancelled and now > (e.created or 0) + 2 * 86400) then
            g.events[id] = nil
            g.signups[id] = nil
        end
    end
    for id in pairs(g.signups) do
        if not g.events[id] then g.signups[id] = nil end
    end
    for tid, t in pairs(g.tournaments) do
        if now > (t.created or 0) + 7 * 86400 then g.tournaments[tid] = nil end
    end
end

local function DR() return ns.db and ns.db.dr end

---------------------------------------------------------------------------
-- Resultater (toppliste/historikk)
---------------------------------------------------------------------------
-- id;a;b;winner;loser;amount;rolls;t;season;paid;kind;tid;mi
-- kind: "duel" (1v1), "tmatch" (turneringskamp, teller seire/tap, ingen gull),
--       "tpot" (pott-oppgjør, teller gull, ikke seire/tap)
function ns.EncodeResult(r)
    return table.concat({ clean(r.id), clean(r.a), clean(r.b), clean(r.winner), clean(r.loser),
        r.amount or 0, r.rolls or 0, r.t or 0, r.season or 0, r.paid and 1 or 0,
        clean(r.kind or "duel"), clean(r.tid or ""), r.mi or 0 }, ";")
end

function ns.DecodeResult(s)
    local x = split(s, ";")
    if #x < 10 or x[1] == "" then return nil end
    return { id = x[1], a = ns.Short(x[2]), b = ns.Short(x[3]), winner = ns.Short(x[4]), loser = ns.Short(x[5]),
             amount = tonumber(x[6]) or 0, rolls = tonumber(x[7]) or 0, t = tonumber(x[8]) or 0,
             season = tonumber(x[9]) or 0, paid = x[10] == "1",
             kind = (x[11] and x[11] ~= "") and x[11] or "duel",
             tid = (x[12] and x[12] ~= "") and x[12] or nil, mi = tonumber(x[13]) or 0 }
end

function ns.StoreResult(r)
    local db = DR()
    if not db or not r then return false end
    local old = db.results[r.id]
    if old then
        if r.paid and not old.paid then old.paid = true; return true end
        return false
    end
    db.results[r.id] = r
    return true
end

---------------------------------------------------------------------------
-- Duell-logikk
--  duel = { id, a, b, amount, start, max, turn, state, rolls = {}, created, lastAct }
--  state: "invite" -> "active" -> "done" | "declined" | "cancelled"
---------------------------------------------------------------------------
local function Other(d, name) return ns.Key(name) == ns.Key(d.a) and d.b or d.a end

function ns.MyActiveDuel()
    for _, d in pairs(ns.duels) do
        if (d.state == "invite" or d.state == "active" or d.state == "open")
            and (ns.IsMe(d.a) or ns.IsMe(d.b)) then return d end
    end
end

function ns.FocusDuel()
    local mine = ns.MyActiveDuel()
    if mine then return mine end
    local best
    for _, d in pairs(ns.duels) do
        if not best or (d.lastAct or 0) > (best.lastAct or 0) then best = d end
    end
    return best
end

-- Alle «rom»: pågående kamper (invitasjon/aktiv) + nylig avsluttede
function ns.ActiveDuels()
    local out = {}
    for _, d in pairs(ns.duels) do
        if d.state == "invite" or d.state == "active" or d.state == "open"
            or (d.state == "done" and GetTime() - (d.lastAct or 0) < 25) then
            out[#out + 1] = d
        end
    end
    table.sort(out, function(a, b) return (a.created or 0) < (b.created or 0) end)
    return out
end

-- MERK: innsats sendes ALLTID i copper til Challenge/OpenChallenge. Tidligere ble
-- et tall her omregnet som gull (×10000) – men CreateEvent sender copper, så det ga
-- dobbel omregning (10 silver ble til 1000 gull). Nå tar funksjonene copper direkte,
-- og slash-kommandoen konverterer sin streng med ns.ParseMoney før kallet.
function ns.Challenge(target, gold, start)
    if not ns.db then DPrint("Du må være i en guild.") return end
    if ns.MyActiveDuel() then DPrint("Du er allerede i en duell.") return end
    target = tostring(target or ""):gsub("^%s*@?%s*", ""):gsub("%s+$", "")   -- tillat «@Navn»
    local full = ns.FindMember(target)
    if not full then DPrint("Fant ikke '" .. tostring(target) .. "' i guilden.") return end
    if ns.IsMe(full) then DPrint("Du kan ikke invitere deg selv.") return end
    local copper = math.max(0, math.floor(tonumber(gold) or 0))   -- gold-param er ALLEREDE copper
    start = math.floor(tonumber(start) or 1000)
    if start < 2 then DPrint("Startverdien må være minst 2.") return end
    local me = ns.PlayerName()
    local id = H(me .. GetServerTime() .. math.random(1, 1e6))
    local d = { id = id, a = me, b = full, amount = copper, start = start, max = start, turn = me,
                state = "invite", rolls = {}, created = GetTime(), lastAct = GetTime() }
    ns.duels[id] = d
    if ns.Arena then ns.Arena.selectedDuelId = id end
    ns.Send("DRCH", table.concat({ id, clean(me), clean(full), d.amount, start }, ";"), "GUILD")
    DPrint(string.format("Du utfordret %s til Death Roll om %s (start %d). Venter på svar …",
        ns.Short(full), ns.FormatMoney(d.amount), start))
    ns.Sound("IG_PLAYER_INVITE")
    ns.DRRefresh()
    C_Timer.After(INVITE_TIMEOUT, function()
        if d.state == "invite" and not d.noTimeout then
            d.state = "cancelled"
            DPrint(ns.Short(full) .. " svarte ikke. Utfordringen er trukket tilbake.")
            ns.DRRefresh()
        end
    end)
    return id
end

-- Åpen 1v1: hvem som helst i guilden kan bli med, men BARE én motstander.
function ns.OpenChallenge(gold, start)
    if not ns.db then DPrint("Du må være i en guild.") return end
    if ns.MyActiveDuel() then DPrint("Du er allerede i en duell.") return end
    local copper = math.max(0, math.floor(tonumber(gold) or 0))   -- gold-param er ALLEREDE copper
    start = math.floor(tonumber(start) or 1000)
    if start < 2 then DPrint("Startverdien må være minst 2.") return end
    local me = ns.PlayerName()
    local id = H(me .. "open" .. GetServerTime() .. math.random(1, 1e6))
    local d = { id = id, a = me, b = nil, amount = copper, start = start, max = start, turn = me,
                state = "open", open = true, rolls = {}, created = GetTime(), lastAct = GetTime() }
    ns.duels[id] = d
    if ns.Arena then ns.Arena.selectedDuelId = id end
    ns.Send("DROP", table.concat({ id, clean(me), copper, start }, ";"), "GUILD")
    DPrint("Åpen 1v1 opprettet om " .. (copper > 0 and ns.FormatMoney(copper) or "ingen innsats")
        .. " – venter på at noen blir med …")
    ns.Sound("IG_PLAYER_INVITE")
    ns.DRRefresh()
    C_Timer.After(180, function()
        if d.state == "open" and not d.noTimeout then
            d.state = "cancelled"
            DPrint("Ingen ble med i den åpne kampen. Trukket tilbake.")
            ns.DRRefresh()
        end
    end)
    return id
end

-- Bli med i en åpen 1v1 (fra en annen enn oppretteren)
function ns.JoinOpen(id)
    local d = ns.duels[id]
    if not d or d.state ~= "open" then DPrint("Den kampen er ikke åpen lenger.") return end
    if ns.IsMe(d.a) then DPrint("Du kan ikke bli med i din egen kamp.") return end
    if ns.MyActiveDuel() then DPrint("Du er allerede i en duell.") return end
    ns.Send("DRJN", id .. ";" .. clean(ns.PlayerName()), "GUILD")
    DPrint("Ba om å bli med i kampen mot " .. ns.Short(d.a) .. " …")
end

function ns.Accept(id)
    local d = ns.duels[id]
    if not d or d.state ~= "invite" then return end
    d.state = "active"; d.lastAct = GetTime()
    ns.Send("DRAC", id, "GUILD")
    ns.Sound("READY_CHECK")
    if ns.OnDuelStart then ns.OnDuelStart(d) end
    ns.DRRefresh()
end

function ns.Decline(id)
    local d = ns.duels[id]
    if not d or d.state ~= "invite" then return end
    d.state = "declined"
    ns.Send("DRDE", id, "GUILD")
    ns.DRRefresh()
end

function ns.Forfeit()
    local d = ns.MyActiveDuel()
    if not d then return end
    local me = ns.PlayerName()
    ns.Send("DRCA", d.id .. ";" .. clean(me), "GUILD")
    ns.ApplyCancel(d, me)
end

function ns.ApplyCancel(d, who)
    if d.state == "invite" or d.state == "open" then
        d.state = "cancelled"
    elseif d.state == "active" then
        d.forfeit = true
        ns.Finish(d, who)
    end
    ns.DRRefresh()
end

function ns.DoRoll()
    local d = ns.MyActiveDuel()
    if not d or d.state ~= "active" or not ns.IsMe(d.turn) then return end
    if ns.pendingRoll and GetTime() - ns.pendingRoll.t < 3 then return end
    ns.pendingRoll = { id = d.id, max = d.max, t = GetTime() }
    if RandomRoll then RandomRoll(1, d.max)
    elseif C_RandomRoll and C_RandomRoll.RandomRoll then C_RandomRoll.RandomRoll(1, d.max) end
end

function ns.ApplyRoll(d, who, value, max)
    if d.state ~= "active" then return end
    if ns.Key(who) ~= ns.Key(d.turn) or max ~= d.max then return end
    local verified = ns.drSeen[ns.Key(who) .. ":" .. value .. ":" .. max] ~= nil or ns.IsMe(who)
    table.insert(d.rolls, { who = who, value = value, max = max, verified = verified })
    d.lastAct = GetTime()
    if ns.OnRoll then ns.OnRoll(d, who, value, max) end
    if value <= 1 then
        ns.Finish(d, who)
    else
        d.max = value
        d.turn = Other(d, who)
        if ns.IsMe(d.turn) then ns.Sound("RAID_WARNING") end
    end
    ns.DRRefresh()
end

function ns.Finish(d, loser)
    if d.state == "done" then return end
    d.state = "done"
    d.loser = loser
    d.winner = Other(d, loser)
    d.lastAct = GetTime()
    d.doneAt = GetServerTime()
    local db = DR()
    local r = { id = d.id, a = d.a, b = d.b, winner = d.winner, loser = d.loser,
                amount = d.tid and 0 or d.amount, rolls = #d.rolls, t = GetServerTime(),
                season = db and db.season or 0, paid = (d.tid ~= nil or d.amount == 0),
                kind = d.tid and "tmatch" or "duel", tid = d.tid, mi = d.mi }
    ns.StoreResult(r)
    if r.tid and ns.TournamentOnResult then ns.TournamentOnResult(r) end
    if ns.IsMe(d.a) or ns.IsMe(d.b) then
        ns.Send("DRRS", ns.EncodeResult(r), "GUILD")
        if ns.IsMe(loser) and d.amount > 0 then
            DPrint(string.format("Du tapte! Du skylder %s %s. Gi det i en trade, så merkes det som betalt.",
                ns.Short(d.winner), ns.FormatMoney(d.amount)))
        end
        -- (Ingen annonsering i guild chat – holdes lokalt i addonet.)
    end
    if ns.OnFinish then ns.OnFinish(d) end
    ns.DRRefresh()
end

---------------------------------------------------------------------------
-- Systemmeldinger: "Navn rolls 57 (1-100)"
---------------------------------------------------------------------------
local rollPattern
local function RollPattern()
    if rollPattern then return rollPattern end
    local fmt = RANDOM_ROLL_RESULT or "%s rolls %d (%d-%d)"
    fmt = fmt:gsub("%%%d%$", "%%")
    fmt = fmt:gsub("([%(%)%.%[%]%+%-%*%?%^%$])", "%%%1")
    fmt = fmt:gsub("%%s", "(.+)")
    fmt = fmt:gsub("%%d", "(%%d+)")
    rollPattern = "^" .. fmt .. "$"
    return rollPattern
end
ns.RollPattern = RollPattern

local function OnSystemMessage(msg)
    local name, value, lo, hi = msg:match(RollPattern())
    if not name then return end
    value, lo, hi = tonumber(value), tonumber(lo), tonumber(hi)
    if lo ~= 1 then return end
    ns.drSeen[ns.Key(name) .. ":" .. value .. ":" .. hi] = GetTime()
    if ns.IsMe(name) and ns.pendingRoll and hi == ns.pendingRoll.max then
        local d = ns.duels[ns.pendingRoll.id]
        ns.pendingRoll = nil
        if d then
            local me = ns.PlayerName()
            ns.Send("DRRO", table.concat({ d.id, clean(me), value, hi }, ";"), "GUILD")
            ns.ApplyRoll(d, me, value, hi)
        end
    else
        for _, d in pairs(ns.duels) do
            for _, r in ipairs(d.rolls) do
                if ns.Key(r.who) == ns.Key(name) and r.value == value and r.max == hi then r.verified = true end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Events (alle kan lage)
--  e = { id, title, host, when, stake(copper), start, note, rev, cancelled, created, by }
--  ns.db.signups[id] = { [key] = { name, joined, t } }
---------------------------------------------------------------------------
local function EventRev(e) return e and (e.rev or 1) or 0 end

function ns.EncodeEvent(e)
    return table.concat({ clean(e.id), clean(e.title), clean(e.host), e.when or 0, e.stake or 0,
        e.start or 1000, clean(e.note), e.rev or 1, e.cancelled and 1 or 0, e.created or 0, clean(e.by),
        clean(e.mode or "1v1"), clean(e.tid or ""), clean(e.invited or ""), clean(e.duelId or "") }, ";")
end

function ns.DecodeEvent(s)
    local x = split(s, ";")
    if #x < 11 or x[1] == "" then return nil end
    return { id = x[1], title = x[2], host = ns.Short(x[3]), when = tonumber(x[4]) or 0,
             stake = tonumber(x[5]) or 0, start = tonumber(x[6]) or 1000, note = x[7],
             rev = tonumber(x[8]) or 1, cancelled = x[9] == "1", created = tonumber(x[10]) or 0, by = ns.Short(x[11]),
             mode = (x[12] and x[12] ~= "") and x[12] or "1v1", tid = (x[13] and x[13] ~= "") and x[13] or nil,
             invited = (x[14] and x[14] ~= "") and ns.Short(x[14]) or nil,
             duelId = (x[15] and x[15] ~= "") and x[15] or nil }
end

-- returnerer true hvis noe endret seg
function ns.MergeEvent(e)
    if not ns.db or not e then return false end
    ns.EnsureDR()
    local old = ns.db.events[e.id]
    if old and EventRev(old) >= EventRev(e) then return false end
    -- behold evt. lokal "cancelled" selv om en gammel rev kommer inn
    ns.db.events[e.id] = e
    -- tilknyttet 1v1-duell skal ikke time ut av seg selv (den styres av eventet)
    if e.duelId and ns.duels and ns.duels[e.duelId] then
        ns.duels[e.duelId].noTimeout = true
        ns.duels[e.duelId].eventId = e.id
    end
    return true
end

function ns.SetSignup(id, name, joined, t)
    if not ns.db then return false end
    ns.EnsureDR()
    ns.db.signups[id] = ns.db.signups[id] or {}
    local key = ns.Key(name)
    local old = ns.db.signups[id][key]
    if old and (old.t or 0) >= t then return false end
    ns.db.signups[id][key] = { name = ns.Short(name), joined = joined, t = t }
    return true
end

function ns.SignupCount(id)
    local n = 0
    for _, s in pairs(ns.db and ns.db.signups[id] or {}) do if s.joined then n = n + 1 end end
    return n
end

function ns.AmSignedUp(id)
    local s = ns.db and ns.db.signups[id] and ns.db.signups[id][ns.Key(ns.PlayerName())]
    return s ~= nil and s.joined
end

function ns.SignupList(id)
    local out = {}
    for _, s in pairs(ns.db and ns.db.signups[id] or {}) do
        if s.joined then out[#out + 1] = s.name end
    end
    table.sort(out, function(a, b) return a:lower() < b:lower() end)
    return out
end

-- Kommende (ikke avlyste, ikke utgått) events, sortert etter tid
function ns.EventList()
    local out = {}
    if not ns.db then return out end
    local now = GetServerTime()
    for _, e in pairs(ns.db.events) do
        local past = e.when and e.when > 0 and now > e.when + 3 * 3600
        -- ferdig turnering: vis vinneren i 10 min, så forsvinner eventet
        local doneT = false
        if e.tid then
            local t = ns.db.tournaments[e.tid]
            if t and t.finished then
                local fa = t.finishedAt
                doneT = (not fa) or (now > fa + 600)
            end
        end
        -- 1v1-event: vis vinneren i 10 min etter at duellen er ferdig, så forsvinn
        if e.duelId then
            local d = ns.duels and ns.duels[e.duelId]
            if d then
                if d.state == "done" then
                    local fa = d.doneAt or 0
                    if fa == 0 or now > fa + 600 then doneT = true end
                elseif d.state == "declined" or d.state == "cancelled" then
                    doneT = true
                end
            end
        end
        if not e.cancelled and not past and not doneT then out[#out + 1] = e end
    end
    table.sort(out, function(a, b)
        local wa = (a.when and a.when > 0) and a.when or (a.created + 1e10)
        local wb = (b.when and b.when > 0) and b.when or (b.created + 1e10)
        if wa ~= wb then return wa < wb end
        return (a.created or 0) < (b.created or 0)
    end)
    return out
end

function ns.CreateEvent(title, whenEpoch, stakeCopper, startVal, note, mode, invited)
    if not ns.db then DPrint("Du må være i en guild.") return end
    ns.EnsureDR()
    local me = ns.PlayerName()
    local id = H(me .. GetServerTime() .. math.random(1, 1e6))
    invited = invited and invited:gsub("^%s*@?%s*", ""):gsub("%s+$", "") or ""
    local e = { id = id, title = (title ~= "" and title) or "Death Roll", host = me,
                when = whenEpoch or 0, stake = stakeCopper or 0, start = startVal or 1000,
                note = note or "", rev = 1, cancelled = false, created = GetServerTime(), by = me,
                mode = (mode == "tournament") and "tournament" or "1v1",
                invited = (invited ~= "") and invited or nil }
    ns.db.events[id] = e
    -- 1v1 «nå»: opprett tilknyttet duell med en gang (vises som event-kort du kan gå inn/ut av)
    if e.mode == "1v1" and (whenEpoch or 0) == 0 then
        local did
        if e.invited then
            did = ns.Challenge(e.invited, e.stake, e.start)
            if not did then ns.db.events[id] = nil; return end   -- fant ikke spiller e.l.
        else
            did = ns.OpenChallenge(e.stake, e.start)
        end
        if did and ns.duels[did] then
            e.duelId = did
            ns.duels[did].eventId = id
            ns.duels[did].noTimeout = true    -- event-dueller utløper ikke av seg selv
        end
    end
    ns.Send("EVNEW", ns.EncodeEvent(e), "GUILD")
    ns.JoinEvent(id, true)   -- verten blir automatisk påmeldt (for turnering/planlagt)
    DPrint("Event laget: " .. e.title .. " (" .. (e.mode == "tournament" and "turnering" or "1v1")
        .. "). Alle i guilden ser det nå.")
    if e.duelId and ns.FocusArenaDuel then ns.FocusArenaDuel(e.duelId) end
    ns.DRRefresh()
    return id
end

function ns.CancelEvent(id)
    local e = ns.db and ns.db.events[id]
    if not e then return end
    if not (ns.IsMe(e.host) or ns.IsGM(ns.PlayerName())) then
        DPrint("Bare den som lagde eventet (eller GM) kan avlyse det.")
        return
    end
    e.cancelled = true
    e.rev = (e.rev or 1) + 1
    -- avlys den tilknyttede 1v1-duellen (hvis den ikke er ferdig)
    if e.duelId then
        local d = ns.duels[e.duelId]
        if d and (d.state == "invite" or d.state == "open" or d.state == "active") then
            d.noTimeout = nil
            ns.Send("DRCA", d.id .. ";" .. clean(ns.PlayerName()), "GUILD")
            ns.ApplyCancel(d, ns.PlayerName())
        end
    end
    ns.Send("EVNEW", ns.EncodeEvent(e), "GUILD")
    DPrint("Eventet er avlyst.")
    ns.DRRefresh()
end

local function mySignupTime(id)
    local prev = ns.db and ns.db.signups[id] and ns.db.signups[id][ns.Key(ns.PlayerName())]
    return math.max(GetServerTime(), (prev and prev.t or 0) + 1)   -- strengt økende per spiller
end

function ns.JoinEvent(id, silent)
    local e = ns.db and ns.db.events[id]
    if not e then return end
    local me = ns.PlayerName()
    local t = mySignupTime(id)
    ns.SetSignup(id, me, true, t)
    ns.Send("EVSIGN", table.concat({ clean(id), clean(me), 1, t }, ";"), "GUILD")
    if not silent then DPrint("Du er påmeldt: " .. e.title) end
    ns.DRRefresh()
end

function ns.LeaveEvent(id)
    local e = ns.db and ns.db.events[id]
    if not e then return end
    local me = ns.PlayerName()
    local t = mySignupTime(id)
    ns.SetSignup(id, me, false, t)
    ns.Send("EVSIGN", table.concat({ clean(id), clean(me), 0, t }, ";"), "GUILD")
    ns.DRRefresh()
end

---------------------------------------------------------------------------
-- Mottak (registrert i GuildKompass sin Handlers-tabell)
---------------------------------------------------------------------------
local Handlers = ns.Handlers

Handlers.DRCH = function(from, data)
    local x = split(data, ";")
    if #x < 5 then return end
    local id, a, b, amount, start = x[1], ns.Short(x[2]), ns.Short(x[3]), tonumber(x[4]) or 0, tonumber(x[5]) or 1000
    local tid = (x[6] and x[6] ~= "") and x[6] or nil
    local mi = tonumber(x[7]) or nil
    if ns.Key(a) ~= ns.Key(from) then return end
    -- Turneringskamp: hvis begge trykket «Spill kampen» samtidig har jeg kanskje
    -- en egen utgående invitasjon med samme id. Da vinner den "kanoniske" starteren
    -- (lavest navn), så begge ender opp med samme kamp (a=kanonisk, b=den andre).
    if tid then
        local mine = ns.duels[id]
        if mine and mine.state == "invite" and ns.IsMe(mine.a) then
            local canon = (ns.Key(mine.a) < ns.Key(mine.b)) and mine.a or mine.b
            if ns.IsMe(canon) then return end   -- jeg er kanonisk starter: behold min, ignorer innkommende
            -- ellers: jeg viker og godtar den innkommende (faller gjennom)
        end
    end
    local d = { id = id, a = from, b = b, amount = amount, start = start, max = start, turn = from,
                state = "invite", rolls = {}, created = GetTime(), lastAct = GetTime(), tid = tid, mi = mi }
    ns.duels[id] = d
    if ns.IsMe(b) then
        if ns.MyActiveDuel() and ns.MyActiveDuel() ~= d then
            ns.Send("DRDE", id, "GUILD")
            d.state = "declined"
            return
        end
        d.b = ns.PlayerName()
        if tid then
            -- Turneringskamp: godta AUTOMATISK – du er den utpekte motstanderen og
            -- det er din tur i bracketen. Da slipper begge å trykke, og ingen havner
            -- i «begge venter på hverandre»-lås. Ingen auto-timeout på turneringskamper.
            C_Timer.After(0.3, function()
                if d.state == "invite" then ns.Accept(id) end
            end)
        else
            if ns.ShowInvite then ns.ShowInvite(d) end
            C_Timer.After(INVITE_TIMEOUT, function()
                if d.state == "invite" and not d.noTimeout then d.state = "cancelled"; ns.DRRefresh() end
            end)
        end
    end
    ns.DRRefresh()
end

Handlers.DRAC = function(from, id)
    local d = ns.duels[id]
    if not d or d.state ~= "invite" or ns.Key(from) ~= ns.Key(d.b) then return end
    d.state = "active"; d.lastAct = GetTime()
    if ns.IsMe(d.a) then
        DPrint(ns.Short(d.b) .. " godtok! Du starter – trykk ROLL.")
        ns.Sound("READY_CHECK")
    end
    -- Tilskuer-varsel: kamp (1v1 eller turnering) som jeg ikke selv er med i
    if not (ns.IsMe(d.a) or ns.IsMe(d.b)) then
        ns.SpectateWarn(d)
    end
    if ns.OnDuelStart then ns.OnDuelStart(d) end
    ns.DRRefresh()
end

Handlers.DRDE = function(from, id)
    local d = ns.duels[id]
    if not d or d.state ~= "invite" then return end
    d.state = "declined"
    if ns.IsMe(d.a) then DPrint(ns.Short(from) .. " avslo utfordringen.") end
    if ns.HideInvite then ns.HideInvite(d) end
    ns.DRRefresh()
end

Handlers.DRCA = function(from, data)
    local x = split(data, ";")
    local d = ns.duels[x[1] or ""]
    if not d or ns.Key(from) ~= ns.Key(x[2]) then return end
    if ns.Key(from) ~= ns.Key(d.a) and ns.Key(from) ~= ns.Key(d.b) then return end
    if ns.HideInvite then ns.HideInvite(d) end
    ns.ApplyCancel(d, from)
end

-- Åpen 1v1 opprettet: alle lagrer rommet (uten motstander ennå)
Handlers.DROP = function(from, data)
    local x = split(data, ";")
    if #x < 4 then return end
    local id, a, amount, start = x[1], ns.Short(x[2]), tonumber(x[3]) or 0, tonumber(x[4]) or 1000
    if ns.Key(a) ~= ns.Key(from) then return end
    if ns.duels[id] then return end
    ns.duels[id] = { id = id, a = from, b = nil, amount = amount, start = start, max = start,
                     turn = from, state = "open", open = true, rolls = {},
                     created = GetTime(), lastAct = GetTime() }
    if not ns.IsMe(from) and ns.global and ns.global.eventWarnings and ns.Anim and ns.Anim.Banner then
        ns.Anim.Banner("ÅPEN 1v1!", ns.Short(from) .. " venter på motstander – åpne arenaen og bli med")
    end
    ns.DRRefresh()
end

-- Noen ber om å bli med: BARE oppretteren tildeler, og bare den første.
Handlers.DRJN = function(from, data)
    local x = split(data, ";")
    local id, joiner = x[1], ns.Short(x[2] or "")
    local d = ns.duels[id or ""]
    if not d or ns.Key(joiner) ~= ns.Key(from) then return end
    if not ns.IsMe(d.a) then return end
    if d.state ~= "open" or d.b then return end
    if ns.Key(joiner) == ns.Key(d.a) then return end
    d.b = joiner; d.state = "active"; d.turn = d.a; d.open = nil; d.lastAct = GetTime()
    ns.Send("DROK", table.concat({ id, clean(d.a), clean(d.b), d.amount or 0, d.start or 1000 }, ";"), "GUILD")
    DPrint(ns.Short(joiner) .. " ble med! Du starter – trykk ROLL.")
    ns.Sound("READY_CHECK")
    if ns.OnDuelStart then ns.OnDuelStart(d) end
    ns.DRRefresh()
end

-- Bekreftelse: motstander valgt, kampen er i gang (alle oppdaterer rommet)
Handlers.DROK = function(from, data)
    local x = split(data, ";")
    if #x < 5 then return end
    local id, a, b, amount, start = x[1], ns.Short(x[2]), ns.Short(x[3]), tonumber(x[4]) or 0, tonumber(x[5]) or 1000
    if ns.Key(a) ~= ns.Key(from) then return end
    local d = ns.duels[id]
    if not d then d = { id = id, a = from, rolls = {}, created = GetTime() }; ns.duels[id] = d end
    if d.state == "active" or d.state == "done" then return end
    d.a = from; d.b = b; d.amount = amount; d.start = start; d.max = start
    d.turn = a; d.state = "active"; d.open = nil; d.lastAct = GetTime()
    d.rolls = d.rolls or {}
    if ns.IsMe(b) then
        DPrint("Du ble med i kampen mot " .. ns.Short(a) .. "! Vent på hans kast.")
        ns.Sound("READY_CHECK")
    elseif not ns.IsMe(a) then
        ns.SpectateWarn(d)
    end
    if ns.OnDuelStart then ns.OnDuelStart(d) end
    ns.DRRefresh()
end

Handlers.DRRO = function(from, data)
    local x = split(data, ";")
    if #x < 4 then return end
    local d = ns.duels[x[1]]
    if not d or ns.Key(from) ~= ns.Key(x[2]) then return end
    ns.ApplyRoll(d, from, tonumber(x[3]) or 0, tonumber(x[4]) or 0)
end

ns.drCovered = ns.drCovered or {}

Handlers.DRRS = function(from, data)
    local changed = false
    for _, s in ipairs(split(data, "/")) do
        local r = ns.DecodeResult(s)
        if r then
            ns.drCovered[r.id] = true
            if ns.StoreResult(r) then changed = true end
            if r.tid and ns.TournamentOnResult then
                if ns.TournamentOnResult(r) then changed = true end
            end
        end
    end
    if changed then ns.DRRefresh() end
end

Handlers.DRPA = function(from, id)
    local db = DR()
    local r = db and db.results[id]
    if r and ns.Key(from) == ns.Key(r.loser) and not r.paid then
        r.paid = true
        ns.DRRefresh()
    end
end

Handlers.DRSE = function(from, data)
    local db = DR()
    local s = tonumber(data)
    if db and s and s > db.season and ns.IsGM(from) then
        db.season = s
        DPrint("Guildmaster har startet en ny Death Roll-sesong!")
        ns.DRRefresh()
    end
end

-- Full GM-config: eventDay;cfgTime;resetWday;resetHour;weekReset
-- (gamle klienter sendte bare eventDay;cfgTime – da beholdes resten)
function ns.SendDRConfig()
    local db = DR()
    if not db then return end
    db.cfgTime = math.max(GetServerTime(), (db.cfgTime or 0) + 1)
    ns.Send("DRCF", table.concat({ db.eventDay or 4, db.cfgTime, db.resetWday or 0,
        db.resetHour or 4, db.weekReset or 0 }, ";"), "GUILD")
end

Handlers.DRCF = function(from, data)
    local db = DR()
    if not db or not ns.IsGM(from) then return end
    local x = split(data, ";")
    local day, t = tonumber(x[1]), tonumber(x[2])
    if not day or not t or t <= (db.cfgTime or 0) then return end
    db.eventDay, db.cfgTime = day, t
    if x[3] then db.resetWday = tonumber(x[3]) or db.resetWday end
    if x[4] then db.resetHour = tonumber(x[4]) or db.resetHour end
    if x[5] then db.weekReset = math.max(db.weekReset or 0, tonumber(x[5]) or 0) end
    ns.DRRefresh()
end

-- Hello ved innlogging: send hva jeg har, be om det jeg mangler
function ns.DR_SendHello()
    local db = DR()
    if not db or not IsInGuild() then return end
    local ids = {}
    for id in pairs(db.results) do ids[#ids + 1] = H(id) end
    ns.Send("DRHI", db.season .. ";" .. table.concat(ids, ","), "GUILD")
    -- GM re-kringkaster gjeldende config så nye/offline medlemmer får vedlikeholdsdag m.m.
    if ns.IsGM(ns.PlayerName()) then
        ns.Send("DRCF", table.concat({ db.eventDay or 4, db.cfgTime or 0, db.resetWday or 0,
            db.resetHour or 4, db.weekReset or 0 }, ";"), "GUILD")
    end
    -- events: send listen over event-id:rev jeg har
    local evs = {}
    for id, e in pairs(ns.db.events) do evs[#evs + 1] = H(id) .. ":" .. (e.rev or 1) end
    ns.Send("EVHI", table.concat(evs, ","), "GUILD")
end

Handlers.DRHI = function(from, data)
    local db = DR()
    if not db then return end
    local season, list = data:match("^(%d+);(.*)$")
    season = tonumber(season) or 0
    local have = {}
    for h in (list or ""):gmatch("[^,]+") do have[h] = true end
    local missing = {}
    for id in pairs(db.results) do
        if not have[H(id)] then missing[#missing + 1] = id end
    end
    local needSeason = db.season > season
    if #missing == 0 and not needSeason then return end
    wipe(ns.drCovered)
    C_Timer.After(1 + math.random() * 4, function()
        if needSeason then ns.Send("DRSE", tostring(db.season), "GUILD") end
        local batch = {}
        for _, id in ipairs(missing) do
            if not ns.drCovered[id] and db.results[id] then
                batch[#batch + 1] = ns.EncodeResult(db.results[id])
                ns.drCovered[id] = true
                if #batch >= 6 then ns.Send("DRRS", table.concat(batch, "/"), "GUILD"); batch = {} end
            end
        end
        if #batch > 0 then ns.Send("DRRS", table.concat(batch, "/"), "GUILD") end
    end)
end

-- Varsel (banner) når noen lager en ny TURNERING: meld deg på.
function ns.EventWarn(e)
    if not ns.global.eventWarnings or not ns.Anim then return end
    if e.mode ~= "tournament" then return end     -- 1v1 varsles når selve kampen starter
    ns.Anim.Banner("DEATH ROLL-TURNERING!", "Meld deg på i guild-vinduet"
        .. (e.title and e.title ~= "" and e.title ~= "Death Roll" and ("  ·  " .. e.title) or ""))
end

-- Varsel (banner) når en 1v1-kamp starter: gå inn og se kampen mellom X og Y.
function ns.SpectateWarn(d)
    if not ns.global.eventWarnings or not ns.Anim then return end
    ns.Anim.Banner("DEATH ROLL!", "Gå inn og se kampen: " .. ns.Short(d.a) .. " mot " .. ns.Short(d.b))
end

Handlers.EVNEW = function(from, data)
    local e = ns.DecodeEvent(data)
    if not e then return end
    local existed = ns.db and ns.db.events[e.id] ~= nil
    if ns.MergeEvent(e) then
        -- varsle bare om GENUINT nye events (ikke egne, ikke gamle via innlogging-synk)
        if not existed and not e.cancelled and not ns.IsMe(e.host)
            and (GetServerTime() - (e.created or 0)) < 180 then
            ns.EventWarn(e)
        end
        ns.DRRefresh()
    end
end

Handlers.EVSIGN = function(from, data)
    local x = split(data, ";")
    if #x < 4 then return end
    local id, name, joined, t = x[1], ns.Short(x[2]), x[3] == "1", tonumber(x[4]) or 0
    -- stol bare på at folk melder seg på/av SEG SELV
    if ns.Key(name) ~= ns.Key(from) then return end
    if ns.SetSignup(id, name, joined, t) then ns.DRRefresh() end
end

local evCovered = {}

Handlers.EVHI = function(from, data)
    if not ns.db then return end
    ns.EnsureDR()
    local have = {}
    for p in (data or ""):gmatch("[^,]+") do
        local h, rev = p:match("^(%x+):(%d+)$")
        if h then have[h] = tonumber(rev) end
    end
    -- events der jeg har nyere/manglende rev hos den som spør
    local send = {}
    for id, e in pairs(ns.db.events) do
        local hv = have[H(id)]
        if not hv or hv < (e.rev or 1) then send[#send + 1] = id end
    end
    local tourns = {}
    for tid in pairs(ns.db.tournaments) do tourns[#tourns + 1] = tid end
    if #send == 0 and #tourns == 0 then return end
    C_Timer.After(1 + math.random() * 4, function()
        for _, id in ipairs(send) do
            local e = ns.db.events[id]
            if e then
                ns.Send("EVNEW", ns.EncodeEvent(e), "GUILD")
                for _, s in pairs(ns.db.signups[id] or {}) do
                    ns.Send("EVSIGN", table.concat({ clean(id), clean(s.name), s.joined and 1 or 0, s.t or 0 }, ";"), "GUILD")
                end
            end
        end
        for _, tid in ipairs(tourns) do
            local t = ns.db.tournaments[tid]
            if t then ns.Send("TNEW", ns.EncodeTournament(t), "GUILD") end
        end
    end)
end

Handlers.TNEW = function(from, data)
    local t = ns.DecodeTournament(data)
    if t and ns.MergeTournament(t) then ns.DRRefresh() end
end

---------------------------------------------------------------------------
-- Betaling via trade
---------------------------------------------------------------------------
function ns.MyDebts()
    local owe, owed = {}, {}
    local db = DR()
    for _, r in pairs(db and db.results or {}) do
        if not r.paid and r.amount > 0 then
            if ns.IsMe(r.loser) then owe[#owe + 1] = r elseif ns.IsMe(r.winner) then owed[#owed + 1] = r end
        end
    end
    return owe, owed
end

local trade = {}
local function OnTrade(event, ...)
    if event == "TRADE_SHOW" then
        trade = { partner = ns.FullName(UnitName("NPC")), money = 0 }
    elseif event == "TRADE_MONEY_CHANGED" or event == "TRADE_ACCEPT_UPDATE" or event == "TRADE_PLAYER_ITEM_CHANGED" then
        local m = GetPlayerTradeMoney and GetPlayerTradeMoney()
        if m then trade.money = m end
    elseif event == "UI_INFO_MESSAGE" then
        local a, b = ...
        local msg = b or a
        if msg == ERR_TRADE_COMPLETE and trade.partner and (trade.money or 0) > 0 then
            local left = trade.money
            local owe = ns.MyDebts()
            table.sort(owe, function(x, y) return x.t < y.t end)
            for _, r in ipairs(owe) do
                if ns.Key(r.winner) == ns.Key(trade.partner) and left >= r.amount then
                    r.paid = true
                    left = left - r.amount
                    ns.Send("DRPA", r.id, "GUILD")
                    DPrint(string.format("Betaling registrert: %s til %s. Gjeld oppgjort!",
                        ns.FormatMoney(r.amount), ns.Short(r.winner)))
                end
            end
            trade = {}
            ns.DRRefresh()
        elseif msg == ERR_TRADE_CANCELLED then
            trade = {}
        end
    end
end

---------------------------------------------------------------------------
-- Statistikk
---------------------------------------------------------------------------
function ns.Leaderboard(period)
    local stats = {}
    local db = DR()
    if not db then return {} end
    local since = (period == "week") and ns.WeekStart() or 0
    local function S(name)
        local k = ns.Key(name)
        local s = stats[k]
        if not s then s = { name = name, wins = 0, losses = 0, w1 = 0, l1 = 0, wt = 0, lt = 0,
                            won = 0, lost = 0, best = 0, games = 0 }; stats[k] = s end
        return s
    end
    local list = {}
    for _, r in pairs(db.results) do
        if r.season == db.season and r.t >= since then list[#list + 1] = r end
    end
    for _, r in ipairs(list) do
        local w, l = S(r.winner), S(r.loser)
        if r.kind ~= "tpot" then
            -- vanlig duell eller turneringskamp: teller seire/tap
            if r.kind == "tmatch" then
                w.wt = w.wt + 1; l.lt = l.lt + 1          -- turnering
            else
                w.w1 = w.w1 + 1; l.l1 = l.l1 + 1          -- 1v1
            end
            w.wins = w.wins + 1; w.games = w.games + 1
            l.losses = l.losses + 1; l.games = l.games + 1
        end
        -- gull: duell + pott-oppgjør (turneringskamper har 0)
        w.won = w.won + (r.amount or 0)
        if (r.amount or 0) > w.best then w.best = r.amount end
        l.lost = l.lost + (r.amount or 0)
    end
    local out = {}
    for _, s in pairs(stats) do s.net = s.won - s.lost; out[#out + 1] = s end
    table.sort(out, function(x, y)
        if x.net ~= y.net then return x.net > y.net end
        if x.wins ~= y.wins then return x.wins > y.wins end
        return x.name < y.name
    end)
    return out
end

-- GM: nullstill hele sesongtabellen (skjuler alle tidligere resultater)
function ns.ResetSeason()
    local db = DR()
    if not db then return end
    db.season = math.max(GetServerTime(), (db.season or 0) + 1)
    ns.Send("DRSE", tostring(db.season), "GUILD")
    DPrint("Ny sesong startet – hele topplisten er nullstilt for alle.")
    ns.DRRefresh()
end

-- GM: nullstill ukestabellen nå (påvirker bare uke-visningen, ikke sesongen)
function ns.ResetWeek()
    local db = DR()
    if not db then return end
    db.weekReset = math.max(GetServerTime(), (db.weekReset or 0) + 1)
    ns.SendDRConfig()
    DPrint("Ukestabellen er nullstilt for alle.")
    ns.DRRefresh()
end

function ns.History()
    local out = {}
    local db = DR()
    if not db then return out end
    for _, r in pairs(db.results) do
        if r.season == db.season then out[#out + 1] = r end
    end
    table.sort(out, function(x, y) return x.t > y.t end)
    return out
end

-- Rekorder/statistikk for sesongen
function ns.DeathRollStats()
    local db = DR()
    if not db then return {} end
    local S = {}
    local function g(name)
        local k = ns.Key(name)
        local s = S[k]
        if not s then s = { name = ns.Short(name), wins = 0, losses = 0, won = 0, lost = 0, best = 0 }; S[k] = s end
        return s
    end
    local list = {}
    for _, r in pairs(db.results) do if r.season == db.season then list[#list + 1] = r end end
    table.sort(list, function(a, b) return (a.t or 0) < (b.t or 0) end)
    local bestRollDuel, biggestWin
    local streakMax, streakCur = {}, {}
    for _, r in ipairs(list) do
        if r.kind ~= "tpot" then
            g(r.winner).wins = g(r.winner).wins + 1
            g(r.loser).losses = g(r.loser).losses + 1
            local lk, wk = ns.Key(r.loser), ns.Key(r.winner)
            streakCur[lk] = (streakCur[lk] or 0) + 1
            streakMax[lk] = math.max(streakMax[lk] or 0, streakCur[lk])
            streakCur[wk] = 0
            if (r.rolls or 0) > (bestRollDuel and bestRollDuel.rolls or -1) then bestRollDuel = r end
        end
        if (r.amount or 0) > 0 then
            g(r.winner).won = g(r.winner).won + r.amount
            local l = g(r.loser); l.lost = l.lost + r.amount
            local w = g(r.winner); if r.amount > w.best then w.best = r.amount end
            if not biggestWin or r.amount > biggestWin.amount then biggestWin = { name = ns.Short(r.winner), amount = r.amount } end
        end
    end
    local function top(field)
        local best
        for _, s in pairs(S) do if (s[field] or 0) > 0 and (not best or s[field] > best[field]) then best = s end end
        return best
    end
    local out = {}
    local mw = top("wins"); if mw then out[#out + 1] = { icon = "Interface\\Icons\\Achievement_PVP_A_A", label = "Flest seire", who = mw.name, val = mw.wins .. " seire" } end
    local ml = top("losses"); if ml then out[#out + 1] = { icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8", label = "Uflakskongen (flest tap)", who = ml.name, val = ml.losses .. " tap" } end
    local lsKey, lsVal = nil, 0
    for k, v in pairs(streakMax) do if v > lsVal then lsVal = v; lsKey = k end end
    if lsKey and lsVal > 1 then out[#out + 1] = { icon = "Interface\\Icons\\Spell_Shadow_DeathCoil", label = "Lengste tapsrekke", who = S[lsKey].name, val = lsVal .. " tap på rad" } end
    local mwon = top("won"); if mwon then out[#out + 1] = { icon = "Interface\\Icons\\INV_Misc_Coin_01", label = "Mest vunnet", who = mwon.name, val = ns.MoneyText(mwon.won) } end
    local mlost = top("lost"); if mlost then out[#out + 1] = { icon = "Interface\\Icons\\INV_Misc_Coin_02", label = "Mest tapt", who = mlost.name, val = ns.MoneyText(mlost.lost) } end
    if biggestWin then out[#out + 1] = { icon = "Interface\\Icons\\INV_Misc_Coin_17", label = "Største enkeltgevinst", who = biggestWin.name, val = ns.MoneyText(biggestWin.amount) } end
    if bestRollDuel then out[#out + 1] = { icon = "Interface\\Icons\\Ability_Rogue_RolltheBones01", label = "Lengste duell", who = ns.Short(bestRollDuel.winner) .. " vs " .. ns.Short(bestRollDuel.loser), val = (bestRollDuel.rolls or 0) .. " kast" } end
    return out
end

---------------------------------------------------------------------------
-- TURNERING (single-elimination bracket, felles pott – vinneren tar alt)
--  t = { tid, eventId, part={navn...}, stake(copper), start, season,
--        winners={navn...}, started, finished, champion, created, by, rev }
---------------------------------------------------------------------------
local function cleanList(list)
    local o = {}
    for i, v in ipairs(list or {}) do o[i] = clean(v) end
    return table.concat(o, ",")
end
local function parseList(s)
    local o = {}
    if s and s ~= "" then for v in s:gmatch("[^,]+") do o[#o + 1] = v end end
    return o
end

function ns.EncodeTournament(t)
    return table.concat({ clean(t.tid), clean(t.eventId), t.stake or 0, t.start or 1000, t.season or 0,
        t.created or 0, clean(t.by), t.rev or 1, t.finished and 1 or 0, clean(t.champion or ""),
        cleanList(t.part), cleanList(t.winners) }, ";")
end

function ns.DecodeTournament(s)
    local x = split(s, ";")
    if #x < 12 or x[1] == "" then return nil end
    return { tid = x[1], eventId = x[2], stake = tonumber(x[3]) or 0, start = tonumber(x[4]) or 1000,
             season = tonumber(x[5]) or 0, created = tonumber(x[6]) or 0, by = ns.Short(x[7]),
             rev = tonumber(x[8]) or 1, finished = x[9] == "1", champion = (x[10] ~= "" and ns.Short(x[10]) or nil),
             started = true, part = parseList(x[11]), winners = parseList(x[12]) }
end

-- Deterministisk single-elimination bracket. Likt hos alle gitt part[] (fast,
-- stokket rekkefølge) og winners[] (vinnere i kamp-rekkefølge). Er antallet ikke
-- en toerpotens, får de første (S-N) spillerne i part[] en bye (fritak) i runde 1.
-- Kampene spilles én om gangen (current = neste uspilte kamp).
-- Returnerer: rounds (hele treet, for visning), matches (ekte kamper i spill-
-- rekkefølge med stabil idx), current, finished, champion, byes.
local BYE = "(bye)"
local PENDING = {}            -- plassholder for ennå-ukjent deltaker (beholder tabell-lengde)
ns.BYE = BYE
function ns.ComputeBracket(part, winners)
    winners = winners or {}
    local N = #part
    if N == 0 then return { rounds = {}, matches = {}, finished = true, byes = 0 } end
    if N == 1 then return { rounds = {}, matches = {}, finished = true, champion = part[1], byes = 0 } end
    local S = 1
    while S < N do S = S * 2 end
    local byes = S - N
    -- Runde 1: de med bye først (paret med BYE), så resten parvis.
    local entr = {}
    for i = 1, byes do entr[#entr + 1] = part[i]; entr[#entr + 1] = BYE end
    for i = byes + 1, N do entr[#entr + 1] = part[i] end
    local rounds, matches = {}, {}
    local current, roundNo = nil, 0
    while #entr > 1 do
        roundNo = roundNo + 1
        local rnd, nextEntr = {}, {}
        for i = 1, #entr, 2 do
            local ra, rb = entr[i], entr[i + 1]
            local a = (ra ~= PENDING) and ra or nil
            local b = (rb ~= PENDING) and rb or nil
            local m = { a = a, b = b, round = roundNo }
            if a == BYE or b == BYE then
                m.bye = true
                m.winner = (a == BYE) and b or a
            else
                matches[#matches + 1] = m
                m.idx = #matches
                if a ~= nil and b ~= nil then
                    m.winner = winners[m.idx]
                    if (not m.winner) and (not current) then current = m.idx; m.current = true end
                end
            end
            rnd[#rnd + 1] = m
            nextEntr[#nextEntr + 1] = m.winner or PENDING
        end
        rounds[#rounds + 1] = rnd
        entr = nextEntr
    end
    local champion = (entr[1] ~= PENDING) and entr[1] or nil
    return { rounds = rounds, matches = matches, current = current,
             finished = (champion ~= nil), champion = champion, byes = byes }
end

-- Varsle spilleren når det blir hans tur i en turnering (én gang per kamp).
function ns.CheckTurnNotify(t)
    if not t or t.finished then return end
    local b = ns.ComputeBracket(t.part, t.winners)
    if not b.current then return end
    local m = b.matches[b.current]
    if not m then return end
    if not (ns.IsMe(m.a) or ns.IsMe(m.b)) then return end
    -- Ser du allerede på kampen (vinduet åpent) blir du automatisk tatt inn,
    -- siden det er din tur. Da slipper du å trykke noe.
    if ns.Arena and ns.Arena.frame and ns.Arena.frame:IsShown() and ns.PlayTournamentMatch then
        ns.PlayTournamentMatch(t.tid)
    end
    t._turnNotified = t._turnNotified or {}
    if t._turnNotified[b.current] then return end
    t._turnNotified[b.current] = true
    local opp = ns.IsMe(m.a) and m.b or m.a
    DPrint("|cffffd100Din tur i turneringen!|r Kamp mot " .. ns.Short(opp)
        .. " – gå inn via «Spill kampen» på eventet.")
    ns.Sound("READY_CHECK")
    if ns.Anim and ns.Anim.Banner then ns.Anim.Banner("DIN TUR!", "Turneringskamp mot " .. ns.Short(opp)) end
end

function ns.StartTournament(eventId, buyInCopper)
    local e = ns.db and ns.db.events[eventId]
    if not e or e.mode ~= "tournament" then return end
    if not (ns.IsMe(e.host) or ns.IsGM(ns.PlayerName())) then
        DPrint("Bare den som lagde eventet (eller GM) kan starte turneringen.")
        return
    end
    if e.tid and ns.db.tournaments[e.tid] and not ns.db.tournaments[e.tid].finished then
        DPrint("Turneringen er allerede startet.")
        return
    end
    local part = ns.SignupList(eventId)
    if #part < 2 then DPrint("Det må være minst 2 påmeldte for å starte.") return end
    for i = #part, 2, -1 do local j = math.random(1, i); part[i], part[j] = part[j], part[i] end
    local stake = buyInCopper or e.stake or 0
    if stake < 0 then stake = 0 end
    local db = DR()
    local tid = H(eventId .. "T" .. GetServerTime() .. math.random(1, 1e6))
    local t = { tid = tid, eventId = eventId, part = part, stake = stake, start = e.start or 1000,
                season = db and db.season or 0, winners = {}, started = true, finished = false,
                created = GetServerTime(), by = ns.PlayerName(), rev = 1 }
    ns.db.tournaments[tid] = t
    e.tid = tid; e.stake = stake; e.rev = (e.rev or 1) + 1
    ns.Send("EVNEW", ns.EncodeEvent(e), "GUILD")
    ns.Send("TNEW", ns.EncodeTournament(t), "GUILD")
    DPrint("Turnering startet med " .. #part .. " spillere · buy-in "
        .. (stake > 0 and ns.FormatMoney(stake) or "ingen") .. "!")
    ns.Sound("READY_CHECK")
    local b0 = ns.ComputeBracket(t.part, t.winners)
    if (b0.byes or 0) > 0 and ns.ShowByeWheel then t._wheelShown = true; ns.ShowByeWheel(t) end
    ns.CheckTurnNotify(t)
    ns.DRRefresh()
    return tid
end

function ns.MergeTournament(t2)
    if not ns.db then return false end
    ns.EnsureDR()
    local old = ns.db.tournaments[t2.tid]
    if old then
        local newer = (#t2.winners > #old.winners) or (#t2.winners == #old.winners and (t2.rev or 0) > (old.rev or 0))
        if not newer then return false end
    end
    if old then t2._wheelShown = old._wheelShown; t2._turnNotified = old._turnNotified end
    ns.db.tournaments[t2.tid] = t2
    local b = ns.ComputeBracket(t2.part, t2.winners)
    if b.finished and not t2.finished then
        t2.finished = true; t2.champion = b.champion
    end
    if t2.finished and not t2._announced then
        t2._announced = true
        ns.OnTournamentFinished(t2, true)
    end
    if (not t2.finished) and (not t2._wheelShown) and (b.byes or 0) > 0 and ns.ShowByeWheel then
        t2._wheelShown = true; ns.ShowByeWheel(t2)
    end
    ns.CheckTurnNotify(t2)
    return true
end

-- kalt når en turneringskamp er avgjort (fra Finish og DRRS)
function ns.TournamentOnResult(r)
    local t = ns.db and ns.db.tournaments and ns.db.tournaments[r.tid]
    if not t or t.finished then return false end
    if r.kind ~= "tmatch" then return false end
    local mi = r.mi or 0
    if mi ~= #t.winners + 1 then return false end
    t.winners[mi] = ns.Short(r.winner)
    t.rev = (t.rev or 1) + 1
    local b = ns.ComputeBracket(t.part, t.winners)
    if b.finished then
        t.finished = true; t.champion = b.champion
        t._announced = true
        ns.OnTournamentFinished(t)
    end
    if ns.IsMe(r.a) or ns.IsMe(r.b) then
        ns.Send("TNEW", ns.EncodeTournament(t), "GUILD")
    end
    ns.CheckTurnNotify(t)
    return true
end

function ns.OnTournamentFinished(t, fromSync)
    t.finishedAt = t.finishedAt or GetServerTime()
    DPrint("|cffffd100Turnering ferdig!|r Vinner: " .. ns.Short(t.champion or "?")
        .. ((t.stake or 0) > 0 and (" – potten er " .. ns.FormatMoney((t.stake or 0) * math.max(0, #t.part)) .. "!") or "") .. "")
    ns.Sound("RAID_WARNING")
    if ns.Anim and ns.Anim.Banner then
        ns.Anim.Banner("TURNERINGSVINNER!", ns.Short(t.champion or "?") .. " tok potten")
    end
    -- pott-oppgjør: hver deltaker (unntatt vinner) skylder innsats til vinner.
    -- Bare vinneren oppretter og kringkaster (deterministisk id → ingen dubletter).
    if (t.stake or 0) > 0 and ns.IsMe(t.champion) then
        local db = DR()
        local batch = {}
        for _, p in ipairs(t.part) do
            if ns.Key(p) ~= ns.Key(t.champion) then
                local r = { id = H(t.tid .. "pot" .. ns.Key(p)), a = t.champion, b = p,
                            winner = t.champion, loser = p, amount = t.stake, rolls = 0,
                            t = GetServerTime(), season = db and db.season or 0, paid = false,
                            kind = "tpot", tid = t.tid, mi = 0 }
                ns.StoreResult(r)
                batch[#batch + 1] = ns.EncodeResult(r)
                if #batch >= 6 then ns.Send("DRRS", table.concat(batch, "/"), "GUILD"); batch = {} end
            end
        end
        if #batch > 0 then ns.Send("DRRS", table.concat(batch, "/"), "GUILD") end
        -- (Ingen annonsering i guild chat.)
    end
    ns.DRRefresh()
end

-- Hent den aktive turneringen for et event (hvis noen)
function ns.EventTournament(e)
    if not e or not e.tid or not ns.db then return nil end
    return ns.db.tournaments[e.tid]
end

-- Id-en til duellen for den gjeldende turneringskampen (samme hos alle).
function ns.CurrentTournamentDuelId(tid)
    local t = ns.db and ns.db.tournaments and ns.db.tournaments[tid]
    if not t or t.finished then return nil end
    local b = ns.ComputeBracket(t.part, t.winners)
    if not b.current then return nil end
    return H(tid .. "#" .. b.current)
end

-- Spill den gjeldende kampen i en turnering. BEGGE spillerne kan starte –
-- den som trykker først blir utfordrer, den andre godtar automatisk.
-- Deterministisk id (tid+kampnr) gjør at samtidige trykk ikke lager to dueller.
-- Send turneringskamp-invitasjonen (bare den kanoniske starteren «a» gjør dette) og
-- gjenta et par ganger – på WoW Forever kan enkeltmeldinger droppes, og da skal
-- oppkoblingen likevel gå i orden uten at noen må synke/relogge.
local function SendTournamentInvite(d)
    if not d or d.state ~= "invite" then return end
    ns.Send("DRCH", table.concat({ d.id, clean(d.a), clean(d.b), 0, d.start or 1000,
            clean(d.tid), d.mi }, ";"), "GUILD")
    d._invTries = (d._invTries or 0) + 1
    if d._invTries < 5 then
        C_Timer.After(3, function()
            if ns.duels[d.id] == d and d.state == "invite" then SendTournamentInvite(d) end
        end)
    end
end

-- Hvem er den «kanoniske» starteren (a) i en kamp mellom to navn: lavest nøkkel.
local function CanonAB(n1, n2)
    if ns.Key(n1) <= ns.Key(n2) then return n1, n2 else return n2, n1 end
end

function ns.PlayTournamentMatch(tid)
    local t = ns.db and ns.db.tournaments[tid]
    if not t or t.finished then return end
    local bk = ns.ComputeBracket(t.part, t.winners)
    if bk.finished or not bk.current then return end
    local m = bk.matches[bk.current]
    local me = ns.PlayerName()
    if not (ns.Key(m.a) == ns.Key(me) or ns.Key(m.b) == ns.Key(me)) then
        DPrint("Det er ikke din kamp akkurat nå.") return
    end
    local id = H(tid .. "#" .. bk.current)
    -- Deterministiske roller: begge klienter regner samme a/b, så kampen blir den
    -- samme uansett hvem som går inn først. a kaster først.
    local aName, bName = CanonAB(m.a, m.b)
    local iAmA = ns.Key(me) == ns.Key(aName)

    local existing = ns.duels[id]
    if existing and existing.state ~= "cancelled" and existing.state ~= "declined" then
        -- kampen finnes allerede: gå (tilbake) inn, og godta hvis jeg er motstanderen
        if existing.state == "invite" and ns.Key(existing.b) == ns.Key(me) then ns.Accept(id) end
        if ns.OpenArenaOnTournament then ns.OpenArenaOnTournament(tid) end
        ns.DRRefresh()
        return
    end
    local busy = ns.MyActiveDuel()
    if busy and busy.id ~= id then DPrint("Du er allerede i en duell.") return end

    if iAmA then
        local d = { id = id, a = aName, b = bName, amount = 0, start = t.start or 1000, max = t.start or 1000,
                    turn = aName, state = "invite", rolls = {}, created = GetTime(), lastAct = GetTime(),
                    tid = tid, mi = bk.current }
        ns.duels[id] = d
        SendTournamentInvite(d)
        DPrint("Turneringskamp mot " .. ns.Short(bName) .. " – kobler opp …")
        ns.Sound("IG_PLAYER_INVITE")
    else
        -- Jeg er motstanderen (b): be den kanoniske starteren starte kampen. Gjentas
        -- et par ganger i tilfelle meldingen droppes. Når invitasjonen kommer, godtar
        -- jeg automatisk (se DRCH-håndtereren).
        local tries = 0
        local function poke()
            if ns.duels[id] then return end          -- invitasjonen har kommet
            ns.Send("DRTR", table.concat({ id, clean(tid), bk.current }, ";"), "GUILD")
            tries = tries + 1
            if tries < 5 then C_Timer.After(3, poke) end
        end
        poke()
        DPrint("Turneringskamp mot " .. ns.Short(aName) .. " – kobler opp …")
    end
    if ns.OpenArenaOnTournament then ns.OpenArenaOnTournament(tid) end
    ns.DRRefresh()
    -- Ingen auto-timeout på turneringskamper.
end

-- «b» ber «a» (kanonisk starter) om å starte turneringskampen – robust mot at
-- den som skulle invitere ikke har gått inn ennå, eller at en melding ble droppet.
Handlers.DRTR = function(from, data)
    local x = split(data, ";")
    local id, tid, mi = x[1], x[2], tonumber(x[3])
    if not (id and tid and mi) then return end
    local t = ns.db and ns.db.tournaments[tid]
    if not t or t.finished then return end
    local bk = ns.ComputeBracket(t.part, t.winners)
    if bk.current ~= mi then return end
    local m = bk.matches[bk.current]
    if not m then return end
    local aName = select(1, CanonAB(m.a, m.b))
    if ns.Key(ns.PlayerName()) ~= ns.Key(aName) then return end   -- bare den kanoniske starteren svarer
    local d = ns.duels[id]
    if d and d.state == "active" then
        -- allerede i gang: bekreft på nytt så motstanderen henger med
        ns.Send("DROK", table.concat({ id, clean(d.a), clean(d.b), 0, d.start or 1000 }, ";"), "GUILD")
        return
    end
    if d and d.state == "done" then return end
    if d and d.state == "invite" and ns.IsMe(d.a) then
        -- invitasjonen finnes alt: send den på nytt med en gang
        ns.Send("DRCH", table.concat({ id, clean(d.a), clean(d.b), 0, d.start or 1000, clean(tid), mi }, ";"), "GUILD")
        return
    end
    ns.PlayTournamentMatch(tid)   -- oppretter/sender invitasjonen (a=meg)
end

---------------------------------------------------------------------------
-- Oppdater begge vinduene (arena + hovedvinduets events-fane)
---------------------------------------------------------------------------
function ns.DRRefresh()
    if ns.Arena and ns.Arena.Update then ns.Arena:Update() end
    if ns.UI and ns.UI.Update then ns.UI:Update() end
end

---------------------------------------------------------------------------
-- Slash /dr
---------------------------------------------------------------------------
local DAYS = { "søndag", "mandag", "tirsdag", "onsdag", "torsdag", "fredag", "lørdag" }
ns.DAYS = DAYS

function ns.HandleDeathRollSlash(msg)
    msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local lower = msg:lower()
    if msg == "" then if ns.Arena then ns.Arena:Toggle() end return end
    local sc = lower:match("^skala%s+([%d%.,]+)$") or lower:match("^scale%s+([%d%.,]+)$")
    if sc then
        local n = tonumber((sc:gsub(",", ".")))
        if not n or n < 0.6 or n > 1.4 then DPrint("Bruk: /dr skala 0.9   (fra 0.6 til 1.4)") return end
        ns.global.arenaScale = n
        if ns.Arena and ns.Arena.frame then ns.Arena.frame:SetScale(n) end
        DPrint("Rulle-vinduets størrelse satt til " .. n .. ".")
        return
    end
    if not ns.db then DPrint("Du må være i en guild.") return end
    if lower == "roll" then ns.DoRoll() return end
    if lower == "gi opp" or lower == "avbryt" then ns.Forfeit() return end
    if lower == "nysesong" then
        if not ns.IsGM(ns.PlayerName()) then DPrint("Bare guildmaster kan nullstille sesongtabellen.") return end
        ns.ResetSeason()
        return
    end
    if lower == "nyuke" then
        if not ns.IsGM(ns.PlayerName()) then DPrint("Bare guildmaster kan nullstille ukestabellen.") return end
        ns.ResetWeek()
        return
    end
    local day = lower:match("^dag%s+(%S+)$")
    if day then
        local db = DR()
        if not ns.IsGM(ns.PlayerName()) then DPrint("Bare guildmaster kan velge event-dag.") return end
        for i, name in ipairs(DAYS) do
            if name == day then
                db.eventDay = i
                ns.SendDRConfig()
                DPrint("Event-dag satt til " .. name .. ".")
                ns.DRRefresh()
                return
            end
        end
        DPrint("Ukjent dag. Skriv f.eks. /dr dag onsdag")
        return
    end
    local vday, vhour = lower:match("^vedlikehold%s+(%S+)%s*(%d*)$")
    if vday then
        local db = DR()
        if not ns.IsGM(ns.PlayerName()) then DPrint("Bare guildmaster kan velge vedlikeholdsdag.") return end
        for i, name in ipairs(DAYS) do
            if name == vday then
                db.resetWday = i
                if vhour and vhour ~= "" then db.resetHour = math.max(0, math.min(23, tonumber(vhour) or 4)) end
                ns.SendDRConfig()
                DPrint("Vedlikeholdsdag satt til " .. name .. " kl " .. (db.resetHour or 4) .. ":00. Ukestabellen nullstilles automatisk da.")
                ns.DRRefresh()
                return
            end
        end
        DPrint("Ukjent dag. Skriv f.eks. /dr vedlikehold onsdag 4")
        return
    end
    local name, gold, start = msg:match("^(.-)%s+(%d+)%s*(%d*)$")
    if name and name ~= "" then
        -- slash: tallet er hele gull (f.eks. /dr Thrall 10 = 10 gull) → copper
        ns.Challenge(name, (tonumber(gold) or 0) * 10000, start ~= "" and start or nil)
        return
    end
    if ns.Arena then ns.Arena:Toggle() end
end

---------------------------------------------------------------------------
-- Egen hendelsesramme (systemmeldinger, trade). Addon-meldinger kommer via
-- GuildKompass sin CHAT_MSG_ADDON → ns.Handlers.
---------------------------------------------------------------------------
local ef = CreateFrame("Frame")
for _, e in ipairs({ "CHAT_MSG_SYSTEM", "TRADE_SHOW", "TRADE_MONEY_CHANGED",
                     "TRADE_ACCEPT_UPDATE", "TRADE_PLAYER_ITEM_CHANGED", "UI_INFO_MESSAGE" }) do
    pcall(ef.RegisterEvent, ef, e)
end
ef:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_SYSTEM" then OnSystemMessage((...)) else OnTrade(event, ...) end
end)

-- Kjøres fra Core.lua ved innlogging (etter at guilden er lastet)
-- Påminnelse: banner ~10 min før et event med tidspunkt, og «starter nå»
ns.evReminded = ns.evReminded or {}
function ns.CheckEventReminders()
    if not ns.db or not ns.global.eventWarnings or not ns.Anim then return end
    local now = GetServerTime()
    for id, e in pairs(ns.db.events or {}) do
        if not e.cancelled and e.when and e.when > 0 then
            local r = ns.evReminded[id] or {}
            local typ = (e.mode == "tournament") and "Death Roll-turnering" or "Death Roll"
            local name = (e.title and e.title ~= "") and e.title or typ
            if not r.pre and now >= e.when - 600 and now < e.when - 30 then
                r.pre = true
                local mins = math.max(1, math.floor((e.when - now) / 60 + 0.5))
                ns.Anim.Banner(typ:upper() .. " OM " .. mins .. " MIN!", "Meld deg på / gjør deg klar  ·  " .. name)
                ns.Sound("RAID_WARNING")
            end
            if not r.now and now >= e.when - 30 and now < e.when + 300 then
                r.now = true
                ns.Anim.Banner(typ:upper() .. " STARTER NÅ!", name)
                ns.Sound("RAID_WARNING")
            end
            ns.evReminded[id] = r
        end
    end
    if ns.CheckRaidReminders then ns.CheckRaidReminders() end
end

function ns.DR_OnLogin()
    ns.EnsureDR()
    if ns.EnsureRaids then ns.EnsureRaids() end
    ns.DR_SendHello()
    if ns.Raid_SendHello then ns.Raid_SendHello() end
    local db = DR()
    if db and date("*t").wday == db.eventDay and ns.Anim then
        ns.Anim.Banner("DEATH ROLL " .. DAYS[db.eventDay]:upper() .. "!", "Åpne guild-vinduet → Events")
    end
    if not ns.evTicker then ns.evTicker = C_Timer.NewTicker(30, ns.CheckEventReminders) end
end

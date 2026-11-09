local ADDON, ns = ...

-- Gullbidrag hentes fra guild bankens egen MONEY LOG.
--  * Hver gang noen med addonen åpner guild banken, leses loggen.
--  * Hvert innskudd lagres som en "observasjon": karakter, beløp og et
--    tidsvindu (loggen sier bare "for 3 timer siden" = mellom 3 og 4 timer
--    siden). Observasjonene deles uendret med hele guilden.
--  * Antall faktiske innskudd regnes ut fra alle observasjonene med
--    maksimal matching: to observasjoner fra ulike lesere er samme innskudd
--    hvis karakter og beløp er like og tidsvinduene overlapper. Fordi alle
--    har de samme observasjonene og regner likt, får alle samme svar.
--  * Karakteren kobles til Battle.net-kontoen sin, så summene vises per
--    konto. Innskudd fra folk uten addon telles også (med karakternavn).
--
-- Offiserer kan i tillegg føre/korrigere manuelt med /gk gull.

-- Money log er "fanen etter siste bankfane". Antall faner varierer mellom
-- spillversjoner, og MAX_GUILDBANK_TABS finnes først når bank-UI-et er lastet,
-- så det må leses idet vi spør – ikke når addonen lastes.
local function MoneyLogTabs()
    local max = _G.MAX_GUILDBANK_TABS
    if max then return { max + 1 } end
    return { 7, 9 }   -- 6 eller 8 faner
end
-- Typer i money log. Bare "deposit" er gullbidrag; resten vises i loggen
-- og brukes til å stemme av mot bankbeholdningen.
ns.LOG_KINDS = {
    deposit        = { label = "Innskudd",          sign =  1 },
    withdraw       = { label = "Uttak",             sign = -1 },
    repair         = { label = "Reparasjon",        sign = -1 },
    buyTab         = { label = "Kjøpt bankfane",    sign = -1 },
    withdrawForTab = { label = "Uttak til bankfane", sign = -1 },
    depositSummary = { label = "Innskudd (sum)",    sign =  1 },
}
local SLACK = 120   -- sekunder slingringsmonn når tidsvinduer sammenlignes

local function SafeBankMoney()
    if not GetGuildBankMoney then return 0 end
    local ok, m = pcall(GetGuildBankMoney)
    return (ok and m) or 0
end

function ns.TributesChanged()
    ns.tribCache = nil
    ns.RefreshUI()
end

---------------------------------------------------------------------------
-- Manuell føring (offiser)
---------------------------------------------------------------------------
function ns.RecordTribute(from, amount, via)
    if not ns.db or not amount or amount == 0 then return end
    local me = ns.PlayerName()
    ns.tribSeq = (ns.tribSeq or 0) + 1
    local now = GetServerTime()
    local e = {
        id = "M" .. me .. "#" .. now .. "#" .. ns.tribSeq,
        from = from, amount = amount, time = now, lo = now, hi = now,
        via = via or "manuell", banker = me,
    }
    ns.db.tributes[e.id] = e
    ns.Send("TRIBS", ns.EncodeTribute(e), "GUILD")
    ns.TributesChanged()
    return e
end

-- Godtar vi en oppføring fra en annen spiller?
--  * "log":   lest fra bankens logg av et guildmedlem
--  * "bank":  eldre selvrapportering (1.5–1.7) – bare fra personen selv
--  * ellers:  manuelt – bare fra offiser
function ns.TrustTribute(e)
    if not e then return false end
    -- Logg-oppføringer kommer bare via guildkanalen (eller synk fra guildmedlemmer),
    -- og er en kopi av bankens egen logg – godta dem alltid.
    if e.via == "log" then return true end
    if e.via == "bank" then return e.banker == e.from end
    return ns.IsOfficer(e.banker)
end

function ns.MergeTribute(e)
    if e.from then e.from = ns.Short(e.from) end
    if e.banker then e.banker = ns.Short(e.banker) end
    if ns.db.tributes[e.id] or not ns.TrustTribute(e) then return false end
    ns.db.tributes[e.id] = e
    ns.tribCache = nil
    return true
end

---------------------------------------------------------------------------
-- Matching
---------------------------------------------------------------------------
local function Overlap(a, b)
    return a.lo <= b.hi + SLACK and b.lo <= a.hi + SLACK
end

-- Maksimal bipartitt matching (Kuhn). Returnerer matchL[i] = j eller nil.
local function MaxMatching(L, R)
    local adj = {}
    for i = 1, #L do
        local a = {}
        for j = 1, #R do
            if Overlap(L[i], R[j]) then a[#a + 1] = j end
        end
        adj[i] = a
    end
    local matchR = {}
    local function Try(i, seen)
        for _, j in ipairs(adj[i]) do
            if not seen[j] then
                seen[j] = true
                if not matchR[j] or Try(matchR[j], seen) then
                    matchR[j] = i
                    return true
                end
            end
        end
        return false
    end
    for i = 1, #L do Try(i, {}) end
    local matchL = {}
    for j, i in pairs(matchR) do matchL[i] = j end
    return matchL
end

local function Bounds(e)
    -- eldre oppføringer uten vindu
    local lo, hi = e.lo, e.hi
    if not lo or not hi or lo == 0 then
        local w = (e.via == "bank") and 600 or 0
        lo, hi = (e.time or 0) - w, (e.time or 0) + w
    end
    return lo, hi
end

-- Nøkkel for "samme type bevegelse": type + navn (uten realm, små bokstaver) + beløp.
-- Navnet normaliseres så små forskjeller i skrivemåte mellom spillere ikke
-- gjør at samme innskudd blir sett på som to forskjellige.
local function NKey(kind, from, amount)
    return (kind or "deposit") .. "|" .. ns.Short(from or "?"):lower() .. "|" .. (amount or 0)
end
ns.NKey = NKey

-- Alle faktiske bevegelser: { from, amount, time, via, kind, lo, hi }
--
-- To kilder:
--  1. FASIT: den nyeste lesingen av bankens money log (ns.db.snap), delt med
--     hele guilden. Innenfor tidsrommet loggen dekker, er den eksakt.
--  2. Eldre lesinger (observasjoner), for innskudd som har rullet ut av
--     loggen. Disse slås sammen med matching.
function ns.TributeEvents()
    if ns.tribCache then return ns.tribCache end
    local out = {}
    if not ns.db then return out end
    local clusters = {}
    for _, e in pairs(ns.db.tributes) do
        if e.via == "bank" then
            -- Gamle selvrapporterte innskudd (1.5–1.7) telles ikke lenger:
            -- de samme innskuddene står i bankens logg, og to kilder med
            -- ulik tidsangivelse ga dobbeltelling.
        elseif e.via == "log" then
            local key = NKey(e.kind, e.from, e.amount)
            local reader = e.banker or "?"
            local lo, hi = Bounds(e)
            clusters[key] = clusters[key] or {}
            clusters[key][reader] = clusters[key][reader] or {}
            table.insert(clusters[key][reader], { lo = lo, hi = hi, id = e.id, from = e.from, amount = e.amount,
                                                  kind = e.kind or "deposit" })
        else
            out[#out + 1] = { from = e.from, amount = e.amount, time = e.time, via = e.via, banker = e.banker,
                              kind = "deposit" }
        end
    end
    for _, byReader in pairs(clusters) do
        local readers = {}
        for r in pairs(byReader) do readers[#readers + 1] = r end
        table.sort(readers)   -- fast rekkefølge = samme svar hos alle
        local C = {}
        for _, r in ipairs(readers) do
            local R = byReader[r]
            table.sort(R, function(a, b) if a.lo ~= b.lo then return a.lo < b.lo end return a.id < b.id end)
            local m = MaxMatching(R, C)
            for i, o in ipairs(R) do
                if not m[i] then C[#C + 1] = { lo = o.lo, hi = o.hi, from = o.from, amount = o.amount, kind = o.kind } end
            end
        end
        for _, c in ipairs(C) do
            out[#out + 1] = { from = c.from, amount = c.amount, time = math.floor((c.lo + c.hi) / 2), via = "log",
                              approx = (c.hi - c.lo) > 60, kind = c.kind, lo = c.lo, hi = c.hi }
        end
    end

    -- Fasit fra siste logglesing
    local snap = ns.db.snap
    if snap and snap.entries and #snap.entries > 0 then
        -- Den eldste linjen i loggen: alt som garantert er nyere, MÅ stå i loggen
        local oldest
        local snapBy = {}
        for _, s in ipairs(snap.entries) do
            if not oldest or s.lo < oldest.lo then oldest = s end
            local k = NKey(s.kind, s.from, s.amount)
            snapBy[k] = snapBy[k] or {}
            table.insert(snapBy[k], s)
        end
        local cutLo, cutHi = oldest.lo, oldest.hi
        local result, logBy = {}, {}
        for _, e in ipairs(out) do
            if e.via == "log" then
                local k = NKey(e.kind, e.from, e.amount)
                logBy[k] = logBy[k] or {}
                table.insert(logBy[k], e)
            else
                result[#result + 1] = e   -- manuelle føringer beholdes alltid
            end
        end
        local keys = {}
        for k in pairs(snapBy) do keys[k] = true end
        for k in pairs(logBy) do keys[k] = true end
        for k in pairs(keys) do
            local S, F = snapBy[k] or {}, logBy[k] or {}
            -- Garantert eldre enn loggen: røres ikke
            local old, rest = {}, {}
            for _, f in ipairs(F) do
                if f.hi < cutLo then old[#old + 1] = f else rest[#rest + 1] = f end
            end
            local m = MaxMatching(rest, S)
            local matched, dup = 0, false
            for i, f in ipairs(rest) do
                if m[i] then matched = matched + 1
                elseif f.lo >= cutHi then dup = true end   -- nyere enn loggen, men ikke i den
            end
            if matched == #S and not dup then
                -- Enig med bankens logg: behold som det er
                for _, f in ipairs(F) do result[#result + 1] = f end
            else
                -- Uenig: bankens logg er fasit for sitt tidsrom
                for _, s in ipairs(S) do
                    result[#result + 1] = { from = s.from, amount = s.amount, kind = s.kind, via = "log",
                                            time = math.floor((s.lo + s.hi) / 2), approx = true, lo = s.lo, hi = s.hi }
                end
                for _, f in ipairs(old) do result[#result + 1] = f end
                for i, f in ipairs(rest) do
                    if not m[i] and f.lo < cutHi then result[#result + 1] = f end
                end
            end
        end
        out = result
    end

    ns.tribCache = out
    return out
end

-- Ny fasit (fra meg eller en annen). Nyeste lesing vinner.
function ns.SetSnapshot(snap, fromNetwork)
    if not ns.db or not snap or not snap.entries then return false end
    if ns.db.snap and (ns.db.snap.t or 0) >= (snap.t or 0) then return false end
    ns.db.snap = snap
    ns.tribCache = nil
    return true
end

function ns.EncodeSnapshot(snap)
    local parts = {}
    for _, s in ipairs(snap.entries) do
        parts[#parts + 1] = table.concat({ s.kind, (s.from:gsub("[;,:%^/]", "")), s.amount, s.lo, s.hi }, ",")
    end
    return snap.t .. ";" .. (snap.by or ""):gsub("[;,:%^/]", "") .. ";" .. table.concat(parts, "/")
end

function ns.DecodeSnapshot(data)
    local t, by, rest = data:match("^(%d+);([^;]*);(.*)$")
    t = tonumber(t)
    if not t then return nil end
    local snap = { t = t, by = by, entries = {} }
    for item in rest:gmatch("[^/]+") do
        local kind, from, amount, lo, hi = item:match("^([^,]*),([^,]*),(%d+),(%-?%d+),(%-?%d+)$")
        if kind and ns.LOG_KINDS[kind] then
            table.insert(snap.entries, { kind = kind, from = from, amount = tonumber(amount),
                                         lo = tonumber(lo), hi = tonumber(hi) })
        end
    end
    return snap
end

---------------------------------------------------------------------------
-- Lesing av money log
---------------------------------------------------------------------------
local function QueryLog()
    if not QueryGuildBankLog then return end
    local now = GetTime()
    if ns.lastLogQuery and now - ns.lastLogQuery < 3 then return end
    ns.lastLogQuery = now
    for _, tab in ipairs(MoneyLogTabs()) do pcall(QueryGuildBankLog, tab) end
end

function ns.ReadMoneyLog()
    if not ns.db or not GetNumGuildBankMoneyTransactions or not GetGuildBankMoneyTransaction then return end
    local n = GetNumGuildBankMoneyTransactions() or 0
    if n == 0 then return end
    local now = GetServerTime()
    local me = ns.PlayerName()

    -- 1. Alle bevegelser i loggen akkurat nå, gruppert på type + karakter + beløp
    local batch, snapEntries = {}, {}
    for i = 1, n do
        local kind, name, amount, years, months, days, hours = GetGuildBankMoneyTransaction(i)
        if kind and ns.LOG_KINDS[kind] and amount and amount > 0 then
            name = name or "?"
            years, months, days, hours = years or 0, months or 0, days or 0, hours or 0
            local h = (years * 365 + months * 30 + days) * 24 + hours
            -- Tål både "hele timer siden" og avrundet tid fra spillet
            local lo, hi = now - (h + 1) * 3600 - 300, math.min(now, now - h * 3600 + 1800)
            if months > 0 or years > 0 then lo, hi = lo - 3 * 86400, hi + 3 * 86400 end
            local from = ns.FullName(name) or name
            local key = NKey(kind, from, amount)
            batch[key] = batch[key] or {}
            table.insert(batch[key], { from = from, amount = amount, lo = lo, hi = hi, kind = kind })
            snapEntries[#snapEntries + 1] = { kind = kind, from = from, amount = amount, lo = lo, hi = hi }
        end
    end

    -- Hele loggen akkurat nå blir ny fasit for alle
    if #snapEntries > 0 then
        local snap = { t = now, by = me, entries = snapEntries }
        if ns.SetSnapshot(snap) then
            ns.Send("SNAP", ns.EncodeSnapshot(snap), "GUILD")
            ns.TributesChanged()
        end
    end

    -- 2. Match mot det JEG har lest før (samme leser), lagre resten som nye
    local added = {}
    for key, items in pairs(batch) do
        local mine = {}
        for _, e in pairs(ns.db.tributes) do
            if e.via == "log" and e.banker == me and NKey(e.kind, e.from, e.amount) == key then
                local lo, hi = Bounds(e)
                mine[#mine + 1] = { lo = lo, hi = hi }
            end
        end
        local m = MaxMatching(items, mine)
        for i, b in ipairs(items) do
            if not m[i] then
                ns.tribSeq = (ns.tribSeq or 0) + 1
                local e = {
                    id = "L" .. me .. "#" .. b.lo .. "#" .. ns.tribSeq,
                    from = b.from, amount = b.amount, lo = b.lo, hi = b.hi,
                    time = math.floor((b.lo + b.hi) / 2), via = "log", banker = me, kind = b.kind,
                }
                ns.db.tributes[e.id] = e
                added[#added + 1] = e
            end
        end
    end

    if #added > 0 then
        local enc = {}
        for i, e in ipairs(added) do
            enc[#enc + 1] = ns.EncodeTribute(e)
            if #enc >= 8 or i == #added then
                ns.Send("TRIBS", table.concat(enc, "/"), "GUILD")
                enc = {}
            end
        end
        ns.TributesChanged()
    end
    return added
end

---------------------------------------------------------------------------
-- Bankbeholdning og hendelser
---------------------------------------------------------------------------
function ns.SaveBankBalance()
    if not ns.db then return end
    local m = SafeBankMoney()
    if m <= 0 and not ns.atBank then return end
    ns.db.bank = { money = m, time = GetServerTime(), by = ns.PlayerName() }
    ns.Send("BANK", m .. ";" .. ns.db.bank.time, "GUILD")
    ns.RefreshUI()
end

-- Kalles uansett hvordan vi oppdager at banken er åpnet (flere veier, se under).
-- Leser loggen to ganger for sikkerhets skyld; spillet trenger litt tid.
local lastOpen = 0
local function OnBankOpened()
    ns.atBank = true
    local now = GetTime()
    if now - lastOpen < 15 then return end
    lastOpen = now
    C_Timer.After(1, function()
        ns.SaveBankBalance()
        ns.lastLogQuery = nil
        QueryLog()
    end)
    C_Timer.After(4, function()
        ns.lastLogQuery = nil
        QueryLog()
    end)
end
ns.OnBankOpened = OnBankOpened

-- Sikreste måte: hekt oss på selve guild bank-vinduet når det lastes
function ns.HookGuildBankFrame()
    -- Vi hooker IKKE GuildBankFrame med HookScript: på denne klienten tainter det
    -- bank-UI-et, så Blizzards egne bank-funksjoner (PurchaseBankTab o.l.) blokkeres.
    -- Åpne/lukke fanges i stedet via events (GUILDBANKFRAME_OPENED/CLOSED,
    -- PLAYER_INTERACTION_MANAGER_*, GUILDBANK_UPDATE_*), som allerede er registrert.
    if ns.bankFrameHooked then return end
    ns.bankFrameHooked = true
    local frame = _G.GuildBankFrame
    if frame and frame:IsShown() then OnBankOpened() end
end

local pendingThanks
function ns.OnBankEvent(event, ...)
    if event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" or event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        local kind = ...
        local gb = Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.GuildBanker
        if not gb or kind ~= gb then return end
        if event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then OnBankOpened() else ns.atBank = false end
    elseif event == "GUILDBANKFRAME_OPENED" then
        OnBankOpened()
    elseif event == "GUILDBANKFRAME_CLOSED" then
        ns.atBank = false
    elseif event == "GUILDBANKBAGSLOTS_CHANGED" or event == "GUILDBANK_UPDATE_TABS" then
        -- Kommer når bankinnholdet lastes, dvs. når banken åpnes
        OnBankOpened()
    elseif event == "GUILDBANK_UPDATE_MONEY" then
        ns.SaveBankBalance()
        OnBankOpened()
        C_Timer.After(2, QueryLog)
    elseif event == "GUILDBANKLOG_UPDATE" then
        local added = ns.ReadMoneyLog() or {}
        ns.lastLogRead = GetServerTime()
        ns.SaveBankBalance()   -- forteller alle at loggen nettopp ble lest (og av hvem)
        if pendingThanks then
            for _, e in ipairs(added) do
                if ns.IsMe(e.from) and e.amount == pendingThanks and (e.kind or "deposit") == "deposit" then
                    ns.Print(string.format("Takk! %s lagt i guild banken er registrert.", ns.FormatMoney(e.amount)))
                    pendingThanks = nil
                    break
                end
            end
        end
    end
end

function ns.HookGuildBank()
    if ns.bankHooked then return end
    if DepositGuildBankMoney then
        -- Etter et innskudd: les loggen så det registreres med en gang
        hooksecurefunc("DepositGuildBankMoney", function(amount)
            pendingThanks = tonumber(amount)
            C_Timer.After(2, function() ns.lastLogQuery = nil; QueryLog() end)
        end)
        ns.bankHooked = true
    end
end

---------------------------------------------------------------------------
-- Visning: per Battle.net-konto
---------------------------------------------------------------------------
-- Hvilken konto en karakter hører til: nøkkel, visningsnavn.
-- Ukjent konto (karakter uten addon) = karakternavnet.
function ns.CharAccount(from)
    if ns.IsMe(from) then
        local k, n = ns.AccountInfo()
        return k, (n ~= "" and n or ns.Short(from))
    end
    local rec = ns.db.members[from]
    if not (rec and rec.bnetKey) then
        -- Samme karakter kan være skrevet med ulik realm-endelse: søk på navnet alene
        local short = ns.Short(from or "?"):lower()
        if ns.IsMe(from) or short == ns.Short(ns.PlayerName()):lower() then
            local k, n = ns.AccountInfo()
            return k, (n ~= "" and n or ns.Short(from))
        end
        for name, r in pairs(ns.db.members) do
            if r.bnetKey and ns.Short(name):lower() == short then rec = r break end
        end
    end
    if rec and rec.bnetKey then
        return rec.bnetKey, (rec.bnetName and rec.bnetName ~= "") and rec.bnetName or "Ukjent konto"
    end
    return "char:" .. ns.Short(from or "?"):lower(), ns.Short(from)
end

-- Summer per Battle.net-konto
function ns.TributeTotals()
    local totals = {}
    if not ns.db then return totals end
    local weekStart = ns.WeekStart()
    for _, e in ipairs(ns.TributeEvents()) do
      if (e.kind or "deposit") == "deposit" then
        local key, name = ns.CharAccount(e.from)
        local t = totals[key]
        if not t then
            t = { key = key, name = name, total = 0, week = 0, count = 0, last = 0 }
            totals[key] = t
        end
        t.total = t.total + e.amount
        if e.amount > 0 then t.count = t.count + 1 end
        if e.time >= weekStart then t.week = t.week + e.amount end
        if e.time > t.last then t.last = e.time end
      end
    end
    return totals
end

-- Sum inn/ut (fra et tidspunkt) for avstemming
function ns.BankFlow(since)
    local inn, ut = 0, 0
    for _, e in ipairs(ns.TributeEvents()) do
        if not since or e.time >= since then
            local k = ns.LOG_KINDS[e.kind or "deposit"]
            if k and k.sign < 0 then ut = ut + e.amount else inn = inn + e.amount end
        end
    end
    return inn, ut
end

-- /gk logg: vis hva bankens money log inneholder akkurat nå, og sammenlign
-- med det addonen har registrert. Må stå ved guild banken.
function ns.DumpMoneyLog()
    if not ns.atBank or not GetNumGuildBankMoneyTransactions then
        ns.Print("Åpne guild banken først, og skriv /gk logg igjen.")
        ns.lastLogQuery = nil
        QueryLog()
        return
    end
    local n = GetNumGuildBankMoneyTransactions() or 0
    ns.Print(string.format("Bankens money log (%d linjer) – beholdning nå: %s", n, ns.FormatMoney(SafeBankMoney())))
    local logIn, logOut = 0, 0
    for i = 1, n do
        local kind, name, amount, years, months, days, hours = GetGuildBankMoneyTransaction(i)
        local k = ns.LOG_KINDS[kind or ""]
        local sign = (k and k.sign) or 0
        if sign > 0 then logIn = logIn + (amount or 0) elseif sign < 0 then logOut = logOut + (amount or 0) end
        local ago = (days or 0) > 0 and ((days or 0) .. "d " .. (hours or 0) .. "t") or ((hours or 0) .. "t")
        DEFAULT_CHAT_FRAME:AddMessage(string.format("  %s  %s  %s  (%s siden)",
            (k and k.label) or tostring(kind), tostring(name), ns.FormatMoney(amount or 0), ago))
    end
    local inn, ut = ns.BankFlow(nil)
    ns.Print(string.format("I loggen nå: inn %s, ut %s.  Addonen har registrert totalt: inn %s, ut %s.",
        ns.FormatMoney(logIn), ns.FormatMoney(logOut), ns.FormatMoney(inn), ns.FormatMoney(ut)))
    local legacy, manual = 0, 0
    for _, e in pairs(ns.db.tributes) do
        if e.via == "bank" then legacy = legacy + 1 elseif e.via ~= "log" then manual = manual + 1 end
    end
    if manual > 0 then
        ns.Print(string.format("Merk: %d manuelle oppføringer (/gk gull) er også med i summen.", manual))
    end
    if legacy > 0 then
        ns.Print(string.format("(%d gamle selvrapporterte oppføringer fra versjon 1.5–1.7 ignoreres.)", legacy))
    end
end

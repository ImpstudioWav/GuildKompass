local ADDON, ns = ...

-- Protokoll:  TYPE^ID^DEL^ANTALL^EPOKE^data
-- Lange meldinger deles opp automatisk. Lister skilles med "/".
local CHUNK = 210
local SendAddon = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage

---------------------------------------------------------------------------
-- Koding av data
---------------------------------------------------------------------------
local function clean(s)
    return (tostring(s or ""):gsub("[;,:%^/]", ""))
end

local function split(s, sep)
    local out, start = {}, 1
    while true do
        local i = string.find(s, sep, start, true)
        if not i then out[#out + 1] = s:sub(start); break end
        out[#out + 1] = s:sub(start, i - 1)
        start = i + 1
    end
    return out
end
ns.Split = split

function ns.EncodeRecord(r)
    local profs = {}
    for _, p in ipairs(r.profs or {}) do
        profs[#profs + 1] = clean(p[1]) .. ":" .. (p[2] or 0) .. ":" .. (p[3] or 0)
    end
    local raids = {}
    for key, l in pairs(r.raids or {}) do
        raids[#raids + 1] = clean(key) .. ":" .. (l.resetAt or 0) .. ":" .. (l.done or 0) .. ":" .. (l.total or 0)
    end
    table.sort(raids)
    local spec = {}
    for _, t in ipairs(r.spec or {}) do
        spec[#spec + 1] = clean(t[1]) .. ":" .. (t[2] or 0) .. ":" .. clean(t[3] and tostring(t[3]) or "")
    end
    local attune = {}
    for key, v in pairs(r.attune or {}) do
        if v then attune[#attune + 1] = clean(key) end
    end
    table.sort(attune)
    return table.concat({
        clean(r.name), clean(r.class), r.level or 0, string.format("%.1f", r.ilvl or 0),
        r.updated or 0, clean(r.version), table.concat(profs, ","), table.concat(raids, ","),
        -- felt 9–13 (fra versjon 1.1)
        r.epics or 0, r.fireRes or 0, clean(r.main), table.concat(spec, ","), table.concat(attune, ","),
        -- felt 14–15 (fra versjon 1.4)
        clean(r.bnetKey), clean(r.bnetName),
    }, ";")
end

function ns.DecodeRecord(s)
    local f = split(s, ";")
    if #f < 8 then return nil end
    local r = {
        name = f[1], class = f[2], level = tonumber(f[3]) or 0, ilvl = tonumber(f[4]) or 0,
        updated = tonumber(f[5]) or 0, version = f[6], profs = {}, raids = {},
    }
    if f[7] ~= "" then
        for _, p in ipairs(split(f[7], ",")) do
            local x = split(p, ":")
            r.profs[#r.profs + 1] = { x[1], tonumber(x[2]) or 0, tonumber(x[3]) or 0 }
        end
    end
    if f[8] ~= "" then
        for _, p in ipairs(split(f[8], ",")) do
            local x = split(p, ":")
            r.raids[x[1]] = { resetAt = tonumber(x[2]) or 0, done = tonumber(x[3]) or 0, total = tonumber(x[4]) or 0 }
        end
    end
    if #f >= 13 then
        r.epics   = tonumber(f[9]) or 0
        r.fireRes = tonumber(f[10]) or 0
        r.main    = f[11]
        r.spec    = {}
        if f[12] ~= "" then
            for _, p in ipairs(split(f[12], ",")) do
                local x = split(p, ":")
                local icon = x[3] ~= "" and x[3] or nil
                r.spec[#r.spec + 1] = { x[1], tonumber(x[2]) or 0, icon and (tonumber(icon) or icon) }
            end
        end
        r.attune = {}
        if f[13] ~= "" then
            for _, k in ipairs(split(f[13], ",")) do r.attune[k] = true end
        end
    end
    if #f >= 15 then
        r.bnetKey  = f[14] ~= "" and f[14] or nil
        r.bnetName = f[15]
    end
    return r
end

function ns.EncodeTribute(e)
    return table.concat({ clean(e.id), clean(e.from), e.amount or 0, e.time or 0, clean(e.via), clean(e.banker),
        clean(e.acctKey), clean(e.acctName), e.lo or 0, e.hi or 0, clean(e.kind or "deposit") }, ";")
end

function ns.DecodeTribute(s)
    local f = split(s, ";")
    if #f < 6 or f[1] == "" then return nil end
    local e = { id = f[1], from = f[2], amount = tonumber(f[3]) or 0, time = tonumber(f[4]) or 0, via = f[5], banker = f[6] }
    if #f >= 8 and f[7] ~= "" then e.acctKey, e.acctName = f[7], f[8] end
    if #f >= 10 then
        local lo, hi = tonumber(f[9]), tonumber(f[10])
        if lo and hi and lo > 0 then e.lo, e.hi = lo, hi end
    end
    if #f >= 11 and f[11] ~= "" then e.kind = f[11] end
    return e
end

function ns.EncodeConfig(c)
    local bankers, open = {}, {}
    for n in pairs(c.bankers) do bankers[#bankers + 1] = clean(n) end
    for k, v in pairs(c.openRaids) do if v then open[#open + 1] = clean(k) end end
    return table.concat({ c.updated or 0, clean(c.by), c.officerRank or 1, table.concat(bankers, ","), table.concat(open, ",") }, ";")
end

function ns.DecodeConfig(s)
    local f = split(s, ";")
    if #f < 5 then return nil end
    local c = { updated = tonumber(f[1]) or 0, by = ns.Short(f[2]), officerRank = tonumber(f[3]) or 1, bankers = {}, openRaids = {} }
    if f[4] ~= "" then for _, n in ipairs(split(f[4], ",")) do c.bankers[ns.Short(n)] = true end end
    for _, r in ipairs(ns.RAIDS) do c.openRaids[r.key] = false end
    if f[5] ~= "" then for _, k in ipairs(split(f[5], ",")) do c.openRaids[k] = true end end
    return c
end

---------------------------------------------------------------------------
-- Sendekø
-- Blizzard tillater ca. 10 addon-meldinger i et rykk, deretter ~1 per
-- sekund per prefix. Køen holder seg under det.
---------------------------------------------------------------------------
local queue = {}
local tokens, MAX_TOKENS, RATE = 8, 8, 1.0
local lastRefill = GetTime()
local msgId = 0

local function Refill()
    local now = GetTime()
    tokens = math.min(MAX_TOKENS, tokens + (now - lastRefill) * RATE)
    lastRefill = now
end

local sender = CreateFrame("Frame")
sender:Hide()
sender:SetScript("OnUpdate", function(self)
    Refill()
    while tokens >= 1 and #queue > 0 do
        local m = table.remove(queue, 1)
        if m.channel ~= "GUILD" or IsInGuild() then
            SendAddon(ns.PREFIX, m.msg, m.channel, m.target)
        end
        tokens = tokens - 1
    end
    if #queue == 0 then self:Hide() end
end)

function ns.Epoch()
    return (ns.db and ns.db.epoch and ns.db.epoch.t) or 0
end

-- Tidskritiske meldinger (utfordring, godta/avslå, terningkast, events) skal ikke
-- stå i kø bak en stor synk – ellers kan en 1v1-utfordring bli liggende i minutter
-- mens mottakeren ikke ser noe. De legges FORAN vanlige synk-meldinger, men bak
-- andre prioriterte, så rekkefølgen mellom dem bevares.
local PRIORITY = {
    DRCH = true, DROP = true, DRJN = true, DRAC = true, DRDE = true, DRCA = true,
    DROK = true, DRTR = true, DRRO = true, EVNEW = true, EVSIGN = true, TNEW = true,
}

function ns.Send(kind, payload, channel, target)
    payload = payload or ""
    msgId = (msgId % 9999) + 1
    local ep = ns.Epoch()
    local n = math.max(1, math.ceil(#payload / CHUNK))
    local prio = PRIORITY[kind] or false
    local pos = #queue + 1
    if prio then
        pos = 1
        while queue[pos] and queue[pos].prio do pos = pos + 1 end
    end
    for i = 1, n do
        local part = payload:sub((i - 1) * CHUNK + 1, i * CHUNK)
        table.insert(queue, pos, {
            msg = kind .. "^" .. msgId .. "^" .. i .. "^" .. n .. "^" .. ep .. "^" .. part,
            channel = channel, target = target, prio = prio,
        })
        pos = pos + 1
    end
    if not sender:IsShown() then Refill(); sender:Show() end
end

-- Hvor mange meldinger som venter (vises i vinduet under synk)
function ns.QueueSize() return #queue end

---------------------------------------------------------------------------
-- Synk-modell
--   Alt data har en nøkkel og en versjon:
--     m<hash>  medlem      (versjon = når dataene ble samlet inn)
--     t<hash>  gullbidrag  (finnes eller ikke)
--     cfg      innstillinger, bank  guild bank-beholdning
--   En synkrunde:
--     1. A sender SYNC + en innholdsliste (INV) til hele guilden.
--     2. Alle andre sammenligner med sin egen liste:
--          - det de har som A mangler, sender de til hele guilden
--          - det A har som de mangler, ber de om (WANT), og A sender det
--        Hver venter litt tilfeldig og dropper det noen andre allerede har
--        sendt eller bedt om, så samme data ikke sendes mange ganger.
--     Resultat: alle som er pålogget ender opp med summen av alles data.
---------------------------------------------------------------------------
local function H(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return string.format("%08x", h)
end

local covered = {}     -- nøkkel -> versjon noen har sendt i denne runden
local wanted  = {}     -- nøkkel -> true: noen har allerede bedt om den
local lastRoundAt = 0

local function TouchRound()
    local now = GetTime()
    if now - lastRoundAt > 90 then wipe(covered); wipe(wanted) end
    lastRoundAt = now
end

local function Mark(key, ver)
    if (covered[key] or 0) < (ver or 1) then covered[key] = ver or 1 end
end

local function LocalMaps()
    local mByH, tByH = {}, {}
    for name, rec in pairs(ns.db.members) do mByH[H(name)] = rec end
    for id, e in pairs(ns.db.tributes) do tByH[H(id)] = e end
    return mByH, tByH
end

local function BankTime() return (ns.db.bank and ns.db.bank.time) or 0 end
local function SnapTime() return (ns.db.snap and ns.db.snap.t) or 0 end
local function CfgTime() return ns.db.config.updated or 0 end

local function Inventory()
    local m, t = {}, {}
    for name, rec in pairs(ns.db.members) do m[#m + 1] = H(name) .. ":" .. (rec.updated or 0) end
    for id in pairs(ns.db.tributes) do t[#t + 1] = H(id) end
    return table.concat(m, ",") .. ";" .. table.concat(t, ",") .. ";" .. CfgTime() .. ";" .. BankTime() .. ";" .. SnapTime()
end

local function ParseInventory(s)
    local f = split(s, ";")
    if #f < 4 then return nil end
    local inv = { m = {}, t = {}, cfg = tonumber(f[3]) or 0, bank = tonumber(f[4]) or 0, snap = tonumber(f[5]) or 0, count = 0 }
    if f[1] ~= "" then
        for _, p in ipairs(split(f[1], ",")) do
            local h, v = p:match("^(%x+):(%d+)$")
            if h then inv.m[h] = tonumber(v); inv.count = inv.count + 1 end
        end
    end
    if f[2] ~= "" then
        for _, h in ipairs(split(f[2], ",")) do inv.t[h] = true; inv.count = inv.count + 1 end
    end
    return inv
end

-- Send en liste med nøkler til hele guilden (hopper over det andre allerede har sendt)
local BATCH = 8
function ns.SendItems(keys)
    if not ns.db then return end
    local mByH, tByH = LocalMaps()
    local recs, tribs = {}, {}
    local function Flush(kind, list)
        if #list > 0 then ns.Send(kind, table.concat(list, "/"), "GUILD") end
    end
    for _, key in ipairs(keys) do
        if key == "cfg" then
            if CfgTime() > 0 and (covered.cfg or 0) < CfgTime() then
                ns.Send("CFG", ns.EncodeConfig(ns.db.config), "GUILD"); Mark("cfg", CfgTime())
            end
        elseif key == "snap" then
            if SnapTime() > 0 and (covered.snap or 0) < SnapTime() then
                ns.Send("SNAP", ns.EncodeSnapshot(ns.db.snap), "GUILD"); Mark("snap", SnapTime())
            end
        elseif key == "bank" then
            if BankTime() > 0 and (covered.bank or 0) < BankTime() then
                ns.Send("BANK", ns.db.bank.money .. ";" .. ns.db.bank.time, "GUILD"); Mark("bank", BankTime())
            end
        elseif key:sub(1, 1) == "m" then
            local rec = mByH[key:sub(2)]
            if rec and (covered[key] or 0) < (rec.updated or 0) then
                recs[#recs + 1] = ns.EncodeRecord(rec); Mark(key, rec.updated)
                if #recs >= BATCH then Flush("RECS", recs); recs = {} end
            end
        elseif key:sub(1, 1) == "t" then
            local e = tByH[key:sub(2)]
            if e and not covered[key] then
                tribs[#tribs + 1] = ns.EncodeTribute(e); Mark(key, 1)
                if #tribs >= BATCH then Flush("TRIBS", tribs); tribs = {} end
            end
        end
    end
    Flush("RECS", recs)
    Flush("TRIBS", tribs)
end

local function AllKeys()
    local keys = { "cfg", "bank", "snap" }
    for name in pairs(ns.db.members) do keys[#keys + 1] = "m" .. H(name) end
    for id in pairs(ns.db.tributes) do keys[#keys + 1] = "t" .. H(id) end
    return keys
end

-- Start en synkrunde. refresh = alle oppdaterer også sine egne data først.
function ns.StartSync(refresh)
    if not ns.db or not IsInGuild() then return false end
    local now = GetTime()
    if ns.lastOwnSync and now - ns.lastOwnSync < 10 then
        if refresh then ns.Print("Vent litt – en synk er allerede i gang.") end
        return false
    end
    ns.lastOwnSync = now
    TouchRound()
    ns.Send("SYNC", refresh and "1" or "0", "GUILD")
    ns.Send("INV", Inventory(), "GUILD")
    return true
end

---------------------------------------------------------------------------
-- Nullstilling (epoke)
-- En offiser kan nullstille alt data for hele guilden. Alle meldinger bærer
-- epoken; den som har eldre epoke får beskjed og nullstiller seg selv,
-- også om de var avlogget da nullstillingen skjedde.
---------------------------------------------------------------------------
local function EpochPayload()
    return ns.Epoch() .. ";" .. ((ns.db.epoch and ns.db.epoch.by) or "")
end

function ns.ApplyReset(t, by)
    wipe(ns.db.members)
    wipe(ns.db.tributes)
    ns.tribCache = nil
    ns.db.bank = nil
    ns.db.snap = nil
    ns.db.epoch = { t = t, by = by }
    wipe(covered); wipe(wanted)
    ns.Print("Alle data er nullstilt" .. (by ~= ns.PlayerName() and (" av " .. ns.Short(by)) or "") .. ".")
    ns.UpdateSelf(true)
    ns.RefreshUI()
    -- Hent det de andre har lagt inn etter nullstillingen
    C_Timer.After(12, function()
        ns.lastOwnSync = nil
        ns.StartSync(false)
    end)
end

-- /gk status: hvem hører jeg fra, og er vi på samme nullstilling?
-- /gk test: finner ut om addon-meldinger kan sendes og mottas i det hele tatt
function ns.SelfTest()
    local function P(s) ns.Print(s) end
    local guildName = IsInGuild() and GetGuildInfo("player") or nil
    P("|cffffd100--- GuildKompass test ---|r")
    P("I guild: " .. tostring(IsInGuild()) .. (guildName and (" (" .. guildName .. ")") or ""))
    local reg = "ukjent"
    if C_ChatInfo and C_ChatInfo.IsAddonMessagePrefixRegistered then
        reg = tostring(C_ChatInfo.IsAddonMessagePrefixRegistered(ns.PREFIX))
    end
    P("Prefix " .. ns.PREFIX .. " registrert: " .. reg)
    local before = ns.rawSeen.own
    local ok, res = pcall(SendAddon, ns.PREFIX, "PING^1^1^1^" .. ns.Epoch() .. "^" .. ns.VERSION, "GUILD")
    local resText = tostring(res)
    if Enum and Enum.SendAddonMessageResult and type(res) == "number" then
        for k, v in pairs(Enum.SendAddonMessageResult) do if v == res then resText = res .. " (" .. k .. ")" end end
    end
    P("Sender test-melding til GUILD … resultat: " .. (ok and resText or ("|cffff5555feil: " .. resText .. "|r")))
    C_Timer.After(3, function()
        local rs = ns.rawSeen
        if rs.own > before then
            P("|cff55ff55Egen melding kom tilbake|r (" .. rs.ownBack[#rs.ownBack] .. ") – SENDING VIRKER.")
        else
            P("|cffff5555Egen melding kom IKKE tilbake – serveren slipper ikke gjennom addon-meldinger på GUILD.|r")
        end
        P("Addon-meldinger mottatt siden innlogging (alle addons): " .. rs.total)
        local n = 0
        for pk, c in pairs(rs.byPrefix) do
            n = n + 1
            if n <= 8 then P("   " .. pk .. ": " .. c) end
        end
        local others = {}
        for s, c in pairs(rs.bySender) do
            if not ns.IsMe(ns.FullName(s)) then others[#others + 1] = s .. " (" .. c .. ")" end
        end
        P("Fra andre spillere: " .. (#others > 0 and table.concat(others, ", ") or "|cffff5555ingen|r"))
        P("Meg: " .. tostring(ns.PlayerName()) .. "  ·  UnitName: " .. tostring(UnitName("player")))
    end)
end

function ns.PrintStatus()
    local me = ns.PlayerName()
    local key, accName = ns.AccountInfo()
    ns.Print(string.format("Jeg er %s  ·  Battle.net: %s  ·  versjon %s  ·  nullstilling: %s",
        me, (accName ~= "" and accName or "ukjent"), ns.VERSION,
        ns.Epoch() > 0 and date("%d.%m %H:%M", ns.Epoch()) or "ingen"))
    if not ns.roster[me] and next(ns.roster) then
        ns.Print("|cffff5555Fant ikke meg selv i guildlista – navnet mitt har feil format.|r")
    end
    local any = false
    for name, p in pairs(ns.peers or {}) do
        any = true
        local same = (p.ep == ns.Epoch())
        DEFAULT_CHAT_FRAME:AddMessage(string.format("  %s – sist hørt for %s siden %s%s",
            ns.Short(name), ns.FormatDuration(GetServerTime() - p.t),
            same and "|cff55ff55(OK)|r" or "|cffff5555(annen nullstilling!)|r",
            ns.roster[name] and "" or " |cffff9933(ikke funnet i guildlista)|r"))
    end
    if not any then
        ns.Print("Har ikke hørt fra noen andre ennå. Trykk Synk, og prøv /gk status igjen om noen sekunder.")
    end
end

function ns.GuildReset()
    if not ns.db then return end
    local me = ns.PlayerName()
    if not ns.IsOfficer(me) then ns.Print("Bare offiserer kan nullstille data.") return end
    local t = math.max(GetServerTime(), ns.Epoch() + 1)
    ns.ApplyReset(t, me)
    ns.Send("RESET", t .. ";" .. me, "GUILD")
end

---------------------------------------------------------------------------
-- Mottak
---------------------------------------------------------------------------
local buffers = {}
local Handlers = {}
ns.Handlers = Handlers   -- death roll / events legger til egne meldingstyper her
local throttle = {}

local function Throttled(key, seconds, fn)
    local now = GetTime()
    if throttle[key] and now - throttle[key] < seconds then return end
    throttle[key] = now
    fn()
end

-- Rå logg over ALLE addon-meldinger (alle addons), for /gk test
ns.rawSeen = { total = 0, byPrefix = {}, bySender = {}, own = 0, ownBack = {} }

function ns.OnAddonMessage(prefix, text, channel, from)
    local rs = ns.rawSeen
    rs.total = rs.total + 1
    local pk = tostring(prefix) .. " (" .. tostring(channel) .. ")"
    rs.byPrefix[pk] = (rs.byPrefix[pk] or 0) + 1
    rs.bySender[tostring(from)] = (rs.bySender[tostring(from)] or 0) + 1
    if prefix == ns.PREFIX and type(text) == "string" and text:find("^PING%^") then
        rs.own = rs.own + 1
        rs.ownBack[#rs.ownBack + 1] = tostring(from) .. " via " .. tostring(channel)
    end
    if prefix ~= ns.PREFIX or not ns.db then return end
    from = ns.FullName(from)
    if not from or ns.IsMe(from) then return end
    local kind, id, i, n, ep, data = text:match("^(%u+)%^(%d+)%^(%d+)%^(%d+)%^(%d+)%^(.*)$")
    if not kind then return end
    i, n, ep = tonumber(i), tonumber(n), tonumber(ep)

    -- Husk hvem vi hører fra (for /gk status)
    ns.peers = ns.peers or {}
    ns.peers[from] = { t = GetServerTime(), ep = ep, kind = kind }

    -- Ulik epoke: ikke bland data fra før og etter en nullstilling.
    -- Death roll (DR*) og events (EV*) er uavhengige av nullstillingen, så de
    -- slipper forbi denne sperren – ellers kunne en duell stoppe fordi to
    -- spillere hadde ulik nullstilling på medlemsdataene.
    local pre2 = kind:sub(1, 2)
    if kind ~= "RESET" and kind ~= "EPOCHQ" and pre2 ~= "DR" and pre2 ~= "EV" and pre2 ~= "TN" and pre2 ~= "RD" then
        local mine = ns.Epoch()
        if ep > mine then
            -- De har en nyere nullstilling enn meg: spør (via guildkanalen, ikke whisper)
            Throttled("q", 20, function() ns.Send("EPOCHQ", "", "GUILD") end)
            return
        elseif ep < mine then
            -- De har eldre data: fortell hele guilden hvilken nullstilling som gjelder
            Throttled("r", 20, function() ns.Send("RESET", EpochPayload(), "GUILD") end)
            return
        end
    end

    if n == 1 then
        if Handlers[kind] then Handlers[kind](from, data, channel) end
        return
    end
    local key = from .. ":" .. kind .. ":" .. id
    local b = buffers[key]
    if not b then
        b = { parts = {}, got = 0, n = n, t = GetTime() }
        buffers[key] = b
    end
    if not b.parts[i] then
        b.parts[i] = data
        b.got = b.got + 1
    end
    if b.got >= b.n then
        buffers[key] = nil
        if Handlers[kind] then Handlers[kind](from, table.concat(b.parts), channel) end
    end
    local now = GetTime()
    for k, v in pairs(buffers) do
        if now - v.t > 600 then buffers[k] = nil end
    end
end

local function StoreRecord(r)
    if not r or not r.name or r.name == "" then return false end
    r.name = ns.Short(r.name)
    if ns.IsMe(r.name) then return false end
    -- Hører vi fra et medlem vi ikke har i guild-rosteret (f.eks. nettopp
    -- innmeldt), be om en roster-oppdatering så rang/online fylles inn.
    if not ns.roster[r.name] and ns.RequestRoster then
        Throttled("rosterrefresh", 10, function() ns.RequestRoster() end)
    end
    Mark("m" .. H(r.name), r.updated)
    local old = ns.db.members[r.name]
    if old and (old.updated or 0) >= (r.updated or 0) then return false end
    ns.db.members[r.name] = r
    return true
end

-- Et medlem sender sine egne data (live)
Handlers.ME = function(from, data)
    local r = ns.DecodeRecord(data)
    if not r then return end
    r.name = from  -- stol bare på avsenderens eget navn
    if StoreRecord(r) then ns.RefreshUI() end
end

Handlers.RECS = function(from, data)
    local changed = false
    for _, s in ipairs(split(data, "/")) do
        if s ~= "" and StoreRecord(ns.DecodeRecord(s)) then changed = true end
    end
    if changed then ns.RefreshUI() end
end

Handlers.TRIBS = function(from, data)
    local changed = false
    for _, s in ipairs(split(data, "/")) do
        local e = s ~= "" and ns.DecodeTribute(s)
        if e then
            Mark("t" .. H(e.id), 1)
            if ns.MergeTribute(e) then changed = true end
        end
    end
    if changed then ns.TributesChanged() end
end

Handlers.CFG = function(from, data)
    local c = ns.DecodeConfig(data)
    if not c then return end
    Mark("cfg", c.updated)
    if not ns.IsOfficer(c.by) then return end
    if c.updated <= CfgTime() then return end
    ns.db.config.updated     = c.updated
    ns.db.config.by          = c.by
    ns.db.config.officerRank = c.officerRank
    ns.db.config.bankers     = c.bankers
    ns.db.config.openRaids   = c.openRaids
    ns.RefreshUI()
end

-- Guild bankens beholdning: "kobber;tidspunkt" – nyeste vinner
Handlers.BANK = function(from, data)
    local money, t = data:match("^(%d+);(%d+)$")
    money, t = tonumber(money), tonumber(t)
    if not money or not t then return end
    Mark("bank", t)
    if BankTime() >= t then return end
    ns.db.bank = { money = money, time = t, by = from }
    ns.RefreshUI()
end

-- Hele bankloggen slik noen nettopp leste den (fasit) – nyeste vinner
Handlers.SNAP = function(from, data)
    local snap = ns.DecodeSnapshot(data)
    if not snap then return end
    Mark("snap", snap.t)
    if ns.SetSnapshot(snap, true) then ns.TributesChanged() end
end

local lastSyncFrom = {}
local rounds = {}

-- Noen starter en synkrunde
Handlers.SYNC = function(from, data)
    local now = GetTime()
    if lastSyncFrom[from] and now - lastSyncFrom[from] < 8 then return end
    lastSyncFrom[from] = now
    TouchRound()
    local refresh = (data == "1")
    rounds[from] = { refresh = refresh, t = now }
    if refresh then
        ns.Print(ns.Short(from) .. " synker guilden …")
        ns.RequestRoster()
        ns.UpdateSelf(true)
    end
end

-- Innholdslisten til den som startet runden
Handlers.INV = function(from, data)
    local inv = ParseInventory(data)
    if not inv then return end
    TouchRound()
    local round = rounds[from] or {}
    local mByH, tByH = LocalMaps()

    -- Det jeg har som de mangler (eller har nyere)
    local offers = {}
    for h, rec in pairs(mByH) do
        local v = inv.m[h]
        if not v or v < (rec.updated or 0) then offers[#offers + 1] = "m" .. h end
    end
    for h in pairs(tByH) do
        if not inv.t[h] then offers[#offers + 1] = "t" .. h end
    end
    if CfgTime() > inv.cfg then offers[#offers + 1] = "cfg" end
    if BankTime() > inv.bank then offers[#offers + 1] = "bank" end
    if SnapTime() > inv.snap then offers[#offers + 1] = "snap" end

    -- Det de har som jeg mangler
    local wants = {}
    for h, v in pairs(inv.m) do
        local rec = mByH[h]
        if not rec or (rec.updated or 0) < v then wants[#wants + 1] = { "m" .. h, v } end
    end
    for h in pairs(inv.t) do
        if not tByH[h] then wants[#wants + 1] = { "t" .. h, 1 } end
    end
    if inv.cfg > CfgTime() then wants[#wants + 1] = { "cfg", inv.cfg } end
    if inv.bank > BankTime() then wants[#wants + 1] = { "bank", inv.bank } end
    if inv.snap > SnapTime() then wants[#wants + 1] = { "snap", inv.snap } end

    local delay = 1 + math.random() * 4 + (round.refresh and 2.5 or 0)
    C_Timer.After(delay, function()
        if not ns.db then return end
        if #offers > 0 then ns.SendItems(offers) end
        -- Be bare om det som fortsatt mangler og som ingen andre har bedt om
        local list = {}
        local m2, t2 = LocalMaps()
        for _, w in ipairs(wants) do
            local key, ver = w[1], w[2]
            local have
            if key == "cfg" then have = CfgTime() >= ver
            elseif key == "bank" then have = BankTime() >= ver
            elseif key == "snap" then have = SnapTime() >= ver
            elseif key:sub(1, 1) == "m" then have = m2[key:sub(2)] and (m2[key:sub(2)].updated or 0) >= ver
            else have = t2[key:sub(2)] ~= nil end
            if not have and not wanted[key] and (covered[key] or 0) < ver then list[#list + 1] = key end
        end
        if #list > 0 then
            local payload = (#list > inv.count * 0.6) and "*" or table.concat(list, ",")
            ns.Send("WANT", from .. "|" .. payload, "GUILD")
            for _, k in ipairs(list) do wanted[k] = true end
        end
    end)
end

-- Noen ber den som startet runden om data
local pendingWant, pendingAll, wantTimer = {}, false, false
Handlers.WANT = function(from, data)
    local target, list = data:match("^(.-)|(.*)$")
    if not target then return end
    TouchRound()
    target = ns.Short(target)
    if target ~= ns.PlayerName() then
        if list ~= "*" then for k in list:gmatch("[^,]+") do wanted[k] = true end end
        return
    end
    if list == "*" then pendingAll = true
    else for k in list:gmatch("[^,]+") do pendingWant[k] = true end end
    if wantTimer then return end
    wantTimer = true
    C_Timer.After(1.5, function()
        wantTimer = false
        local keys
        if pendingAll then
            keys = AllKeys()
        else
            keys = {}
            for k in pairs(pendingWant) do keys[#keys + 1] = k end
        end
        pendingWant, pendingAll = {}, false
        ns.SendItems(keys)
    end)
end

Handlers.EPOCHQ = function(from)
    if ns.Epoch() > 0 then
        Throttled("r", 20, function() ns.Send("RESET", EpochPayload(), "GUILD") end)
    end
end

-- Nyere nullstilling: godta den hvis den kommer fra et guildmedlem.
-- (Før krevdes det at navnet i nullstillingen var en offiser. Med fornavn +
-- etternavn i Forever kunne navnet ha feil format, og da ble guilden delt i
-- to grupper som ignorerte hverandre.)
Handlers.RESET = function(from, data)
    local t, by = data:match("^(%d+);(.*)$")
    t = tonumber(t)
    if not t or t <= ns.Epoch() then return end
    by = ns.Short(by)
    local rosterLoaded = next(ns.roster) ~= nil
    if rosterLoaded and not ns.roster[from] and not ns.IsOfficer(by) then return end
    ns.ApplyReset(t, (by ~= "" and by) or from)
end

---------------------------------------------------------------------------
-- Utsending av egne data (live)
---------------------------------------------------------------------------
function ns.BroadcastSelf()
    if not ns.db or not IsInGuild() then return end
    local r = ns.db.members[ns.PlayerName()]
    if r then
        ns.Send("ME", ns.EncodeRecord(r), "GUILD")
        Mark("m" .. H(r.name), r.updated)
    end
end

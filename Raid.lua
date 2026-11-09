local ADDON, ns = ...

-- Raid-påmelding med roller og vert-godkjenning. Bygger på GuildKompass sin
-- transport (ns.Send/ns.Handlers) og database (ns.db). Meldingstyper: RD*.
--  raid = { rid, title, host, when(epoch), size, note, rev, cancelled, created, by }
--  ns.db.raidsignups[rid][key] = { name, role, joined, status, tSign, tAppr }
--    role: "tank" | "healer" | "dps"      status: "pending" | "accepted" | "declined"

local ROLES = { "tank", "healer", "dps" }
ns.RAID_ROLES = ROLES
ns.RAID_ROLE_LABEL = { tank = "Tank", healer = "Healer", dps = "DPS" }

local function clean(s) return (tostring(s or ""):gsub("[|;,/%^:]", "")) end
local split = ns.Split
local function H(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return string.format("%08x", h)
end
local function RPrint(msg) DEFAULT_CHAT_FRAME:AddMessage("|cff66bbffRaid|r: " .. tostring(msg)) end
ns.RPrint = RPrint

function ns.EnsureRaids()
    local g = ns.db
    if not g then return end
    g.raids = g.raids or {}
    g.raidsignups = g.raidsignups or {}
    local now = GetServerTime()
    for rid, r in pairs(g.raids) do
        if (r.when and r.when > 0 and now > r.when + 7 * 86400) or (r.cancelled and now > (r.created or 0) + 3 * 86400) then
            g.raids[rid] = nil; g.raidsignups[rid] = nil
        end
    end
    for rid in pairs(g.raidsignups) do if not g.raids[rid] then g.raidsignups[rid] = nil end end
end

---------------------------------------------------------------------------
-- Koding
---------------------------------------------------------------------------
function ns.EncodeRaid(r)
    return table.concat({ clean(r.rid), clean(r.title), clean(r.host), r.when or 0, r.size or 0,
        clean(r.note), r.rev or 1, r.cancelled and 1 or 0, r.created or 0, clean(r.by) }, ";")
end

function ns.DecodeRaid(s)
    local x = split(s, ";")
    if #x < 10 or x[1] == "" then return nil end
    return { rid = x[1], title = x[2], host = ns.Short(x[3]), when = tonumber(x[4]) or 0,
             size = tonumber(x[5]) or 0, note = x[6], rev = tonumber(x[7]) or 1,
             cancelled = x[8] == "1", created = tonumber(x[9]) or 0, by = ns.Short(x[10]) }
end

function ns.MergeRaid(r)
    if not ns.db or not r then return false end
    ns.EnsureRaids()
    local old = ns.db.raids[r.rid]
    if old and (old.rev or 1) >= (r.rev or 1) then return false end
    ns.db.raids[r.rid] = r
    return true
end

-- Påmeldingsdel eid av spilleren selv (rolle + om de er med)
function ns.SetRaidSign(rid, name, role, joined, t)
    if not ns.db then return false end
    ns.EnsureRaids()
    ns.db.raidsignups[rid] = ns.db.raidsignups[rid] or {}
    local k = ns.Key(name)
    local s = ns.db.raidsignups[rid][k]
    if s and (s.tSign or 0) >= t then return false end
    if not s then s = { name = ns.Short(name), status = "pending" }; ns.db.raidsignups[rid][k] = s end
    s.role = role; s.joined = joined; s.tSign = t
    if not joined then s.status = "pending" end
    return true
end

-- Statusdel eid av verten/offiser
function ns.SetRaidStatus(rid, name, status, t)
    if not ns.db then return false end
    ns.EnsureRaids()
    ns.db.raidsignups[rid] = ns.db.raidsignups[rid] or {}
    local k = ns.Key(name)
    local s = ns.db.raidsignups[rid][k]
    if not s then s = { name = ns.Short(name), role = "dps", joined = true }; ns.db.raidsignups[rid][k] = s end
    if (s.tAppr or 0) >= t then return false end
    s.status = status; s.tAppr = t
    return true
end

---------------------------------------------------------------------------
-- Handlinger
---------------------------------------------------------------------------
function ns.CreateRaid(title, whenEpoch, size, note)
    if not ns.db then RPrint("Du må være i en guild.") return end
    ns.EnsureRaids()
    local me = ns.PlayerName()
    local rid = H(me .. GetServerTime() .. math.random(1, 1e6))
    local r = { rid = rid, title = (title ~= "" and title) or "Raid", host = me, when = whenEpoch or 0,
                size = size or 40, note = note or "", rev = 1, cancelled = false,
                created = GetServerTime(), by = me }
    ns.db.raids[rid] = r
    ns.Send("RDNEW", ns.EncodeRaid(r), "GUILD")
    RPrint("Raid opprettet: " .. r.title .. ". Alle i guilden ser den nå.")
    ns.RaidRefresh()
    return rid
end

function ns.CancelRaid(rid)
    local r = ns.db and ns.db.raids[rid]
    if not r then return end
    if not (ns.IsMe(r.host) or ns.IsGM(ns.PlayerName())) then
        RPrint("Bare verten (eller GM) kan avlyse raiden.")
        return
    end
    r.cancelled = true; r.rev = (r.rev or 1) + 1
    ns.Send("RDNEW", ns.EncodeRaid(r), "GUILD")
    RPrint("Raiden er avlyst.")
    ns.RaidRefresh()
end

function ns.SignRaid(rid, role)
    local r = ns.db and ns.db.raids[rid]
    if not r then return end
    role = (role == "tank" or role == "healer" or role == "dps") and role or "dps"
    local me = ns.PlayerName()
    local cur = ns.MyRaidSign(rid)
    local t = math.max(GetServerTime(), (cur and cur.tSign or 0) + 1)   -- strengt økende per spiller
    ns.SetRaidSign(rid, me, role, true, t)
    ns.Send("RDSIGN", table.concat({ clean(rid), clean(me), role, 1, t }, ";"), "GUILD")
    RPrint("Du meldte deg på " .. r.title .. " som " .. (ns.RAID_ROLE_LABEL[role] or role) .. ". Venter på godkjenning.")
    ns.RaidRefresh()
end

function ns.UnsignRaid(rid)
    local me = ns.PlayerName()
    local cur = ns.db and ns.db.raidsignups[rid] and ns.db.raidsignups[rid][ns.Key(me)]
    local t = math.max(GetServerTime(), (cur and cur.tSign or 0) + 1)
    ns.SetRaidSign(rid, me, cur and cur.role or "dps", false, t)
    ns.Send("RDSIGN", table.concat({ clean(rid), clean(me), cur and cur.role or "dps", 0, t }, ";"), "GUILD")
    ns.RaidRefresh()
end

function ns.SetRaidDecision(rid, name, accept)
    local r = ns.db and ns.db.raids[rid]
    if not r then return end
    if not (ns.IsMe(r.host) or ns.IsOfficer(ns.PlayerName())) then
        RPrint("Bare verten (eller en offiser) kan godkjenne.")
        return
    end
    local s = ns.db.raidsignups[rid] and ns.db.raidsignups[rid][ns.Key(name)]
    local t = math.max(GetServerTime(), (s and s.tAppr or 0) + 1)
    local status = accept and "accepted" or "declined"
    ns.SetRaidStatus(rid, name, status, t)
    ns.Send("RDAPPR", table.concat({ clean(rid), clean(name), status, t }, ";"), "GUILD")
    ns.RaidRefresh()
end

---------------------------------------------------------------------------
-- Oppslag
---------------------------------------------------------------------------
function ns.RaidList()
    local out = {}
    if not ns.db then return out end
    local now = GetServerTime()
    for _, r in pairs(ns.db.raids) do
        local past = r.when and r.when > 0 and now > r.when + 3 * 3600
        if not r.cancelled and not past then out[#out + 1] = r end
    end
    table.sort(out, function(a, b)
        local wa = (a.when and a.when > 0) and a.when or (a.created + 1e10)
        local wb = (b.when and b.when > 0) and b.when or (b.created + 1e10)
        if wa ~= wb then return wa < wb end
        return (a.created or 0) < (b.created or 0)
    end)
    return out
end

function ns.RaidSignups(rid)
    local out = {}
    for _, s in pairs(ns.db and ns.db.raidsignups[rid] or {}) do
        if s.joined then out[#out + 1] = s end
    end
    table.sort(out, function(a, b)
        local order = { tank = 1, healer = 2, dps = 3 }
        if (order[a.role] or 4) ~= (order[b.role] or 4) then return (order[a.role] or 4) < (order[b.role] or 4) end
        return (a.name or ""):lower() < (b.name or ""):lower()
    end)
    return out
end

function ns.RaidCounts(rid)
    local c = { tank = 0, healer = 0, dps = 0, accepted = 0, pending = 0, declined = 0, total = 0 }
    for _, s in pairs(ns.db and ns.db.raidsignups[rid] or {}) do
        if s.joined then
            c.total = c.total + 1
            c[s.role or "dps"] = (c[s.role or "dps"] or 0) + 1
            c[s.status or "pending"] = (c[s.status or "pending"] or 0) + 1
        end
    end
    return c
end

function ns.MyRaidSign(rid)
    return ns.db and ns.db.raidsignups[rid] and ns.db.raidsignups[rid][ns.Key(ns.PlayerName())]
end

-- Raids jeg er godkjent til (min "kalender")
function ns.MyRaids()
    local out = {}
    if not ns.db then return out end
    for rid, r in pairs(ns.db.raids) do
        if not r.cancelled then
            local s = ns.db.raidsignups[rid] and ns.db.raidsignups[rid][ns.Key(ns.PlayerName())]
            if s and s.joined then out[#out + 1] = { raid = r, sign = s } end
        end
    end
    table.sort(out, function(a, b)
        local wa = (a.raid.when and a.raid.when > 0) and a.raid.when or 1e11
        local wb = (b.raid.when and b.raid.when > 0) and b.raid.when or 1e11
        return wa < wb
    end)
    return out
end

---------------------------------------------------------------------------
-- Mottak
---------------------------------------------------------------------------
local Handlers = ns.Handlers

Handlers.RDNEW = function(from, data)
    local r = ns.DecodeRaid(data)
    if not r then return end
    local existed = ns.db and ns.db.raids[r.rid] ~= nil
    if ns.MergeRaid(r) then
        if not existed and not r.cancelled and not ns.IsMe(r.host)
            and (GetServerTime() - (r.created or 0)) < 180 and ns.global.eventWarnings and ns.Anim then
            ns.Anim.Banner("NY RAID: " .. (r.title ~= "" and r.title or "Raid"), "Meld deg på i guild-vinduet → Raid")
        end
        ns.RaidRefresh()
    end
end

Handlers.RDSIGN = function(from, data)
    local x = split(data, ";")
    if #x < 5 then return end
    local rid, name, role, joined, t = x[1], ns.Short(x[2]), x[3], x[4] == "1", tonumber(x[5]) or 0
    if ns.Key(name) ~= ns.Key(from) then return end     -- bare egen påmelding
    if ns.SetRaidSign(rid, name, role, joined, t) then ns.RaidRefresh() end
end

Handlers.RDAPPR = function(from, data)
    local x = split(data, ";")
    if #x < 4 then return end
    local rid, name, status, t = x[1], ns.Short(x[2]), x[3], tonumber(x[4]) or 0
    local r = ns.db and ns.db.raids[rid]
    if not r then return end
    if ns.Key(from) ~= ns.Key(r.host) and not ns.IsOfficer(from) then return end   -- bare vert/offiser
    if ns.SetRaidStatus(rid, name, status, t) then
        if ns.IsMe(name) then
            if status == "accepted" then
                RPrint("|cff55ff55Du er godkjent til " .. (r.title or "raiden") .. "!|r Den ligger nå i «Mine raids».")
                if ns.Anim then ns.Anim.Banner("GODKJENT TIL RAID!", r.title or "Raid") end
            elseif status == "declined" then
                RPrint("|cffff5555Du ble dessverre ikke tatt med på " .. (r.title or "raiden") .. ".|r")
            end
        end
        ns.RaidRefresh()
    end
end

-- Hello: be om / send raid-data ved innlogging
function ns.Raid_SendHello()
    if not ns.db or not IsInGuild() then return end
    ns.EnsureRaids()
    local list = {}
    for rid, r in pairs(ns.db.raids) do list[#list + 1] = H(rid) .. ":" .. (r.rev or 1) end
    ns.Send("RDHI", table.concat(list, ","), "GUILD")
end

Handlers.RDHI = function(from, data)
    if not ns.db then return end
    ns.EnsureRaids()
    local have = {}
    for p in (data or ""):gmatch("[^,]+") do
        local h, rev = p:match("^(%x+):(%d+)$")
        if h then have[h] = tonumber(rev) end
    end
    local send = {}
    for rid, r in pairs(ns.db.raids) do
        local hv = have[H(rid)]
        if not hv or hv < (r.rev or 1) then send[#send + 1] = rid end
    end
    if #send == 0 then return end
    C_Timer.After(1 + math.random() * 4, function()
        for _, rid in ipairs(send) do
            local r = ns.db.raids[rid]
            if r then
                ns.Send("RDNEW", ns.EncodeRaid(r), "GUILD")
                for _, s in pairs(ns.db.raidsignups[rid] or {}) do
                    ns.Send("RDSIGN", table.concat({ clean(rid), clean(s.name), s.role or "dps", s.joined and 1 or 0, s.tSign or 0 }, ";"), "GUILD")
                    if s.tAppr then
                        ns.Send("RDAPPR", table.concat({ clean(rid), clean(s.name), s.status or "pending", s.tAppr }, ";"), "GUILD")
                    end
                end
            end
        end
    end)
end

-- Påminnelse om raids (kalt fra samme ticker som events)
ns.raidReminded = ns.raidReminded or {}
function ns.CheckRaidReminders()
    if not ns.db or not ns.global.eventWarnings or not ns.Anim then return end
    local now = GetServerTime()
    for rid, r in pairs(ns.db.raids or {}) do
        if not r.cancelled and r.when and r.when > 0 then
            local rem = ns.raidReminded[rid] or {}
            local name = (r.title and r.title ~= "") and r.title or "Raid"
            if not rem.pre and now >= r.when - 1800 and now < r.when - 60 then
                rem.pre = true
                local mins = math.max(1, math.floor((r.when - now) / 60 + 0.5))
                ns.Anim.Banner("RAID OM " .. mins .. " MIN!", name)
                ns.Sound("RAID_WARNING")
            end
            if not rem.now and now >= r.when - 60 and now < r.when + 600 then
                rem.now = true
                ns.Anim.Banner("RAID STARTER NÅ!", name)
                ns.Sound("RAID_WARNING")
            end
            ns.raidReminded[rid] = rem
        end
    end
end

function ns.RaidRefresh()
    if ns.UI and ns.UI.Update then ns.UI:Update() end
end

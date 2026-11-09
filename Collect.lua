local ADDON, ns = ...

-- WoW: Forever bruker det moderne API-et (C_Item, GetProfessions osv.).
-- Alt her prøver moderne funksjoner først og faller tilbake til Classic.
local GetItemInfoX = (C_Item and C_Item.GetItemInfo) or GetItemInfo

-- Utstyrsplasser som teller med (skjorte og tabard er utelatt)
local SLOTS = { 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 }
ns.GEAR_SLOTS = #SLOTS

local function ItemLevel(link)
    if C_Item and C_Item.GetDetailedItemLevelInfo then
        local ok, l = pcall(C_Item.GetDetailedItemLevelInfo, link)
        if ok and l then return l end
    end
    if GetItemInfoX then
        local _, _, _, ilvl = GetItemInfoX(link)
        return ilvl
    end
end

-- Returnerer snitt-item-level og antall epics (eller bedre)
function ns.CollectGear()
    local total, epics, pending = 0, 0, false
    local offLink = GetInventoryItemLink("player", 17)
    for _, slot in ipairs(SLOTS) do
        local link = GetInventoryItemLink("player", slot)
        if link then
            local q = GetInventoryItemQuality and GetInventoryItemQuality("player", slot)
            if q and q >= 4 then epics = epics + 1 end
            local ilvl = ItemLevel(link)
            if ilvl then
                total = total + ilvl
                -- Tohåndsvåpen uten offhand teller dobbelt (samme som Blizzard)
                if slot == 16 and not offLink and GetItemInfoX then
                    local equipLoc = select(9, GetItemInfoX(link))
                    if equipLoc == "INVTYPE_2HWEAPON" then total = total + ilvl end
                end
            else
                pending = true
            end
        end
    end
    ns.ilvlPending = pending
    return total / #SLOTS, epics
end

local function AddProf(out, name, rank, maxRank, kind)
    if not name then return end
    -- Ukjente navn (f.eks. annet språk) får typen fra plassen de ligger på
    if not ns.PROFESSIONS[name] and kind then ns.PROFESSIONS[name] = kind end
    out[#out + 1] = { name, rank or 0, maxRank or 0 }
end

function ns.CollectProfessions()
    local out = {}
    if GetProfessions and GetProfessionInfo then
        -- Moderne: prof1, prof2, arkeologi, fishing, cooking, (first aid)
        local slots = { GetProfessions() }
        local n = select("#", GetProfessions())
        for i = 1, n do
            local idx = slots[i]
            if idx then
                local name, _, rank, maxRank = GetProfessionInfo(idx)
                AddProf(out, name, rank, maxRank, (i <= 2) and "primary" or "secondary")
            end
        end
    elseif GetNumSkillLines and GetSkillLineInfo then
        if ExpandSkillHeader then pcall(ExpandSkillHeader, 0) end
        for i = 1, (GetNumSkillLines() or 0) do
            local name, isHeader, _, rank, _, _, maxRank = GetSkillLineInfo(i)
            if name and not isHeader and ns.PROFESSIONS[name] then
                AddProf(out, name, rank, maxRank)
            end
        end
    end
    table.sort(out, function(a, b)
        local pa = ns.PROFESSIONS[a[1]] ~= "secondary"
        local pb = ns.PROFESSIONS[b[1]] ~= "secondary"
        if pa ~= pb then return pa end
        return a[2] > b[2]
    end)
    return out
end

-- Talenter/spec. Classic: { {tre, poeng, ikon}, ... }. Moderne: { {specnavn, -1, ikon} }
-- Ikonet sendes med fordi spillet bare kjenner ikonene til egen klasse.
-- WoW: Forever: hvert talenttre er en "specialization", og poeng per tre står
-- i GetSpecializationInfo(i) (7. returverdi = pointsSpent). Kan returnere
-- enten en liste med verdier eller en tabell, avhengig av versjon.
local function ForeverSpecInfo(i)
    for _, fn in ipairs({ C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo, GetSpecializationInfo }) do
        if fn then
            local ok, a, b, c, d, e, f, g = pcall(fn, i)
            if ok and a ~= nil then
                if type(a) == "table" then
                    return a.name, a.icon, a.pointsSpent or a.points
                end
                return b, d, g
            end
        end
    end
end

local function ForeverNumSpecs()
    local classID = select(3, UnitClass("player"))
    local candidates = {
        function() return GetNumSpecializations() end,
        function() return C_SpecializationInfo.GetNumSpecializationsForClassID(classID) end,
        function() return GetNumSpecializationsForClassID(classID) end,
    }
    for _, f in ipairs(candidates) do
        local ok, n = pcall(f)
        if ok and type(n) == "number" and n > 0 then return n end
    end
    return 0
end

local function Try(fn, ...)
    if not fn then return nil end
    local ok, a, b, c = pcall(fn, ...)
    if ok then return a, b, c end
end

-- WoW: Forever bruker "traits"-systemet: ett talenttre per klasse, delt i
-- grupper (Arcane / Fire / Frost). Poeng brukt per gruppe ligger i
-- gruppens "currency". (Samme fremgangsmåte som Blizzards eget talentvindu.)
local function TraitTrees()
    if not C_Traits or not C_SpecializationInfo then return nil end
    local specGroup = Try(C_SpecializationInfo.GetActiveSpecGroup) or 1
    local configID = Try(C_SpecializationInfo.GetCombatConfigIDForSpecGroup, specGroup)
    if not configID and C_ClassTalents then configID = Try(C_ClassTalents.GetActiveConfigID) end
    if not configID then return nil end
    local config = Try(C_Traits.GetConfigInfo, configID)
    local treeID = type(config) == "table" and type(config.treeIDs) == "table" and config.treeIDs[1]
    if not treeID then return nil end
    local displays = Try(C_Traits.GetGroupDisplayInfoByTreeID, treeID)
    if type(displays) ~= "table" or #displays == 0 then return nil end

    local groupIDs = {}
    for _, d in ipairs(displays) do
        if type(d) == "table" and type(d.groupID) == "number" then groupIDs[#groupIDs + 1] = d.groupID end
    end
    local spent = {}
    local currencies = Try(C_Traits.GetGroupCurrencyInfo, configID, groupIDs)
    if type(currencies) == "table" then
        for _, g in ipairs(currencies) do
            local first = type(g) == "table" and type(g.currencyInfos) == "table" and g.currencyInfos[1]
            if type(g) == "table" and g.traitNodeGroupID and type(first) == "table" and type(first.spent) == "number" then
                spent[g.traitNodeGroupID] = first.spent
            end
        end
    end

    local out = {}
    for _, d in ipairs(displays) do
        if type(d) == "table" and type(d.displayName) == "string" and d.displayName ~= "" then
            local icon = d.icon or d.iconFileID or d.iconTexture
            if icon == 0 then icon = nil end
            out[#out + 1] = { d.displayName, spent[d.groupID] or 0, icon }
        end
    end
    return #out > 0 and out or nil
end

function ns.CollectSpec()
    local out = {}

    -- 1. WoW: Forever – traits-systemet (poeng per gruppe/tre)
    local trees = TraitTrees()
    if trees then return trees end

    -- 2. Spec-API med poeng per tre (godtas bare hvis det faktisk finnes poeng)
    local n = ForeverNumSpecs()
    if n > 0 then
        local total = 0
        for i = 1, n do
            local name, icon, points = ForeverSpecInfo(i)
            if name then
                total = total + (tonumber(points) or 0)
                out[#out + 1] = { tostring(name), tonumber(points) or 0, icon }
            end
        end
        if total > 0 then return out end
        out = {}
    end

    -- 3. Classic Era – talentfaner
    if GetNumTalentTabs and GetTalentTabInfo then
        for i = 1, (GetNumTalentTabs() or 0) do
            -- Signaturen varierer: ny: id, name, desc, icon, points  |  gml: name, icon, points
            local a, b, c, d, e = GetTalentTabInfo(i)
            local name, points, icon
            if type(a) == "number" then name, points, icon = b, e, d else name, points, icon = a, c, b end
            out[#out + 1] = { tostring(name or ("Tre " .. i)), tonumber(points) or 0, icon }
        end
    end
    return out
end

-- /gk spec: vis hva addonen leser av talenter, og hvor det evt. stopper
function ns.PrintSpec()
    local spec = ns.CollectSpec()
    if #spec > 0 then
        local _, class = UnitClass("player")
        for _, t in ipairs(spec) do
            local icon = t[3] or (ns.SPEC_ICONS[class] and ns.SPEC_ICONS[class][t[1]])
            local tex = icon and ("|T" .. tostring(icon) .. ":16|t ") or ""
            DEFAULT_CHAT_FRAME:AddMessage(string.format("  %s%s: %d poeng", tex, t[1], t[2]))
        end
        return
    end
    -- Feilsøking: hvor i traits-kjeden stopper det?
    local steps = {}
    steps[#steps + 1] = "C_Traits=" .. tostring(C_Traits ~= nil) .. " C_SpecializationInfo=" .. tostring(C_SpecializationInfo ~= nil)
    if C_SpecializationInfo then
        local sg = Try(C_SpecializationInfo.GetActiveSpecGroup)
        local cid = Try(C_SpecializationInfo.GetCombatConfigIDForSpecGroup, sg or 1)
        steps[#steps + 1] = "specGroup=" .. tostring(sg) .. " configID=" .. tostring(cid)
        if C_ClassTalents then steps[#steps + 1] = "activeConfig=" .. tostring(Try(C_ClassTalents.GetActiveConfigID)) end
        if cid and C_Traits then
            local cfg = Try(C_Traits.GetConfigInfo, cid)
            local tree = type(cfg) == "table" and type(cfg.treeIDs) == "table" and cfg.treeIDs[1]
            steps[#steps + 1] = "treeID=" .. tostring(tree)
            if tree then
                local d = Try(C_Traits.GetGroupDisplayInfoByTreeID, tree)
                steps[#steps + 1] = "grupper=" .. tostring(type(d) == "table" and #d or d)
            end
        end
    end
    steps[#steps + 1] = "GetNumTalentTabs=" .. tostring(GetNumTalentTabs ~= nil)
    ns.Print("Fant ingen talentpoeng. Har karakteren brukt talentpoeng? (starter på level 10)")
    ns.Print("Teknisk info (send skjermbilde): " .. table.concat(steps, "  ·  "))
end

---------------------------------------------------------------------------
-- Battle.net-konto
-- Kontonavnet (det før #) vises for guilden. Hele BattleTag-en sendes
-- ALDRI – bare en enveis-nøkkel laget av den, så karakterene dine kan
-- grupperes uten at andre ser nummeret ditt.
---------------------------------------------------------------------------
local function Hash(s, seed)
    local h = seed
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 4294967296
    end
    return string.format("%08x", h)
end

local function BattleTag()
    if BNGetInfo then
        local ok, _, tag = pcall(BNGetInfo)
        if ok and type(tag) == "string" and tag ~= "" then return tag end
    end
end

function ns.AccountInfo()
    if ns.accountKey then return ns.accountKey, ns.accountName end
    local tag = BattleTag()
    if tag then
        ns.accountKey  = "b" .. Hash(tag, 5381) .. Hash(tag:reverse(), 7919)
        ns.accountName = tag:match("^([^#]+)") or tag
    else
        -- Ingen Battle.net-kontakt: bruk en tilfeldig nøkkel for denne WoW-kontoen
        if not ns.global.accountId then
            ns.global.accountId = string.format("a%08x%08x", math.random(0, 2147483647), math.random(0, 2147483647))
        end
        return ns.global.accountId, ""   -- ikke lagre i cache: prøv BattleTag igjen senere
    end
    return ns.accountKey, ns.accountName
end

function ns.RememberSelfChar()
    if not ns.db then return end
    ns.db.myChars = ns.db.myChars or {}
    ns.db.myChars[ns.PlayerName()] = UnitLevel("player")
end

-- Er denne karakteren min (samme Battle.net-konto)?
function ns.IsMine(full)
    if not ns.db or not full then return false end
    if ns.IsMe(full) then return true end
    if ns.db.myChars and ns.db.myChars[full] then return true end
    local rec = ns.db.members[full]
    return rec ~= nil and rec.bnetKey ~= nil and rec.bnetKey == (ns.AccountInfo())
end

function ns.MyChars()
    local list = {}
    for full in pairs(ns.roster) do
        if ns.IsMine(full) then list[#list + 1] = full end
    end
    if #list == 0 then
        for full in pairs(ns.db.myChars or {}) do list[#list + 1] = full end
    end
    table.sort(list)
    return list
end

-- Sett main (nil = automatisk). Bare egne karakterer er lov.
function ns.SetMain(full)
    if full and not ns.IsMine(full) then
        local names = {}
        for _, n in ipairs(ns.MyChars()) do names[#names + 1] = ns.Short(n) end
        ns.Print("Du kan bare velge blant dine egne karakterer: " .. table.concat(names, ", "))
        return false
    end
    ns.db.myMain = full
    ns.UpdateSelf(true)
    if full then
        ns.Print(ns.Short(full) .. " er nå main for alle karakterene dine.")
    else
        ns.Print("Main velges nå automatisk (høyest level).")
    end
    return true
end

-- Kjører en innsamler trygt: feiler den, får vi en tom verdi i stedet for Lua-feil
local function Safe(fn, default)
    local ok, a, b = pcall(fn)
    if ok then return a, b end
    return default
end

function ns.CollectSelf()
    local name = ns.PlayerName()
    if not name then return nil end
    ns.RememberSelfChar()
    local _, class = UnitClass("player")
    local ilvl, epics = Safe(ns.CollectGear, 0)
    local key, accName = ns.AccountInfo()
    local main = ns.db.myMain
    if main and not ns.IsMine(main) then main = nil; ns.db.myMain = nil end
    return {
        name     = name,
        class    = class,
        level    = UnitLevel("player"),
        ilvl     = ilvl or 0,
        epics    = epics or 0,
        profs    = Safe(ns.CollectProfessions, {}),
        spec     = Safe(ns.CollectSpec, {}),
        main     = main or "",          -- tom = automatisk
        bnetKey  = key,
        bnetName = accName,
        updated  = GetServerTime(),
        version  = ns.VERSION,
    }
end

-- Ikonet til talenttreet med flest poeng (nil hvis ingen talenter ennå)
function ns.SpecIcon(rec, class)
    local spec = rec and rec.spec
    if not spec or #spec == 0 then return nil end
    local best
    for _, t in ipairs(spec) do
        if not best or t[2] > best[2] then best = t end
    end
    if not best or best[2] == 0 then return nil end
    if best[3] and best[3] ~= "" then return best[3] end
    local byClass = ns.SPEC_ICONS[class or (rec and rec.class) or ""]
    return byClass and byClass[best[1]]
end

-- "Fury 5/31/15" (Classic) eller bare "Fury" (moderne spec-system)
function ns.SpecText(rec)
    local spec = rec and rec.spec
    if not spec or #spec == 0 then return nil end
    if #spec == 1 and spec[1][2] < 0 then return spec[1][1] end
    local best, pts, total = nil, -1, 0
    for _, t in ipairs(spec) do
        total = total + t[2]
        if t[2] > pts then best, pts = t[1], t[2] end
    end
    if total == 0 then return "ingen talenter" end
    local parts = {}
    for _, t in ipairs(spec) do parts[#parts + 1] = t[2] end
    return best .. " " .. table.concat(parts, "/")
end

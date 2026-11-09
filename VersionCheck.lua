-- VersionCheck.lua  (GuildKompass)
--
-- Sier fra i chatten når noen i guilden har en nyere versjon av GuildKompass, så man vet
-- at det er på tide å kjøre oppdateringsprogrammet. Addons kan ikke nå internett, så
-- klientene forteller hverandre hvilken versjon de har, over guild-kanalen.
--
-- Bevisst en EGEN, fast addon-prefix ("GKompassVer") og helt uavhengig av den vanlige
-- synken (ns.PREFIX, som byttes når protokollen endres): da fungerer varselet også
-- mellom versjoner som ellers ikke snakker sammen - det er jo akkurat da man må oppdatere.
-- Ikke endre PREFIX her.
--
-- Protokoll (guild):  "V:<versjon>"
--   * ved innlogging / reload: si fra hvilken versjon jeg har (etter en kort tilfeldig pause)
--   * hører jeg en NYERE versjon: varsle (én gang per økt)
--   * hører jeg en ELDRE versjon: si fra hvilken jeg har (maks hvert 30. sekund), så den
--     personen får vite det
--
-- Versjonen leses fra ns.VERSION (Data.lua) eller ellers "## Version" i .toc. Er den
-- ugyldig eller et ikke-erstattet token som @project-version@ (utviklerkopi), er
-- denne filen helt stille. Utgivelses-workflowen setter begge til tag-versjonen.

local ADDON, ns = ...
if type(ADDON) ~= "string" then return end
if type(ns) ~= "table" then ns = {} end

local PREFIX = "GKompassVer" -- maks 16 tegn. Skal ALDRI endres (se over).
local THROTTLE_SECONDS = 30

local GetMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
local SendMsg = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
local RegisterPrefix = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix
if not (SendMsg and RegisterPrefix and C_Timer and CreateFrame) then return end

local myVersion = ns.VERSION
if type(myVersion) ~= "string" or myVersion == "" then
    myVersion = GetMeta and GetMeta(ADDON, "Version")
end
if type(myVersion) ~= "string" or myVersion == "" or myVersion:find("@", 1, true) then return end

-- ---------------------------------------------------------------------------------------------
-- Sammenligning av versjoner. Samme regler som oppdateringsprogrammet: "v1.4", "1.4.0" og
-- "1.4.0-beta" forstås; manglende ledd teller som 0; en pre-release er eldre enn utgivelsen.
-- Gir 1 hvis a > b, -1 hvis a < b, 0 hvis like, nil hvis noen av dem ikke kan tolkes.
-- ---------------------------------------------------------------------------------------------
local function ParseVersion(s)
    s = tostring(s or "")
    s = s:gsub("^%s*[vV]?", "")
    s = s:gsub("%+.*$", "")
    local core, rest = s:match("^([%d%.]+)(.*)$")
    if not core then return nil end
    if rest ~= "" and not rest:find("^%-") then return nil end
    local nums = {}
    for n in core:gmatch("%d+") do
        nums[#nums + 1] = tonumber(n)
    end
    if #nums == 0 then return nil end
    local pre = rest:match("^%-(.+)$")
    return nums, pre
end

local function CompareVersions(a, b)
    local an, ap = ParseVersion(a)
    local bn, bp = ParseVersion(b)
    if not an or not bn then return nil end
    for i = 1, math.max(#an, #bn) do
        local x, y = an[i] or 0, bn[i] or 0
        if x ~= y then return x > y and 1 or -1 end
    end
    if ap == bp then return 0 end
    if not ap then return 1 end
    if not bp then return -1 end
    return ap > bp and 1 or -1 -- godt nok for beta/rc
end

ns.CompareVersions = CompareVersions

-- ---------------------------------------------------------------------------------------------

local warned = false
local lastBroadcast = -math.huge

local function Say(msg)
    if ns.Print then
        ns.Print(msg)
    else
        print("GuildKompass: " .. msg)
    end
end

local function Broadcast()
    if not IsInGuild() then return end
    local now = GetTime()
    if now - lastBroadcast < THROTTLE_SECONDS then return end
    lastBroadcast = now
    pcall(SendMsg, PREFIX, "V:" .. myVersion, "GUILD")
end

local function IsMe(sender)
    local me = UnitName("player")
    if sender == me then return true end
    return Ambiguate and Ambiguate(sender, "short") == me
end

pcall(RegisterPrefix, PREFIX)

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        local isInitialLogin, isReloadingUi = ...
        if isInitialLogin or isReloadingUi then
            -- tilfeldig pause så ikke hele guilden snakker i samme sekund
            C_Timer.After(5 + math.random() * 10, Broadcast)
        end
        return
    end

    -- CHAT_MSG_ADDON
    local prefix, text, channel, sender = ...
    if prefix ~= PREFIX or channel ~= "GUILD" then return end
    if type(text) ~= "string" or type(sender) ~= "string" or #text > 40 then return end
    local theirs = text:match("^V:(.+)$")
    if not theirs or IsMe(sender) then return end

    local cmp = CompareVersions(theirs, myVersion)
    if cmp == nil then return end
    if cmp > 0 then
        if not warned then
            warned = true
            Say(("En nyere versjon (|cffffff00%s|r) finnes - du har %s. "
                .. "Lukk WoW, kjør oppdateringsprogrammet, og start spillet på nytt."):format(theirs, myVersion))
        end
    elseif cmp < 0 then
        C_Timer.After(1 + math.random() * 4, Broadcast)
    end
end)

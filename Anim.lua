local ADDON, ns = ...

-- Liten animasjonsmotor: alt animeres bilde for bilde med OnUpdate, så det
-- virker likt i alle klientversjoner (Classic, Forever, Retail).
local A = {}
ns.Anim = A

---------------------------------------------------------------------------
-- Tween-motor
---------------------------------------------------------------------------
local tweens = {}
local driver = CreateFrame("Frame")
driver:Hide()
driver:SetScript("OnUpdate", function(self, elapsed)
    for i = #tweens, 1, -1 do
        local t = tweens[i]
        if t then
            t.elapsed = t.elapsed + elapsed
            local p = math.min(1, t.elapsed / t.duration)
            local ok = pcall(t.step, p, t.elapsed)
            if p >= 1 or not ok then
                table.remove(tweens, i)
                if t.done then pcall(t.done) end
            end
        end
    end
    if #tweens == 0 then self:Hide() end
end)

function A.Tween(duration, step, done)
    local t = { duration = math.max(0.01, duration), elapsed = 0, step = step, done = done }
    tweens[#tweens + 1] = t
    driver:Show()
    return t
end

function A.Cancel(t)
    for i, x in ipairs(tweens) do
        if x == t then table.remove(tweens, i) return end
    end
end

local function easeOut(p) return 1 - (1 - p) ^ 3 end
local function easeOutBack(p)
    local c1 = 1.70158
    local c3 = c1 + 1
    return 1 + c3 * (p - 1) ^ 3 + c1 * (p - 1) ^ 2
end
A.easeOut = easeOut

---------------------------------------------------------------------------
-- Pop: noe dukker opp stort og "smekker" på plass
---------------------------------------------------------------------------
function A.Pop(frame, from, duration)
    from = from or 1.8
    if frame.popTween then A.Cancel(frame.popTween) end
    frame.popTween = A.Tween(duration or 0.35, function(p)
        frame:SetScale(math.max(0.05, from + (1 - from) * easeOutBack(p)))
    end, function() frame:SetScale(1); frame.popTween = nil end)
end

---------------------------------------------------------------------------
-- Spinn: tallet ruller som en enarmet banditt og lander på resultatet
---------------------------------------------------------------------------
function A.Spin(fs, max, final, duration, onDone)
    duration = duration or 1.3
    local last = -1
    if fs.spinTween then A.Cancel(fs.spinTween) end
    fs.spinTween = A.Tween(duration, function(p, el)
        local interval = 0.03 + 0.22 * p * p        -- går saktere mot slutten
        if el - last >= interval then
            last = el
            fs:SetText(tostring(math.random(1, math.max(1, max))))
        end
    end, function()
        fs.spinTween = nil
        fs:SetText(tostring(final))
        if onDone then onDone() end
    end)
end

---------------------------------------------------------------------------
-- Rist: rammen rister (brukes når det nærmer seg 1)
---------------------------------------------------------------------------
function A.Shake(frame, intensity, duration)
    if frame.shaking then return end
    local point, rel, relPoint, x, y = frame:GetPoint(1)
    if not point then return end
    frame.shaking = true
    intensity = intensity or 6
    A.Tween(duration or 0.45, function(p)
        local k = intensity * (1 - p)
        frame:ClearAllPoints()
        frame:SetPoint(point, rel, relPoint, x + (math.random() * 2 - 1) * k, y + (math.random() * 2 - 1) * k)
    end, function()
        frame:ClearAllPoints()
        frame:SetPoint(point, rel, relPoint, x, y)
        frame.shaking = false
    end)
end

---------------------------------------------------------------------------
-- Gullmynt-regn for vinneren
---------------------------------------------------------------------------
local coinPool = {}
local COIN_TEX = {
    "Interface\\Icons\\INV_Misc_Coin_01", "Interface\\Icons\\INV_Misc_Coin_02",
    "Interface\\Icons\\INV_Misc_Coin_03", "Interface\\Icons\\INV_Misc_Coin_17",
}

function A.Coins(parent, count, anchor)
    count = count or 24
    anchor = anchor or parent
    for i = 1, count do
        local tex = table.remove(coinPool) or parent:CreateTexture(nil, "OVERLAY", nil, 7)
        tex:SetParent(parent)
        tex:SetTexture(COIN_TEX[math.random(1, #COIN_TEX)])
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local size = math.random(14, 26)
        tex:SetSize(size, size)
        tex:SetAlpha(1)
        tex:Show()
        local vx, vy = math.random(-240, 240), math.random(160, 420)
        local spin = (math.random() * 2 - 1) * 8
        local delay = math.random() * 0.25
        A.Tween(1.6 + delay, function(p, el)
            local t = math.max(0, el - delay)
            local dx = vx * t
            local dy = vy * t - 520 * t * t
            tex:ClearAllPoints()
            tex:SetPoint("CENTER", anchor, "CENTER", dx, dy)
            if tex.SetRotation then tex:SetRotation(spin * t) end
            tex:SetAlpha(p < 0.6 and 1 or (1 - (p - 0.6) / 0.4))
        end, function()
            tex:Hide()
            coinPool[#coinPool + 1] = tex
        end)
    end
end

---------------------------------------------------------------------------
-- Hodeskalle for taperen
---------------------------------------------------------------------------
function A.Skull(parent, anchor, size)
    anchor = anchor or parent
    local tex = parent.skullTex
    if not tex then
        tex = parent:CreateTexture(nil, "OVERLAY", nil, 6)
        tex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_8")
        parent.skullTex = tex
    end
    size = size or 110
    tex:ClearAllPoints()
    tex:SetPoint("CENTER", anchor, "CENTER", 0, 0)
    tex:Show()
    A.Tween(2.4, function(p, el)
        local s
        if el < 0.35 then s = 3 - 2 * easeOut(el / 0.35) else s = 1 end
        tex:SetSize(size * s, size * s)
        if el < 0.35 then tex:SetAlpha(el / 0.35)
        elseif el > 1.8 then tex:SetAlpha(math.max(0, 1 - (el - 1.8) / 0.6))
        else tex:SetAlpha(1) end
        if tex.SetRotation then tex:SetRotation(math.sin(el * 14) * 0.12 * math.max(0, 1 - el)) end
    end, function() tex:Hide() end)
end

---------------------------------------------------------------------------
-- Svevende tekst (f.eks. "+10g" eller "1!")
---------------------------------------------------------------------------
function A.FloatText(parent, anchor, text, r, g, b)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    fs:SetText(text)
    fs:SetTextColor(r or 1, g or 0.82, b or 0)
    A.Tween(1.6, function(p)
        fs:ClearAllPoints()
        fs:SetPoint("CENTER", anchor, "CENTER", 0, 20 + 70 * easeOut(p))
        fs:SetAlpha(p < 0.5 and 1 or (1 - (p - 0.5) * 2))
    end, function() fs:Hide() end)
end

---------------------------------------------------------------------------
-- Puls (glød som går opp og ned) – for "DIN TUR" og "VINNER"
---------------------------------------------------------------------------
local pulses = {}
local pulseDriver = CreateFrame("Frame")
pulseDriver:Hide()
pulseDriver:SetScript("OnUpdate", function(self)
    local t = GetTime()
    local any = false
    for region, cfg in pairs(pulses) do
        any = true
        local a = cfg.min + (cfg.max - cfg.min) * (0.5 + 0.5 * math.sin(t * cfg.speed))
        region:SetAlpha(a)
    end
    if not any then self:Hide() end
end)

function A.StartPulse(region, minA, maxA, speed)
    pulses[region] = { min = minA or 0.35, max = maxA or 1, speed = speed or 5 }
    pulseDriver:Show()
end

function A.StopPulse(region)
    if pulses[region] then
        pulses[region] = nil
        region:SetAlpha(1)
    end
end

---------------------------------------------------------------------------
-- Banner øverst på skjermen (event-dag)
---------------------------------------------------------------------------
local banner
function A.Banner(title, sub)
    if not banner then
        local tpl = BackdropTemplateMixin and "BackdropTemplate" or nil
        banner = CreateFrame("Frame", "GuildDeathRollBanner", UIParent, tpl)
        banner:SetSize(520, 96)
        banner:SetFrameStrata("FULLSCREEN_DIALOG")
        if banner.SetBackdrop then
            banner:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 32,
                insets = { left = 11, right = 12, top = 12, bottom = 11 } })
        end
        local l = banner:CreateTexture(nil, "ARTWORK")
        l:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_8")
        l:SetSize(56, 56); l:SetPoint("LEFT", 22, 0)
        local r = banner:CreateTexture(nil, "ARTWORK")
        r:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_8")
        r:SetSize(56, 56); r:SetPoint("RIGHT", -22, 0)
        banner.title = banner:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
        banner.title:SetPoint("TOP", 0, -24)
        banner.title:SetTextColor(1, 0.25, 0.25)
        banner.sub = banner:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        banner.sub:SetPoint("TOP", banner.title, "BOTTOM", 0, -8)
        banner:EnableMouse(true)
        banner:SetScript("OnMouseDown", function()
            if ns.UI and ns.UI.OpenTab then ns.UI:OpenTab("events") end
            banner:Hide()
        end)
    end
    banner.title:SetText(title)
    banner.sub:SetText(sub or "")
    banner:SetAlpha(1)
    banner:Show()
    ns.Sound("RAID_WARNING")
    A.StartPulse(banner.title, 0.55, 1, 4)
    A.Tween(6.5, function(p, el)
        local y
        if el < 0.6 then y = 140 - 260 * easeOut(el / 0.6) else y = -120 end
        banner:ClearAllPoints()
        banner:SetPoint("TOP", UIParent, "TOP", 0, y)
        if el > 5.6 then banner:SetAlpha(math.max(0, 1 - (el - 5.6) / 0.9)) end
    end, function()
        A.StopPulse(banner.title)
        banner:Hide()
    end)
end

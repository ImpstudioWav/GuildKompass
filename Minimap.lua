local ADDON, ns = ...

local button

local function UpdatePosition()
    local angle = math.rad(ns.global.minimap.angle or 200)
    -- Radius etter minimapens faktiske størrelse (moderne minimap er større enn Classic sin)
    local radius = (Minimap:GetWidth() or 140) / 2 + 10
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

function ns.UpdateMinimapButton()
    if not button then return end
    if ns.global.minimap.hide then button:Hide() else button:Show(); UpdatePosition() end
end

function ns.CreateMinimapButton()
    if button or not ns.global then return end
    button = CreateFrame("Button", "GuildKompassMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local icon = button:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
    icon:SetPoint("TOPLEFT", 7, -5)

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT")

    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetScript("OnClick", function(_, mouse)
        if mouse == "RightButton" then ns.HandleSlash("synk") else ns.UI:Toggle() end
    end)
    button:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale
            ns.global.minimap.angle = math.deg(math.atan2(cy - my, cx - mx))
            UpdatePosition()
        end)
    end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("GuildKompass")
        GameTooltip:AddLine("Venstreklikk: åpne/lukke", 1, 1, 1)
        GameTooltip:AddLine("Høyreklikk: synk med guilden", 1, 1, 1)
        GameTooltip:AddLine("Dra: flytt knappen", 1, 1, 1)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    ns.UpdateMinimapButton()
end

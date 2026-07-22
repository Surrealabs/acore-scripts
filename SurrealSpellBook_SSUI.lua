-------------------------------------------------------------------------------
-- SurrealSpellBook_SSUI.lua
--
-- Custom spellbook panel replacing the default Blizzard spellbook.
-- Displays all known spells organized by spell school/tab.
-- Uses SecureActionButtonTemplate for casting spells on click.
--
-- Usage:
--   Press P (default spellbook keybind) or /spells
--   Hides talent/collections/character when opened (mutual exclusion)
-------------------------------------------------------------------------------

local SSUI = SSUI or require("SSUI")

if SSUI.AddAddon() then
    -- Server side: nothing needed — spellbook is entirely client-side
else
    ---------------------------------------------------------------------------
    -- CLIENT SIDE
    ---------------------------------------------------------------------------

    -- =================================================================
    --  C O N F I G
    -- =================================================================
    local CFG = {
        WIDTH     = 980,
        HEIGHT    = 640,
        BG        = { 0.06, 0.06, 0.10 },
        BG_A      = 0.95,
        EDGE      = { 0.30, 0.30, 0.35 },
        ICON_SIZE = 38,
        ROW_H     = 44,
        COLS      = 2,       -- two-column spell layout
        TOP_PAD   = 60,      -- below title + tabs
        BOT_PAD   = 16,
        SIDE_PAD  = 16,
    }

    -- Compute rows per page
    local LIST_H = CFG.HEIGHT - CFG.TOP_PAD - CFG.BOT_PAD - 40 -- 40 for page bar
    local ROWS_PER_PAGE = math.floor(LIST_H / CFG.ROW_H)
    local SPELLS_PER_PAGE = ROWS_PER_PAGE * CFG.COLS

    -- =================================================================
    --  S T A T E
    -- =================================================================
    local currentTab   = 1
    local currentPage  = 1
    local totalPages   = 1
    local spellCache   = {}  -- [tab] = { {name, rank, icon, id, passive}, ... }
    local spellButtons = {}

    -- =================================================================
    --  M A I N   F R A M E
    -- =================================================================
    local frame = CreateFrame("Frame", "SurrealSpellBook", UIParent)
    frame:SetSize(CFG.WIDTH, CFG.HEIGHT)
    frame:SetPoint("CENTER", 0, 30)
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)
    frame:Hide()

    frame:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(CFG.BG[1], CFG.BG[2], CFG.BG[3], CFG.BG_A)
    frame:SetBackdropBorderColor(CFG.EDGE[1], CFG.EDGE[2], CFG.EDGE[3], 1)

    tinsert(UISpecialFrames, "SurrealSpellBook")

    -- Title
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -12)
    title:SetText("|cffffd100Spellbook|r")

    -- Close button
    local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() frame:Hide() end)

    -- =================================================================
    --  S P E L L   T A B S
    -- =================================================================
    local tabBar = CreateFrame("Frame", nil, frame)
    tabBar:SetPoint("TOPLEFT", 10, -34)
    tabBar:SetSize(CFG.WIDTH - 20, 24)

    local tabButtons = {}
    local MAX_TABS = 8

    for ti = 1, MAX_TABS do
        local tb = CreateFrame("Button", nil, tabBar)
        tb:SetSize(110, 22)
        tb:SetPoint("TOPLEFT", (ti - 1) * 114, 0)

        local tbBg = tb:CreateTexture(nil, "BACKGROUND")
        tbBg:SetAllPoints()
        tbBg:SetTexture(0.15, 0.15, 0.18, 0.5)
        tb.bg = tbBg

        local tbIcon = tb:CreateTexture(nil, "ARTWORK")
        tbIcon:SetSize(18, 18)
        tbIcon:SetPoint("LEFT", 2, 0)
        tb.icon = tbIcon

        local tbText = tb:CreateFontString(nil, "OVERLAY",
            "GameFontNormalSmall")
        tbText:SetPoint("LEFT", tbIcon, "RIGHT", 4, 0)
        tbText:SetPoint("RIGHT", -4, 0)
        tbText:SetJustifyH("LEFT")
        tb.label = tbText

        local tbHL = tb:CreateTexture(nil, "HIGHLIGHT")
        tbHL:SetAllPoints()
        tbHL:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
        tbHL:SetBlendMode("ADD")
        tbHL:SetAlpha(0.2)

        tb.tabIndex = ti
        tb:SetScript("OnClick", function(self)
            currentTab = self.tabIndex
            currentPage = 1
            RefreshSpellDisplay()
        end)

        tb:Hide()
        tabButtons[ti] = tb
    end

    -- =================================================================
    --  S P E L L   G R I D
    -- =================================================================
    local gridFrame = CreateFrame("Frame", nil, frame)
    gridFrame:SetPoint("TOPLEFT", CFG.SIDE_PAD, -CFG.TOP_PAD)
    gridFrame:SetPoint("BOTTOMRIGHT", -CFG.SIDE_PAD, CFG.BOT_PAD + 32)

    local colW = (CFG.WIDTH - 2 * CFG.SIDE_PAD) / CFG.COLS

    for si = 1, SPELLS_PER_PAGE do
        local col = ((si - 1) % CFG.COLS)
        local row = math.floor((si - 1) / CFG.COLS)

        -- Use SecureActionButtonTemplate so clicking casts the spell
        local btn = CreateFrame("Button", "SurrealSpell" .. si,
            gridFrame, "SecureActionButtonTemplate")
        btn:SetSize(colW - 8, CFG.ROW_H - 4)
        btn:SetPoint("TOPLEFT", col * colW + 4, -(row * CFG.ROW_H))

        -- Background
        local rowBg = btn:CreateTexture(nil, "BACKGROUND")
        rowBg:SetAllPoints()
        if si % 2 == 0 then
            rowBg:SetTexture(0.12, 0.12, 0.14, 0.3)
        else
            rowBg:SetTexture(0.10, 0.10, 0.12, 0.15)
        end

        -- Spell icon
        local ico = btn:CreateTexture(nil, "ARTWORK")
        ico:SetSize(CFG.ICON_SIZE, CFG.ICON_SIZE)
        ico:SetPoint("LEFT", 4, 0)
        ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        btn.icon = ico

        -- Spell name
        local nameText = btn:CreateFontString(nil, "OVERLAY",
            "GameFontNormal")
        nameText:SetPoint("LEFT", ico, "RIGHT", 8, 6)
        nameText:SetPoint("RIGHT", -8, 0)
        nameText:SetJustifyH("LEFT")
        btn.nameText = nameText

        -- Spell rank / subtext
        local rankText = btn:CreateFontString(nil, "OVERLAY",
            "GameFontNormalSmall")
        rankText:SetPoint("LEFT", ico, "RIGHT", 8, -8)
        rankText:SetJustifyH("LEFT")
        rankText:SetTextColor(0.6, 0.6, 0.6)
        btn.rankText = rankText

        -- Passive indicator
        local passiveText = btn:CreateFontString(nil, "OVERLAY",
            "GameFontNormalSmall")
        passiveText:SetPoint("RIGHT", -8, 0)
        passiveText:SetText("|cff888888Passive|r")
        passiveText:Hide()
        btn.passiveText = passiveText

        -- Highlight
        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
        hl:SetBlendMode("ADD")
        hl:SetAlpha(0.12)

        btn.spellID = nil
        btn.spellName = nil
        btn:Hide()

        -- Tooltip
        btn:SetScript("OnEnter", function(self)
            if self.spellID then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetSpellByID(self.spellID)
                GameTooltip:Show()
            end
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        -- Drag to action bar (spell pickup)
        btn:SetScript("OnDragStart", function(self)
            if self.spellName then
                PickupSpell(self.spellName)
            end
        end)
        btn:RegisterForDrag("LeftButton")

        -- Secure attribute: type=spell
        btn:SetAttribute("type", "spell")
        btn:RegisterForClicks("AnyUp")

        spellButtons[si] = btn
    end

    -- =================================================================
    --  P A G I N A T I O N
    -- =================================================================
    local pageFrame = CreateFrame("Frame", nil, frame)
    pageFrame:SetSize(CFG.WIDTH - 2 * CFG.SIDE_PAD, 28)
    pageFrame:SetPoint("BOTTOM", 0, CFG.BOT_PAD)

    local prevBtn = CreateFrame("Button", nil, pageFrame,
        "UIPanelButtonTemplate")
    prevBtn:SetSize(60, 22)
    prevBtn:SetPoint("LEFT", 4, 0)
    prevBtn:SetText("< Prev")
    prevBtn:SetScript("OnClick", function()
        if currentPage > 1 then
            currentPage = currentPage - 1
            RefreshSpellDisplay()
        end
    end)

    local nextBtn = CreateFrame("Button", nil, pageFrame,
        "UIPanelButtonTemplate")
    nextBtn:SetSize(60, 22)
    nextBtn:SetPoint("RIGHT", -4, 0)
    nextBtn:SetText("Next >")
    nextBtn:SetScript("OnClick", function()
        if currentPage < totalPages then
            currentPage = currentPage + 1
            RefreshSpellDisplay()
        end
    end)

    local pageText = pageFrame:CreateFontString(nil, "OVERLAY",
        "GameFontNormal")
    pageText:SetPoint("CENTER", 0, 0)

    -- =================================================================
    --  S C A N   S P E L L B O O K
    -- =================================================================
    local function ScanSpellbook()
        spellCache = {}
        local numTabs = GetNumSpellTabs()
        for ti = 1, numTabs do
            local tabName, tabTex, offset, count = GetSpellTabInfo(ti)
            spellCache[ti] = { name = tabName, icon = tabTex, spells = {} }

            for si = 1, count do
                local spellIndex = offset + si
                local name, rank = GetSpellName(spellIndex, BOOKTYPE_SPELL)
                if name then
                    local _, _, icon = GetSpellInfo(name)
                    -- Check if passive
                    local passive = IsPassiveSpell(spellIndex, BOOKTYPE_SPELL)
                    -- Get spell ID from link
                    local spellID = nil
                    local link = GetSpellLink(name)
                    if link then
                        spellID = tonumber(link:match("spell:(%d+)"))
                    end

                    table.insert(spellCache[ti].spells, {
                        name    = name,
                        rank    = rank or "",
                        icon    = icon,
                        id      = spellID,
                        passive = passive,
                        index   = spellIndex,
                    })
                end
            end
        end
    end

    -- =================================================================
    --  R E F R E S H   D I S P L A Y
    -- =================================================================
    function RefreshSpellDisplay()
        -- Update tab buttons
        local numTabs = #spellCache
        for ti = 1, MAX_TABS do
            if ti <= numTabs then
                local tab = spellCache[ti]
                tabButtons[ti].label:SetText(tab.name)
                if tab.icon then
                    tabButtons[ti].icon:SetTexture(tab.icon)
                end
                tabButtons[ti]:Show()
                if ti == currentTab then
                    tabButtons[ti].bg:SetTexture(0.25, 0.25, 0.35, 0.8)
                else
                    tabButtons[ti].bg:SetTexture(0.15, 0.15, 0.18, 0.5)
                end
            else
                tabButtons[ti]:Hide()
            end
        end

        -- Get spells for current tab
        local tabData = spellCache[currentTab]
        local spells = tabData and tabData.spells or {}

        -- Compute pages
        local total = #spells
        totalPages = math.ceil(total / SPELLS_PER_PAGE)
        if totalPages < 1 then totalPages = 1 end
        if currentPage > totalPages then currentPage = totalPages end

        local startIdx = (currentPage - 1) * SPELLS_PER_PAGE + 1

        -- Update title
        if tabData then
            title:SetText("|cffffd100Spellbook - " .. tabData.name .. "|r")
        end

        -- Populate spell buttons
        for si = 1, SPELLS_PER_PAGE do
            local btn = spellButtons[si]
            local idx = startIdx + si - 1
            local spell = spells[idx]

            if spell then
                btn.icon:SetTexture(spell.icon or
                    "Interface\\Icons\\INV_Misc_QuestionMark")
                btn.nameText:SetText(spell.name)
                btn.rankText:SetText(spell.rank ~= "" and spell.rank or "")
                btn.spellID = spell.id
                btn.spellName = spell.name

                if spell.passive then
                    btn.passiveText:Show()
                    btn.nameText:SetTextColor(0.6, 0.6, 0.6)
                else
                    btn.passiveText:Hide()
                    btn.nameText:SetTextColor(1, 1, 1)
                end

                -- Set secure attribute for casting
                btn:SetAttribute("spell", spell.name)

                btn:Show()
            else
                btn:Hide()
                btn.spellID = nil
                btn.spellName = nil
            end
        end

        -- Page buttons
        pageText:SetText(currentPage .. " / " .. totalPages)
        if currentPage <= 1 then prevBtn:Disable() else prevBtn:Enable() end
        if currentPage >= totalPages then
            nextBtn:Disable()
        else
            nextBtn:Enable()
        end
    end

    -- =================================================================
    --  T O G G L E   /   K E Y B I N D
    -- =================================================================
    local function ToggleSpellbook()
        if frame:IsShown() then
            frame:Hide()
        else
            frame:Show()
        end
    end

    SLASH_SURREALSPELLBOOK1 = "/spells"
    SLASH_SURREALSPELLBOOK2 = "/sb"
    SlashCmdList["SURREALSPELLBOOK"] = function()
        ToggleSpellbook()
    end

    -- Override ToggleSpellBook to open ours (P key)
    ToggleSpellBook = function()
        ToggleSpellbook()
    end

    -- Hook SpellbookMicroButton
    local hookFrame = CreateFrame("Frame")
    hookFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    hookFrame:SetScript("OnEvent", function(self, event)
        if SpellbookMicroButton then
            SpellbookMicroButton:SetScript("OnClick", function()
                ToggleSpellbook()
            end)
        end
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    end)

    -- =================================================================
    --  O N   S H O W
    -- =================================================================
    frame:SetScript("OnShow", function(self)
        -- Mutual exclusion
        if SurrealTalentFrame and SurrealTalentFrame:IsShown() then
            SurrealTalentFrame:Hide()
        end
        if SurrealCollections and SurrealCollections:IsShown() then
            SurrealCollections:Hide()
        end
        if SurrealCharacterFrame and SurrealCharacterFrame:IsShown() then
            SurrealCharacterFrame:Hide()
        end

        -- Scan and display
        ScanSpellbook()
        RefreshSpellDisplay()
    end)

    -- Listen for spell learn events
    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("LEARNED_SPELL_IN_TAB")
    eventFrame:RegisterEvent("SPELLS_CHANGED")
    eventFrame:SetScript("OnEvent", function()
        if frame:IsShown() then
            ScanSpellbook()
            RefreshSpellDisplay()
        end
    end)

end

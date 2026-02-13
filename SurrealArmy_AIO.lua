local AIO = AIO or require("AIO")

if AIO.AddAddon() then
    -- SERVER SIDE
    local Handlers = AIO.AddHandlers("SurrealArmy", {})

    function Handlers.RequestAlts(player)
        if not player then
            return
        end
        
        local accountId = player:GetAccountId()
        local playerGuid = player:GetGUIDLow()
        
        local result = CharDBQuery("SELECT guid, name, level, class FROM characters WHERE account = " .. accountId .. " AND guid != " .. playerGuid)
        
        -- Build a simple string list: "guid1:name1:level1:class1|guid2:name2:level2:class2|..."
        local altStr = ""
        local count = 0
        if result then
            repeat
                if count > 0 then altStr = altStr .. "|" end
                altStr = altStr .. result:GetUInt32(0) .. ":" .. result:GetString(1) .. ":" .. result:GetUInt32(2) .. ":" .. result:GetUInt32(3)
                count = count + 1
            until not result:NextRow()
        end
        
        AIO.Handle(player, "SurrealArmy", "ReceiveAlts", altStr)
    end

    function Handlers.SpawnBot(player, botName)
        if not player or not botName then
            return
        end
        -- Execute the army spawn command for this player
        player:RunCommand("army spawn " .. botName)
    end

    function Handlers.DismissBot(player, botName)
        if not player then
            return
        end
        if botName and botName ~= "" then
            -- Dismiss a specific bot by name
            player:RunCommand("army dismissone " .. botName)
        else
            -- Dismiss all bots
            player:RunCommand("army dismiss")
        end
    end
else
    -- CLIENT SIDE
    local ArmyHandlers = AIO.AddHandlers("SurrealArmy", {})
    
    function ArmyHandlers.ReceiveAlts(player, altStr)
        -- Parse string format: "guid1:name1:level1:class1|guid2:name2:level2:class2|..."
        local altList = {}
        if type(altStr) == "string" and altStr ~= "" then
            for entry in altStr:gmatch("[^|]+") do
                local guid, name, level, class = entry:match("^(%d+):([^:]+):(%d+):(%d+)$")
                if guid and name then
                    altList[#altList + 1] = {tonumber(guid), name, tonumber(level), tonumber(class)}
                end
            end
        end
        _G.SurrealArmyAlts = altList
        if _G.SurrealArmyBotSlots then
            for i = 2, 5 do
                if _G.SurrealArmyBotSlots[i] then
                    _G.PopulateSurrealArmyDropdown(_G.SurrealArmyBotSlots[i], altList)
                end
            end
        end
    end

    -- Constants
    local FRAME_W, FRAME_H = 980, 640
    local SLOT_W, SLOT_H = 110, 160
    local SLOT_GAP = 10
    local MAX_BOTS = 5

    --------------------------------------------------------------------------
    -- HELPER: find a party/raid unit ID by character name
    --------------------------------------------------------------------------
    local function GetUnitIdByName(name)
        for i = 1, 4 do
            local id = "party" .. i
            if UnitExists(id) and UnitName(id) == name then return id end
        end
        return nil
    end

    -- Main frame
    local armyFrame = CreateFrame("Frame", "SurrealArmyFrame", UIParent)
    armyFrame:SetSize(FRAME_W, FRAME_H)
    armyFrame:SetPoint("CENTER", 0, 30)
    armyFrame:SetFrameStrata("HIGH")
    armyFrame:SetMovable(true)
    armyFrame:EnableMouse(true)
    armyFrame:RegisterForDrag("LeftButton")
    armyFrame:SetScript("OnDragStart", armyFrame.StartMoving)
    armyFrame:SetScript("OnDragStop", armyFrame.StopMovingOrSizing)
    armyFrame:SetClampedToScreen(true)
    armyFrame:Hide()

    -- Request alts from server when panel is shown
    armyFrame:SetScript("OnShow", function()
        -- Close other Surreal frames for mutual exclusion
        if SurrealCharacterFrame and SurrealCharacterFrame:IsShown() then
            SurrealCharacterFrame:Hide()
        end
        if SurrealTalentFrame and SurrealTalentFrame:IsShown() then
            SurrealTalentFrame:Hide()
        end
        if SurrealSpellBook and SurrealSpellBook:IsShown() then
            SurrealSpellBook:Hide()
        end
        if CharacterFrame and CharacterFrame:IsShown() then
            CharacterFrame:Hide()
        end
        AIO.Handle("SurrealArmy", "RequestAlts")

        -- After a short delay, sync slot spawned state with current party members
        local syncTimer = CreateFrame("Frame")
        syncTimer.elapsed = 0
        syncTimer:SetScript("OnUpdate", function(self, dt)
            self.elapsed = self.elapsed + dt
            if self.elapsed >= 0.5 then
                self:SetScript("OnUpdate", nil)
                -- Build lookup of current party member names
                local partyNames = {}
                for pi = 1, 4 do
                    local id = "party" .. pi
                    if UnitExists(id) then
                        partyNames[UnitName(id)] = true
                    end
                end
                -- Check each alt slot
                if _G.SurrealArmyBotSlots and _G.SurrealArmyAlts then
                    local usedAlts = {}  -- track which alts are already assigned to slots
                    -- First pass: keep existing spawned slots that are still in party
                    for i = 2, 5 do
                        local s = _G.SurrealArmyBotSlots[i]
                        if s and s.isSpawned and s.ddText then
                            local name = s.ddText:GetText()
                            if name and partyNames[name] then
                                usedAlts[name] = i
                            else
                                -- Was spawned but no longer in party — reset
                                s.isSpawned = false
                                if s.model then s.model:Hide() end
                                if s.ddText then s.ddText:SetText("Select Alt") end
                                if s.spawnBtn then s.spawnBtn:Hide() end
                                if s.dismissBtn then s.dismissBtn:Hide() end
                                if s.emptyText then s.emptyText:Show() end
                                if s.spawnedName then s.spawnedName:Hide() end
                                if s.ddBtn then s.ddBtn:Show() end
                                s.selectedAlt = nil
                            end
                        end
                    end
                    -- Second pass: assign untracked party members to empty slots
                    for partyName, _ in pairs(partyNames) do
                        if not usedAlts[partyName] then
                            -- Find this alt's data
                            local altData = nil
                            for _, alt in ipairs(_G.SurrealArmyAlts) do
                                if alt[2] == partyName then
                                    altData = alt
                                    break
                                end
                            end
                            if altData then
                                -- Find first empty slot
                                for i = 2, 5 do
                                    local s = _G.SurrealArmyBotSlots[i]
                                    if s and not s.isSpawned and (not s.ddText or s.ddText:GetText() == "Select Alt") then
                                        s.isSpawned = true
                                        s.selectedAlt = altData[1]
                                        s.altClass = altData[4] or 0
                                        s.altLevel = altData[3] or 0
                                        if s.ddText then s.ddText:SetText(partyName) end
                                        if s.ddBtn then s.ddBtn:Hide() end
                                        if s.emptyText then s.emptyText:Hide() end
                                        if s.spawnBtn then s.spawnBtn:Hide() end
                                        if s.dismissBtn then s.dismissBtn:Show() end
                                        if s.spawnedName then
                                            s.spawnedName:SetText("|cffffd700" .. partyName .. "|r")
                                            s.spawnedName:Show()
                                        end
                                        -- Show slot thumbnail model
                                        local unitId = GetUnitIdByName(partyName)
                                        if unitId and s.model then
                                            s.model:SetUnit(unitId)
                                            s.model:Show()
                                        end
                                        break
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end)
    end)

    -- Backdrop
    armyFrame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    armyFrame:SetBackdropColor(0.06, 0.06, 0.10, 0.95)
    armyFrame:SetBackdropBorderColor(0.30, 0.30, 0.35, 1)

    tinsert(UISpecialFrames, "SurrealArmyFrame")

    -- Title
    local titleText = armyFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleText:SetPoint("TOP", 0, -10)
    titleText:SetText("|cffffd100Select a Character|r")

    -- Close button
    local closeBtn = CreateFrame("Button", nil, armyFrame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() armyFrame:Hide() end)

    -- Selected slot tracker
    local selectedSlot = nil
    local activeTab = "character"  -- "character", "talents", "bags"

    --------------------------------------------------------------------------
    -- RIGHT SIDE TAB LIST
    --------------------------------------------------------------------------
    local TAB_W, TAB_H = 100, 32
    local TAB_PAD = 4
    local tabPanel = CreateFrame("Frame", nil, armyFrame)
    tabPanel:SetSize(TAB_W + 8, FRAME_H - 60)
    tabPanel:SetPoint("TOPRIGHT", armyFrame, "TOPRIGHT", -6, -30)

    local tabDefs = {
        { key = "character", label = "Character", icon = "Interface\\Icons\\INV_Misc_GroupLooking" },
        { key = "talents",   label = "Talents",   icon = "Interface\\Icons\\Ability_Marksmanship" },
        { key = "bags",      label = "Bags",      icon = "Interface\\Icons\\INV_Misc_Bag_08" },
    }
    local tabButtons = {}

    --------------------------------------------------------------------------
    -- CENTER CONTENT PANELS (one per tab)
    --------------------------------------------------------------------------
    -- Character panel (3D model using DressUpModel for gear display)
    local centerFrame = CreateFrame("Frame", nil, armyFrame)
    centerFrame:SetSize(500, 500)
    centerFrame:SetPoint("CENTER", armyFrame, "CENTER", -50, 20)

    local centerModel = CreateFrame("DressUpModel", nil, centerFrame)
    centerModel:SetPoint("CENTER", centerFrame, "CENTER", 0, -20)
    centerModel:SetSize(400, 400)
    centerModel:SetUnit("player")



    local centerName = centerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    centerName:SetPoint("TOP", centerFrame, "TOP", 0, -10)
    centerName:SetText("|cffffd700" .. (UnitName("player") or "Player") .. "|r")

    -- Level & class info under name
    local centerInfo = centerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    centerInfo:SetPoint("TOP", centerName, "BOTTOM", 0, -4)
    centerInfo:SetText("")

    -- Talents panel (hidden by default)
    local talentPanel = CreateFrame("Frame", nil, armyFrame)
    talentPanel:SetSize(700, 520)
    talentPanel:SetPoint("CENTER", armyFrame, "CENTER", -50, 10)
    talentPanel:Hide()

    local talentTitle = talentPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    talentTitle:SetPoint("TOP", talentPanel, "TOP", 0, -6)
    talentTitle:SetText("|cffffd100Talents|r")

    -- Talent icon grid — pool of reusable icon buttons
    local TALENT_BTN_SIZE = 34
    local TALENT_BTN_GAP  = 4
    local TALENT_COLS     = 14
    local MAX_TALENT_BTNS = 60
    local talentBtns = {}

    local talentGrid = CreateFrame("Frame", nil, talentPanel)
    talentGrid:SetSize(TALENT_COLS * (TALENT_BTN_SIZE + TALENT_BTN_GAP), 400)
    talentGrid:SetPoint("TOP", talentTitle, "BOTTOM", 0, -8)

    for bi = 1, MAX_TALENT_BTNS do
        local btn = CreateFrame("Button", nil, talentGrid)
        btn:SetSize(TALENT_BTN_SIZE, TALENT_BTN_SIZE)
        btn:Hide()

        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(0.15, 0.15, 0.18)
        btn.bg = bg

        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", 2, -2)
        icon:SetPoint("BOTTOMRIGHT", -2, 2)
        btn.icon = icon

        -- Glow border for learned talents
        local glow = btn:CreateTexture(nil, "OVERLAY")
        glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        glow:SetBlendMode("ADD")
        glow:SetPoint("CENTER")
        glow:SetSize(TALENT_BTN_SIZE * 1.4, TALENT_BTN_SIZE * 1.4)
        glow:SetVertexColor(0.85, 0.68, 0.00)
        glow:SetAlpha(0.5)
        btn.glow = glow

        btn:SetScript("OnEnter", function(self)
            if self.spellName then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(self.spellName, 1, 1, 1)
                GameTooltip:Show()
            end
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        talentBtns[bi] = btn
    end

    -- Placeholder text when no data
    local talentEmpty = talentPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    talentEmpty:SetPoint("CENTER", talentPanel, "CENTER", 0, 0)
    talentEmpty:SetText("|cffaaaaaaSelect a character to view their talents.|r")

    -- Bags panel (hidden by default)
    local bagsPanel = CreateFrame("Frame", nil, armyFrame)
    bagsPanel:SetSize(600, 480)
    bagsPanel:SetPoint("CENTER", armyFrame, "CENTER", -50, 20)
    bagsPanel:Hide()

    local bagsTitle = bagsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    bagsTitle:SetPoint("TOP", bagsPanel, "TOP", 0, -10)
    bagsTitle:SetText("|cffffd100Bags|r")

    local bagsComingSoon = bagsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    bagsComingSoon:SetPoint("CENTER", bagsPanel, "CENTER", 0, 0)
    bagsComingSoon:SetText("|cff888888Coming Soon|r")

    -- Tab content map
    local tabPanels = {
        character = centerFrame,
        talents   = talentPanel,
        bags      = bagsPanel,
    }

    -- Switch active tab
    local function SetActiveTab(key)
        activeTab = key
        for k, panel in pairs(tabPanels) do
            if k == key then panel:Show() else panel:Hide() end
        end
        -- Update tab button highlights
        for _, tb in ipairs(tabButtons) do
            if tb.key == key then
                tb:SetBackdropColor(0.15, 0.15, 0.25, 1)
                tb:SetBackdropBorderColor(0.4, 0.4, 0.8, 1)
            else
                tb:SetBackdropColor(0.08, 0.08, 0.12, 0.9)
                tb:SetBackdropBorderColor(0.25, 0.25, 0.30, 1)
            end
        end
    end

    -- Create tab buttons
    for idx, def in ipairs(tabDefs) do
        local tb = CreateFrame("Button", nil, tabPanel)
        tb:SetSize(TAB_W, TAB_H)
        tb:SetPoint("TOPLEFT", tabPanel, "TOPLEFT", 4, -((idx-1) * (TAB_H + TAB_PAD)) - 4)
        tb:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 8, edgeSize = 8,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        tb:SetBackdropColor(0.08, 0.08, 0.12, 0.9)
        tb:SetBackdropBorderColor(0.25, 0.25, 0.30, 1)
        tb.key = def.key

        -- Icon
        local icon = tb:CreateTexture(nil, "ARTWORK")
        icon:SetSize(20, 20)
        icon:SetPoint("LEFT", tb, "LEFT", 6, 0)
        icon:SetTexture(def.icon)

        -- Label
        local label = tb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("LEFT", icon, "RIGHT", 6, 0)
        label:SetText("|cffffd700" .. def.label .. "|r")

        tb:SetScript("OnClick", function() SetActiveTab(def.key) end)
        tb:SetScript("OnEnter", function()
            if tb.key ~= activeTab then
                tb:SetBackdropColor(0.12, 0.12, 0.20, 1)
            end
        end)
        tb:SetScript("OnLeave", function()
            if tb.key ~= activeTab then
                tb:SetBackdropColor(0.08, 0.08, 0.12, 0.9)
            end
        end)

        tabButtons[#tabButtons + 1] = tb
    end

    -- Initialize to character tab
    SetActiveTab("character")

    --------------------------------------------------------------------------
    -- CLASS DATA
    --------------------------------------------------------------------------
    local CLASS_NAMES = {
        [1] = "Warrior", [2] = "Paladin", [3] = "Hunter", [4] = "Rogue",
        [5] = "Priest", [6] = "Death Knight", [7] = "Shaman", [8] = "Mage",
        [9] = "Warlock", [11] = "Druid",
    }
    local CLASS_COLORS = {
        [1] = "ffc79c6e", [2] = "fff58cba", [3] = "ffabd473", [4] = "fffff569",
        [5] = "ffffffff", [6] = "ffc41f3b", [7] = "ff0070de", [8] = "ff69ccf0",
        [9] = "ff9482c9", [11] = "ffff7d0a",
    }

    --------------------------------------------------------------------------
    -- TALENT DISPLAY — inspect-based grid with real tier/column positions
    --------------------------------------------------------------------------
    -- Track which bot we're inspecting
    local inspectingBotName = nil
    local inspectingBotUnit = nil

    local function UpdateTalentDisplay(unitName, isInspect)
        -- Hide all talent buttons first
        for bi = 1, MAX_TALENT_BTNS do talentBtns[bi]:Hide() end

        if not unitName or unitName == "Select Alt" then
            talentEmpty:SetText("|cffaaaaaaSelect a character to view their talents.|r")
            talentEmpty:Show()
            talentTitle:SetText("|cffffd100Talents|r")
            return
        end
        talentTitle:SetText("|cffffd100" .. unitName .. " \226\128\148 Talents|r")

        -- Determine if we use inspect or player API
        local useInspect = isInspect
        local numTabs = GetNumTalentTabs(useInspect) or 0
        if numTabs == 0 and isInspect then
            -- Inspect data not ready yet
            talentEmpty:SetText("|cffaaaaaa" .. unitName .. "'s talents loading...|r")
            talentEmpty:Show()
            return
        end
        if numTabs == 0 then
            talentEmpty:SetText("|cffaaaaaaNo talent data available.|r")
            talentEmpty:Show()
            return
        end

        -- Build spec tab buttons at the top of the talent panel
        -- Find which spec has the most points (or show all 3 tabs)
        local tabInfo = {}
        local bestTab, bestPts = 1, 0
        for tab = 1, numTabs do
            local tabName, tabIcon, pointsSpent = GetTalentTabInfo(tab, useInspect)
            tabInfo[tab] = { name = tabName, icon = tabIcon, pts = pointsSpent or 0 }
            if (pointsSpent or 0) > bestPts then
                bestTab = tab
                bestPts = pointsSpent
            end
        end

        -- Use a grid layout: 5 columns wide, positioned by tier (row) and column
        local GRID_COLS = 5
        local GRID_BTN = TALENT_BTN_SIZE
        local GRID_GAP_X = 52   -- horizontal spacing between button origins
        local GRID_GAP_Y = 42   -- vertical spacing between button origins
        local TAB_HEADER_H = 28

        local idx = 0
        local yOffset = 0

        for tab = 1, numTabs do
            local tabName = tabInfo[tab].name
            local tabPts  = tabInfo[tab].pts
            if tabPts > 0 then
                -- Count learned talents in this tab
                local numTalents = GetNumTalents(tab, useInspect) or 0
                local learnedCount = 0
                local maxTier = 0

                -- First pass: find learned talents and max tier
                local learned = {}
                for ti = 1, numTalents do
                    local name, iconTex, tier, col, curRank, maxRank = GetTalentInfo(tab, ti, useInspect)
                    if name and curRank and curRank > 0 then
                        learned[#learned + 1] = { ti = ti, name = name, icon = iconTex, tier = tier, col = col, rank = curRank, maxRank = maxRank }
                        if tier and tier > maxTier then maxTier = tier end
                        learnedCount = learnedCount + 1
                    end
                end

                if learnedCount > 0 then
                    -- Show all talents in this tab (learned = full color, unlearned = dim)
                    for ti = 1, numTalents do
                        local name, iconTex, tier, col, curRank, maxRank = GetTalentInfo(tab, ti, useInspect)
                        if name and iconTex and tier and col and idx < MAX_TALENT_BTNS then
                            idx = idx + 1
                            local btn = talentBtns[idx]
                            btn:ClearAllPoints()
                            btn:SetPoint("TOPLEFT", talentGrid, "TOPLEFT",
                                col * GRID_GAP_X,
                                -(yOffset + tier * GRID_GAP_Y))
                            btn.icon:SetTexture(iconTex)

                            if curRank and curRank > 0 then
                                btn.icon:SetDesaturated(false)
                                btn.icon:SetAlpha(1)
                                if curRank >= maxRank then
                                    btn.bg:SetTexture(0.85, 0.68, 0.00)
                                    btn.glow:SetVertexColor(0.85, 0.68, 0.00)
                                    btn.glow:SetAlpha(0.5)
                                    btn.glow:Show()
                                else
                                    btn.bg:SetTexture(0.00, 0.70, 0.00)
                                    btn.glow:SetVertexColor(0.00, 0.80, 0.00)
                                    btn.glow:SetAlpha(0.4)
                                    btn.glow:Show()
                                end
                                btn.spellName = name .. "  " .. curRank .. "/" .. maxRank
                            else
                                btn.icon:SetDesaturated(true)
                                btn.icon:SetAlpha(0.35)
                                btn.bg:SetTexture(0.13, 0.13, 0.15)
                                btn.glow:Hide()
                                btn.spellName = "|cff888888" .. name .. "|r  0/" .. maxRank
                            end
                            btn:Show()
                        end
                    end
                    yOffset = yOffset + (maxTier + 1) * GRID_GAP_Y + 12
                end
            end
        end

        if idx > 0 then
            talentEmpty:Hide()
        else
            talentEmpty:SetText("|cffaaaaaa" .. unitName .. " has no talents.|r")
            talentEmpty:Show()
        end
    end

    --------------------------------------------------------------------------
    -- Show bot model via SetUnit (only works when spawned/in party)
    --------------------------------------------------------------------------
    local function ShowBotModel(name, class, level)
        local unitId = GetUnitIdByName(name)
        if unitId then
            centerModel:SetUnit(unitId)
        else
            centerModel:ClearModel()
        end
        local className = CLASS_NAMES[class] or "Unknown"
        local classColor = CLASS_COLORS[class] or "ffffffff"
        centerName:SetText("|cffffd700" .. name .. "|r")
        centerInfo:SetText("|c" .. classColor .. className .. "|r  Level " .. level)
        titleText:SetText("|cffffd100" .. name .. "|r")
    end

    -- Expose global update functions
    _G.SurrealArmyShowBotModel = ShowBotModel

    -- Listen for inspect talent data to arrive
    local inspectEventFrame = CreateFrame("Frame")
    inspectEventFrame:RegisterEvent("INSPECT_TALENT_READY")
    inspectEventFrame:SetScript("OnEvent", function()
        if inspectingBotName and armyFrame:IsShown() then
            UpdateTalentDisplay(inspectingBotName, true)
        elseif selectedSlot and armyFrame:IsShown() and selectedSlot.index == 1 then
            UpdateTalentDisplay(UnitName("player"), false)
        end
    end)

    -- Dismiss All button to the left of slot 1
    local dismissAllBtn = CreateFrame("Button", nil, armyFrame)
    dismissAllBtn:SetSize(36, 36)
    dismissAllBtn:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    dismissAllBtn:SetBackdropColor(0.4, 0.1, 0.1, 0.9)
    dismissAllBtn:SetBackdropBorderColor(0.6, 0.2, 0.2, 1)

    local dismissIcon = dismissAllBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    dismissIcon:SetPoint("CENTER", dismissAllBtn, "CENTER", 0, 0)
    dismissIcon:SetText("|cffff4444X|r")

    local dismissLabel = dismissAllBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    dismissLabel:SetPoint("TOP", dismissAllBtn, "BOTTOM", 0, -2)
    dismissLabel:SetText("|cffff6666Dismiss|r")

    dismissAllBtn:SetScript("OnClick", function()
        AIO.Handle("SurrealArmy", "DismissBot", "")
        -- Reset all alt slots to empty
        if _G.SurrealArmyBotSlots then
            for i = 2, MAX_BOTS do
                local s = _G.SurrealArmyBotSlots[i]
                if s then
                    s.isSpawned = false
                    if s.model then s.model:Hide() end
                    if s.ddText then s.ddText:SetText("Select Alt") end
                    if s.spawnBtn then s.spawnBtn:Hide() end
                    if s.dismissBtn then s.dismissBtn:Hide() end
                    if s.emptyText then s.emptyText:Show() end
                    if s.spawnedName then s.spawnedName:Hide() end
                    if s.ddBtn then s.ddBtn:Show() end
                    s.selectedAlt = nil
                end
            end
        end
    end)
    dismissAllBtn:SetScript("OnEnter", function()
        dismissAllBtn:SetBackdropColor(0.6, 0.15, 0.15, 1)
    end)
    dismissAllBtn:SetScript("OnLeave", function()
        dismissAllBtn:SetBackdropColor(0.4, 0.1, 0.1, 0.9)
    end)

    -- Bot slots at bottom - centered
    local botSlots = {}
    _G.SurrealArmyBotSlots = botSlots  -- Make globally accessible for handlers
    
    local totalWidth = (SLOT_W * MAX_BOTS) + (SLOT_GAP * (MAX_BOTS - 1))
    local startX = (FRAME_W - totalWidth) / 2
    
    for i = 1, MAX_BOTS do
        local slot = CreateFrame("Button", nil, armyFrame)
        slot:SetSize(SLOT_W, SLOT_H)
        slot:SetPoint("BOTTOMLEFT", armyFrame, "BOTTOMLEFT", startX + (i-1)*(SLOT_W+SLOT_GAP), 20)
        slot.index = i
        slot.isSelected = false
        slot.centerModel = centerModel
        slot.centerName = centerName

        -- Make slot button invisible by default
        slot:SetNormalTexture("")
        slot:SetPushedTexture("")
        slot:SetHighlightTexture("")

        -- Create a backdrop frame for the slot
        local backdrop = CreateFrame("Frame", nil, slot)
        backdrop:SetAllPoints(slot)
        backdrop:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        backdrop:SetBackdropColor(0.08, 0.08, 0.12, 0.95)
        backdrop:SetBackdropBorderColor(0.30, 0.30, 0.35, 1)
        slot.backdrop = backdrop

        -- First slot is always the player character
        if i == 1 then
            local label = slot:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            label:SetPoint("TOP", slot, "TOP", 0, -5)
            label:SetText("|cffffd700" .. (UnitName("player") or "Player") .. "|r")

            local model = CreateFrame("PlayerModel", nil, slot)
            model:SetPoint("TOP", label, "BOTTOM", 0, -5)
            model:SetSize(70, 80)
            model:SetUnit("player")
            slot.model = model
            slot.altGuid = nil  -- No guid for player
        else
            -- Other slots have integrated dropdown button
            local ddBtn = CreateFrame("Button", nil, slot)
            ddBtn:SetSize(100, 16)
            ddBtn:SetPoint("TOP", slot, "TOP", 0, -5)
            ddBtn:SetBackdrop({
                bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = true, tileSize = 8, edgeSize = 8,
                insets = { left = 2, right = 2, top = 2, bottom = 2 },
            })
            ddBtn:SetBackdropColor(0.1, 0.1, 0.15, 0.8)
            ddBtn:SetBackdropBorderColor(0.2, 0.2, 0.25, 1)

            local ddText = ddBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            ddText:SetPoint("CENTER", ddBtn, "CENTER", -20, 0)
            ddText:SetText("Select Alt")
            slot.ddText = ddText

            -- Dropdown menu
            local dd = CreateFrame("Frame", "SurrealArmyDropdown" .. i, UIParent)
            dd:SetFrameStrata("DIALOG")
            dd:SetBackdrop({
                bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = true, tileSize = 16, edgeSize = 12,
                insets = { left = 3, right = 3, top = 3, bottom = 3 },
            })
            dd:SetBackdropColor(0.08, 0.08, 0.12, 0.98)
            dd:SetBackdropBorderColor(0.30, 0.30, 0.35, 1)
            dd:Hide()
            dd:SetSize(120, 100)
            dd:SetPoint("TOP", ddBtn, "BOTTOM", 0, -2)
            slot.ddMenu = dd

            -- Dropdown button click handler
            ddBtn:SetScript("OnClick", function()
                if slot.ddMenu:IsShown() then
                    slot.ddMenu:Hide()
                else
                    slot.ddMenu:Show()
                    -- Hide spawn button when opening dropdown
                    if slot.spawnBtn then
                        slot.spawnBtn:Hide()
                    end
                end
            end)

            local model = CreateFrame("PlayerModel", nil, slot)
            model:SetPoint("TOP", ddBtn, "BOTTOM", 0, -5)
            model:SetSize(70, 80)
            model:Hide()  -- Hidden until spawned
            slot.model = model
            slot.ddBtn = ddBtn
            slot.altGuid = nil
            slot.isSpawned = false

            -- Empty slot indicator
            local emptyText = slot:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            emptyText:SetPoint("CENTER", slot, "CENTER", 0, 5)
            emptyText:SetText("|cff666666Empty|r")
            slot.emptyText = emptyText

            -- Spawn button for alt slots
            local spawnBtn = CreateFrame("Button", nil, slot)
            spawnBtn:SetSize(90, 18)
            spawnBtn:SetPoint("BOTTOM", slot, "BOTTOM", 0, 5)
            spawnBtn:SetBackdrop({
                bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = true, tileSize = 8, edgeSize = 8,
                insets = { left = 2, right = 2, top = 2, bottom = 2 },
            })
            spawnBtn:SetBackdropColor(0.1, 0.3, 0.1, 0.8)
            spawnBtn:SetBackdropBorderColor(0.2, 0.5, 0.2, 1)

            local spawnText = spawnBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            spawnText:SetPoint("CENTER", spawnBtn, "CENTER")
            spawnText:SetText("Spawn")
            spawnBtn.text = spawnText

            -- Per-slot dismiss button (hidden by default, shown after spawn)
            local dismissBtn = CreateFrame("Button", nil, slot)
            dismissBtn:SetSize(90, 18)
            dismissBtn:SetPoint("BOTTOM", slot, "BOTTOM", 0, 5)
            dismissBtn:SetBackdrop({
                bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = true, tileSize = 8, edgeSize = 8,
                insets = { left = 2, right = 2, top = 2, bottom = 2 },
            })
            dismissBtn:SetBackdropColor(0.4, 0.1, 0.1, 0.8)
            dismissBtn:SetBackdropBorderColor(0.6, 0.2, 0.2, 1)
            dismissBtn:Hide()

            local dismissText = dismissBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            dismissText:SetPoint("CENTER", dismissBtn, "CENTER")
            dismissText:SetText("|cffff6666Dismiss|r")

            -- Dismiss button click handler
            dismissBtn:SetScript("OnClick", function()
                local altName = slot.ddText:GetText()
                if altName and altName ~= "Select Alt" then
                    AIO.Handle("SurrealArmy", "DismissBot", altName)
                end
                -- Reset slot to empty state
                slot.isSpawned = false
                dismissBtn:Hide()
                if slot.model then slot.model:Hide() end
                if slot.emptyText then slot.emptyText:Show() end
                if slot.spawnedName then slot.spawnedName:Hide() end
                if slot.ddBtn then slot.ddBtn:Show() end
                slot.ddText:SetText("Select Alt")
                slot.selectedAlt = nil
            end)
            dismissBtn:SetScript("OnEnter", function()
                dismissBtn:SetBackdropColor(0.6, 0.15, 0.15, 1)
            end)
            dismissBtn:SetScript("OnLeave", function()
                dismissBtn:SetBackdropColor(0.4, 0.1, 0.1, 0.8)
            end)
            slot.dismissBtn = dismissBtn

            -- Spawned character name label (hidden until spawned)
            local spawnedName = slot:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            spawnedName:SetPoint("TOP", slot.model, "BOTTOM", 0, -2)
            spawnedName:Hide()
            slot.spawnedName = spawnedName

            -- Spawn button click handler
            spawnBtn:SetScript("OnClick", function()
                local altName = slot.ddText:GetText()
                if altName and altName ~= "Select Alt" then
                    AIO.Handle("SurrealArmy", "SpawnBot", altName)
                    slot.isSpawned = true
                    spawnBtn:Hide()
                    dismissBtn:Show()
                    -- Hide dropdown button and empty text, show model
                    if slot.ddBtn then slot.ddBtn:Hide() end
                    if slot.emptyText then slot.emptyText:Hide() end
                    -- Show character name
                    if slot.spawnedName then
                        slot.spawnedName:SetText("|cffffd700" .. altName .. "|r")
                        slot.spawnedName:Show()
                    end
                    -- Load model after 1s delay so the bot has time to join the party
                    local altNameForTimer = altName
                    local altClassForTimer = slot.altClass or 0
                    local altLevelForTimer = slot.altLevel or 0
                    local altGuidForTimer = slot.selectedAlt
                    local timer = CreateFrame("Frame")
                    timer.elapsed = 0
                    timer:SetScript("OnUpdate", function(self, dt)
                        self.elapsed = self.elapsed + dt
                        if self.elapsed >= 1.0 then
                            self:SetScript("OnUpdate", nil)
                            ShowBotModel(altNameForTimer, altClassForTimer, altLevelForTimer)
                            -- Show slot thumbnail model
                            local unitId = GetUnitIdByName(altNameForTimer)
                            if unitId and slot.model then
                                slot.model:SetUnit(unitId)
                                slot.model:Show()
                            end
                            -- Inspect for talents
                            local inspUnit = GetUnitIdByName(altNameForTimer)
                            if inspUnit then
                                inspectingBotName = altNameForTimer
                                inspectingBotUnit = inspUnit
                                NotifyInspect(inspUnit)
                            end
                        end
                    end)
                    if slot.emptyText then slot.emptyText:Hide() end
                end
            end)

            spawnBtn:SetScript("OnEnter", function()
                spawnBtn:SetBackdropColor(0.15, 0.4, 0.15, 1)
            end)

            spawnBtn:SetScript("OnLeave", function()
                spawnBtn:SetBackdropColor(0.1, 0.3, 0.1, 0.8)
            end)

            slot.spawnBtn = spawnBtn
        end

        -- Slot click handler - update center display, target bot, highlight
        slot:SetScript("OnClick", function(self)
            -- Deselect previous slot
            if selectedSlot and selectedSlot ~= self then
                selectedSlot.isSelected = false
                selectedSlot.backdrop:SetBackdropBorderColor(0.30, 0.30, 0.35, 1)
            end
            -- Select this slot
            self.isSelected = true
            selectedSlot = self
            self.backdrop:SetBackdropBorderColor(0.00, 1.00, 0.00, 1)  -- Green highlight

            -- Update center display
            if self.index == 1 then
                -- Player character
                centerModel:SetUnit("player")
                local playerName = UnitName("player") or "Player"
                local playerLevel = UnitLevel("player")
                centerName:SetText("|cffffd700" .. playerName .. "|r")
                centerInfo:SetText("Level " .. playerLevel)
                titleText:SetText("|cffffd100" .. playerName .. "|r")
                UpdateTalentDisplay(playerName, false)
            else
                local altName = self.ddText:GetText()
                local altGuid = self.selectedAlt
                if altName and altName ~= "Select Alt" then
                    local altClass = self.altClass or 0
                    local altLevel = self.altLevel or 0
                    if self.isSpawned then
                        -- Bot is in party — show full model + inspect for talents
                        ShowBotModel(altName, altClass, altLevel)
                        local unitId = GetUnitIdByName(altName)
                        if unitId then
                            inspectingBotName = altName
                            inspectingBotUnit = unitId
                            NotifyInspect(unitId)
                        end
                    else
                        -- Not spawned — show info text only, no model
                        local className = CLASS_NAMES[altClass] or "Unknown"
                        local classColor = CLASS_COLORS[altClass] or "ffffffff"
                        centerModel:ClearModel()
                        centerName:SetText("|cffffd700" .. altName .. "|r")
                        centerInfo:SetText("|c" .. classColor .. className .. "|r  Level " .. altLevel .. "  |cff888888(not spawned)|r")
                        titleText:SetText("|cffffd100" .. altName .. "|r")
                    end
                    -- Talents: only show via inspect if spawned
                    if self.isSpawned then
                        UpdateTalentDisplay(altName, true)
                    else
                        UpdateTalentDisplay(nil)
                    end
                else
                    centerName:SetText("")
                    centerInfo:SetText("")
                    titleText:SetText("|cffffd100Select a Character|r")
                    centerModel:ClearModel()
                    UpdateTalentDisplay(nil)
                end
            end
        end)

        botSlots[i] = slot
    end

    -- Position dismiss button to the left of slot 1
    dismissAllBtn:SetPoint("RIGHT", botSlots[1], "LEFT", -10, 0)

    -- Populate integrated dropdowns with alts
    local function PopulateArmyDropdown(slot, altList)
        local ddMenu = slot.ddMenu
        local ddBtn = slot.ddBtn
        
        -- Clear previous buttons if any
        for idx = 1, #ddMenu do
            if ddMenu[idx] then
                ddMenu[idx]:Hide()
            end
        end
        
        local btnHeight = 18
        -- alt format: {guid, name, level, class}
        for idx, alt in ipairs(altList) do
            local altName = alt[2] or alt.name or "Unknown"
            local altGuid = alt[1] or alt.guid or 0
            local btn = CreateFrame("Button", nil, ddMenu)
            btn:SetSize(114, btnHeight)
            btn:SetPoint("TOPLEFT", ddMenu, "TOPLEFT", 3, -3 - (idx-1)*btnHeight)
            btn:SetText(altName)
            btn:SetNormalFontObject("GameFontNormalSmall")
            
            btn:SetScript("OnClick", function()
                slot.ddText:SetText(altName)
                slot.selectedAlt = altGuid
                slot.altClass = alt[4] or 0
                slot.altLevel = alt[3] or 0
                ddMenu:Hide()
                -- Show spawn button when alt is selected (only if not already spawned)
                if slot.spawnBtn and not slot.isSpawned then
                    slot.spawnBtn:Show()
                end
            end)
            
            btn:SetScript("OnEnter", function()
                btn:SetBackdropColor(0.2, 0.2, 0.3, 1)
            end)
            
            btn:SetScript("OnLeave", function()
                btn:SetBackdropColor(0, 0, 0, 0)
            end)
        end
        
        -- Resize menu to fit items
        local menuHeight = math.min(#altList * btnHeight + 6, 150)
        ddMenu:SetHeight(menuHeight)
    end
    
    -- Make globally accessible for ReceiveAlts handler
    _G.PopulateSurrealArmyDropdown = PopulateArmyDropdown

    -- Hide spawn buttons initially (dropdowns populated when alts received from server)
    for i = 2, MAX_BOTS do
        if botSlots[i].spawnBtn then
            botSlots[i].spawnBtn:Hide()
        end
    end

    -- Show/hide toggle
    SLASH_SURREALARMY1 = "/army"
    SlashCmdList["SURREALARMY"] = function()
        if armyFrame:IsShown() then
            armyFrame:Hide()
        else
            armyFrame:Show()
        end
    end

    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SurrealUI]|r Bot army panel loaded.")
end

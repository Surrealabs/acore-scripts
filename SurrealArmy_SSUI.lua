local SSUI = SSUI or require("SSUI")

if SSUI.AddAddon() then
    -- SERVER SIDE
    local Handlers = SSUI.AddHandlers("SurrealArmy", {})

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
        
        SSUI.Handle(player, "SurrealArmy", "ReceiveAlts", altStr)
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

    -- ─── Bags tab: inventory / gear management ─────────────────────────────
    function Handlers.RequestBotInventory(player, targetName)
        if not player or not targetName or targetName == "" then
            return
        end

        local target
        if targetName == player:GetName() then
            target = player
        else
            target = GetPlayerByName(targetName)
        end

        if not target then
            SSUI.Handle(player, "SurrealArmy", "ReceiveBotInventory", targetName, "", "")
            return
        end

        -- Equipped items: slots 0-18
        local equipParts = {}
        for slot = 0, 18 do
            local item = target:GetItemByPos(255, slot)
            if item then
                equipParts[#equipParts + 1] = slot .. ":" .. item:GetEntry() .. ":" .. item:GetCount()
            end
        end

        -- Bag items: backpack (255, slots 23-38) + 4 equipped bags (19-22, slots 0-35)
        local bagParts = {}
        for slot = 23, 38 do
            local item = target:GetItemByPos(255, slot)
            if item then
                bagParts[#bagParts + 1] = "255:" .. slot .. ":" .. item:GetEntry() .. ":" .. item:GetCount()
            end
        end
        for bag = 19, 22 do
            for slot = 0, 35 do
                local item = target:GetItemByPos(bag, slot)
                if item then
                    bagParts[#bagParts + 1] = bag .. ":" .. slot .. ":" .. item:GetEntry() .. ":" .. item:GetCount()
                end
            end
        end

        SSUI.Handle(player, "SurrealArmy", "ReceiveBotInventory", targetName,
                   table.concat(equipParts, "|"), table.concat(bagParts, "|"))
    end

    function Handlers.EquipBotItem(player, botName, bag, slot)
        if not player or not botName then
            return
        end
        player:RunCommand("army equipitem " .. botName .. " " .. bag .. " " .. slot)
    end

    function Handlers.UnequipBotItem(player, botName, slot)
        if not player or not botName then
            return
        end
        player:RunCommand("army unequip " .. botName .. " " .. slot)
    end

    function Handlers.AutoEquipBot(player, botName)
        if not player or not botName then
            return
        end
        player:RunCommand("army equip " .. botName)
    end
else
    -- CLIENT SIDE
    local ArmyHandlers = SSUI.AddHandlers("SurrealArmy", {})
    
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
        SSUI.Handle("SurrealArmy", "RequestAlts")

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

    -- Track who the Character/Bags tabs are currently showing gear for, and
    -- whether it's an interactive bot (equip/unequip enabled) vs. read-only
    -- (the master's own character).
    local bagsCurrentName = nil
    local bagsCurrentInteractive = false

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

    local centerName = centerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    centerName:SetPoint("TOP", centerFrame, "TOP", 0, -10)
    centerName:SetText("|cffffd700" .. (UnitName("player") or "Player") .. "|r")

    -- Level & class info under name
    local centerInfo = centerFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    centerInfo:SetPoint("TOP", centerName, "BOTTOM", 0, -4)
    centerInfo:SetText("")

    local centerModel = CreateFrame("DressUpModel", nil, centerFrame)
    centerModel:SetSize(280, 330)
    centerModel:SetPoint("TOP", centerInfo, "BOTTOM", 0, -20)
    centerModel:SetUnit("player")

    -- ── Equipped gear — paperdoll-style left/right/bottom slot columns ──
    -- Same spacing convention as SurrealCharacter_SSUI.lua's equipment slots.
    local SLOT_SIZE = 40
    local SLOT_GAP  = 6
    local SLOT_STEP = SLOT_SIZE + SLOT_GAP

    -- { label, slotString (for default icon lookup), server equipment slot }
    local LEFT_SLOTS = {
        { "Head",     "HeadSlot",     0  },
        { "Neck",     "NeckSlot",     1  },
        { "Shoulder", "ShoulderSlot", 2  },
        { "Back",     "BackSlot",     14 },
        { "Chest",    "ChestSlot",    4  },
        { "Shirt",    "ShirtSlot",    3  },
        { "Tabard",   "TabardSlot",   18 },
        { "Wrist",    "WristSlot",    8  },
    }
    local RIGHT_SLOTS = {
        { "Hands",     "HandsSlot",    9  },
        { "Waist",     "WaistSlot",    5  },
        { "Legs",      "LegsSlot",     6  },
        { "Feet",      "FeetSlot",     7  },
        { "Ring 1",    "Finger0Slot",  10 },
        { "Ring 2",    "Finger1Slot",  11 },
        { "Trinket 1", "Trinket0Slot", 12 },
        { "Trinket 2", "Trinket1Slot", 13 },
    }
    local BOTTOM_SLOTS = {
        { "Main Hand", "MainHandSlot",       15 },
        { "Off Hand",  "SecondaryHandSlot",  16 },
        { "Ranged",    "RangedSlot",         17 },
    }

    local equipBtns = {}

    local function CreateArmyEquipSlot(label, slotString, serverSlot, xOff, yOff)
        local _, defaultTex = GetInventorySlotInfo(slotString)

        local btn = CreateFrame("Button", nil, centerFrame)
        btn:SetSize(SLOT_SIZE, SLOT_SIZE)
        btn:SetPoint("TOP", centerModel, "TOP", xOff, yOff)
        btn.slot = serverSlot
        btn.slotLabel = label

        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(defaultTex or "Interface\\PaperDoll\\UI-PaperDoll-Slot-Chest")
        bg:SetAlpha(0.5)
        btn.bg = bg

        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints()
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        icon:Hide()
        btn.icon = icon

        local border = CreateFrame("Frame", nil, btn)
        border:SetPoint("TOPLEFT", -3, 3)
        border:SetPoint("BOTTOMRIGHT", 3, -3)
        border:SetBackdrop({
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        border:SetBackdropBorderColor(0.3, 0.3, 0.3, 0)
        btn.border = border

        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
        hl:SetBlendMode("ADD")
        hl:SetAlpha(0.3)

        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if self.entry then
                GameTooltip:SetHyperlink("item:" .. self.entry)
            else
                GameTooltip:SetText(self.slotLabel, 1, 1, 1)
                GameTooltip:AddLine("Empty slot", 0.5, 0.5, 0.5)
            end
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        btn:SetScript("OnClick", function(self)
            if self.entry and bagsCurrentInteractive and bagsCurrentName then
                SSUI.Handle("SurrealArmy", "UnequipBotItem", bagsCurrentName, self.slot)
                local t = CreateFrame("Frame")
                t.elapsed = 0
                t:SetScript("OnUpdate", function(f, dt)
                    f.elapsed = f.elapsed + dt
                    if f.elapsed >= 0.4 then
                        f:SetScript("OnUpdate", nil)
                        SSUI.Handle("SurrealArmy", "RequestBotInventory", bagsCurrentName)
                    end
                end)
            end
        end)

        btn:Hide()
        equipBtns[serverSlot] = btn
        return btn
    end

    -- Left column (hugging left side of the 3D model)
    local leftColX  = -(SLOT_SIZE / 2) - 8
    local rightColX = (SLOT_SIZE / 2) + 8
    for i, s in ipairs(LEFT_SLOTS) do
        CreateArmyEquipSlot(s[1], s[2], s[3], leftColX - centerModel:GetWidth()/2, -(i - 1) * SLOT_STEP)
    end
    -- Right column (hugging right side of the 3D model)
    for i, s in ipairs(RIGHT_SLOTS) do
        CreateArmyEquipSlot(s[1], s[2], s[3], rightColX + centerModel:GetWidth()/2 - SLOT_SIZE, -(i - 1) * SLOT_STEP)
    end
    -- Bottom weapons (centered under the model)
    local wepY = -(8 * SLOT_STEP) - 16
    local wepStart = -(3 * SLOT_SIZE + 2 * 10) / 2
    for i, s in ipairs(BOTTOM_SLOTS) do
        CreateArmyEquipSlot(s[1], s[2], s[3], wepStart + (i - 1) * (SLOT_SIZE + 10), wepY)
    end

    -- Talents panel (hidden by default)
    local talentPanel = CreateFrame("Frame", nil, armyFrame)
    talentPanel:SetSize(760, 520)
    talentPanel:SetPoint("CENTER", armyFrame, "CENTER", -30, 10)
    talentPanel:Hide()

    local talentTitle = talentPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    talentTitle:SetPoint("TOP", talentPanel, "TOP", 0, -6)
    talentTitle:SetText("|cffffd100Talents|r")

    -- Opens the real talent builder (same frame/UI you use for yourself)
    -- retargeted at whichever character is currently selected, so you can
    -- actually spend/reset points instead of just viewing them here. Closes
    -- the Army panel so the two frames don't sit on top of each other.
    local editBuildBtn = CreateFrame("Button", nil, talentPanel, "UIPanelButtonTemplate")
    editBuildBtn:SetSize(140, 24)
    editBuildBtn:SetPoint("TOPRIGHT", talentPanel, "TOPRIGHT", -10, -10)
    editBuildBtn:SetText("Edit Full Build")
    editBuildBtn:SetScript("OnClick", function()
        if not selectedSlot or not _G.SurrealTalentFrame_OpenFor then return end
        local opened = false
        if selectedSlot.index == 1 then
            _G.SurrealTalentFrame_OpenFor(UnitName("player") or "Player", nil)
            opened = true
        elseif selectedSlot.isSpawned then
            local altName = selectedSlot.ddText and selectedSlot.ddText:GetText()
            if altName and altName ~= "Select Alt" then
                _G.SurrealTalentFrame_OpenFor(altName, selectedSlot.altClass or 0)
                opened = true
            end
        end
        if opened then
            armyFrame:Hide()
        end
    end)

    -- ── Zone layout — mirrors SurrealTalentFrame_SSUI.lua's class/spec/hero
    -- tree split so this preview lines up the same way as the real editor.
    local SPEC_COL_START  = 3
    local SPEC_COLS       = 7
    local SIDE_ROWS       = 5
    local SIDE_COLS       = 3
    local HERO2_ROW_START = 5

    local function IsIgnoredCorner(localRow, localCol)
        if localRow < 1 or localCol < 1 then return false end
        if localCol ~= 1 and localCol ~= SIDE_COLS then return false end
        return localRow == 1 or localRow == SIDE_ROWS
    end

    -- Returns zone, localRow, localCol for a talent def (row/col are 1-based
    -- global grid coordinates from SURREAL_TALENT_TREES).
    local function TalentZone(def)
        local row, col = def.row, def.col
        if not row or not col then return nil end

        if row >= 1 and row <= SIDE_ROWS and col >= 1 and col <= SIDE_COLS then
            if IsIgnoredCorner(row, col) then return nil end
            return "class", row, col
        end

        if row >= 1 and col > SPEC_COL_START and col <= (SPEC_COL_START + SPEC_COLS) then
            return "spec", row, col - SPEC_COL_START
        end

        local heroColStart = SPEC_COL_START + SPEC_COLS
        if col > heroColStart and col <= (heroColStart + SIDE_COLS) then
            local heroCol = col - heroColStart
            if row >= 1 and row <= SIDE_ROWS then
                if IsIgnoredCorner(row, heroCol) then return nil end
                return "hero1", row, heroCol
            end
            if row > HERO2_ROW_START and row <= (HERO2_ROW_START + SIDE_ROWS) then
                local hero2Row = row - HERO2_ROW_START
                if IsIgnoredCorner(hero2Row, heroCol) then return nil end
                return "hero2", hero2Row, heroCol
            end
        end

        return nil
    end

    -- Section headers (class tree / spec / hero trees)
    local classHeader = talentPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    classHeader:SetText("|cffaaaaccClass Tree|r")
    local specHeader = talentPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    local heroHeader = talentPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    heroHeader:SetText("|cffaaaaccHero Trees|r")

    -- Talent icon grid — pool of reusable icon buttons
    local TALENT_BTN_SIZE = 30
    local TALENT_BTN_GAP  = 4
    local TALENT_STEP     = TALENT_BTN_SIZE + TALENT_BTN_GAP
    local MAX_TALENT_BTNS = 90
    local talentBtns = {}

    -- Zone x-origins within talentGrid (class | spec | hero, left-to-right)
    local ZONE_GAP  = 20
    local classZoneX = 0
    local specZoneX  = SIDE_COLS * TALENT_STEP + ZONE_GAP
    local heroZoneX  = specZoneX + SPEC_COLS * TALENT_STEP + ZONE_GAP

    local talentGrid = CreateFrame("Frame", nil, talentPanel)
    talentGrid:SetSize(heroZoneX + SIDE_COLS * TALENT_STEP, 400)
    talentGrid:SetPoint("TOP", talentTitle, "BOTTOM", 0, -34)

    classHeader:SetPoint("BOTTOMLEFT", talentGrid, "TOPLEFT", classZoneX, 6)
    specHeader:SetPoint("BOTTOMLEFT", talentGrid, "TOPLEFT", specZoneX, 6)
    heroHeader:SetPoint("BOTTOMLEFT", talentGrid, "TOPLEFT", heroZoneX, 6)

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

    local bagsEmpty = bagsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    bagsEmpty:SetPoint("CENTER", bagsPanel, "CENTER", 0, 0)
    bagsEmpty:SetText("|cffaaaaaaSelect a spawned character to view their gear.|r")

    -- ── Bag contents grid ───────────────────────────────────────────────
    local BAG_BTN_SIZE = 30
    local BAG_COLS      = 12
    local MAX_BAG_BTNS  = 96

    local bagSectionTitle = bagsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bagSectionTitle:SetPoint("TOPLEFT", bagsTitle, "BOTTOMLEFT", -290, -14)
    bagSectionTitle:SetText("|cffffd700Bags|r")

    local bagGrid = CreateFrame("Frame", nil, bagsPanel)
    bagGrid:SetPoint("TOPLEFT", bagSectionTitle, "BOTTOMLEFT", 0, -6)
    bagGrid:SetSize(BAG_COLS * (BAG_BTN_SIZE + 3), 300)

    local bagBtns = {}
    for i = 1, MAX_BAG_BTNS do
        local btn = CreateFrame("Button", nil, bagGrid)
        btn:SetSize(BAG_BTN_SIZE, BAG_BTN_SIZE)
        btn:SetPoint("TOPLEFT", bagGrid, "TOPLEFT",
            ((i - 1) % BAG_COLS) * (BAG_BTN_SIZE + 3),
            -math.floor((i - 1) / BAG_COLS) * (BAG_BTN_SIZE + 3))

        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints()
        btn.icon = icon

        local countText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        countText:SetPoint("BOTTOMRIGHT", -1, 1)
        btn.countText = countText

        btn:SetScript("OnEnter", function(self)
            if self.entry then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink("item:" .. self.entry)
                GameTooltip:Show()
            end
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        btn:SetScript("OnClick", function(self)
            if self.entry and bagsCurrentInteractive and bagsCurrentName then
                SSUI.Handle("SurrealArmy", "EquipBotItem", bagsCurrentName, self.bag, self.slot)
                local t = CreateFrame("Frame")
                t.elapsed = 0
                t:SetScript("OnUpdate", function(f, dt)
                    f.elapsed = f.elapsed + dt
                    if f.elapsed >= 0.4 then
                        f:SetScript("OnUpdate", nil)
                        SSUI.Handle("SurrealArmy", "RequestBotInventory", bagsCurrentName)
                    end
                end)
            end
        end)

        btn:Hide()
        bagBtns[i] = btn
    end

    -- ── Auto-Equip Best button ──────────────────────────────────────────
    local autoEquipBtn = CreateFrame("Button", nil, bagsPanel, "UIPanelButtonTemplate")
    autoEquipBtn:SetSize(140, 24)
    autoEquipBtn:SetPoint("TOPLEFT", bagSectionTitle, "TOPRIGHT", 200, 4)
    autoEquipBtn:SetText("Auto-Equip Best")
    autoEquipBtn:SetScript("OnClick", function()
        if bagsCurrentInteractive and bagsCurrentName then
            SSUI.Handle("SurrealArmy", "AutoEquipBot", bagsCurrentName)
            local t = CreateFrame("Frame")
            t.elapsed = 0
            t:SetScript("OnUpdate", function(f, dt)
                f.elapsed = f.elapsed + dt
                if f.elapsed >= 0.5 then
                    f:SetScript("OnUpdate", nil)
                    SSUI.Handle("SurrealArmy", "RequestBotInventory", bagsCurrentName)
                end
            end)
        end
    end)
    autoEquipBtn:Hide()

    -- Populate the Bags tab from parsed inventory strings
    local function UpdateBagsDisplay(name, interactive, equipStr, bagStr)
        bagsCurrentName = name
        bagsCurrentInteractive = interactive or false

        for i = 0, 18 do equipBtns[i]:Hide() end
        for i = 1, MAX_BAG_BTNS do bagBtns[i]:Hide() end
        autoEquipBtn:Hide()

        if not name then
            bagsEmpty:SetText("|cffaaaaaaSelect a spawned character to view their gear.|r")
            bagsEmpty:Show()
            return
        end

        if not equipStr and not bagStr then
            -- Waiting on server response
            bagsEmpty:SetText("|cffaaaaaaLoading gear for " .. name .. "...|r")
            bagsEmpty:Show()
            return
        end

        if equipStr == "" and bagStr == "" then
            bagsEmpty:SetText("|cffff6666" .. name .. " is not in the world (spawn them first).|r")
            bagsEmpty:Show()
            return
        end

        bagsEmpty:Hide()
        if bagsCurrentInteractive then
            autoEquipBtn:Show()
        end

        if equipStr and equipStr ~= "" then
            for part in equipStr:gmatch("[^|]+") do
                local slot, entry, count = part:match("^(%d+):(%d+):(%d+)$")
                slot = tonumber(slot)
                entry = tonumber(entry)
                if slot and entry and equipBtns[slot] then
                    local btn = equipBtns[slot]
                    local _, _, _, _, _, _, _, _, _, tex = GetItemInfo(entry)
                    btn.icon:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")
                    btn.entry = entry
                    btn:Show()
                end
            end
        end

        if bagStr and bagStr ~= "" then
            local idx = 0
            for part in bagStr:gmatch("[^|]+") do
                local bag, slot, entry, count = part:match("^(%d+):(%d+):(%d+):(%d+)$")
                idx = idx + 1
                if idx <= MAX_BAG_BTNS and bag and slot and entry then
                    local btn = bagBtns[idx]
                    local _, _, _, _, _, _, _, _, _, tex = GetItemInfo(tonumber(entry))
                    btn.icon:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")
                    btn.entry = tonumber(entry)
                    btn.bag = tonumber(bag)
                    btn.slot = tonumber(slot)
                    count = tonumber(count) or 1
                    btn.countText:SetText(count > 1 and count or "")
                    btn:Show()
                end
            end
        end
    end
    _G.SurrealArmyUpdateBagsDisplay = UpdateBagsDisplay

    -- Ask the server for gear data for whichever character is selected
    local function RequestBagsFor(name, interactive)
        bagsCurrentName = name
        bagsCurrentInteractive = interactive
        if not name then
            UpdateBagsDisplay(nil)
            return
        end
        UpdateBagsDisplay(name, interactive, nil, nil) -- show "Loading..."
        SSUI.Handle("SurrealArmy", "RequestBotInventory", name)
    end
    _G.SurrealArmyRequestBagsFor = RequestBagsFor

    -- Server responded with gear data — only apply if still the active selection
    function ArmyHandlers.ReceiveBotInventory(player, targetName, equipStr, bagStr)
        if targetName == bagsCurrentName then
            UpdateBagsDisplay(targetName, bagsCurrentInteractive, equipStr, bagStr)
        end
    end

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
    -- TALENT DISPLAY — driven by the custom talent system (SURREAL_TALENT_TREES
    -- + server-pushed talent ranks). This server replaced Blizzard's native
    -- talent trees, so the native inspect-based talent API has no useful
    -- data; see SurrealTalentBridge_SSUI.lua for the equivalent server logic.
    --------------------------------------------------------------------------
    local talentsCurrentName = nil

    local function UpdateTalentDisplay(unitName, talents, classId)
        -- Hide all talent buttons/headers first
        for bi = 1, MAX_TALENT_BTNS do talentBtns[bi]:Hide() end
        classHeader:Hide()
        specHeader:Hide()
        heroHeader:Hide()

        if not unitName or unitName == "Select Alt" then
            talentEmpty:SetText("|cffaaaaaaSelect a character to view their talents.|r")
            talentEmpty:Show()
            talentTitle:SetText("|cffffd100Talents|r")
            return
        end
        talentTitle:SetText("|cffffd100" .. unitName .. " \226\128\148 Talents|r")

        if not talents then
            talentEmpty:SetText("|cffaaaaaa" .. unitName .. "'s talents loading...|r")
            talentEmpty:Show()
            return
        end

        local classTrees = SURREAL_TALENT_TREES and SURREAL_TALENT_TREES[classId]
        if not classTrees or not classTrees.tabs then
            talentEmpty:SetText("|cffaaaaaaNo talent data available.|r")
            talentEmpty:Show()
            return
        end

        -- Same as the real talent frame: show only the committed spec
        -- (whichever tab has the most points spent), not every tab at once.
        local bestTab, bestPts = nil, 0
        for _, tab in ipairs(classTrees.tabs) do
            local pts = 0
            for talentId in pairs(tab.talents or {}) do
                pts = pts + (tonumber(talents[talentId]) or 0)
            end
            if pts > bestPts then
                bestTab, bestPts = tab, pts
            end
        end

        if not bestTab then
            talentEmpty:SetText("|cffaaaaaa" .. unitName .. " has no talents spent yet.|r")
            talentEmpty:Show()
            return
        end
        talentEmpty:Hide()

        specHeader:SetText("|cffffd700" .. (bestTab.name or "Spec") .. "|r  (" .. bestPts .. " pts)")

        -- Classify this tab's talents into class/spec/hero1/hero2 zones
        local entries = {}
        local zoneUsed = { class = false, hero1 = false, hero2 = false }
        for talentId, def in pairs(bestTab.talents or {}) do
            local zone, lr, lc = TalentZone(def)
            if zone then
                entries[#entries + 1] = { id = talentId, def = def, zone = zone, lr = lr, lc = lc }
                if zoneUsed[zone] ~= nil then zoneUsed[zone] = true end
            end
        end

        if zoneUsed.class then classHeader:Show() else classHeader:Hide() end
        specHeader:Show()
        if zoneUsed.hero1 or zoneUsed.hero2 then heroHeader:Show() else heroHeader:Hide() end

        local idx = 0
        for _, e in ipairs(entries) do
            if idx < MAX_TALENT_BTNS then
                local rank = tonumber(talents[e.id]) or 0
                local maxRank = tonumber(e.def.maxRank) or 0
                local spellId = e.def.spells and e.def.spells[1]
                local name, iconTex
                if spellId then
                    name, _, iconTex = GetSpellInfo(spellId)
                end
                name = name or ("Talent " .. e.id)
                iconTex = iconTex or "Interface\\Icons\\INV_Misc_QuestionMark"

                local x, y
                if e.zone == "class" then
                    x, y = classZoneX + (e.lc - 1) * TALENT_STEP, (e.lr - 1) * TALENT_STEP
                elseif e.zone == "spec" then
                    x, y = specZoneX + (e.lc - 1) * TALENT_STEP, (e.lr - 1) * TALENT_STEP
                elseif e.zone == "hero1" then
                    x, y = heroZoneX + (e.lc - 1) * TALENT_STEP, (e.lr - 1) * TALENT_STEP
                else -- hero2, stacked below hero1 with a gap
                    x = heroZoneX + (e.lc - 1) * TALENT_STEP
                    y = (SIDE_ROWS * TALENT_STEP + 16) + (e.lr - 1) * TALENT_STEP
                end

                idx = idx + 1
                local btn = talentBtns[idx]
                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT", talentGrid, "TOPLEFT", x, -y)
                btn.icon:SetTexture(iconTex)

                if rank > 0 then
                    btn.icon:SetDesaturated(false)
                    btn.icon:SetAlpha(1)
                    if rank >= maxRank then
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
                    btn.spellName = name .. "  " .. rank .. "/" .. maxRank
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
    end

    -- Ask the server for a character's custom talent ranks
    local function RequestTalentsFor(name)
        talentsCurrentName = name
        if not name then
            UpdateTalentDisplay(nil)
            return
        end
        UpdateTalentDisplay(name, nil, nil) -- show "loading..."
        SSUI.Handle("SurrealArmyTalents", "RequestBotTalents", name)
    end
    _G.SurrealArmyRequestTalentsFor = RequestTalentsFor

    -- Dedicated SSUI channel (NOT "SurrealTalents" — that name is already
    -- registered client-side by SurrealTalentFrame_SSUI.lua, and SSUI.AddHandlers
    -- asserts/errors if the same name is registered twice on the same side).
    local ArmyTalentHandlers = SSUI.AddHandlers("SurrealArmyTalents", {})
    function ArmyTalentHandlers.ReceiveBotTalents(player, targetName, talents, spent, maxPts, unspent, tabInfo, classId)
        if targetName == talentsCurrentName then
            UpdateTalentDisplay(targetName, talents or {}, classId)
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
        SSUI.Handle("SurrealArmy", "DismissBot", "")
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
                    SSUI.Handle("SurrealArmy", "DismissBot", altName)
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
                    SSUI.Handle("SurrealArmy", "SpawnBot", altName)
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
                            -- Refresh talents/gear if this bot is the current selection
                            if talentsCurrentName == altNameForTimer then
                                RequestTalentsFor(altNameForTimer)
                            end
                            if bagsCurrentName == altNameForTimer then
                                RequestBagsFor(altNameForTimer, true)
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
                RequestTalentsFor(playerName)
                RequestBagsFor(playerName, true)
            else
                local altName = self.ddText:GetText()
                local altGuid = self.selectedAlt
                if altName and altName ~= "Select Alt" then
                    local altClass = self.altClass or 0
                    local altLevel = self.altLevel or 0
                    if self.isSpawned then
                        -- Bot is in party — show full model
                        ShowBotModel(altName, altClass, altLevel)
                    else
                        -- Not spawned — show info text only, no model
                        local className = CLASS_NAMES[altClass] or "Unknown"
                        local classColor = CLASS_COLORS[altClass] or "ffffffff"
                        centerModel:ClearModel()
                        centerName:SetText("|cffffd700" .. altName .. "|r")
                        centerInfo:SetText("|c" .. classColor .. className .. "|r  Level " .. altLevel .. "  |cff888888(not spawned)|r")
                        titleText:SetText("|cffffd100" .. altName .. "|r")
                    end
                    -- Talents/gear only available while the bot is spawned in the world
                    if self.isSpawned then
                        RequestTalentsFor(altName)
                        RequestBagsFor(altName, true)
                    else
                        RequestTalentsFor(nil)
                        RequestBagsFor(nil, false)
                    end
                else
                    centerName:SetText("")
                    centerInfo:SetText("")
                    titleText:SetText("|cffffd100Select a Character|r")
                    centerModel:ClearModel()
                    RequestTalentsFor(nil)
                    RequestBagsFor(nil, false)
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

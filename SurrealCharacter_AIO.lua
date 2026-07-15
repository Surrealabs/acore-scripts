-------------------------------------------------------------------------------
-- SurrealCharacter_AIO.lua
--
-- Custom character panel replacing the default Blizzard character frame.
-- Entirely client‑side. Equipment interaction uses native PickupInventoryItem
-- (works from hardware‑event handlers in WoTLK 3.3.5) so drag‑and‑drop,
-- click‑to‑equip, and click‑to‑unequip all work exactly like the default UI.
--
-- Stats panel has its own renamed-rating display with a dropdown for
-- Base Stats / Melee / Ranged / Spell / Defenses.
--
-- Equipment Manager support: save / load / delete gear sets using the
-- built‑in 3.3.5 equipment‑set API.
--
-- Keybind: C (ToggleCharacter override) | /char
-------------------------------------------------------------------------------

local AIO = AIO or require("AIO")

if AIO.AddAddon() then
    -- =====================================================================
    --  S E R V E R  S I D E  –  send known titles to client
    -- =====================================================================
    local SCharHandlers = AIO.AddHandlers("SurrealChar", {})

    function SCharHandlers.RequestTitles(player)
        local titles = {}
        -- CharTitlesEntry IDs go up to about 200 in WoTLK
        for tid = 1, 300 do
            if player:HasTitle(tid) then
                local entry = {id = tid}
                table.insert(titles, entry)
            end
        end
        AIO.Handle(player, "SurrealChar", "ReceiveTitles", titles)
    end

    -- Send titles on login
    local function OnLogin(event, player)
        SCharHandlers.RequestTitles(player)
    end
    RegisterPlayerEvent(3, OnLogin)  -- PLAYER_EVENT_ON_LOGIN
else
    -- =====================================================================
    --  C L I E N T  S I D E
    -- =====================================================================

    -- Enable the equipment manager CVar (safe no‑op if already set)
    pcall(function() SetCVar("equipmentManager", 1) end)

    -- -----------------------------------------------------------------
    --  I T E M   T O O L T I P   S T A T   R E M A P
    -- -----------------------------------------------------------------
    -- Shows only Surreal stat naming in item tooltips.
    -- Any old stat type not implemented yet is replaced with a clear marker.
    local ACTIVE_STAT_REMAP = {
        ["defense rating"] = "haste",
        ["dodge rating"] = "crit",
        ["parry rating"] = "mastery",
        ["block rating"] = "multistrike",
        ["hit rating"] = "versatility",
    }

    local UNIMPLEMENTED_STATS = {
        { token = "resilience rating", label = "Resilience" },
        { token = "resilience", label = "Resilience" },
        { token = "expertise rating", label = "Expertise" },
        { token = "armor penetration rating", label = "Armor Penetration" },
        { token = "crit rating", label = "Crit Rating" },
        { token = "haste rating", label = "Haste Rating" },
        { token = "spell penetration", label = "Spell Penetration" },
        { token = "block value", label = "Block Value" },
        { token = "mana regeneration", label = "Mana Regeneration" },
        { token = "health regeneration", label = "Health Regeneration" },
        { token = "hit avoidance", label = "Hit Avoidance" },
        { token = "crit avoidance", label = "Crit Avoidance" },
    }

    local function ReplaceCaseInsensitive(sourceText, findText, replaceText)
        local out = sourceText
        local lowerOut = string.lower(out)
        local startPos, endPos = string.find(lowerOut, findText, 1, true)
        while startPos do
            out = string.sub(out, 1, startPos - 1) .. replaceText .. string.sub(out, endPos + 1)
            lowerOut = string.lower(out)
            startPos, endPos = string.find(lowerOut, findText, 1, true)
        end
        return out
    end

    local function RemapItemStatTooltipLine(lineText)
        if not lineText or lineText == "" then return lineText end
        local lower = string.lower(lineText)

        for _, unimpl in ipairs(UNIMPLEMENTED_STATS) do
            if string.find(lower, unimpl.token, 1, true) then
                local amount = string.match(lineText, "by%s+([%+%-]?%d+)")
                    or string.match(lineText, "([%+%-]?%d+)")
                if amount then
                    return string.format("Equip: Not yet implemented (%s: %s)", unimpl.label, amount)
                end
                return string.format("Not yet implemented (%s)", unimpl.label)
            end
        end

        local remapped = lineText
        for oldText, newText in pairs(ACTIVE_STAT_REMAP) do
            if string.find(string.lower(remapped), oldText, 1, true) then
                remapped = ReplaceCaseInsensitive(remapped, oldText, newText)
            end
        end

        remapped = ReplaceCaseInsensitive(remapped, "shield multistrike", "multistrike")
        remapped = ReplaceCaseInsensitive(remapped, "melee versatility", "versatility")
        remapped = ReplaceCaseInsensitive(remapped, "ranged versatility", "versatility")
        remapped = ReplaceCaseInsensitive(remapped, "spell versatility", "versatility")

        return remapped
    end

    local function SurrealCharacter_RemapTooltipStats(tooltip)
        if not tooltip or not tooltip.GetName then return end
        local tooltipName = tooltip:GetName()
        if not tooltipName then return end

        for i = 1, tooltip:NumLines() do
            local leftLine = _G[tooltipName .. "TextLeft" .. i]
            if leftLine then
                local original = leftLine:GetText()
                if original and original ~= "" then
                    local remapped = RemapItemStatTooltipLine(original)
                    if remapped ~= original then
                        leftLine:SetText(remapped)
                    end
                end
            end
        end
    end

    GameTooltip:HookScript("OnTooltipSetItem", SurrealCharacter_RemapTooltipStats)
    ItemRefTooltip:HookScript("OnTooltipSetItem", SurrealCharacter_RemapTooltipStats)
    ShoppingTooltip1:HookScript("OnTooltipSetItem", SurrealCharacter_RemapTooltipStats)
    ShoppingTooltip2:HookScript("OnTooltipSetItem", SurrealCharacter_RemapTooltipStats)

    local StatScanTooltip = CreateFrame("GameTooltip", "SurrealCharacterStatScanTooltip", nil, "GameTooltipTemplate")
    StatScanTooltip:SetOwner(UIParent, "ANCHOR_NONE")

    local function GetEquippedTooltipRating(token)
        local total = 0

        for slot = 1, 19 do
            StatScanTooltip:ClearLines()
            if StatScanTooltip:SetInventoryItem("player", slot) then
                local lineCount = StatScanTooltip:NumLines() or 0
                for i = 2, lineCount do
                    local leftLine = _G["SurrealCharacterStatScanTooltipTextLeft" .. i]
                    if leftLine then
                        local text = leftLine:GetText()
                        if text and text ~= "" then
                            local remapped = RemapItemStatTooltipLine(text)
                            local lower = string.lower(remapped)
                            if string.find(lower, token, 1, true) then
                                local amount = string.match(remapped, "by%s+([%+%-]?%d+)")
                                    or string.match(remapped, "([%+%-]?%d+)")
                                if amount then
                                    total = total + (tonumber(amount) or 0)
                                end
                            end
                        end
                    end
                end
            end
        end

        return total
    end

    -- Table of title IDs the server confirmed this character has
    local knownTitleIDs = {}

    -- -----------------------------------------------------------------
    --  C O N S T A N T S
    -- -----------------------------------------------------------------
    local FRAME_W, FRAME_H = 980, 640
    local SLOT_SIZE  = 40
    local SLOT_GAP   = 6
    local SLOT_STEP  = SLOT_SIZE + SLOT_GAP  -- 46

    -- Slot definitions: { label, slotString }
    local LEFT_SLOTS = {
        { "Head",      "HeadSlot"     },
        { "Neck",      "NeckSlot"     },
        { "Shoulder",  "ShoulderSlot" },
        { "Back",      "BackSlot"     },
        { "Chest",     "ChestSlot"    },
        { "Shirt",     "ShirtSlot"    },
        { "Tabard",    "TabardSlot"   },
        { "Wrist",     "WristSlot"    },
    }

    local RIGHT_SLOTS = {
        { "Hands",     "HandsSlot"    },
        { "Waist",     "WaistSlot"    },
        { "Legs",      "LegsSlot"     },
        { "Feet",      "FeetSlot"     },
        { "Ring 1",    "Finger0Slot"  },
        { "Ring 2",    "Finger1Slot"  },
        { "Trinket 1", "Trinket0Slot" },
        { "Trinket 2", "Trinket1Slot" },
    }

    local BOTTOM_SLOTS = {
        { "Main Hand", "MainHandSlot"      },
        { "Off Hand",  "SecondaryHandSlot"  },
        { "Ranged",    "RangedSlot"         },
    }

    local STAT_CATEGORIES = {
        "Base Stats", "Melee", "Ranged", "Spell", "Defenses",
    }

    -- =================================================================
    --  S K I N   S Y S T E M  (4-file custom border)
    -- =================================================================
    -- File layout in your patch MPQ:
    --   Interface\SurrealUI\Border_Special.tga   (unique TL corner, 128x128)
    --   Interface\SurrealUI\Border_Corners.tga   (TR/BL/BR atlas, 256x128)
    --   Interface\SurrealUI\Border_Edge_H.tga    (top/bottom tile, 64x128)
    --   Interface\SurrealUI\Border_Edge_V.tga    (left/right tile, 128x64)
    --
    -- Border_Corners.tga atlas layout (256x128):
    --   Left half  (0-0.5, 0-0.5) = TR corner  (mirrored from TL)
    --   Left half  (0-0.5, 0.5-1) = BL corner
    --   Right half (0.5-1, 0-1)   = BR corner
    --
    -- To use fallback Blizzard textures until you have custom art,
    -- set SKIN_CUSTOM = false.  Set true once your files are in the MPQ.
    -- =================================================================
    local SKIN_CUSTOM  = false
    local SKIN_PATH    = "Interface\\SurrealUI\\"
    local CORNER_SIZE  = 64      -- px thickness of corner art
    local EDGE_THICK   = 16      -- px thickness of edge strips

    -- Apply the 4-file skin to any frame
    local function ApplySurrealSkin(f, w, h)
        if not SKIN_CUSTOM then
            -- Fallback: use the clean dark tooltip style
            f:SetBackdrop({
                bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = true, tileSize = 16, edgeSize = 16,
                insets = { left = 4, right = 4, top = 4, bottom = 4 },
            })
            f:SetBackdropColor(0.06, 0.06, 0.10, 0.95)
            f:SetBackdropBorderColor(0.30, 0.30, 0.35, 1)
            return
        end

        -- Background only (no edge — we draw edges manually)
        f:SetBackdrop({
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            tile = true, tileSize = 16,
            insets = { left = EDGE_THICK, right = EDGE_THICK,
                       top  = EDGE_THICK, bottom = EDGE_THICK },
        })
        f:SetBackdropColor(0.06, 0.06, 0.10, 0.95)

        local CS = CORNER_SIZE
        local ET = EDGE_THICK

        -- ---- TOP-LEFT corner (unique "hero" piece) ----
        local tl = f:CreateTexture(nil, "OVERLAY")
        tl:SetSize(CS, CS)
        tl:SetPoint("TOPLEFT", -ET, ET)
        tl:SetTexture(SKIN_PATH .. "Border_Special")

        -- ---- TOP-RIGHT corner (atlas: left half, top half) ----
        local tr = f:CreateTexture(nil, "OVERLAY")
        tr:SetSize(CS, CS)
        tr:SetPoint("TOPRIGHT", ET, ET)
        tr:SetTexture(SKIN_PATH .. "Border_Corners")
        tr:SetTexCoord(0, 0.5, 0, 0.5)

        -- ---- BOTTOM-LEFT corner (atlas: left half, bottom half) ----
        local bl = f:CreateTexture(nil, "OVERLAY")
        bl:SetSize(CS, CS)
        bl:SetPoint("BOTTOMLEFT", -ET, -ET)
        bl:SetTexture(SKIN_PATH .. "Border_Corners")
        bl:SetTexCoord(0, 0.5, 0.5, 1)

        -- ---- BOTTOM-RIGHT corner (atlas: right half, full height) ----
        local br = f:CreateTexture(nil, "OVERLAY")
        br:SetSize(CS, CS)
        br:SetPoint("BOTTOMRIGHT", ET, -ET)
        br:SetTexture(SKIN_PATH .. "Border_Corners")
        br:SetTexCoord(0.5, 1, 0, 1)

        -- ---- TOP edge (horizontal tile) ----
        local top = f:CreateTexture(nil, "OVERLAY")
        top:SetPoint("TOPLEFT", tl, "TOPRIGHT", 0, 0)
        top:SetPoint("TOPRIGHT", tr, "TOPLEFT", 0, 0)
        top:SetHeight(ET)
        top:SetTexture(SKIN_PATH .. "Border_Edge_H", true)  -- tile
        top:SetHorizTile(true)

        -- ---- BOTTOM edge (horizontal tile, flipped) ----
        local bot = f:CreateTexture(nil, "OVERLAY")
        bot:SetPoint("BOTTOMLEFT", bl, "BOTTOMRIGHT", 0, 0)
        bot:SetPoint("BOTTOMRIGHT", br, "BOTTOMLEFT", 0, 0)
        bot:SetHeight(ET)
        bot:SetTexture(SKIN_PATH .. "Border_Edge_H", true)
        bot:SetHorizTile(true)
        bot:SetTexCoord(0, 1, 1, 0)  -- flip vertical

        -- ---- LEFT edge (vertical tile) ----
        local left = f:CreateTexture(nil, "OVERLAY")
        left:SetPoint("TOPLEFT", tl, "BOTTOMLEFT", 0, 0)
        left:SetPoint("BOTTOMLEFT", bl, "TOPLEFT", 0, 0)
        left:SetWidth(ET)
        left:SetTexture(SKIN_PATH .. "Border_Edge_V", true)
        left:SetVertTile(true)

        -- ---- RIGHT edge (vertical tile, flipped) ----
        local right = f:CreateTexture(nil, "OVERLAY")
        right:SetPoint("TOPRIGHT", tr, "BOTTOMRIGHT", 0, 0)
        right:SetPoint("BOTTOMRIGHT", br, "TOPRIGHT", 0, 0)
        right:SetWidth(ET)
        right:SetTexture(SKIN_PATH .. "Border_Edge_V", true)
        right:SetVertTile(true)
        right:SetTexCoord(1, 0, 0, 1)  -- flip horizontal
    end

    -- -----------------------------------------------------------------
    --  M A I N   F R A M E
    -- -----------------------------------------------------------------
    local frame = CreateFrame("Frame", "SurrealCharacterFrame", UIParent)
    frame:SetSize(FRAME_W, FRAME_H)
    frame:SetPoint("CENTER", 0, 30)
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop",  frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)
    frame:Hide()

    ApplySurrealSkin(frame, FRAME_W, FRAME_H)

    tinsert(UISpecialFrames, "SurrealCharacterFrame")

    -- Title (shows player name)
    local titleText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleText:SetPoint("TOP", 0, -10)
    titleText:SetText("|cffffd100" .. (UnitName("player") or "Character") .. "|r")

    -- Close
    local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() frame:Hide() end)

    -- Army button (opens the bot army panel)
    local armyBtn = CreateFrame("Button", nil, frame)
    armyBtn:SetSize(80, 22)
    armyBtn:SetPoint("TOPRIGHT", closeBtn, "TOPLEFT", -4, -4)
    armyBtn:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    armyBtn:SetBackdropColor(0.12, 0.10, 0.20, 0.9)
    armyBtn:SetBackdropBorderColor(0.35, 0.30, 0.50, 1)

    local armyIcon = armyBtn:CreateTexture(nil, "ARTWORK")
    armyIcon:SetSize(16, 16)
    armyIcon:SetPoint("LEFT", armyBtn, "LEFT", 4, 0)
    armyIcon:SetTexture("Interface\\Icons\\Achievement_General_StayClassy")

    local armyLabel = armyBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    armyLabel:SetPoint("LEFT", armyIcon, "RIGHT", 4, 0)
    armyLabel:SetText("|cffffd700Army|r")

    armyBtn:SetScript("OnClick", function()
        if SurrealArmyFrame then
            if SurrealArmyFrame:IsShown() then
                SurrealArmyFrame:Hide()
            else
                SurrealArmyFrame:Show()
            end
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[SurrealUI]|r Army panel not loaded.")
        end
    end)
    armyBtn:SetScript("OnEnter", function()
        armyBtn:SetBackdropColor(0.20, 0.15, 0.30, 1)
        GameTooltip:SetOwner(armyBtn, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Bot Army", 1, 0.82, 0)
        GameTooltip:AddLine("Manage your bot companions", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    armyBtn:SetScript("OnLeave", function()
        armyBtn:SetBackdropColor(0.12, 0.10, 0.20, 0.9)
        GameTooltip:Hide()
    end)

    -- Player info line
    local nameText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameText:SetPoint("TOP", 0, -30)

    -- -----------------------------------------------------------------
    --  T I T L E   S E L E C T O R
    -- -----------------------------------------------------------------
    local titleBtn = CreateFrame("Button", nil, frame)
    titleBtn:SetSize(200, 16)
    titleBtn:SetPoint("TOP", nameText, "BOTTOM", 0, -2)

    local titleLabel = titleBtn:CreateFontString(nil, "OVERLAY",
        "GameFontNormalSmall")
    titleLabel:SetPoint("CENTER")
    titleLabel:SetText("|cff666688No Title|r")

    local titleArrow = titleBtn:CreateTexture(nil, "OVERLAY")
    titleArrow:SetSize(12, 12)
    titleArrow:SetPoint("LEFT", titleLabel, "RIGHT", 2, 0)
    titleArrow:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")

    -- Dropdown popup
    local titleDD = CreateFrame("Frame", nil, titleBtn)
    titleDD:SetFrameStrata("DIALOG")
    titleDD:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    titleDD:SetBackdropColor(0.08, 0.08, 0.12, 0.98)
    titleDD:SetBackdropBorderColor(0.30, 0.30, 0.35, 1)
    titleDD:Hide()
    titleDD:EnableMouseWheel(true)

    local titleRows = {}
    local TITLE_VISIBLE = 10
    local ROW_H = 16
    local titleList = {}   -- { {id=, name=}, ... }
    local titleScroll = 0

    for i = 1, TITLE_VISIBLE do
        local row = CreateFrame("Button", nil, titleDD)
        row:SetSize(190, ROW_H)
        row:SetPoint("TOPLEFT", 5, -5 - (i - 1) * ROW_H)

        local txt = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        txt:SetPoint("LEFT", 4, 0)
        txt:SetJustifyH("LEFT")
        row.text = txt

        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        hl:SetBlendMode("ADD")
        hl:SetAlpha(0.15)

        row:SetScript("OnClick", function(self)
            if self.titleId then
                SetCurrentTitle(self.titleId)
            end
            titleDD:Hide()
        end)
        titleRows[i] = row
    end

    local function BuildTitleList()
        titleList = {}
        table.insert(titleList, { id = -1, name = "No Title" })
        -- Use server-confirmed title IDs only
        for _, entry in ipairs(knownTitleIDs) do
            local tid = entry.id
            local tName = GetTitleName(tid)
            if tName and tName ~= "" then
                tName = tName:gsub("%s+$", "")
                table.insert(titleList, { id = tid, name = tName })
            end
        end
    end

    local function RefreshTitleDropdown()
        local maxScroll = math.max(0, #titleList - TITLE_VISIBLE)
        if titleScroll > maxScroll then titleScroll = maxScroll end
        if titleScroll < 0 then titleScroll = 0 end

        local curTitle = GetCurrentTitle and GetCurrentTitle() or 0

        for i = 1, TITLE_VISIBLE do
            local row = titleRows[i]
            local entry = titleList[titleScroll + i]
            if entry then
                local active = (entry.id == curTitle)
                    or (entry.id == -1 and curTitle == 0)
                row.text:SetText(
                    (active and "|cff44ff44" or "|cffcccccc")
                    .. entry.name .. "|r")
                row.titleId = (entry.id == -1) and 0 or entry.id
                row:Show()
            else
                row:Hide()
            end
        end

        local h = math.min(#titleList, TITLE_VISIBLE) * ROW_H + 10
        titleDD:SetSize(200, h)
    end

    local function RefreshTitleLabel()
        local curTitle = GetCurrentTitle and GetCurrentTitle() or 0
        if curTitle == 0 then
            titleLabel:SetText("|cff666688No Title|r")
        else
            local tName = GetTitleName(curTitle)
            if tName then
                tName = tName:gsub("%s+$", "")
                titleLabel:SetText("|cffffd100" .. tName .. "|r")
            else
                titleLabel:SetText("|cff666688No Title|r")
            end
        end
    end

    titleDD:SetScript("OnMouseWheel", function(self, delta)
        titleScroll = titleScroll - delta
        RefreshTitleDropdown()
    end)

    titleBtn:SetScript("OnClick", function()
        if titleDD:IsShown() then
            titleDD:Hide()
        else
            BuildTitleList()
            titleScroll = 0
            RefreshTitleDropdown()
            titleDD:ClearAllPoints()
            titleDD:SetPoint("TOP", titleBtn, "BOTTOM", 0, -2)
            titleDD:Show()
        end
    end)

    local function UpdatePlayerInfo()
        local name  = UnitName("player")  or ""
        local level = UnitLevel("player") or "?"
        local race  = UnitRace("player")  or ""
        local _, cls = UnitClass("player")
        titleText:SetText("|cffffd100" .. name .. "|r")
        nameText:SetText("|cff888888Level "
            .. level .. " " .. race .. " " .. (cls or "") .. "|r")
        RefreshTitleLabel()
    end

    -- -----------------------------------------------------------------
    --  3 D   M O D E L
    -- -----------------------------------------------------------------
    local model = CreateFrame("DressUpModel", nil, frame)
    model:SetSize(280, 330)
    model:SetPoint("TOP", 0, -48)
    model:SetUnit("player")
    model:SetRotation(0)

    model:EnableMouse(true)
    model.rotation = 0
    model.rotating = false
    model:SetScript("OnMouseDown", function(self, btn)
        if btn == "LeftButton" then
            self.rotating = true
            self.startX   = GetCursorPosition()
            self.startRot = self.rotation
        end
    end)
    model:SetScript("OnMouseUp", function(self, btn)
        if btn == "LeftButton" then self.rotating = false end
    end)
    model:SetScript("OnUpdate", function(self, elapsed)
        if self.rotating then
            local x = GetCursorPosition()
            self.rotation = self.startRot + (x - self.startX) / 50
            self:SetRotation(self.rotation)
        end
        -- Deferred model refresh after equipment change
        if self.pendingRefresh then
            self.refreshTimer = (self.refreshTimer or 0) + elapsed
            if self.refreshTimer >= 0.1 then
                self.pendingRefresh = false
                self:SetUnit("player")
            end
        end
    end)

    -- -----------------------------------------------------------------
    --  E Q U I P M E N T   S L O T S
    -- -----------------------------------------------------------------
    local slotButtons = {}

    local function CreateEquipSlot(parent, label, slotString, xOff, yOff)
        local invSlot, defaultTex = GetInventorySlotInfo(slotString)

        local btn = CreateFrame("Button", nil, parent)
        btn:SetSize(SLOT_SIZE, SLOT_SIZE)
        btn:SetPoint("TOPLEFT", xOff, yOff)
        btn.invSlot   = invSlot
        btn.slotLabel = label

        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        btn:RegisterForDrag("LeftButton")

        -- Background (empty‑slot icon)
        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(defaultTex or
            "Interface\\PaperDoll\\UI-PaperDoll-Slot-Chest")
        bg:SetAlpha(0.5)
        btn.bg = bg

        -- Item icon
        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints()
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        icon:Hide()
        btn.icon = icon

        -- Quality border (outer frame around the slot)
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

        -- Hover highlight
        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
        hl:SetBlendMode("ADD")
        hl:SetAlpha(0.3)

        -- Interactions  (all native WoW API – works from hardware events)
        btn:SetScript("OnClick", function(self, button)
            if button == "RightButton" then
                -- Right-click: open socketing UI if the item has sockets
                if GetInventoryItemTexture("player", self.invSlot) then
                    pcall(SocketInventoryItem, self.invSlot)
                end
            elseif IsShiftKeyDown() then
                pcall(SocketInventoryItem, self.invSlot)
            else
                PickupInventoryItem(self.invSlot)
            end
        end)
        btn:SetScript("OnDragStart", function(self)
            PickupInventoryItem(self.invSlot)
        end)
        btn:SetScript("OnReceiveDrag", function(self)
            PickupInventoryItem(self.invSlot)
        end)

        -- Tooltip
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local hasItem = GameTooltip:SetInventoryItem("player", self.invSlot)
            if not hasItem then
                GameTooltip:SetText(self.slotLabel, 1, 1, 1)
                GameTooltip:AddLine("Empty slot", 0.5, 0.5, 0.5)
                GameTooltip:Show()
            end
        end)
        btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        slotButtons[invSlot] = btn
        return btn
    end

    -- Left column (hugging left side of the 3D model)
    local modelLeft  = math.floor((FRAME_W - 280) / 2)     -- 350
    local modelRight = modelLeft + 280                       -- 630
    local leftColX   = modelLeft - SLOT_SIZE - 8             -- 302
    local rightColX  = modelRight + 8                        -- 638
    for i, s in ipairs(LEFT_SLOTS) do
        CreateEquipSlot(frame, s[1], s[2], leftColX, -52 - (i-1)*SLOT_STEP)
    end
    -- Right column (hugging right side of the 3D model)
    for i, s in ipairs(RIGHT_SLOTS) do
        CreateEquipSlot(frame, s[1], s[2],
            rightColX, -52 - (i-1)*SLOT_STEP)
    end
    -- Bottom weapons (centered)
    local wepY = -52 - 8*SLOT_STEP - 10
    local wepStart = math.floor((FRAME_W - 3*SLOT_SIZE - 2*10) / 2)
    for i, s in ipairs(BOTTOM_SLOTS) do
        CreateEquipSlot(frame, s[1], s[2],
            wepStart + (i-1)*(SLOT_SIZE + 10), wepY)
    end

    -- -----------------------------------------------------------------
    --  R E F R E S H   S L O T S
    -- -----------------------------------------------------------------
    local function RefreshSlots()
        for invSlot, btn in pairs(slotButtons) do
            local tex = GetInventoryItemTexture("player", invSlot)
            if tex then
                btn.icon:SetTexture(tex)
                btn.icon:Show()
                btn.bg:Hide()
                local q = GetInventoryItemQuality("player", invSlot)
                if q and q >= 2 then
                    local r, g, b = GetItemQualityColor(q)
                    btn.border:SetBackdropBorderColor(r, g, b, 1)
                else
                    btn.border:SetBackdropBorderColor(0.3, 0.3, 0.3, 0)
                end
            else
                btn.icon:Hide()
                btn.bg:Show()
                btn.border:SetBackdropBorderColor(0.3, 0.3, 0.3, 0)
            end
        end
    end

    -- =================================================================
    --  S T A T S   P A N E L  (two independent dropdown columns)
    -- =================================================================
    local statsPanel = CreateFrame("Frame", nil, frame)
    statsPanel:SetSize(440, 155)
    statsPanel:SetPoint("BOTTOMLEFT", 16, 10)
    statsPanel:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    statsPanel:SetBackdropColor(0.05, 0.05, 0.08, 0.8)
    statsPanel:SetBackdropBorderColor(0.25, 0.25, 0.30, 0.8)

    -- forward-declare
    local RefreshStats

    -- Helper: create a dropdown + 6 stat rows for a column
    local function CreateStatColumn(parent, anchorX, defaultCat)
        local col = {}
        col.category = defaultCat

        -- Dropdown button
        col.ddBtn = CreateFrame("Button", nil, parent)
        col.ddBtn:SetSize(200, 22)
        col.ddBtn:SetPoint("TOPLEFT", anchorX, -6)
        col.ddBtn:SetBackdrop({
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 10,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        col.ddBtn:SetBackdropColor(0.12, 0.12, 0.16, 1)
        col.ddBtn:SetBackdropBorderColor(0.35, 0.35, 0.40, 1)

        col.ddLabel = col.ddBtn:CreateFontString(nil, "OVERLAY",
            "GameFontNormalSmall")
        col.ddLabel:SetPoint("LEFT", 8, 0)
        col.ddLabel:SetText(defaultCat)

        local arrow = col.ddBtn:CreateTexture(nil, "OVERLAY")
        arrow:SetSize(14, 14)
        arrow:SetPoint("RIGHT", -4, 0)
        arrow:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")

        -- Dropdown list
        col.ddList = CreateFrame("Frame", nil, col.ddBtn)
        col.ddList:SetSize(200, #STAT_CATEGORIES * 20 + 10)
        col.ddList:SetPoint("TOP", col.ddBtn, "BOTTOM", 0, 2)
        col.ddList:SetFrameStrata("DIALOG")
        col.ddList:SetBackdrop({
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        col.ddList:SetBackdropColor(0.08, 0.08, 0.12, 0.98)
        col.ddList:SetBackdropBorderColor(0.30, 0.30, 0.35, 1)
        col.ddList:Hide()

        for idx, cat in ipairs(STAT_CATEGORIES) do
            local opt = CreateFrame("Button", nil, col.ddList)
            opt:SetSize(188, 18)
            opt:SetPoint("TOPLEFT", 6, -5 - (idx-1)*20)
            local oText = opt:CreateFontString(nil, "OVERLAY",
                "GameFontNormalSmall")
            oText:SetPoint("LEFT", 4, 0)
            oText:SetText(cat)
            opt:SetHighlightTexture(
                "Interface\\QuestFrame\\UI-QuestTitleHighlight")
            opt:GetHighlightTexture():SetBlendMode("ADD")
            opt:SetScript("OnClick", function()
                col.category = cat
                col.ddLabel:SetText(cat)
                col.ddList:Hide()
                RefreshStats()
            end)
        end

        col.ddBtn:SetScript("OnClick", function()
            if col.ddList:IsShown() then
                col.ddList:Hide()
            else
                col.ddList:Show()
            end
        end)

        -- 6 stat rows
        col.rows = {}
        for i = 1, 6 do
            local sf = CreateFrame("Frame", nil, parent)
            sf:SetSize(200, 18)
            sf:SetPoint("TOPLEFT", anchorX, -34 - (i-1)*18)
            sf:EnableMouse(true)

            sf.label = sf:CreateFontString(nil, "OVERLAY",
                "GameFontNormalSmall")
            sf.label:SetPoint("LEFT", 2, 0)
            sf.label:SetTextColor(0.67, 0.67, 0.73)

            sf.value = sf:CreateFontString(nil, "OVERLAY",
                "GameFontNormalSmall")
            sf.value:SetPoint("RIGHT", -2, 0)
            sf.value:SetTextColor(1, 1, 1)

            sf.tipTitle = ""
            sf.tipText  = ""

            local hl = sf:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetTexture(
                "Interface\\QuestFrame\\UI-QuestTitleHighlight")
            hl:SetBlendMode("ADD")
            hl:SetAlpha(0.12)

            sf:SetScript("OnEnter", function(self)
                if self.tipTitle and self.tipTitle ~= "" then
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText(self.tipTitle, 1, 1, 1)
                    if self.tipText and self.tipText ~= "" then
                        GameTooltip:AddLine(self.tipText,
                            0.8, 0.8, 0.6, true)
                    end
                    GameTooltip:Show()
                end
            end)
            sf:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)

            col.rows[i] = sf
        end

        return col
    end

    local leftCol  = CreateStatColumn(statsPanel, 8,   "Base Stats")
    local rightCol = CreateStatColumn(statsPanel, 218, "Melee")

    local SPELL_DK_FROST_PRESENCE = 48263
    local SPELL_PAL_RIGHTEOUS_FURY = 25780
    local TANK_PASSIVE_PARRY_CAP_RATING = 200 -- 20% at 10 rating per 1%
    local TANK_PASSIVE_DODGE_CAP_RATING = 200 -- 20% at 10 rating per 1%

    local function HasPlayerAuraBySpellId(spellId)
        local spellName = GetSpellInfo(spellId)
        if not spellName then return false end
        return UnitBuff("player", spellName) ~= nil
    end

    local function GetTankPassiveStateText()
        local _, classToken = UnitClass("player")
        local form = GetShapeshiftForm and GetShapeshiftForm() or 0

        if classToken == "DEATHKNIGHT" then
            local active = HasPlayerAuraBySpellId(SPELL_DK_FROST_PRESENCE)
            return active, active and "Active (Frost Presence)" or "Inactive (requires Frost Presence)"
        elseif classToken == "DRUID" then
            local active = (form == FORM_BEAR or form == FORM_DIREBEAR)
            return active, active and "Active (Bear Form)" or "Inactive (requires Bear Form)"
        elseif classToken == "PALADIN" then
            local active = HasPlayerAuraBySpellId(SPELL_PAL_RIGHTEOUS_FURY)
            return active, active and "Active (Righteous Fury)" or "Inactive (requires Righteous Fury)"
        elseif classToken == "WARRIOR" then
            local active = (form == FORM_DEFENSIVESTANCE)
            return active, active and "Active (Defensive Stance)" or "Inactive (requires Defensive Stance)"
        end

        return false, "Inactive (tank passive only applies to DK/Druid/Paladin/Warrior)"
    end

    local function GetPlayerClassAndSpecIndex()
        local _, classToken = UnitClass("player")
        local specIndex = nil
        if GetPrimaryTalentTree then
            specIndex = GetPrimaryTalentTree()
        end
        return classToken, specIndex
    end

    local function BuildMasteryTooltipText(maPct)
        local classToken, specIndex = GetPlayerClassAndSpecIndex()
        local masteryMul = 1 + (maPct / 100)

        if classToken == "WARLOCK" then
            local specNames = { "Affliction", "Demonology", "Destruction" }
            local specName = specNames[specIndex or 0] or "Unknown"
            return format(
                "Your mastery increases Warlock pet and guardian damage.\nBaseline: 100%% pet/guardian damage\nMastery Bonus: +%.1f%%%%\nFinal: 100%%%% + %.1f%%%% = %.1f%%%% (x%.3f)\nSpec: %s",
                maPct, maPct, 100 + maPct, masteryMul, specName
            )
        end

        if classToken == "DEATHKNIGHT" then
            if specIndex == 1 then
                return format(
                    "Blood mastery increases Death Strike healing and Blood Barrier shielding.\nBaseline Heal: max(50%%%% of damage taken in last 5s, 10%%%% max HP)\nBaseline Shield: 50%%%% of Death Strike heal\nMastery Bonus: +%.1f%%%%\nFinal heal & shield multiplier: x%.3f",
                    maPct, masteryMul
                )
            end
            return format(
                "Blood DK mastery scaling is active for Death Strike heal + shield.\nCurrent spec does not use this custom mastery hook.\nCurrent mastery: %.1f%%%% (x%.3f)",
                maPct, masteryMul
            )
        end

        if classToken == "PALADIN" then
            if specIndex == 1 then
                return format(
                    "Holy mastery increases Beacon of Light transfer amounts.\nBaseline Damage Funnel: 50%%%% damage heal per target (2 targets)\nBaseline Direct-Heal Duplicate: 100%%%% heal per target (5 targets, excluding original)\nMastery Bonus: +%.1f%%%%\nFinal Beacon transfer multiplier: x%.3f",
                    maPct, masteryMul
                )
            end
            return format(
                "Holy Paladin mastery scaling is active for Beacon transfers.\nCurrent spec does not use this custom mastery hook.\nCurrent mastery: %.1f%%%% (x%.3f)",
                maPct, masteryMul
            )
        end

        if classToken == "PRIEST" then
            local specNames = { "Discipline", "Holy", "Shadow" }
            local specName = specNames[specIndex or 0] or "Unknown"
            local baseTransferPct = 25.0
            local finalTransferPct = baseTransferPct + maPct
            local baseExtensionSec = 0.2
            local finalExtensionSec = baseExtensionSec * masteryMul
            return format(
                "Shadow mastery increases Psychic Link output.\nBaseline Transfer: %.1f%%%%\nMastery Bonus: +%.1f%%%%\nFinal Transfer: %.1f%%%%\n\nBaseline DoT Extension: %.3fs per proc\nMastery-scaled Extension: %.3fs per proc\n\nSpec: %s",
                baseTransferPct, maPct, finalTransferPct,
                baseExtensionSec, finalExtensionSec,
                specName
            )
        end

        return format("%.1f%%%% Mastery (class-specific effect)", maPct)
    end

    -- ---- helper: fill secondary rating stats into row array ---------------
    local function SetSecondaryStats(rows, startIdx)
        -- Crit (dodge rating)
        local mCrit = GetCritChance() or 0
        local rCrit = GetRangedCritChance() or 0
        local sCrit = GetSpellCritChance(2) or 0
        for i = 3, (MAX_SPELL_SCHOOLS or 7) do
            local c = GetSpellCritChance(i) or 0
            if c < sCrit then sCrit = c end
        end
        local dodgeR = GetCombatRating(CR_DODGE) or 0
        if dodgeR <= 0 then
            dodgeR = GetEquippedTooltipRating("crit")
        end
        local critDmg = dodgeR / 5
        local sf = rows[startIdx]
        sf.label:SetText("Crit:")
        sf.value:SetText(format("%.1f%%", mCrit))
        sf.value:SetTextColor(1,1,1)
        sf.tipTitle = format("Crit: %d Rating", dodgeR)
        local tankActive, tankState = GetTankPassiveStateText()
        local parryFromCrit = tankActive and min(dodgeR, TANK_PASSIVE_PARRY_CAP_RATING) or 0
        sf.tipText  = format("%.2f%% Melee Crit\n%.2f%% Ranged Crit\n%.2f%% Spell Crit\n+%.1f%% Crit Damage Bonus\n\nTank Passive: Crit -> Parry Rating\nCurrent Bonus: +%d Parry Rating\nPassive Cap: +%d (20%%)\nState: %s",
            mCrit, rCrit, sCrit, critDmg, parryFromCrit, TANK_PASSIVE_PARRY_CAP_RATING, tankState)

        -- Versatility (hit rating)
        local hitR = GetCombatRating(CR_HIT_MELEE) or 0
        if hitR <= 0 then
            hitR = GetEquippedTooltipRating("versatility")
        end
        local vPct = hitR / 10
        sf = rows[startIdx + 1]
        sf.label:SetText("Versatility:")
        sf.value:SetText(format("%.1f%%", vPct))
        sf.value:SetTextColor(1,1,1)
        sf.tipTitle = format("Versatility: %d Rating", hitR)
        sf.tipText  = format("+%.1f%% Damage & Healing\n-%.1f%% Damage Taken",
            vPct, vPct * 0.5)

        -- Haste (defense rating)
        local defR = GetCombatRating(CR_DEFENSE_SKILL) or 0
        if defR <= 0 then
            defR = GetEquippedTooltipRating("haste")
        end
        local mH = GetCombatRatingBonus(CR_HASTE_MELEE) or 0
        local rH = GetCombatRatingBonus(CR_HASTE_RANGED) or 0
        local sH = GetCombatRatingBonus(CR_HASTE_SPELL) or 0
        sf = rows[startIdx + 2]
        sf.label:SetText("Haste:")
        sf.value:SetText(format("%.1f%%", mH))
        sf.value:SetTextColor(1,1,1)
        sf.tipTitle = format("Haste: %d Rating", defR)
        sf.tipText  = format("%.2f%% Melee Haste\n%.2f%% Ranged Haste\n%.2f%% Spell Haste",
            mH, rH, sH)

        -- Multistrike (block rating)
        local blkR = GetCombatRating(CR_BLOCK) or 0
        if blkR <= 0 then
            blkR = GetEquippedTooltipRating("multistrike")
        end
        local msPct = blkR / 10
        sf = rows[startIdx + 3]
        sf.label:SetText("Multistrike:")
        sf.value:SetText(format("%.1f%%", msPct))
        sf.value:SetTextColor(1,1,1)
        sf.tipTitle = format("Multistrike: %d Rating", blkR)
        local tankActiveMs, tankStateMs = GetTankPassiveStateText()
        local dodgeFromMultistrike = tankActiveMs and min(blkR, TANK_PASSIVE_DODGE_CAP_RATING) or 0
        sf.tipText  = format("%.1f%% chance to recast at 33%% effectiveness\n\nTank Passive: Multistrike -> Dodge Rating\nCurrent Bonus: +%d Dodge Rating\nPassive Cap: +%d (20%%)\nState: %s",
            msPct, dodgeFromMultistrike, TANK_PASSIVE_DODGE_CAP_RATING, tankStateMs)

        -- Mastery (parry rating)
        local parR = GetCombatRating(CR_PARRY) or 0
        if parR <= 0 then
            parR = GetEquippedTooltipRating("mastery")
        end
        local maPct = parR / 10
        sf = rows[startIdx + 4]
        sf.label:SetText("Mastery:")
        sf.value:SetText(format("%.1f%%", maPct))
        sf.value:SetTextColor(1,1,1)
        sf.tipTitle = format("Mastery: %d Rating", parR)
        sf.tipText  = BuildMasteryTooltipText(maPct)
    end

    -- ---- fill a column's rows based on its category -----------------------
    local function FillColumn(col)
        local rows = col.rows
        local cat  = col.category

        if cat == "Base Stats" then
            local names = {"Strength","Agility","Stamina","Intellect","Spirit"}
            local tips  = {
                function(e) return format("%d Attack Power",  e * 2) end,
                function(e) return format("%d Attack Power",  e * 2) end,
                function(e) return format("%d Health",        e * 10) end,
                function(e) return format("%d Spell Damage",  e * 2) end,
                function(e) return format("%d Spell Healing", e * 2) end,
            }
            for i = 1, 5 do
                local _, eff, pos, neg = UnitStat("player", i)
                eff = eff or 0; pos = pos or 0; neg = neg or 0
                rows[i].label:SetText(names[i] .. ":")
                rows[i].value:SetText(math.floor(eff))
                if neg < 0 then
                    rows[i].value:SetTextColor(1, 0.2, 0.2)
                elseif pos > 0 then
                    rows[i].value:SetTextColor(0.2, 1, 0.2)
                else
                    rows[i].value:SetTextColor(1, 1, 1)
                end
                rows[i].tipTitle = format("%s: %d", names[i], eff)
                rows[i].tipText  = tips[i](eff)
            end
            local base, effective = UnitArmor("player")
            effective = effective or 0; base = base or 0
            rows[6].label:SetText("Armor:")
            rows[6].value:SetText(effective)
            rows[6].value:SetTextColor(1,1,1)
            rows[6].tipTitle = format("Armor: %d", effective)
            local attackerLevel = UnitLevel("target") or UnitLevel("player") or 80
            if attackerLevel < 1 then attackerLevel = 80 end
            local reductionVsTarget = 0
            local denomTarget = effective + 400 + 85 * attackerLevel
            if denomTarget > 0 then
                reductionVsTarget = (effective / denomTarget) * 100
            end
            local reductionVs83 = 0
            local denom83 = effective + 400 + 85 * 83
            if denom83 > 0 then
                reductionVs83 = (effective / denom83) * 100
            end
            rows[6].tipText  = format("Base Armor: %d\nDamage Reduction vs L%d: %.2f%%\nDamage Reduction vs L83: %.2f%%",
                base, attackerLevel, reductionVsTarget, reductionVs83)

        elseif cat == "Melee" then
            local b, p, n = UnitAttackPower("player")
            b = b or 0; p = p or 0; n = n or 0
            local ap = b + p + n
            local minD, maxD, minOffD, maxOffD = UnitDamage("player")
            local mainSpeed, offSpeed = UnitAttackSpeed("player")
            minD = minD or 0; maxD = maxD or 0
            minOffD = minOffD or 0; maxOffD = maxOffD or 0
            mainSpeed = mainSpeed or 0; offSpeed = offSpeed or 0
            rows[1].label:SetText("Attack Power:")
            rows[1].value:SetText(ap)
            rows[1].value:SetTextColor(1,1,1)
            rows[1].tipTitle = format("Attack Power: %d", ap)
            local tip = format("%.1f DPS Increase", ap / 14)
            if mainSpeed > 0 then
                local mainDps = ((minD + maxD) / 2) / mainSpeed
                tip = tip .. format("\nMain Hand: %.0f - %.0f (%.2fs, %.1f DPS)", minD, maxD, mainSpeed, mainDps)
            end
            if offSpeed > 0 and (maxOffD > 0 or minOffD > 0) then
                local offDps = ((minOffD + maxOffD) / 2) / offSpeed
                tip = tip .. format("\nOff Hand: %.0f - %.0f (%.2fs, %.1f DPS)", minOffD, maxOffD, offSpeed, offDps)
            end
            rows[1].tipText = tip
            SetSecondaryStats(rows, 2)

        elseif cat == "Ranged" then
            local b, p, n = UnitRangedAttackPower("player")
            b = b or 0; p = p or 0; n = n or 0
            local rap = b + p + n
            local rSpeed, rMin, rMax = UnitRangedDamage("player")
            rSpeed = rSpeed or 0; rMin = rMin or 0; rMax = rMax or 0
            rows[1].label:SetText("Ranged AP:")
            rows[1].value:SetText(rap)
            rows[1].value:SetTextColor(1,1,1)
            rows[1].tipTitle = format("Ranged Attack Power: %d", rap)
            local tip = format("%.1f DPS Increase", rap / 14)
            if rSpeed > 0 then
                local rangedDps = ((rMin + rMax) / 2) / rSpeed
                tip = tip .. format("\nRanged: %.0f - %.0f (%.2fs, %.1f DPS)", rMin, rMax, rSpeed, rangedDps)
            end
            rows[1].tipText = tip
            SetSecondaryStats(rows, 2)

        elseif cat == "Spell" then
            local bonusDmg = GetSpellBonusDamage(2) or 0
            for i = 3, (MAX_SPELL_SCHOOLS or 7) do
                local v = GetSpellBonusDamage(i) or 0
                if v > bonusDmg then bonusDmg = v end
            end
            local bonusHeal = GetSpellBonusHealing() or 0
            local sp = math.max(bonusDmg, bonusHeal)
            rows[1].label:SetText("Spell Power:")
            rows[1].value:SetText(sp)
            rows[1].value:SetTextColor(1,1,1)
            rows[1].tipTitle = format("Spell Power: %d", sp)
            rows[1].tipText  = format("%d Spell Damage\n%d Spell Healing",
                bonusDmg, bonusHeal)
            SetSecondaryStats(rows, 2)

        elseif cat == "Defenses" then
            local _, sta = UnitStat("player", 3)
            sta = sta or 0
            rows[1].label:SetText("Stamina:")
            rows[1].value:SetText(math.floor(sta))
            rows[1].value:SetTextColor(1,1,1)
            rows[1].tipTitle = format("Stamina: %d", sta)
            rows[1].tipText  = format("%d Health", sta * 10)

            local dodge = GetDodgeChance() or 0
            local tankActiveDef, tankStateDef = GetTankPassiveStateText()
            local blkRDef = GetCombatRating(CR_BLOCK) or 0
            if blkRDef <= 0 then
                blkRDef = GetEquippedTooltipRating("multistrike")
            end
            local dodgePassivePct = tankActiveDef and (min(blkRDef, TANK_PASSIVE_DODGE_CAP_RATING) / 10) or 0
            local dodgeCombined = dodge + dodgePassivePct
            rows[2].label:SetText("Dodge:")
            rows[2].value:SetText(format("%.2f%%", dodgeCombined))
            rows[2].value:SetTextColor(1,1,1)
            rows[2].tipTitle = "Dodge"
            rows[2].tipText  = format("Base: %.2f%%\nTank Passive: +%.2f%%\nCombined: %.2f%%\nState: %s", dodge, dodgePassivePct, dodgeCombined, tankStateDef)

            local parry = GetParryChance() or 0
            local critRDef = GetCombatRating(CR_DODGE) or 0
            if critRDef <= 0 then
                critRDef = GetEquippedTooltipRating("crit")
            end
            local parryPassivePct = tankActiveDef and (min(critRDef, TANK_PASSIVE_PARRY_CAP_RATING) / 10) or 0
            local parryCombined = parry + parryPassivePct
            rows[3].label:SetText("Parry:")
            rows[3].value:SetText(format("%.2f%%", parryCombined))
            rows[3].value:SetTextColor(1,1,1)
            rows[3].tipTitle = "Parry"
            rows[3].tipText  = format("Base: %.2f%%\nTank Passive: +%.2f%%\nCombined: %.2f%%\nState: %s", parry, parryPassivePct, parryCombined, tankStateDef)

            local block = GetBlockChance() or 0
            rows[4].label:SetText("Block:")
            rows[4].value:SetText(format("%.2f%%", block))
            rows[4].value:SetTextColor(1,1,1)
            rows[4].tipTitle = "Block"
            rows[4].tipText  = format("%.2f%% chance to block", block)

            local hitR = GetCombatRating(CR_HIT_MELEE) or 0
            local vPct = hitR / 10
            rows[5].label:SetText("Versatility:")
            rows[5].value:SetText(format("%.1f%%", vPct))
            rows[5].value:SetTextColor(1,1,1)
            rows[5].tipTitle = format("Versatility: %d Rating", hitR)
            rows[5].tipText  = format("+%.1f%% Damage & Healing\n-%.1f%% Damage Taken",
                vPct, vPct * 0.5)

            local aBase, aEff = UnitArmor("player")
            aEff = aEff or 0; aBase = aBase or 0
            rows[6].label:SetText("Armor:")
            rows[6].value:SetText(aEff)
            rows[6].value:SetTextColor(1,1,1)
            rows[6].tipTitle = format("Armor: %d", aEff)
            local attackerLevel = UnitLevel("target") or UnitLevel("player") or 80
            if attackerLevel < 1 then attackerLevel = 80 end
            local reductionVsTarget = 0
            local denomTarget = aEff + 400 + 85 * attackerLevel
            if denomTarget > 0 then
                reductionVsTarget = (aEff / denomTarget) * 100
            end
            local reductionVs83 = 0
            local denom83 = aEff + 400 + 85 * 83
            if denom83 > 0 then
                reductionVs83 = (aEff / denom83) * 100
            end
            rows[6].tipText  = format("Base Armor: %d\nDamage Reduction vs L%d: %.2f%%\nDamage Reduction vs L83: %.2f%%",
                aBase, attackerLevel, reductionVsTarget, reductionVs83)
        end
    end

    -- ---- RefreshStats implementation --------------------------------------
    RefreshStats = function()
        UpdatePlayerInfo()
        FillColumn(leftCol)
        FillColumn(rightCol)
    end

    -- =================================================================
    --  E Q U I P M E N T   M A N A G E R  (Coming Soon)
    -- =================================================================
    local eqmPanel = CreateFrame("Frame", nil, frame)
    eqmPanel:SetSize(440, 155)
    eqmPanel:SetPoint("BOTTOMRIGHT", -16, 10)
    eqmPanel:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    eqmPanel:SetBackdropColor(0.05, 0.05, 0.08, 0.8)
    eqmPanel:SetBackdropBorderColor(0.25, 0.25, 0.30, 0.8)

    local eqmTitle = eqmPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    eqmTitle:SetPoint("TOPLEFT", 10, -6)
    eqmTitle:SetText("|cffffd100Equipment Manager|r")

    local comingSoon = eqmPanel:CreateFontString(nil, "OVERLAY",
        "GameFontNormalLarge")
    comingSoon:SetPoint("CENTER", 0, 0)
    comingSoon:SetText("|cff888899Coming Soon|r")



    -- =================================================================
    --  E V E N T S
    -- =================================================================
    local evFrame = CreateFrame("Frame")
    evFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    evFrame:RegisterEvent("UNIT_INVENTORY_CHANGED")
    evFrame:RegisterEvent("UNIT_STATS")
    evFrame:RegisterEvent("UNIT_AURA")
    evFrame:RegisterEvent("COMBAT_RATING_UPDATE")
    evFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    evFrame:SetScript("OnEvent", function(self, event, arg1)
        if event == "PLAYER_ENTERING_WORLD" then
            -- Kill the Blizzard CharacterFrame
            if CharacterFrame then
                CharacterFrame:UnregisterAllEvents()
                CharacterFrame:Hide()
                CharacterFrame:SetScript("OnShow", function(f) f:Hide() end)
            end
            if CharacterMicroButton then
                CharacterMicroButton:SetScript("OnClick", function()
                    ToggleSurrealCharacter()
                end)
            end
            self:UnregisterEvent("PLAYER_ENTERING_WORLD")
            return
        end

        if not frame:IsShown() then return end

        if event == "PLAYER_EQUIPMENT_CHANGED"
           or event == "UNIT_INVENTORY_CHANGED" then
            RefreshSlots()
            RefreshStats()
            -- Hard-reset the model: clear it, then restore after 1 frame
            model:ClearModel()
            model.pendingRefresh = true
            model.refreshTimer  = 0
        elseif event == "UNIT_STATS" or event == "UNIT_AURA"
               or event == "COMBAT_RATING_UPDATE" then
            if not arg1 or arg1 == "player" then
                RefreshStats()
            end
        end
    end)

    -- =================================================================
    --  T O G G L E  /  K E Y B I N D
    -- =================================================================
    function ToggleSurrealCharacter()
        if frame:IsShown() then frame:Hide() else frame:Show() end
    end

    -- Override the global so the C key opens our frame
    ToggleCharacter = function(tab)
        ToggleSurrealCharacter()
    end

    SLASH_SURREALCHARACTER1 = "/char"
    SlashCmdList["SURREALCHARACTER"] = function()
        ToggleSurrealCharacter()
    end

    -- =================================================================
    --  O N   S H O W  (mutual exclusion + refresh)
    -- =================================================================
    frame:SetScript("OnShow", function(self)
        if SurrealTalentFrame and SurrealTalentFrame:IsShown() then
            SurrealTalentFrame:Hide()
        end
        if SurrealCollections and SurrealCollections:IsShown() then
            SurrealCollections:Hide()
        end
        if SurrealSpellBook and SurrealSpellBook:IsShown() then
            SurrealSpellBook:Hide()
        end
        if CharacterFrame and CharacterFrame:IsShown() then
            CharacterFrame:Hide()
        end
        if SurrealArmyFrame and SurrealArmyFrame:IsShown() then
            SurrealArmyFrame:Hide()
        end

        model:SetUnit("player")
        UpdatePlayerInfo()
        RefreshSlots()
        RefreshStats()
    end)

    DEFAULT_CHAT_FRAME:AddMessage(
        "|cff00ff00[SurrealUI]|r Character panel loaded.")

    -- =================================================================
    --  E M B E D   B L I Z Z A R D   S O C K E T I N G   F R A M E
    -- =================================================================
    -- Load the Blizzard socketing addon on demand, then reparent it
    -- into the left side of our character panel.
    local socketHooked = false
    local function HookSocketingFrame()
        if socketHooked then return end
        if not ItemSocketingFrame then return end
        socketHooked = true

        -- Remove from UISpecialFrames so ESC doesn't close it separately
        for i = #UISpecialFrames, 1, -1 do
            if UISpecialFrames[i] == "ItemSocketingFrame" then
                table.remove(UISpecialFrames, i)
            end
        end

        -- Reparent into our character frame
        ItemSocketingFrame:SetParent(frame)
        ItemSocketingFrame:ClearAllPoints()
        ItemSocketingFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -52)

        -- Shrink to fit the left margin
        ItemSocketingFrame:SetScale(0.75)

        -- Make it non-movable within our frame
        ItemSocketingFrame:SetMovable(false)
        ItemSocketingFrame:EnableMouse(true)
        ItemSocketingFrame:SetClampedToScreen(false)

        -- Force position on every show (Blizzard's code resets it)
        local function ForceSocketPosition()
            ItemSocketingFrame:ClearAllPoints()
            ItemSocketingFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -52)
            ItemSocketingFrame:SetScale(0.75)
            ItemSocketingFrame:SetParent(frame)
        end

        -- Override Show to ensure our character frame is visible
        local origShow = ItemSocketingFrame.Show
        ItemSocketingFrame.Show = function(self)
            if not frame:IsShown() then frame:Show() end
            origShow(self)
            ForceSocketPosition()
        end

        -- Also hook OnShow in case Blizzard moves it there
        hooksecurefunc(ItemSocketingFrame, "SetPoint", function()
            -- Only reposition if we're the parent
            if ItemSocketingFrame:GetParent() == frame then
                ItemSocketingFrame:SetScale(0.75)
            end
        end)

        -- When our character frame hides, close socketing too
        local origOnHide = frame:GetScript("OnHide")
        frame:SetScript("OnHide", function(self)
            if ItemSocketingFrame and ItemSocketingFrame:IsShown() then
                pcall(CloseSocketInfo)
                ItemSocketingFrame:Hide()
            end
            if origOnHide then origOnHide(self) end
        end)
    end

    -- The socketing addon loads on demand; hook it via ADDON_LOADED
    -- and also try immediately in case it's already loaded.
    pcall(function() LoadAddOn("Blizzard_ItemSocketingUI") end)
    HookSocketingFrame()

    local socketLoadFrame = CreateFrame("Frame")
    socketLoadFrame:RegisterEvent("ADDON_LOADED")
    socketLoadFrame:RegisterEvent("SOCKET_INFO_UPDATE")
    socketLoadFrame:SetScript("OnEvent", function(self, event, arg1)
        if event == "ADDON_LOADED" and arg1 == "Blizzard_ItemSocketingUI" then
            HookSocketingFrame()
            self:UnregisterEvent("ADDON_LOADED")
        elseif event == "SOCKET_INFO_UPDATE" then
            -- Ensure the addon is loaded and hooked when socketing opens
            if not socketHooked then
                pcall(function() LoadAddOn("Blizzard_ItemSocketingUI") end)
                HookSocketingFrame()
            end
            -- Make sure our frame is showing
            if not frame:IsShown() then frame:Show() end
        end
    end)

    -- =================================================================
    --  A I O   H A N D L E R S  (receive data from server)
    -- =================================================================
    local SurrealCharCli = AIO.AddHandlers("SurrealChar", {})

    function SurrealCharCli.ReceiveTitles(player, titles)
        knownTitleIDs = titles or {}
    end
end

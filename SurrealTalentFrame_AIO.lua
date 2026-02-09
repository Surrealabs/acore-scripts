-------------------------------------------------------------------------------
-- SurrealTalentFrame_AIO.lua
--
-- Replaces the default WoTLK talent frame with a modern, wider layout.
-- Each talent's grid position is configurable per class / spec.
-- Row requirements have been removed server-side (see mod-talents-expanded).
--
-- Usage:
--   Press N to open the talent frame (same binding as default)
--   /surrealtalents debug  — prints all talent indices for layout config
--
-- Configuration:
--   1. Edit TALENT_LAYOUTS to reposition any talent (per class, per spec tab).
--   2. Edit CFG for grid dimensions, button size, spacing, and colours.
-------------------------------------------------------------------------------

local AIO = AIO or require("AIO")

if AIO.AddAddon() then
    ---------------------------------------------------------------------------
    -- SERVER SIDE — Talent reset handler via AIO
    ---------------------------------------------------------------------------
    local Handlers = AIO.AddHandlers("SurrealTalents", {})

    -- Client requests the current reset cost
    function Handlers.GetResetCost(player)
        local cost = player:ResetTalentsCost()
        AIO.Handle(player, "SurrealTalents", "ShowResetCost", cost)
    end

    -- Client confirms the talent reset
    function Handlers.ConfirmReset(player)
        local cost = player:ResetTalentsCost()
        if player:GetCoinage() < cost then
            player:SendBroadcastMessage("Not enough gold to reset talents.")
            return
        end
        if player:ResetTalents(false) then
            player:SendBroadcastMessage("Talents have been reset.")
            -- Send updated cost for next time
            local newCost = player:ResetTalentsCost()
            AIO.Handle(player, "SurrealTalents", "ResetDone", newCost)
        else
            player:SendBroadcastMessage("No talents to reset.")
        end
    end

    -- Client requests to apply a glyph from bags
    -- itemID = glyph item entry, socketIdx = 0-5 (slot index)
    function Handlers.ApplyGlyph(player, itemID, socketIdx)
        -- Validate socket index
        if type(socketIdx) ~= "number" or socketIdx < 0 or socketIdx > 5 then
            player:SendBroadcastMessage("Invalid glyph slot.")
            return
        end

        -- Check player has the item
        if not player:HasItem(itemID, 1, false) then
            player:SendBroadcastMessage("You don't have that glyph.")
            return
        end

        -- Get the item to read its spell
        local item = player:GetItemByEntry(itemID)
        if not item then
            player:SendBroadcastMessage("Could not find glyph item.")
            return
        end

        -- Get the glyph application spell from the item (spellid_1 = index 0)
        local glyphSpellId = item:GetSpellId(0)
        if not glyphSpellId or glyphSpellId == 0 then
            player:SendBroadcastMessage("Invalid glyph item.")
            return
        end

        -- Get the GlyphProperties ID from the spell's MiscValue
        local spellInfo = GetSpellInfo(glyphSpellId)
        if not spellInfo then
            player:SendBroadcastMessage("Invalid glyph spell.")
            return
        end

        local glyphPropsId = spellInfo:GetEffectMiscValueA(0)
        if not glyphPropsId or glyphPropsId == 0 then
            player:SendBroadcastMessage("Could not resolve glyph properties.")
            return
        end

        -- Apply the new glyph (SetGlyph handles replacing old glyph data)
        player:SetGlyph(glyphPropsId, socketIdx)

        -- Cast the glyph application spell to apply the passive aura
        -- This spell has SPELL_EFFECT_APPLY_GLYPH which handles aura
        player:CastSpell(player, glyphSpellId, true)

        -- Consume the glyph item
        player:RemoveItem(itemID, 1)

        -- Notify client
        AIO.Handle(player, "SurrealTalents", "GlyphApplied", socketIdx)
        player:SendBroadcastMessage("Glyph applied successfully.")
    end

    -- Client requests to remove a glyph
    function Handlers.RemoveGlyph(player, socketIdx)
        if type(socketIdx) ~= "number" or socketIdx < 0 or socketIdx > 5 then
            player:SendBroadcastMessage("Invalid glyph slot.")
            return
        end

        local oldGlyphId = player:GetGlyph(socketIdx)
        if not oldGlyphId or oldGlyphId == 0 then
            player:SendBroadcastMessage("No glyph in that slot.")
            return
        end

        -- Clear the glyph slot
        player:SetGlyph(0, socketIdx)

        -- Send talent update to refresh client glyph data
        player:SendTalentsInfoData(false)

        AIO.Handle(player, "SurrealTalents", "GlyphApplied", socketIdx)
        player:SendBroadcastMessage("Glyph removed.")
    end
else
    ---------------------------------------------------------------------------
    -- CLIENT SIDE
    ---------------------------------------------------------------------------

    -- =================================================================
    --  C O N F I G U R A T I O N
    -- =================================================================

    local CFG = {
        -- Main frame ---------------------------------------------------
        FRAME_W     = 980,          -- total frame width
        FRAME_H     = 640,          -- total frame height

        -- Talent buttons -----------------------------------------------
        BTN_SIZE    = 40,           -- icon square size (px)

        -- Distance between button TOPLEFT anchors ----------------------
        SPACING_X   = 70,          -- horizontal (spec grid, 5 cols)
        SPACING_Y   = 46,          -- vertical (11 rows)

        -- Grid origin (offset from main frame TOPLEFT) -----------------
        GRID_X      = 330,         -- centre panel X
        GRID_Y      = -60,         -- below title

        -- Side trees (Class / Hero) — dummy placeholders ---------------
        SIDE_BTN    = 36,          -- dummy slot icon size
        SIDE_SPC    = 50,          -- spacing between slots
        SIDE_COLS   = 3,
        SIDE_ROWS   = 4,

        -- Glyph bar ---------------------------------------------------
        GLYPH_SIZE  = 30,          -- glyph icon size
        GLYPH_GAP   = 14,          -- gap between glyph slots

        -- Colours (R, G, B) – alpha set separately where needed --------
        BG          = { 0.06, 0.06, 0.10 },
        BG_A        = 0.95,
        EDGE        = { 0.30, 0.30, 0.35 },

        COL_MAXED   = { 0.85, 0.68, 0.00 },   -- gold
        COL_PARTIAL = { 0.00, 0.70, 0.00 },   -- green
        COL_AVAIL   = { 0.28, 0.28, 0.32 },   -- subtle grey
        COL_LOCKED  = { 0.13, 0.13, 0.15 },   -- dim

        GLOW_MAXED  = { 1.00, 0.82, 0.00 },
        GLOW_PART   = { 0.00, 0.80, 0.00 },

        TXT_MAXED   = { 1.00, 0.82, 0.00 },
        TXT_PARTIAL = { 0.00, 0.80, 0.00 },
        TXT_AVAIL   = { 0.65, 0.65, 0.65 },
        TXT_LOCKED  = { 0.38, 0.38, 0.38 },
    }

    -- =================================================================
    --  T A L E N T   L A Y O U T   O V E R R I D E S
    --
    --  Format:
    --    TALENT_LAYOUTS["CLASSTOKEN"][tabPage][talentIndex] = { row, col }
    --
    --  row / col are 1-based.  row 1 = top, col 1 = left.
    --  When no override exists the DBC position (tier, column) is used.
    --
    --  To discover talentIndex numbers run:   /surrealtalents debug
    --
    --  Example — move Warlock Affliction talent #3 to row 1, col 6:
    --
    --    TALENT_LAYOUTS["WARLOCK"] = {
    --        [1] = {                        -- tab 1  (Affliction)
    --            [3] = { 1, 6 },            -- talentIndex 3 → row 1 col 6
    --        },
    --    }
    -- =================================================================

    local TALENT_LAYOUTS = {
        -- Warlock starter layout — 5 cols × 11 rows per spec
        -- Talent index 1 = mastery (hidden), so indices start at 2
        ["WARLOCK"] = {
            [1] = {   -- Affliction (28 talents, #1=mastery)
                [2]  = { 1, 1 },  [3]  = { 1, 2 },  [4]  = { 1, 3 },
                [5]  = { 2, 1 },  [6]  = { 2, 2 },  [7]  = { 2, 3 },  [8]  = { 2, 4 },
                [9]  = { 3, 1 },  [10] = { 3, 2 },  [11] = { 3, 3 },
                [12] = { 4, 1 },  [13] = { 4, 1 },  [14] = { 4, 4 },
                [15] = { 5, 1 },  [16] = { 5, 2 },  [17] = { 5, 3 },
                [18] = { 6, 1 },  [19] = { 6, 2 },
                [20] = { 7, 1 },  [21] = { 7, 2 },  [22] = { 7, 3 },
                [23] = { 8, 1 },  [24] = { 8, 3 },
                [25] = { 9, 1 },  [26] = { 9, 2 },
                [27] = { 10, 1 }, [28] = { 10, 2 },
            },
            [2] = {   -- Demonology (27 talents, #1=mastery)
                [2]  = { 1, 1 },  [3]  = { 1, 2 },  [4]  = { 1, 3 },  [5]  = { 1, 4 },
                [6]  = { 2, 1 },  [7]  = { 2, 2 },  [8]  = { 2, 3 },
                [9]  = { 3, 1 },  [10] = { 3, 2 },  [11] = { 3, 3 },  [12] = { 3, 4 },
                [13] = { 4, 2 },  [14] = { 4, 3 },
                [15] = { 5, 1 },  [16] = { 5, 3 },
                [17] = { 6, 2 },  [18] = { 6, 3 },
                [19] = { 7, 1 },  [20] = { 7, 2 },  [21] = { 7, 3 },
                [22] = { 8, 2 },  [23] = { 8, 3 },
                [24] = { 9, 1 },  [25] = { 9, 2 },  [26] = { 9, 3 },
                [27] = { 10, 2 },
            },
            [3] = {   -- Destruction (26 talents, #1=mastery)
                [2]  = { 1, 2 },  [3]  = { 1, 3 },
                [4]  = { 2, 1 },  [5]  = { 2, 2 },  [6]  = { 2, 3 },
                [7]  = { 3, 1 },  [8]  = { 3, 2 },  [9]  = { 3, 3 },
                [10] = { 4, 1 },  [11] = { 4, 2 },  [12] = { 4, 4 },
                [13] = { 5, 1 },  [14] = { 5, 2 },  [15] = { 5, 3 },
                [16] = { 6, 1 },  [17] = { 6, 3 },
                [18] = { 7, 2 },  [19] = { 7, 3 },
                [20] = { 8, 1 },  [21] = { 8, 4 },
                [22] = { 9, 2 },  [23] = { 9, 3 },
                [24] = { 10, 1 }, [25] = { 10, 2 }, [26] = { 10, 3 },
            },
        },
        -- Add other classes here as needed
    }

    -- =================================================================
    --  C H O I C E   N O D E S
    --
    --  Format:
    --    CHOICE_NODES["CLASSTOKEN"][tabPage] = { {idxA, idxB}, ... }
    --
    --  Two talents sharing a grid cell — player picks one, the other
    --  becomes locked.  Both share the same TALENT_LAYOUTS position.
    --  The first talent in the pair renders on the LEFT half, the
    --  second on the RIGHT half.  A diamond-shaped border is drawn.
    --
    --  Example for Warlock Affliction tab, talents 12 and 13:
    --    CHOICE_NODES["WARLOCK"] = { [1] = { {12, 13} } }
    -- =================================================================
    local CHOICE_NODES = {
        ["WARLOCK"] = {
            [1] = { {12, 13} },  -- Affliction: talents 12 & 13 as choice node
        },
    }

    -- =================================================================
    --  I N T E R N A L   S T A T E
    -- =================================================================
    local activeTab   = 1
    local buttons     = {}
    local MAX_BTNS    = 60        -- button pool size (>= max talents per tree)
    local previewMode = true      -- preview on by default
    local resetCostCache = nil    -- cached from server
    local chosenSpecTab = nil     -- spec chosen via overlay (nil = none)
    local choiceSelected = {}     -- choiceSelected["tab-row-col"] = talentIdx

    -- Forward declarations
    local UpdateTalents
    local applyBtn, cancelBtn, resetBtn
    local classTreePanel, heroTreePanel, glyphFrame, glyphSlots

    -- AIO handlers for server → client messages
    local ClientHandlers = AIO.AddHandlers("SurrealTalents", {})

    -- =================================================================
    --  H E L P E R S
    -- =================================================================
    local function ClassToken()
        local _, tok = UnitClass("player")
        return tok
    end

    local function TalentGroup()
        return GetActiveTalentGroup(false, false) or 1
    end

    -- Choice node helpers (must be after ClassToken / TalentGroup)
    local function ChoicePartner(tab, idx)
        local cls = ClassToken()
        local cn = CHOICE_NODES[cls]
        if not cn or not cn[tab] then return nil end
        for _, pair in ipairs(cn[tab]) do
            if pair[1] == idx then return pair[2] end
            if pair[2] == idx then return pair[1] end
        end
        return nil
    end

    local function IsChoiceRight(tab, idx)
        local cls = ClassToken()
        local cn = CHOICE_NODES[cls]
        if not cn or not cn[tab] then return false end
        for _, pair in ipairs(cn[tab]) do
            if pair[2] == idx then return true end
        end
        return false
    end

    local function ChoiceBlocked(tab, idx)
        local partner = ChoicePartner(tab, idx)
        if not partner then return false end
        local tg = TalentGroup()
        local _, _, _, _, rank = GetTalentInfo(tab, partner, false, false, tg)
        return rank and rank > 0
    end

    local function Override(tab, idx)
        local c = TALENT_LAYOUTS[ClassToken()]
        if c and c[tab] and c[tab][idx] then
            return c[tab][idx]
        end
    end

    local function TalentPos(tab, idx)
        local ov = Override(tab, idx)
        if ov then return ov[1], ov[2] end
        local _, _, tier, col = GetTalentInfo(tab, idx)
        return tier, col
    end

    local function PrereqOK(tab, idx)
        local pTier, pCol, met = GetTalentPrereqs(tab, idx)
        if not pTier then return true end        -- no dependency
        return met and met ~= 0
    end

    -- Returns the tab where talent #1 (mastery) has rank > 0, or nil
    local function GetCommittedSpec()
        local tg = TalentGroup()
        for tab = 1, (GetNumTalentTabs() or 0) do
            local _, _, _, _, rank = GetTalentInfo(tab, 1, false, false, tg)
            if rank and rank > 0 then return tab end
        end
        return nil
    end

    -- Is a spec active (committed or chosen via overlay)?
    local function HasSpec()
        return GetCommittedSpec() or chosenSpecTab
    end

    -- =================================================================
    --  M A I N   F R A M E
    -- =================================================================
    local frame = CreateFrame("Frame", "SurrealTalentFrame", UIParent)
    frame:SetSize(CFG.FRAME_W, CFG.FRAME_H)
    frame:SetPoint("CENTER", 0, 30)
    frame:SetFrameStrata("HIGH")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop",  frame.StopMovingOrSizing)
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

    -- Escape-key closes the frame
    tinsert(UISpecialFrames, "SurrealTalentFrame")

    -- =================================================================
    --  T I T L E   B A R
    -- =================================================================
    local titleText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleText:SetPoint("TOP", 0, -14)
    titleText:SetText("")

    local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)

    -- Separator line below title
    local sep = frame:CreateTexture(nil, "ARTWORK")
    sep:SetTexture(0.40, 0.40, 0.45)
    sep:SetAlpha(0.35)
    sep:SetPoint("TOPLEFT", 10, -36)
    sep:SetPoint("TOPRIGHT", -10, -36)
    sep:SetHeight(1)

    -- =================================================================
    --  S P E C   T A B S
    -- =================================================================
    local tabBtns = {}

    local function RefreshTabLabels()
        for i = 1, 3 do
            local name, iconTex, pts = GetTalentTabInfo(i, false, false, TalentGroup())
            local tb = tabBtns[i]
            if tb and name then
                tb.label:SetText(name .. "  |cffffd100" .. (pts or 0) .. "|r")
                tb.icon:SetTexture(iconTex)
            end
        end
    end

    for i = 1, 3 do
        local tb = CreateFrame("Button", nil, frame)
        tb:SetSize(280, 30)
        tb:SetPoint("TOPLEFT", 40 + (i - 1) * 310, -38)

        tb:SetBackdrop({
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        tb:SetBackdropColor(0.10, 0.10, 0.14, 0.85)
        tb:SetBackdropBorderColor(0.40, 0.40, 0.45, 1)

        -- selected indicator (gold bar at bottom)
        local sel = tb:CreateTexture(nil, "OVERLAY")
        sel:SetTexture(1, 0.82, 0)
        sel:SetAlpha(0.45)
        sel:SetPoint("BOTTOMLEFT", 3, 2)
        sel:SetPoint("BOTTOMRIGHT", -3, 2)
        sel:SetHeight(2)
        sel:Hide()
        tb.sel = sel

        -- spec icon
        local icon = tb:CreateTexture(nil, "ARTWORK")
        icon:SetSize(20, 20)
        icon:SetPoint("LEFT", 6, 0)
        tb.icon = icon

        -- spec label
        local label = tb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("LEFT", icon, "RIGHT", 4, 0)
        label:SetPoint("RIGHT", -4, 0)
        label:SetJustifyH("LEFT")
        tb.label = label

        local tabIdx = i
        tb:SetScript("OnClick", function()
            SelectTab(tabIdx)
        end)

        tabBtns[i] = tb
    end

    -- =================================================================
    --  I N F O   B A R
    -- =================================================================
    local unspentText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    unspentText:SetPoint("TOPRIGHT", -16, -44)

    -- Distribution string (e.g. "20 / 51 / 0")
    local distText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    distText:SetPoint("BOTTOM", 0, 14)

    -- Bottom separator
    local sep2 = frame:CreateTexture(nil, "ARTWORK")
    sep2:SetTexture(0.40, 0.40, 0.45)
    sep2:SetAlpha(0.35)
    sep2:SetPoint("BOTTOMLEFT", 10, 36)
    sep2:SetPoint("BOTTOMRIGHT", -10, 36)
    sep2:SetHeight(1)

    -- =================================================================
    --  G R I D   C O N T A I N E R  (centre — spec talents)
    -- =================================================================
    local grid = CreateFrame("Frame", nil, frame)
    grid:SetSize(350, 510)
    grid:SetPoint("CENTER", 0, 10)

    -- =================================================================
    --  S I D E   P A N E L S  (Class Tree left / Hero Tree right)
    -- =================================================================
    local function MakeSidePanel(panelName, headerText, anchor, offX, offY)
        local cw = (CFG.SIDE_COLS - 1) * CFG.SIDE_SPC + CFG.SIDE_BTN
        local ch = (CFG.SIDE_ROWS - 1) * CFG.SIDE_SPC + CFG.SIDE_BTN
        local pw, ph = cw + 12, ch + 32

        local p = CreateFrame("Frame", panelName, frame)
        p:SetSize(pw, ph)
        p:SetPoint(anchor, offX, offY)
        -- No backdrop — borderless, blends into the main frame

        local hdr = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        hdr:SetPoint("TOP", 0, -2)
        hdr:SetText("|cffaaaacc" .. headerText .. "|r")
        p.header = hdr

        p.slots = {}
        for row = 1, CFG.SIDE_ROWS do
            for col = 1, CFG.SIDE_COLS do
                local s = CreateFrame("Frame", nil, p)
                s:SetSize(CFG.SIDE_BTN, CFG.SIDE_BTN)
                s:SetPoint("TOPLEFT",
                    6 + (col - 1) * CFG.SIDE_SPC,
                    -18 - (row - 1) * CFG.SIDE_SPC)

                local bg = s:CreateTexture(nil, "BACKGROUND")
                bg:SetAllPoints()
                bg:SetTexture(0.14, 0.14, 0.17)

                local ic = s:CreateTexture(nil, "ARTWORK")
                ic:SetPoint("TOPLEFT", 2, -2)
                ic:SetPoint("BOTTOMRIGHT", -2, 2)
                ic:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                ic:SetDesaturated(true)
                ic:SetAlpha(0.25)

                p.slots[#p.slots + 1] = s
            end
        end

        local cs = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        cs:SetPoint("BOTTOM", 0, 2)
        cs:SetText("|cff666666Coming Soon|r")

        p:Hide()
        return p
    end

    classTreePanel = MakeSidePanel("SurrealClassTree", "Class Tree",
        "LEFT", 16, 0)
    heroTreePanel  = MakeSidePanel("SurrealHeroTree",  "Hero Tree",
        "RIGHT", -16, 0)

    -- =================================================================
    --  G L Y P H   B A R
    -- =================================================================
    glyphFrame = CreateFrame("Frame", nil, frame)
    glyphFrame:SetSize(980, 68)
    glyphFrame:SetPoint("BOTTOM", 0, 8)
    glyphFrame:Hide()

    -- Major / Minor labels
    local majorLabel = glyphFrame:CreateFontString(nil, "OVERLAY",
        "GameFontNormalSmall")
    majorLabel:SetPoint("TOP", glyphFrame, "TOP", -140, 0)
    majorLabel:SetText("|cffaaaacc Major|r")

    local minorLabel = glyphFrame:CreateFontString(nil, "OVERLAY",
        "GameFontNormalSmall")
    minorLabel:SetPoint("TOP", glyphFrame, "TOP", 140, 0)
    minorLabel:SetText("|cffaaaacc Minor|r")

    local GLYPH_COUNT = 6
    -- Socket ordering: Major = indices 1,4,6   Minor = indices 2,3,5
    -- We display them grouped: [Major1 Major4 Major6] | [Minor2 Minor3 Minor5]
    local glyphOrder = {1, 4, 6, 2, 3, 5}  -- first 3 major, last 3 minor
    glyphSlots = {}

    local slotSize = CFG.GLYPH_SIZE
    local slotGap  = CFG.GLYPH_GAP
    local groupGap = 30  -- extra gap between major and minor groups

    -- Calculate positions: 3 major slots | gap | 3 minor slots
    local totalW = 6 * slotSize + 5 * slotGap + groupGap
    local startX = (980 - totalW) / 2

    -- Pending glyph state
    local pendingSocketIdx = nil   -- which socket the picker was opened for

    for slotPos = 1, GLYPH_COUNT do
        local socketIdx = glyphOrder[slotPos]
        local gBtn = CreateFrame("Button", "SurrealGlyphSlot" .. socketIdx,
            glyphFrame, "SecureActionButtonTemplate")
        gBtn:SetSize(slotSize, slotSize)

        -- Position: first 3 are major, then groupGap, then 3 minor
        local xOff
        if slotPos <= 3 then
            xOff = startX + (slotPos - 1) * (slotSize + slotGap)
        else
            xOff = startX + 3 * (slotSize + slotGap) + groupGap
                + (slotPos - 4) * (slotSize + slotGap)
        end
        gBtn:SetPoint("TOPLEFT", glyphFrame, "TOPLEFT", xOff, -14)

        local gbg = gBtn:CreateTexture(nil, "BACKGROUND")
        gbg:SetAllPoints()
        gbg:SetTexture(0.14, 0.14, 0.17)
        gBtn.bg = gbg

        -- Border highlight for pending glyph target
        local border = gBtn:CreateTexture(nil, "OVERLAY")
        border:SetPoint("TOPLEFT", -1, 1)
        border:SetPoint("BOTTOMRIGHT", 1, -1)
        border:SetTexture(1, 1, 1)
        border:SetAlpha(0)
        gBtn.border = border

        local gIcon = gBtn:CreateTexture(nil, "ARTWORK")
        gIcon:SetPoint("TOPLEFT", 2, -2)
        gIcon:SetPoint("BOTTOMRIGHT", -2, 2)
        gIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        gIcon:SetDesaturated(true)
        gIcon:SetAlpha(0.30)
        gBtn.icon = gIcon

        -- Type label under the slot
        local typeLabel = gBtn:CreateFontString(nil, "OVERLAY",
            "GameFontNormalSmall")
        typeLabel:SetPoint("TOP", gBtn, "BOTTOM", 0, -2)
        typeLabel:SetFont("Fonts\\FRIZQT__.TTF", 8)
        gBtn.typeLabel = typeLabel

        gBtn.socketIdx = socketIdx

        gBtn:SetScript("OnClick", function(self, button)
            -- Left-click: show glyph picker
            if button == "LeftButton" then
                ShowGlyphPicker(self.socketIdx)
            -- Right-click: remove glyph via server
            elseif button == "RightButton" then
                local enabled, gType, spellID = GetGlyphSocketInfo(self.socketIdx)
                if spellID and spellID > 0 then
                    -- Socket indices: client uses 1-6, server uses 0-5
                    AIO.Handle("SurrealTalents", "RemoveGlyph",
                        self.socketIdx - 1)
                end
            end
        end)

        gBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        gBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            local enabled, gType, spellID, iconPath =
                GetGlyphSocketInfo(self.socketIdx)
            if spellID and spellID > 0 then
                GameTooltip:SetGlyph(self.socketIdx)
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("|cff888888Right-click to remove|r")
            else
                local typeName = (gType == 1) and "Major" or "Minor"
                GameTooltip:SetText("Empty " .. typeName .. " Glyph Slot",
                    0.5, 0.5, 0.5)
                GameTooltip:AddLine("Left-click to add a glyph.", 0.7, 0.7, 0.7)
            end
            GameTooltip:Show()
        end)
        gBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

        glyphSlots[socketIdx] = gBtn
    end

    -- -----------------------------------------------------------------
    --  G L Y P H   P I C K E R   P O P U P
    -- -----------------------------------------------------------------
    local glyphPicker = CreateFrame("Frame", "SurrealGlyphPicker", frame)
    glyphPicker:SetSize(220, 300)
    glyphPicker:SetPoint("CENTER", 0, 0)
    glyphPicker:SetFrameStrata("DIALOG")
    glyphPicker:SetFrameLevel(frame:GetFrameLevel() + 20)
    glyphPicker:Hide()

    local pickerBg = glyphPicker:CreateTexture(nil, "BACKGROUND")
    pickerBg:SetAllPoints()
    pickerBg:SetTexture(0.08, 0.08, 0.10, 0.95)

    local pickerBorder = CreateFrame("Frame", nil, glyphPicker)
    pickerBorder:SetPoint("TOPLEFT", -1, 1)
    pickerBorder:SetPoint("BOTTOMRIGHT", 1, -1)
    pickerBorder:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14,
    })
    pickerBorder:SetBackdropBorderColor(0.4, 0.4, 0.5, 0.8)

    local pickerTitle = glyphPicker:CreateFontString(nil, "OVERLAY",
        "GameFontNormal")
    pickerTitle:SetPoint("TOP", 0, -10)

    local pickerClose = CreateFrame("Button", nil, glyphPicker,
        "UIPanelCloseButton")
    pickerClose:SetPoint("TOPRIGHT", 2, 2)
    pickerClose:SetScript("OnClick", function()
        glyphPicker:Hide()
    end)

    -- Scroll frame for glyph list
    local pickerScroll = CreateFrame("ScrollFrame",
        "SurrealGlyphPickerScroll", glyphPicker, "UIPanelScrollFrameTemplate")
    pickerScroll:SetPoint("TOPLEFT", 10, -30)
    pickerScroll:SetPoint("BOTTOMRIGHT", -30, 10)

    local pickerContent = CreateFrame("Frame", nil, pickerScroll)
    pickerContent:SetSize(180, 1)
    pickerScroll:SetScrollChild(pickerContent)

    local pickerButtons = {}
    local MAX_PICKER_BTNS = 40

    local pendingSocketIdx = nil  -- which socket the picker was opened for

    for pi = 1, MAX_PICKER_BTNS do
        local pb = CreateFrame("Button", "SurrealGlyphPick" .. pi,
            pickerContent)
        pb:SetSize(175, 24)
        pb:SetPoint("TOPLEFT", 0, -((pi - 1) * 25))

        local pbBg = pb:CreateTexture(nil, "BACKGROUND")
        pbBg:SetAllPoints()
        pbBg:SetTexture(0.15, 0.15, 0.18, 0.6)
        pb.bg = pbBg

        local pbIcon = pb:CreateTexture(nil, "ARTWORK")
        pbIcon:SetSize(20, 20)
        pbIcon:SetPoint("LEFT", 2, 0)
        pb.icon = pbIcon

        local pbText = pb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        pbText:SetPoint("LEFT", pbIcon, "RIGHT", 4, 0)
        pbText:SetPoint("RIGHT", -4, 0)
        pbText:SetJustifyH("LEFT")
        pb.label = pbText

        local pbHL = pb:CreateTexture(nil, "HIGHLIGHT")
        pbHL:SetAllPoints()
        pbHL:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
        pbHL:SetBlendMode("ADD")
        pbHL:SetAlpha(0.3)

        pb:Hide()
        pb.bag    = nil
        pb.slot   = nil
        pb.itemID = nil

        pb:SetScript("OnClick", function(self)
            if self.itemID and pendingSocketIdx then
                -- Send to server: apply glyph (server uses 0-5)
                AIO.Handle("SurrealTalents", "ApplyGlyph",
                    self.itemID, pendingSocketIdx - 1)
                glyphPicker:Hide()
            end
        end)

        pb:SetScript("OnEnter", function(self)
            if self.bag and self.slot then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetBagItem(self.bag, self.slot)
                GameTooltip:Show()
            end
        end)
        pb:SetScript("OnLeave", function() GameTooltip:Hide() end)

        pickerButtons[pi] = pb
    end

    -- Reusable hidden tooltip for scanning glyph items
    local scanTip = CreateFrame("GameTooltip", "SurrealGlyphScanTip",
        nil, "GameTooltipTemplate")
    scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")

    -- Scan bags for glyph items matching the given socket type
    function ShowGlyphPicker(socketIdx)
        pendingSocketIdx = socketIdx
        local _, gType = GetGlyphSocketInfo(socketIdx)
        local typeName = (gType == 1) and "Major" or "Minor"
        pickerTitle:SetText("|cffffd100" .. typeName .. " Glyphs|r")

        -- Hide all buttons first
        for pi = 1, MAX_PICKER_BTNS do
            pickerButtons[pi]:Hide()
        end

        local found = 0
        for bag = 0, 4 do
            local numSlots = GetContainerNumSlots(bag)
            for slot = 1, numSlots do
                local itemID = GetContainerItemID(bag, slot)
                if itemID then
                    local name, _, _, _, _, itemType, itemSubType,
                          _, _, tex = GetItemInfo(itemID)
                    -- In 3.3.5, itemType is "Glyph" for glyph items
                    if itemType and itemType == "Glyph" then
                        -- Scan tooltip to determine Major vs Minor
                        scanTip:ClearLines()
                        scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
                        scanTip:SetBagItem(bag, slot)
                        local isMajor = false
                        local isMinor = false
                        for li = 1, scanTip:NumLines() do
                            local lineObj = _G["SurrealGlyphScanTipTextLeft" .. li]
                            if lineObj then
                                local txt = lineObj:GetText() or ""
                                if txt:find("Major") then
                                    isMajor = true
                                    break
                                elseif txt:find("Minor") then
                                    isMinor = true
                                    break
                                end
                            end
                        end

                        local matchesType = (gType == 1 and isMajor)
                            or (gType == 2 and (isMinor or not isMajor))

                        if matchesType and name then
                            found = found + 1
                            if found <= MAX_PICKER_BTNS then
                                local pb = pickerButtons[found]
                                pb.bag    = bag
                                pb.slot   = slot
                                pb.itemID = itemID
                                pb.icon:SetTexture(tex or
                                    "Interface\\Icons\\INV_Misc_QuestionMark")
                                -- Strip "Glyph of " prefix for cleaner display
                                local display = name:gsub("^Glyph of ", "")
                                pb.label:SetText(display)
                                pb:Show()
                            end
                        end
                    end
                end
            end
        end

        -- Update content height for scrolling
        pickerContent:SetHeight(math.max(1, found * 25))

        -- If no glyphs found, show message
        if found == 0 then
            pickerButtons[1].icon:SetTexture(
                "Interface\\Icons\\INV_Misc_QuestionMark")
            pickerButtons[1].label:SetText("|cff888888No " .. typeName
                .. " glyphs in bags|r")
            pickerButtons[1].bag    = nil
            pickerButtons[1].slot   = nil
            pickerButtons[1].itemID = nil
            pickerButtons[1]:Show()
            pickerContent:SetHeight(25)
        end

        glyphPicker:Show()
    end

    local function RefreshGlyphs()
        for _, socketIdx in ipairs(glyphOrder) do
            local gBtn = glyphSlots[socketIdx]
            local enabled, gType, spellID, iconPath =
                GetGlyphSocketInfo(socketIdx)

            if spellID and spellID > 0 and iconPath then
                gBtn.icon:SetTexture(iconPath)
                gBtn.icon:SetDesaturated(false)
                gBtn.icon:SetAlpha(1)
                gBtn.bg:SetTexture(0.20, 0.20, 0.25)
                gBtn.typeLabel:SetText("")
                gBtn.border:SetAlpha(0)
            else
                gBtn.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                gBtn.icon:SetDesaturated(true)
                gBtn.icon:SetAlpha(0.30)
                gBtn.bg:SetTexture(0.14, 0.14, 0.17)
                gBtn.typeLabel:SetText("")
                gBtn.border:SetAlpha(0)
            end
        end
    end

    -- Register for glyph events (refresh display when client catches up)
    local glyphEventFrame = CreateFrame("Frame")
    glyphEventFrame:RegisterEvent("GLYPH_ADDED")
    glyphEventFrame:RegisterEvent("GLYPH_REMOVED")
    glyphEventFrame:RegisterEvent("GLYPH_UPDATED")
    glyphEventFrame:SetScript("OnEvent", function(self, event)
        RefreshGlyphs()
    end)

    -- =================================================================
    --  S P E C   C H O I C E   O V E R L A Y
    -- =================================================================
    local specOverlay = CreateFrame("Frame", nil, frame)
    specOverlay:SetAllPoints()
    specOverlay:SetFrameLevel(frame:GetFrameLevel() + 10)
    specOverlay:Hide()

    local specTitle = specOverlay:CreateFontString(nil, "OVERLAY",
        "GameFontNormalLarge")
    specTitle:SetPoint("TOP", 0, -100)
    specTitle:SetText("|cffffd100Choose Your Specialization|r")

    local specSubtitle = specOverlay:CreateFontString(nil, "OVERLAY",
        "GameFontNormal")
    specSubtitle:SetPoint("TOP", specTitle, "BOTTOM", 0, -8)
    specSubtitle:SetText("Select a mastery to begin building your talents.")

    local specBtns = {}
    for si = 1, 3 do
        local sb = CreateFrame("Button", nil, specOverlay)
        sb:SetSize(260, 280)
        sb:SetPoint("TOP", specOverlay, "TOP", (si - 2) * 290, -150)
        sb:SetBackdrop({
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        sb:SetBackdropColor(0.10, 0.10, 0.14, 0.90)
        sb:SetBackdropBorderColor(0.40, 0.40, 0.45, 1)

        -- Large spec icon
        local sIcon = sb:CreateTexture(nil, "ARTWORK")
        sIcon:SetSize(64, 64)
        sIcon:SetPoint("TOP", 0, -24)
        sb.specIcon = sIcon

        -- Spec name
        local sName = sb:CreateFontString(nil, "OVERLAY",
            "GameFontNormalLarge")
        sName:SetPoint("TOP", sIcon, "BOTTOM", 0, -10)
        sb.specName = sName

        -- Divider
        local sDivider = sb:CreateTexture(nil, "ARTWORK")
        sDivider:SetTexture(0.40, 0.40, 0.45)
        sDivider:SetAlpha(0.35)
        sDivider:SetPoint("LEFT", 16, 0)
        sDivider:SetPoint("RIGHT", -16, 0)
        sDivider:SetPoint("TOP", sName, "BOTTOM", 0, -8)
        sDivider:SetHeight(1)

        -- Mastery talent icon
        local mIcon = sb:CreateTexture(nil, "ARTWORK")
        mIcon:SetSize(36, 36)
        mIcon:SetPoint("TOP", sDivider, "BOTTOM", 0, -12)
        sb.masteryIcon = mIcon

        -- Mastery talent name
        local mName = sb:CreateFontString(nil, "OVERLAY",
            "GameFontNormal")
        mName:SetPoint("TOP", mIcon, "BOTTOM", 0, -6)
        mName:SetWidth(230)
        sb.masteryName = mName

        -- "Select" label at bottom
        local selectLabel = sb:CreateFontString(nil, "OVERLAY",
            "GameFontNormalSmall")
        selectLabel:SetPoint("BOTTOM", 0, 12)
        selectLabel:SetText("|cff888888Click to select|r")
        sb.selectLabel = selectLabel

        -- Hover effects
        sb.tabIdx = si
        sb:SetScript("OnEnter", function(self)
            self:SetBackdropColor(0.18, 0.18, 0.25, 0.95)
            self:SetBackdropBorderColor(1, 0.82, 0, 1)
            self.selectLabel:SetText("|cffffd100Click to select|r")
            if self.tabIdx then
                GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
                GameTooltip:SetTalent(self.tabIdx, 1, false, false,
                    TalentGroup())
                GameTooltip:Show()
            end
        end)
        sb:SetScript("OnLeave", function(self)
            self:SetBackdropColor(0.10, 0.10, 0.14, 0.90)
            self:SetBackdropBorderColor(0.40, 0.40, 0.45, 1)
            self.selectLabel:SetText("|cff888888Click to select|r")
            GameTooltip:Hide()
        end)

        local specIdx = si
        sb:SetScript("OnClick", function()
            chosenSpecTab = specIdx
            AddPreviewTalentPoints(specIdx, 1, 1, false, TalentGroup())
            activeTab = specIdx
            UpdateTalents()
        end)

        specBtns[si] = sb
    end

    local function RefreshSpecOverlay()
        local tg = TalentGroup()
        local numTabs = GetNumTalentTabs() or 0
        for si = 1, 3 do
            local sb = specBtns[si]
            if si <= numTabs then
                local tabName, tabIcon =
                    GetTalentTabInfo(si, false, false, tg)
                local talentName, talentIcon =
                    GetTalentInfo(si, 1, false, false, tg)
                sb.specIcon:SetTexture(tabIcon)
                sb.specName:SetText(tabName or ("Spec " .. si))
                sb.masteryIcon:SetTexture(talentIcon)
                sb.masteryName:SetText("|cff88ccff" ..
                    (talentName or "Mastery") .. "|r")
                sb:Show()
            else
                sb:Hide()
            end
        end
    end

    -- =================================================================
    --  T A L E N T   B U T T O N   P O O L
    -- =================================================================
    for i = 1, MAX_BTNS do
        local btn = CreateFrame("Button", "SurrealTalentBtn" .. i, grid)
        btn:SetSize(CFG.BTN_SIZE, CFG.BTN_SIZE)
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        btn:Hide()

        -- Coloured border / background behind the icon (2 px inset)
        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(0.15, 0.15, 0.18)
        btn.bg = bg

        -- Talent icon
        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", 2, -2)
        icon:SetPoint("BOTTOMRIGHT", -2, 2)
        btn.icon = icon

        -- Glow (additive ring, only shown on learned talents)
        local glow = btn:CreateTexture(nil, "OVERLAY")
        glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        glow:SetBlendMode("ADD")
        glow:SetPoint("CENTER")
        glow:SetSize(CFG.BTN_SIZE * 1.45, CFG.BTN_SIZE * 1.45)
        glow:Hide()
        btn.glow = glow

        -- Rank text  (bottom-right, e.g. "3/5")
        local rk = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        rk:SetPoint("BOTTOMRIGHT", 0, 0)
        btn.rankText = rk

        -- Hover highlight
        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
        hl:SetBlendMode("ADD")
        hl:SetPoint("TOPLEFT", 2, -2)
        hl:SetPoint("BOTTOMRIGHT", -2, 2)

        -- Data (filled during Update)
        btn.tTab = nil
        btn.tIdx = nil

        -- Left-click = add point, Right-click = remove preview point
        btn:SetScript("OnClick", function(self, button)
            if self.tTab and self.tIdx then
                local partner = ChoicePartner(self.tTab, self.tIdx)

                -- Choice node left-click: select this talent + add point
                if partner and button == "LeftButton" then
                    -- Mark this as the chosen talent
                    local r, c = TalentPos(self.tTab, self.tIdx)
                    local key = self.tTab .. "-" .. r .. "-" .. c
                    choiceSelected[key] = self.tIdx
                    if previewMode then
                        AddPreviewTalentPoints(self.tTab, self.tIdx, 1,
                            false, TalentGroup())
                    else
                        LearnTalent(self.tTab, self.tIdx)
                    end
                    return
                end

                -- Choice node right-click: remove preview point
                if partner and button == "RightButton" then
                    if previewMode then
                        AddPreviewTalentPoints(self.tTab, self.tIdx, -1,
                            false, TalentGroup())
                        -- If rank drops to 0, clear selection so both show again
                        local tg = TalentGroup()
                        local _, _, _, _, rk, _, _, _, prev =
                            GetTalentInfo(self.tTab, self.tIdx, false, false, tg)
                        local dr = rk or 0
                        if prev and prev > dr then dr = prev end
                        if dr <= 0 then
                            local r2, c2 = TalentPos(self.tTab, self.tIdx)
                            local k2 = self.tTab .. "-" .. r2 .. "-" .. c2
                            choiceSelected[k2] = nil
                            UpdateTalents()
                        end
                    end
                    return
                end

                -- Normal talent handling
                if ChoiceBlocked(self.tTab, self.tIdx) then
                    return
                end
                if previewMode then
                    if button == "RightButton" then
                        AddPreviewTalentPoints(self.tTab, self.tIdx, -1,
                            false, TalentGroup())
                    else
                        AddPreviewTalentPoints(self.tTab, self.tIdx, 1,
                            false, TalentGroup())
                    end
                else
                    if button == "LeftButton" then
                        LearnTalent(self.tTab, self.tIdx)
                    end
                end
            end
        end)

        -- Tooltip
        btn:SetScript("OnEnter", function(self)
            if self.tTab and self.tIdx then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetTalent(self.tTab, self.tIdx, false, false, TalentGroup())
                local partner = ChoicePartner(self.tTab, self.tIdx)
                if partner then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine("|cffaaaacc\226\151\134 Choice Node|r")
                    GameTooltip:AddLine("|cff888888Click to choose this talent|r")
                end
                GameTooltip:Show()
            end
        end)
        btn:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        buttons[i] = btn
    end

    -- =================================================================
    --  U P D A T E   /   R E F R E S H
    -- =================================================================
    UpdateTalents = function()
        local tab = activeTab
        local tg  = TalentGroup()

        -- Spec state check
        local committed = GetCommittedSpec()
        local specActive = committed or chosenSpecTab

        if not specActive then
            -- No spec chosen — show spec choice overlay
            specOverlay:Show()
            RefreshSpecOverlay()
            grid:Hide()
            for si, tb in ipairs(tabBtns) do tb:Hide() end
            for bi = 1, MAX_BTNS do buttons[bi]:Hide() end
            unspentText:Hide()
            distText:Hide()
            sep:Hide()
            sep2:Hide()
            applyBtn:Hide()
            cancelBtn:Hide()
            classTreePanel:Hide()
            heroTreePanel:Hide()
            glyphFrame:Hide()
            titleText:SetText("|cffffd100Choose Your Specialization|r")
            -- Show reset if player has legacy talents (no mastery)
            local totalPts = 0
            for t = 1, (GetNumTalentTabs() or 0) do
                local _, _, pts = GetTalentTabInfo(t, false, false, tg)
                totalPts = totalPts + (pts or 0)
            end
            if totalPts > 0 then
                resetBtn:Show()
            else
                resetBtn:Hide()
            end
            return
        end

        -- Spec active — hide overlay, show normal UI
        specOverlay:Hide()
        grid:Show()
        resetBtn:Show()
        unspentText:Show()
        distText:Hide()
        sep:Hide()
        sep2:Hide()
        classTreePanel:Show()
        heroTreePanel:Show()
        glyphFrame:Show()
        RefreshGlyphs()

        local specTab = committed or chosenSpecTab
        activeTab = specTab  -- lock to chosen spec tree
        local tab = activeTab
        local specName = GetTalentTabInfo(specTab, false, false, tg)
        titleText:SetText("|cffffd100" ..
            (specName or "Unknown") .. "|r")

        -- Tabs — hide all (player is locked to one spec)
        for i, tb in ipairs(tabBtns) do
            tb:Hide()
        end

        -- Unspent
        local usp = GetUnspentTalentPoints(false, false, tg) or 0
        local previewSpent = 0
        if previewMode then
            previewSpent = GetGroupPreviewTalentPointsSpent(false, tg) or 0
        end
        local effectiveUnspent = usp - previewSpent
        if previewMode and previewSpent > 0 then
            unspentText:SetText("Unspent: |cffffd100" .. effectiveUnspent ..
                "|r  (|cffff8800" .. previewSpent .. " queued|r)")
        else
            unspentText:SetText("Unspent: |cffffd100" .. usp .. "|r")
        end

        -- Hide the whole pool
        for i = 1, MAX_BTNS do buttons[i]:Hide() end

        -- Populate active tab (skip talent #1 = mastery)
        local num = GetNumTalents(tab) or 0
        for i = 2, math.min(num, MAX_BTNS) do
            local name, iconTex, tier, col, rank, maxRank,
                  isExcept, avail, previewRank, previewAvail =
                GetTalentInfo(tab, i, false, false, tg)

            if name and iconTex then
                local btn   = buttons[i]
                btn.tTab    = tab
                btn.tIdx    = i

                -- In preview mode use previewRank for display
                local displayRank = rank
                if previewMode and previewRank and previewRank > rank then
                    displayRank = previewRank
                end

                -- Choice node handling
                local partner = ChoicePartner(tab, i)
                local isRight = IsChoiceRight(tab, i)
                local choiceBlock = ChoiceBlocked(tab, i)

                -- If this talent is blocked by its choice partner, skip it
                if not choiceBlock then

                -- Position
                local r, c  = TalentPos(tab, i)
                btn:ClearAllPoints()
                if btn.choiceSwap then btn.choiceSwap:Hide() end

                -- Determine if this choice pair is resolved
                local choiceResolved = false
                local choiceWinner   = false   -- true if THIS talent is the winner
                if partner then
                    local key = tab .. "-" .. r .. "-" .. c
                    local sel = choiceSelected[key]
                    local hasPoints = displayRank > 0
                    -- Check partner points
                    local _, _, _, _, pRank, _, _, _, pPrev =
                        GetTalentInfo(tab, partner, false, false, tg)
                    local partnerPts = (pRank or 0)
                    if previewMode and pPrev and pPrev > partnerPts then
                        partnerPts = pPrev
                    end
                    if hasPoints or partnerPts > 0 or sel then
                        choiceResolved = true
                        choiceWinner = hasPoints or (sel == i)
                    end
                end

                if partner and choiceResolved and not choiceWinner then
                    -- Loser in a resolved choice — hide completely and skip
                    btn:Hide()
                else

                if partner and not choiceResolved then
                    -- UNRESOLVED: show both at half-width, side by side
                    local halfW = math.floor(CFG.BTN_SIZE / 2) - 1
                    btn:SetSize(halfW, CFG.BTN_SIZE)
                    local cellX = (c - 1) * CFG.SPACING_X
                    local cellY = -((r - 1) * CFG.SPACING_Y)
                    if isRight then
                        btn:SetPoint("TOPLEFT", grid, "TOPLEFT",
                            cellX + halfW + 2, cellY)
                    else
                        btn:SetPoint("TOPLEFT", grid, "TOPLEFT",
                            cellX, cellY)
                    end
                    btn.icon:SetPoint("TOPLEFT", 2, -2)
                    btn.icon:SetPoint("BOTTOMRIGHT", -2, 2)
                    btn.rankText:Hide()
                else
                    -- Normal talent OR resolved choice winner: full size
                    btn:SetSize(CFG.BTN_SIZE, CFG.BTN_SIZE)
                    btn:SetPoint("TOPLEFT", grid, "TOPLEFT",
                        (c - 1) * CFG.SPACING_X,
                        -((r - 1) * CFG.SPACING_Y))
                    btn.icon:SetPoint("TOPLEFT", 2, -2)
                    btn.icon:SetPoint("BOTTOMRIGHT", -2, 2)
                    btn.rankText:Show()
                end

                -- Icon
                btn.icon:SetTexture(iconTex)

                -- Rank label — show preview ranks in orange
                local isPreview = previewMode and previewRank and previewRank > rank
                if isPreview then
                    btn.rankText:SetText("|cffff8800" .. displayRank ..
                        "|r/" .. maxRank)
                else
                    btn.rankText:SetText(displayRank .. "/" .. maxRank)
                end

                -- Visual state
                local ok = PrereqOK(tab, i)

                if displayRank >= maxRank then
                    -- MAXED (or preview-maxed)
                    if isPreview then
                        btn.bg:SetTexture(0.70, 0.45, 0.00)   -- orange border
                    else
                        btn.bg:SetTexture(CFG.COL_MAXED[1], CFG.COL_MAXED[2],
                            CFG.COL_MAXED[3])
                    end
                    btn.icon:SetDesaturated(false)
                    btn.icon:SetAlpha(1)
                    btn.glow:SetVertexColor(CFG.GLOW_MAXED[1],
                        CFG.GLOW_MAXED[2], CFG.GLOW_MAXED[3])
                    btn.glow:SetAlpha(0.55)
                    btn.glow:Show()
                    btn.rankText:SetTextColor(CFG.TXT_MAXED[1],
                        CFG.TXT_MAXED[2], CFG.TXT_MAXED[3])

                elseif displayRank > 0 then
                    -- PARTIAL (or preview-partial)
                    if isPreview then
                        btn.bg:SetTexture(0.70, 0.45, 0.00)
                    else
                        btn.bg:SetTexture(CFG.COL_PARTIAL[1],
                            CFG.COL_PARTIAL[2], CFG.COL_PARTIAL[3])
                    end
                    btn.icon:SetDesaturated(false)
                    btn.icon:SetAlpha(1)
                    btn.glow:SetVertexColor(CFG.GLOW_PART[1],
                        CFG.GLOW_PART[2], CFG.GLOW_PART[3])
                    btn.glow:SetAlpha(0.40)
                    btn.glow:Show()
                    btn.rankText:SetTextColor(CFG.TXT_PARTIAL[1],
                        CFG.TXT_PARTIAL[2], CFG.TXT_PARTIAL[3])

                elseif ok then
                    btn.bg:SetTexture(CFG.COL_AVAIL[1], CFG.COL_AVAIL[2],
                        CFG.COL_AVAIL[3])
                    btn.icon:SetDesaturated(false)
                    btn.icon:SetAlpha(0.85)
                    btn.glow:Hide()
                    btn.rankText:SetTextColor(CFG.TXT_AVAIL[1],
                        CFG.TXT_AVAIL[2], CFG.TXT_AVAIL[3])
                else
                    btn.bg:SetTexture(CFG.COL_LOCKED[1], CFG.COL_LOCKED[2],
                        CFG.COL_LOCKED[3])
                    btn.icon:SetDesaturated(true)
                    btn.icon:SetAlpha(0.55)
                    btn.glow:Hide()
                    btn.rankText:SetTextColor(CFG.TXT_LOCKED[1],
                        CFG.TXT_LOCKED[2], CFG.TXT_LOCKED[3])
                end

                btn:Show()
                end -- close choice loser guard
                end -- close choiceBlock guard
            end
        end

        -- Show/hide preview action buttons
        UpdateActionButtons()
    end

    -- Exposed for tab buttons
    function SelectTab(t)
        activeTab = t
        UpdateTalents()
    end

    -- =================================================================
    --  A C T I O N   B U T T O N S  (bottom bar)
    -- =================================================================

    -- Helper to make a styled button
    local function MakeButton(name, w, parent, anchor, ax, ay)
        local b = CreateFrame("Button", name, parent)
        b:SetSize(w, 24)
        b:SetPoint(anchor, ax, ay)
        b:SetBackdrop({
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        b:SetBackdropColor(0.12, 0.12, 0.16, 0.9)
        b:SetBackdropBorderColor(0.40, 0.40, 0.45, 1)
        local t = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        t:SetPoint("CENTER")
        b.text = t
        -- Hover highlight
        b:SetScript("OnEnter", function(self)
            self:SetBackdropColor(0.20, 0.20, 0.28, 0.95)
        end)
        b:SetScript("OnLeave", function(self)
            self:SetBackdropColor(0.12, 0.12, 0.16, 0.9)
        end)
        return b
    end

    -- -- "Apply" — commit previewed talents -- --
    applyBtn = MakeButton("SurrealTalentApply", 90, frame,
        "BOTTOMLEFT", 16, 8)
    applyBtn.text:SetText("|cff00cc00Apply|r")
    applyBtn:SetScript("OnClick", function()
        LearnPreviewTalents(false)
        UpdateTalents()
    end)
    applyBtn:Hide()

    -- -- "Cancel" — discard preview -- --
    cancelBtn = CreateFrame("Button", "SurrealTalentCancel", frame)
    cancelBtn:SetSize(90, 24)
    cancelBtn:SetPoint("LEFT", applyBtn, "RIGHT", 6, 0)
    cancelBtn:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    cancelBtn:SetBackdropColor(0.12, 0.12, 0.16, 0.9)
    cancelBtn:SetBackdropBorderColor(0.40, 0.40, 0.45, 1)
    cancelBtn.text = cancelBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    cancelBtn.text:SetPoint("CENTER")
    cancelBtn.text:SetText("|cffcc0000Cancel|r")
    cancelBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.20, 0.20, 0.28, 0.95)
    end)
    cancelBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.12, 0.12, 0.16, 0.9)
    end)
    cancelBtn:SetScript("OnClick", function()
        ResetGroupPreviewTalentPoints(false, TalentGroup())
        chosenSpecTab = nil  -- back to spec choice if no committed spec
        UpdateTalents()
    end)
    cancelBtn:Hide()

    -- -- "Reset Talents" — ask server for cost then confirm -- --
    resetBtn = MakeButton("SurrealTalentReset", 120, frame,
        "BOTTOMRIGHT", -16, 8)
    resetBtn.text:SetText("Reset Talents")
    resetBtn:SetScript("OnClick", function()
        -- Ask server for reset cost
        AIO.Handle("SurrealTalents", "GetResetCost")
    end)

    -- Confirmation dialog (static popup style)
    StaticPopupDialogs["SURREAL_TALENT_RESET"] = {
        text = "Reset all talents?\n\nCost: %s",
        button1 = "Reset",
        button2 = "Cancel",
        OnAccept = function()
            AIO.Handle("SurrealTalents", "ConfirmReset")
        end,
        timeout = 0,
        whileDead = false,
        hideOnEscape = true,
        preferredIndex = 3,
    }

    -- Format copper → gold string
    local function GoldStr(copper)
        copper = copper or 0
        local g = math.floor(copper / 10000)
        local s = math.floor((copper % 10000) / 100)
        local c = copper % 100
        local parts = {}
        if g > 0 then parts[#parts + 1] = "|cffffd100" .. g .. "g|r" end
        if s > 0 then parts[#parts + 1] = "|cffc0c0c0" .. s .. "s|r" end
        if c > 0 or #parts == 0 then
            parts[#parts + 1] = "|cffb87333" .. c .. "c|r"
        end
        return table.concat(parts, " ")
    end

    -- Server → Client: show reset cost dialog
    function ClientHandlers.ShowResetCost(player, cost)
        resetCostCache = cost
        StaticPopup_Show("SURREAL_TALENT_RESET", GoldStr(cost))
    end

    -- Server → Client: reset completed
    function ClientHandlers.ResetDone(player, newCost)
        resetCostCache = newCost
        chosenSpecTab = nil  -- talents reset, back to spec choice
        UpdateTalents()
    end

    -- Server → Client: glyph applied/removed, refresh display
    function ClientHandlers.GlyphApplied(player, socketIdx)
        -- Give the client a moment to receive the talent data update
        local refresher = CreateFrame("Frame")
        refresher.elapsed = 0
        refresher:SetScript("OnUpdate", function(self, dt)
            self.elapsed = self.elapsed + dt
            if self.elapsed > 0.3 then
                RefreshGlyphs()
                self:SetScript("OnUpdate", nil)
            end
        end)
    end

    -- Show/hide Apply/Cancel based on whether preview points are queued
    function UpdateActionButtons()
        if not previewMode then
            applyBtn:Hide()
            cancelBtn:Hide()
            return
        end
        local queued = GetGroupPreviewTalentPointsSpent(false, TalentGroup()) or 0
        if queued > 0 then
            applyBtn:Show()
            cancelBtn:Show()
        else
            applyBtn:Hide()
            cancelBtn:Hide()
        end
    end

    -- =================================================================
    --  E V E N T S
    -- =================================================================
    frame:RegisterEvent("CHARACTER_POINTS_CHANGED")
    frame:RegisterEvent("PLAYER_TALENT_UPDATE")
    frame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
    frame:RegisterEvent("PREVIEW_TALENT_POINTS_CHANGED")
    frame:RegisterEvent("GLYPH_ADDED")
    frame:RegisterEvent("GLYPH_REMOVED")
    frame:RegisterEvent("GLYPH_UPDATED")

    frame:SetScript("OnEvent", function(self)
        if self:IsShown() then UpdateTalents() end
    end)
    frame:SetScript("OnShow", function()
        -- Clear stale preview state when opening
        if previewMode then
            ResetGroupPreviewTalentPoints(false, TalentGroup())
        end
        chosenSpecTab = nil  -- reset spec preview on frame open
        UpdateTalents()

        -- Close other frames if open (mutual exclusion)
        if SurrealCollections and SurrealCollections:IsShown() then
            SurrealCollections:Hide()
        end
        if SurrealCharacterFrame and SurrealCharacterFrame:IsShown() then
            SurrealCharacterFrame:Hide()
        end
        if SurrealSpellBook and SurrealSpellBook:IsShown() then
            SurrealSpellBook:Hide()
        end
    end)

    -- =================================================================
    --  K E Y B I N D   /   T O G G L E   H O O K
    -- =================================================================

    -- Replace the global ToggleTalentFrame so pressing N opens this frame
    -- instead of loading Blizzard_TalentUI.
    ToggleTalentFrame = function()
        if SurrealTalentFrame:IsShown() then
            SurrealTalentFrame:Hide()
        else
            SurrealTalentFrame:Show()
        end
    end

    -- Also override PlayerTalentFrame_Toggle to prevent Blizzard UI
    -- from loading at all (UIParent.lua calls this on keybind press).
    PlayerTalentFrame_Toggle = ToggleTalentFrame

    -- Kill the load-on-demand trigger that the default UI uses
    if UIParentLoadAddOn then
        local origLoad = UIParentLoadAddOn
        UIParentLoadAddOn = function(name)
            if name == "Blizzard_TalentUI" then return end
            return origLoad(name)
        end
    end

    -- Also hook the micro-menu Talent button & prevent Blizzard UI loading
    local loader = CreateFrame("Frame")
    loader:RegisterEvent("PLAYER_ENTERING_WORLD")
    loader:RegisterEvent("ADDON_LOADED")
    loader:SetScript("OnEvent", function(self, event, addon)
        -- Hook micro-button (works on click AND tooltip hover-click)
        if TalentMicroButton then
            TalentMicroButton:SetScript("OnClick", function()
                ToggleTalentFrame()
            end)
            -- Override the tooltip to reference our frame
            TalentMicroButton:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText("Talents", 1, 1, 1)
                GameTooltip:AddLine("View and customize your talents.",
                    nil, nil, nil, true)
                GameTooltip:Show()
            end)
            TalentMicroButton:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)
        end

        -- If Blizzard talent UI loaded, kill it
        if PlayerTalentFrame then
            PlayerTalentFrame:UnregisterAllEvents()
            PlayerTalentFrame:Hide()
            PlayerTalentFrame:SetScript("OnShow", function(f)
                f:Hide()
                ToggleTalentFrame()
            end)
        end

        -- Intercept the Blizzard addon before it can set up
        if event == "ADDON_LOADED" and addon == "Blizzard_TalentUI" then
            if PlayerTalentFrame then
                PlayerTalentFrame:UnregisterAllEvents()
                PlayerTalentFrame:Hide()
                PlayerTalentFrame:SetScript("OnShow", function(f)
                    f:Hide()
                    ToggleTalentFrame()
                end)
            end
        end

        -- Intercept Blizzard glyph UI — redirect to our talent frame
        if event == "ADDON_LOADED" and addon == "Blizzard_GlyphUI" then
            if GlyphFrame then
                GlyphFrame:UnregisterAllEvents()
                GlyphFrame:Hide()
                GlyphFrame:SetScript("OnShow", function(f)
                    f:Hide()
                    if not SurrealTalentFrame:IsShown() then
                        SurrealTalentFrame:Show()
                    end
                end)
            end
        end
    end)

    -- =================================================================
    --  S L A S H   C O M M A N D
    -- =================================================================
    SLASH_SURREALTALENTS1 = "/surrealtalents"
    SlashCmdList["SURREALTALENTS"] = function(msg)
        msg = (msg or ""):lower()
        if msg == "debug" then
            local cls = ClassToken()
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff00ff00[SurrealTalents]|r class = " .. cls)
            for tab = 1, GetNumTalentTabs() do
                local tname = GetTalentTabInfo(tab) or "?"
                DEFAULT_CHAT_FRAME:AddMessage(
                    "|cff88ccff--- " .. tname .. "  (tab " .. tab .. ") ---|r")
                for idx = 1, GetNumTalents(tab) do
                    local name, _, tier, col, rank, maxRank =
                        GetTalentInfo(tab, idx)
                    if name then
                        local ov = Override(tab, idx)
                        local posStr = "tier=" .. tier .. " col=" .. col
                        if ov then
                            posStr = posStr ..
                                "  |cffff8800-> override row=" ..
                                ov[1] .. " col=" .. ov[2] .. "|r"
                        end
                        DEFAULT_CHAT_FRAME:AddMessage(string.format(
                            "  |cffffd100[%2d]|r %-30s  %s  (%d/%d)",
                            idx, name, posStr, rank, maxRank))
                    end
                end
            end
        elseif msg == "reset" then
            SurrealTalentFrame:ClearAllPoints()
            SurrealTalentFrame:SetPoint("CENTER", 0, 30)
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff00ff00[SurrealTalents]|r Frame position reset.")
        else
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff00ff00/surrealtalents debug|r — list all talent indices & grid positions")
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cff00ff00/surrealtalents reset|r — reset frame position to centre")
        end
    end

    -- =================================================================
    --  I N I T
    -- =================================================================
    DEFAULT_CHAT_FRAME:AddMessage(
        "|cff00ff00[SurrealUI]|r Talent Frame loaded.  Press |cffffd100N|r to open.")
end

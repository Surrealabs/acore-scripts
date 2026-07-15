-------------------------------------------------------------------------------
-- SurrealTalentFrame_AIO.lua
--
-- Replaces the default WoTLK talent frame with a modern, wider layout.
-- Talent grid positions are read directly from the DBC (TierID / ColumnIndex).
-- Use the Talent Layout Editor (web) to visually arrange talents and save
-- positions back into Talent.dbc.
--
-- Usage:
--   Press N to open the talent frame (same binding as default)
--   /surrealtalents debug  — prints all talent indices & DBC grid positions
--
-- Configuration:
--   Edit CFG for grid dimensions, button size, spacing, and colours.
-------------------------------------------------------------------------------

local AIO = AIO or require("AIO")

if AIO.AddAddon() then
    ---------------------------------------------------------------------------
    -- SERVER SIDE
    -- Server logic has been moved to SurrealTalentServer_AIO.lua.
    -- This block is intentionally empty — AIO.AddAddon() returns true on
    -- the server, so the client-side code below won't run there.
    ---------------------------------------------------------------------------

else
    ---------------------------------------------------------------------------
    -- CLIENT SIDE
    ---------------------------------------------------------------------------

    -- =================================================================
    --  C U S T O M   T A L E N T   D A T A   L A Y E R
    --
    --  Replaces WoW's native talent API (GetTalentInfo, LearnTalent, etc.)
    --  with versions backed by SURREAL_TALENT_TREES (shared config) and
    --  server-pushed player state.  All existing UI code continues to work
    --  by calling these local functions instead of the global WoW APIs.
    -- =================================================================

    local BlizzardGetUnspentTalentPoints = _G.GetUnspentTalentPoints
    local BlizzardLearnTalent = _G.LearnTalent
    local BlizzardIsSpellKnown = _G.IsSpellKnown or _G.IsPlayerSpell
    local TALENT_DEBUG = false

    local function DebugTalent(msg)
        if TALENT_DEBUG and DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
            DEFAULT_CHAT_FRAME:AddMessage("|cff7dd3fc[SurrealTalents]|r " .. tostring(msg))
        end
    end

    -- The server sends us talent state via AIO; we store it here.
    local ST_playerTalents   = {}   -- {talentId = rank}
    local ST_spent           = 0
    local ST_maxPoints       = 0
    local ST_unspent         = 0
    local ST_tabPointInfo    = {}   -- {[tabIdx] = {name=, points=}}
    local ST_previewPoints   = {}   -- {talentId = delta} (preview mode)
    local ST_previewSpent    = 0
    local ST_dataReady       = false
    local ST_waitingForServer = false
    local ST_waitReason = nil

    -- Build ordered talent lists from tree config (sorted by row, col)
    -- These are indexed by [tabIdx][orderedIndex] = {talentId, def}
    local _, ST_classToken = UnitClass("player")

    -- 3.3.5a UnitClass only returns 2 values (name, token).
    -- classId (3rd return) was added in MoP 5.0, so we map it ourselves.
    local CLASS_TOKEN_TO_ID = {
        WARRIOR = 1, PALADIN = 2, HUNTER = 3, ROGUE = 4,
        PRIEST = 5, DEATHKNIGHT = 6, SHAMAN = 7, MAGE = 8,
        WARLOCK = 9, DRUID = 11,
    }
    local ST_classId = CLASS_TOKEN_TO_ID[ST_classToken]
    local ST_classTrees = SURREAL_TALENT_TREES and SURREAL_TALENT_TREES[ST_classId]
    local ST_orderedTalents = {}  -- [tabIdx] = {{id=, def=}, ...}
    local ST_talentIndex    = {}  -- [tabIdx][talentId] = orderedIdx

    -- Bot-editing target (nil = editing your own talents). Set via
    -- SetEditTarget() / the exposed _G.SurrealTalentFrame_OpenFor entry
    -- point used by the Army panel's "Edit Full Build" button. Only talent
    -- points are supported for bot targets — glyph slots stay disabled.
    local ST_editTarget = nil

    local function SetEditTarget(name, classId)
        ST_editTarget = name
        local newClassId = classId or CLASS_TOKEN_TO_ID[ST_classToken]
        if newClassId ~= ST_classId then
            ST_classId = newClassId
            ST_classTrees = SURREAL_TALENT_TREES and SURREAL_TALENT_TREES[ST_classId]
            ST_orderedTalents = {}
            ST_talentIndex = {}
        end
        ST_dataReady = false
        if UpdateEditTargetBanner then UpdateEditTargetBanner() end
    end

    _G.SurrealTalentFrame_OpenFor = function(name, classId)
        SetEditTarget(name, classId)
        if SurrealTalentFrame then
            SurrealTalentFrame:Show()
        end
    end

    -- Zone layout constants (must be declared before GetTalentInfo)
    local SPEC_COL_START = 3
    local SPEC_COLS = 7
    local SIDE_ROWS = 5
    local SIDE_COLS = 3
    local HERO2_ROW_START = 5
    local TREE_POINT_CAP = 8

    -- Lazy-init: build ordered lists from tree config
    -- Called on first use OR when ReceiveTalents fires, in case load order
    -- meant SURREAL_TALENT_TREES wasn't ready at file-load time.
    local function InitTreeData()
        if not ST_classTrees then
            ST_classTrees = SURREAL_TALENT_TREES and SURREAL_TALENT_TREES[ST_classId]
        end
        if not ST_classTrees then return end
        if ST_orderedTalents[1] then return end  -- already built

        for tabIdx, tab in ipairs(ST_classTrees.tabs) do
            local ordered = {}
            for talentId, def in pairs(tab.talents) do
                ordered[#ordered + 1] = {id = talentId, def = def}
            end
            -- Sort: mastery first, then by row, col
            table.sort(ordered, function(a, b)
                local aDef = (type(a.def) == "table") and a.def or {}
                local bDef = (type(b.def) == "table") and b.def or {}
                local aMastery = aDef.mastery and true or false
                local bMastery = bDef.mastery and true or false
                if aMastery ~= bMastery then
                    return aMastery and not bMastery
                end

                local aRow = tonumber(aDef.row) or 0
                local bRow = tonumber(bDef.row) or 0
                if aRow ~= bRow then
                    return aRow < bRow
                end

                local aCol = tonumber(aDef.col) or 0
                local bCol = tonumber(bDef.col) or 0
                if aCol ~= bCol then
                    return aCol < bCol
                end

                return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
            end)
            ST_orderedTalents[tabIdx] = ordered
            ST_talentIndex[tabIdx] = {}
            for i, entry in ipairs(ordered) do
                ST_talentIndex[tabIdx][entry.id] = i
            end
        end
    end

    local function SyncStateFromBlizzard()
        InitTreeData()

        local talents = {}
        local spent = 0
        local tabs = {}

        if ST_classTrees then
            for tabIdx, tab in ipairs(ST_classTrees.tabs) do
                local tabPoints = 0
                for talentId, def in pairs(tab.talents) do
                    local rank = 0
                    if type(def.spells) == "table" and BlizzardIsSpellKnown then
                        for r, spellId in ipairs(def.spells) do
                            if spellId and BlizzardIsSpellKnown(spellId) then
                                rank = r
                            end
                        end
                    end
                    if rank > 0 then
                        talents[talentId] = rank
                        spent = spent + rank
                        tabPoints = tabPoints + rank
                    end
                end
                tabs[tabIdx] = { name = tab.name, points = tabPoints }
            end
        end

        local unspent = tonumber(BlizzardGetUnspentTalentPoints and BlizzardGetUnspentTalentPoints() or 0) or 0
        ST_playerTalents = talents
        ST_spent = spent
        ST_unspent = unspent
        ST_maxPoints = spent + unspent
        ST_tabPointInfo = tabs
        ST_dataReady = true
        if UpdateTalents then UpdateTalents() end
    end

    local RequestTalentsFromServer
    local SetServerWait

    local function ScheduleTalentRefresh(delaySeconds)
        local wait = tonumber(delaySeconds) or 0.6
        if wait < 0 then wait = 0 end

        local refresher = CreateFrame("Frame")
        refresher.elapsed = 0
        refresher:SetScript("OnUpdate", function(self, dt)
            self.elapsed = self.elapsed + dt
            if self.elapsed >= wait then
                RequestTalentsFromServer()
                SyncStateFromBlizzard()
                self:SetScript("OnUpdate", nil)
            end
        end)
    end

    -- Try immediate init (works if Config loaded before Frame)
    InitTreeData()

    -- ── Compatibility API ────────────────────────────────────────────────
    -- These shadow the global WoW functions within this scope.

    local function GetNumTalentTabs()
        InitTreeData()
        if ST_classTrees then return #ST_classTrees.tabs end
        return 0
    end

    local function GetNumTalents(tab)
        local ord = ST_orderedTalents[tab]
        return ord and #ord or 0
    end

    -- GetTalentInfo(tab, idx) → name, iconTex, tier, col, rank, maxRank,
    --   isExceptional, available, previewRank, previewAvail
    local function GetTalentInfo(tab, idx, ...)
        local ord = ST_orderedTalents[tab]
        if not ord or not ord[idx] then return nil end
        local entry = ord[idx]
        local def = entry.def
        local talentId = entry.id

        local rank = tonumber(ST_playerTalents[talentId]) or 0
        local maxRank = tonumber(def.maxRank) or 0

        -- Resolve name and icon from the spell (client has spell data)
        local spellId = def.spells[1]
        local name, _, iconTex
        if spellId then
            name, _, iconTex = GetSpellInfo(spellId)
        end
        name = name or ("Talent " .. talentId)
        iconTex = iconTex or "Interface\\Icons\\INV_Misc_QuestionMark"

        -- tier/col are display positions (0-based for compat)
        local tier = (def.row or 1) - 1
        local col  = (def.col or 1) - 1

        -- isExceptional = has the "flags=1" bit (passive/active toggle)
        local isExcept = (def.flags and def.flags > 0) or false

        -- "available" = prereqs met + has unspent points
        local rowOK = true
        local dRow = tonumber(def.row or 0) or 0
        local dCol = tonumber(def.col or 0) or 0
        local isSpecTalent = (dRow >= 1 and dCol > SPEC_COL_START and dCol <= (SPEC_COL_START + SPEC_COLS))

        local prereqOK = true
        if isSpecTalent and type(def.prereqs) == "table" then
            for _, p in ipairs(def.prereqs) do
                local prereqId = tonumber(p and p.id)
                local pRank = prereqId and (tonumber(ST_playerTalents[prereqId]) or 0) or 0
                local needed = tonumber(p and p.rank)
                if not needed or needed <= 0 then needed = 1 end
                if pRank < needed then prereqOK = false; break end
            end
        end

        local avail = rowOK and prereqOK and (ST_unspent - ST_previewSpent > 0)
            and rank < maxRank

        -- Preview rank
        local previewDelta = tonumber(ST_previewPoints[talentId]) or 0
        local previewRank = rank + previewDelta
        if previewRank < 0 then previewRank = 0 end
        if previewRank > maxRank then previewRank = maxRank end

        local previewAvail = avail  -- simplified

        return name, iconTex, tier, col, rank, maxRank,
               isExcept, avail, previewRank, previewAvail
    end

    -- GetTalentTabInfo(tab) → name, iconTex, pointsSpent
    local function GetTalentTabInfo(tab, ...)
        if not ST_classTrees or not ST_classTrees.tabs[tab] then
            return nil
        end
        local tabDef = ST_classTrees.tabs[tab]
        local name = tabDef.name or "Unknown"
        -- Icon: use the mastery talent's first spell icon
        local iconTex = "Interface\\Icons\\INV_Misc_QuestionMark"
        local masteryId = tabDef.masteryTalentId
        if masteryId and tabDef.talents[masteryId] then
            local sp = tabDef.talents[masteryId].spells[1]
            if sp then
                local _, _, ic = GetSpellInfo(sp)
                if ic then iconTex = ic end
            end
        end
        local pts = ST_tabPointInfo[tab] and ST_tabPointInfo[tab].points or 0
        return name, iconTex, pts
    end

    local function GetUnspentTalentPoints(...)
        local baseUnspent = tonumber(ST_unspent) or 0
        if baseUnspent <= 0 and BlizzardGetUnspentTalentPoints then
            local nativePoints = tonumber(BlizzardGetUnspentTalentPoints()) or 0
            if nativePoints > baseUnspent then
                baseUnspent = nativePoints
            end
        end
        return math.max(0, baseUnspent - ST_previewSpent)
    end

    local function GetActiveTalentGroup(...)
        return 1  -- We only have one talent group
    end

    local function TalentGroup()
        return 1
    end

    local chosenHeroTree = nil

    local function IsCappedZone(zone)
        return zone == "class" or zone == "hero1" or zone == "hero2"
    end

    local function IsIgnoredCorner(localRow, localCol)
        if localRow < 1 or localCol < 1 then return false end
        if localCol ~= 1 and localCol ~= SIDE_COLS then return false end
        return localRow == 1 or localRow == SIDE_ROWS
    end

    local TalentZone
    local GetZonePoints
    local PrereqOK
    local AutoQueueHeroEntryTalent

    -- Preview talent system (client-side only, before committing)
    local function AddPreviewTalentPoints(tab, idx, delta, ...)
        local ord = ST_orderedTalents[tab]
        if not ord or not ord[idx] then return false, "Invalid talent" end

        if delta > 0 then
            local unspent = GetUnspentTalentPoints(false, false, TalentGroup()) or 0
            if unspent <= 0 then
                return false, "No unspent talent points"
            end

            local zone = TalentZone(tab, idx)
            if not zone then
                return false, "Invalid talent slot"
            end
            if zone == "hero1" then
                if chosenHeroTree ~= 1 then
                    return false, "Choose Hero Tree 1 first"
                end
            elseif zone == "hero2" then
                if chosenHeroTree ~= 2 then
                    return false, "Choose Hero Tree 2 first"
                end
            end

            if IsCappedZone(zone) then
                if GetZonePoints(tab, zone, true) >= TREE_POINT_CAP then
                    return false, "Max points reached for this tree (8)"
                end
            end

            if zone == "spec" and not PrereqOK(tab, idx) then
                return false, "Prerequisites not met"
            end
        end

        local talentId = ord[idx].id
        local current = ST_previewPoints[talentId] or 0
        local before = current
        local newVal = current + delta
        if newVal < 0 then newVal = 0 end
        local def = ord[idx].def
        local rank = ST_playerTalents[talentId] or 0
        if rank + newVal > def.maxRank then
            newVal = def.maxRank - rank
        end
        if newVal <= 0 then
            ST_previewPoints[talentId] = nil
        else
            ST_previewPoints[talentId] = newVal
        end
        -- Recalculate total preview spent
        ST_previewSpent = 0
        for _, d in pairs(ST_previewPoints) do
            ST_previewSpent = ST_previewSpent + d
        end

        if newVal == before then
            if delta > 0 then
                return false, "Talent already at max rank"
            end
            return false, "No queued points to remove"
        end

        return true
    end

    local function GetGroupPreviewTalentPointsSpent(...)
        return ST_previewSpent
    end

    local function ResetGroupPreviewTalentPoints(...)
        ST_previewPoints = {}
        ST_previewSpent = 0
    end

    -- LearnTalent: sends native packet to server (single point)
    local function LearnTalent(tab, idx)
        if ST_waitingForServer then
            PushTalentFeedback("Waiting for server reply...")
            return
        end

        local ord = ST_orderedTalents[tab]
        if not ord or not ord[idx] then return end
        local talentId = ord[idx].id
        local currentRank = tonumber(ST_playerTalents[talentId]) or 0

        if talentId then
            DebugTalent("Learn request talent=" .. tostring(talentId) .. " rank=" .. tostring(currentRank))
            SetServerWait(true, "learn")
            AIO.Handle("SurrealTalents", "LearnTalent", talentId, currentRank, ST_editTarget)
            ScheduleTalentRefresh(0.6)
        end
    end

    -- LearnPreviewTalents: commit all preview points
    local function LearnPreviewTalents(...)
        if ST_waitingForServer then
            PushTalentFeedback("Waiting for server reply...")
            return
        end

        local payload = {}
        for talentId, delta in pairs(ST_previewPoints) do
            local idNum = tonumber(talentId)
            local dNum = tonumber(delta)
            if idNum and dNum and dNum > 0 then
                payload[idNum] = math.floor(dNum)
            end
        end

        if next(payload) then
            local queuedCount = 0
            for _ in pairs(payload) do queuedCount = queuedCount + 1 end
            DebugTalent("Apply clicked, queued talents=" .. tostring(queuedCount))
            SetServerWait(true, "apply")
            AIO.Handle("SurrealTalents", "ApplyPreviewTalents", payload, ST_editTarget)
            ScheduleTalentRefresh(0.6)
        end
        ST_previewPoints = {}
        ST_previewSpent = 0
    end

    -- GetTalentPrereqs: returns prereq info for rendering arrows
    local function GetTalentPrereqs(tab, idx)
        local ord = ST_orderedTalents[tab]
        if not ord or not ord[idx] then return nil end
        local def = ord[idx].def
        if type(def.prereqs) ~= "table" or #def.prereqs == 0 then return nil end
        local p = def.prereqs[1]
        if type(p) ~= "table" then return nil end
        local prereqId = tonumber(p.id)
        if not prereqId then return nil end
        -- Find prereq's display position
        local pDef
        if ST_classTrees then
            for _, t in ipairs(ST_classTrees.tabs) do
                if t.talents[prereqId] then
                    pDef = t.talents[prereqId]
                    break
                end
            end
        end
        if not pDef then return nil end
        local pTier = (tonumber(pDef.row) or 1) - 1
        local pCol  = (tonumber(pDef.col) or 1) - 1
        -- "met" = prereq rank achieved
        local pRank = tonumber(ST_playerTalents[prereqId]) or 0
        local needed = tonumber(p.rank)
        if not needed or needed <= 0 then needed = 1 end
        local met = pRank >= needed and 1 or 0
        return pTier, pCol, met
    end

    -- Request talents from server on frame open
    RequestTalentsFromServer = function()
        DebugTalent("RequestTalents target=" .. tostring(ST_editTarget))
        AIO.Handle("SurrealTalents", "RequestTalents", ST_editTarget)
    end

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
        SIDE_ROWS   = 5,

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
    --  C H O I C E   N O D E S
    --
    --  Format:
    --    CHOICE_NODES["CLASSTOKEN"][tabPage] = { {idxA, idxB}, ... }
    --
    --  Two talents sharing a grid cell — player picks one, the other
    --  becomes locked.  Both share the same DBC position.
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
    local MAX_BTNS    = 90        -- button pool size (>= max talents per tree)
    local previewMode = true      -- preview on by default
    local resetCostCache = nil    -- cached from server
    local chosenSpecTab = nil     -- spec chosen via overlay (nil = none)
    local forceSpecSelection = false
    local choiceSelected = {}     -- choiceSelected["tab-row-col"] = talentIdx

    -- Forward declarations
    local UpdateTalents
    local applyBtn, cancelBtn, resetBtn
    local classTreePanel, heroTreePanel, heroTreePanel2, glyphFrame, glyphSlots
    local heroChoiceOverlay, RefreshHeroOverlay
    local buildBar

    local function PushTalentFeedback(msg)
        if UIErrorsFrame and UIErrorsFrame.AddMessage then
            UIErrorsFrame:AddMessage(msg or "Action blocked", 1.0, 0.25, 0.25, 1.0)
        elseif DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff4444[Talents]|r " .. (msg or "Action blocked"))
        end
    end

    SetServerWait = function(waiting, reason)
        ST_waitingForServer = waiting and true or false
        ST_waitReason = ST_waitingForServer and (reason or "request") or nil

        if applyBtn then
            if ST_waitingForServer then
                applyBtn:Disable()
                applyBtn.text:SetText("|cffffff00Wait...|r")
            else
                applyBtn:Enable()
                applyBtn.text:SetText("|cff00cc00Apply|r")
            end
        end

        if resetBtn then
            if ST_waitingForServer then
                resetBtn:Disable()
            else
                resetBtn:Enable()
            end
        end
    end

    -- AIO handlers for server → client messages
    local ClientHandlers = AIO.AddHandlers("SurrealTalents", {})

    -- =================================================================
    --  H E L P E R S
    -- =================================================================
    local function ClassToken()
        return ST_classToken
    end

    -- TalentGroup already defined in shim above

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

    -- Returns 1-based row, col for display from SURREAL_TALENT_TREES.
    -- No DBC dependency.
    local function TalentPos(tab, idx)
        local ord = ST_orderedTalents[tab]
        if ord and ord[idx] then
            return ord[idx].def.row, ord[idx].def.col
        end
        return 1, 1
    end

    TalentZone = function(tab, idx)
        local row, col = TalentPos(tab, idx)
        if not row or not col then return nil end

        if row >= 1 and row <= SIDE_ROWS and col >= 1 and col <= SIDE_COLS then
            if IsIgnoredCorner(row, col) then
                return nil
            end
            return "class", row, col
        end

        if row >= 1 and col > SPEC_COL_START and col <= (SPEC_COL_START + SPEC_COLS) then
            return "spec", row, col - SPEC_COL_START
        end

        local heroColStart = SPEC_COL_START + SPEC_COLS
        if col > heroColStart and col <= (heroColStart + SIDE_COLS) then
            if row >= 1 and row <= SIDE_ROWS then
                local heroCol = col - heroColStart
                if IsIgnoredCorner(row, heroCol) then
                    return nil
                end
                return "hero1", row, heroCol
            end
            if row > HERO2_ROW_START and row <= (HERO2_ROW_START + SIDE_ROWS) then
                local hero2Row = row - HERO2_ROW_START
                local heroCol = col - heroColStart
                if IsIgnoredCorner(hero2Row, heroCol) then
                    return nil
                end
                return "hero2", hero2Row, heroCol
            end
        end

        return nil
    end

    GetZonePoints = function(tab, zoneName, includePreview)
        local ord = ST_orderedTalents[tab]
        if not ord then return 0 end
        local total = 0
        for idx, entry in ipairs(ord) do
            local zone = TalentZone(tab, idx)
            if zone == zoneName then
                local tid = entry.id
                local base = ST_playerTalents[tid] or 0
                local queued = includePreview and (ST_previewPoints[tid] or 0) or 0
                total = total + base + queued
            end
        end
        return total
    end

    PrereqOK = function(tab, idx)
        local pTier, pCol, met = GetTalentPrereqs(tab, idx)
        if not pTier then return true end
        return met and met ~= 0
    end

    local function GetMasteryTalentIndex(tab)
        local ord = ST_orderedTalents[tab]
        if not ord then return nil end
        for idx, entry in ipairs(ord) do
            if entry and type(entry.def) == "table" and entry.def.mastery then
                return idx
            end
        end
        return nil
    end

    -- Returns the tab where talent #1 (mastery) has rank > 0, or nil
    local function GetCommittedSpec()
        for tab = 1, GetNumTalentTabs() do
            local masteryIdx = GetMasteryTalentIndex(tab)
            if masteryIdx then
                local _, _, _, _, rank = GetTalentInfo(tab, masteryIdx)
                if rank and rank > 0 then return tab end
            end
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

    -- Shown only while editing a bot's build (see SetEditTarget)
    local editTargetBanner = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    editTargetBanner:SetPoint("TOP", titleText, "BOTTOM", 0, -2)
    editTargetBanner:Hide()

    function UpdateEditTargetBanner()
        if ST_editTarget then
            editTargetBanner:SetText("|cff55ff55Editing " .. ST_editTarget .. "'s build|r")
            editTargetBanner:Show()
        else
            editTargetBanner:Hide()
        end
    end

    local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)

    -- Separator line below title
    local sep = frame:CreateTexture(nil, "ARTWORK")
    sep:SetTexture(0.40, 0.40, 0.45)
    sep:SetAlpha(0.35)
    sep:SetPoint("TOPLEFT", 10, -36)
    sep:SetPoint("TOPRIGHT", -10, -36)
    sep:SetHeight(1)

    local unspentText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    unspentText:SetPoint("TOPLEFT", 16, -58)
    unspentText:SetJustifyH("LEFT")
    unspentText:SetText("Unspent: |cffffd1000|r")

    local distText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    distText:SetPoint("TOPRIGHT", -16, -58)
    distText:SetJustifyH("RIGHT")
    distText:SetText("")
    distText:Hide()

    local sep2 = frame:CreateTexture(nil, "ARTWORK")
    sep2:SetTexture(0.40, 0.40, 0.45)
    sep2:SetAlpha(0.25)
    sep2:SetPoint("TOPLEFT", 10, -76)
    sep2:SetPoint("TOPRIGHT", -10, -76)
    sep2:SetHeight(1)
    sep2:Hide()

    -- =================================================================
    --  S P E C   T A B S
    -- =================================================================
    local tabBtns = {}
    local MAX_SPEC_TABS = 5
    local TAB_GAP = 8
    local TAB_ROW_WIDTH = 900
    local TAB_W = math.floor((TAB_ROW_WIDTH - (TAB_GAP * (MAX_SPEC_TABS - 1))) / MAX_SPEC_TABS)
    local TAB_START_X = math.floor((980 - TAB_ROW_WIDTH) / 2)

    local function RefreshTabLabels()
        local numTabs = GetNumTalentTabs() or 0
        for i = 1, MAX_SPEC_TABS do
            local tb = tabBtns[i]
            if tb then
                if i <= numTabs then
                    local name, iconTex, pts = GetTalentTabInfo(i, false, false, TalentGroup())
                    tb.label:SetText(name or ("Spec " .. i))
                    tb.icon:SetTexture(iconTex)
                    tb:Show()
                else
                    tb:Hide()
                end
            end
        end
    end

    for i = 1, MAX_SPEC_TABS do
        local tb = CreateFrame("Button", nil, frame)
        tb:SetSize(TAB_W, 30)
        tb:SetPoint("TOPLEFT", TAB_START_X + (i - 1) * (TAB_W + TAB_GAP), -38)

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
    --  S I D E   P A N E L S  (Class Tree + Hero Tree 1 + Hero Tree 2)
    -- =================================================================
    local function MakeSidePanel(panelName, headerText, anchor, offX, offY)
        local cw = (CFG.SIDE_COLS - 1) * CFG.SIDE_SPC + CFG.SIDE_BTN
        local ch = (CFG.SIDE_ROWS - 1) * CFG.SIDE_SPC + CFG.SIDE_BTN
        local pw, ph = cw + 12, ch + 32

        local p = CreateFrame("Frame", panelName, frame)
        p:SetSize(pw, ph)
        p:SetPoint(anchor, offX, offY)

        local hdr = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        hdr:SetPoint("TOP", 0, -2)
        hdr:SetText("|cffaaaacc" .. headerText .. "|r")
        p.header = hdr

        p.slots = {}
        p.slotMap = {}
        for row = 1, CFG.SIDE_ROWS do
            for col = 1, CFG.SIDE_COLS do
                local s = CreateFrame("Button", nil, p)
                s:SetSize(CFG.SIDE_BTN, CFG.SIDE_BTN)
                s:SetPoint("TOPLEFT",
                    6 + (col - 1) * CFG.SIDE_SPC,
                    -18 - (row - 1) * CFG.SIDE_SPC)
                s:EnableMouse(true)
                s:RegisterForClicks("LeftButtonUp", "RightButtonUp")

                    local bg = s:CreateTexture(nil, "BACKGROUND")
                    bg:SetAllPoints()

                bg:SetTexture(0.14, 0.14, 0.17)

                local ic = s:CreateTexture(nil, "ARTWORK")
                ic:SetPoint("TOPLEFT", 2, -2)
                ic:SetPoint("BOTTOMRIGHT", -2, 2)
                ic:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                ic:SetDesaturated(true)
                ic:SetAlpha(0.25)
                s.icon = ic
                s.bg = bg
                s.gridRow = row
                s.gridCol = col
                s.tTab = nil
                s.tIdx = nil
                s:SetScript("OnClick", function(self, button)
                    if not self.tTab or not self.tIdx then return end
                    if previewMode then
                        local delta = (button == "RightButton") and -1 or 1
                        local ok, err = AddPreviewTalentPoints(self.tTab, self.tIdx, delta, false, TalentGroup())
                        if not ok then
                            PushTalentFeedback(err)
                        end
                        UpdateTalents()
                    else
                        if button == "LeftButton" then
                            LearnTalent(self.tTab, self.tIdx)
                        end
                    end
                end)
                s:SetScript("OnEnter", function(self)
                    if ShowTalentTooltip then
                        ShowTalentTooltip(self, "ANCHOR_RIGHT")
                    end
                end)
                s:SetScript("OnLeave", function()
                    GameTooltip:Hide()
                end)

                p.slots[#p.slots + 1] = s
                p.slotMap[row .. ":" .. col] = s
            end
        end

        p:Hide()
        return p
    end

    -- Class tree goes LEFT, hero trees go RIGHT (chosen via overlay)
    classTreePanel = MakeSidePanel("SurrealClassTree", "Class Tree",
        "LEFT", 16, 0)
    heroTreePanel  = MakeSidePanel("SurrealHeroTree1",  "Hero Tree 1",
        "RIGHT", -16, 0)
    heroTreePanel2 = MakeSidePanel("SurrealHeroTree2",  "Hero Tree 2",
        "RIGHT", -16, 0)

    -- =================================================================
    --  H E R O  T R E E  C H O I C E  O V E R L A Y
    -- =================================================================
    chosenHeroTree = nil  -- nil = not chosen, 1 = tree 1, 2 = tree 2

    heroChoiceOverlay = CreateFrame("Frame", "SurrealHeroChoice", frame)
    heroChoiceOverlay:SetPoint("RIGHT", -6, 0)
    local heroPanelW = (CFG.SIDE_COLS - 1) * CFG.SIDE_SPC + CFG.SIDE_BTN + 24
    heroChoiceOverlay:SetSize(heroPanelW, 320)
    heroChoiceOverlay:SetFrameLevel(frame:GetFrameLevel() + 12)
    heroChoiceOverlay:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    heroChoiceOverlay:SetBackdropColor(0.08, 0.08, 0.12, 0.95)
    heroChoiceOverlay:SetBackdropBorderColor(0.40, 0.40, 0.45, 1)
    heroChoiceOverlay:Hide()

    local heroChoiceTitle = heroChoiceOverlay:CreateFontString(nil, "OVERLAY",
        "GameFontNormal")
    heroChoiceTitle:SetPoint("TOP", 0, -12)
    heroChoiceTitle:SetText("|cffffd100Choose Hero Tree|r")

    local heroChoiceSub = heroChoiceOverlay:CreateFontString(nil, "OVERLAY",
        "GameFontNormalSmall")
    heroChoiceSub:SetPoint("TOP", heroChoiceTitle, "BOTTOM", 0, -4)
    heroChoiceSub:SetText("|cff888888Select one to unlock|r")

    local heroChoiceBtns = {}
    for hi = 1, 2 do
        local hb = CreateFrame("Button", nil, heroChoiceOverlay)
        hb:SetSize(heroPanelW - 20, 110)
        hb:SetPoint("TOP", heroChoiceOverlay, "TOP", 0, -48 - (hi - 1) * 120)
        hb:SetBackdrop({
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        hb:SetBackdropColor(0.12, 0.12, 0.16, 0.95)
        hb:SetBackdropBorderColor(0.35, 0.35, 0.40, 1)

        -- Entry talent icon
        local hIcon = hb:CreateTexture(nil, "ARTWORK")
        hIcon:SetSize(40, 40)
        hIcon:SetPoint("LEFT", 12, 0)
        hIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        hb.entryIcon = hIcon

        -- Tree name
        local hName = hb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        hName:SetPoint("TOPLEFT", hIcon, "TOPRIGHT", 10, -2)
        hName:SetText("|cffaaaacc Hero Tree " .. hi .. "|r")
        hb.treeName = hName

        -- Description
        local hDesc = hb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hDesc:SetPoint("TOPLEFT", hName, "BOTTOMLEFT", 0, -4)
        hDesc:SetWidth(heroPanelW - 80)
        hDesc:SetText("|cff666666Entry talent preview|r")
        hb.treeDesc = hDesc

        -- Select label
        local hSelect = hb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        hSelect:SetPoint("BOTTOM", 0, 6)
        hSelect:SetText("|cff888888Click to select|r")
        hb.selectLabel = hSelect

        hb:SetScript("OnEnter", function(self)
            self:SetBackdropColor(0.18, 0.18, 0.25, 0.95)
            self:SetBackdropBorderColor(1, 0.82, 0, 1)
            self.selectLabel:SetText("|cffffd100Click to select|r")
        end)
        hb:SetScript("OnLeave", function(self)
            self:SetBackdropColor(0.12, 0.12, 0.16, 0.95)
            self:SetBackdropBorderColor(0.35, 0.35, 0.40, 1)
            self.selectLabel:SetText("|cff888888Click to select|r")
        end)

        local heroIdx = hi
        hb:SetScript("OnClick", function()
            chosenHeroTree = heroIdx
            AutoQueueHeroEntryTalent(heroIdx)
            heroChoiceOverlay:Hide()
            UpdateTalents()
        end)

        heroChoiceBtns[hi] = hb
    end

    local function GetHeroEntryTalentInfo(tab, heroIdx)
        local ord = ST_orderedTalents[tab]
        if not ord then return nil end
        local targetZone = (heroIdx == 1) and "hero1" or "hero2"

        local candidateIdx = nil
        for idx = 1, #ord do
            local zone, row, col = TalentZone(tab, idx)
            if zone == targetZone and row == 1 and col == 2 then
                candidateIdx = idx
                break
            end
        end
        if not candidateIdx then
            for idx = 1, #ord do
                local zone, row = TalentZone(tab, idx)
                if zone == targetZone and row == 1 then
                    candidateIdx = idx
                    break
                end
            end
        end
        if not candidateIdx then return nil end

        local def = ord[candidateIdx].def or {}
        local spellId = type(def.spells) == "table" and def.spells[1] or nil
        local name, icon = nil, nil
        if spellId then
            name, _, icon = GetSpellInfo(spellId)
        end
        local desc = spellId and ((GetSpellDescription and GetSpellDescription(spellId))
            or select(2, GetSpellInfo(spellId))) or nil

        return {
            spellId = spellId,
            name = name,
            icon = icon,
            desc = desc,
        }
    end

    local function SyncChosenHeroTree(tab)
        if not tab then return end
        local hero1Committed = GetZonePoints(tab, "hero1", false)
        local hero2Committed = GetZonePoints(tab, "hero2", false)
        if hero1Committed > 0 and hero2Committed <= 0 then
            chosenHeroTree = 1
        elseif hero2Committed > 0 and hero1Committed <= 0 then
            chosenHeroTree = 2
        elseif hero1Committed > 0 and hero2Committed > 0 then
            if chosenHeroTree ~= 1 and chosenHeroTree ~= 2 then
                chosenHeroTree = 1
            end
        end
    end

    RefreshHeroOverlay = function(tab)
        local active = tab or activeTab or GetCommittedSpec() or chosenSpecTab
        for hi = 1, 2 do
            local hb = heroChoiceBtns[hi]
            local entry = active and GetHeroEntryTalentInfo(active, hi) or nil
            hb.treeName:SetText("|cffaaaacc Hero Tree " .. hi .. "|r")
            if entry and entry.name then
                hb.treeDesc:SetText("|cff88ccffLearns:|r " .. entry.name)
                hb.entryIcon:SetTexture(entry.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
                hb.entryIcon:SetDesaturated(false)
                hb.entryIcon:SetAlpha(1)
                hb.entryIcon.spellId = entry.spellId
            else
                hb.treeDesc:SetText("|cff666666No entry talent configured|r")
                hb.entryIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                hb.entryIcon:SetDesaturated(true)
                hb.entryIcon:SetAlpha(0.35)
            end
        end
    end

    local function ResolveTooltipSpell(def, rank)
        if type(def) ~= "table" or type(def.spells) ~= "table" then
            return nil
        end

        local wantedRank = math.max(tonumber(rank) or 0, 1)
        local spellId = def.spells[wantedRank]
        if spellId then
            return spellId
        end

        local bestSpell = nil
        for r, sid in ipairs(def.spells) do
            if sid and r <= wantedRank then
                bestSpell = sid
            end
        end

        return bestSpell or def.spells[1]
    end

    function ShowTalentTooltip(button, anchor)
        if not button or not button.tTab or not button.tIdx then
            return
        end

        local tab = button.tTab
        local idx = button.tIdx
        local tName, _, _, _, tRank, tMax, _, _, previewRank = GetTalentInfo(tab, idx)
        local ord = ST_orderedTalents[tab]
        local def = ord and ord[idx] and ord[idx].def

        local baseRank = tonumber(tRank) or 0
        local displayRank = baseRank
        if previewMode and previewRank and tonumber(previewRank) and tonumber(previewRank) > displayRank then
            displayRank = tonumber(previewRank)
        end

        local currentSpell = ResolveTooltipSpell(def, displayRank)
        local nextSpell = nil
        if (tonumber(tMax) or 0) > displayRank then
            nextSpell = ResolveTooltipSpell(def, displayRank + 1)
        end

        GameTooltip:SetOwner(button, anchor or "ANCHOR_RIGHT")
        GameTooltip:ClearLines()

        local hasSpellHeader = false
        if currentSpell and GameTooltip.SetHyperlink then
            pcall(GameTooltip.SetHyperlink, GameTooltip, "spell:" .. tostring(currentSpell))
            hasSpellHeader = GameTooltipTextLeft1 and GameTooltipTextLeft1:GetText() and GameTooltipTextLeft1:GetText() ~= ""
        end
        if (not hasSpellHeader) and currentSpell and GameTooltip.SetSpellByID then
            pcall(GameTooltip.SetSpellByID, GameTooltip, currentSpell)
            hasSpellHeader = GameTooltipTextLeft1 and GameTooltipTextLeft1:GetText() and GameTooltipTextLeft1:GetText() ~= ""
        end

        if not hasSpellHeader then
            GameTooltip:ClearLines()
            GameTooltip:AddLine(tName or ("Talent " .. tostring(idx)), 1, 1, 1)
            if currentSpell then
                local curDesc = (GetSpellDescription and GetSpellDescription(currentSpell)) or select(2, GetSpellInfo(currentSpell))
                if curDesc and curDesc ~= "" then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine(curDesc, 1, 1, 1, true)
                end
            end
        end

        GameTooltip:AddLine(" ")
        if previewMode and displayRank ~= baseRank then
            GameTooltip:AddLine(string.format("Preview Rank %d/%d (current %d/%d)", displayRank, tMax or 0, baseRank, tMax or 0), 0.2, 1, 0.2)
        else
            GameTooltip:AddLine(string.format("Rank %d/%d", displayRank, tMax or 0), 1, 0.82, 0)
        end

        if nextSpell then
            local nextDesc = (GetSpellDescription and GetSpellDescription(nextSpell)) or select(2, GetSpellInfo(nextSpell))
            if nextDesc and nextDesc ~= "" then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("|cff00ff00Next rank:|r", 0, 1, 0)
                GameTooltip:AddLine(nextDesc, 1, 1, 1, true)
            end
        end

        local partner = ChoicePartner(tab, idx)
        if partner then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("|cffaaaacc\226\151\134 Choice Node|r")
            GameTooltip:AddLine("|cff888888Click to choose this talent|r")
        end

        GameTooltip:Show()
    end

    local function RefreshSidePanel(panel, tab, zoneName, titleText)
        if not panel then return end

        panel.header:SetText(titleText or "")

        for _, slot in ipairs(panel.slots or {}) do
            local isCorner = IsIgnoredCorner(slot.gridRow or 0, slot.gridCol or 0)
            if isCorner then
                slot:Hide()
            else
                slot:Show()
            end
            slot.tTab = nil
            slot.tIdx = nil
            if slot.icon then
                slot.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                slot.icon:SetDesaturated(true)
                slot.icon:SetAlpha(0.25)
            end
            if not slot.rankText then
                local rt = slot:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                rt:SetPoint("BOTTOMRIGHT", -1, 1)
                rt:SetFont(rt:GetFont(), 9, "OUTLINE")
                slot.rankText = rt
            end
            slot.rankText:SetText("")
        end

        local tg = TalentGroup()
        local num = GetNumTalents(tab) or 0
        for idx = 1, num do
            local zone, row, col = TalentZone(tab, idx)
            if zone == zoneName then
                local key = tostring(row) .. ":" .. tostring(col)
                local slot = panel.slotMap and panel.slotMap[key]
                if slot and slot.icon then
                    local name, iconTex, _, _, rank, maxRank, _, avail, previewRank =
                        GetTalentInfo(tab, idx, false, false, tg)
                    if name and iconTex then
                        local displayRank = rank or 0
                        if previewMode and previewRank and previewRank > displayRank then
                            displayRank = previewRank
                        end
                        slot.tTab = tab
                        slot.tIdx = idx
                        slot.icon:SetTexture(iconTex)
                        slot.icon:SetDesaturated(false)
                        slot.icon:SetAlpha((displayRank > 0 or avail) and 1 or 0.75)
                        slot.rankText:SetText(displayRank .. "/" .. (maxRank or 0))
                    end
                end
            end
        end
    end

    AutoQueueHeroEntryTalent = function(heroIdx)
        local tab = activeTab
        if not tab or tab <= 0 then return end
        local targetZone = (heroIdx == 1) and "hero1" or "hero2"
        local ord = ST_orderedTalents[tab]
        if not ord then return end

        local entryIdx = nil
        for idx = 1, #ord do
            local zone, row, col = TalentZone(tab, idx)
            if zone == targetZone and row == 1 and col == 2 then
                entryIdx = idx
                break
            end
        end
        if not entryIdx then
            for idx = 1, #ord do
                local zone, row = TalentZone(tab, idx)
                if zone == targetZone and row == 1 then
                    entryIdx = idx
                    break
                end
            end
        end
        if not entryIdx then return end

        local _, _, _, _, rank, _, _, _, previewRank = GetTalentInfo(tab, entryIdx, false, false, TalentGroup())
        local current = rank or 0
        if previewMode and previewRank and previewRank > current then
            current = previewRank
        end

        if current <= 0 then
            local ok, err = AddPreviewTalentPoints(tab, entryIdx, 1, false, TalentGroup())
            if not ok then
                PushTalentFeedback(err)
            end
        end
    end

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
            if ST_editTarget then
                PushTalentFeedback("Glyphs can only be managed on your own character.")
                return
            end
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
    for si = 1, MAX_SPEC_TABS do
        local sb = CreateFrame("Button", nil, specOverlay)
        sb:SetSize(180, 240)
        local xOffset = (si - ((MAX_SPEC_TABS + 1) / 2)) * 190
        local yOffset = -170
        sb:SetPoint("TOP", specOverlay, "TOP", xOffset, yOffset)
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
        mName:SetWidth(160)
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
                -- Manual tooltip from shim data (SetTalent uses native data)
                local tName, tIcon, _, _, tRank, tMax = GetTalentInfo(self.tabIdx, 1)
                if tName then
                    GameTooltip:AddLine(tName, 1, 1, 1)
                    -- Show spell description from current/first rank
                    local ord = ST_orderedTalents[self.tabIdx]
                    if ord and ord[1] then
                        local def = ord[1].def
                        local spellIdx = math.max(tRank, 1)
                        local sp = def.spells[spellIdx]
                        if sp then
                            local desc = GetSpellDescription and GetSpellDescription(sp)
                                or select(2, GetSpellInfo(sp))
                            if desc and desc ~= "" then
                                GameTooltip:AddLine(desc, 1, 0.82, 0, true)
                            end
                        end
                    end
                end
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
            forceSpecSelection = false
            chosenSpecTab = specIdx
            chosenHeroTree = nil
            local masteryIdx = GetMasteryTalentIndex(specIdx)
            if masteryIdx then
                AddPreviewTalentPoints(specIdx, masteryIdx, 1, false, TalentGroup())
            end
            activeTab = specIdx
            UpdateTalents()
        end)

        specBtns[si] = sb
    end

    local function RefreshSpecOverlay()
        InitTreeData()
        local tg = TalentGroup()
        local numTabs = GetNumTalentTabs() or 0
        for si = 1, MAX_SPEC_TABS do
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

    -- Talent grid canvas (parent for talent buttons)
    local grid = CreateFrame("Frame", nil, frame)
    grid:SetPoint("TOP", frame, "TOP", 0, -90)
    grid:SetSize(500, 510)
    grid:Show()

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
                        local ok, err = AddPreviewTalentPoints(self.tTab, self.tIdx, 1,
                            false, TalentGroup())
                        if not ok then
                            PushTalentFeedback(err)
                        end
                        UpdateTalents()
                    else
                        LearnTalent(self.tTab, self.tIdx)
                    end
                    return
                end

                -- Choice node right-click: remove preview point
                if partner and button == "RightButton" then
                    if previewMode then
                        local ok, err = AddPreviewTalentPoints(self.tTab, self.tIdx, -1,
                            false, TalentGroup())
                        if not ok then
                            PushTalentFeedback(err)
                        end
                        UpdateTalents()
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
                    PushTalentFeedback("Choice already locked by the other talent")
                    return
                end
                if previewMode then
                    if button == "RightButton" then
                        local ok, err = AddPreviewTalentPoints(self.tTab, self.tIdx, -1,
                            false, TalentGroup())
                        if not ok then
                            PushTalentFeedback(err)
                        end
                    else
                        local ok, err = AddPreviewTalentPoints(self.tTab, self.tIdx, 1,
                            false, TalentGroup())
                        if not ok then
                            PushTalentFeedback(err)
                        end
                    end
                    UpdateTalents()
                else
                    if button == "LeftButton" then
                        LearnTalent(self.tTab, self.tIdx)
                    end
                end
            end
        end)

        -- Tooltip
        btn:SetScript("OnEnter", function(self)
            ShowTalentTooltip(self, "ANCHOR_RIGHT")
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
        InitTreeData()
        local tab = activeTab
        local tg  = TalentGroup()

        -- Spec state check
        local committed = GetCommittedSpec()
        local specActive = forceSpecSelection and nil or (committed or chosenSpecTab)

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
            heroTreePanel2:Hide()
            heroChoiceOverlay:Hide()
            chosenHeroTree = nil
            glyphFrame:Hide()
            if buildBar then buildBar:Hide() end
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

        local specTab = committed or chosenSpecTab
        SyncChosenHeroTree(specTab)

        -- Spec active — hide overlay, show normal UI
        specOverlay:Hide()
        grid:Show()
        resetBtn:Show()
        unspentText:Show()
        distText:Hide()
        sep:Hide()
        sep2:Hide()
        classTreePanel:Show()
        if chosenHeroTree then
            heroChoiceOverlay:Hide()
            if chosenHeroTree == 1 then
                heroTreePanel:Show()
                heroTreePanel2:Hide()
            else
                heroTreePanel:Hide()
                heroTreePanel2:Show()
            end
        else
            heroChoiceOverlay:Show()
            RefreshHeroOverlay(specTab)
            heroTreePanel:Hide()
            heroTreePanel2:Hide()
        end
        glyphFrame:Show()
        if buildBar then buildBar:Show() end
        RefreshGlyphs()

        activeTab = specTab  -- lock to chosen spec tree
        local tab = activeTab
        local specName = GetTalentTabInfo(specTab, false, false, tg)
        local classPts = GetZonePoints(tab, "class", true)
        local hero1Pts = GetZonePoints(tab, "hero1", true)
        local hero2Pts = GetZonePoints(tab, "hero2", true)
        titleText:SetText("|cffffd100" ..
            (specName or "Unknown") .. "|r")

        RefreshSidePanel(classTreePanel, tab, "class", "|cffaaaaccClass Tree " .. classPts .. "/" .. TREE_POINT_CAP .. "|r")
        RefreshSidePanel(heroTreePanel, tab, "hero1", "|cffaaaaccHero Tree 1 " .. hero1Pts .. "/" .. TREE_POINT_CAP .. "|r")
        RefreshSidePanel(heroTreePanel2, tab, "hero2", "|cffaaaaccHero Tree 2 " .. hero2Pts .. "/" .. TREE_POINT_CAP .. "|r")

        -- Tabs — hide all (player is locked to one spec)
        for i, tb in ipairs(tabBtns) do
            tb:Hide()
        end

        -- Unspent
        local baseUnspent = tonumber(ST_unspent) or 0
        local previewSpent = 0
        if previewMode then
            previewSpent = GetGroupPreviewTalentPointsSpent(false, tg) or 0
        end
        local effectiveUnspent = baseUnspent - previewSpent
        if previewMode and previewSpent > 0 then
            unspentText:SetText("Unspent: |cffffd100" .. effectiveUnspent .. "|r")
        else
            unspentText:SetText("Unspent: |cffffd100" .. baseUnspent .. "|r")
        end

        -- Hide the whole pool
        for i = 1, MAX_BTNS do buttons[i]:Hide() end

        -- Populate active tab (skip talent #1 = mastery)
        local num = GetNumTalents(tab) or 0

        -- Auto-size grid to fit all display positions (uses coord table)
        local maxR, maxC = 0, 0
        for i = 2, math.min(num, MAX_BTNS) do
            local r, c = TalentPos(tab, i)
            local isSpecCell = r and c and (c > SPEC_COL_START and c <= (SPEC_COL_START + SPEC_COLS))
            if isSpecCell then
                local specCol = c - SPEC_COL_START
                maxR = math.max(maxR, r)
                maxC = math.max(maxC, specCol)
            end
        end

        -- Dynamically scale spacing if grid would be too wide for the frame
        local sidePanelWidth = 164  -- approximate width of each side panel + margin
        local availWidth = CFG.FRAME_W - 40  -- 20px margin each side
        local neededW = maxC * CFG.SPACING_X + CFG.BTN_SIZE
        local spacingX = CFG.SPACING_X
        local showSidePanels = true

        if neededW > availWidth then
            -- Keep side panels visible and compress spec grid spacing as needed.
            spacingX = math.max(36, math.floor((availWidth - CFG.BTN_SIZE) / math.max(maxC, 1)))
        end

        -- Show/hide side panels based on grid width
        if showSidePanels then
            classTreePanel:Show()
            if chosenHeroTree == 1 then heroTreePanel:Show()
            elseif chosenHeroTree == 2 then heroTreePanel2:Show()
            else
                heroTreePanel:Hide()
                heroTreePanel2:Hide()
            end
        else
            classTreePanel:Hide()
            heroTreePanel:Hide()
            heroTreePanel2:Hide()
        end

        local gridW = math.max(500, maxC * spacingX + CFG.BTN_SIZE)
        local gridH = math.max(510, maxR * CFG.SPACING_Y + CFG.BTN_SIZE)
        grid:SetSize(gridW, gridH)

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
                local isSpecCell = r and c and (c > SPEC_COL_START and c <= (SPEC_COL_START + SPEC_COLS))
                if not isSpecCell then
                    btn:Hide()
                else
                    local specCol = c - SPEC_COL_START
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
                    local cellX = (specCol - 1) * spacingX
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
                        (specCol - 1) * spacingX,
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
                end -- close isSpecCell guard
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
        if ST_waitingForServer then
            PushTalentFeedback("Waiting for server reply...")
            return
        end
        -- Ask server for reset cost
        SetServerWait(true, "reset-cost")
        AIO.Handle("SurrealTalents", "GetResetCost", ST_editTarget)
    end)

    -- Confirmation dialog (static popup style)
    StaticPopupDialogs["SURREAL_TALENT_RESET"] = {
        text = "Reset all talents?\n\nCost: %s",
        button1 = "Reset",
        button2 = "Cancel",
        OnAccept = function()
            SetServerWait(true, "reset")
            AIO.Handle("SurrealTalents", "ConfirmReset", ST_editTarget)
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
        SetServerWait(false)
        resetCostCache = cost
        StaticPopup_Show("SURREAL_TALENT_RESET", GoldStr(cost))
    end

    -- Server → Client: reset completed  
    function ClientHandlers.ResetDone(player, newCost, talents, spent, maxPts, unspent, tabInfo)
        DebugTalent("ResetDone received")
        SetServerWait(false)
        resetCostCache = newCost
        if talents then
            ST_playerTalents = talents
            ST_spent = spent or 0
            ST_maxPoints = maxPts or 0
            ST_unspent = unspent or 0
            ST_tabPointInfo = tabInfo or {}
            ST_dataReady = true
        else
            ST_playerTalents = {}
            ST_spent = 0
            ST_unspent = tonumber(BlizzardGetUnspentTalentPoints and BlizzardGetUnspentTalentPoints() or 0) or 0
            ST_maxPoints = ST_unspent
            ST_tabPointInfo = {}
            ST_dataReady = true
        end
        ST_previewPoints = {}
        ST_previewSpent = 0
        forceSpecSelection = true
        chosenSpecTab = nil  -- talents reset, back to spec choice
        chosenHeroTree = nil
        UpdateTalents()
        RequestTalentsFromServer()
        ScheduleTalentRefresh(0.6)
    end

    -- Server → Client: receive full talent state
    function ClientHandlers.ReceiveTalents(player, talents, spent, maxPts, unspent, tabInfo, targetName, classId)
        -- Ignore stale replies from a target we've since switched away from
        if targetName ~= ST_editTarget then return end

        DebugTalent("ReceiveTalents spent=" .. tostring(spent or 0) .. " unspent=" .. tostring(unspent or 0))
        SetServerWait(false)

        local newClassId = classId or CLASS_TOKEN_TO_ID[ST_classToken]
        if newClassId ~= 0 and newClassId ~= ST_classId then
            ST_classId = newClassId
            ST_classTrees = SURREAL_TALENT_TREES and SURREAL_TALENT_TREES[ST_classId]
            ST_orderedTalents = {}
            ST_talentIndex = {}
        end
        InitTreeData()  -- ensure tree data is built
        ST_playerTalents = talents or {}
        ST_spent = spent or 0
        ST_maxPoints = maxPts or 0
        ST_unspent = unspent or 0
        ST_tabPointInfo = tabInfo or {}
        ST_previewPoints = {}
        ST_previewSpent = 0
        ST_dataReady = true
        if UpdateTalents then UpdateTalents() end
    end

    function ClientHandlers.Debug(player, msg)
        DebugTalent("Server: " .. tostring(msg))
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

        if ST_waitingForServer then
            applyBtn:Show()
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
    --  B U I L D   B A R  (import / export / saved builds)
    -- =================================================================

    -- Persistent saved builds (per character, stored in WTF folder)
    SurrealUI_TalentBuilds = SurrealUI_TalentBuilds or {}
    if AIO.AddSavedVarChar then
        AIO.AddSavedVarChar("SurrealUI_TalentBuilds")
    end

    -- Client-side talent string encoder (Wowhead format)
    -- Starts at idx=2 to skip the mastery talent (idx 1), matching the
    -- server's import which also skips mastery.
    local function EncodeTalentString()
        local tg = TalentGroup()
        local trees = {}
        for tab = 1, (GetNumTalentTabs() or 0) do
            local digits = {}
            for idx = 2, (GetNumTalents(tab) or 0) do
                local name, _, _, _, rank =
                    GetTalentInfo(tab, idx, false, false, tg)
                if name then
                    digits[#digits + 1] = tostring(rank or 0)
                end
            end
            local str = table.concat(digits)
            str = str:gsub("0+$", "")
            if str == "" then str = "0" end
            trees[#trees + 1] = str
        end
        return table.concat(trees, "-")
    end

    local RefreshBuildDropdown  -- forward declare

    -- Build bar container (occupies the spec-tab row when spec is active)
    buildBar = CreateFrame("Frame", nil, frame)
    buildBar:SetSize(940, 28)
    buildBar:SetPoint("BOTTOM", glyphFrame, "TOP", 0, 2)
    buildBar:Hide()

    -- Builds dropdown trigger
    local buildsBtn = MakeButton("SurrealBuildsBtn", 90, buildBar,
        "LEFT", 0, 0)
    buildsBtn.text:SetText("Builds")

    -- Talent string edit box (paste / export target)
    local buildEditBox = CreateFrame("EditBox", "SurrealBuildEditBox",
        buildBar)
    buildEditBox:SetSize(520, 22)
    buildEditBox:SetPoint("LEFT", buildsBtn, "RIGHT", 6, 0)
    buildEditBox:SetFontObject(ChatFontNormal)
    buildEditBox:SetAutoFocus(false)
    buildEditBox:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    buildEditBox:SetBackdropColor(0.08, 0.08, 0.12, 0.9)
    buildEditBox:SetBackdropBorderColor(0.35, 0.35, 0.40, 1)
    buildEditBox:SetTextInsets(6, 6, 0, 0)
    buildEditBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    buildEditBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)

    -- Export button
    local bExport = MakeButton("SurrealBuildExport", 58, buildBar,
        "LEFT", 0, 0)
    bExport:ClearAllPoints()
    bExport:SetPoint("LEFT", buildEditBox, "RIGHT", 4, 0)
    bExport.text:SetText("|cffffd100Export|r")
    bExport:SetScript("OnClick", function()
        local str = EncodeTalentString()
        buildEditBox:SetText(str)
        buildEditBox:HighlightText()
        buildEditBox:SetFocus()
        DEFAULT_CHAT_FRAME:AddMessage(
            "|cff00ff00[SurrealUI]|r Build exported — Ctrl+C to copy.")
    end)

    -- Import button
    local bImport = MakeButton("SurrealBuildImport", 58, buildBar,
        "LEFT", 0, 0)
    bImport:ClearAllPoints()
    bImport:SetPoint("LEFT", bExport, "RIGHT", 4, 0)
    bImport.text:SetText("|cff00cc00Import|r")
    bImport:SetScript("OnClick", function()
        local str = buildEditBox:GetText()
        if not str or str == "" then
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cffff0000[SurrealUI]|r Paste a talent string first.")
            return
        end
        buildEditBox:ClearFocus()
        StaticPopupDialogs["SURREAL_BUILD_IMPORT"] = {
            text = "Import and apply this build?\n\n|cffffd100"
                .. str .. "|r\n\nThis will reset your talents.",
            button1 = "Apply",
            button2 = "Cancel",
            OnAccept = function()
                AIO.Handle("SurrealTalents", "ImportTalents", str)
            end,
            timeout = 0,
            whileDead = false,
            hideOnEscape = true,
            preferredIndex = 3,
        }
        StaticPopup_Show("SURREAL_BUILD_IMPORT")
    end)

    -- Save button
    local bSave = MakeButton("SurrealBuildSave", 50, buildBar,
        "LEFT", 0, 0)
    bSave:ClearAllPoints()
    bSave:SetPoint("LEFT", bImport, "RIGHT", 4, 0)
    bSave.text:SetText("|cff88ccffSave|r")
    bSave:SetScript("OnClick", function()
        local str = buildEditBox:GetText()
        if not str or str == "" then
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cffff0000[SurrealUI]|r Export or paste a build first.")
            return
        end
        StaticPopupDialogs["SURREAL_BUILD_SAVE"] = {
            text = "Name this build:",
            button1 = "Save",
            button2 = "Cancel",
            hasEditBox = true,
            OnAccept = function(self)
                local name = self.editBox:GetText()
                if name and name ~= "" then
                    SurrealUI_TalentBuilds[name] = {
                        string = str,
                        class = select(2, UnitClass("player")),
                        time = time(),
                    }
                    DEFAULT_CHAT_FRAME:AddMessage(
                        "|cff00ff00[SurrealUI]|r Build '"
                        .. name .. "' saved!")
                    if RefreshBuildDropdown then
                        RefreshBuildDropdown()
                    end
                end
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
        StaticPopup_Show("SURREAL_BUILD_SAVE")
    end)

    -- ── Builds Dropdown Popup ───────────────────────────────────────
    local buildsPopup = CreateFrame("Frame", "SurrealBuildsPopup", frame)
    buildsPopup:SetSize(260, 240)
    buildsPopup:SetPoint("TOPLEFT", buildsBtn, "BOTTOMLEFT", 0, -2)
    buildsPopup:SetFrameStrata("DIALOG")
    buildsPopup:SetFrameLevel(frame:GetFrameLevel() + 20)
    buildsPopup:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    buildsPopup:SetBackdropColor(0.08, 0.08, 0.10, 0.95)
    buildsPopup:SetBackdropBorderColor(0.40, 0.40, 0.45, 1)
    buildsPopup:Hide()

    -- Close popup when build bar hides
    buildBar:SetScript("OnHide", function()
        buildsPopup:Hide()
    end)

    local popupTitle = buildsPopup:CreateFontString(nil, "OVERLAY",
        "GameFontNormal")
    popupTitle:SetPoint("TOP", 0, -8)
    popupTitle:SetText("|cffffd100Saved Builds|r")

    local buildScroll = CreateFrame("ScrollFrame",
        "SurrealBuildsScroll", buildsPopup,
        "UIPanelScrollFrameTemplate")
    buildScroll:SetPoint("TOPLEFT", 8, -26)
    buildScroll:SetPoint("BOTTOMRIGHT", -28, 8)
    local buildContent = CreateFrame("Frame", nil, buildScroll)
    buildContent:SetSize(210, 1)
    buildScroll:SetScrollChild(buildContent)

    local MAX_BUILD_BTNS = 20
    local buildListBtns = {}
    for bi = 1, MAX_BUILD_BTNS do
        local bb = CreateFrame("Button", nil, buildContent)
        bb:SetSize(205, 22)
        bb:SetPoint("TOPLEFT", 0, -((bi - 1) * 24))

        local bbBg = bb:CreateTexture(nil, "BACKGROUND")
        bbBg:SetAllPoints()
        bbBg:SetTexture(0.15, 0.15, 0.18, 0.6)

        local bbText = bb:CreateFontString(nil, "OVERLAY",
            "GameFontNormalSmall")
        bbText:SetPoint("LEFT", 6, 0)
        bbText:SetPoint("RIGHT", -26, 0)
        bbText:SetJustifyH("LEFT")
        bb.label = bbText

        -- Delete (X) button
        local del = CreateFrame("Button", nil, bb)
        del:SetSize(16, 16)
        del:SetPoint("RIGHT", -2, 0)
        local delT = del:CreateFontString(nil, "OVERLAY",
            "GameFontNormalSmall")
        delT:SetPoint("CENTER")
        delT:SetText("|cffff4444X|r")
        del:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Delete build", 1, 0.3, 0.3)
            GameTooltip:Show()
        end)
        del:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
        del:SetScript("OnClick", function()
            if bb.buildName and SurrealUI_TalentBuilds then
                SurrealUI_TalentBuilds[bb.buildName] = nil
                DEFAULT_CHAT_FRAME:AddMessage(
                    "|cff00ff00[SurrealUI]|r Deleted '"
                    .. bb.buildName .. "'.")
                if RefreshBuildDropdown then
                    RefreshBuildDropdown()
                end
            end
        end)
        bb.delBtn = del

        local hl = bb:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
        hl:SetBlendMode("ADD")
        hl:SetAlpha(0.3)

        bb:Hide()
        bb.buildName   = nil
        bb.buildString = nil

        bb:SetScript("OnClick", function(self)
            if self.buildString then
                buildEditBox:SetText(self.buildString)
                buildsPopup:Hide()
                DEFAULT_CHAT_FRAME:AddMessage(
                    "|cff00ff00[SurrealUI]|r Loaded: "
                    .. (self.buildName or "?"))
            end
        end)
        bb:SetScript("OnEnter", function(self)
            if self.buildString then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(self.buildName or "",
                    1, 0.82, 0)
                GameTooltip:AddLine(self.buildString,
                    0.7, 0.7, 0.7)
                GameTooltip:Show()
            end
        end)
        bb:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        buildListBtns[bi] = bb
    end

    -- Populate the saved-build list
    RefreshBuildDropdown = function()
        for bi = 1, MAX_BUILD_BTNS do
            buildListBtns[bi]:Hide()
        end
        local idx = 0
        local cls = select(2, UnitClass("player"))
        for name, data in pairs(SurrealUI_TalentBuilds or {}) do
            if not data.class or data.class == cls then
                idx = idx + 1
                if idx <= MAX_BUILD_BTNS then
                    local bb = buildListBtns[idx]
                    bb.buildName   = name
                    bb.buildString = data.string or ""
                    bb.label:SetText("|cffffd100" .. name .. "|r")
                    bb.delBtn:Show()
                    bb:Show()
                end
            end
        end
        buildContent:SetHeight(math.max(1, idx * 24))
        if idx == 0 then
            local bb = buildListBtns[1]
            bb.buildName   = nil
            bb.buildString = nil
            bb.label:SetText("|cff888888No saved builds|r")
            bb.delBtn:Hide()
            bb:Show()
            buildContent:SetHeight(24)
        end
    end

    buildsBtn:SetScript("OnClick", function()
        if buildsPopup:IsShown() then
            buildsPopup:Hide()
        else
            RefreshBuildDropdown()
            buildsPopup:Show()
        end
    end)

    -- Server -> Client: talent import completed
    function ClientHandlers.ImportResult(player, success, errMsg)
        if success then
            chosenSpecTab = nil
            local refresher = CreateFrame("Frame")
            refresher.elapsed = 0
            refresher:SetScript("OnUpdate", function(self, dt)
                self.elapsed = self.elapsed + dt
                if self.elapsed > 0.5 then
                    UpdateTalents()
                    buildEditBox:SetText(EncodeTalentString())
                    self:SetScript("OnUpdate", nil)
                end
            end)
        else
            DEFAULT_CHAT_FRAME:AddMessage(
                "|cffff0000[SurrealUI]|r "
                .. (errMsg or "Import failed."))
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
        -- Request latest talent state from server
        RequestTalentsFromServer()
        -- Clear stale preview state when opening
        if previewMode then
            ResetGroupPreviewTalentPoints()
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
            -- Normal keybind/menu open always means "my own talents",
            -- even if the frame was last showing a bot's build.
            SetEditTarget(nil, nil)
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

        if event == "PLAYER_ENTERING_WORLD" then
            RequestTalentsFromServer()
            ScheduleTalentRefresh(0.8)
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
                            local posStr = "tier=" .. tier .. " col=" .. col ..
                            "  (row " .. (tier + 1) .. ", col " .. (col + 1) .. ")"
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

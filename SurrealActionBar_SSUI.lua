-------------------------------------------------------------------------------
-- SurrealActionBar_SSUI.lua
--
-- Replaces the default WotLK action bar with a single fixed 12-slot bar
-- driven by a GM-authored, per-class/per-spec loadout (configured via the
-- SDBEditor "Action Bar Builder" web tool). The Blizzard action bar is
-- permanently hidden -- this bar is authoritative, same precedent as the
-- custom talent system (SurrealTalentFrame_SSUI.lua) already replacing the
-- default talent UI entirely.
--
-- Design notes:
--   * Blizzard's real ActionButton1-12 frames are reused (repositioned +
--     reskinned), NOT recreated. This means Blizzard's own combat-safe
--     click handling, keybindings, cooldown swipes, usable/range tinting
--     and macro/hotkey text all keep working with zero extra code, and
--     nothing we do ever touches a protected attribute during combat.
--   * The action bar is locked to page 1 always (RegisterStateDriver), so
--     stance/vehicle/possess paging never swaps in a different 12 slots --
--     every class has exactly 12 abilities on this server, no paging.
--   * Icon swap (proc rules) is COSMETIC ONLY: it changes the displayed
--     texture, never the underlying action/spell bound to the slot.
--   * Baseline loadout (GM config) auto-applies once per class+spec. Once
--     a player manually customizes a slot, that layout is saved server-side
--     and always takes precedence after that. /actionbarreset reverts to
--     the GM baseline.
--
-- Slash commands:
--   /actionbarreset  — wipe your local customization and re-apply the
--                       server (GM) baseline loadout for your current spec.
--   /hudunlock        — show draggable "(drag me)" strips above the action
--                       bar, menu/bag cluster, and stance bar so you can
--                       reposition any/all of them (ElvUI-style anchors).
--   /hudlock          — hide the drag strips and save the current
--                       positions of all HUD pieces locally (account-wide
--                       SavedVariable, shared by every character on this
--                       WoW account -- no server storage involved).
--   /actionbarprocdebug — print every proc rule for your current spec plus
--                       every active player buff / target debuff, to help
--                       diagnose a proc rule that isn't triggering.
-------------------------------------------------------------------------------

local SSUI = SSUI or require("SSUI")

if SSUI.AddAddon() then
    ---------------------------------------------------------------------------
    -- SERVER SIDE
    ---------------------------------------------------------------------------
    if not SURREAL_ACTIONBAR_CONFIG then
        pcall(dofile, "lua_scripts/SurrealActionBarConfig_SSUI.lua")
    end

    local SLOT_COUNT = 12

    local function ClampSlots(slots)
        local out = {}
        for i = 1, SLOT_COUNT do
            local v = tonumber(slots and slots[i]) or 0
            if v < 0 then v = 0 end
            out[i] = v
        end
        return out
    end

    local function GetBaselineSlots(classId, specIndex)
        local classCfg = SURREAL_ACTIONBAR_CONFIG and SURREAL_ACTIONBAR_CONFIG[classId]
        local specCfg = classCfg and classCfg.specs and classCfg.specs[specIndex]
        return ClampSlots(specCfg and specCfg.slots)
    end

    local function LoadSavedSlots(guid, classId, specIndex)
        local q = CharDBQuery(string.format(
            "SELECT slot_1, slot_2, slot_3, slot_4, slot_5, slot_6, " ..
            "slot_7, slot_8, slot_9, slot_10, slot_11, slot_12 " ..
            "FROM surreal_talents.actionbar_loadout " ..
            "WHERE guid = %d AND class_id = %d AND spec_index = %d",
            guid, classId, specIndex))
        if not q then return nil end
        local slots = {}
        for i = 1, SLOT_COUNT do
            slots[i] = q:GetUInt32(i - 1)
        end
        return slots
    end

    local function SaveSlots(guid, classId, specIndex, slots)
        local c = ClampSlots(slots)
        CharDBExecute(string.format(
            "REPLACE INTO surreal_talents.actionbar_loadout " ..
            "(guid, class_id, spec_index, slot_1, slot_2, slot_3, slot_4, " ..
            "slot_5, slot_6, slot_7, slot_8, slot_9, slot_10, slot_11, slot_12) " ..
            "VALUES (%d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d)",
            guid, classId, specIndex,
            c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11], c[12]))
    end

    local function DeleteSlots(guid, classId, specIndex)
        CharDBExecute(string.format(
            "DELETE FROM surreal_talents.actionbar_loadout " ..
            "WHERE guid = %d AND class_id = %d AND spec_index = %d",
            guid, classId, specIndex))
    end

    -- Movable UI anchor positions ("actionbar", "menubar", "stancebar", ...)
    -- are NOT stored server-side -- a DB round trip is overkill for a purely
    -- cosmetic screen position. The client saves/restores these itself via
    -- an account-wide (not per-character) SavedVariable, see CLIENT SIDE
    -- below, so every character on the same WoW account shares one layout
    -- with zero server involvement.

    local Handlers = SSUI.AddHandlers("SurrealActionBar", {})

    function Handlers.RequestLoadout(player, classId, specIndex)
        if not player then return end
        classId = tonumber(classId)
        specIndex = tonumber(specIndex)
        if not classId or not specIndex then return end
        if classId ~= player:GetClass() then return end

        local guid = player:GetGUIDLow()
        local saved = LoadSavedSlots(guid, classId, specIndex)
        if saved then
            SSUI.Handle(player, "SurrealActionBar", "ReceiveLoadout", classId, specIndex, saved, true)
        else
            SSUI.Handle(player, "SurrealActionBar", "ReceiveLoadout", classId, specIndex,
                       GetBaselineSlots(classId, specIndex), false)
        end
    end

    function Handlers.SaveLoadout(player, classId, specIndex, slots)
        if not player then return end
        classId = tonumber(classId)
        specIndex = tonumber(specIndex)
        if not classId or not specIndex then return end
        if classId ~= player:GetClass() then return end
        if type(slots) ~= "table" then return end

        SaveSlots(player:GetGUIDLow(), classId, specIndex, slots)
    end

    function Handlers.ResetLoadout(player, classId, specIndex)
        if not player then return end
        classId = tonumber(classId)
        specIndex = tonumber(specIndex)
        if not classId or not specIndex then return end
        if classId ~= player:GetClass() then return end

        DeleteSlots(player:GetGUIDLow(), classId, specIndex)
        SSUI.Handle(player, "SurrealActionBar", "ReceiveLoadout", classId, specIndex,
                   GetBaselineSlots(classId, specIndex), false)
    end

else
    ---------------------------------------------------------------------------
    -- CLIENT SIDE
    ---------------------------------------------------------------------------
    if not SURREAL_ACTIONBAR_CONFIG then
        pcall(dofile, "lua_scripts/SurrealActionBarConfig_SSUI.lua")
    end

    local SLOT_COUNT = 12
    local BUTTON_GAP = 7

    -- =================================================================
    --  G E N E R I C   M O V A B L E   A N C H O R   S Y S T E M
    --  (ElvUI-style: every repositionable HUD piece -- action bar, menu/
    --   bag cluster, stance bar -- shares this same drag/lock/persist code)
    --
    --  Positions are saved LOCALLY on the player's own computer via an
    --  account-wide SavedVariable (SurrealActionBar_Anchors, declared in
    --  SSUI_Client.toc's plain "## SavedVariables:" line, NOT PerCharacter)
    --  -- no server DB round trip needed for a cosmetic screen position,
    --  and since it's account-wide every character on this WoW account
    --  shares the same saved layout automatically.
    -- =================================================================
    SurrealActionBar_Anchors = SurrealActionBar_Anchors or {}

    local anchors = {} -- [name] = { frame, handle, locked }

    -- Saved/restored as an offset from screen CENTER (not from whatever
    -- anchor point the frame happened to default to) so this works
    -- uniformly regardless of each frame's own default anchor scheme
    -- (e.g. the stance bar defaults relative to the action bar, the menu/
    -- bag cluster defaults relative to BOTTOMRIGHT) -- translating
    -- everything through a common CENTER-relative frame avoids ever
    -- reapplying a saved offset against the wrong reference point.
    local function SaveAnchorPosition(name, frame)
        local cx, cy = frame:GetCenter()
        local ux, uy = UIParent:GetCenter()
        if not cx or not ux then return end
        SurrealActionBar_Anchors[name] = { x = cx - ux, y = cy - uy }
    end

    local function ApplySavedAnchor(name, frame)
        local pos = SurrealActionBar_Anchors[name]
        if not pos or not pos.x or not pos.y then return end
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", UIParent, "CENTER", pos.x, pos.y)
    end

    -- Registers `frame` as a draggable, position-persisted HUD element.
    -- Adds a small labeled grip strip above the frame that's only
    -- mouse-enabled while unlocked -- dragging the frame's own body never
    -- fights with clicking the real buttons it contains.
    local function CreateMovableAnchor(name, frame, label)
        frame:SetMovable(true)
        frame:SetClampedToScreen(true)

        local handle = CreateFrame("Frame", nil, UIParent)
        handle:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, 2)
        handle:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 0, 2)
        handle:SetHeight(16)
        handle:EnableMouse(false)
        handle:SetFrameStrata("HIGH")
        handle:RegisterForDrag("LeftButton")
        handle:Hide()

        local bg = handle:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(handle)
        bg:SetTexture(0.15, 0.55, 1, 0.85)

        local text = handle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("CENTER", handle, "CENTER", 0, 0)
        text:SetText(label .. " (drag me)")

        handle:SetScript("OnDragStart", function() frame:StartMoving() end)
        handle:SetScript("OnDragStop", function()
            frame:StopMovingOrSizing()
            SaveAnchorPosition(name, frame)
        end)

        anchors[name] = { frame = frame, handle = handle, locked = true }

        -- Restore this account's saved position (if any) over whatever
        -- default SetPoint the caller just set up above.
        ApplySavedAnchor(name, frame)
    end

    local function SetAnchorLocked(name, locked)
        local a = anchors[name]
        if not a then return end
        a.locked = locked
        a.handle:EnableMouse(not locked)
        if locked then a.handle:Hide() else a.handle:Show() end
    end

    local function SetAllAnchorsLocked(locked)
        for name in pairs(anchors) do SetAnchorLocked(name, locked) end
    end

    -- =================================================================
    --  B A R   F R A M E   +   R E U S E   B L I Z Z A R D   B U T T O N S
    -- =================================================================
    local bar = CreateFrame("Frame", "SurrealActionBar", UIParent)
    -- Centered horizontally, raised well up off the very bottom edge so
    -- the character's feet stay visible underneath the bar (previously
    -- y=4, essentially flush with the screen edge).
    bar:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 110)
    bar:SetFrameStrata("MEDIUM")

    local buttons = {}
    local barWidth = 0
    for i = 1, SLOT_COUNT do
        local btn = _G["ActionButton" .. i]
        if btn then
            btn:SetParent(bar)
            btn:ClearAllPoints()
            if i == 1 then
                btn:SetPoint("LEFT", bar, "LEFT", 0, 0)
            else
                btn:SetPoint("LEFT", buttons[i - 1], "RIGHT", BUTTON_GAP, 0)
            end
            btn:Show()
            buttons[i] = btn
            barWidth = barWidth + btn:GetWidth() + (i > 1 and BUTTON_GAP or 0)
        end
    end
    bar:SetSize(math.max(barWidth, 1), 40)
    CreateMovableAnchor("actionbar", bar, "Action Bar")

    -- Lock the action bar to page 1 permanently. Every class/spec here has
    -- exactly 12 fixed abilities -- there is no bonus/stance/vehicle page to
    -- swap to. RegisterStateDriver is an unprotected API safe to call any
    -- time (including combat); calling it again simply replaces whichever
    -- default driver Blizzard registered on these frames.
    if MainMenuBarArtFrame then
        RegisterStateDriver(MainMenuBarArtFrame, "page", "1")
    end
    if MainMenuBar then
        RegisterStateDriver(MainMenuBar, "page", "1")
    end

    -- =================================================================
    --  M E N U   +   B A G   B A R   ( M I C R O   B U T T O N S )
    -- =================================================================
    -- Character/Spellbook/Talent/Achievement/etc. micro buttons (hooked by
    -- SurrealCharacter_SSUI.lua, SurrealSpellBook_SSUI.lua, etc. to open our
    -- custom panels) and the bag bar are literal XML children of
    -- MainMenuBarArtFrame -- Hide()ing a parent frame cascades to hide all
    -- of its children regardless of their own Show() state, AND their
    -- original anchors reference MainMenuBarArtFrame/each other so they
    -- don't move as a group on their own. Reparent them to our own frame
    -- (never hidden) AND re-chain their anchors relative to it, in two
    -- rows (micro buttons, then bags), so the whole cluster is one
    -- draggable unit.
    local menuBar = CreateFrame("Frame", "SurrealMenuBar", UIParent)
    menuBar:SetFrameStrata("MEDIUM")
    -- Anchored relative to the action bar itself (not a screen corner) so
    -- it always sits directly to the bar's right at the same height,
    -- rather than floating alone down in the bottom-right corner.
    menuBar:SetPoint("BOTTOMLEFT", bar, "BOTTOMRIGHT", 20, 0)

    local MICRO_BUTTON_NAMES = {
        "CharacterMicroButton", "SpellbookMicroButton", "TalentMicroButton",
        "AchievementMicroButton", "QuestLogMicroButton", "SocialMicroButton",
        "PVPMicroButton", "LFDMicroButton", "MainMenuMicroButton", "HelpMicroButton",
    }
    local BAG_BUTTON_NAMES = {
        "MainMenuBarBackpackButton", "CharacterBag0Slot", "CharacterBag1Slot",
        "CharacterBag2Slot", "CharacterBag3Slot", "KeyRingButton",
    }

    local function ChainRow(names, parent, yOffset, gap)
        local prev, rowWidth, rowHeight = nil, 0, 0
        for _, fname in ipairs(names) do
            local f = _G[fname]
            if f then
                f:SetParent(parent)
                f:ClearAllPoints()
                if not prev then
                    f:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
                else
                    f:SetPoint("LEFT", prev, "RIGHT", gap, 0)
                end
                f:Show()
                rowWidth = rowWidth + f:GetWidth() + (prev and gap or 0)
                rowHeight = math.max(rowHeight, f:GetHeight())
                prev = f
            end
        end
        return rowWidth, rowHeight
    end

    local microWidth, microHeight = ChainRow(MICRO_BUTTON_NAMES, menuBar, 0, 2)
    local bagWidth, bagHeight = ChainRow(BAG_BUTTON_NAMES, menuBar, -(microHeight + 4), 4)
    menuBar:SetSize(math.max(microWidth, bagWidth, 1), microHeight + 4 + bagHeight)
    CreateMovableAnchor("menubar", menuBar, "Menu / Bags")

    -- =================================================================
    --  S T A N C E   /   S H A P E S H I F T   B A R
    -- =================================================================
    -- Previously hidden entirely (a mistake -- warriors/druids/rogues/
    -- paladins etc. need stances/forms/stealth/auras). Keep Blizzard's own
    -- ShapeshiftBarFrame + its buttons fully functional, just reposition it
    -- (default: just above the action bar) and make it draggable like
    -- everything else. Blizzard's own logic still shows/hides the actual
    -- buttons on it based on class/form availability -- untouched.
    local stanceBar = ShapeshiftBarFrame or StanceBarFrame
    if stanceBar then
        stanceBar:SetParent(UIParent)
        stanceBar:ClearAllPoints()
        stanceBar:SetPoint("BOTTOM", bar, "TOP", 0, 10)
        stanceBar:SetFrameStrata("MEDIUM")
        CreateMovableAnchor("stancebar", stanceBar, "Stance Bar")
    end

    -- =================================================================
    --  H I D E   R E D U N D A N T   B L I Z Z A R D   C H R O M E
    -- =================================================================
    local function HideForever(f)
        if not f then return end
        f:UnregisterAllEvents()
        f:Hide()
        f:HookScript("OnShow", function(self) self:Hide() end)
    end

    HideForever(MainMenuBarArtFrame)
    HideForever(MainMenuBarArtFrameBackground)
    HideForever(MultiBarBottomLeft)
    HideForever(MultiBarBottomRight)
    HideForever(MultiBarLeft)
    HideForever(MultiBarRight)
    HideForever(MultiBarBottomLeftButton)
    HideForever(MultiBarBottomRightButton)


    -- =================================================================
    --  P E R - B U T T O N   C O S M E T I C   O V E R L A Y S
    --  (icon swap texture when a proc rule is active)
    -- =================================================================
    local overlays = {}
    for i = 1, SLOT_COUNT do
        local btn = buttons[i]
        if btn then
            local iconTex = _G[btn:GetName() .. "Icon"]
            local cooldownFrame = _G[btn:GetName() .. "Cooldown"]

            -- The swap texture is created directly ON the button itself
            -- (a texture layer, not a child frame) -- child frames ALWAYS
            -- render above their parent's own texture draw layers
            -- regardless of texture sub-level, so this guarantees the
            -- swap texture stays BELOW the button's built-in Cooldown
            -- swipe (a separate CooldownFrameTemplate child frame), same
            -- as the real icon normally is. This is deliberate: the
            -- cooldown swipe is driven entirely by Blizzard based on the
            -- REAL spell/action actually placed in this slot (the one
            -- really cast) -- we only ever change what icon is drawn
            -- underneath, never how/when the cooldown swipes, so it must
            -- keep rendering on top of whatever icon is currently shown,
            -- exactly like any ordinary action button.
            local swap = btn:CreateTexture(nil, "ARTWORK")
            if iconTex then
                swap:SetAllPoints(iconTex)
            else
                swap:SetAllPoints(btn)
            end
            swap:Hide()

            -- Frame refs kept around (not just the texture itself) purely
            -- so /actionbarprocdebug can print concrete rendering state
            -- (shown/texture/alpha/frame level/strata) instead of just the
            -- logical procActive flag, in case detection is fine but the
            -- visual result still isn't -- ground truth beats more guessing.
            overlays[i] = { swap = swap, procActive = false, cooldownFrame = cooldownFrame, btn = btn }
        end
    end

    -- =================================================================
    --  P R O C   R U L E S   ( C O S M E T I C   I C O N   S W A P )
    -- =================================================================
    -- Rules target an ABILITY (targetSpellId), not a fixed slot number --
    -- the player can freely rearrange their bar (see ACTIONBAR_SLOT_CHANGED
    -- below), so every refresh re-resolves each rule's targetSpellId to
    -- whichever slot currently holds it (if any) via a fresh spell->slot
    -- map built from the live bar. This means a proc rule keeps working
    -- correctly no matter where the player has actually placed that
    -- ability, instead of silently glowing whatever unrelated spell
    -- happens to sit in the slot it was originally authored against.
    --
    -- watchToRules[watchBuffSpellId] = { rule, rule, ... } -- lets
    -- RefreshProcs pair each ACTIVE buff directly with the rule(s) that
    -- watch it (a buff can drive more than one target ability at once).
    local watchToRules = {}

    local function RebuildProcIndex(classId, specIndex)
        watchToRules = {}
        local classCfg = SURREAL_ACTIONBAR_CONFIG and SURREAL_ACTIONBAR_CONFIG[classId]
        local specCfg = classCfg and classCfg.specs and classCfg.specs[specIndex]
        local rules = specCfg and specCfg.procRules
        if not rules then return end
        for _, rule in ipairs(rules) do
            local watchId = tonumber(rule.watchBuffSpellId)
            local targetSpellId = tonumber(rule.targetSpellId)
            if rule.enabled and watchId and watchId > 0 and targetSpellId and targetSpellId > 0 then
                watchToRules[watchId] = watchToRules[watchId] or {}
                table.insert(watchToRules[watchId], rule)
            end
        end
    end

    -- spellId -> slot currently showing that spell, built fresh each
    -- refresh from the live action bar (same source CurrentSlots() reads).
    local function BuildSpellSlotMap()
        local map = {}
        for i = 1, SLOT_COUNT do
            local actionType, id = GetActionInfo(i)
            if actionType == "spell" and id then
                map[id] = i
            end
        end
        return map
    end

    -- Purely cosmetic icon swap -- the cooldown swipe is
    -- NEVER driven from here. It's always Blizzard's own built-in
    -- cooldownFrame, based on whatever real spell the player actually has
    -- placed/cast in this slot -- we only ever change what icon texture
    -- is drawn underneath it (see the swap texture's creation above,
    -- deliberately kept below cooldownFrame in draw order), never how or
    -- when it swipes.
    local function ClearProcVisual(slot)
        local ov = overlays[slot]
        if not ov or not ov.procActive then return end
        ov.procActive = false
        ov.swap:Hide()
    end

    local function ApplyProcVisual(slot, rule, buffIcon)
        local ov = overlays[slot]
        if not ov then return end
        local tex = buffIcon
        -- swapIconName is a plain icon FILE NAME (e.g. "Ability_Rogue_Ambush",
        -- no extension/path), picked directly from the icon manifest in the
        -- GM tool -- purely cosmetic, no spell lookup involved at all.
        local iconName = rule.swapIconName
        if iconName and iconName ~= "" then
            tex = "Interface\\Icons\\" .. iconName
        end
        if tex then
            ov.swap:SetTexture(tex)
            ov.swap:Show()
        end
        ov.procActive = true
    end

    -- Scans both player buffs (including PASSIVE-flagged auras, which the
    -- default "HELPFUL"-only filter silently excludes -- internal
    -- mechanic/stance-marker auras are frequently flagged passive so they
    -- don't clutter the normal buff bar) AND debuffs the watched rule's
    -- buff exists on your current target (for rules built around a
    -- target-applied debuff proc, e.g. a melee "expose" effect -- those
    -- are combat-only by nature since they require a target). Every call
    -- re-resolves each rule's target ability to its CURRENT slot (if any
    -- is currently placed at all), so a rule never sticks to a stale slot
    -- after the player rearranges their bar.
    local function RefreshProcs()
        if not next(watchToRules) then
            for slot = 1, SLOT_COUNT do ClearProcVisual(slot) end
            return
        end

        local spellSlotMap = BuildSpellSlotMap()

        -- [slot] = { rule = <the rule whose watched buff is active AND
        -- whose target ability currently sits in this slot>, icon = <that
        -- buff's actual icon> }
        local activeForSlot = {}

        local function RecordMatches(spellId, icon)
            local rules = spellId and watchToRules[spellId]
            if not rules then return end
            for _, rule in ipairs(rules) do
                local slot = spellSlotMap[rule.targetSpellId]
                if slot then
                    activeForSlot[slot] = { rule = rule, icon = icon }
                end
            end
        end

        for i = 1, 40 do
            local name, _, icon, _, _, _, _, _, _, _, spellId = UnitBuff("player", i, "HELPFUL|PASSIVE")
            if not name then break end
            RecordMatches(spellId, icon)
        end

        if UnitExists("target") then
            for i = 1, 40 do
                local name, _, icon, _, _, _, _, _, _, _, spellId = UnitDebuff("target", i, "PLAYER")
                if not name then break end
                RecordMatches(spellId, icon)
            end
        end

        for slot = 1, SLOT_COUNT do
            local active = activeForSlot[slot]
            if active then
                ApplyProcVisual(slot, active.rule, active.icon)
            else
                ClearProcVisual(slot)
            end
        end
    end

    -- =================================================================
    --  L O A D O U T   A P P L Y   /   M A N U A L   E D I T   T R A C K I N G
    -- =================================================================
    local lastClassId, lastSpecIndex
    local ignoreSlotEvents = false
    local pendingSpecCheck = nil
    -- True only once Handlers.ReceiveLoadout has actually delivered the
    -- real, server/DB-authoritative loadout for the CURRENT session. A
    -- ReloadUI (whether from a single or a back-to-back "double" reload
    -- triggered by an ALE script reload) re-runs this whole file from
    -- scratch, resetting all of these upvalues to nil/false again -- so
    -- any auto-save path (ACTIONBAR_SLOT_CHANGED, newly-learned-talent
    -- auto-fill, etc.) must wait for this flag before it's ever safe to
    -- push CurrentSlots() to the server. Without this gate, a stray
    -- ACTIONBAR_SLOT_CHANGED firing while the real RequestLoadout round
    -- trip is still in flight (or while Blizzard's own UI is still
    -- settling from the reload) can save transient/placeholder bar
    -- content and clobber the player's real saved loadout in the DB.
    local hasReceivedAuthoritativeLoadout = false

    local function CurrentSlots()
        local slots = {}
        for i = 1, SLOT_COUNT do
            local actionType, id = GetActionInfo(i)
            if actionType == "spell" and id then
                slots[i] = id
            else
                slots[i] = 0
            end
        end
        return slots
    end

    -- Populates action slots 1-12 from a GM/saved loadout. Never called
    -- during combat -- PlaceAction is a protected action-bar-content change
    -- and will simply be skipped if combat starts before this runs.
    local function ApplySlots(slots)
        if InCombatLockdown() then return false end
        ignoreSlotEvents = true
        for i = 1, SLOT_COUNT do
            local spellId = tonumber(slots[i]) or 0
            if spellId > 0 then
                PickupSpell(spellId)
                PlaceAction(i)
                ClearCursor()
            elseif HasAction(i) then
                PickupAction(i)
                ClearCursor()
            end
        end
        ignoreSlotEvents = false
        return true
    end

    -- =================================================================
    --  C L I E N T - S I D E   C A C H E   ( L E S S   L A G   O N   R E L O A D )
    -- =================================================================
    -- The real loadout only ever arrives after a full round trip: talent
    -- data loads async -> CheckSpec() detects class/spec -> a server
    -- request/response fetches that spec's saved slots -> ApplySlots.
    -- On every /reload or relogin the bar sits empty/stale until all of
    -- that finishes. SurrealActionBar_Cache is a real SavedVariablesPerCharacter
    -- table (declared on the SSUI_Client addon itself, see SSUI_Client.toc --
    -- NOT this pushed script, since pushed script globals don't survive a
    -- reload) that remembers the last-applied class/spec/slots so we can
    -- paint them immediately as a provisional guess, THEN let the normal
    -- CheckSpec -> RequestLoadout -> ReceiveLoadout flow run as always and
    -- overwrite/correct it with the real, authoritative data once that
    -- arrives. A stale/wrong cache can never stick -- it's always just a
    -- placeholder until the real response lands.
    SurrealActionBar_Cache = SurrealActionBar_Cache or {}

    local function ApplyCachedLoadout()
        local cache = SurrealActionBar_Cache
        if not cache or not cache.classId or not cache.specIndex or not cache.slots then return end
        lastClassId, lastSpecIndex = cache.classId, cache.specIndex
        RebuildProcIndex(cache.classId, cache.specIndex)
        ApplySlots(cache.slots)
        RefreshProcs()
    end

    local function SaveCachedLoadout(classId, specIndex, slots)
        SurrealActionBar_Cache = { classId = classId, specIndex = specIndex, slots = slots }
    end

    local Handlers = SSUI.AddHandlers("SurrealActionBar", {})

    function Handlers.ReceiveLoadout(player, classId, specIndex, slots, customized)
        lastClassId, lastSpecIndex = classId, specIndex
        RebuildProcIndex(classId, specIndex)
        ApplySlots(slots or {})
        RefreshProcs()
        SaveCachedLoadout(classId, specIndex, slots or {})
        hasReceivedAuthoritativeLoadout = true
    end

    local function RequestLoadoutFor(classId, specIndex)
        if not classId or not specIndex then return end
        SSUI.Handle("SurrealActionBar", "RequestLoadout", classId, specIndex)
    end

    local function CheckSpec()
        if type(_G.SurrealTalent_GetCommittedSpec) ~= "function" then return end
        local classId, specIndex = _G.SurrealTalent_GetCommittedSpec()
        if not classId or not specIndex then return end
        if classId == lastClassId and specIndex == lastSpecIndex then return end

        if InCombatLockdown() then
            pendingSpecCheck = true
            return
        end
        RequestLoadoutFor(classId, specIndex)
    end

    -- SurrealTalentFrame_SSUI.lua's real per-tab talent data arrives
    -- asynchronously (server round-trip on login, or a delayed refresh
    -- timer after learning a talent) -- often well after our own
    -- PLAYER_ENTERING_WORLD-triggered CheckSpec() already ran and found
    -- nothing. It calls this global once that data actually lands so we
    -- can re-check immediately instead of staying stuck at "spec nil"
    -- until some unrelated event happens to fire again.
    _G.SurrealActionBar_OnTalentDataReady = CheckSpec

    -- =================================================================
    --  A U T O - P L A C E   N E W L Y   L E A R N E D   T A L E N T   S P E L L S
    -- =================================================================
    -- Spending a talent point mid-session (without changing spec) doesn't
    -- go through CheckSpec/RequestLoadout at all (that path only fires on
    -- an actual class/spec change), so a spell you just learned would
    -- otherwise never make it onto the bar until your next full loadout
    -- reload. Whenever talent/character-point events fire, look at the
    -- CURRENT spec's baseline slot layout (already available client-side
    -- via SURREAL_ACTIONBAR_CONFIG -- no server round-trip needed) and
    -- drop any newly-known spell into ITS designated slot, but ONLY if
    -- that slot is currently empty. This never clobbers a slot the player
    -- (or a previously saved loadout -- "where they last had it when they
    -- played that spec") has already put something into; it only fills
    -- gaps for abilities that are brand new to the bar.
    local function ApplyNewlyLearnedBaseline()
        if not lastClassId or not lastSpecIndex then return end
        if InCombatLockdown() then
            pendingSpecCheck = true
            return
        end

        local classCfg = SURREAL_ACTIONBAR_CONFIG and SURREAL_ACTIONBAR_CONFIG[lastClassId]
        local specCfg = classCfg and classCfg.specs and classCfg.specs[lastSpecIndex]
        local baseline = specCfg and specCfg.slots
        if not baseline then return end

        local changed = false
        ignoreSlotEvents = true
        for i = 1, SLOT_COUNT do
            local spellId = tonumber(baseline[i]) or 0
            if spellId > 0 and not HasAction(i) and IsSpellKnown(spellId) then
                PickupSpell(spellId)
                PlaceAction(i)
                ClearCursor()
                changed = true
            end
        end
        ignoreSlotEvents = false

        if changed and hasReceivedAuthoritativeLoadout then
            SSUI.Handle("SurrealActionBar", "SaveLoadout", lastClassId, lastSpecIndex, CurrentSlots())
            RefreshProcs()
        end
    end

    -- =================================================================
    --  S L A S H   C O M M A N D
    -- =================================================================
    SLASH_SURREALACTIONBARRESET1 = "/actionbarreset"
    SlashCmdList["SURREALACTIONBARRESET"] = function()
        if not lastClassId or not lastSpecIndex then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff5555SurrealActionBar:|r spec not detected yet.")
            return
        end
        if InCombatLockdown() then
            DEFAULT_CHAT_FRAME:AddMessage("|cffff5555SurrealActionBar:|r cannot reset while in combat.")
            return
        end
        SSUI.Handle("SurrealActionBar", "ResetLoadout", lastClassId, lastSpecIndex)
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99SurrealActionBar:|r loadout reset to server default.")
    end

    SLASH_SURREALHUDUNLOCK1 = "/hudunlock"
    SlashCmdList["SURREALHUDUNLOCK"] = function()
        SetAllAnchorsLocked(false)
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99SurrealActionBar:|r HUD unlocked -- drag the blue \"(drag me)\" strips (action bar, menu/bags, stance bar) to reposition, then /hudlock to save.")
    end

    SLASH_SURREALHUDLOCK1 = "/hudlock"
    SlashCmdList["SURREALHUDLOCK"] = function()
        for name, a in pairs(anchors) do
            SaveAnchorPosition(name, a.frame)
        end
        SetAllAnchorsLocked(true)
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99SurrealActionBar:|r HUD locked and positions saved.")
    end

    -- Diagnostic: prints every registered proc rule for the current spec
    -- plus every currently-active player buff / target debuff, so a proc
    -- rule that isn't triggering can be compared against what auras are
    -- actually up at that moment (e.g. wrong watchBuffSpellId configured
    -- on the website, or the aura is on the target rather than the player).
    SLASH_SURREALACTIONBARPROCDEBUG1 = "/actionbarprocdebug"
    SlashCmdList["SURREALACTIONBARPROCDEBUG"] = function()
        DEFAULT_CHAT_FRAME:AddMessage(string.format(
            "|cff33ff99SurrealActionBar:|r proc rules (class %s, spec %s):",
            tostring(lastClassId), tostring(lastSpecIndex)))
        local any = false
        local spellSlotMap = BuildSpellSlotMap()
        for watchId, rules in pairs(watchToRules) do
            for _, rule in ipairs(rules) do
                any = true
                local slot = spellSlotMap[rule.targetSpellId]
                local ov = slot and overlays[slot]
                DEFAULT_CHAT_FRAME:AddMessage(string.format(
                    "  watches spellId %s -> swap ability %s's icon to %s (currently slot=%s, enabled=%s, currently active=%s)",
                    tostring(watchId), tostring(rule.targetSpellId), tostring(rule.swapIconName),
                    tostring(slot or "not on bar"), tostring(rule.enabled), tostring(ov and ov.procActive)))
                if ov then
                    DEFAULT_CHAT_FRAME:AddMessage(string.format(
                        "    swap texture: shown=%s texture=%s alpha=%.2f",
                        tostring(ov.swap:IsShown()), tostring(ov.swap:GetTexture()), ov.swap:GetAlpha()))
                    DEFAULT_CHAT_FRAME:AddMessage(string.format(
                        "    button: level=%s strata=%s | cooldownFrame: level=%s strata=%s",
                        tostring(ov.btn:GetFrameLevel()), tostring(ov.btn:GetFrameStrata()),
                        tostring(ov.cooldownFrame and ov.cooldownFrame:GetFrameLevel()), tostring(ov.cooldownFrame and ov.cooldownFrame:GetFrameStrata())))
                end
            end
        end
        if not any then
            DEFAULT_CHAT_FRAME:AddMessage("  (no proc rules configured for this spec)")
        end

        -- Bar-replacing addons (Bartender4/Dominos/ElvUI) commonly re-skin
        -- or re-parent ActionButton1-12 and can hide/cover any texture we
        -- add to them that they don't recognize -- worth ruling out.
        for _, name in ipairs({ "Bartender4", "Dominos", "ElvUI", "Bongos3" }) do
            if IsAddOnLoaded and IsAddOnLoaded(name) then
                DEFAULT_CHAT_FRAME:AddMessage(string.format(
                    "|cffff5555SurrealActionBar:|r WARNING: %s is loaded and may re-skin/hide action buttons.", name))
            end
        end

        DEFAULT_CHAT_FRAME:AddMessage("Active player buffs (incl. passive):")
        for i = 1, 40 do
            local name, _, _, _, _, _, _, _, _, _, spellId = UnitBuff("player", i, "HELPFUL|PASSIVE")
            if not name then break end
            DEFAULT_CHAT_FRAME:AddMessage(string.format("  %s (id %s)", name, tostring(spellId)))
        end

        if UnitExists("target") then
            DEFAULT_CHAT_FRAME:AddMessage("Active debuffs you placed on your target:")
            for i = 1, 40 do
                local name, _, _, _, _, _, _, _, _, _, spellId = UnitDebuff("target", i, "PLAYER")
                if not name then break end
                DEFAULT_CHAT_FRAME:AddMessage(string.format("  %s (id %s)", name, tostring(spellId)))
            end
        end
    end

    -- =================================================================
    --  E V E N T S
    -- =================================================================
    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
    eventFrame:RegisterEvent("CHARACTER_POINTS_CHANGED")
    eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    eventFrame:RegisterEvent("UNIT_AURA")
    eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
    eventFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")

    -- UNIT_AURA/PLAYER_TARGET_CHANGED/ACTIONBAR_SLOT_CHANGED can all fire
    -- rapidly back-to-back (e.g. several auras refreshing at once while a
    -- form/proc is active) -- calling the full RefreshProcs() scan (up to
    -- 80 UnitBuff/UnitDebuff calls) synchronously on every single one of
    -- those events was a real source of frame drops. Coalesce bursts into
    -- a single throttled pass at most twice a second instead of once per
    -- event by just marking the icons "dirty" here and letting a small
    -- OnUpdate ticker do the actual (heavier) refresh.
    local procsDirty = false
    local procThrottle = CreateFrame("Frame")
    procThrottle.elapsed = 0
    procThrottle:SetScript("OnUpdate", function(self, dt)
        self.elapsed = self.elapsed + dt
        if self.elapsed < 0.5 then return end
        self.elapsed = 0
        if procsDirty then
            procsDirty = false
            RefreshProcs()
        end
    end)

    eventFrame:SetScript("OnEvent", function(self, event, arg1)
        if event == "UNIT_AURA" then
            if arg1 == "player" or arg1 == "target" then procsDirty = true end
            return
        end

        if event == "PLAYER_TARGET_CHANGED" then
            procsDirty = true
            return
        end

        if event == "ACTIONBAR_SLOT_CHANGED" then
            local slot = arg1
            if not ignoreSlotEvents and slot and slot >= 1 and slot <= SLOT_COUNT
               and lastClassId and lastSpecIndex and hasReceivedAuthoritativeLoadout then
                SSUI.Handle("SurrealActionBar", "SaveLoadout", lastClassId, lastSpecIndex, CurrentSlots())
            end
            procsDirty = true
            return
        end

        if event == "PLAYER_REGEN_DISABLED" then
            return
        end

        if event == "PLAYER_REGEN_ENABLED" then
            if pendingSpecCheck then
                pendingSpecCheck = nil
                CheckSpec()
                ApplyNewlyLearnedBaseline()
            end
            return
        end

        -- PLAYER_ENTERING_WORLD / PLAYER_TALENT_UPDATE / CHARACTER_POINTS_CHANGED
        CheckSpec()
        ApplyNewlyLearnedBaseline()
    end)

    -- Paint immediately from the last-known cached spec/slots (if any) so
    -- the bar isn't sitting empty while the real detect+fetch round trip
    -- below is still in flight -- see the cache block above for why this
    -- is safe (always superseded by the real ReceiveLoadout response).
    ApplyCachedLoadout()

    -- In case this script loads after PLAYER_ENTERING_WORLD already fired
    -- (SSUI can push scripts post-login), do an initial check right away.
    CheckSpec()

    -- Safety net: SurrealTalentFrame_SSUI.lua's real spec data arrives
    -- asynchronously (server round-trip) and pushes a notification here
    -- once it lands (see SurrealActionBar_OnTalentDataReady above), but
    -- that push only works if THIS script has already finished loading
    -- and defined the callback by the time that data shows up -- SSUI can
    -- load addon files in either order, so on a fast reply the push can
    -- fire before we even exist yet, silently doing nothing. Poll as a
    -- fallback that doesn't depend on load order at all: retry CheckSpec
    -- every 0.5s for up to 15s after login, stopping early the moment
    -- spec detection actually succeeds.
    do
        local pollFrame = CreateFrame("Frame")
        pollFrame.elapsed = 0
        pollFrame.totalElapsed = 0
        pollFrame:SetScript("OnUpdate", function(self, dt)
            self.elapsed = self.elapsed + dt
            self.totalElapsed = self.totalElapsed + dt
            if lastClassId and lastSpecIndex then
                self:SetScript("OnUpdate", nil)
                return
            end
            if self.totalElapsed >= 15 then
                self:SetScript("OnUpdate", nil)
                return
            end
            if self.elapsed >= 0.5 then
                self.elapsed = 0
                CheckSpec()
            end
        end)
    end
end

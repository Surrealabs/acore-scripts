-------------------------------------------------------------------------------
-- SurrealCollections_AIO.lua
--
-- An in-game item collection browser (like AtlasLoot).
-- Categories: Glyphs, Weapons, Armor, Consumables, Recipes, etc.
-- Server queries item_template and sends paged results to the client.
--
-- Usage:
--   /collections   — toggle the collections window
--   Also accessible from a micro-button hook or keybind (Shift-P)
-------------------------------------------------------------------------------

local AIO = AIO or require("AIO")

if AIO.AddAddon() then
    ---------------------------------------------------------------------------
    -- SERVER SIDE
    ---------------------------------------------------------------------------
    local Handlers = AIO.AddHandlers("SurrealCollections", {})

    -- =====================================================================
    --  Category definitions (server-side mirrors of client categories)
    -- =====================================================================
    -- Item class IDs from item_template
    -- 0=Consumable, 1=Container, 2=Weapon, 3=Gem, 4=Armor, 5=Reagent,
    -- 6=Projectile, 7=TradeGoods, 9=Recipe, 12=Quest, 15=Misc, 16=Glyph

    -- Armor subclasses: 0=Misc, 1=Cloth, 2=Leather, 3=Mail, 4=Plate,
    --   5=Buckler(unused), 6=Shield, 7=Libram, 8=Idol, 9=Totem, 10=Sigil
    -- Armor InventoryType: 1=Head, 2=Neck, 3=Shoulder, 4=Shirt, 5=Chest,
    --   6=Waist, 7=Legs, 8=Feet, 9=Wrists, 10=Hands, 11=Finger, 12=Trinket,
    --   13=OneHand, 14=Shield, 15=Ranged, 16=Back, 20=Robe

    local PAGE_SIZE = 18  -- items per page (matches client row count)

    -- Build the WHERE clause for a category query
    local function CategoryWhere(catID, subCatID, classFilter)
        -- catID: top-level category
        -- subCatID: sub-category (optional)
        -- classFilter: player classID for glyphs

        if catID == "GLYPHS" then
            local w = "class=16"
            if classFilter then
                w = w .. " AND subclass=" .. classFilter
            end
            w = w .. " AND name NOT LIKE 'NPC%' AND name NOT LIKE 'Deprecated%'"
            return w
        elseif catID == "WEAPONS" then
            local w = "class=2"
            if subCatID then w = w .. " AND subclass=" .. subCatID end
            return w
        elseif catID == "ARMOR" then
            local w = "class=4"
            if subCatID then w = w .. " AND subclass=" .. subCatID end
            return w
        elseif catID == "CONSUMABLES" then
            return "class=0"
        elseif catID == "RECIPES" then
            return "class=9"
        elseif catID == "GEMS" then
            return "class=3"
        elseif catID == "TRADESKILL" then
            return "class=7"
        elseif catID == "CONTAINERS" then
            return "class=1"
        elseif catID == "QUEST" then
            return "class=12"
        elseif catID == "MISC" then
            return "class=15"
        else
            return "1=1"
        end
    end

    -- Glyph sub-class → class mapping
    local GLYPH_SUBCLASS = {
        WARRIOR = 1, PALADIN = 2, HUNTER = 3, ROGUE = 4,
        PRIEST = 5, DEATHKNIGHT = 6, SHAMAN = 7, MAGE = 8,
        WARLOCK = 9, DRUID = 11,
    }

    -- Client requests a page of items
    function Handlers.Browse(player, catID, subCatID, page, search)
        page = page or 1
        if page < 1 then page = 1 end

        -- For glyphs, map class token to subclass
        local classFilter = nil
        if catID == "GLYPHS" and subCatID and GLYPH_SUBCLASS[subCatID] then
            classFilter = GLYPH_SUBCLASS[subCatID]
            subCatID = nil  -- clear so CategoryWhere uses classFilter
        end

        local whereClause = CategoryWhere(catID, subCatID, classFilter)

        -- Search filter
        if search and search ~= "" then
            -- Sanitize search
            local safe = search:gsub("'", ""):gsub('"', ""):gsub("\\", "")
            whereClause = whereClause .. " AND name LIKE '%" .. safe .. "%'"
        end

        -- Count total
        local countQ = WorldDBQuery(
            "SELECT COUNT(*) FROM item_template WHERE " .. whereClause)
        local total = 0
        if countQ then
            total = countQ:GetUInt32(0)
        end

        local totalPages = math.ceil(total / PAGE_SIZE)
        if totalPages < 1 then totalPages = 1 end
        if page > totalPages then page = totalPages end

        local offset = (page - 1) * PAGE_SIZE

        -- Fetch items
        local items = {}
        local q = WorldDBQuery(
            "SELECT entry, name, Quality, ItemLevel, RequiredLevel, " ..
            "InventoryType, class, subclass " ..
            "FROM item_template WHERE " .. whereClause ..
            " ORDER BY ItemLevel DESC, name ASC" ..
            " LIMIT " .. PAGE_SIZE .. " OFFSET " .. offset)

        if q then
            repeat
                local entry    = q:GetUInt32(0)
                local name     = q:GetString(1)
                local quality  = q:GetUInt32(2)
                local ilvl     = q:GetUInt32(3)
                local reqLvl   = q:GetUInt32(4)
                local invType  = q:GetUInt32(5)
                local iClass   = q:GetUInt32(6)
                local iSubClass = q:GetUInt32(7)
                table.insert(items, {
                    entry, name, quality, ilvl, reqLvl, invType, iClass, iSubClass
                })
            until not q:NextRow()
        end

        AIO.Handle(player, "SurrealCollections", "ShowItems",
            catID, page, totalPages, total, items)
    end

    -- Client requests item tooltip data (itemID)
    function Handlers.GetItemLink(player, itemID)
        if not itemID or type(itemID) ~= "number" then return end
        -- Send the item directly to player to cache it
        local link = "|cffffffff|Hitem:" .. itemID ..
            ":0:0:0:0:0:0:0:0|h[Item]|h|r"
        AIO.Handle(player, "SurrealCollections", "CacheItem", itemID)
    end

else
    ---------------------------------------------------------------------------
    -- CLIENT SIDE
    ---------------------------------------------------------------------------
    local ClientHandlers = AIO.AddHandlers("SurrealCollections", {})

    -- =================================================================
    --  C O N F I G
    -- =================================================================
    local CFG = {
        WIDTH       = 980,
        HEIGHT      = 640,
        SIDEBAR_W   = 160,
        ITEM_H      = 26,       -- height per item row
        COLS        = 1,        -- single column list view
        TAB_H       = 28,      -- tab bar height
        SEARCH_H    = 24,      -- search bar area
        HEADER_H    = 18,      -- column header row
        PAGE_H      = 28,      -- pagination bar height
        TOP_PAD     = 36,      -- top padding (title bar)
        BOT_PAD     = 12,      -- bottom padding
    }

    -- Dynamically compute how many rows fit
    -- Available content height = HEIGHT - TOP_PAD - TAB_H - SEARCH_H - HEADER_H - PAGE_H - BOT_PAD - padding
    local CONTENT_TOP = CFG.TOP_PAD + CFG.TAB_H  -- where content starts below tabs
    local AVAIL_H = CFG.HEIGHT - CONTENT_TOP - CFG.SEARCH_H - CFG.HEADER_H
                    - CFG.PAGE_H - CFG.BOT_PAD - 12  -- 12px extra spacing
    local ITEMS_PER_PAGE = math.floor(AVAIL_H / CFG.ITEM_H)
    if ITEMS_PER_PAGE < 1 then ITEMS_PER_PAGE = 1 end

    -- Quality colors
    local QUALITY_COLORS = {
        [0] = { 0.62, 0.62, 0.62 },  -- Poor (grey)
        [1] = { 1.00, 1.00, 1.00 },  -- Common (white)
        [2] = { 0.12, 1.00, 0.00 },  -- Uncommon (green)
        [3] = { 0.00, 0.44, 0.87 },  -- Rare (blue)
        [4] = { 0.64, 0.21, 0.93 },  -- Epic (purple)
        [5] = { 1.00, 0.50, 0.00 },  -- Legendary (orange)
        [6] = { 0.90, 0.80, 0.50 },  -- Artifact
        [7] = { 0.00, 0.80, 1.00 },  -- Heirloom
    }

    -- =================================================================
    --  C A T E G O R Y   D E F I N I T I O N S
    -- =================================================================
    local CATEGORIES = {
        { id = "GLYPHS",      label = "Glyphs",       icon = "Interface\\Icons\\INV_Inscription_Tradeskill01",
          subcats = {
            { id = "WARRIOR",     label = "Warrior" },
            { id = "PALADIN",     label = "Paladin" },
            { id = "HUNTER",      label = "Hunter" },
            { id = "ROGUE",       label = "Rogue" },
            { id = "PRIEST",      label = "Priest" },
            { id = "DEATHKNIGHT", label = "Death Knight" },
            { id = "SHAMAN",      label = "Shaman" },
            { id = "MAGE",        label = "Mage" },
            { id = "WARLOCK",     label = "Warlock" },
            { id = "DRUID",       label = "Druid" },
          }
        },
        { id = "ARMOR",       label = "Armor",         icon = "Interface\\Icons\\INV_Chest_Chain",
          subcats = {
            { id = "1",  label = "Cloth" },
            { id = "2",  label = "Leather" },
            { id = "3",  label = "Mail" },
            { id = "4",  label = "Plate" },
            { id = "6",  label = "Shield" },
            { id = "0",  label = "Miscellaneous" },
          }
        },
        { id = "WEAPONS",     label = "Weapons",       icon = "Interface\\Icons\\INV_Sword_04",
          subcats = {
            { id = "0",  label = "One-Hand Axe" },
            { id = "1",  label = "Two-Hand Axe" },
            { id = "2",  label = "Bow" },
            { id = "3",  label = "Gun" },
            { id = "4",  label = "One-Hand Mace" },
            { id = "5",  label = "Two-Hand Mace" },
            { id = "6",  label = "Polearm" },
            { id = "7",  label = "One-Hand Sword" },
            { id = "8",  label = "Two-Hand Sword" },
            { id = "10", label = "Staff" },
            { id = "13", label = "Fist Weapon" },
            { id = "15", label = "Dagger" },
            { id = "16", label = "Thrown" },
            { id = "18", label = "Crossbow" },
            { id = "19", label = "Wand" },
          }
        },
        { id = "CONSUMABLES", label = "Consumables",   icon = "Interface\\Icons\\INV_Potion_54" },
        { id = "GEMS",        label = "Gems",           icon = "Interface\\Icons\\INV_Misc_Gem_01" },
        { id = "RECIPES",     label = "Recipes",        icon = "Interface\\Icons\\INV_Scroll_03" },
        { id = "TRADESKILL",  label = "Trade Goods",    icon = "Interface\\Icons\\INV_Fabric_Silk_02" },
        { id = "CONTAINERS",  label = "Containers",     icon = "Interface\\Icons\\INV_Box_01" },
        { id = "QUEST",       label = "Quest Items",    icon = "Interface\\Icons\\INV_Misc_Map02" },
        { id = "MISC",        label = "Miscellaneous",  icon = "Interface\\Icons\\INV_Misc_Bag_10" },
    }

    -- =================================================================
    --  S T A T E
    -- =================================================================
    local activeCat    = nil
    local activeSubCat = nil
    local currentPage  = 1
    local totalPages   = 1
    local totalItems   = 0
    local searchText   = ""
    local itemRows     = {}
    local subCatBtns   = {}
    local activeTab    = "COLLECTIONS"  -- "COLLECTIONS" or "ACHIEVEMENTS"

    -- =================================================================
    --  M A I N   F R A M E
    -- =================================================================
    local frame = CreateFrame("Frame", "SurrealCollections", UIParent)
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

    -- Background + Border (matching talent frame style)
    frame:SetBackdrop({
        bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0.06, 0.06, 0.10, 0.95)
    frame:SetBackdropBorderColor(0.30, 0.30, 0.35, 1)

    -- Title
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -12)
    title:SetText("|cffffd100Collections|r")

    -- Close button
    local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() frame:Hide() end)

    -- ESC to close
    tinsert(UISpecialFrames, "SurrealCollections")

    -- =================================================================
    --  T A B   B A R   ( C o l l e c t i o n s  |  A c h i e v e m e n t s )
    -- =================================================================
    local tabBar = CreateFrame("Frame", nil, frame)
    tabBar:SetPoint("TOPLEFT", 8, -CFG.TOP_PAD)
    tabBar:SetSize(CFG.WIDTH - 16, CFG.TAB_H)

    local tabBarBg = tabBar:CreateTexture(nil, "BACKGROUND")
    tabBarBg:SetAllPoints()
    tabBarBg:SetTexture(0.08, 0.08, 0.10, 0.8)

    -- Container frames for each tab's content
    local collectionsBody  -- forward declare, built below
    local achievementsBody -- forward declare, built below

    local function MakeTab(parent, label, xOff, tabID)
        local tb = CreateFrame("Button", nil, parent)
        tb:SetSize(120, CFG.TAB_H - 2)
        tb:SetPoint("TOPLEFT", xOff, -1)

        local tbBg = tb:CreateTexture(nil, "BACKGROUND")
        tbBg:SetAllPoints()
        tbBg:SetTexture(0.15, 0.15, 0.18, 0.6)
        tb.bg = tbBg

        local tbText = tb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        tbText:SetPoint("CENTER", 0, 0)
        tbText:SetText(label)
        tb.label = tbText

        local tbHL = tb:CreateTexture(nil, "HIGHLIGHT")
        tbHL:SetAllPoints()
        tbHL:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
        tbHL:SetBlendMode("ADD")
        tbHL:SetAlpha(0.15)

        tb.tabID = tabID
        return tb
    end

    local collectionsTab  = MakeTab(tabBar, "|cffffffffCollections|r",   4, "COLLECTIONS")
    local achievementsTab = MakeTab(tabBar, "|cffffffffAchievements|r", 128, "ACHIEVEMENTS")

    local function SetActiveTab(tabID)
        activeTab = tabID
        if tabID == "COLLECTIONS" then
            collectionsTab.bg:SetTexture(0.25, 0.25, 0.35, 0.9)
            achievementsTab.bg:SetTexture(0.15, 0.15, 0.18, 0.5)
            title:SetText("|cffffd100Collections|r")
            if collectionsBody  then collectionsBody:Show()  end
            if achievementsBody then achievementsBody:Hide() end
        else
            collectionsTab.bg:SetTexture(0.15, 0.15, 0.18, 0.5)
            achievementsTab.bg:SetTexture(0.25, 0.25, 0.35, 0.9)
            title:SetText("|cffffd100Achievements|r")
            if collectionsBody  then collectionsBody:Hide()  end
            if achievementsBody then achievementsBody:Show() end
        end
    end

    collectionsTab:SetScript("OnClick",  function() SetActiveTab("COLLECTIONS") end)
    achievementsTab:SetScript("OnClick", function()
        SetActiveTab("ACHIEVEMENTS")
        -- Load Blizzard achievement UI on demand if available
        if not AchievementFrame then
            pcall(function()
                -- Try the raw addon load
                local loaded = LoadAddOn("Blizzard_AchievementUI")
            end)
        end
    end)

    -- =================================================================
    --  C O L L E C T I O N S   B O D Y   ( sidebar + content )
    -- =================================================================
    collectionsBody = CreateFrame("Frame", nil, frame)
    collectionsBody:SetPoint("TOPLEFT", 8, -(CFG.TOP_PAD + CFG.TAB_H + 2))
    collectionsBody:SetPoint("BOTTOMRIGHT", -8, CFG.BOT_PAD)

    -- ----- SIDEBAR -----
    local sidebar = CreateFrame("Frame", nil, collectionsBody)
    sidebar:SetPoint("TOPLEFT", 0, 0)
    sidebar:SetSize(CFG.SIDEBAR_W, CFG.HEIGHT - CFG.TOP_PAD - CFG.TAB_H
                    - CFG.BOT_PAD - 8)

    local sidebarBg = sidebar:CreateTexture(nil, "BACKGROUND")
    sidebarBg:SetAllPoints()
    sidebarBg:SetTexture(0.10, 0.10, 0.12, 0.7)

    local catBtns = {}
    for ci, cat in ipairs(CATEGORIES) do
        local cb = CreateFrame("Button", nil, sidebar)
        cb:SetSize(CFG.SIDEBAR_W - 4, 22)
        cb:SetPoint("TOPLEFT", 2, -((ci - 1) * 23) - 2)

        local cbBg = cb:CreateTexture(nil, "BACKGROUND")
        cbBg:SetAllPoints()
        cbBg:SetTexture(0.15, 0.15, 0.18, 0.5)
        cb.bg = cbBg

        local cbIcon = cb:CreateTexture(nil, "ARTWORK")
        cbIcon:SetSize(18, 18)
        cbIcon:SetPoint("LEFT", 2, 0)
        if cat.icon then cbIcon:SetTexture(cat.icon) end

        local cbText = cb:CreateFontString(nil, "OVERLAY",
            "GameFontNormalSmall")
        cbText:SetPoint("LEFT", cbIcon, "RIGHT", 4, 0)
        cbText:SetText(cat.label)

        local cbHL = cb:CreateTexture(nil, "HIGHLIGHT")
        cbHL:SetAllPoints()
        cbHL:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
        cbHL:SetBlendMode("ADD")
        cbHL:SetAlpha(0.2)

        cb.catData = cat
        cb:SetScript("OnClick", function(self)
            activeCat = self.catData.id
            activeSubCat = nil
            currentPage = 1
            for _, b in ipairs(catBtns) do
                b.bg:SetTexture(0.15, 0.15, 0.18, 0.5)
            end
            self.bg:SetTexture(0.25, 0.25, 0.35, 0.8)
            ShowSubCategories(self.catData)
            RequestPage()
        end)

        catBtns[ci] = cb
    end

    -- ----- SUB-CATEGORY PANEL -----
    local subPanel = CreateFrame("Frame", nil, collectionsBody)
    subPanel:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 2, 0)
    subPanel:SetSize(120, CFG.HEIGHT - CFG.TOP_PAD - CFG.TAB_H
                     - CFG.BOT_PAD - 8)
    subPanel:Hide()

    local subPanelBg = subPanel:CreateTexture(nil, "BACKGROUND")
    subPanelBg:SetAllPoints()
    subPanelBg:SetTexture(0.10, 0.10, 0.12, 0.5)

    local MAX_SUBCATS = 20
    for si = 1, MAX_SUBCATS do
        local sb = CreateFrame("Button", nil, subPanel)
        sb:SetSize(116, 20)
        sb:SetPoint("TOPLEFT", 2, -((si - 1) * 21) - 2)

        local sbBg = sb:CreateTexture(nil, "BACKGROUND")
        sbBg:SetAllPoints()
        sbBg:SetTexture(0.15, 0.15, 0.18, 0.4)
        sb.bg = sbBg

        local sbText = sb:CreateFontString(nil, "OVERLAY",
            "GameFontNormalSmall")
        sbText:SetPoint("LEFT", 6, 0)
        sb.label = sbText

        local sbHL = sb:CreateTexture(nil, "HIGHLIGHT")
        sbHL:SetAllPoints()
        sbHL:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
        sbHL:SetBlendMode("ADD")
        sbHL:SetAlpha(0.2)

        sb:Hide()
        sb.subID = nil
        sb:SetScript("OnClick", function(self)
            activeSubCat = self.subID
            currentPage = 1
            for _, b in ipairs(subCatBtns) do
                b.bg:SetTexture(0.15, 0.15, 0.18, 0.4)
            end
            self.bg:SetTexture(0.20, 0.25, 0.35, 0.7)
            RequestPage()
        end)

        subCatBtns[si] = sb
    end

    function ShowSubCategories(catData)
        for si = 1, MAX_SUBCATS do
            subCatBtns[si]:Hide()
        end
        if catData.subcats and #catData.subcats > 0 then
            for si, sc in ipairs(catData.subcats) do
                if si <= MAX_SUBCATS then
                    subCatBtns[si].subID = sc.id
                    subCatBtns[si].label:SetText(sc.label)
                    subCatBtns[si].bg:SetTexture(0.15, 0.15, 0.18, 0.4)
                    subCatBtns[si]:Show()
                end
            end
            subPanel:Show()
        else
            subPanel:Hide()
        end
    end

    -- ----- CONTENT AREA -----
    local contentX = CFG.SIDEBAR_W + 124
    local contentW = CFG.WIDTH - contentX - 20

    local content = CreateFrame("Frame", nil, collectionsBody)
    content:SetPoint("TOPLEFT", contentX, 0)
    content:SetPoint("BOTTOMRIGHT", 0, 0)

    -- Search bar
    local searchBox = CreateFrame("EditBox", "SurrealCollSearchBox",
        content, "InputBoxTemplate")
    searchBox:SetSize(contentW - 80, 20)
    searchBox:SetPoint("TOPLEFT", 0, 0)
    searchBox:SetAutoFocus(false)
    searchBox:SetMaxLetters(40)
    searchBox:SetScript("OnEnterPressed", function(self)
        searchText = self:GetText() or ""
        currentPage = 1
        RequestPage()
        self:ClearFocus()
    end)
    searchBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    -- Search button
    local searchBtn = CreateFrame("Button", nil, content,
        "UIPanelButtonTemplate")
    searchBtn:SetSize(70, 22)
    searchBtn:SetPoint("LEFT", searchBox, "RIGHT", 6, 0)
    searchBtn:SetText("Search")
    searchBtn:SetScript("OnClick", function()
        searchText = searchBox:GetText() or ""
        currentPage = 1
        RequestPage()
    end)

    -- Pagination bar (create FIRST so we can anchor the list above it)
    local pageFrame = CreateFrame("Frame", nil, content)
    pageFrame:SetSize(contentW, CFG.PAGE_H)
    pageFrame:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 0)
    pageFrame:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)

    local pageBg = pageFrame:CreateTexture(nil, "BACKGROUND")
    pageBg:SetAllPoints()
    pageBg:SetTexture(0.08, 0.08, 0.10, 0.5)

    local prevBtn = CreateFrame("Button", nil, pageFrame,
        "UIPanelButtonTemplate")
    prevBtn:SetSize(60, 22)
    prevBtn:SetPoint("LEFT", 4, 0)
    prevBtn:SetText("< Prev")
    prevBtn:SetScript("OnClick", function()
        if currentPage > 1 then
            currentPage = currentPage - 1
            RequestPage()
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
            RequestPage()
        end
    end)

    local pageText = pageFrame:CreateFontString(nil, "OVERLAY",
        "GameFontNormal")
    pageText:SetPoint("CENTER", 0, 0)

    local totalText = pageFrame:CreateFontString(nil, "OVERLAY",
        "GameFontNormalSmall")
    totalText:SetPoint("LEFT", prevBtn, "RIGHT", 8, 0)

    -- Column headers
    local headerFrame = CreateFrame("Frame", nil, content)
    headerFrame:SetSize(contentW, CFG.HEADER_H)
    headerFrame:SetPoint("TOPLEFT", 0, -(CFG.SEARCH_H + 2))

    local headerBg = headerFrame:CreateTexture(nil, "BACKGROUND")
    headerBg:SetAllPoints()
    headerBg:SetTexture(0.12, 0.12, 0.15, 0.5)

    local hdrName = headerFrame:CreateFontString(nil, "OVERLAY",
        "GameFontNormalSmall")
    hdrName:SetPoint("LEFT", 30, 0)
    hdrName:SetText("|cffaaaaccName|r")

    local hdrIlvl = headerFrame:CreateFontString(nil, "OVERLAY",
        "GameFontNormalSmall")
    hdrIlvl:SetPoint("RIGHT", -60, 0)
    hdrIlvl:SetText("|cffaaaacciLvl|r")

    local hdrReq = headerFrame:CreateFontString(nil, "OVERLAY",
        "GameFontNormalSmall")
    hdrReq:SetPoint("RIGHT", -10, 0)
    hdrReq:SetText("|cffaaaaccReq|r")

    -- Item list area — anchored between header and pagination
    local listFrame = CreateFrame("Frame", nil, content)
    listFrame:SetPoint("TOPLEFT", headerFrame, "BOTTOMLEFT", 0, -1)
    listFrame:SetPoint("BOTTOMRIGHT", pageFrame, "TOPRIGHT", 0, 2)

    -- Create item rows
    for ri = 1, ITEMS_PER_PAGE do
        local row = CreateFrame("Button", nil, listFrame)
        row:SetSize(contentW, CFG.ITEM_H)
        row:SetPoint("TOPLEFT", 0, -((ri - 1) * CFG.ITEM_H))

        local rowBg = row:CreateTexture(nil, "BACKGROUND")
        rowBg:SetAllPoints()
        if ri % 2 == 0 then
            rowBg:SetTexture(0.12, 0.12, 0.14, 0.4)
        else
            rowBg:SetTexture(0.10, 0.10, 0.12, 0.2)
        end
        row.bg = rowBg

        -- Icon
        local ico = row:CreateTexture(nil, "ARTWORK")
        ico:SetSize(20, 20)
        ico:SetPoint("LEFT", 4, 0)
        row.icon = ico

        -- Name
        local nameText = row:CreateFontString(nil, "OVERLAY",
            "GameFontNormalSmall")
        nameText:SetPoint("LEFT", ico, "RIGHT", 6, 0)
        nameText:SetPoint("RIGHT", -120, 0)
        nameText:SetJustifyH("LEFT")
        row.nameText = nameText

        -- Item Level
        local ilvlText = row:CreateFontString(nil, "OVERLAY",
            "GameFontNormalSmall")
        ilvlText:SetPoint("RIGHT", -60, 0)
        ilvlText:SetWidth(50)
        ilvlText:SetJustifyH("CENTER")
        row.ilvlText = ilvlText

        -- Required Level
        local reqText = row:CreateFontString(nil, "OVERLAY",
            "GameFontNormalSmall")
        reqText:SetPoint("RIGHT", -10, 0)
        reqText:SetWidth(40)
        reqText:SetJustifyH("CENTER")
        row.reqText = reqText

        -- Highlight
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
        hl:SetBlendMode("ADD")
        hl:SetAlpha(0.15)

        row.itemEntry = nil
        row:Hide()

        -- Tooltip — use SetHyperlink with full item string
        row:SetScript("OnEnter", function(self)
            if self.itemEntry then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(
                    "item:" .. self.itemEntry ..
                    ":0:0:0:0:0:0:0")
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        -- Click: Shift-click to link in chat
        row:SetScript("OnClick", function(self, button)
            if self.itemEntry and IsShiftKeyDown() then
                local _, link = GetItemInfo(self.itemEntry)
                if link then
                    if ChatFrameEditBox and ChatFrameEditBox:IsShown() then
                        ChatFrameEditBox:Insert(link)
                    elseif ChatFrame1EditBox
                           and ChatFrame1EditBox:IsShown() then
                        ChatFrame1EditBox:Insert(link)
                    end
                end
            end
        end)

        itemRows[ri] = row
    end

    -- =================================================================
    --  A C H I E V E M E N T S   B O D Y
    -- =================================================================
    achievementsBody = CreateFrame("Frame", nil, frame)
    achievementsBody:SetPoint("TOPLEFT", 8, -(CFG.TOP_PAD + CFG.TAB_H + 2))
    achievementsBody:SetPoint("BOTTOMRIGHT", -8, CFG.BOT_PAD)
    achievementsBody:Hide()

    -- Embed the Blizzard AchievementFrame inside our body
    local achPlaceholder = achievementsBody:CreateFontString(nil, "OVERLAY",
        "GameFontNormal")
    achPlaceholder:SetPoint("CENTER", 0, 0)
    achPlaceholder:SetText("|cff888888Loading Achievements...|r")

    -- When the achievements tab is shown, try to parent the Blizzard
    -- AchievementFrame into our container
    achievementsBody:SetScript("OnShow", function(self)
        if AchievementFrame then
            AchievementFrame:SetParent(self)
            AchievementFrame:ClearAllPoints()
            AchievementFrame:SetAllPoints(self)
            AchievementFrame:Show()
            achPlaceholder:Hide()
        else
            achPlaceholder:SetText(
                "|cff888888Achievement UI not available.|r")
            achPlaceholder:Show()
        end
    end)

    achievementsBody:SetScript("OnHide", function()
        -- Restore AchievementFrame to UIParent when leaving tab
        if AchievementFrame then
            AchievementFrame:Hide()
            AchievementFrame:SetParent(UIParent)
        end
    end)

    -- =================================================================
    --  R E Q U E S T   /   D I S P L A Y
    -- =================================================================
    function RequestPage()
        if not activeCat then return end
        AIO.Handle("SurrealCollections", "Browse",
            activeCat, activeSubCat, currentPage, searchText)
    end

    local function DisplayItems(items)
        -- Hide all rows first
        for ri = 1, ITEMS_PER_PAGE do
            itemRows[ri]:Hide()
        end

        if not items then return end

        for ri, item in ipairs(items) do
            if ri > ITEMS_PER_PAGE then break end
            local row    = itemRows[ri]
            local entry  = item[1]
            local name   = item[2]
            local qual   = item[3] or 1
            local ilvl   = item[4] or 0
            local reqLvl = item[5] or 0

            row.itemEntry = entry

            -- Color name by quality
            local qc = QUALITY_COLORS[qual] or QUALITY_COLORS[1]
            row.nameText:SetTextColor(qc[1], qc[2], qc[3])
            row.nameText:SetText(name)

            -- Get icon from client cache (may need a frame to load)
            local _, _, _, _, _, _, _, _, _, tex = GetItemInfo(entry)
            if tex then
                row.icon:SetTexture(tex)
            else
                row.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
            end

            row.ilvlText:SetText(ilvl > 0 and ilvl or "")
            row.ilvlText:SetTextColor(0.7, 0.7, 0.7)

            row.reqText:SetText(reqLvl > 0 and reqLvl or "")
            row.reqText:SetTextColor(0.6, 0.6, 0.6)

            row:Show()
        end
    end

    -- =================================================================
    --  S E R V E R   ->   C L I E N T   H A N D L E R S
    -- =================================================================
    function ClientHandlers.ShowItems(player, catID, page, pages, total, items)
        currentPage = page
        totalPages  = pages
        totalItems  = total

        pageText:SetText(page .. " / " .. pages)
        totalText:SetText("|cff888888" .. total .. " items|r")

        if page <= 1 then prevBtn:Disable() else prevBtn:Enable() end
        if page >= pages then nextBtn:Disable() else nextBtn:Enable() end

        DisplayItems(items)
    end

    function ClientHandlers.CacheItem(player, itemID)
        -- Force client to cache the item for tooltip
        GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
        GameTooltip:SetHyperlink("item:" .. itemID .. ":0:0:0:0:0:0:0")
        GameTooltip:Hide()
    end

    -- =================================================================
    --  T O G G L E   F U N C T I O N
    -- =================================================================
    local function ToggleCollections()
        if frame:IsShown() then
            frame:Hide()
        else
            frame:Show()
        end
    end

    -- =================================================================
    --  S L A S H   C O M M A N D S
    -- =================================================================
    SLASH_SURREALCOLLECTIONS1 = "/collections"
    SLASH_SURREALCOLLECTIONS2 = "/col"
    SlashCmdList["SURREALCOLLECTIONS"] = function(msg)
        ToggleCollections()
    end

    -- =================================================================
    --  H O O K   A C H I E V E M E N T   B U T T O N   ( Y  key )
    -- =================================================================
    -- Override ToggleAchievementFrame to open our Collections instead
    ToggleAchievementFrame = function()
        ToggleCollections()
    end

    -- Hook the AchievementMicroButton if it exists
    local hookFrame = CreateFrame("Frame")
    hookFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    hookFrame:SetScript("OnEvent", function(self, event)
        if AchievementMicroButton then
            AchievementMicroButton:SetScript("OnClick", function()
                ToggleCollections()
            end)
        end
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    end)

    -- =================================================================
    --  O N   S H O W   —   D E F A U L T   T O   C O L L E C T I O N S
    -- =================================================================
    frame:SetScript("OnShow", function(self)
        -- Close other frames if open (mutual exclusion)
        if SurrealTalentFrame and SurrealTalentFrame:IsShown() then
            SurrealTalentFrame:Hide()
        end
        if SurrealCharacterFrame and SurrealCharacterFrame:IsShown() then
            SurrealCharacterFrame:Hide()
        end
        if SurrealSpellBook and SurrealSpellBook:IsShown() then
            SurrealSpellBook:Hide()
        end

        -- Ensure we're on the correct tab
        SetActiveTab(activeTab)

        if not activeCat then
            activeCat = "GLYPHS"
            local _, tok = UnitClass("player")
            activeSubCat = tok
            currentPage = 1
            -- Highlight the glyphs category
            if catBtns[1] then
                catBtns[1].bg:SetTexture(0.25, 0.25, 0.35, 0.8)
            end
            -- Show glyph subcategories
            for ci, cat in ipairs(CATEGORIES) do
                if cat.id == "GLYPHS" then
                    ShowSubCategories(cat)
                    -- Highlight current class subcat
                    for si, sc in ipairs(cat.subcats) do
                        if sc.id == tok and subCatBtns[si] then
                            subCatBtns[si].bg:SetTexture(
                                0.20, 0.25, 0.35, 0.7)
                        end
                    end
                    break
                end
            end
            RequestPage()
        end
    end)

end

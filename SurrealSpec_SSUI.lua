-------------------------------------------------------------------------------
-- SurrealSpec_SSUI.lua
--
-- Wowhead-style talent string import/export via chat commands.
-- Players can export their current build, import a build, and apply it
-- to their own character or their army bots.
--
-- Commands:
--   /spec export                — Prints your current talent string to chat
--   /spec import <string>       — Queue a build to apply (resets + learns)
--   /spec bot <name> <string>   — Apply a talent build to an army bot
--   /spec help                  — Show usage
--
-- Format: Wowhead-style talent string (digits per talent, trees split by -)
-- Example: "302023013-305053000520310053120501-0"
-------------------------------------------------------------------------------

local SSUI = SSUI or require("SSUI")

if SSUI.AddAddon() then
    ---------------------------------------------------------------------------
    -- SERVER SIDE
    ---------------------------------------------------------------------------
    local Handlers = SSUI.AddHandlers("SurrealSpec", {})

    -- Class ID → ordered talent tab IDs (same order as Wowhead)
    local CLASS_TABS = {
        [1]  = { 161, 164, 163 },        -- Warrior: Arms, Fury, Protection
        [2]  = { 381, 382, 383 },        -- Paladin: Holy, Protection, Retribution
        [3]  = { 361, 362, 363 },        -- Hunter: Beast Mastery, Marksmanship, Survival
        [4]  = { 181, 182, 183 },        -- Rogue: Assassination, Combat, Subtlety
        [5]  = { 201, 202, 203 },        -- Priest: Discipline, Holy, Shadow
        [6]  = { 398, 399, 400 },        -- Death Knight: Blood, Frost, Unholy
        [7]  = { 261, 262, 263 },        -- Shaman: Elemental, Enhancement, Restoration
        [8]  = { 41, 61, 81 },           -- Mage: Arcane, Fire, Frost
        [9]  = { 301, 302, 303 },        -- Warlock: Affliction, Demonology, Destruction
        [11] = { 281, 282, 283 },        -- Druid: Balance, Feral, Restoration
    }

    -- Cache: builds talent data from DBC on first use
    local talentCache = nil -- { [tabId] = { sorted list of { talentId, spellRanks[], maxRank } } }

    local function BuildTalentCache()
        if talentCache then return end
        talentCache = {}

        -- Iterate all talents in the DBC
        local count = GetTalentCount and GetTalentCount() or 0
        if count == 0 then
            -- Fallback: query world DB for talent data
            local q = WorldDBQuery("SELECT ID, TabID, TierID, ColumnIndex, SpellRank_1, SpellRank_2, SpellRank_3, SpellRank_4, SpellRank_5 FROM talent_dbc ORDER BY TabID, TierID, ColumnIndex")
            if q then
                repeat
                    local id = q:GetUInt32(0)
                    local tabId = q:GetUInt32(1)
                    local row = q:GetUInt32(2)
                    local col = q:GetUInt32(3)
                    local ranks = {}
                    local maxRank = 0
                    for r = 0, 4 do
                        local spellId = q:GetUInt32(4 + r)
                        ranks[r + 1] = spellId
                        if spellId > 0 then maxRank = r + 1 end
                    end
                    if not talentCache[tabId] then talentCache[tabId] = {} end
                    talentCache[tabId][#talentCache[tabId] + 1] = {
                        talentId = id,
                        row = row,
                        col = col,
                        ranks = ranks,
                        maxRank = maxRank,
                    }
                until not q:NextRow()
            end
        end

        -- Sort each tab by row, then column
        for tabId, talents in pairs(talentCache) do
            table.sort(talents, function(a, b)
                if a.row ~= b.row then return a.row < b.row end
                return a.col < b.col
            end)
        end
    end

    -- Encode a player's current talents into a Wowhead string
    local function EncodeTalents(player)
        BuildTalentCache()

        local classId = player:GetClass()
        local tabs = CLASS_TABS[classId]
        if not tabs then return "" end

        local trees = {}
        for _, tabId in ipairs(tabs) do
            local talents = talentCache[tabId] or {}
            local digits = {}
            for _, t in ipairs(talents) do
                -- Find current rank: check each rank spell from highest to lowest
                local curRank = 0
                for r = t.maxRank, 1, -1 do
                    if t.ranks[r] and t.ranks[r] > 0 and player:HasSpell(t.ranks[r]) then
                        curRank = r
                        break
                    end
                end
                digits[#digits + 1] = tostring(curRank)
            end
            -- Trim trailing zeros
            local str = table.concat(digits)
            str = str:gsub("0+$", "")
            if str == "" then str = "0" end
            trees[#trees + 1] = str
        end
        return table.concat(trees, "-")
    end

    -- Decode a talent string and apply to player (reset + learn)
    local function ApplyTalentString(player, talentStr)
        BuildTalentCache()

        local classId = player:GetClass()
        local tabs = CLASS_TABS[classId]
        if not tabs then
            player:SendBroadcastMessage("Error: Unknown class.")
            return false
        end

        -- Parse the string
        local treeStrs = {}
        for part in talentStr:gmatch("[^-]+") do
            treeStrs[#treeStrs + 1] = part
        end

        -- Count total points needed
        local totalNeeded = 0
        for _, tStr in ipairs(treeStrs) do
            for i = 1, #tStr do
                totalNeeded = totalNeeded + tonumber(tStr:sub(i, i))
            end
        end

        local maxPoints = math.min(math.max(player:GetLevel() - 9, 0), 71)
        if totalNeeded > maxPoints then
            player:SendBroadcastMessage(string.format(
                "|cffff0000Build requires %d points but you only have %d (level %d).|r",
                totalNeeded, maxPoints, player:GetLevel()))
            return false
        end

        -- Reset talents first (free)
        player:ResetTalents(true) -- true = no cost

        -- Apply each talent
        local learned = 0
        for treeIdx, tabId in ipairs(tabs) do
            local tStr = treeStrs[treeIdx] or ""
            local talents = talentCache[tabId] or {}

            for i, t in ipairs(talents) do
                local points = tonumber(tStr:sub(i, i)) or 0
                if points > 0 then
                    -- Learn each rank up to the desired rank
                    for rank = 0, points - 1 do
                        player:LearnTalent(t.talentId, rank)
                    end
                    learned = learned + 1
                end
            end
        end

        player:SendTalentsInfoData(false)
        player:SendBroadcastMessage(string.format(
            "|cff00ff00Talent build applied! %d talents learned (%d points).|r", learned, totalNeeded))
        return true
    end

    -- Apply talent string to an army bot
    local function ApplyTalentStringToBot(player, botName, talentStr)
        BuildTalentCache()

        -- Find the bot
        local botPlayer = nil
        -- Check party members
        local group = player:GetGroup()
        if group then
            for i = 0, group:GetMembersCount() - 1 do
                local member = group:GetMemberGUID(i)
                if member then
                    local p = Map and Map:GetPlayer(member)
                    if p and p:GetName() == botName then
                        botPlayer = p
                        break
                    end
                end
            end
        end

        if not botPlayer then
            -- Try using .army talent reset + learn commands directly
            player:SendBroadcastMessage("|cff00ff00Applying talents via army commands...|r")

            local classId = nil
            -- We need the bot's class — try to find from party
            -- For now, use the player's own class tabs
            -- This works if the bot is the same class
            local tabs = CLASS_TABS[player:GetClass()]
            if not tabs then
                player:SendBroadcastMessage("|cffff0000Cannot determine class tabs.|r")
                return false
            end

            -- Reset bot talents
            player:RunCommand("army talent reset " .. botName)

            -- Parse and learn each talent
            local treeStrs = {}
            for part in talentStr:gmatch("[^-]+") do
                treeStrs[#treeStrs + 1] = part
            end

            local totalLearned = 0
            for treeIdx, tabId in ipairs(tabs) do
                local tStr = treeStrs[treeIdx] or ""
                local talents = talentCache[tabId] or {}

                for i, t in ipairs(talents) do
                    local points = tonumber(tStr:sub(i, i)) or 0
                    if points > 0 then
                        for rank = 1, points do
                            player:RunCommand("army talent learn " .. botName .. " " .. t.talentId)
                        end
                        totalLearned = totalLearned + 1
                    end
                end
            end

            player:SendBroadcastMessage(string.format(
                "|cff00ff00Applied %d talents to %s.|r", totalLearned, botName))
            return true
        end

        player:SendBroadcastMessage("|cffff0000Bot not found in party.|r")
        return false
    end

    -- Register /spec command handler
    local function OnChat(event, player, msg, _, lang)
        if not msg or msg == "" then return end

        local cmd = msg:match("^[/.]spec%s+(.*)")
        if not cmd then return end

        local subCmd = cmd:match("^(%S+)")
        if not subCmd then return end
        subCmd = subCmd:lower()

        if subCmd == "export" then
            local str = EncodeTalents(player)
            player:SendBroadcastMessage("|cffffd100Your talent build:|r " .. str)
            player:SendBroadcastMessage("|cff888888Copy the string above and paste in the Spec Builder to share.|r")
            return false

        elseif subCmd == "import" then
            local talentStr = cmd:match("^import%s+(%S+)")
            if not talentStr or not talentStr:find("-") then
                player:SendBroadcastMessage("|cffff0000Usage: /spec import <talent-string>|r")
                player:SendBroadcastMessage("|cff888888Example: /spec import 302023013-305053000-0|r")
                return false
            end
            ApplyTalentString(player, talentStr)
            return false

        elseif subCmd == "bot" then
            local botName, talentStr = cmd:match("^bot%s+(%S+)%s+(%S+)")
            if not botName or not talentStr or not talentStr:find("-") then
                player:SendBroadcastMessage("|cffff0000Usage: /spec bot <botname> <talent-string>|r")
                return false
            end
            ApplyTalentStringToBot(player, botName, talentStr)
            return false

        elseif subCmd == "help" then
            player:SendBroadcastMessage("|cffffd100=== Spec Builder Commands ===|r")
            player:SendBroadcastMessage("|cff00ff00/spec export|r — Export your current talents as a string")
            player:SendBroadcastMessage("|cff00ff00/spec import <string>|r — Reset & apply a talent build")
            player:SendBroadcastMessage("|cff00ff00/spec bot <name> <string>|r — Apply build to an army bot")
            player:SendBroadcastMessage("|cff888888Talent strings use Wowhead format (digits per talent, trees split by -)|r")
            return false
        end

        return false
    end

    RegisterPlayerEvent(18, OnChat) -- PLAYER_EVENT_ON_CHAT

else
    ---------------------------------------------------------------------------
    -- CLIENT SIDE — No client-side code needed for chat commands
    ---------------------------------------------------------------------------
end

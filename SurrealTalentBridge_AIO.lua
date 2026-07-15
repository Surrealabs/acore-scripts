local AIO = AIO or require("AIO")

if AIO.AddAddon() then
    if not SURREAL_TALENT_TREES then
        pcall(dofile, "lua_scripts/SurrealTalentConfig_AIO.lua")
    end

    local SERVER_DEBUG = false

    local MAX_TALENT_POINTS = 71
    local MIN_TALENT_LEVEL = 10

    local function GetMaxPoints(player)
        local level = player:GetLevel()
        if level < MIN_TALENT_LEVEL then return 0 end
        return math.min(level - MIN_TALENT_LEVEL + 1, MAX_TALENT_POINTS)
    end

    local function LoadPlayerTalents(guid)
        local talents = {}
        local q = CharDBQuery(string.format(
            "SELECT talent_id, `rank` FROM surreal_talents.talent_ranks WHERE guid = %d",
            guid))
        if q then
            repeat
                talents[q:GetUInt32(0)] = q:GetUInt32(1)
            until not q:NextRow()
        end
        return talents
    end

    local function SaveTalentRank(guid, talentId, rank)
        local tId = tonumber(talentId)
        local r = tonumber(rank) or 0
        if not guid or not tId then return end

        if r <= 0 then
            CharDBExecute(string.format(
                "DELETE FROM surreal_talents.talent_ranks WHERE guid = %d AND talent_id = %d",
                guid, tId))
            return
        end

        CharDBExecute(string.format(
            "REPLACE INTO surreal_talents.talent_ranks (guid, talent_id, `rank`) VALUES (%d, %d, %d)",
            guid, tId, r))
    end

    local function GetClassTrees(player)
        if not player then return nil end
        local classId = player:GetClass()
        return SURREAL_TALENT_TREES and SURREAL_TALENT_TREES[classId]
    end

    local function GetTalentDef(player, talentId)
        local classTrees = GetClassTrees(player)
        if not classTrees or not classTrees.tabs then return nil end

        local tId = tonumber(talentId)
        if not tId then return nil end

        for _, tab in ipairs(classTrees.tabs) do
            if tab.talents and tab.talents[tId] then
                return tab.talents[tId]
            end
        end

        return nil
    end

    local function ForEachTalentDef(player, fn)
        if type(fn) ~= "function" then return end
        local classTrees = GetClassTrees(player)
        if not classTrees or not classTrees.tabs then return end

        for _, tab in ipairs(classTrees.tabs) do
            if tab.talents then
                for talentId, talentDef in pairs(tab.talents) do
                    fn(tonumber(talentId), talentDef)
                end
            end
        end
    end

    local function ApplyTalentSpellRank(player, talentDef, rank)
        if not player or type(talentDef) ~= "table" then return end
        if type(talentDef.spells) ~= "table" then return end

        local r = tonumber(rank) or 0
        local desiredSpell = nil
        if r > 0 then
            desiredSpell = tonumber(talentDef.spells[r])
            if desiredSpell and desiredSpell <= 0 then desiredSpell = nil end
        end

        for _, spellId in ipairs(talentDef.spells) do
            local sId = tonumber(spellId)
            if sId and sId > 0 and sId ~= desiredSpell and player:HasSpell(sId) then
                player:RemoveSpell(sId)
            end
        end

        if r <= 0 then return end

        local learnSpell = desiredSpell
        if learnSpell and learnSpell > 0 and not player:HasSpell(learnSpell) then
            player:LearnSpell(learnSpell)
        end
    end

    local function ApplySavedTalentSpells(player, savedTalents)
        if not player or type(savedTalents) ~= "table" then return end
        for talentId, rank in pairs(savedTalents) do
            local tId = tonumber(talentId)
            if tId then
                local talentDef = GetTalentDef(player, tId)
                if talentDef then
                    ApplyTalentSpellRank(player, talentDef, rank)
                end
            end
        end
    end

    local function RemoveAllConfiguredTalentSpells(player)
        if not player then return end
        ForEachTalentDef(player, function(_, talentDef)
            if type(talentDef) == "table" and type(talentDef.spells) == "table" then
                for _, spellId in ipairs(talentDef.spells) do
                    local sId = tonumber(spellId)
                    if sId and sId > 0 and player:HasSpell(sId) then
                        player:RemoveSpell(sId)
                    end
                end
            end
        end)
    end

    local function CountSpentPoints(savedTalents)
        local total = 0
        for _, rank in pairs(savedTalents) do
            total = total + (tonumber(rank) or 0)
        end
        return total
    end

    local function BuildTabInfo(player, savedTalents)
        local classId = player:GetClass()
        local classTrees = SURREAL_TALENT_TREES and SURREAL_TALENT_TREES[classId]
        local tabInfo = {}
        if not classTrees or not classTrees.tabs then
            return tabInfo
        end

        for tabIdx, tab in ipairs(classTrees.tabs) do
            local points = 0
            for talentId, rank in pairs(savedTalents) do
                if tab.talents[talentId] then
                    points = points + (tonumber(rank) or 0)
                end
            end
            tabInfo[tabIdx] = {
                name = tab.name,
                points = points,
            }
        end

        return tabInfo
    end

    local function SendTalentSnapshot(player, target, targetName)
        if not player then return end
        target = target or player
        local guid = target:GetGUIDLow()
        local talents = LoadPlayerTalents(guid)
        local spent = CountSpentPoints(talents)
        local maxPts = GetMaxPoints(target)
        local unspent = maxPts - spent
        if unspent < 0 then unspent = 0 end
        local tabInfo = BuildTabInfo(target, talents)

        AIO.Handle(player, "SurrealTalents", "ReceiveTalents", talents, spent, maxPts, unspent, tabInfo,
                   targetName, target:GetClass())
    end

    local function SendDebug(player, message)
        if not SERVER_DEBUG or not player then return end
        AIO.Handle(player, "SurrealTalents", "Debug", message)
    end

    -- Resolves an optional "editing a bot" target. Only allows targeting a
    -- character on your OWN account that is currently in your party (i.e.
    -- one of your own spawned Army of Alts bots) — never an arbitrary
    -- other player's character. Returns (target, resolvedName); target is
    -- nil if targetName was supplied but couldn't be validated.
    local function ResolveTarget(player, targetName)
        if not targetName or targetName == "" or targetName == player:GetName() then
            return player, nil
        end

        local target = GetPlayerByName(targetName)
        if not target then return nil, targetName end

        if target:GetAccountId() ~= player:GetAccountId() then
            return nil, targetName
        end

        local group = player:GetGroup()
        if not group or not group:IsMember(target:GetGUID()) then
            return nil, targetName
        end

        return target, targetName
    end

    local Handlers = AIO.AddHandlers("SurrealTalents", {})

    function Handlers.RequestTalents(player, targetName)
        SendDebug(player, "RequestTalents")
        local target, resolvedName = ResolveTarget(player, targetName)
        if not target then
            AIO.Handle(player, "SurrealTalents", "ReceiveTalents", {}, 0, 0, 0, {}, targetName, 0)
            return
        end
        SendTalentSnapshot(player, target, resolvedName)
    end

    -- Separate AIO channel for the Army panel's own lightweight read-only
    -- Talents tab preview (can't reuse "SurrealTalents" for registration —
    -- AIO.AddHandlers asserts if a name is registered twice on the same
    -- side, and SurrealTalentFrame_AIO.lua already owns the client-side
    -- "SurrealTalents" handlers).
    local ArmyTalentHandlers = AIO.AddHandlers("SurrealArmyTalents", {})

    -- Used by the Army panel's Talents tab: fetch another live character's
    -- (bot's) custom talent picks, or the master's own if targetName matches.
    function ArmyTalentHandlers.RequestBotTalents(player, targetName)
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
            AIO.Handle(player, "SurrealArmyTalents", "ReceiveBotTalents", targetName, {}, 0, 0, 0, {}, 0)
            return
        end

        local guid = target:GetGUIDLow()
        local talents = LoadPlayerTalents(guid)
        local spent = CountSpentPoints(talents)
        local maxPts = GetMaxPoints(target)
        local unspent = maxPts - spent
        if unspent < 0 then unspent = 0 end
        local tabInfo = BuildTabInfo(target, talents)
        local classId = target:GetClass()

        AIO.Handle(player, "SurrealArmyTalents", "ReceiveBotTalents", targetName,
                   talents, spent, maxPts, unspent, tabInfo, classId)
    end

    function Handlers.LearnTalent(player, talentId, currentRank, targetName)
        if not player then return end
        local target, resolvedName = ResolveTarget(player, targetName)
        if not target then return end

        local guid = target:GetGUIDLow()
        local tId = tonumber(talentId)
        if not tId then return end

        local talentDef = GetTalentDef(target, tId)
        if not talentDef then
            SendDebug(player, string.format("LearnTalent id=%d missing-def", math.floor(tId)))
            return
        end

        local saved = LoadPlayerTalents(guid)
        local before = tonumber(saved[tId]) or 0
        local maxRank = tonumber(talentDef.maxRank) or 0
        if maxRank <= 0 then
            SendDebug(player, string.format("LearnTalent id=%d invalid-maxrank", math.floor(tId)))
            return
        end

        local spent = CountSpentPoints(saved)
        local maxPts = GetMaxPoints(target)
        if spent >= maxPts then
            SendDebug(player, string.format("LearnTalent id=%d blocked-no-points", math.floor(tId)))
            SendTalentSnapshot(player, target, resolvedName)
            return
        end

        local requested = tonumber(currentRank)
        local targetRank
        if requested and requested >= 0 then
            targetRank = math.floor(requested) + 1
        else
            targetRank = before + 1
        end

        if targetRank < 1 then targetRank = 1 end
        if targetRank > maxRank then targetRank = maxRank end
        if targetRank <= before then
            SendDebug(player, string.format("LearnTalent id=%d no-op before=%d target=%d", math.floor(tId), before, targetRank))
            SendTalentSnapshot(player, target, resolvedName)
            return
        end

        SaveTalentRank(guid, tId, targetRank)
        ApplyTalentSpellRank(target, talentDef, targetRank)

        local after = LoadPlayerTalents(guid)[tId] or 0
        SendDebug(player, string.format("LearnTalent id=%d before=%d after=%d", math.floor(tId), before, tonumber(after) or 0))
        SendTalentSnapshot(player, target, resolvedName)
    end

    function Handlers.ApplyPreviewTalents(player, payload, targetName)
        if not player or type(payload) ~= "table" then return end
        local target, resolvedName = ResolveTarget(player, targetName)
        if not target then return end

        local guid = target:GetGUIDLow()
        local saved = LoadPlayerTalents(guid)
        local available = GetMaxPoints(target) - CountSpentPoints(saved)
        if available < 0 then available = 0 end

        local totalApplied = 0
        for talentId, points in pairs(payload) do
            local tId = tonumber(talentId)
            local p = tonumber(points) or 0
            if tId and p > 0 then
                local talentDef = GetTalentDef(target, tId)
                if talentDef then
                    local rank = tonumber(saved[tId]) or 0
                    local maxRank = tonumber(talentDef.maxRank) or 0
                    local toApply = math.floor(p)
                    if toApply > available then
                        toApply = available
                    end

                    local targetRank = rank + toApply
                    if targetRank > maxRank then
                        targetRank = maxRank
                    end

                    local learned = targetRank - rank
                    if learned > 0 then
                        SaveTalentRank(guid, tId, targetRank)
                        ApplyTalentSpellRank(target, talentDef, targetRank)
                        saved[tId] = targetRank
                        totalApplied = totalApplied + learned
                        available = available - learned
                    end
                end
            end
        end

        SendDebug(player, string.format("ApplyPreviewTalents applied=%d", totalApplied))
        SendTalentSnapshot(player, target, resolvedName)
    end

    function Handlers.GetResetCost(player, targetName)
        if not player then return end
        SendDebug(player, "GetResetCost")
        AIO.Handle(player, "SurrealTalents", "ShowResetCost", 0)
    end

    function Handlers.ConfirmReset(player, targetName)
        if not player then return end
        local target, resolvedName = ResolveTarget(player, targetName)
        if not target then return end

        target:ResetTalents(true)
        RemoveAllConfiguredTalentSpells(target)
        CharDBExecute(string.format(
            "DELETE FROM surreal_talents.talent_ranks WHERE guid = %d",
            target:GetGUIDLow()))

        SendDebug(player, "ConfirmReset executed")
        AIO.Handle(player, "SurrealTalents", "ResetDone", 0)
        SendTalentSnapshot(player, target, resolvedName)
    end

end

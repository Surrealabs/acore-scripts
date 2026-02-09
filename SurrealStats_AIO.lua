local AIO = AIO or require("AIO")

if AIO.AddAddon() then
    -- Server side: nothing needed, this is purely client UI
else
    -- Client side: pushed to all players via AIO

-- ============================================================================
-- Tooltip Stat Name Replacements
-- Scans item tooltips and replaces old stat names with new ones
-- ============================================================================
local STAT_REPLACEMENTS = {
	-- Converted stats
	["Defense Rating"]       = "Haste",
	["defense rating"]       = "Haste",
	["Dodge Rating"]         = "Crit",
	["dodge rating"]         = "Crit",
	["Parry Rating"]         = "Mastery",
	["parry rating"]         = "Mastery",
	["Block Rating"]         = "Multistrike",
	["block rating"]         = "Multistrike",
	["Hit Rating"]           = "Versatility",
	["hit rating"]           = "Versatility",

	-- Not yet implemented stats
	["Resilience Rating"]    = "Not Yet Implemented (ID:35 CR:14-16)",
	["resilience rating"]    = "Not Yet Implemented (ID:35 CR:14-16)",
	["Resilience"]           = "Not Yet Implemented (ID:35 CR:14-16)",
	["resilience"]           = "Not Yet Implemented (ID:35 CR:14-16)",
	["Expertise Rating"]     = "Not Yet Implemented (ID:37 CR:23)",
	["expertise rating"]     = "Not Yet Implemented (ID:37 CR:23)",
	["Armor Penetration Rating"] = "Not Yet Implemented (ID:44 CR:24)",
	["armor penetration rating"] = "Not Yet Implemented (ID:44 CR:24)",
	["Crit Rating"]          = "Not Yet Implemented (ID:19-21 CR:8-10)",
	["crit rating"]          = "Not Yet Implemented (ID:19-21 CR:8-10)",
	["Haste Rating"]         = "Not Yet Implemented (ID:28-30 CR:17-19)",
	["haste rating"]         = "Not Yet Implemented (ID:28-30 CR:17-19)",
	["Spell Penetration"]    = "Not Yet Implemented (ID:47)",
	["spell penetration"]    = "Not Yet Implemented (ID:47)",
	["Block Value"]          = "Not Yet Implemented (ID:48)",
	["block value"]          = "Not Yet Implemented (ID:48)",
	["Mana Regeneration"]    = "Not Yet Implemented (ID:43)",
	["mana regeneration"]    = "Not Yet Implemented (ID:43)",
	["Health Regeneration"]  = "Not Yet Implemented (ID:46)",
	["health regeneration"]  = "Not Yet Implemented (ID:46)",
}

local function SurrealStats_ReplaceTooltipLines(tooltip)
	for i = 1, tooltip:NumLines() do
		local left = _G[tooltip:GetName().."TextLeft"..i];
		if left then
			local text = left:GetText();
			if text then
				for old, new in pairs(STAT_REPLACEMENTS) do
					if text:find(old) then
						text = text:gsub(old, new);
						left:SetText(text);
					end
				end
			end
		end
	end
end

GameTooltip:HookScript("OnTooltipSetItem", SurrealStats_ReplaceTooltipLines);
ItemRefTooltip:HookScript("OnTooltipSetItem", SurrealStats_ReplaceTooltipLines);
ShoppingTooltip1:HookScript("OnTooltipSetItem", SurrealStats_ReplaceTooltipLines);
ShoppingTooltip2:HookScript("OnTooltipSetItem", SurrealStats_ReplaceTooltipLines);

-- ============================================================================
-- Override: PaperDollFrame_SetStat
-- Custom primary stat tooltips showing server-side conversions
-- ============================================================================
function PaperDollFrame_SetStat(statFrame, statIndex)
	local label = _G[statFrame:GetName().."Label"];
	local text = _G[statFrame:GetName().."StatText"];
	local stat;
	local effectiveStat;
	local posBuff;
	local negBuff;
	stat, effectiveStat, posBuff, negBuff = UnitStat("player", statIndex);
	local statName = _G["SPELL_STAT"..statIndex.."_NAME"];
	local customTooltip = nil;
	local customName = statName;
	local customTitle = nil;
	if statIndex == 1 then -- Strength
		customName = "Strength"
		customTitle = string.format("Strength: %d", effectiveStat)
		customTooltip = string.format("%d Attack Power", effectiveStat * 2)
	elseif statIndex == 2 then -- Agility
		customName = "Agility"
		customTitle = string.format("Agility: %d", effectiveStat)
		customTooltip = string.format("%d Attack Power", effectiveStat * 2)
	elseif statIndex == 3 then -- Stamina
		customName = "Stamina"
		customTitle = string.format("Stamina: %d", effectiveStat)
		customTooltip = string.format("%d Health", effectiveStat * 10)
	elseif statIndex == 4 then -- Intellect
		customName = "Intellect"
		customTitle = string.format("Intellect: %d", effectiveStat)
		customTooltip = string.format("%d Spell Damage", effectiveStat * 2)
	elseif statIndex == 5 then -- Spirit
		customName = "Spirit"
		customTitle = string.format("Spirit: %d", effectiveStat)
		customTooltip = string.format("%d Spell Healing", effectiveStat * 2)
	end
	label:SetText(format(STAT_FORMAT, customName));
	local tooltipText = HIGHLIGHT_FONT_COLOR_CODE..format(PAPERDOLLFRAME_TOOLTIP_FORMAT, customName).." ";
	if ( ( posBuff == 0 ) and ( negBuff == 0 ) ) then
		text:SetText(effectiveStat);
		statFrame.tooltip = tooltipText..effectiveStat..FONT_COLOR_CODE_CLOSE;
	else
		tooltipText = tooltipText..effectiveStat;
		if ( posBuff > 0 or negBuff < 0 ) then
			tooltipText = tooltipText.." ("..(stat - posBuff - negBuff)..FONT_COLOR_CODE_CLOSE;
		end
		if ( posBuff > 0 ) then
			tooltipText = tooltipText..FONT_COLOR_CODE_CLOSE..GREEN_FONT_COLOR_CODE.."+"..posBuff..FONT_COLOR_CODE_CLOSE;
		end
		if ( negBuff < 0 ) then
			tooltipText = tooltipText..RED_FONT_COLOR_CODE.." "..negBuff..FONT_COLOR_CODE_CLOSE;
		end
		if ( posBuff > 0 or negBuff < 0 ) then
			tooltipText = tooltipText..HIGHLIGHT_FONT_COLOR_CODE..")"..FONT_COLOR_CODE_CLOSE;
		end
		statFrame.tooltip = tooltipText;
		if ( negBuff < 0 ) then
			text:SetText(RED_FONT_COLOR_CODE..effectiveStat..FONT_COLOR_CODE_CLOSE);
		else
			text:SetText(GREEN_FONT_COLOR_CODE..effectiveStat..FONT_COLOR_CODE_CLOSE);
		end
	end
	if customTooltip then
		statFrame.tooltipTitle = customTitle;
		statFrame.tooltip = nil;
		statFrame.tooltip2 = customTooltip;
	else
		statFrame.tooltipTitle = nil;
		statFrame.tooltip2 = _G["DEFAULT_STAT"..statIndex.."_TOOLTIP"];
	end
	statFrame:Show();
end

-- ============================================================================
-- Override: PaperDollFrame_SetRating
-- ============================================================================
function PaperDollFrame_SetRating(statFrame, ratingIndex)
	local label = _G[statFrame:GetName().."Label"];
	local text = _G[statFrame:GetName().."StatText"];
	local rating = GetCombatRating(ratingIndex);
	local customName = nil;
	local customTitle = nil;
	local customTooltip = nil;
	local displayText = nil;

	if ratingIndex == CR_DEFENSE_SKILL then
		customName = "Haste";
		local meleeHaste  = GetCombatRatingBonus(CR_HASTE_MELEE);
		local rangedHaste = GetCombatRatingBonus(CR_HASTE_RANGED);
		local spellHaste  = GetCombatRatingBonus(CR_HASTE_SPELL);
		displayText = string.format("%.1f%%", meleeHaste);
		customTitle = string.format("Haste: %d Rating", rating);
		customTooltip = string.format(
			"%.2f%% Melee Haste\n%.2f%% Ranged Haste\n%.2f%% Spell Haste",
			meleeHaste, rangedHaste, spellHaste
		);

	elseif ratingIndex == CR_DODGE then
		customName = "Crit";
		local meleeCrit  = GetCritChance();
		local rangedCrit = GetRangedCritChance();
		local minSpellCrit = GetSpellCritChance(2);
		for i = 3, MAX_SPELL_SCHOOLS do
			local sc = GetSpellCritChance(i);
			if sc < minSpellCrit then minSpellCrit = sc; end
		end
		local critDmgPct = rating / 5;
		displayText = string.format("%.1f%%", meleeCrit);
		customTitle = string.format("Crit: %d Rating", rating);
		customTooltip = string.format(
			"%.2f%% Melee Crit Chance\n%.2f%% Ranged Crit Chance\n%.2f%% Spell Crit Chance\n+%.1f%% Crit Damage Bonus",
			meleeCrit, rangedCrit, minSpellCrit, critDmgPct
		);

	elseif ratingIndex == CR_PARRY then
		customName = "Mastery";
		local pct = rating / 10;
		displayText = string.format("%.1f%%", pct);
		customTitle = string.format("Mastery: %d Rating", rating);
		customTooltip = string.format("%.1f%% Mastery (class-specific effect)", pct);

	elseif ratingIndex == CR_BLOCK then
		customName = "Multistrike";
		local pct = rating / 10;
		displayText = string.format("%.1f%%", pct);
		customTitle = string.format("Multistrike: %d Rating", rating);
		customTooltip = string.format(
			"%.1f%% chance to recast at 33%% effectiveness",
			pct
		);

	elseif ratingIndex == CR_HIT_MELEE then
		customName = "Versatility";
		local pct = rating / 10;
		local dmgReduction = pct * 0.5;
		displayText = string.format("%.1f%%", pct);
		customTitle = string.format("Versatility: %d Rating", rating);
		customTooltip = string.format(
			"+%.1f%% Damage & Healing\n-%.1f%% Damage Taken",
			pct, dmgReduction
		);
	end

	if customName then
		label:SetText(format(STAT_FORMAT, customName));
		text:SetText(displayText);
		statFrame.tooltipTitle = customTitle;
		statFrame.tooltip = nil;
		statFrame.tooltip2 = customTooltip;
	else
		local statName = _G["COMBAT_RATING_NAME"..ratingIndex] or "Unknown";
		label:SetText(format(STAT_FORMAT, statName));
		text:SetText(rating);
		statFrame.tooltipTitle = nil;
		statFrame.tooltip = HIGHLIGHT_FONT_COLOR_CODE..format(PAPERDOLLFRAME_TOOLTIP_FORMAT, statName).." "..rating..FONT_COLOR_CODE_CLOSE;
		statFrame.tooltip2 = nil;
	end
	statFrame:Show();
end

-- ============================================================================
-- Override: PaperDollStatTooltip
-- ============================================================================
function PaperDollStatTooltip(self, unit)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT");
	if self.tooltipTitle then
		GameTooltip:SetText(self.tooltipTitle, 1.0, 1.0, 1.0);
	else
		local labelObj = _G[self:GetName().."Label"];
		if labelObj and labelObj:GetText() then
			GameTooltip:SetText(labelObj:GetText(), 1.0, 1.0, 1.0);
		else
			GameTooltip:SetText("Stat", 1.0, 1.0, 1.0);
		end
	end
	if self.tooltip then
		GameTooltip:AddLine(self.tooltip, NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g, NORMAL_FONT_COLOR.b, 1);
	end
	if self.tooltip2 then
		GameTooltip:AddLine(self.tooltip2, NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g, NORMAL_FONT_COLOR.b, 1);
	end
	GameTooltip:Show();
end

-- ============================================================================
-- Override: UpdatePaperdollStats
-- ============================================================================
function UpdatePaperdollStats(prefix, index)
	local stat1 = _G[prefix..1];
	local stat2 = _G[prefix..2];
	local stat3 = _G[prefix..3];
	local stat4 = _G[prefix..4];
	local stat5 = _G[prefix..5];
	local stat6 = _G[prefix..6];

	stat1:SetScript("OnEnter", PaperDollStatTooltip);
	stat2:SetScript("OnEnter", PaperDollStatTooltip);
	stat4:SetScript("OnEnter", PaperDollStatTooltip);

	stat6:Show();

	if ( index == "PLAYERSTAT_BASE_STATS" ) then
		PaperDollFrame_SetStat(stat1, 1);
		PaperDollFrame_SetStat(stat2, 2);
		PaperDollFrame_SetStat(stat3, 3);
		PaperDollFrame_SetStat(stat4, 4);
		PaperDollFrame_SetStat(stat5, 5);
		PaperDollFrame_SetArmor(stat6);
	elseif ( index == "PLAYERSTAT_MELEE_COMBAT" ) then
		PaperDollFrame_SetAttackPower(stat1);
		PaperDollFrame_SetRating(stat2, CR_DODGE);
		PaperDollFrame_SetRating(stat3, CR_HIT_MELEE);
		PaperDollFrame_SetRating(stat4, CR_DEFENSE_SKILL);
		PaperDollFrame_SetRating(stat5, CR_BLOCK);
		PaperDollFrame_SetRating(stat6, CR_PARRY);
	elseif ( index == "PLAYERSTAT_RANGED_COMBAT" ) then
		PaperDollFrame_SetRangedAttackPower(stat1);
		PaperDollFrame_SetRating(stat2, CR_DODGE);
		PaperDollFrame_SetRating(stat3, CR_HIT_MELEE);
		PaperDollFrame_SetRating(stat4, CR_DEFENSE_SKILL);
		PaperDollFrame_SetRating(stat5, CR_BLOCK);
		PaperDollFrame_SetRating(stat6, CR_PARRY);
	elseif ( index == "PLAYERSTAT_SPELL_COMBAT" ) then
		local bonusDmg = GetSpellBonusDamage(2);
		for i=3, MAX_SPELL_SCHOOLS do
			local v = GetSpellBonusDamage(i);
			if v > bonusDmg then bonusDmg = v end
		end
		local bonusHeal = GetSpellBonusHealing();
		local spellPower = max(bonusDmg, bonusHeal);
		_G[stat1:GetName().."StatText"]:SetText(spellPower);
		_G[stat1:GetName().."Label"]:SetText(format(STAT_FORMAT, "Spell Power"));
		stat1.tooltipTitle = string.format("Spell Power: %d", spellPower);
		stat1.tooltip = nil;
		stat1.tooltip2 = string.format("%d Spell Damage\n%d Spell Healing", bonusDmg, bonusHeal);
		PaperDollFrame_SetRating(stat2, CR_DODGE);
		PaperDollFrame_SetRating(stat3, CR_HIT_MELEE);
		PaperDollFrame_SetRating(stat4, CR_DEFENSE_SKILL);
		PaperDollFrame_SetRating(stat5, CR_BLOCK);
		PaperDollFrame_SetRating(stat6, CR_PARRY);
	elseif ( index == "PLAYERSTAT_DEFENSES" ) then
		PaperDollFrame_SetStat(stat1, 3);
		PaperDollFrame_SetDodge(stat2);
		PaperDollFrame_SetParry(stat3);
		PaperDollFrame_SetBlock(stat4);
		PaperDollFrame_SetRating(stat5, CR_HIT_MELEE);
		PaperDollFrame_SetArmor(stat6);
	end
end

-- ============================================================================
-- Event-driven stat refresh
-- ============================================================================
local SurrealStatRefresh = CreateFrame("Frame");
SurrealStatRefresh:RegisterEvent("COMBAT_RATING_UPDATE");
SurrealStatRefresh:RegisterEvent("UNIT_STATS");
SurrealStatRefresh:RegisterEvent("UNIT_AURA");
SurrealStatRefresh:RegisterEvent("PLAYER_EQUIPMENT_CHANGED");
SurrealStatRefresh:RegisterEvent("PLAYER_TALENT_UPDATE");
SurrealStatRefresh:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED");
SurrealStatRefresh:RegisterEvent("SPELL_POWER_CHANGED");
SurrealStatRefresh:RegisterEvent("UNIT_ATTACK_POWER");
SurrealStatRefresh:RegisterEvent("UNIT_RANGEDDAMAGE");
SurrealStatRefresh:RegisterEvent("UNIT_DAMAGE");
SurrealStatRefresh:RegisterEvent("UNIT_ATTACK_SPEED");
SurrealStatRefresh:SetScript("OnEvent", function(self, event, unit)
	if unit and unit ~= "player" then return; end
	if CharacterFrame and CharacterFrame:IsShown() and PaperDollFrame_UpdateStats then
		PaperDollFrame_UpdateStats();
	end
end);

DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SurrealUI]|r Stats panel loaded via AIO.")

end -- AIO client block

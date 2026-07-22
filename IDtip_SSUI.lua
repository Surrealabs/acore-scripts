local SSUI = SSUI or require("SSUI")

if SSUI.AddAddon() then
    -- Server side: nothing needed
else
    -- Client side: pushed to all players via SSUI

local hooksecurefunc, select, UnitBuff, UnitDebuff, UnitAura, UnitGUID, GetGlyphSocketInfo, tonumber, strfind =
      hooksecurefunc, select, UnitBuff, UnitDebuff, UnitAura, UnitGUID, GetGlyphSocketInfo, tonumber, strfind

local types = {
	spell		= "SpellID:",
	item		= "ItemID:",
	unit		= "NPC ID:",
	quest		= "QuestID:",
	talent		= "TalentID:",
	achievement	= "AchievementID:",
	criteria	= "CriteriaID:",
	ability		= "AbilityID:",
}

local function addLine(tooltip, id, type, source)
    local found = false
    for i = 1,15 do
        local frame = _G[tooltip:GetName() .. "TextLeft" .. i]
        local text
        if frame then text = frame:GetText() end
        if text and text == type then found = true break end
    end
    if not found then
      if source then
        tooltip:AddDoubleLine(type.." |cffffffff" .. id, source)
      else
        tooltip:AddDoubleLine(type, "|cffffffff" .. id)
      end
        tooltip:Show()
    end
end

local function onSetHyperlink(self, link)
    local type, id = string.match(link,"^(%a+):(%d+)")
    if not type or not id then return end
    if type == "spell" or type == "enchant" or type == "trade" then
        addLine(self, id, types.spell)
    elseif type == "talent" then
        addLine(self, id, types.talent)
    elseif type == "quest" then
        addLine(self, id, types.quest)
    elseif type == "achievement" then
        addLine(self, id, types.achievement)
    elseif type == "item" then
        addLine(self, id, types.item)
    end
end

hooksecurefunc(ItemRefTooltip, "SetHyperlink", onSetHyperlink)
hooksecurefunc(GameTooltip, "SetHyperlink", onSetHyperlink)

-- Spells
hooksecurefunc(GameTooltip, "SetUnitBuff", function(self, ...)
    local caster, _, _, id = select(8, UnitAura(...))
    if caster then
        local name = UnitName(caster)
        if id then addLine(self, id, types.spell, name) end
    else
        if id then addLine(self, id, types.spell) end
    end
end)

hooksecurefunc(GameTooltip, "SetUnitDebuff", function(self,...)
    local caster, _, _, id = select(8, UnitAura(...))
    if caster then
        local name = UnitName(caster)
        if id then addLine(self, id, types.spell, name) end
    else
        if id then addLine(self, id, types.spell) end
    end
end)

hooksecurefunc(GameTooltip, "SetUnitAura", function(self,...)
    local caster, _, _, id = select(8, UnitAura(...))
    if caster then
        local name = UnitName(caster)
        if id then addLine(self, id, types.spell, name) end
    else
        if id then addLine(self, id, types.spell) end
    end
end)

hooksecurefunc("SetItemRef", function(link, ...)
    local id = tonumber(link:match("spell:(%d+)"))
    if id then addLine(ItemRefTooltip, id, types.spell) end
end)

GameTooltip:HookScript("OnTooltipSetSpell", function(self)
    local id = select(3, self:GetSpell())
    if id then addLine(self, id, types.spell) end
end)

-- NPCs
GameTooltip:HookScript("OnTooltipSetUnit", function(self)
    local unit = select(2, self:GetUnit())
    if unit then
        local id = tonumber((UnitGUID(unit)):sub(-10, -7), 16)
        if id > 0 then addLine(GameTooltip, id, types.unit) end
    end
end)

-- Items
local function attachItemTooltip(self)
    local link = select(2, self:GetItem())
    if link then
        local id = string.match(link, "item:(%d*)")
        if id then addLine(self, id, types.item) end
    end
end

GameTooltip:HookScript("OnTooltipSetItem", attachItemTooltip)
ItemRefTooltip:HookScript("OnTooltipSetItem", attachItemTooltip)
ShoppingTooltip1:HookScript("OnTooltipSetItem", attachItemTooltip)
ShoppingTooltip2:HookScript("OnTooltipSetItem", attachItemTooltip)

DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SurrealUI]|r IDtip loaded via SSUI.")

end -- SSUI client block

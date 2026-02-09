local AIO = AIO or require("AIO")

if AIO.AddAddon() then
    -- Server side: nothing needed
else
    -- Client side: pushed to all players via AIO

local function IsDemonologyWarlock()
    local _, class = UnitClass("player")
    if class ~= "WARLOCK" then return false end
    local spec = GetPrimaryTalentTree and GetPrimaryTalentTree() or nil
    return spec == 3
end

local function SurrealPlayerFrame_UpdateManaBar()
    if not IsDemonologyWarlock() then return end
    local manaBar = _G["PlayerFrameManaBar"]
    if manaBar then
        manaBar:SetStatusBarColor(0.6, 0.2, 0.8)
    end
end

local function SurrealPlayerFrame_HookManaBar()
    local manaBar = _G["PlayerFrameManaBar"]
    if manaBar and not manaBar.surrealUIHooked then
        manaBar:HookScript("OnShow", SurrealPlayerFrame_UpdateManaBar)
        manaBar:HookScript("OnValueChanged", SurrealPlayerFrame_UpdateManaBar)
        manaBar.surrealUIHooked = true
    end
end

local surrealPlayerFrame = CreateFrame("Frame")
surrealPlayerFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
surrealPlayerFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
surrealPlayerFrame:RegisterEvent("PLAYER_LOGIN")
surrealPlayerFrame:SetScript("OnEvent", function()
    SurrealPlayerFrame_HookManaBar()
    SurrealPlayerFrame_UpdateManaBar()
end)

DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[SurrealUI]|r PlayerFrame loaded via AIO.")

end -- AIO client block

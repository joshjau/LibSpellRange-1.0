--- LibSpellRange-1.0 - The War Within Advanced Optimization
-- Enhanced with complete 11.0.7 API optimizations
-- @class file
-- @name LibSpellRange-1.0.lua

local major = "SpellRange-1.0"
local minor = 60 -- Final optimized version for 11.0.7

local format = format
assert(LibStub, format("%s requires LibStub.", major))

local Lib = LibStub:NewLibrary(major, minor)
if not Lib then return end

-- Cache frequently used API functions
local UnitExists = UnitExists
local tonumber = tonumber
local type = type
local GetTime = GetTime
local wipe = wipe
local pairs = pairs

-- Modern C_Spell API caching
local C_Spell_IsSpellInRange = C_Spell.IsSpellInRange
local C_Spell_DoesSpellExist = C_Spell.DoesSpellExist
local C_Spell_GetOverrideSpell = C_Spell.GetOverrideSpell
local C_Spell_GetSpellIDForSpellIdentifier = C_Spell.GetSpellIDForSpellIdentifier
local C_Spell_RequestLoadSpellData = C_Spell.RequestLoadSpellData
local C_Spell_IsSpellDataCached = C_Spell.IsSpellDataCached
local C_Spell_GetSpellInfo = C_Spell.GetSpellInfo
local C_Spell_IsSpellUsable = C_Spell.IsSpellUsable
local C_Spell_GetSpellCooldown = C_Spell.GetSpellCooldown
local C_Spell_GetSpellPowerCost = C_Spell.GetSpellPowerCost
local C_Spell_GetSpellCharges = C_Spell.GetSpellCharges
local C_Spell_SpellHasRange = C_Spell.SpellHasRange

-- Optimization caches with structured data
Lib.spellCache = Lib.spellCache or {}
local spellCache = Lib.spellCache

-- Initialize structured data
local function CreateSpellData()
    return {
        lastChecked = 0,
        hasRange = false,
        hasOverride = false,
        overrideID = nil,
        inRangeMask = {}, -- For quick unit checks
        powerType = nil,
        powerCost = 0,
        hasCharges = false,
        maxCharges = 0,
    }
end

-- Enhanced IsSpellInRange with multiple optimizations
function Lib.IsSpellInRange(spellInput, unit)
    -- Early optimization for invalid unit
    if not unit or not UnitExists(unit) then 
        return nil 
    end
    
    local spellID = spellInput
    
    -- Convert string to ID if needed
    if type(spellInput) == "string" then
        spellID = C_Spell_GetSpellIDForSpellIdentifier(spellInput)
    end
    
    -- Ensure we have a valid spell ID
    if not spellID or not tonumber(spellID) then
        if C_Spell_DoesSpellExist(spellInput) then
            -- Direct API call for string inputs
            local result = C_Spell_IsSpellInRange(spellInput, unit)
            return result == true and 1 or result == false and 0 or result
        end
        return nil
    end
    
    -- Initialize and cache spell data
    if not spellCache[spellID] then
        spellCache[spellID] = CreateSpellData()
        C_Spell_RequestLoadSpellData(spellID)
    end
    
    local data = spellCache[spellID]
    local currentTime = GetTime()
    
    -- Check for overrides once per second
    if currentTime - data.lastChecked > 1 then
        data.lastChecked = currentTime
        
        -- Update override status
        if C_Spell_DoesSpellExist(spellID) then
            local overrideID = C_Spell_GetOverrideSpell(spellID)
            if overrideID and overrideID ~= spellID then
                data.hasOverride = true
                data.overrideID = overrideID
                
                -- Initialize override spell data if needed
                if not spellCache[overrideID] then
                    spellCache[overrideID] = CreateSpellData()
                    C_Spell_RequestLoadSpellData(overrideID)
                end
            else
                data.hasOverride = false
                data.overrideID = nil
            end
            
            -- Cache power cost information
            local powerCosts = C_Spell_GetSpellPowerCost(spellID)
            if powerCosts and powerCosts[1] then
                data.powerType = powerCosts[1].type
                data.powerCost = powerCosts[1].cost
            end
            
            -- Cache charge information
            local chargeInfo = C_Spell_GetSpellCharges(spellID)
            if chargeInfo then
                data.hasCharges = true
                data.maxCharges = chargeInfo.maxCharges
            end
        end
    end
    
    -- Use the override spell if available
    local effectiveSpellID = (data.hasOverride and data.overrideID) or spellID
    
    -- Actual range check with effective spell ID
    local result = C_Spell_IsSpellInRange(effectiveSpellID, unit)
    
    -- Store result in the inRangeMask for potential future lookups
    data.inRangeMask[unit] = result
    
    -- Convert to traditional 1/0/nil format for backwards compatibility
    return result == true and 1 or result == false and 0 or result
end

-- Optimized SpellHasRange function
function Lib.SpellHasRange(spellInput)
    local spellID = spellInput
    
    -- Convert string to ID if needed
    if type(spellInput) == "string" then
        spellID = C_Spell_GetSpellIDForSpellIdentifier(spellInput)
    end
    
    -- Check cache first
    if tonumber(spellID) and spellCache[spellID] then
        if spellCache[spellID].hasRange ~= nil then
            return spellCache[spellID].hasRange and 1 or 0
        end
    end
    
    -- Use direct API if available
    if C_Spell_SpellHasRange then
        local hasRange = C_Spell_SpellHasRange(spellID or spellInput)
        
        -- Update cache if we have a valid spell ID
        if tonumber(spellID) then
            if not spellCache[spellID] then
                spellCache[spellID] = CreateSpellData()
            end
            spellCache[spellID].hasRange = hasRange
        end
        
        return hasRange and 1 or 0
    end
    
    -- Fallback to spell info
    local spellInfo = C_Spell_GetSpellInfo(spellID or spellInput)
    if not spellInfo then
        return 0
    end
    
    -- Check the minRange and maxRange values
    local hasRange = (spellInfo.minRange and spellInfo.minRange > 0) or 
                     (spellInfo.maxRange and spellInfo.maxRange > 0)
    
    -- Update cache if we have a valid spell ID
    if tonumber(spellID) then
        if not spellCache[spellID] then
            spellCache[spellID] = CreateSpellData()
        end
        spellCache[spellID].hasRange = hasRange
    end
    
    return hasRange and 1 or 0
end

-- Advanced range optimization for rotation addons - comprehensive spell state
function Lib.GetSpellState(spellID, unit)
    -- Early return for invalid inputs
    if not spellID or not unit then return nil end
    
    -- Initialize result table
    local state = {
        exists = false,
        usable = false,
        inRange = false,
        onCooldown = false,
        cooldownRemaining = 0,
        resourceCost = 0,
        hasCharges = false,
        charges = 0,
        maxCharges = 0,
        chargeCooldownRemaining = 0,
        hasOverride = false,
        overrideID = nil,
    }
    
    -- Check if spell exists
    state.exists = C_Spell_DoesSpellExist(spellID)
    if not state.exists then
        return state
    end
    
    -- Check override
    if spellCache[spellID] and spellCache[spellID].hasOverride then
        state.hasOverride = true
        state.overrideID = spellCache[spellID].overrideID
        -- Use override ID for remaining checks
        if state.overrideID then
            spellID = state.overrideID
        end
    end
    
    -- Get range information if unit exists
    if UnitExists(unit) then
        local inRange = C_Spell_IsSpellInRange(spellID, unit)
        state.inRange = inRange == true
    end
    
    -- Get usability information
    state.usable, state.noResource = C_Spell_IsSpellUsable(spellID)
    
    -- Get cooldown information
    local cooldownInfo = C_Spell_GetSpellCooldown(spellID)
    if cooldownInfo then
        state.onCooldown = cooldownInfo.duration > 0
        if state.onCooldown then
            state.cooldownRemaining = (cooldownInfo.startTime + cooldownInfo.duration) - GetTime()
        end
    end
    
    -- Get charge information
    local chargeInfo = C_Spell_GetSpellCharges(spellID)
    if chargeInfo then
        state.hasCharges = true
        state.charges = chargeInfo.currentCharges
        state.maxCharges = chargeInfo.maxCharges
        if chargeInfo.cooldownStartTime > 0 then
            state.chargeCooldownRemaining = (chargeInfo.cooldownStartTime + 
                                           chargeInfo.cooldownDuration) - GetTime()
        end
    end
    
    -- Get resource cost
    local powerCosts = C_Spell_GetSpellPowerCost(spellID)
    if powerCosts and powerCosts[1] then
        state.resourceCost = powerCosts[1].cost
        state.resourceType = powerCosts[1].type
    end
    
    return state
end

-- Preload spell data for critical rotation spells
function Lib.PreCacheSpells(spellList)
    if not spellList or type(spellList) ~= "table" then return end
    
    for _, spellID in ipairs(spellList) do
        if type(spellID) == "number" then
            -- Force spell data loading
            C_Spell_RequestLoadSpellData(spellID)
            
            -- Initialize cache entry
            if not spellCache[spellID] then
                spellCache[spellID] = CreateSpellData()
            end
            
            -- Setup override detection
            C_Timer.After(0.5, function()
                if C_Spell_DoesSpellExist(spellID) then
                    local overrideID = C_Spell_GetOverrideSpell(spellID)
                    if overrideID and overrideID ~= spellID then
                        if not spellCache[spellID] then
                            spellCache[spellID] = CreateSpellData()
                        end
                        spellCache[spellID].hasOverride = true
                        spellCache[spellID].overrideID = overrideID
                        
                        -- Cache the override spell too
                        C_Spell_RequestLoadSpellData(overrideID)
                        if not spellCache[overrideID] then
                            spellCache[overrideID] = CreateSpellData()
                        end
                    end
                    
                    -- Cache power costs
                    local powerCosts = C_Spell_GetSpellPowerCost(spellID)
                    if powerCosts and powerCosts[1] then
                        spellCache[spellID].powerType = powerCosts[1].type
                        spellCache[spellID].powerCost = powerCosts[1].cost
                    end
                    
                    -- Cache charge information
                    local chargeInfo = C_Spell_GetSpellCharges(spellID)
                    if chargeInfo then
                        spellCache[spellID].hasCharges = true
                        spellCache[spellID].maxCharges = chargeInfo.maxCharges
                    end
                end
            end)
        end
    end
end

-- Clear spell cache for memory optimization
function Lib.ClearCache()
    wipe(spellCache)
end

-- Create event frame if needed
if not Lib.eventFrame then
    Lib.eventFrame = CreateFrame("Frame")
end

-- Register for events
Lib.eventFrame:UnregisterAllEvents()
Lib.eventFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
Lib.eventFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
Lib.eventFrame:RegisterEvent("SPELLS_CHANGED")
Lib.eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
Lib.eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

-- Event handler
Lib.eventFrame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_REGEN_DISABLED" then
        -- Entering combat - preload all cached spells
        for spellID in pairs(spellCache) do
            C_Spell_RequestLoadSpellData(spellID)
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Exiting combat - update all overrides
        for spellID, data in pairs(spellCache) do
            if C_Spell_DoesSpellExist(spellID) then
                local overrideID = C_Spell_GetOverrideSpell(spellID)
                if overrideID and overrideID ~= spellID then
                    data.hasOverride = true
                    data.overrideID = overrideID
                else
                    data.hasOverride = false
                    data.overrideID = nil
                end
            end
            data.lastChecked = 0
        end
    elseif event == "PLAYER_TALENT_UPDATE" or event == "ACTIVE_TALENT_GROUP_CHANGED" or event == "SPELLS_CHANGED" then
        -- Reset override caches on talent/spec changes
        for spellID, data in pairs(spellCache) do
            data.hasOverride = false
            data.overrideID = nil
            data.lastChecked = 0
        end
    end
end)

-- Setup backwards compatibility for older addons
Lib.IsSpellInRangeWithCooldown = function(spellID, unit)
    local state = Lib.GetSpellState(spellID, unit)
    if not state then
        return nil, false, 0, false, false
    end
    return state.inRange and 1 or 0,
           state.onCooldown,
           state.cooldownRemaining,
           state.usable,
           state.noResource
end
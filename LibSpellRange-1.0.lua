--- = Background =
-- Blizzard's IsSpellInRange API has limitations:
-- 1. Requires spell name or spellbook ID
-- 2. Cannot check range directly by spellID
-- 3. Does not work with replacement spells (e.g., talent-modified spells)
--
-- This library provides enhanced spell range checking that:
-- 1. Supports both spell names and spellIDs
-- 2. Handles replacement spells correctly
-- 3. Maintains compatibility with existing addons
--
-- @class file
-- @name LibSpellRange-1.0.lua

local major = "SpellRange-1.0"
local minor = 25

assert(LibStub, format("%s requires LibStub.", major))

local Lib = LibStub:NewLibrary(major, minor)
if not Lib then return end

-- Localize globals
local tonumber = _G.tonumber
local strlower = _G.strlower
local wipe = _G.wipe
local type = _G.type
local select = _G.select
local UnitExists = _G.UnitExists
local GetPetActionInfo = _G.GetPetActionInfo
local UnitIsUnit = _G.UnitIsUnit

-- Localize API functions
local GetSpellBookItemInfo = C_SpellBook.GetSpellBookItemType
local GetSpellBookItemName = C_SpellBook.GetSpellBookItemName
local GetSpellLink = C_Spell.GetSpellLink
local GetSpellName = C_Spell.GetSpellName
local GetSpellIDForSpellIdentifier = C_Spell.GetSpellIDForSpellIdentifier
local GetNumSpellTabs = C_SpellBook.GetNumSpellBookSkillLines
local GetSpellBookSkillLineInfo = C_SpellBook.GetSpellBookSkillLineInfo
local IsSpellBookItemInRange = C_SpellBook.IsSpellBookItemInRange
local SpellHasRange = C_Spell.SpellHasRange
local SpellBookHasRange = C_SpellBook.IsSpellBookItemInRange

-- Constants
local playerBook = Enum.SpellBookSpellBank.Player
local petBook = Enum.SpellBookSpellBank.Pet

-- Helper functions
--- Wraps IsSpellBookItemInRange to normalize return values
-- @param index Spellbook slot index
-- @param spellBank Player or pet spellbook
-- @param unit Target unit
-- @return 1 if in range, 0 if out of range, nil if range check failed
local function IsSpellBookItemInRangeWrapper(index, spellBank, unit)
    local result = IsSpellBookItemInRange(index, spellBank, unit)
    if result == true then
        return 1
    elseif result == false then
        return 0
    end
    return nil
end

--- Extracts spellID from various identifier formats
-- @param identifier Spell name, ID, or link
-- @return spellID if found, nil otherwise
local function GetSpellIDFromIdentifier(identifier)
    if not identifier then return nil end
    if type(identifier) == "number" then return identifier end
    
    -- Try modern API first
    local spellID = GetSpellIDForSpellIdentifier(identifier)
    if spellID then return spellID end
    
    -- Fallback to link parsing
    if type(identifier) == "string" then
        local linkID = tonumber(identifier:gsub("|", "||"):match("spell:(%d+)"))
        if linkID then return linkID end
    end
    
    return nil
end

-- Handles updating spellsByName and spellsByID
if not Lib.updaterFrame then
    Lib.updaterFrame = CreateFrame("Frame")
end
Lib.updaterFrame:UnregisterAllEvents()

-- Performance optimization: Cache for number conversions
-- Uses weak table to allow garbage collection of unused entries
Lib.isNumber = Lib.isNumber or setmetatable({}, {
    __mode = "kv",
    __index = function(t, i)
        local o = tonumber(i) or false
        t[i] = o
        return o
    end
})
local isNumber = Lib.isNumber

-- Performance optimization: Cache for lowercase string conversions
-- Uses weak table to allow garbage collection of unused entries
Lib.strlowerCache = Lib.strlowerCache or setmetatable({}, {
    __index = function(t, i)
        if not i then return nil end
        local o
        if type(i) == "number" then
            o = i
        else
            o = strlower(i)
        end
        t[i] = o
        return o
    end
})
local strlowerCache = Lib.strlowerCache

-- Spell lookup tables
-- Maps spell identifiers to their spellbook slots
-- Uses weak tables for garbage collection
Lib.spellsByName_spell = Lib.spellsByName_spell or {}
local spellsByName_spell = Lib.spellsByName_spell

Lib.spellsByID_spell = Lib.spellsByID_spell or {}
local spellsByID_spell = Lib.spellsByID_spell

Lib.spellsByName_pet = Lib.spellsByName_pet or {}
local spellsByName_pet = Lib.spellsByName_pet

Lib.spellsByID_pet = Lib.spellsByID_pet or {}
local spellsByID_pet = Lib.spellsByID_pet

-- Pet action bar lookup tables
-- Maps pet spell identifiers to their action bar slots
Lib.actionsByName_pet = Lib.actionsByName_pet or {}
local actionsByName_pet = Lib.actionsByName_pet

Lib.actionsById_pet = Lib.actionsById_pet or {}
local actionsById_pet = Lib.actionsById_pet

-- Cache for pet spell range information
-- Records whether a pet spell has ever had a range
-- Uses weak table for garbage collection
-- Not wiped as pet spell ranges are constant
Lib.petSpellHasRange = Lib.petSpellHasRange or setmetatable({}, {
    __mode = "kv"
})
local petSpellHasRange = Lib.petSpellHasRange

--- Retrieves spell tab information with error handling
-- @param index Tab index in spellbook
-- @return name, iconID, offset, numSpells, isGuild, offSpecID, shouldHide, specID
local function GetSpellTabInfo(index)
    local skillLineInfo = GetSpellBookSkillLineInfo(index)
    if skillLineInfo then
        return  skillLineInfo.name,
                skillLineInfo.iconID,
                skillLineInfo.itemIndexOffset,
                skillLineInfo.numSpellBookItems,
                skillLineInfo.isGuild,
                skillLineInfo.offSpecID,
                skillLineInfo.shouldHide,
                skillLineInfo.specID
    end
    return nil
end

if C_Spell.IsSpellInRange then
    -- Modern API (TWW) supports:
    -- 1. Both spell names and IDs
    -- 2. Automatic handling of override spells
    -- 3. Pet spell range checking
    --
    -- Test cases:
    -- 1. Templar's Verdict (base) & Final Verdict (ret pally talent)
    -- 2. Growl (hunter pet)

    local IsSpellInRange = C_Spell.IsSpellInRange

    function Lib.IsSpellInRange(spellInput, unit)
        -- Try modern API first
        local result = IsSpellInRange(spellInput, unit)
        if result ~= nil then
            return result and 1 or 0
        end
        
        -- If modern API fails, try legacy behavior
        if isNumber[spellInput] then
            local spell = spellsByID_spell[spellInput]
            if spell then
                return IsSpellBookItemInRangeWrapper(spell, playerBook, unit)
            else
                local spell = spellsByID_pet[spellInput]
                if spell then
                    local petResult = IsSpellBookItemInRangeWrapper(spell, petBook, unit)
                    if petResult ~= nil then
                        return petResult
                    end
                    
                    -- IsSpellInRange seems to no longer work for pet spellbook,
                    -- so we also try the action bar API.
                    local actionSlot = actionsById_pet[spellInput]
                    if actionSlot and (unit == "target" or UnitIsUnit(unit, "target")) then
                        return select(9, GetPetActionInfo(actionSlot)) and 1 or 0
                    end
                end
            end
        else
            local spellInput = strlowerCache[spellInput]
            if not spellInput then return nil end
            
            local spell = spellsByName_spell[spellInput]
            if spell then
                return IsSpellBookItemInRangeWrapper(spell, playerBook, unit)
            else
                local spell = spellsByName_pet[spellInput]
                if spell then
                    local petResult = IsSpellBookItemInRangeWrapper(spell, petBook, unit)
                    if petResult ~= nil then
                        return petResult
                    end

                    -- IsSpellInRange seems to no longer work for pet spellbook,
                    -- so we also try the action bar API.
                    local actionSlot = actionsByName_pet[spellInput]
                    if actionSlot and (unit == "target" or UnitIsUnit(unit, "target")) then
                        return select(9, GetPetActionInfo(actionSlot)) and 1 or 0
                    end
                end
            end
        end
        return nil
    end

    function Lib.SpellHasRange(spellInput)
        -- Try modern API first
        local result = SpellHasRange(spellInput)
        if result ~= nil then
            return result and 1 or 0
        end
        
        -- If modern API fails, try legacy behavior
        if isNumber[spellInput] then
            local spell = spellsByID_spell[spellInput]
            if spell then
                return SpellBookHasRange(spell, playerBook)
            else
                local spell = spellsByID_pet[spellInput]
                if spell then
                    -- SpellHasRange seems to no longer work for pet spellbook.
                    return SpellBookHasRange(spell, petBook) or petSpellHasRange[spellInput] or false
                end
            end
        else
            local spellInput = strlowerCache[spellInput]
            if not spellInput then return nil end
            
            local spell = spellsByName_spell[spellInput]
            if spell then
                return SpellBookHasRange(spell, playerBook)
            else
                local spell = spellsByName_pet[spellInput]
                if spell then
                    -- SpellHasRange seems to no longer work for pet spellbook.
                    return SpellBookHasRange(spell, petBook) or petSpellHasRange[spellInput] or false
                end
            end
        end
        return nil
    end

    -- Modern API handles all cases including pet spells and overrides, so we can return early
    return
end

--- Updates spellbook lookup tables
-- @param bookType "spell" for player spells, "pet" for pet spells
local function UpdateBook(bookType)
    local book = bookType == "spell" and playerBook or petBook
    local max = 0
    for i = 1, GetNumSpellTabs() do
        local _, _, offs, numspells, _, specId = GetSpellTabInfo(i)
        if specId == 0 then
            max = offs + numspells
        end
    end

    local spellsByName = Lib["spellsByName_" .. bookType]
    local spellsByID = Lib["spellsByID_" .. bookType]
    
    wipe(spellsByName)
    wipe(spellsByID)
    
    for spellBookID = 1, max do
        local type, baseSpellID = GetSpellBookItemInfo(spellBookID, book)
        
        if type == "SPELL" or type == "PETACTION" then
            local currentSpellName, _, currentSpellID = GetSpellBookItemName(spellBookID, book)
            if not currentSpellID then
                local link = GetSpellLink(currentSpellName)
                currentSpellID = GetSpellIDFromIdentifier(link)
            end

            -- Prevent passive spells from overwriting active spells
            -- Example: Ret paladin mastery "Judgement" (fixed in BFA)
            if currentSpellName and not spellsByName[strlower(currentSpellName)] then
                spellsByName[strlower(currentSpellName)] = spellBookID
            end
            if currentSpellID and not spellsByID[currentSpellID] then
                spellsByID[currentSpellID] = spellBookID
            end
            
            if type == "SPELL" then
                -- Handle base spells (only for player spells)
                local baseSpellName = GetSpellName(baseSpellID)
                if baseSpellName and not spellsByName[strlower(baseSpellName)] then
                    spellsByName[strlower(baseSpellName)] = spellBookID
                end
                if baseSpellID and not spellsByID[baseSpellID] then
                    spellsByID[baseSpellID] = spellBookID
                end
            end
        end
    end
end

--- Updates pet action bar lookup tables
-- Handles pet spell range information caching
local function UpdatePetBar()
    wipe(actionsByName_pet)
    wipe(actionsById_pet)
    if not UnitExists("pet") then return end

    for i = 1, NUM_PET_ACTION_SLOTS do
        local name, texture, isToken, isActive, autoCastAllowed, autoCastEnabled, spellID, checksRange, inRange = GetPetActionInfo(i)
        if checksRange then
            actionsByName_pet[strlower(name)] = i
            actionsById_pet[spellID] = i

            -- Cache range information for faster lookups
            petSpellHasRange[strlower(name)] = true
            petSpellHasRange[spellID] = true
        end
    end
end
UpdatePetBar()

Lib.updaterFrame:RegisterEvent("SPELLS_CHANGED")
Lib.updaterFrame:RegisterEvent("PET_BAR_UPDATE")
Lib.updaterFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
Lib.updaterFrame:RegisterEvent("CVAR_UPDATE")

local function UpdateSpells(_, event, arg1)
    if event == "PET_BAR_UPDATE" then
        UpdatePetBar()
    elseif event == "PLAYER_TARGET_CHANGED" then
        -- `checksRange` from GetPetActionInfo() changes based on whether the player has a target or not.
        UpdatePetBar()
    elseif event == "SPELLS_CHANGED" then
        UpdateBook("spell")
        UpdateBook("pet")
    elseif event == "CVAR_UPDATE" and arg1 == "ShowAllSpellRanks" then
        UpdateBook("spell")
        UpdateBook("pet")
    end
end

Lib.updaterFrame:SetScript("OnEvent", UpdateSpells)

--- Improved spell range checking function.
-- @name SpellRange.IsSpellInRange
-- @paramsig spell, unit
-- @param spell Name or spellID of a spell that you wish to check the range of. The spell must be a spell that you have in your spellbook or your pet's spellbook.
-- @param unit UnitID of the spell that you wish to check the range on.
-- @return Exact same returns as http://wowprogramming.com/docs/api/IsSpellInRange
-- @usage
-- -- Check spell range by spell name on unit "target"
-- local SpellRange = LibStub("SpellRange-1.0")
-- local inRange = SpellRange.IsSpellInRange("Stormstrike", "target")
--
-- -- Check spell range by spellID on unit "mouseover"
-- local SpellRange = LibStub("SpellRange-1.0")
-- local inRange = SpellRange.IsSpellInRange(17364, "mouseover")
function Lib.IsSpellInRange(spellInput, unit)
    if not spellInput then return nil end
    if isNumber[spellInput] then
        local spell = spellsByID_spell[spellInput]
        if spell then
            return IsSpellBookItemInRangeWrapper(spell, playerBook, unit)
        else
            local spell = spellsByID_pet[spellInput]
            if spell then
                local petResult = IsSpellBookItemInRangeWrapper(spell, petBook, unit)
                if petResult ~= nil then
                    return petResult
                end
                
                -- IsSpellInRange seems to no longer work for pet spellbook,
                -- so we also try the action bar API.
                local actionSlot = actionsById_pet[spellInput]
                if actionSlot and (unit == "target" or UnitIsUnit(unit, "target")) then
                    return select(9, GetPetActionInfo(actionSlot)) and 1 or 0
                end
            end
        end

        -- if "show all ranks" in spellbook is not ticked and the input was a lower rank of a spell, it won't exist in spellsByID_spell. 
        -- Workaround this issue by testing by name when no result was found using spellbook
        local name = GetSpellName(spellInput)
        if name then
            return IsSpellInRange(name, unit)
        end
    else
        local spellInput = strlowerCache[spellInput]
        if not spellInput then return nil end
        
        local spell = spellsByName_spell[spellInput]
        if spell then
            return IsSpellBookItemInRangeWrapper(spell, playerBook, unit)
        else
            local spell = spellsByName_pet[spellInput]
            if spell then
                local petResult = IsSpellBookItemInRangeWrapper(spell, petBook, unit)
                if petResult ~= nil then
                    return petResult
                end

                -- IsSpellInRange seems to no longer work for pet spellbook,
                -- so we also try the action bar API.
                local actionSlot = actionsByName_pet[spellInput]
                if actionSlot and (unit == "target" or UnitIsUnit(unit, "target")) then
                    return select(9, GetPetActionInfo(actionSlot)) and 1 or 0
                end
            end
        end
        return IsSpellInRange(spellInput, unit)
    end
end

--- Improved SpellHasRange.
-- @name SpellRange.SpellHasRange
-- @paramsig spell
-- @param spell Name or spellID of a spell that you wish to check for a range. The spell must be a spell that you have in your spellbook or your pet's spellbook.
-- @return Exact same returns as http://wowprogramming.com/docs/api/SpellHasRange
-- @usage
-- -- Check if a spell has a range by spell name
-- local SpellRange = LibStub("SpellRange-1.0")
-- local hasRange = SpellRange.SpellHasRange("Stormstrike")
--
-- -- Check if a spell has a range by spellID
-- local SpellRange = LibStub("SpellRange-1.0")
-- local hasRange = SpellRange.SpellHasRange(17364)
function Lib.SpellHasRange(spellInput)
    if not spellInput then return nil end
    if isNumber[spellInput] then
        local spell = spellsByID_spell[spellInput]
        if spell then
            return SpellBookHasRange(spell, playerBook)
        else
            local spell = spellsByID_pet[spellInput]
            if spell then
                -- SpellHasRange seems to no longer work for pet spellbook.
                return SpellBookHasRange(spell, petBook) or petSpellHasRange[spellInput] or false
            end
        end
    
        local name = GetSpellName(spellInput)
        if name then
            return SpellHasRange(name)
        end
    else
        local spellInput = strlowerCache[spellInput]
        if not spellInput then return nil end
        
        local spell = spellsByName_spell[spellInput]
        if spell then
            return SpellBookHasRange(spell, playerBook)
        else
            local spell = spellsByName_pet[spellInput]
            if spell then
                -- SpellHasRange seems to no longer work for pet spellbook.
                return SpellBookHasRange(spell, petBook) or petSpellHasRange[spellInput] or false
            end
        end
        return SpellHasRange(spellInput)
    end
end
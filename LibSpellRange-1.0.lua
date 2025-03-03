--- = Background =
-- Blizzard's IsSpellInRange API has always been very limited - you either must have the name of the spell, or its spell book ID. Checking directly by spellID is simply not possible.
-- Now, in Mists of Pandaria, Blizzard changed the way that many talents and specialization spells work - instead of giving you a new spell when leaned, they replace existing spells. These replacement spells do not work with Blizzard's IsSpellInRange function whatsoever; this limitation is what prompted the creation of this lib.
-- = Usage = 
-- **LibSpellRange-1.0** exposes an enhanced version of IsSpellInRange that:
-- * Allows ranged checking based on both spell name and spellID.
-- * Works correctly with replacement spells that will not work using Blizzard's IsSpellInRange method alone.
--
-- @class file
-- @name LibSpellRange-1.0.lua

local major = "SpellRange-1.0"
local minor = 26

assert(LibStub, format("%s requires LibStub.", major))

local Lib = LibStub:NewLibrary(major, minor)
if not Lib then return end

-- Localize more Lua functions for faster access
local tonumber = _G.tonumber
local strlower = _G.strlower
local wipe = _G.wipe
local type = _G.type
local select = _G.select
local pairs = _G.pairs
local next = _G.next
local format = _G.format
local tinsert = _G.table.insert
local tremove = _G.table.remove
local GetTime = _G.GetTime
local math_max = _G.math.max
local math_min = _G.math.min

-- Cache configuration settings
local THROTTLE_INTERVAL = 0.2  -- Only update every 0.2 seconds
local CACHE_DURATION = 1.5     -- Cache spell range results for 1.5 seconds (optimized for high-end systems)
local HIGH_PRIORITY_UNITS = {
    ["player"] = true,
    ["target"] = true,
    ["focus"] = true,
    ["mouseover"] = true,
    ["arena1"] = true,
    ["arena2"] = true,
    ["arena3"] = true,
    ["arena4"] = true,
    ["arena5"] = true,
    ["boss1"] = true,
    ["boss2"] = true,
    ["boss3"] = true,
    ["boss4"] = true,
    ["boss5"] = true,
    ["party1"] = true,
    ["party2"] = true,
    ["party3"] = true,
    ["party4"] = true,
}

-- Pre-allocate tables for range cache
Lib.rangeCache = Lib.rangeCache or {}
local rangeCache = Lib.rangeCache

Lib.rangeCacheTimestamps = Lib.rangeCacheTimestamps or {}
local rangeCacheTimestamps = Lib.rangeCacheTimestamps

Lib.lastUpdateTime = Lib.lastUpdateTime or 0

-- Add player-specific cache prefix to avoid conflicts when switching characters
Lib.playerCachePrefix = Lib.playerCachePrefix or (UnitGUID("player") and string.sub(UnitGUID("player"), 1, 8) or "")
local playerCachePrefix = Lib.playerCachePrefix

-- Cache performance tracking for high-end systems
Lib.cacheHits = Lib.cacheHits or 0
Lib.cacheMisses = Lib.cacheMisses or 0
Lib.lastCacheCleanupTime = Lib.lastCacheCleanupTime or 0
local CACHE_CLEANUP_INTERVAL = 3.0 -- Less frequent cleanup for high-end systems

-- isNumber is basically a tonumber cache for maximum efficiency
Lib.isNumber = Lib.isNumber or setmetatable({}, {
	__mode = "kv",
	__index = function(t, i)
		local o = tonumber(i) or false
		t[i] = o
		return o
	end})
local isNumber = Lib.isNumber

-- Define IsSpellBookItemInRange for use in both code paths
local IsSpellBookItemInRange = function(index, spellBank, unit)
  local result = C_SpellBook.IsSpellBookItemInRange(index, spellBank, unit)
  if result == true then
    return 1
  elseif result == false then
    return 0
  end
  return nil
end

-- Define SpellBookHasRange function for consistent use in both code paths
local SpellBookHasRange = function(index, spellBank)
  local result = C_SpellBook.SpellHasRange(index, spellBank)
  if result == true then
    return 1
  elseif result == false then
    return 0
  end
  return nil
end

-- Handles updating spellsByName and spellsByID
if not Lib.updaterFrame then
	Lib.updaterFrame = CreateFrame("Frame")
end
Lib.updaterFrame:UnregisterAllEvents()

local UnitGUID = _G.UnitGUID

local playerBook = _G.Enum.SpellBookSpellBank.Player
local petBook = _G.Enum.SpellBookSpellBank.Pet

-- strlower cache for maximum efficiency
Lib.strlowerCache = Lib.strlowerCache or setmetatable(
{}, {
	__index = function(t, i)
		if not i then return end
		local o
		if type(i) == "number" then
			o = i
		else
			o = strlower(i)
		end
		t[i] = o
		return o
	end,
}) local strlowerCache = Lib.strlowerCache

-- Matches lowercase player spell names to their spellBookID
Lib.spellsByName_spell = Lib.spellsByName_spell or {}
local spellsByName_spell = Lib.spellsByName_spell

-- Matches player spellIDs to their spellBookID
Lib.spellsByID_spell = Lib.spellsByID_spell or {}
local spellsByID_spell = Lib.spellsByID_spell

-- Matches lowercase pet spell names to their spellBookID
Lib.spellsByName_pet = Lib.spellsByName_pet or {}
local spellsByName_pet = Lib.spellsByName_pet

-- Matches pet spellIDs to their spellBookID
Lib.spellsByID_pet = Lib.spellsByID_pet or {}
local spellsByID_pet = Lib.spellsByID_pet

-- Matches pet spell names to their pet action bar slot
Lib.actionsByName_pet = Lib.actionsByName_pet or {}
local actionsByName_pet = Lib.actionsByName_pet

-- Matches pet spell IDs to their pet action bar slot
Lib.actionsById_pet = Lib.actionsById_pet or {}
local actionsById_pet = Lib.actionsById_pet

-- Caches whether a pet spell has been observed to ever have had a range.
-- Since this should never change for any particular spell,
-- it is not wiped.
Lib.petSpellHasRange = Lib.petSpellHasRange or {}
local petSpellHasRange = Lib.petSpellHasRange

-- Check for C_Spell.IsSpellInRange which is available in TWW (The War Within)
if C_Spell and C_Spell.IsSpellInRange then
	-- In TWW, IsSpellInRange supports both spell names and IDs
	-- and also automatically handles override spells (i.e. when given a base spell
	-- that has an active override, the range of the override is what's checked - 
	-- no need to pass the input through C_Spell.GetOverrideSpell).
	-- And it once again works with pet spells too!

	-- It remains to be seen if C_Spell.IsSpellInRange will continue to be so well behaved
	-- if/when it is brought to classic and era. May need to change the feature detection used.

	-- Some good spells to test with:
	-- 	Templar's Verdict (base) & Final Verdict (ret pally talent), talent has longer range than base
	--	Growl (hunter pet) - pet spell with range.

	local IsSpellInRange = C_Spell.IsSpellInRange
	local SpellHasRange = C_Spell.SpellHasRange
	
	-- Implement a cache-based function with the same interface
	function Lib.IsSpellInRange(spellInput, unit)
		-- Skip updates for non-essential units when throttling
		local currentTime = GetTime()
		if not HIGH_PRIORITY_UNITS[unit] and (currentTime - Lib.lastUpdateTime) < THROTTLE_INTERVAL then
			return nil -- Return nil for non-priority targets during throttle
		end
		
		-- Create cache key
		local spellType = isNumber[spellInput] and "id:" or "name:"
		local cacheKey = playerCachePrefix .. ":" .. spellType .. spellInput .. ":" .. (unit or "")
		
		-- Check if we have a cached value that's still valid
		if rangeCache[cacheKey] and currentTime - rangeCacheTimestamps[cacheKey] < CACHE_DURATION then
			Lib.cacheHits = Lib.cacheHits + 1
			return rangeCache[cacheKey]
		else
			Lib.cacheMisses = Lib.cacheMisses + 1
		end
		
		-- Calculate the actual result
		local result
		
		if isNumber[spellInput] then
			local spell = spellsByID_spell[spellInput]
			if spell then
				result = IsSpellBookItemInRange(spell, playerBook, unit)
			else
				local spell = spellsByID_pet[spellInput]
				if spell then
					local petResult = IsSpellBookItemInRange(spell, petBook, unit)
					if petResult ~= nil then
						result = petResult
					else
						-- IsSpellInRange seems to no longer work for pet spellbook,
						-- so we also try the action bar API.
						local actionSlot = actionsById_pet[spellInput]
						if actionSlot and (unit == "target" or UnitIsUnit(unit, "target")) then
							result = select(9, GetPetActionInfo(actionSlot)) and 1 or 0
						end
					end
				end
			end

			-- if "show all ranks" in spellbook is not ticked and the input was a lower rank of a spell, it won't exist in spellsByID_spell. 
			-- Workaround this issue by testing by name when no result was found using spellbook
			if result == nil then
				local name = C_Spell.GetSpellName(spellInput)
				if name then
					result = IsSpellInRange(name, unit)
				end
			end
		else
			local spellInput = strlowerCache[spellInput]
			
			local spell = spellsByName_spell[spellInput]
			if spell then
				result = IsSpellBookItemInRange(spell, playerBook, unit)
			else
				local spell = spellsByName_pet[spellInput]
				if spell then
					local petResult = IsSpellBookItemInRange(spell, petBook, unit)
					if petResult ~= nil then
						result = petResult
					else
						-- IsSpellInRange seems to no longer work for pet spellbook,
						-- so we also try the action bar API.
						local actionSlot = actionsByName_pet[spellInput]
						if actionSlot and (unit == "target" or UnitIsUnit(unit, "target")) then
							result = select(9, GetPetActionInfo(actionSlot)) and 1 or 0
						end
					end
				end
			end
			
			if result == nil then
				result = IsSpellInRange(spellInput, unit)
			end
		end
		
		-- Cache the standardized result
		rangeCache[cacheKey] = result and 1 or result == false and 0 or result
		rangeCacheTimestamps[cacheKey] = currentTime
		
		return rangeCache[cacheKey]
	end

	function Lib.SpellHasRange(spellInput)
		-- Create cache key
		local spellType = isNumber[spellInput] and "hasrange_id:" or "hasrange_name:"
		local cacheKey = playerCachePrefix .. ":" .. spellType .. spellInput
		local currentTime = GetTime()
		
		-- Check if we have a cached value that's still valid
		if rangeCache[cacheKey] and currentTime - rangeCacheTimestamps[cacheKey] < CACHE_DURATION then
			return rangeCache[cacheKey]
		end
		
		-- Calculate the actual result
		local result
		
		if isNumber[spellInput] then
			local spell = spellsByID_spell[spellInput]
			if spell then
				result = SpellBookHasRange(spell, playerBook)
			else
				local spell = spellsByID_pet[spellInput]
				if spell then
					-- SpellHasRange seems to no longer work for pet spellbook.
					result = SpellBookHasRange(spell, petBook) or petSpellHasRange[spellInput] or false
				end
			end
	
			if result == nil then
				local name = C_Spell.GetSpellName(spellInput)
				if name then
					result = SpellHasRange(name)
				end
			end
		else
			local spellInput = strlowerCache[spellInput]
			
			local spell = spellsByName_spell[spellInput]
			if spell then
				result = SpellBookHasRange(spell, playerBook)
			else
				local spell = spellsByName_pet[spellInput]
				if spell then
					-- SpellHasRange seems to no longer work for pet spellbook.
					result = SpellBookHasRange(spell, petBook) or petSpellHasRange[spellInput] or false
				end
			end
			
			if result == nil then
				result = SpellHasRange(spellInput)
			end
		end
		
		-- Cache the standardized result
		rangeCache[cacheKey] = result and 1 or result == false and 0 or result
		rangeCacheTimestamps[cacheKey] = currentTime
		
		return rangeCache[cacheKey]
	end
	
	-- Setup a timer to clean old cache entries
	Lib.updaterFrame:SetScript("OnUpdate", function(self, elapsed)
		local currentTime = GetTime()
		if currentTime - Lib.lastUpdateTime > THROTTLE_INTERVAL then
			Lib.lastUpdateTime = currentTime
			
			-- Clean old cache entries (optional garbage collection optimization)
			local entriesRemoved = 0
			for key, timestamp in pairs(rangeCacheTimestamps) do
				if currentTime - timestamp > CACHE_DURATION * 2 then
					rangeCacheTimestamps[key] = nil
					rangeCache[key] = nil
					entriesRemoved = entriesRemoved + 1
					
					-- Stop if we've removed a reasonable number of entries per frame
					if entriesRemoved >= 50 then
						break
					end
				end
			end
		end
	end)

	return
end


-- Localize all API functions to reduce global lookups
local GetSpellBookItemInfo = _G.C_SpellBook.GetSpellBookItemType
local GetSpellBookItemName = _G.C_SpellBook.GetSpellBookItemName
local GetSpellLink = _G.C_Spell.GetSpellLink
local GetSpellName = _G.C_Spell.GetSpellName

-- Update to use C_Spell namespace for these functions
local IsSpellInRange = _G.C_Spell.IsSpellInRange
local SpellHasRange = _G.C_Spell.SpellHasRange
-- Our locally defined function is already set up earlier in the file

local UnitExists = _G.UnitExists
local GetPetActionInfo = _G.GetPetActionInfo
local UnitIsUnit = _G.UnitIsUnit

-- Updates spellsByName and spellsByID

local GetNumSpellTabs = _G.C_SpellBook.GetNumSpellBookSkillLines
local GetSpellTabInfo = function(index)
	local skillLineInfo = C_SpellBook.GetSpellBookSkillLineInfo(index);
	if skillLineInfo then
		return	skillLineInfo.name,
				skillLineInfo.iconID,
				skillLineInfo.itemIndexOffset,
				skillLineInfo.numSpellBookItems,
				skillLineInfo.isGuild,
				skillLineInfo.offSpecID,
				skillLineInfo.shouldHide,
				skillLineInfo.specID;
	end
end

-- Track if updates are pending to avoid redundant processing
Lib.updatesPending = Lib.updatesPending or {
    spell = false,
    pet = false,
    petBar = false
}
local updatesPending = Lib.updatesPending

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
				currentSpellID = tonumber(link and link:gsub("|", "||"):match("spell:(%d+)"))
			end

			-- For each entry we add to a table,
			-- only add it if there isn't anything there already.
			-- This prevents weird passives from overwriting real, legit spells.
			-- For example, in WoW 7.3.5 the ret paladin mastery 
			-- was coming back with a base spell named "Judgement",
			-- which was overwriting the real "Judgement".
			-- Passives usually come last in the spellbook,
			-- so this should work just fine as a workaround.
			-- This issue with "Judgement" is gone in BFA because the mastery changed.
			
			if currentSpellName and not spellsByName[strlower(currentSpellName)] then
				spellsByName[strlower(currentSpellName)] = spellBookID
			end
			if currentSpellID and not spellsByID[currentSpellID] then
				spellsByID[currentSpellID] = spellBookID
			end
			
			if type == "SPELL" then
				-- PETACTION (pet abilities) don't return a spellID for baseSpellID,
				-- so base spells only work for proper player spells.
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
	
	-- Mark update as completed
	updatesPending[bookType] = false
end

local function UpdatePetBar()
	wipe(actionsByName_pet)
	wipe(actionsById_pet)
	if not UnitExists("pet") then 
	    updatesPending.petBar = false
	    return 
	end

	for i = 1, NUM_PET_ACTION_SLOTS do
		local name, _, isToken, isActive, autoCastAllowed, autoCastEnabled, spellID, checksRange, inRange = GetPetActionInfo(i)
		if checksRange then
			actionsByName_pet[strlower(name)] = i
			actionsById_pet[spellID] = i

			petSpellHasRange[strlower(name)] = true
			petSpellHasRange[spellID] = true
		end
	end
	
	-- Mark update as completed
	updatesPending.petBar = false
end

-- Call UpdatePetBar immediately on load
UpdatePetBar()

-- Register relevant events
Lib.updaterFrame:RegisterEvent("SPELLS_CHANGED")
Lib.updaterFrame:RegisterEvent("PET_BAR_UPDATE")
Lib.updaterFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
Lib.updaterFrame:RegisterEvent("CVAR_UPDATE")

-- Event handler for spell book updates
local function UpdateSpells(_, event, arg1)
	if event == "PET_BAR_UPDATE" then
		updatesPending.petBar = true
	elseif event == "PLAYER_TARGET_CHANGED" then
		-- `checksRange` from GetPetActionInfo() changes based on whether the player has a target or not.
		updatesPending.petBar = true
	elseif event == "SPELLS_CHANGED" then
		updatesPending.spell = true
		updatesPending.pet = true
	elseif event == "CVAR_UPDATE" and arg1 == "ShowAllSpellRanks" then
		updatesPending.spell = true
		updatesPending.pet = true
	end
end

-- Set up the OnUpdate script with throttling
Lib.updaterFrame:SetScript("OnEvent", UpdateSpells)
Lib.updaterFrame:SetScript("OnUpdate", function(self, elapsed)
    local currentTime = GetTime()
    
    -- Only update if enough time has passed since the last update
    if currentTime - Lib.lastUpdateTime > THROTTLE_INTERVAL then
        Lib.lastUpdateTime = currentTime
        
        -- Process any pending updates
        if updatesPending.spell then
            UpdateBook("spell")
        end
        
        if updatesPending.pet then
            UpdateBook("pet")
        end
        
        if updatesPending.petBar then
            UpdatePetBar()
        end
        
        -- Clean up cache less frequently for high-end systems
        if currentTime - Lib.lastCacheCleanupTime > CACHE_CLEANUP_INTERVAL then
            Lib.lastCacheCleanupTime = currentTime
            
            -- Clean up cache if needed
            local entriesRemoved = 0
            for key, timestamp in pairs(rangeCacheTimestamps) do
                if currentTime - timestamp > CACHE_DURATION * 2 then
                    rangeCacheTimestamps[key] = nil
                    rangeCache[key] = nil
                    entriesRemoved = entriesRemoved + 1
                    
                    -- Stop if we've removed a reasonable number of entries per frame
                    if entriesRemoved >= 50 then
                        break
                    end
                end
            end
        end
    end
end)


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
	-- Skip updates for non-essential units when throttling
	local currentTime = GetTime()
	if not HIGH_PRIORITY_UNITS[unit] and (currentTime - Lib.lastUpdateTime) < THROTTLE_INTERVAL then
		return nil -- Return nil for non-priority targets during throttle
	end
	
	-- Create cache key
	local spellType = isNumber[spellInput] and "id:" or "name:"
	local cacheKey = playerCachePrefix .. ":" .. spellType .. spellInput .. ":" .. (unit or "")
	
	-- Check if we have a cached value that's still valid
	if rangeCache[cacheKey] and currentTime - rangeCacheTimestamps[cacheKey] < CACHE_DURATION then
		Lib.cacheHits = Lib.cacheHits + 1
		return rangeCache[cacheKey]
	else
		Lib.cacheMisses = Lib.cacheMisses + 1
	end
	
	-- Calculate the actual result
	local result
	
	if isNumber[spellInput] then
		local spell = spellsByID_spell[spellInput]
		if spell then
			result = IsSpellBookItemInRange(spell, playerBook, unit)
		else
			local spell = spellsByID_pet[spellInput]
			if spell then
				local petResult = IsSpellBookItemInRange(spell, petBook, unit)
				if petResult ~= nil then
					result = petResult
				else
					-- IsSpellInRange seems to no longer work for pet spellbook,
					-- so we also try the action bar API.
					local actionSlot = actionsById_pet[spellInput]
					if actionSlot and (unit == "target" or UnitIsUnit(unit, "target")) then
						result = select(9, GetPetActionInfo(actionSlot)) and 1 or 0
					end
				end
			end
		end

		-- if "show all ranks" in spellbook is not ticked and the input was a lower rank of a spell, it won't exist in spellsByID_spell. 
		-- Workaround this issue by testing by name when no result was found using spellbook
		if result == nil then
			local name = C_Spell.GetSpellName(spellInput)
			if name then
				result = IsSpellInRange(name, unit)
			end
		end
	else
		local spellInput = strlowerCache[spellInput]
		
		local spell = spellsByName_spell[spellInput]
		if spell then
			result = IsSpellBookItemInRange(spell, playerBook, unit)
		else
			local spell = spellsByName_pet[spellInput]
			if spell then
				local petResult = IsSpellBookItemInRange(spell, petBook, unit)
				if petResult ~= nil then
					result = petResult
				else
					-- IsSpellInRange seems to no longer work for pet spellbook,
					-- so we also try the action bar API.
					local actionSlot = actionsByName_pet[spellInput]
					if actionSlot and (unit == "target" or UnitIsUnit(unit, "target")) then
						result = select(9, GetPetActionInfo(actionSlot)) and 1 or 0
					end
				end
			end
		end
		
		if result == nil then
			result = IsSpellInRange(spellInput, unit)
		end
	end
	
	-- Cache the standardized result
	rangeCache[cacheKey] = result and 1 or result == false and 0 or result
	rangeCacheTimestamps[cacheKey] = currentTime
	
	return rangeCache[cacheKey]
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
	-- Create cache key
	local spellType = isNumber[spellInput] and "hasrange_id:" or "hasrange_name:"
	local cacheKey = playerCachePrefix .. ":" .. spellType .. spellInput
	local currentTime = GetTime()
	
	-- Check if we have a cached value that's still valid
	if rangeCache[cacheKey] and currentTime - rangeCacheTimestamps[cacheKey] < CACHE_DURATION then
		return rangeCache[cacheKey]
	end
	
	-- Calculate the actual result
	local result
	
	if isNumber[spellInput] then
		local spell = spellsByID_spell[spellInput]
		if spell then
			result = SpellBookHasRange(spell, playerBook)
		else
			local spell = spellsByID_pet[spellInput]
			if spell then
				-- SpellHasRange seems to no longer work for pet spellbook.
				result = SpellBookHasRange(spell, petBook) or petSpellHasRange[spellInput] or false
			end
		end
	
		if result == nil then
			local name = C_Spell.GetSpellName(spellInput)
			if name then
				result = SpellHasRange(name)
			end
		end
	else
		local spellInput = strlowerCache[spellInput]
		
		local spell = spellsByName_spell[spellInput]
		if spell then
			result = SpellBookHasRange(spell, playerBook)
		else
			local spell = spellsByName_pet[spellInput]
			if spell then
				-- SpellHasRange seems to no longer work for pet spellbook.
				result = SpellBookHasRange(spell, petBook) or petSpellHasRange[spellInput] or false
			end
		end
		
		if result == nil then
			result = SpellHasRange(spellInput)
		end
	end
	
	-- Cache the standardized result
	rangeCache[cacheKey] = result and 1 or result == false and 0 or result
	rangeCacheTimestamps[cacheKey] = currentTime
	
	return rangeCache[cacheKey]
end
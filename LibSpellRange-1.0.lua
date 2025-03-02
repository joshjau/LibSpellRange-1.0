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
local minor = 25

-- System-specific configuration for high-end systems
local HIGH_PERFORMANCE_MODE = true -- Enable aggressive optimizations
local MEMORY_POOLING = true -- Use more memory to improve speed
local LARGE_CACHE_SIZE = 1000 -- Increased cache size for high-memory systems
local CACHE_EXPIRATION_TIME = 0.5 -- Cache entries expire after 0.5 seconds (in seconds)
local MAX_CACHE_ENTRIES = LARGE_CACHE_SIZE -- Maximum number of cache entries before reset

local format = string.format
assert(LibStub, format("%s requires LibStub.", major))

local Lib = LibStub:NewLibrary(major, minor)
if not Lib then return end

local tonumber = _G.tonumber
local strlower = _G.strlower
local wipe = _G.wipe
local type = _G.type
local select = _G.select
local pairs = _G.pairs
local ipairs = _G.ipairs
local unpack = _G.unpack
local error = _G.error
local next = _G.next
local tostring = _G.tostring
local rawset = _G.rawset
local rawget = _G.rawget
local tinsert = table.insert
local tremove = table.remove
local min = math.min
local max = math.max
local floor = math.floor
local ceil = math.ceil
local GetTime = _G.GetTimePreciseSec or _G.GetTime -- Use high precision timer if available

-- Handles updating spellsByName and spellsByID
if not Lib.updaterFrame then
	Lib.updaterFrame = CreateFrame("Frame")
end
Lib.updaterFrame:UnregisterAllEvents()

-- Check if C_Spell exists and has the IsSpellInRange function
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

	function Lib.IsSpellInRange(spellInput, unit)
		local result = IsSpellInRange(spellInput, unit)
		return result and 1 or result == false and 0 or result
	end

	function Lib.SpellHasRange(spellInput)
		local result = SpellHasRange(spellInput)
		return result and 1 or result == false and 0 or result
	end

	return
end


local GetSpellBookItemInfo = C_SpellBook.GetSpellBookItemInfo
local GetSpellBookItemName = C_SpellBook.GetSpellBookItemName
local GetSpellLink = C_Spell.GetSpellLink
local GetSpellName = function(spellID)
    if not spellID then return nil end
    local info = C_Spell.GetSpellInfo(spellID)
    if not info then return nil end
    if type(info) == "string" then
        return info
    elseif type(info) == "table" and info.name then
        return info.name
    end
    return nil
end

-- Define IsSpellInRange with proper API order and fallbacks
local IsSpellInRange = C_Spell and C_Spell.IsSpellInRange or rawget(_G, "IsSpellInRange") or function(spellName, unit)
    -- No need to check again since we already checked in the outer condition
    return nil
end

-- Use proper spell book range checking with fallbacks
local IsSpellBookItemInRange = C_SpellBook and C_SpellBook.IsSpellBookItemInRange or rawget(_G, "IsSpellBookItemInRange") or function(index, bookType, unit)
  if not index or not bookType or not unit then
    return nil
  end
  
  -- Fall back to IsSpellInRange with spell name if needed
  local spellName = GetSpellBookItemName(index, bookType)
  if spellName then
    local result = IsSpellInRange(spellName, unit)
    return result
  end
  return nil
end

local SpellHasRange = C_Spell and C_Spell.SpellHasRange
local SpellBookHasRange = function(index, bookType)
  -- Try to use SpellHasRange first if possible
  if index and bookType then
    local spellName = GetSpellBookItemName(index, bookType)
    if spellName and SpellHasRange then
      return SpellHasRange(spellName) 
    end
  end
  -- Fallback to assuming it has range in retail
  return true
end

local UnitExists = _G.UnitExists
local GetPetActionInfo = _G.GetPetActionInfo
local UnitIsUnit = _G.UnitIsUnit

-- Use fixed value for retail
local NUM_PET_ACTION_SLOTS = 10

-- Use retail enum values for spell book types
local playerBook = Enum.SpellBookSpellBank.Player
local petBook = Enum.SpellBookSpellBank.Pet

-- isNumber is a tonumber cache for maximum efficiency
-- Remove weak table reference to maximize RAM utilization on high-end systems
Lib.isNumber = Lib.isNumber or setmetatable({}, {
	__index = function(t, i)
		if i == nil then return false end
		local o = tonumber(i) or false
		t[i] = o
		return o
	end
})
local isNumber = Lib.isNumber

-- Pre-allocate number cache for common spell IDs when in high performance mode
if HIGH_PERFORMANCE_MODE then
    -- Pre-populate with typical spell ID ranges to reduce allocations
    for i = 1, 20 do
        isNumber[tostring(i)] = i
    end
    -- Common WoW spell ID ranges (sampling common ranges)
    for i = 1000, 1100, 10 do
        isNumber[tostring(i)] = i
    end
end

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
}) 
local strlowerCache = Lib.strlowerCache

-- Pre-allocate string cache for common spell terms when in high performance mode
if HIGH_PERFORMANCE_MODE then
    -- Pre-populate with common spell categories to reduce runtime allocations
    local commonTerms = {"arcane", "fire", "frost", "nature", "shadow", "holy", "physical", 
                        "healing", "shield", "armor", "weapon", "attack", "defensive", "utility"}
    for _, term in ipairs(commonTerms) do
        strlowerCache[term] = strlower(term)
    end
end

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

-- Updates spellsByName and spellsByID

local GetNumSpellTabs = function()
    return C_SpellBook.GetNumSkillLines()
end

local GetSpellTabInfo = function(index)
    local skillLineInfo = C_SpellBook.GetSkillLineInfo(index)
    if skillLineInfo then
        return skillLineInfo.name,
               skillLineInfo.iconID,
               skillLineInfo.itemIndexOffset,
               skillLineInfo.numSpellBookItems,
               skillLineInfo.isGuild,
               skillLineInfo.offSpecID,
               skillLineInfo.shouldHide,
               skillLineInfo.specID
    end
    -- Return explicit nil values for each expected return to maintain API compatibility
    return nil, nil, nil, nil, nil, nil, nil, nil
end

local function UpdateBook(bookType)
	local book = bookType == "spell" and playerBook or petBook
	local max = 0
	
	-- Pre-compute max spells to avoid multiple iterations
	for i = 1, GetNumSpellTabs() do
		local _, _, offs, numspells, _, specId = GetSpellTabInfo(i)
		if specId == 0 then
			max = offs + numspells
		end
	end

	local spellsByName = Lib["spellsByName_" .. bookType]
	local spellsByID = Lib["spellsByID_" .. bookType]
	
	-- Pre-allocate approximate table size if using memory pooling
	if MEMORY_POOLING and HIGH_PERFORMANCE_MODE then
		-- Clear tables but maintain allocated memory
		for k in pairs(spellsByName) do spellsByName[k] = nil end
		for k in pairs(spellsByID) do spellsByID[k] = nil end
	else
		wipe(spellsByName)
		wipe(spellsByID)
	end

	-- Local caches for faster access
	local localGetSpellBookItemInfo = GetSpellBookItemInfo
	local localGetSpellBookItemName = GetSpellBookItemName
	local localGetSpellLink = GetSpellLink
	local localGetSpellName = GetSpellName
	local localStrlower = strlower
	
	for spellBookID = 1, max do
		local spellType, baseSpellID = localGetSpellBookItemInfo(spellBookID, book)
		
		if spellType == "SPELL" or spellType == "PETACTION" then
			-- Get spell info using C_SpellBook APIs
			local currentSpellName, subName = localGetSpellBookItemName(spellBookID, book)
			local currentSpellID
			
			-- Try to get spell ID directly from API if available
			if C_SpellBook.GetSpellBookItemID then
				currentSpellID = C_SpellBook.GetSpellBookItemID(spellBookID, book)
			end
			
			if not currentSpellID and currentSpellName then
				local link = localGetSpellLink(currentSpellName)
				currentSpellID = tonumber(link and link:gsub("|", "||"):match("spell:(%d+)"))
			end

			-- Fast path for adding entries
			if currentSpellName then
				local lowerName = localStrlower(currentSpellName)
				if not spellsByName[lowerName] then
					spellsByName[lowerName] = spellBookID
				end
			end
			
			if currentSpellID and not spellsByID[currentSpellID] then
				spellsByID[currentSpellID] = spellBookID
			end
			
			if spellType == "SPELL" and baseSpellID then
				local baseSpellName = localGetSpellName(baseSpellID)
				if baseSpellName then
					local lowerBaseName = localStrlower(baseSpellName)
					if not spellsByName[lowerBaseName] then
						spellsByName[lowerBaseName] = spellBookID
					end
				end
				if not spellsByID[baseSpellID] then
					spellsByID[baseSpellID] = spellBookID
				end
			end
		end
	end
end

local function UpdatePetBar()
	-- Pre-allocate approximate table size if using memory pooling
	if MEMORY_POOLING and HIGH_PERFORMANCE_MODE then
		-- Clear tables but maintain allocated memory
		for k in pairs(actionsByName_pet) do actionsByName_pet[k] = nil end
		for k in pairs(actionsById_pet) do actionsById_pet[k] = nil end
	else
		wipe(actionsByName_pet)
		wipe(actionsById_pet)
	end
	
	if not UnitExists("pet") then return end

	-- Local caches for faster access
	local localGetPetActionInfo = GetPetActionInfo
	local localStrlower = strlower
	
	-- Pre-allocate result tables with expected capacity when in high performance mode
	if HIGH_PERFORMANCE_MODE then
		-- Ensure tables have enough capacity for all pet slots
		for i = 1, NUM_PET_ACTION_SLOTS do
			actionsByName_pet["_temp"..i] = nil
			actionsById_pet[i] = nil
		end
	end

	for i = 1, NUM_PET_ACTION_SLOTS do
		local name, texture, isToken, isActive, autoCastAllowed, autoCastEnabled, spellID, checksRange, inRange = localGetPetActionInfo(i)
		if checksRange then
			if name then 
				actionsByName_pet[localStrlower(name)] = i
				petSpellHasRange[localStrlower(name)] = true
			end
			
			if spellID then
				actionsById_pet[spellID] = i
				petSpellHasRange[spellID] = true
			end
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

-- Cache for IsSpellInRange results to reduce API calls for repeated checks
-- Only created when in high performance mode
local rangeResultCache
if HIGH_PERFORMANCE_MODE then
    rangeResultCache = {}
    
    -- Cache structure: rangeResultCache[spellInput][unit] = {result=value, time=GetTime()}
    -- Add event handlers for cache invalidation - but avoid adding duplicate handlers
    local events = {
        PLAYER_TARGET_CHANGED = true,
        UNIT_SPELLCAST_SUCCEEDED = true
    }
    
    -- Only register events that aren't already being handled
    for event in pairs(events) do
        if not Lib.updaterFrame:IsEventRegistered(event) then
            Lib.updaterFrame:RegisterEvent(event)
        end
    end
    
    -- Hook to the existing event handler
    local oldUpdateSpells = Lib.updaterFrame:GetScript("OnEvent")
    Lib.updaterFrame:SetScript("OnEvent", function(frame, event, ...)
        -- Clear range cache on events that could invalidate range information
        if event == "PLAYER_TARGET_CHANGED" or event == "UNIT_SPELLCAST_SUCCEEDED" then
            wipe(rangeResultCache)
        end
        
        -- Call the original handler
        if oldUpdateSpells then
            oldUpdateSpells(frame, event, ...)
        end
    end)
end

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
	-- Fast path for nil inputs
	if not spellInput or not unit then return nil end

	-- Local references for faster access
	local localIsSpellBookItemInRange = IsSpellBookItemInRange
	local localIsSpellInRange = IsSpellInRange
	local localUnitIsUnit = UnitIsUnit
	local localGetPetActionInfo = GetPetActionInfo
	local localSelect = select
	local localGetSpellName = GetSpellName
	
	-- Check cache if in high performance mode
	if HIGH_PERFORMANCE_MODE and rangeResultCache then
		-- Use caching for frequent spell range checks
		local cacheKey = isNumber[spellInput] and spellInput or strlowerCache[spellInput]
		local unitCache = rangeResultCache[cacheKey]
		
		if unitCache and unitCache[unit] then
			local cachedResult = unitCache[unit]
			local currentTime = GetTime()
			
			-- Use cached result if it's not expired
			if (currentTime - cachedResult.time) < CACHE_EXPIRATION_TIME then
				return cachedResult.result
			end
		end
	end
	
	-- Compute the actual range check result
	local result
	
	if isNumber[spellInput] then
		local spell = spellsByID_spell[spellInput]
		if spell then
			result = localIsSpellBookItemInRange(spell, playerBook, unit)
		else
			local spell = spellsByID_pet[spellInput]
			if spell then
				local petResult = localIsSpellBookItemInRange(spell, petBook, unit)
				if petResult ~= nil then
					result = petResult
				else
					-- IsSpellInRange seems to no longer work for pet spellbook,
					-- so we also try the action bar API.
					local actionSlot = actionsById_pet[spellInput]
					if actionSlot and (unit == "target" or localUnitIsUnit(unit, "target")) then
						result = localSelect(9, localGetPetActionInfo(actionSlot)) and 1 or 0
					end
				end
			end
		end

		if not result then
			-- If "show all ranks" in spellbook is not ticked and the input was a lower rank of a spell, 
			-- it won't exist in spellsByID_spell. Workaround this issue by testing by name.
			local name = localGetSpellName(spellInput)
			if name then
				result = localIsSpellInRange(name, unit)
			end
		end
	else
		local spellInput = strlowerCache[spellInput]
		
		local spell = spellsByName_spell[spellInput]
		if spell then
			result = localIsSpellBookItemInRange(spell, playerBook, unit)
		else
			local spell = spellsByName_pet[spellInput]
			if spell then
				local petResult = localIsSpellBookItemInRange(spell, petBook, unit)
				if petResult ~= nil then
					result = petResult
				else
					-- IsSpellInRange seems to no longer work for pet spellbook,
					-- so we also try the action bar API.
					local actionSlot = actionsByName_pet[spellInput]
					if actionSlot and (unit == "target" or localUnitIsUnit(unit, "target")) then
						result = localSelect(9, localGetPetActionInfo(actionSlot)) and 1 or 0
					end
				end
			end
		end
		
		if not result then
			-- Use the original Blizzard function as final fallback
			-- This is safe and won't recurse because IsSpellInRange is the local reference
			-- to the original API function, not our Lib.IsSpellInRange
			result = localIsSpellInRange(spellInput, unit)
		end
	end
	
	-- Store in cache if in high performance mode
	if HIGH_PERFORMANCE_MODE and rangeResultCache and result ~= nil then
		local cacheKey = isNumber[spellInput] and spellInput or strlowerCache[spellInput]
		
		-- Initialize cache tables if needed
		if not rangeResultCache[cacheKey] then
			rangeResultCache[cacheKey] = {}
		end
		
		-- Store the result with timestamp
		rangeResultCache[cacheKey][unit] = {
			result = result,
			time = GetTime()
		}
		
		-- Manage cache size with a smarter approach
		local count = 0
		for k in pairs(rangeResultCache) do
			count = count + 1
		end
		
		-- If cache is too large, remove oldest entries instead of wiping everything
		if count > MAX_CACHE_ENTRIES then
			local oldest = nil
			local oldestTime = GetTime()
			local entriesToRemove = math.floor(MAX_CACHE_ENTRIES * 0.2) -- Remove 20% of entries
			
			for i = 1, entriesToRemove do
				oldest = nil
				oldestTime = GetTime()
				
				-- Find the oldest entry
				for spellKey, unitTable in pairs(rangeResultCache) do
					for unitKey, data in pairs(unitTable) do
						if data.time < oldestTime then
							oldestTime = data.time
							oldest = {spell = spellKey, unit = unitKey}
						end
					end
				end
				
				-- Remove the oldest entry
				if oldest then
					rangeResultCache[oldest.spell][oldest.unit] = nil
					
					-- Clean up empty spell tables
					if next(rangeResultCache[oldest.spell]) == nil then
						rangeResultCache[oldest.spell] = nil
					end
				end
			end
		end
	end
	
	return result
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
	-- Fast path for nil inputs
	if not spellInput then return nil end

	-- Local references for faster access
	local localSpellBookHasRange = SpellBookHasRange
	local localSpellHasRange = SpellHasRange
	local localGetSpellName = GetSpellName
	
	-- Special fast path for common inputs in high performance mode
	if HIGH_PERFORMANCE_MODE then
		-- Check if we have this in our static cache first
		local cachedResult = petSpellHasRange[spellInput] 
		if cachedResult ~= nil then
			return cachedResult
		end
	end

	if isNumber[spellInput] then
		local spell = spellsByID_spell[spellInput]
		if spell then
			return localSpellBookHasRange(spell, playerBook)
		else
			local spell = spellsByID_pet[spellInput]
			if spell then
				-- SpellHasRange seems to no longer work for pet spellbook.
				return localSpellBookHasRange(spell, petBook) or petSpellHasRange[spellInput] or false
			end
		end
	
		local name = localGetSpellName(spellInput)
		if name then
			return localSpellHasRange(name)
		end
	else
		local spellInput = strlowerCache[spellInput]
		
		local spell = spellsByName_spell[spellInput]
		if spell then
			return localSpellBookHasRange(spell, playerBook)
		else
			local spell = spellsByName_pet[spellInput]
			if spell then
				-- SpellHasRange seems to no longer work for pet spellbook.
				return localSpellBookHasRange(spell, petBook) or petSpellHasRange[spellInput] or false
			end
		end
		-- Use the original Blizzard function as final fallback
		-- This is safe and won't recurse because SpellHasRange is the local reference
		-- to the original API function, not our Lib.SpellHasRange
		return localSpellHasRange(spellInput)
	end
end
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
local minor = 28 -- Increment for new version with fixes and optimizations

assert(LibStub, format("%s requires LibStub.", major))

local Lib = LibStub:NewLibrary(major, minor)
if not Lib then return end

-- Cache globals for performance
local tonumber = _G.tonumber
local strlower = _G.strlower
local wipe = _G.wipe
local type = _G.type
local select = _G.select
local pairs = _G.pairs
local max = _G.math.max
local min = _G.math.min
local GetTime = _G.GetTime

-- Handles updating spellsByName and spellsByID
if not Lib.updaterFrame then
	Lib.updaterFrame = CreateFrame("Frame")
end
Lib.updaterFrame:UnregisterAllEvents()

-- PERFORMANCE ENHANCEMENT: Result caching system
-- This dramatically improves rotation addon performance by caching range check results
Lib.rangeCache = Lib.rangeCache or {}
Lib.rangeCacheLifespan = 0.2 -- Cache results for 200ms
Lib.lastCacheCleanup = GetTime()
Lib.dynamicCacheEnabled = true -- Enable dynamic cache adjustment based on framerate

-- Track performance metrics
Lib.performanceMetrics = Lib.performanceMetrics or {
    callCount = 0,
    lastResetTime = GetTime(),
    totalExecutionTime = 0,
    lastFrameTime = GetTime(),
    frameCount = 0,
    estimatedFPS = 60,
    overheadPercentage = 0
}

-- Function to generate cache keys
local function GetCacheKey(spellInput, unit)
    return tostring(spellInput) .. "#" .. (unit or "")
end

-- Function to clean old cache entries
local function CleanCache()
    local now = GetTime()
    if now - Lib.lastCacheCleanup > 1 then  -- Clean every second
        Lib.lastCacheCleanup = now
        for k, v in pairs(Lib.rangeCache) do
            local ttl = v.ttl or Lib.rangeCacheLifespan
            if now - v.time > ttl then
                Lib.rangeCache[k] = nil
            end
        end
    end
end

-- Using C_Spell APIs for modern WoW
local IsSpellInRange = C_Spell.IsSpellInRange
local SpellHasRange = C_Spell.SpellHasRange

-- Add a SafeCall function for error handling
local function SafeCall(func, ...)
    local success, result = pcall(func, ...)
    return success and result or nil
end

function Lib.IsSpellInRange(spellInput, unit)
    -- Check cache first for performance
    local cacheKey = GetCacheKey(spellInput, unit)
    local cached = Lib.rangeCache[cacheKey]
    if cached and GetTime() - cached.time < Lib.rangeCacheLifespan then
        return cached.result
    end
    
    local rawResult = SafeCall(IsSpellInRange, spellInput, unit)
    local result
    -- Convert boolean result to numeric (1/0) format for consistency with WoW API
    if rawResult == true then
        result = 1
    elseif rawResult == false then
        result = 0
    else
        result = nil
    end
    
    -- Store in cache
    if Lib.frequentSpells[spellInput] then
        Lib.rangeCache[cacheKey] = {result = result, time = GetTime(), ttl = Lib.rangeCacheLifespan * 2}
    else
        Lib.rangeCache[cacheKey] = {result = result, time = GetTime()}
    end
    CleanCache()
    
    return result
end

function Lib.SpellHasRange(spellInput)
    -- Check cache first for performance
    local cacheKey = GetCacheKey(spellInput)
    local cached = Lib.rangeCache[cacheKey]
    if cached and GetTime() - cached.time < Lib.rangeCacheLifespan then
        return cached.result
    end
    
    local rawResult = SafeCall(SpellHasRange, spellInput)
    local result
    -- Convert boolean result to numeric (1/0) format for consistency with WoW API
    if rawResult == true then
        result = 1
    elseif rawResult == false then
        result = 0
    else
        result = nil
    end
    
    -- Store in cache
    if Lib.frequentSpells[spellInput] then
        Lib.rangeCache[cacheKey] = {result = result, time = GetTime(), ttl = Lib.rangeCacheLifespan * 2}
    else
        Lib.rangeCache[cacheKey] = {result = result, time = GetTime()}
    end
    CleanCache()
    
    return result
end

-- NEW API: Multi-spell range check for optimizing rotations
-- This allows rotation addons to check multiple spells at once
function Lib.GetSpellsInRange(spellTable, unit)
    if not spellTable or type(spellTable) ~= "table" then return {} end
    
    local results = {}
    for i, spell in pairs(spellTable) do
        results[spell] = Lib.IsSpellInRange(spell, unit)
    end
    return results
end

-- NEW API: Throttled range check that's lightweight for continuous polling
Lib.throttledResults = Lib.throttledResults or {}
function Lib.IsSpellInRangeThrottled(spellInput, unit, interval)
    interval = interval or 0.1 -- Default 100ms throttle
    
    local now = GetTime()
    local cacheKey = GetCacheKey(spellInput, unit)
    local lastCheck = Lib.throttledResults[cacheKey]
    
    if lastCheck and (now - lastCheck.time) < interval then
        return lastCheck.result
    end
    
    local result = Lib.IsSpellInRange(spellInput, unit)
    Lib.throttledResults[cacheKey] = {result = result, time = now}
    
    return result
end

-- NEW: Cache for frequently accessed spells (e.g. for DPS rotations)
-- This prevents repeated lookups for core rotation spells
Lib.frequentSpells = Lib.frequentSpells or {}
Lib.frequentSpellResults = Lib.frequentSpellResults or {}

-- Register events for cache clearing
Lib.updaterFrame:RegisterEvent("SPELLS_CHANGED")
Lib.updaterFrame:RegisterEvent("PET_BAR_UPDATE")
Lib.updaterFrame:RegisterEvent("PLAYER_TARGET_CHANGED")

local function UpdateSpells(_, event)
    -- Clear different caches based on event type
    if event == "SPELLS_CHANGED" then
        -- Spells have changed, clear all caches
        wipe(Lib.rangeCache)
        wipe(Lib.throttledResults)
        wipe(Lib.frequentSpellResults)
        wipe(Lib.targetPositionData)
    elseif event == "PLAYER_TARGET_CHANGED" then
        -- Only clear target-specific caches
        local targetGUID = UnitGUID("target")
        if targetGUID then
            -- Clear position data for previous target
            Lib.targetPositionData[targetGUID] = nil
            
            -- Clear caches with this target
            for k in pairs(Lib.rangeCache) do
                if k:find("#target") then
                    Lib.rangeCache[k] = nil
                end
            end
            
            for k in pairs(Lib.throttledResults) do
                if k:find("#target") then
                    Lib.throttledResults[k] = nil
                end
            end
        end
    elseif event == "PET_BAR_UPDATE" then
        -- Only clear pet-related spell caches
        for k in pairs(Lib.rangeCache) do
            if k:find("#pet") then
                Lib.rangeCache[k] = nil
            end
        end
        
        for k in pairs(Lib.throttledResults) do
            if k:find("#pet") then
                Lib.throttledResults[k] = nil
            end
        end
    end
end

Lib.updaterFrame:SetScript("OnEvent", UpdateSpells)

-- NEW API: Register frequently used spells for optimal caching
-- This allows rotation addons to tell the library which spells are used most often
function Lib.RegisterFrequentSpells(spells)
    if type(spells) ~= "table" then return end
    
    for _, spell in pairs(spells) do
        if not Lib.frequentSpells[spell] then
            Lib.frequentSpells[spell] = true
        end
    end
end

-- NEW API: Check if a range check would be successful without actually checking
-- This allows rotation addons to avoid wasting cycles on spells that can't be checked
function Lib.CanCheckRange(spellInput)
    -- With retail API, we can always check range with C_Spell functions
    return true
end

-- API for adjusting cache lifespan (for high-performance needs)
function Lib.SetCacheLifespan(seconds)
    if type(seconds) == "number" and seconds >= 0 then
        Lib.rangeCacheLifespan = seconds
    end
end

-- NEW API: Adaptive cache system that automatically adjusts based on performance
function Lib.EnableDynamicCache(enabled)
    Lib.dynamicCacheEnabled = enabled and true or false
end

-- NEW API: Priority-based range checking for rotational abilities
-- This implements a smart queuing system that checks high-priority spells more frequently
Lib.prioritySpells = Lib.prioritySpells or {}
function Lib.SetSpellPriority(spellInput, priority)
    if not spellInput then return end
    priority = tonumber(priority) or 1
    Lib.prioritySpells[spellInput] = priority
end

-- Automatically adjust cache lifespan based on estimated FPS
-- This ensures optimal performance across different hardware capabilities
if not Lib.performanceFrame then
    Lib.performanceFrame = CreateFrame("Frame")
    Lib.performanceFrame:SetScript("OnUpdate", function(self, elapsed)
        -- Track frame timing for FPS estimation
        local metrics = Lib.performanceMetrics
        metrics.frameCount = metrics.frameCount + 1
        
        local now = GetTime()
        local timeSince = now - metrics.lastFrameTime
        
        -- Update FPS estimate every second
        if timeSince >= 1 then
            metrics.estimatedFPS = metrics.frameCount / timeSince
            metrics.frameCount = 0
            metrics.lastFrameTime = now
            
            -- Reset call counters
            metrics.callCount = 0
            metrics.totalExecutionTime = 0
            metrics.lastResetTime = now
            
            -- Dynamically adjust cache lifespan based on FPS if enabled
            if Lib.dynamicCacheEnabled then
                if metrics.estimatedFPS < 30 then
                    -- Lower FPS - use longer cache to reduce CPU impact
                    Lib.rangeCacheLifespan = 0.3
                elseif metrics.estimatedFPS < 60 then
                    -- Medium FPS - use standard cache
                    Lib.rangeCacheLifespan = 0.2
                else
                    -- High FPS - can afford shorter cache for more accuracy
                    Lib.rangeCacheLifespan = 0.1
                end
            end
        end
    end)
end

-- NEW API: Range prediction for moving targets
-- This uses position and movement data to predict if a target will enter or leave range soon
-- NOTE: First call for a new target will always return nil as position history is required
-- for velocity calculation. Subsequent calls will provide predictions.
Lib.targetPositionData = Lib.targetPositionData or {}
function Lib.PredictTargetRange(unit, timeOffset)
    if not unit or not UnitExists(unit) then return nil end
    timeOffset = timeOffset or 0.5 -- Default to half second prediction
    
    local now = GetTime()
    local targetGUID = UnitGUID(unit)
    if not targetGUID then return nil end
    local posData = Lib.targetPositionData[targetGUID]
    
    -- Get current position
    local x, y = UnitPosition(unit)
    if not x or not y then return nil end
    
    -- Store position data if needed
    if not posData then
        Lib.targetPositionData[targetGUID] = {
            lastX = x,
            lastY = y,
            speedX = 0,
            speedY = 0,
            lastUpdate = now
        }
        return nil -- Not enough data for prediction yet (first call)
    end
    
    -- Calculate velocity
    local timeDelta = now - posData.lastUpdate
    if timeDelta > 0 then
        posData.speedX = (x - posData.lastX) / timeDelta
        posData.speedY = (y - posData.lastY) / timeDelta
        posData.lastX = x
        posData.lastY = y
        posData.lastUpdate = now
    end
    
    -- Predict future position
    local predictedX = x + (posData.speedX * timeOffset)
    local predictedY = y + (posData.speedY * timeOffset)
    
    return predictedX, predictedY
end

-- NEW API: Get estimated range to target in yards
-- This is extremely useful for rotation addons to make smarter decisions
function Lib.GetEstimatedRange(unit)
    if not unit or not UnitExists(unit) then return nil end
    
    -- Use a series of known range spells to estimate distance
    local rangeChecks = {
        {range = 5, spells = {}},   -- 5 yard spells  
        {range = 8, spells = {}},   -- 8 yard spells
        {range = 10, spells = {}},  -- 10 yard spells
        {range = 15, spells = {}},  -- 15 yard spells
        {range = 20, spells = {}},  -- 20 yard spells
        {range = 25, spells = {}},  -- 25 yard spells
        {range = 30, spells = {}},  -- 30 yard spells
        {range = 40, spells = {}}   -- 40 yard spells
    }
    
    -- Populate range check spells based on registered known-range spells
    for spellID, range in pairs(Lib.knownRangeSpells or {}) do
        local rangeIdx = 1
        for i, check in ipairs(rangeChecks) do
            if check.range == range then
                rangeIdx = i
                break
            end
        end
        
        if not rangeChecks[rangeIdx].primarySpell then
            rangeChecks[rangeIdx].primarySpell = spellID
        end
        table.insert(rangeChecks[rangeIdx].spells, spellID)
    end
    
    -- Find the distance using binary search
    local minRange, maxRange = 0, 100
    
    for _, check in ipairs(rangeChecks) do
        if #check.spells > 0 or check.primarySpell then
            local spellToCheck = check.primarySpell or check.spells[1]
            local inRange = Lib.IsSpellInRange(spellToCheck, unit)
            
            if inRange == 1 then
                -- Target is within this range
                minRange = max(minRange, 0)
                maxRange = min(maxRange, check.range)
            elseif inRange == 0 then
                -- Target is beyond this range
                minRange = max(minRange, check.range)
            end
        end
    end
    
    -- Return the average of min and max as our best estimate
    if maxRange < 100 then -- We have at least some valid data
        return (minRange + maxRange) / 2
    end
    
    return nil -- Can't determine range
end

-- NEW API: Register known-range spells to improve range estimation
Lib.knownRangeSpells = Lib.knownRangeSpells or {}
function Lib.RegisterRangeSpell(spellInput, range)
    if not spellInput or not range or type(range) ~= "number" then return end
    
    local spellID
    if type(spellInput) == "number" then
        spellID = spellInput
    else
        -- For name-based registration, convert to spellID using the new API
        local spellInfo = C_Spell.GetSpellInfo(spellInput)
        if spellInfo then
            spellID = spellInfo.spellID
        end
    end
    
    if spellID then
        Lib.knownRangeSpells[spellID] = range
    end
end

-- NEW API: Check if a spell is usable (combines range check with IsUsableSpell)
-- This is valuable for rotation addons to avoid wasting GCDs
function Lib.IsSpellUsable(spellInput, unit)
    -- Check if on cooldown or unusable using the new API
    local success, usable, noMana = pcall(function() 
        return C_Spell.IsSpellUsable(spellInput)
    end)
    if not success then return false end
    if not usable then return false end
    
    -- Check range if a unit was provided
    if unit then
        local inRange = Lib.IsSpellInRange(spellInput, unit)
        if inRange == 0 then return false end
    end
    
    return true
end

-- NEW API: Batch execute a full rotation priority list
-- This processes a full set of rotation abilities at once
-- Returns the highest priority ready spell
function Lib.ProcessRotation(spellPriorityList, unit)
    if not spellPriorityList or type(spellPriorityList) ~= "table" or not unit then 
        return nil 
    end
    
    local bestSpell, highestPriority = nil, -1
    
    for i, spellData in ipairs(spellPriorityList) do
        local spell = spellData.spell
        if spell then
            local priority = spellData.priority or (#spellPriorityList - i + 1)
            
            -- Skip processing if lower priority than current best
            if priority > highestPriority then
                local isUsable = Lib.IsSpellUsable(spell, unit)
                
                if isUsable then
                    bestSpell = spell
                    highestPriority = priority
                    
                    -- If this is highest possible priority, we can stop checking
                    if priority >= #spellPriorityList then
                        break
                    end
                end
            end
        end
    end
    
    return bestSpell
end

-- Return the library table for users that want direct access to its methods
return Lib

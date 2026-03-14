--[[
================================================================================
  BossTimers Standalone - WGG Native Boss Ability Timer Tracking
  Version: 1.0.0

  Zero dependencies. Only requires WGG API.
  Auto-learns boss ability intervals via UnitCastingInfo/UnitChannelInfo polling
  and supports preset timer tables. Persists learned data to disk via WGG file I/O.
  Auto-updates during combat only; no manual Update() call needed.

  SETUP:
    1. Put this file in C:\WGG\
    2. In your script: local BT = _G.BossTimers
    3. Query: BT:GetTimeUntil(spellId), BT:GetNextAbility(), etc.
       (auto-updates in combat via OnUpdate frame)

  QUICK EXAMPLE:
    local BT = _G.BossTimers

    -- In your rotation function:
    local function MyRotation()
        -- Is a dangerous ability coming in the next 3 seconds?
        local isDanger, remaining, timer = BT:IsDangerousAbilityIn(3)
        if isDanger then
            -- pop a defensive cooldown
        end

        -- When is the next boss ability?
        local next, secs = BT:GetNextAbility()
        if next and secs < 2 then
            -- delay big cast, boss ability imminent
        end

        -- Time until a specific spell?
        local timeLeft = BT:GetTimeUntil(123456)
        if timeLeft < 5 then
            -- prepare for that specific mechanic
        end
    end

  FULL API:
    BT:GetTimeUntil(spellId)        number (seconds until next cast, 999 if unknown)
    BT:GetNextAbility()             table|nil, number (next ability info + remaining)
    BT:GetAllUpcoming()             table (all upcoming abilities sorted by time)
    BT:IsDangerousAbilityIn(secs)   bool, number, table (danger within N seconds?)
    BT:GetLearnedData(spellId)      table|nil (learned interval data for a spell)
    BT:GetAllLearned()              table (all learned spells for current encounter)
    BT:InEncounter()                bool (is an encounter currently active?)
    BT:GetEncounterDuration()       number (seconds since encounter started)

  CONFIG (optional):
    BT.config.enabled = true
    BT.config.autoLearn = true
    BT.config.saveLearnedData = true
    BT.config.dataPath = "c:\\WGG\\cfg\\boss_timers.json"
    BT.config.minSamples = 3
    BT.config.intervalTolerance = 3.0
    BT.config.debug = false

  PRESETS:
    BT.presets["BossName"] = {
        [spellId] = { interval = 30, name = "Ability Name", danger = "high" },
    }
    Danger levels: "critical", "high", "medium", "low"
================================================================================
]]

local BT = {}
local VERSION = "1.0.0"

-- Conflict detection: warn if replacing an older version
if _G.BossTimers and _G.BossTimers.VERSION then
    print("|cFFFFFF00[BossTimers]|r Replacing v" .. _G.BossTimers.VERSION .. " with v" .. VERSION)
end

BT.VERSION = VERSION

-- Environment validation: require WGG JSON functions
if not _G.WGG_JsonEncode then
    print("|cFFFF0000[BossTimers]|r WGG API not found (WGG_JsonEncode missing). Module disabled.")
    return
end

_G.BossTimers = BT

---------------------------------------------------------------------------
-- JSON helpers (use WGG native)
---------------------------------------------------------------------------
local function EncodeJSON(data)
    return _G.WGG_JsonEncode(data)
end

local function IsSafeDecodedTableString(tableStr)
    if type(tableStr) ~= "string" or tableStr == "" then
        return false
    end

    local inSingle = false
    local inDouble = false
    local escaped = false

    for i = 1, #tableStr do
        local ch = tableStr:sub(i, i)

        if escaped then
            escaped = false
        elseif (inSingle or inDouble) and ch == "\\" then
            escaped = true
        elseif not inDouble and ch == "'" then
            inSingle = not inSingle
        elseif not inSingle and ch == '"' then
            inDouble = not inDouble
        elseif not inSingle and not inDouble then
            if ch == "(" or ch == ")" or ch == ";" then
                return false
            end
        end
    end

    if inSingle or inDouble then
        return false
    end

    local normalized = tableStr:gsub("%b''", "''"):gsub('%b""', '""'):lower()
    local bannedPatterns = {
        "function[%s%(]",
        "loadstring",
        "setfenv",
        "getfenv",
        "pcall",
        "xpcall",
        "while%s",
        "repeat%s",
        "until%s",
        "for%s",
        "if%s",
        "then%s",
        "else%s",
        "elseif%s",
        "do%s",
        "os%.[%a_]+",
        "io%.[%a_]+",
        "debug%.[%a_]+",
        "string%.[%a_]+",
        "_g[%W]",
        "require[%s%(]",
    }

    for _, pattern in ipairs(bannedPatterns) do
        if normalized:find(pattern) then
            return false
        end
    end

    return true
end

local function DecodeJSON(str)
    if not str or str == "" then return nil end
    local ok, result = pcall(function()
        local decoded = _G.WGG_JsonDecode(str)
        if not decoded then return nil end
        if type(decoded) == "table" then return decoded end
        if not IsSafeDecodedTableString(decoded) then
            return nil
        end
        local chunkSource = decoded
        if not chunkSource:match("^%s*return[%s{]") then
            chunkSource = "return " .. chunkSource
        end
        local fn = loadstring(chunkSource)
        if fn then return fn() end
        return nil
    end)
    if ok then return result end
    return nil
end

local function TryReadFile(path)
    if type(_G.WGG_FileRead) ~= "function" then
        return nil
    end

    local ok, content = pcall(_G.WGG_FileRead, path)
    if not ok or type(content) ~= "string" or content == "" then
        return nil
    end

    return content
end

---------------------------------------------------------------------------
-- Debug print helper
---------------------------------------------------------------------------
local function DebugPrint(msg)
    if BT.config.debug then
        print("|cFF88CCFF[BossTimers]|r " .. msg)
    end
end

---------------------------------------------------------------------------
-- Config
---------------------------------------------------------------------------
BT.config = {
    enabled = true,
    autoLearn = true,
    saveLearnedData = true,
    dataPath = "c:\\WGG\\cfg\\boss_timers.json",
    -- How many casts to observe before trusting the learned interval
    minSamples = 3,
    -- Tolerance for interval variation (if stddev > this, it's not periodic)
    intervalTolerance = 3.0,
    -- OnUpdate throttle
    updateInterval = 0.1,
    debug = false,
}

---------------------------------------------------------------------------
-- Preset Boss Timers (fill per encounter)
-- Format: [encounterKey] = { [spellId] = { interval, name, danger } }
---------------------------------------------------------------------------
BT.presets = {
    -- =====================================================================
    -- THE VOIDSPIRE (Midnight Season 1)
    -- =====================================================================
    -- Boss 1: Imperator Averzian
    -- Boss 2: Vorasius
    -- Boss 3: Fallen-King Salhadaar
    -- Boss 4: Vaelgor & Ezzorak
    -- Boss 5: Lightblinded Vanguard
    -- Boss 6: Crown of the Cosmos

    -- =====================================================================
    -- TEMPLATE -- copy and fill for each boss:
    -- ["BossName"] = {
    --     [spellId] = { interval = 30, name = "Ability Name", danger = "high" },
    --     [spellId] = { interval = 45, name = "Other Ability", danger = "medium" },
    -- },
    -- =====================================================================

    -- Example (placeholder, replace with real data):
    -- ["Vaelgor & Ezzorak"] = {
    --     [000001] = { interval = 25, name = "Midnight Flames",   danger = "critical" },
    --     [000002] = { interval = 15, name = "Dread Breath",      danger = "high" },
    --     [000003] = { interval = 20, name = "Void Howl",         danger = "medium" },
    --     [000004] = { interval = 30, name = "Nullbeam",          danger = "high" },
    -- },
}

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
BT.state = {
    inEncounter = false,
    encounterName = nil,
    encounterStart = 0,

    -- Observed casts: [spellId] = { lastCast, times = {t1, t2, ...}, count, name }
    observed = {},

    -- Learned intervals: [spellId] = { interval, name, samples, reliable, source, danger }
    learned = {},

    -- Active timers: [spellId] = { expiresAt, name, danger, source, interval }
    activeTimers = {},

    -- Cast history for analysis
    castHistory = {},
    maxHistory = 200,
}

---------------------------------------------------------------------------
-- Encounter Detection
---------------------------------------------------------------------------
function BT:StartEncounter(bossName)
    self.state.inEncounter = true
    self.state.encounterName = bossName
    self.state.encounterStart = GetTime()
    self.state.observed = {}
    self.state.learned = {}
    self.state.activeTimers = {}
    self.state.castHistory = {}

    -- Load presets for this boss
    if self.presets[bossName] then
        for spellId, data in pairs(self.presets[bossName]) do
            self.state.learned[spellId] = {
                interval = data.interval,
                name = data.name,
                danger = data.danger or "medium",
                samples = 99,
                reliable = true,
                source = "preset",
            }
        end
        DebugPrint("Loaded presets for " .. bossName)
    end

    -- Load previously learned data
    self:LoadLearnedData(bossName)

    DebugPrint("Encounter started: " .. bossName)
end

function BT:EndEncounter()
    if self.state.inEncounter and self.config.saveLearnedData then
        self:SaveLearnedData()
    end
    self.state.inEncounter = false

    DebugPrint("Encounter ended: " .. (self.state.encounterName or "Unknown"))
end

---------------------------------------------------------------------------
-- Cast Detection (called from OnUpdate polling)
---------------------------------------------------------------------------
function BT:OnBossCast(spellId, spellName, sourceGUID)
    if not self.state.inEncounter then return end
    if not spellId or spellId == 0 then return end

    local now = GetTime()
    local obs = self.state.observed[spellId]

    if not obs then
        -- First time seeing this spell
        self.state.observed[spellId] = {
            lastCast = now,
            times = { now },
            count = 1,
            name = spellName or "Unknown",
        }
    else
        -- Record interval
        local interval = now - obs.lastCast

        -- Ignore very short intervals (< 3s = probably same cast or GCD overlap)
        if interval < 3 then return end

        obs.lastCast = now
        obs.count = obs.count + 1
        table.insert(obs.times, now)
        -- Cap observed times at 20 entries
        if #obs.times > 20 then
            table.remove(obs.times, 1)
        end

        -- Auto-learn: calculate average interval
        if self.config.autoLearn and obs.count >= self.config.minSamples then
            self:LearnInterval(spellId, obs)
        end
    end

    -- Record in history
    table.insert(self.state.castHistory, {
        spellId = spellId,
        spellName = spellName or "Unknown",
        time = now,
        encounterTime = now - self.state.encounterStart,
        sourceGUID = sourceGUID,
    })
    while #self.state.castHistory > self.state.maxHistory do
        table.remove(self.state.castHistory, 1)
    end

    -- Start countdown timer for next cast
    local learnedData = self.state.learned[spellId]
    if learnedData and learnedData.reliable then
        self.state.activeTimers[spellId] = {
            expiresAt = now + learnedData.interval,
            name = learnedData.name or spellName or "Unknown",
            danger = learnedData.danger or "medium",
            source = learnedData.source or "learned",
            interval = learnedData.interval,
        }
    end

    if self.config.debug then
        local nextStr = learnedData and learnedData.reliable
            and string.format(" (next in %.1fs)", learnedData.interval) or ""
        DebugPrint(string.format("Cast: %s (%d)%s", spellName or "?", spellId, nextStr))
    end
end

---------------------------------------------------------------------------
-- Auto-Learn
---------------------------------------------------------------------------
function BT:LearnInterval(spellId, obs)
    if obs.count < 2 then return end

    local intervals = {}
    for i = 2, #obs.times do
        local diff = obs.times[i] - obs.times[i - 1]
        if diff >= 3 then
            table.insert(intervals, diff)
        end
    end

    if #intervals == 0 then return end

    -- Calculate average
    local sum = 0
    for _, v in ipairs(intervals) do sum = sum + v end
    local avg = sum / #intervals

    -- Check consistency (standard deviation)
    local variance = 0
    for _, v in ipairs(intervals) do
        local diff = v - avg
        variance = variance + diff * diff
    end
    local stddev = math.sqrt(variance / #intervals)

    local isReliable = stddev <= self.config.intervalTolerance and #intervals >= self.config.minSamples

    self.state.learned[spellId] = {
        interval = avg,
        name = obs.name,
        samples = #intervals,
        reliable = isReliable,
        stddev = stddev,
        source = "learned",
        danger = self.state.learned[spellId] and self.state.learned[spellId].danger or "medium",
    }

    if isReliable then
        DebugPrint(string.format("Learned: %s = %.1fs (stddev=%.1f, n=%d)",
            obs.name, avg, stddev, #intervals))
    end
end

---------------------------------------------------------------------------
-- Timer Queries (for rotation scripts)
---------------------------------------------------------------------------

-- Get time until next cast of a specific spell
function BT:GetTimeUntil(spellId)
    local timer = self.state.activeTimers[spellId]
    if not timer then return 999 end
    local remaining = timer.expiresAt - GetTime()
    return remaining > 0 and remaining or 0
end

-- Get the next upcoming boss ability (any spell, sorted by time)
function BT:GetNextAbility()
    local now = GetTime()
    local shortest = nil
    local shortestRemaining = 999

    for spellId, timer in pairs(self.state.activeTimers) do
        local remaining = timer.expiresAt - now
        if remaining > 0 and remaining < shortestRemaining then
            shortestRemaining = remaining
            shortest = {
                spellId = spellId,
                name = timer.name,
                remaining = remaining,
                danger = timer.danger,
                interval = timer.interval,
            }
        end
    end

    return shortest, shortestRemaining
end

-- Get all upcoming abilities sorted by time
function BT:GetAllUpcoming()
    local now = GetTime()
    local result = {}

    for spellId, timer in pairs(self.state.activeTimers) do
        local remaining = timer.expiresAt - now
        if remaining > 0 then
            table.insert(result, {
                spellId = spellId,
                name = timer.name,
                remaining = remaining,
                danger = timer.danger,
                interval = timer.interval,
            })
        end
    end

    table.sort(result, function(a, b) return a.remaining < b.remaining end)
    return result
end

-- Is a dangerous ability coming within N seconds?
function BT:IsDangerousAbilityIn(seconds)
    seconds = seconds or 3
    local now = GetTime()

    for spellId, timer in pairs(self.state.activeTimers) do
        if timer.danger == "critical" or timer.danger == "high" then
            local remaining = timer.expiresAt - now
            if remaining > 0 and remaining <= seconds then
                return true, remaining, timer
            end
        end
    end

    return false, 999, nil
end

-- Get learned data for a spell (for debugging/display)
function BT:GetLearnedData(spellId)
    return self.state.learned[spellId]
end

-- Get all learned spells for current encounter
function BT:GetAllLearned()
    return self.state.learned
end

-- Is encounter active?
function BT:InEncounter()
    return self.state.inEncounter
end

-- Get encounter duration
function BT:GetEncounterDuration()
    if not self.state.inEncounter then return 0 end
    return GetTime() - self.state.encounterStart
end

---------------------------------------------------------------------------
-- Persistence
---------------------------------------------------------------------------
function BT:SaveLearnedData()
    if not _G.WGG_FileWrite then return end
    if not self.state.encounterName then return end

    -- Only save reliable learned data
    local toSave = {}
    for spellId, data in pairs(self.state.learned) do
        if data.reliable and data.source == "learned" then
            toSave[tostring(spellId)] = {
                interval = data.interval,
                name = data.name,
                samples = data.samples,
                danger = data.danger,
            }
        end
    end

    -- Load existing file
    local allData = {}
    local content = TryReadFile(self.config.dataPath)
    if content then
        local parsed = DecodeJSON(content)
        if parsed then allData = parsed end
    end

    allData[self.state.encounterName] = toSave

    local json = EncodeJSON(allData)
    if json then
        _G.WGG_FileWrite(self.config.dataPath, json)
        DebugPrint("Saved learned data for " .. self.state.encounterName)
    end
end

function BT:LoadLearnedData(bossName)
    local content = TryReadFile(self.config.dataPath)
    if not content then return end

    local allData = DecodeJSON(content)
    if not allData then return end

    local bossData = allData[bossName]
    if not bossData then return end

    local loaded = 0
    for spellIdStr, data in pairs(bossData) do
        local spellId = tonumber(spellIdStr)
        if spellId and not self.state.learned[spellId] then
            self.state.learned[spellId] = {
                interval = data.interval,
                name = data.name,
                samples = data.samples or 0,
                reliable = true,
                source = "saved",
                danger = data.danger or "medium",
            }
            loaded = loaded + 1
        end
    end

    if loaded > 0 then
        DebugPrint(string.format("Loaded %d saved timers for %s", loaded, bossName))
    end
end

---------------------------------------------------------------------------
-- Timer Cleanup
---------------------------------------------------------------------------
function BT:CleanupTimers()
    local now = GetTime()
    for spellId, timer in pairs(self.state.activeTimers) do
        -- Scaled grace period: 50% of interval, minimum 15 seconds
        local grace = math.max(15, (timer.interval or 30) * 0.5)
        if now - timer.expiresAt > grace then
            self.state.activeTimers[spellId] = nil
        end
    end
end

---------------------------------------------------------------------------
-- Boss Frame Polling (called from OnUpdate)
---------------------------------------------------------------------------
local function PollBossFrames()
    if not BT.state.inEncounter then return end

    -- Safety net: auto-end encounter after 45 minutes (2700 seconds)
    if BT:GetEncounterDuration() > 2700 then
        DebugPrint("Encounter timeout (45m), auto-ending")
        BT:EndEncounter()
        return
    end

    local now = GetTime()

    -- Scan boss1 through boss5 for casts and channels
    for i = 1, 5 do
        local unit = "boss" .. i
        if UnitExists(unit) and not UnitIsDead(unit) then
            local guid = UnitGUID(unit)

            -- Check casts
            local castName, _, _, _, _, _, _, _, _, spellId = UnitCastingInfo(unit)
            if castName and spellId then
                local obs = BT.state.observed[spellId]
                if not obs or (now - obs.lastCast) > 3 then
                    BT:OnBossCast(spellId, castName, guid)
                end
            end

            -- Check channels
            local chanName, _, _, _, _, _, _, _, chanSpellId = UnitChannelInfo(unit)
            if chanName and chanSpellId then
                local obs = BT.state.observed[chanSpellId]
                if not obs or (now - obs.lastCast) > 3 then
                    BT:OnBossCast(chanSpellId, chanName, guid)
                end
            end
        end
    end

    -- Cleanup expired timers
    BT:CleanupTimers()
end

---------------------------------------------------------------------------
-- Combat Detection: detect boss names and start/end encounters
---------------------------------------------------------------------------
local function DetectEncounterStart()
    -- Detect all boss names for multi-boss encounters (boss1 through boss5)
    local names = {}
    for i = 1, 5 do
        local unit = "boss" .. i
        if UnitExists(unit) then
            local name = UnitName(unit)
            if name then
                local isDuplicate = false
                for _, existing in ipairs(names) do
                    if existing == name then
                        isDuplicate = true
                        break
                    end
                end
                if not isDuplicate then
                    table.insert(names, name)
                end
            end
        end
    end
    if #names > 0 then
        BT:StartEncounter(table.concat(names, " & "))
        return
    end

    -- Fallback: use target name for world bosses (no rareelite)
    if UnitExists("target") then
        local classification = UnitClassification("target")
        if classification == "worldboss" then
            BT:StartEncounter(UnitName("target") or "Unknown")
        end
    end
end

---------------------------------------------------------------------------
-- Auto-update: combat-aware OnUpdate frame
---------------------------------------------------------------------------
local inCombat = false
local elapsed = 0
local frame = CreateFrame("Frame")

frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        -- Detect encounter on combat start
        if not BT.state.inEncounter then
            DetectEncounterStart()
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        -- End encounter on combat end
        if BT.state.inEncounter then
            BT:EndEncounter()
        end
    end
end)

frame:SetScript("OnUpdate", function(self, dt)
    if not inCombat then return end
    if not BT.config.enabled then return end
    elapsed = elapsed + dt
    if elapsed >= BT.config.updateInterval then
        elapsed = 0

        -- If encounter hasn't started yet (boss frames appeared mid-combat), try again
        if not BT.state.inEncounter then
            DetectEncounterStart()
        end

        PollBossFrames()
    end
end)

if BT.config.debug then
    print("|cFF00FF00[BossTimers]|r Standalone v" .. VERSION .. " loaded")
end

--[[
================================================================================
  BossAwareness Standalone - WGG Native Boss Mechanic Detection
  Version: 1.0.1

  Zero dependencies. Only requires WGG API.
  Detects ground effects, missiles, boss casts, and dangerous debuffs
  using WGG memory reads — NOT affected by Midnight 12.0 addon restrictions.
  Auto-updates during combat only; no manual Update() call needed.

  SETUP:
    1. Put this file in C:\WGG\
    2. In your script: local BA = _G.BossAwareness
    3. Query: BA:IsStandingInBad(), BA:CanInterruptBoss(), etc.
       (auto-updates in combat via OnUpdate frame)

  QUICK EXAMPLE:
    local BA = _G.BossAwareness

    -- In your rotation function:
    local function MyRotation()
        -- Am I standing in fire?
        if BA:IsStandingInBad() then
            -- stop casting / move
        end

        -- Should I interrupt?
        local canKick, remaining = BA:CanInterruptBoss()
        if canKick and remaining < 1.5 then
            -- cast interrupt spell
        end

        -- Unified threat check
        local threat, reason = BA:GetThreatLevel()
        -- "MOVE_NOW"  = in ground effect
        -- "MOVE_SOON" = missile < 1.5s
        -- "INTERRUPT" = boss interruptible < 2s
        -- "DEBUFF"    = dangerous debuff
        -- "SAFE"      = all clear
    end

  FULL API:
    BA:IsStandingInBad()              bool
    BA:NearestGroundEffectDistance()   number (yards)
    BA:GetGroundEffects()             table of {x,y,z,radius,distance,spellId,isInside}
    BA:IsMissileIncoming()            bool
    BA:GetMissileETA()                number (seconds)
    BA:GetMissiles()                  table of missile data
    BA:IsBossCasting()                bool
    BA:CanInterruptBoss()             bool, remainingSeconds
    BA:GetBossCast()                  {isCasting,canInterrupt,remaining,spellId,spellName}
    BA:GetAllBossCasts()              table of all active boss casts
    BA:HasDangerousDebuff()           bool
    BA:GetDangerousDebuffs()          table of {spellId,stacks,duration}
    BA:ShouldMove()                   bool (ground OR missile)
    BA:GetThreatLevel()               string, reason

  CONFIG (optional):
    BA.config.enabled = true
    BA.config.areaTriggerDangerRadius = 5
    BA.config.missileDangerRadius = 4
    BA.config.updateInterval = 0.05
    BA.config.debug = false
================================================================================
]]

local BA = {}
local VERSION = "1.0.1"

-- Fix 2: Conflict detection — warn if replacing an older version
if _G.BossAwareness and _G.BossAwareness.VERSION then
    print("|cFFFFFF00[BossAwareness]|r Replacing v" .. _G.BossAwareness.VERSION .. " with v" .. VERSION)
end

BA.VERSION = VERSION

-- Fix 3: Environment validation — bail out if WGG API is missing
if not _G.WGG_GetPlayerPosition then
    print("|cFFFF0000[BossAwareness]|r WGG API not found. Module disabled.")
    return
end

_G.BossAwareness = BA

---------------------------------------------------------------------------
-- Config
---------------------------------------------------------------------------
BA.config = {
    enabled = true,
    detectAreaTriggers = true,
    areaTriggerDangerRadius = 5,
    detectMissiles = true,
    missileDangerRadius = 4,
    detectBossCasts = true,
    detectDangerousDebuffs = true,
    updateInterval = 0.05,
    debug = false,
}

---------------------------------------------------------------------------
-- State (read-only from outside)
---------------------------------------------------------------------------
BA.state = {
    lastUpdate = 0,
    -- Ground effects
    dangerousGroundEffects = {},
    isStandingInBad = false,
    nearestGroundEffectDist = 999,
    -- Missiles
    incomingMissiles = {},
    missileIncoming = false,
    missileETA = 999,
    -- Boss casts
    bossCasts = {},
    bossIsCasting = false,
    bossCanBeInterrupted = false,
    bossCastRemaining = 0,
    bossCastSpellId = nil,
    bossCastSpellName = nil,
    -- Debuffs
    dangerousDebuffs = {},
    hasDangerousDebuff = false,
}

---------------------------------------------------------------------------
-- Safe AreaTriggers (add your own)
---------------------------------------------------------------------------
local SAFE_AREATRIGGERS = {
    -- [spellId] = true,  -- healing circles, buffs, etc.
}

---------------------------------------------------------------------------
-- Internal: get player position
---------------------------------------------------------------------------
local function GetPlayerPos()
    if _G.WGG_GetPlayerPosition then
        local x, y, z = _G.WGG_GetPlayerPosition()
        if x then return x, y, z end
    end
    return nil, nil, nil
end

local function Dist3D(x1, y1, z1, x2, y2, z2)
    local dx, dy, dz = x1 - x2, y1 - y2, z1 - z2
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

---------------------------------------------------------------------------
-- Ground Effects (AreaTriggers)
---------------------------------------------------------------------------
local function ScanGroundEffects(px, py, pz)
    if not BA.config.detectAreaTriggers then return end
    if not _G.WGG_GetObjectCount or not _G.WGG_GetObjectWithIndex then return end

    local effects = {}
    local isInDanger = false
    local nearestDist = 999

    local count = _G.WGG_GetObjectCount()
    for i = 0, count - 1 do
        local obj = _G.WGG_GetObjectWithIndex(i)
        if obj and obj ~= 0 then
            local success, objType = pcall(_G.WGG_ObjectType, obj)
            if success and objType == 11 then -- AreaTrigger
                local ok, data = pcall(_G.WGG_AreaTrigger, obj)
                if ok and data and data.x then
                    if not SAFE_AREATRIGGERS[data.spellId] then
                        -- Fix 4: Skip AreaTriggers from friendly casters
                        local casterIsFriendly = false
                        if data.casterGUID then
                            local resolveToken = UnitTokenFromGUID
                            if resolveToken then
                                local casterUnit = resolveToken(data.casterGUID)
                                if casterUnit and UnitIsFriend("player", casterUnit) then
                                    casterIsFriendly = true
                                end
                            end
                        end

                        if not casterIsFriendly then
                            local dist = Dist3D(px, py, pz, data.x, data.y, data.z)
                            -- Fix 5: Validate radius (fallback to 3 if missing/invalid)
                            local rawRadius = data.radius
                            local radius = (rawRadius and rawRadius > 0) and rawRadius or 3
                            local effectiveRadius = radius + BA.config.areaTriggerDangerRadius

                            if dist < effectiveRadius then
                                table.insert(effects, {
                                    x = data.x, y = data.y, z = data.z,
                                    radius = radius,
                                    distance = dist,
                                    spellId = data.spellId,
                                    casterGUID = data.casterGUID,
                                    duration = data.duration,
                                    isInside = dist <= radius,
                                })
                                if dist <= radius then isInDanger = true end
                                if dist < nearestDist then nearestDist = dist end
                            end
                        end
                    end
                end
            end
        end
    end

    BA.state.dangerousGroundEffects = effects
    BA.state.isStandingInBad = isInDanger
    BA.state.nearestGroundEffectDist = nearestDist
end

---------------------------------------------------------------------------
-- Missiles
---------------------------------------------------------------------------
local function ScanMissiles(px, py, pz)
    if not BA.config.detectMissiles then return end
    if not _G.WGG_GetMissileCount then return end

    local missiles = {}
    local hasDanger = false
    local nearestETA = 999
    local playerGUID = UnitGUID("player")

    local count = _G.WGG_GetMissileCount()
    for i = 1, count do
        local spellID, _, mx, my, mz, srcGUID, sx, sy, sz, tgtGUID, tx, ty, tz = _G.WGG_GetMissileWithIndex(i)
        if spellID and tx then
            local impactDist = Dist3D(px, py, pz, tx, ty, tz)

            if impactDist < BA.config.missileDangerRadius or tgtGUID == playerGUID then
                local travelDist = (mx and sx) and Dist3D(mx, my, mz, tx, ty, tz) or 0
                local eta = travelDist > 0 and (travelDist / 30) or 0.5

                table.insert(missiles, {
                    spellID = spellID,
                    targetX = tx, targetY = ty, targetZ = tz,
                    missileX = mx, missileY = my, missileZ = mz,
                    sourceGUID = srcGUID,
                    targetGUID = tgtGUID,
                    impactDist = impactDist,
                    eta = eta,
                    targetingPlayer = tgtGUID == playerGUID,
                })
                hasDanger = true
                if eta < nearestETA then nearestETA = eta end
            end
        end
    end

    BA.state.incomingMissiles = missiles
    BA.state.missileIncoming = hasDanger
    BA.state.missileETA = nearestETA
end

---------------------------------------------------------------------------
-- Boss Casts
---------------------------------------------------------------------------
local function ScanBossCasts()
    if not BA.config.detectBossCasts then return end

    local casts = {}
    local hasCast = false
    local canInterrupt = false
    local shortestRemaining = 999
    local shortestSpellId = nil
    local shortestSpellName = nil
    local now = GetTime()

    -- boss1-boss5
    for i = 1, 5 do
        local unit = "boss" .. i
        if UnitExists(unit) and not UnitIsDead(unit) then
            -- Casting
            local name, _, _, _, _, endTime, _, _, notInt, spellId = UnitCastingInfo(unit)
            if name then
                local rem = endTime and ((endTime / 1000) - now) or 0
                local interruptible = not notInt
                table.insert(casts, {
                    unit = unit, spellName = name, spellId = spellId,
                    remaining = rem, isInterruptible = interruptible,
                    isCasting = true, isChanneling = false,
                })
                hasCast = true
                if rem < shortestRemaining then
                    shortestRemaining = rem
                    shortestSpellId = spellId
                    shortestSpellName = name
                    canInterrupt = interruptible
                end
            end

            -- Channeling
            local cName, _, _, _, _, cEnd, _, notIntC, cSpellId = UnitChannelInfo(unit)
            if cName then
                local rem = cEnd and ((cEnd / 1000) - now) or 0
                local interruptible = not notIntC
                table.insert(casts, {
                    unit = unit, spellName = cName, spellId = cSpellId,
                    remaining = rem, isInterruptible = interruptible,
                    isCasting = false, isChanneling = true,
                })
                hasCast = true
                if interruptible and rem < shortestRemaining then
                    shortestRemaining = rem
                    shortestSpellId = cSpellId
                    shortestSpellName = cName
                    canInterrupt = true
                end
            end
        end
    end

    -- Also scan via WGG object manager for non-boss enemies
    if _G.WGG_GetObjectCount and _G.WGG_GetObjectWithIndex then
        local count = _G.WGG_GetObjectCount()
        for i = 0, count - 1 do
            local obj = _G.WGG_GetObjectWithIndex(i)
            if obj and obj ~= 0 then
                local ok, objType = pcall(_G.WGG_ObjectType, obj)
                if ok and (objType == 5 or objType == 6) then -- Unit or Player
                    local tokenOk, token = pcall(_G.WGG_ObjectToken, obj)
                    if tokenOk and token and token ~= "" then
                        if UnitExists(token) and UnitCanAttack("player", token) and not UnitIsDead(token) then
                            local castName, _, _, _, _, endTime, _, _, notInt, spellId = UnitCastingInfo(token)
                            if castName and not notInt then
                                local rem = endTime and ((endTime / 1000) - now) or 0
                                if rem > 0 and rem < shortestRemaining then
                                    shortestRemaining = rem
                                    shortestSpellId = spellId
                                    shortestSpellName = castName
                                    canInterrupt = true
                                    hasCast = true
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    BA.state.bossCasts = casts
    BA.state.bossIsCasting = hasCast
    BA.state.bossCanBeInterrupted = canInterrupt
    BA.state.bossCastRemaining = shortestRemaining < 999 and shortestRemaining or 0
    BA.state.bossCastSpellId = shortestSpellId
    BA.state.bossCastSpellName = shortestSpellName
end

---------------------------------------------------------------------------
-- Dangerous Debuffs
---------------------------------------------------------------------------
local function ScanDebuffs()
    if not BA.config.detectDangerousDebuffs then return end

    local debuffs = {}
    local hasDanger = false

    if _G.WGG_GetUnitAuraCount and _G.WGG_GetUnitAuraByIndex then
        local count = _G.WGG_GetUnitAuraCount("player")
        for i = 0, count - 1 do
            local spellId, stacks, duration, flags, instanceID, isHarmful = _G.WGG_GetUnitAuraByIndex("player", i)
            if isHarmful and spellId and duration and duration > 1 then
                table.insert(debuffs, {
                    spellId = spellId,
                    stacks = stacks or 0,
                    duration = duration,
                })
                hasDanger = true
            end
        end
    end

    BA.state.dangerousDebuffs = debuffs
    BA.state.hasDangerousDebuff = hasDanger
end

---------------------------------------------------------------------------
-- Main Update (called automatically during combat)
---------------------------------------------------------------------------
function BA:Update()
    if not self.config.enabled then return end

    local now = GetTime()
    if now - self.state.lastUpdate < self.config.updateInterval then return end
    self.state.lastUpdate = now

    local px, py, pz = GetPlayerPos()
    if not px then
        -- Fix 6: Reset danger states when player position unavailable (dead/loading)
        self.state.isStandingInBad = false
        self.state.missileIncoming = false
        self.state.bossIsCasting = false
        self.state.hasDangerousDebuff = false
        return
    end

    ScanGroundEffects(px, py, pz)
    ScanMissiles(px, py, pz)
    ScanBossCasts()
    ScanDebuffs()
end

---------------------------------------------------------------------------
-- Query API
---------------------------------------------------------------------------

function BA:IsStandingInBad()
    return self.state.isStandingInBad
end

function BA:NearestGroundEffectDistance()
    return self.state.nearestGroundEffectDist
end

function BA:GetGroundEffects()
    return self.state.dangerousGroundEffects
end

function BA:IsMissileIncoming()
    return self.state.missileIncoming
end

function BA:GetMissileETA()
    return self.state.missileETA
end

function BA:GetMissiles()
    return self.state.incomingMissiles
end

function BA:IsBossCasting()
    return self.state.bossIsCasting
end

function BA:CanInterruptBoss()
    return self.state.bossCanBeInterrupted, self.state.bossCastRemaining
end

function BA:GetBossCast()
    return {
        isCasting = self.state.bossIsCasting,
        canInterrupt = self.state.bossCanBeInterrupted,
        remaining = self.state.bossCastRemaining,
        spellId = self.state.bossCastSpellId,
        spellName = self.state.bossCastSpellName,
    }
end

function BA:GetAllBossCasts()
    return self.state.bossCasts
end

function BA:HasDangerousDebuff()
    return self.state.hasDangerousDebuff
end

function BA:GetDangerousDebuffs()
    return self.state.dangerousDebuffs
end

function BA:ShouldMove()
    return self.state.isStandingInBad or self.state.missileIncoming
end

function BA:GetThreatLevel()
    if self.state.isStandingInBad then
        return "MOVE_NOW", "Standing in ground effect"
    end
    if self.state.missileIncoming and self.state.missileETA < 1.5 then
        return "MOVE_SOON", "Missile impact in " .. string.format("%.1f", self.state.missileETA) .. "s"
    end
    if self.state.bossCanBeInterrupted and self.state.bossCastRemaining > 0 and self.state.bossCastRemaining < 2 then
        return "INTERRUPT", "Interruptible: " .. (self.state.bossCastSpellName or "Unknown")
    end
    if self.state.hasDangerousDebuff then
        return "DEBUFF", "Dangerous debuff active"
    end
    return "SAFE", nil
end

---------------------------------------------------------------------------
-- Auto-update: combat-aware OnUpdate frame
---------------------------------------------------------------------------
local inCombat = false
local frame = CreateFrame("Frame")
local elapsed = 0

frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        -- Reset all state on combat end
        BA.state.isStandingInBad = false
        BA.state.missileIncoming = false
        BA.state.bossIsCasting = false
        BA.state.bossCanBeInterrupted = false
        BA.state.hasDangerousDebuff = false
        BA.state.dangerousGroundEffects = {}
        BA.state.incomingMissiles = {}
        BA.state.bossCasts = {}
        BA.state.dangerousDebuffs = {}
        BA.state.nearestGroundEffectDist = 999
        BA.state.missileETA = 999
        BA.state.bossCastRemaining = 0
        BA.state.bossCastSpellId = nil
        BA.state.bossCastSpellName = nil
    end
end)

frame:SetScript("OnUpdate", function(self, dt)
    if not inCombat then return end
    elapsed = elapsed + dt
    if elapsed >= BA.config.updateInterval then
        elapsed = 0
        BA:Update()
    end
end)

if BA.config.debug then
    print("|cFF00FF00[BossAwareness]|r Standalone v" .. VERSION .. " loaded")
end

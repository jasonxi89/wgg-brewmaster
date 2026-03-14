--[[
================================================================================
  WGG Rotation Runtime - Minimal Standalone Runtime for Tank Scripts
  Version: 1.1.5

  Zero VanFW dependency.
  Provides:
    - Object scanning / wrapping
    - Spell wrapper
    - Tick loop start / stop
    - GUID -> token resolution
================================================================================
]]

local Runtime = {}
local VERSION = "1.1.5"
local tableUnpack = table.unpack or unpack

if _G.WGG_RotationRuntime and _G.WGG_RotationRuntime.VERSION then
    print("|cFFFFFF00[WGGRuntime]|r Replacing v" .. _G.WGG_RotationRuntime.VERSION .. " with v" .. VERSION)
end

local REQUIRED_FUNCS = {
    "WGG_ObjectType",
    "WGG_ObjectGUID",
    "WGG_ObjectPos",
}

for _, fn in ipairs(REQUIRED_FUNCS) do
    if not _G[fn] then
        print("|cFFFF0000[WGGRuntime]|r Missing WGG function: " .. fn .. ". Module disabled.")
        return
    end
end

if not _G.WGG_Objects and not (_G.WGG_GetObjectCount and _G.WGG_GetObjectWithIndex) then
    print("|cFFFF0000[WGGRuntime]|r Missing WGG object scan API. Module disabled.")
    return
end

_G.WGG_RotationRuntime = Runtime
Runtime.VERSION = VERSION

Runtime.config = {
    objectUpdateInterval = 0.05,
    minCastDelay = 0.08,
    aoeClickDelay = 0.15,
    groundClickVerifyDelay = 0.05,
    pendingCastMinWindow = 0.12,
    pendingCastMaxWindow = 0.4,
    pendingCastWindowPadding = 0.02,
    debug = false,
}

Runtime.state = {
    running = false,
    tickRate = 0.075,
    elapsedSinceTick = 0,
    rotationCallback = nil,
    frame = nil,
    lastCastTime = 0,
    lastObjectUpdate = 0,
    lastKnownGCDDuration = 0,
    lastKnownGCDModRate = 1,
    lastGroundClick = nil,
    groundClickTrace = {},
    pendingCast = nil,
}

function Runtime:GetGCDInfo()
    local startTime, duration, modRate = 0, 0, 1

    if C_Spell and C_Spell.GetSpellCooldown then
        local info = C_Spell.GetSpellCooldown(61304)
        if info then
            startTime = info.startTime or 0
            duration = info.duration or 0
            modRate = info.modRate or 1
        end
    elseif GetSpellCooldown then
        startTime, duration = GetSpellCooldown(61304)
    end

    if type(modRate) ~= "number" or modRate <= 0 then
        modRate = 1
    end

    local effectiveDuration = 0
    local remaining = 0

    if duration and duration > 0 then
        effectiveDuration = duration / modRate
    end

    if startTime and startTime > 0 and duration and duration > 0 then
        remaining = math.max(0, ((startTime + duration) - (GetTime() or 0)) / modRate)
    end

    if effectiveDuration > 0 then
        self.state.lastKnownGCDDuration = effectiveDuration
        self.state.lastKnownGCDModRate = modRate
    end

    return {
        startTime = startTime or 0,
        rawDuration = duration or 0,
        duration = effectiveDuration,
        modRate = modRate,
        remaining = remaining,
        active = remaining > 0,
        lastKnownDuration = self.state.lastKnownGCDDuration or 0,
        lastKnownModRate = self.state.lastKnownGCDModRate or 1,
    }
end

function Runtime:GetGCD()
    return self:GetGCDInfo().remaining or 0
end

function Runtime:GetGCDDuration()
    local info = self:GetGCDInfo()
    if info.duration and info.duration > 0 then
        return info.duration
    end

    return info.lastKnownDuration or 0
end

function Runtime:IsGCDActive()
    return self:GetGCD() > 0
end

function Runtime:GetCastThrottleRemaining()
    return math.max(0, (self.config.minCastDelay or 0) - ((GetTime() or 0) - (self.state.lastCastTime or 0)))
end

function Runtime:GetLatency()
    if not GetNetStats then
        return 0
    end

    local _, _, latencyHome, latencyWorld = GetNetStats()
    return math.max(0, math.max(latencyHome or 0, latencyWorld or 0) / 1000)
end

function Runtime:GetBuffer()
    return math.max(0, self:GetLatency() + (self.state.tickRate or 0))
end

function Runtime:GetPendingCast()
    return self.state.pendingCast
end

function Runtime:HasPendingCast()
    return self.state.pendingCast ~= nil
end

function Runtime:GetPendingCastRemaining()
    local pending = self.state.pendingCast
    if not pending then
        return 0
    end

    return math.max(0, (pending.waitUntil or 0) - (GetTime() or 0))
end

function Runtime:GetPendingCastInfo()
    local pending = self.state.pendingCast
    if not pending then
        return nil
    end

    local now = GetTime() or 0
    return {
        spellId = pending.spellId or 0,
        spellName = pending.spellName or "Unknown",
        targetToken = pending.targetToken or "",
        issuedAt = pending.issuedAt or 0,
        age = math.max(0, now - (pending.issuedAt or 0)),
        remaining = math.max(0, (pending.waitUntil or 0) - now),
        waitWindow = math.max(0, (pending.waitUntil or 0) - (pending.issuedAt or 0)),
        latency = pending.latency or 0,
        buffer = pending.buffer or 0,
        requiresGCD = pending.requiresGCD == true,
        castType = pending.castType or "target",
        groundPosition = pending.groundPosition,
    }
end

function Runtime:SetLastGroundClickDebug(method, reason, details)
    details = details or {}
    local entry = {
        method = method or "unknown",
        reason = reason or "unknown",
        worldX = details.worldX,
        worldY = details.worldY,
        worldZ = details.worldZ,
        screenX = details.screenX,
        screenY = details.screenY,
        ndcX = details.ndcX,
        ndcY = details.ndcY,
        pendingSpellId = details.pendingSpellId,
        attempt = details.attempt,
        updatedAt = GetTime() or 0,
    }
    self.state.lastGroundClick = entry

    local trace = self.state.groundClickTrace or {}
    trace[#trace + 1] = entry
    while #trace > 12 do
        table.remove(trace, 1)
    end
    self.state.groundClickTrace = trace
end

function Runtime:GetLastGroundClickDebug()
    local info = self.state.lastGroundClick
    if not info then
        return nil
    end

    return {
        method = info.method,
        reason = info.reason,
        worldX = info.worldX,
        worldY = info.worldY,
        worldZ = info.worldZ,
        screenX = info.screenX,
        screenY = info.screenY,
        ndcX = info.ndcX,
        ndcY = info.ndcY,
        pendingSpellId = info.pendingSpellId,
        attempt = info.attempt,
        age = math.max(0, (GetTime() or 0) - (info.updatedAt or 0)),
    }
end

function Runtime:GetGroundClickTrace()
    local trace = self.state.groundClickTrace or {}
    local copied = {}

    for index, info in ipairs(trace) do
        copied[index] = {
            method = info.method,
            reason = info.reason,
            worldX = info.worldX,
            worldY = info.worldY,
            worldZ = info.worldZ,
            screenX = info.screenX,
            screenY = info.screenY,
            ndcX = info.ndcX,
            ndcY = info.ndcY,
            pendingSpellId = info.pendingSpellId,
            attempt = info.attempt,
            age = math.max(0, (GetTime() or 0) - (info.updatedAt or 0)),
        }
    end

    return copied
end

function Runtime:IsSpellPending(spellOrId)
    local pending = self.state.pendingCast
    if not pending then
        return false
    end

    if spellOrId == nil then
        return true
    end

    local identifier = spellOrId
    if type(spellOrId) == "table" then
        identifier = spellOrId.id or spellOrId.name
    end

    return pending.spellId == identifier or pending.spellName == identifier
end

function Runtime:ClearPendingCast(reason)
    local pending = self.state.pendingCast
    self.state.pendingCast = nil
    if pending and self.config.debug then
        print("|cFF88CCFF[WGGRuntime]|r " .. string.format("Cleared pending cast: %s (%s)",
            tostring(pending.spellName or pending.spellId or "unknown"),
            tostring(reason or "unknown")))
    end
end

function Runtime:CreatePendingCast(spell, token, castSnapshot, options)
    options = options or {}
    local now = GetTime() or 0
    local latency = self:GetLatency()
    local buffer = self:GetBuffer()
    local computedWindow = buffer + (self.config.pendingCastWindowPadding or 0.02)
    local waitWindow = tonumber(options.waitWindow)
        or math.max(
            self.config.pendingCastMinWindow or 0.12,
            math.min(
                self.config.pendingCastMaxWindow or 0.4,
                computedWindow
            )
        )
    return {
        spell = spell,
        spellId = spell.id or 0,
        spellName = spell.name or "Unknown",
        targetToken = token or "",
        issuedAt = now,
        waitUntil = now + waitWindow,
        latency = latency,
        buffer = buffer,
        requiresGCD = spell.gcd == true,
        castType = options.castType or (token == "player" and "self" or "target"),
        groundPosition = options.groundPosition,
        preCooldown = castSnapshot and castSnapshot.cooldown or 0,
        preCharges = castSnapshot and castSnapshot.charges or 0,
        preMaxCharges = castSnapshot and castSnapshot.maxCharges or 1,
    }
end

function Runtime:IsPendingCastConfirmed(pending)
    if not pending then
        return false, nil
    end

    if pending.requiresGCD and self:IsGCDActive() then
        return true, "gcd_started"
    end

    local spell = pending.spell
    if not spell then
        return false, nil
    end

    local currentCharges = spell:Charges()
    if currentCharges < (pending.preCharges or currentCharges) then
        return true, "charge_spent"
    end

    local currentCooldown = spell:Cooldown()
    if currentCooldown > ((pending.preCooldown or 0) + 0.01) then
        return true, "cooldown_started"
    end

    return false, nil
end

function Runtime:IsPendingCastBlocking()
    local pending = self.state.pendingCast
    if not pending then
        return false
    end

    local confirmed = self:IsPendingCastConfirmed(pending)
    if confirmed then
        return false
    end

    return (pending.waitUntil or 0) > (GetTime() or 0)
end

function Runtime:ProcessPendingCast()
    local pending = self.state.pendingCast
    if not pending then
        return false
    end

    local confirmed, reason = self:IsPendingCastConfirmed(pending)
    if confirmed then
        self:ClearPendingCast(reason)
        return false
    end

    if (pending.waitUntil or 0) > (GetTime() or 0) then
        return true
    end

    self:ClearPendingCast("timed_out")
    return false
end

Runtime.objects = {
    all = {},
    enemies = {},
    friends = {},
    byGUID = {},
}

Runtime.guidToToken = {}
Runtime.player = nil
Runtime.target = nil

local function DebugPrint(msg)
    if Runtime.config.debug then
        print("|cFF88CCFF[WGGRuntime]|r " .. tostring(msg))
    end
end

local function ErrorPrint(msg)
    print("|cFFFF5555[WGGRuntime]|r " .. tostring(msg))
end

local function Dist3D(x1, y1, z1, x2, y2, z2)
    if not x1 or not x2 then
        return math.huge
    end

    local dx = x1 - x2
    local dy = y1 - y2
    local dz = (z1 or 0) - (z2 or 0)
    return math.sqrt((dx * dx) + (dy * dy) + (dz * dz))
end

local Object = {}
Object.__index = Object

function Object:New(pointer, token, guid)
    local obj = setmetatable({}, Object)
    obj.pointer = pointer
    obj.token = token or ""
    obj._guid = guid or ""

    if obj._guid == "" then
        if pointer and _G.WGG_ObjectGUID then
            local ok, resolvedGuid = pcall(_G.WGG_ObjectGUID, pointer)
            obj._guid = ok and resolvedGuid or ""
        elseif token and token ~= "" then
            obj._guid = UnitGUID(token) or ""
        end
    end

    return obj
end

function Object:GetToken()
    if self.token and self.token ~= "" then
        return self.token
    end

    if self._guid and self._guid ~= "" then
        return Runtime.guidToToken[self._guid]
    end

    return nil
end

function Object:exists()
    local token = self:GetToken()
    return token and token ~= "" and UnitExists(token) or false
end

function Object:guid()
    return self._guid
end

function Object:position()
    if self.pointer and _G.WGG_ObjectPos then
        local ok, x, y, z = pcall(_G.WGG_ObjectPos, self.pointer)
        if ok and x then
            return x, y, z
        end
    end

    local token = self:GetToken()
    if token == "player" and _G.WGG_GetPlayerPosition then
        return _G.WGG_GetPlayerPosition()
    end

    if token == "target" and _G.WGG_GetTargetPosition then
        return _G.WGG_GetTargetPosition()
    end

    if token and _G.UnitPosition then
        local x, y, z = _G.UnitPosition(token)
        if x then
            return x, y, z
        end
    end

    return nil, nil, nil
end

function Object:distance(target)
    local other = target or Runtime.player

    if type(other) == "string" then
        other = Runtime:WrapUnit(other)
    end

    if not other then
        return math.huge
    end

    if self.pointer and other.pointer and _G.WGG_ObjectDistance then
        local ok, distance = pcall(_G.WGG_ObjectDistance, self.pointer, other.pointer)
        if ok and distance then
            return distance
        end
    end

    local x1, y1, z1 = self:position()
    local x2, y2, z2 = other:position()
    return Dist3D(x1, y1, z1, x2, y2, z2)
end

function Object:Health()
    local token = self:GetToken()
    if not token or not UnitExists(token) then
        return 0
    end
    return UnitHealth(token) or 0
end

function Object:HealthMax()
    local token = self:GetToken()
    if not token or not UnitExists(token) then
        return 1
    end
    return UnitHealthMax(token) or 1
end

function Object:hp()
    local maxHealth = self:HealthMax()
    if maxHealth <= 0 then
        return 0
    end
    return (self:Health() / maxHealth) * 100
end

function Object:dead()
    local token = self:GetToken()
    if not token or not UnitExists(token) then
        return false
    end
    return UnitIsDeadOrGhost(token) or false
end

function Object:enemy()
    local token = self:GetToken()
    if not token or not UnitExists(token) then
        return false
    end
    return UnitCanAttack("player", token) or false
end

function Object:combat()
    local token = self:GetToken()
    if not token or not UnitExists(token) then
        return false
    end
    return UnitAffectingCombat(token) or false
end

function Object:HasBuff(spellId)
    local token = self:GetToken()
    if not token or not UnitExists(token) then
        return false, 0, 0
    end

    local now = GetTime()
    if C_UnitAuras and C_UnitAuras.GetBuffDataByIndex then
        for i = 1, 40 do
            local auraData = C_UnitAuras.GetBuffDataByIndex(token, i)
            if not auraData then
                break
            end
            if auraData.spellId == spellId then
                return true, auraData.applications or 1, auraData.expirationTime and (auraData.expirationTime - now) or 0
            end
        end
    elseif UnitAura then
        for i = 1, 40 do
            local name, _, count, _, _, expirationTime, _, _, _, id = UnitAura(token, i, "HELPFUL")
            if not name then
                break
            end
            if id == spellId then
                return true, count or 1, expirationTime and (expirationTime - now) or 0
            end
        end
    end

    return false, 0, 0
end

function Object:BuffStacks(spellId)
    local hasBuff, stacks = self:HasBuff(spellId)
    if hasBuff then
        return stacks or 1
    end
    return 0
end

function Object:HasDebuff(spellId)
    local token = self:GetToken()
    if not token or not UnitExists(token) then
        return false, 0, 0
    end

    local now = GetTime()
    if C_UnitAuras and C_UnitAuras.GetDebuffDataByIndex then
        for i = 1, 40 do
            local auraData = C_UnitAuras.GetDebuffDataByIndex(token, i)
            if not auraData then
                break
            end
            if auraData.spellId == spellId then
                return true, auraData.applications or 1, auraData.expirationTime and (auraData.expirationTime - now) or 0
            end
        end
    elseif UnitAura then
        for i = 1, 40 do
            local name, _, count, _, _, expirationTime, _, _, _, id = UnitAura(token, i, "HARMFUL")
            if not name then
                break
            end
            if id == spellId then
                return true, count or 1, expirationTime and (expirationTime - now) or 0
            end
        end
    end

    return false, 0, 0
end

local Spell = {}
Spell.__index = Spell

function Runtime:CreateSpell(spellIDOrName, options)
    options = options or {}

    local spell = setmetatable({}, Spell)
    if type(spellIDOrName) == "number" then
        spell.id = spellIDOrName
        spell.name = options.name or ((C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellIDOrName)) or "Unknown")
    else
        spell.id = options.id
        spell.name = tostring(spellIDOrName or options.name or "Unknown")
    end

    spell.castMethod = options.castMethod or "auto"
    spell.priority = options.priority or 5
    spell.gcd = options.gcd ~= false
    return spell
end

function Spell:Cooldown()
    if C_Spell and C_Spell.GetSpellCooldown and self.id then
        local info = C_Spell.GetSpellCooldown(self.id)
        if info and info.startTime and info.duration and info.startTime > 0 then
            return math.max(0, info.duration - (GetTime() - info.startTime))
        end
        return 0
    end

    if GetSpellCooldown and self.id then
        local startTime, duration = GetSpellCooldown(self.id)
        if startTime and startTime > 0 then
            return math.max(0, duration - (GetTime() - startTime))
        end
    end

    return 0
end

function Spell:CooldownDuration()
    if C_Spell and C_Spell.GetSpellCooldown and self.id then
        local info = C_Spell.GetSpellCooldown(self.id)
        return info and info.duration or 0
    end

    if GetSpellCooldown and self.id then
        local _, duration = GetSpellCooldown(self.id)
        return duration or 0
    end

    return 0
end

function Spell:Charges()
    if C_Spell and C_Spell.GetSpellCharges and self.id then
        local info = C_Spell.GetSpellCharges(self.id)
        if info then
            return info.currentCharges or 0, info.maxCharges or 1
        end
    elseif GetSpellCharges and self.id then
        local charges, maxCharges = GetSpellCharges(self.id)
        return charges or 0, maxCharges or 1
    end

    return 0, 1
end

function Spell:HasCharges()
    local charges = self:Charges()
    return charges > 0
end

function Spell:IsKnown()
    if self.castMethod == "name" and self.name then
        return true
    end

    if not self.id then
        return false
    end

    return IsSpellKnown(self.id, false) or (IsPlayerSpell and IsPlayerSpell(self.id)) or false
end

function Spell:IsUsable()
    local spellIdentifier = (self.castMethod == "name" and self.name) or self.id
    if not spellIdentifier then
        return false
    end

    if C_Spell and C_Spell.IsSpellUsable then
        local usable = C_Spell.IsSpellUsable(spellIdentifier)
        return usable == true
    end

    if IsUsableSpell then
        local usable = IsUsableSpell(spellIdentifier)
        return usable == true
    end

    return false
end

function Spell:InRange(target)
    if not target then
        return true
    end

    local token = nil
    if type(target) == "table" then
        token = target:GetToken()
    elseif type(target) == "string" then
        token = target
        target = Runtime:WrapUnit(target)
    end

    if token and token ~= "" then
        if C_Spell and C_Spell.IsSpellInRange and (self.id or self.name) then
            local ok, inRange = pcall(C_Spell.IsSpellInRange, self.id or self.name, token)
            if ok and inRange ~= nil then
                return inRange == true or inRange == 1
            end
        end

        if IsSpellInRange and self.name then
            local ok, inRange = pcall(IsSpellInRange, self.name, token)
            if ok and inRange ~= nil then
                return inRange == 1
            end
        end
    end

    if type(target) ~= "table" or type(target.distance) ~= "function" then
        return true
    end

    local distance = target:distance()
    if not distance or distance == math.huge then
        return true
    end

    if C_Spell and C_Spell.GetSpellInfo and self.id then
        local info = C_Spell.GetSpellInfo(self.id)
        if info and info.maxRange and info.maxRange > 0 then
            return distance <= info.maxRange
        end
    end

    return distance <= 5
end

function Spell:Castable(target)
    if not self:IsKnown() then
        return false, "not_known"
    end

    if not self:IsUsable() then
        return false, "not_usable"
    end

    if self:Cooldown() > 0 and not self:HasCharges() then
        return false, "on_cooldown"
    end

    if self.gcd and Runtime:IsGCDActive() then
        return false, "gcd_active"
    end

    if Runtime:GetCastThrottleRemaining() > 0 then
        return false, "cast_throttled"
    end

    if self.gcd and Runtime:IsPendingCastBlocking() then
        return false, "pending_cast"
    end

    if target and not self:InRange(target) then
        return false, "out_of_range"
    end

    return true, nil
end

local function ExecuteCast(spell, token)
    local castMethod = spell.castMethod or "auto"
    local castToken = token and token ~= "" and token or nil

    if castMethod == "name" and spell.name and CastSpellByName then
        CastSpellByName(spell.name, castToken)
        return true
    end

    if spell.id and CastSpellByID then
        CastSpellByID(spell.id, castToken)
        return true
    end

    if spell.name and CastSpellByName then
        CastSpellByName(spell.name, castToken)
        return true
    end

    return false
end

local function NormalizeAoEPosition(x, y, z)
    if type(x) == "table" then
        if type(x.position) == "function" then
            return x:position()
        end

        if type(x[1]) == "number" then
            return x[1], x[2], x[3]
        end

        if type(x.x) == "number" and type(x.y) == "number" then
            return x.x, x.y, x.z
        end
    end

    return x, y, z
end

local function GetWorldClickFunction()
    if type(_G.WGG_Click) == "function" then
        return _G.WGG_Click
    end

    local wgg = _G.WGG
    if (type(wgg) == "table" or type(wgg) == "userdata") and type(wgg.Click) == "function" then
        return wgg.Click
    end

    return nil
end

local function GetTableField(root, fieldName)
    local rootType = type(root)
    if rootType ~= "table" and rootType ~= "userdata" then
        return nil
    end

    local ok, value = pcall(function()
        return root[fieldName]
    end)
    if ok and value ~= nil then
        return value
    end

    if rootType == "userdata" then
        local meta = getmetatable(root)
        if type(meta) == "table" and type(meta.__index) == "table" then
            return meta.__index[fieldName]
        end
    end

    return nil
end

local function GetTableFunction(root, fieldName)
    local value = GetTableField(root, fieldName)
    return type(value) == "function" and value or nil
end

local function GetWGGAPIFunction(fieldName)
    return GetTableFunction(_G.WGG_API, fieldName)
end

local function GetPendingSpellID()
    local pendingSpellID = GetWGGAPIFunction("PendingSpellID")
    if type(pendingSpellID) ~= "function" then
        return nil
    end

    local ok, spellID = pcall(pendingSpellID)
    if ok and type(spellID) == "number" and spellID > 0 then
        return spellID
    end

    return nil
end

local function IsGroundCursorPending()
    if SpellIsTargeting and SpellIsTargeting() then
        return true
    end

    local pendingSpellID = GetPendingSpellID()
    if type(pendingSpellID) == "number" and pendingSpellID > 0 then
        return true
    end

    local apiPendingFunc = GetWGGAPIFunction("IsSpellPending")
    if type(apiPendingFunc) == "function" then
        local ok, pending = pcall(apiPendingFunc)
        if ok and pending == true and type(pendingSpellID) == "number" and pendingSpellID > 0 then
            return true
        end
    end

    if type(_G.WGG_IsSpellPending) == "function" then
        local ok, pending = pcall(_G.WGG_IsSpellPending)
        if ok and pending == true and type(pendingSpellID) == "number" and pendingSpellID > 0 then
            return true
        end
    end

    return false
end

local function RoundScreenCoordinate(value)
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
        return nil
    end

    return math.floor(value + 0.5)
end

local function WorldToScreenCoordinates(worldX, worldY, worldZ)
    local w2s = GetWGGAPIFunction("W2S") or _G.WGG_W2S
    local ndcToScreen = GetWGGAPIFunction("NDCToScreen") or _G.WGG_NDCToScreen

    if type(w2s) ~= "function" then
        return nil, nil, nil, nil, "missing_w2s_api"
    end

    if type(ndcToScreen) ~= "function" then
        return nil, nil, nil, nil, "missing_ndc_to_screen_api"
    end

    local ok, ndcX, ndcY, visible = pcall(w2s, worldX, worldY, worldZ)
    if not ok then
        return nil, nil, nil, nil, "w2s_failed"
    end

    if not visible or visible == 0 or type(ndcX) ~= "number" or type(ndcY) ~= "number" then
        return nil, nil, nil, nil, "w2s_not_visible"
    end

    local screenOk, screenX, screenY = pcall(ndcToScreen, ndcX, ndcY)
    if not screenOk then
        return nil, nil, nil, nil, "ndc_to_screen_failed"
    end

    screenX = RoundScreenCoordinate(screenX)
    screenY = RoundScreenCoordinate(screenY)
    if not screenX or not screenY then
        return nil, nil, nil, nil, "invalid_screen_position"
    end

    return screenX, screenY, ndcX, ndcY, nil
end

local function CallWithProtection(fn, ...)
    local protectedCall = _G.WGG_callProtected or GetWGGAPIFunction("CallProtected")
    local args = {...}

    if type(protectedCall) == "function" then
        local ok, result1, result2, result3 = pcall(function()
            return protectedCall(function()
                return fn(tableUnpack(args))
            end)
        end)
        if ok then
            return true, result1, result2, result3
        end
    end

    return pcall(fn, tableUnpack(args))
end

local function TryFunctionAttempts(fn, attempts)
    if type(fn) ~= "function" then
        return false, nil
    end

    for attemptIndex, args in ipairs(attempts or {}) do
        local ok, result = CallWithProtection(fn, tableUnpack(args))
        if ok and result ~= false then
            return true, attemptIndex
        end
    end

    return false, nil
end

local function CloneGroundClickDetails(details)
    local copy = {}
    for key, value in pairs(details or {}) do
        copy[key] = value
    end
    return copy
end

local function BuildGroundClickMethods(worldX, worldY, worldZ)
    local pendingSpellId = GetPendingSpellID()
    local baseDetails = {
        worldX = worldX,
        worldY = worldY,
        worldZ = worldZ,
        pendingSpellId = pendingSpellId,
    }
    local methods = {}

    local worldClick = GetWorldClickFunction()
    if type(worldClick) == "function" then
        methods[#methods + 1] = {
            name = "wgg_click",
            details = CloneGroundClickDetails(baseDetails),
            invoke = worldClick,
            attempts = {
                {worldX, worldY, worldZ},
            },
            failReason = "ground_click_failed",
        }
    end

    local mouseClick = GetWGGAPIFunction("MouseClick")
    if type(mouseClick) == "function" then
        local screenX, screenY, ndcX, ndcY, screenReason = WorldToScreenCoordinates(worldX, worldY, worldZ)
        local mouseDetails = CloneGroundClickDetails(baseDetails)
        mouseDetails.screenX = screenX
        mouseDetails.screenY = screenY
        mouseDetails.ndcX = ndcX
        mouseDetails.ndcY = ndcY

        methods[#methods + 1] = {
            name = "wgg_api_mouseclick",
            details = mouseDetails,
            unavailableReason = screenReason,
            invoke = mouseClick,
            attempts = {
                {screenX, screenY},
                {screenX, screenY, "LeftButton"},
                {"LeftButton", screenX, screenY},
                {screenX, screenY, 0},
                {0, screenX, screenY},
                {screenX, screenY, 1},
                {1, screenX, screenY},
                {screenX, screenY, "left"},
                {"left", screenX, screenY},
                {ndcX, ndcY},
                {ndcX, ndcY, "LeftButton"},
                {"LeftButton", ndcX, ndcY},
                {ndcX, ndcY, 0},
                {0, ndcX, ndcY},
            },
            failReason = "mouse_click_failed",
        }
    end

    local objectInteract = GetWGGAPIFunction("ObjectInteract")
    if type(objectInteract) == "function" then
        methods[#methods + 1] = {
            name = "wgg_api_object_interact",
            details = CloneGroundClickDetails(baseDetails),
            invoke = objectInteract,
            attempts = {
                {worldX, worldY, worldZ},
                {worldX, worldY, worldZ, 1},
                {worldX, worldY, worldZ, "LeftButton"},
            },
            failReason = "object_interact_failed",
        }
    end

    return methods
end

local function AttemptGroundClickMethods(worldX, worldY, worldZ, callback)
    local methods = BuildGroundClickMethods(worldX, worldY, worldZ)
    if #methods < 1 then
        Runtime:SetLastGroundClickDebug("none", "missing_click_api", {
            worldX = worldX,
            worldY = worldY,
            worldZ = worldZ,
            pendingSpellId = GetPendingSpellID(),
        })
        if callback then
            callback(false, "missing_click_api")
        end
        return
    end

    local verifyDelay = Runtime.config.groundClickVerifyDelay or 0.05

    local function tryMethod(index, attemptIndex, lastReason)
        local method = methods[index]
        if not method then
            local finalReason = lastReason or "all_ground_click_methods_failed"
            Runtime:SetLastGroundClickDebug("none", finalReason, {
                worldX = worldX,
                worldY = worldY,
                worldZ = worldZ,
                pendingSpellId = GetPendingSpellID(),
            })
            if callback then
                callback(false, finalReason)
            end
            return
        end

        local details = CloneGroundClickDetails(method.details)
        details.pendingSpellId = GetPendingSpellID() or details.pendingSpellId
        attemptIndex = attemptIndex or 1

        if method.unavailableReason then
            Runtime:SetLastGroundClickDebug(method.name, method.unavailableReason, details)
            return tryMethod(index + 1, 1, method.unavailableReason)
        end

        local args = method.attempts and method.attempts[attemptIndex] or nil
        if not args then
            Runtime:SetLastGroundClickDebug(method.name, method.failReason or "invoke_failed", details)
            return tryMethod(index + 1, 1, method.failReason or "invoke_failed")
        end

        details.attempt = attemptIndex
        local invoked, invokeResult = CallWithProtection(method.invoke, tableUnpack(args))

        if not invoked or invokeResult == false then
            Runtime:SetLastGroundClickDebug(method.name, method.failReason or "invoke_failed", details)
            if method.attempts and method.attempts[attemptIndex + 1] then
                return tryMethod(index, attemptIndex + 1, method.failReason or "invoke_failed")
            end
            return tryMethod(index + 1, 1, method.failReason or "invoke_failed")
        end

        Runtime:SetLastGroundClickDebug(method.name, "invoked", details)

        C_Timer.After(verifyDelay, function()
            details.pendingSpellId = GetPendingSpellID() or details.pendingSpellId
            if IsGroundCursorPending() then
                Runtime:SetLastGroundClickDebug(method.name, "cursor_still_pending", details)
                if method.attempts and method.attempts[attemptIndex + 1] then
                    return tryMethod(index, attemptIndex + 1, method.name .. "_cursor_still_pending")
                end
                return tryMethod(index + 1, 1, method.name .. "_cursor_still_pending")
            end

            Runtime:SetLastGroundClickDebug(method.name, "success", details)
            if callback then
                callback(true, method.name)
            end
        end)
    end

    tryMethod(1, 1)
end

local function CanUseGroundClickPath()
    if type(GetWorldClickFunction()) == "function" then
        return true, nil
    end

    if type(GetWGGAPIFunction("MouseClick")) == "function"
        and type(GetWGGAPIFunction("W2S") or _G.WGG_W2S) == "function"
        and type(GetWGGAPIFunction("NDCToScreen") or _G.WGG_NDCToScreen) == "function"
    then
        return true, nil
    end

    if type(GetWGGAPIFunction("ObjectInteract")) == "function" then
        return true, nil
    end

    if type(GetWGGAPIFunction("MouseClick")) ~= "function" then
        return false, "missing_click_api"
    elseif type(GetWGGAPIFunction("W2S") or _G.WGG_W2S) ~= "function" then
        return false, "missing_w2s_api"
    elseif type(GetWGGAPIFunction("NDCToScreen") or _G.WGG_NDCToScreen) ~= "function" then
        return false, "missing_ndc_to_screen_api"
    end

    return false, "missing_click_api"
end

function Runtime:IsGroundCursorPending()
    return IsGroundCursorPending()
end

function Runtime:GetExternalPendingSpellID()
    return GetPendingSpellID()
end

function Spell:Cast(target)
    if not self:Castable(target) then
        return false
    end

    if (GetTime() - Runtime.state.lastCastTime) < Runtime.config.minCastDelay then
        return false
    end

    local token = nil
    if type(target) == "table" then
        token = target:GetToken()
    elseif type(target) == "string" then
        token = target
    end

    local castSnapshot = nil
    if self.gcd then
        local charges, maxCharges = self:Charges()
        castSnapshot = {
            cooldown = self:Cooldown(),
            charges = charges or 0,
            maxCharges = maxCharges or 1,
        }
    end

    if not ExecuteCast(self, token) then
        return false
    end

    Runtime.state.lastCastTime = GetTime()
    if self.gcd then
        Runtime.state.pendingCast = Runtime:CreatePendingCast(self, token, castSnapshot)
    end
    return true
end

function Spell:SelfCast()
    if not self:Castable() then
        return false
    end

    if (GetTime() - Runtime.state.lastCastTime) < Runtime.config.minCastDelay then
        return false
    end

    local castSnapshot = nil
    if self.gcd then
        local charges, maxCharges = self:Charges()
        castSnapshot = {
            cooldown = self:Cooldown(),
            charges = charges or 0,
            maxCharges = maxCharges or 1,
        }
    end

    if not ExecuteCast(self, "player") then
        return false
    end

    Runtime.state.lastCastTime = GetTime()
    if self.gcd then
        Runtime.state.pendingCast = Runtime:CreatePendingCast(self, "player", castSnapshot)
    end
    return true
end

function Spell:AoECast(x, y, z, rangeTarget)
    local castable, reason = self:Castable(rangeTarget)
    if not castable then
        return false, reason
    end

    if (GetTime() - Runtime.state.lastCastTime) < Runtime.config.minCastDelay then
        return false, "cast_throttled"
    end

    local castX, castY, castZ = NormalizeAoEPosition(x, y, z)
    if type(castX) ~= "number" or type(castY) ~= "number" or type(castZ) ~= "number" then
        return false, "invalid_ground_position"
    end

    local canClickGround, clickReason = CanUseGroundClickPath()
    if not canClickGround then
        Runtime:SetLastGroundClickDebug("none", clickReason or "missing_click_api", {
            worldX = castX,
            worldY = castY,
            worldZ = castZ,
        })
        return false, clickReason or "missing_click_api"
    end

    if not C_Timer or type(C_Timer.After) ~= "function" then
        return false, "missing_timer_api"
    end

    local castSnapshot = nil
    if self.gcd then
        local charges, maxCharges = self:Charges()
        castSnapshot = {
            cooldown = self:Cooldown(),
            charges = charges or 0,
            maxCharges = maxCharges or 1,
        }
    end

    if not ExecuteCast(self, nil) then
        return false, "cast_returned_false"
    end

    Runtime.state.lastCastTime = GetTime()
    if self.gcd then
        local waitWindow = (Runtime.config.aoeClickDelay or 0.15) + Runtime:GetBuffer() + (Runtime.config.pendingCastWindowPadding or 0.02)
        Runtime.state.pendingCast = Runtime:CreatePendingCast(self, nil, castSnapshot, {
            castType = "ground",
            waitWindow = waitWindow,
            groundPosition = {
                x = castX,
                y = castY,
                z = castZ,
            },
        })
    end

    C_Timer.After(Runtime.config.aoeClickDelay or 0.15, function()
        local shouldClick = IsGroundCursorPending()

        if shouldClick then
            AttemptGroundClickMethods(castX, castY, castZ, function(clicked, clickReason)
                if not clicked then
                    local pendingInfo = Runtime:GetPendingCastInfo()
                    if pendingInfo and pendingInfo.castType == "ground" and pendingInfo.spellId == (self.id or 0) then
                        Runtime:ClearPendingCast(clickReason or "ground_click_failed")
                    end
                end
            end)
            return
        end

        local pendingInfo = Runtime:GetPendingCastInfo()
        if pendingInfo and pendingInfo.castType == "ground" and pendingInfo.spellId == (self.id or 0) then
            Runtime:SetLastGroundClickDebug("none", "no_ground_cursor", {
                worldX = castX,
                worldY = castY,
                worldZ = castZ,
                pendingSpellId = GetPendingSpellID(),
            })
            Runtime:ClearPendingCast("no_ground_cursor")
        end
    end)

    return true, nil
end

function Runtime:WrapUnit(token, pointer)
    if not token or token == "" then
        return nil
    end

    local guid = UnitGUID(token) or ""
    if guid ~= "" and self.objects.byGUID[guid] then
        local obj = self.objects.byGUID[guid]
        if token ~= obj.token then
            obj.token = token
        end
        return obj
    end

    return Object:New(pointer, token, guid)
end

function Runtime:RefreshTokenMap()
    self.guidToToken = {}

    local function addToken(token)
        if token and UnitExists(token) then
            local guid = UnitGUID(token)
            if guid and guid ~= "" then
                self.guidToToken[guid] = token
            end
        end
    end

    addToken("player")
    addToken("target")
    addToken("mouseover")
    addToken("focus")

    for i = 1, 5 do
        addToken("boss" .. i)
    end

    for i = 1, 40 do
        addToken("nameplate" .. i)
    end
end

function Runtime:UpdateObjects(force)
    local now = GetTime()
    if not force and (now - self.state.lastObjectUpdate) < self.config.objectUpdateInterval then
        return
    end
    self.state.lastObjectUpdate = now

    self:RefreshTokenMap()

    local all = {}
    local enemies = {}
    local friends = {}
    local byGUID = {}

    local pointers = nil
    if _G.WGG_Objects then
        local ok, result = pcall(_G.WGG_Objects)
        if ok and type(result) == "table" then
            pointers = result
        end
    end

    if not pointers and _G.WGG_GetObjectCount and _G.WGG_GetObjectWithIndex then
        pointers = {}
        local count = _G.WGG_GetObjectCount()
        for i = 0, count - 1 do
            pointers[#pointers + 1] = _G.WGG_GetObjectWithIndex(i)
        end
    end

    for _, pointer in ipairs(pointers or {}) do
        if pointer and pointer ~= 0 then
            local okType, objType = pcall(_G.WGG_ObjectType, pointer)
            if okType and (objType == 5 or objType == 6) then
                local guid = ""
                local okGuid, resolvedGuid = pcall(_G.WGG_ObjectGUID, pointer)
                if okGuid and resolvedGuid then
                    guid = resolvedGuid
                end

                local token = nil
                if _G.WGG_ObjectToken then
                    local okToken, resolvedToken = pcall(_G.WGG_ObjectToken, pointer)
                    if okToken and resolvedToken and resolvedToken ~= "" then
                        token = resolvedToken
                    end
                end

                if (not token or token == "") and guid ~= "" then
                    token = self.guidToToken[guid]
                end

                local obj = Object:New(pointer, token, guid)
                if obj._guid ~= "" then
                    all[#all + 1] = obj
                    byGUID[obj._guid] = obj

                    if obj:exists() and not obj:dead() then
                        if obj:enemy() then
                            enemies[#enemies + 1] = obj
                        else
                            friends[#friends + 1] = obj
                        end
                    end
                end
            end
        end
    end

    self.objects.all = all
    self.objects.enemies = enemies
    self.objects.friends = friends
    self.objects.byGUID = byGUID

    self.player = self:WrapUnit("player")

    if UnitExists("target") then
        local targetGuid = UnitGUID("target")
        self.target = targetGuid and byGUID[targetGuid] or self:WrapUnit("target")
    else
        self.target = nil
    end
end

function Runtime:GetEnemiesInRange(range)
    local result = {}
    for _, enemy in ipairs(self.objects.enemies) do
        if enemy:distance() <= range then
            result[#result + 1] = enemy
        end
    end
    return result
end

function Runtime:GetClosestEnemy(range)
    local best = nil
    local bestDistance = range or math.huge

    for _, enemy in ipairs(self.objects.enemies) do
        local distance = enemy:distance()
        if distance < bestDistance then
            best = enemy
            bestDistance = distance
        end
    end

    return best
end

function Runtime:GetObjectByGUID(guid)
    return guid and self.objects.byGUID[guid] or nil
end

function Runtime:Print(msg)
    print("|cFF00FFFF[WGGRuntime]|r " .. tostring(msg))
end

function Runtime:Success(msg)
    print("|cFF00FF00[WGGRuntime]|r " .. tostring(msg))
end

function Runtime:Error(msg)
    ErrorPrint(msg)
end

function Runtime:Start(rotationCallback, tickRate)
    if not rotationCallback or type(rotationCallback) ~= "function" then
        self:Error("Start requires a rotation callback")
        return false
    end

    self.state.rotationCallback = rotationCallback
    self.state.tickRate = tickRate or 0.075
    self.state.elapsedSinceTick = 0
    self.state.running = true
    self.state.pendingCast = nil
    self.state.lastGroundClick = nil
    self.state.groundClickTrace = {}

    if not self.state.frame then
        self.state.frame = CreateFrame("Frame")
    end

    self.state.frame:SetScript("OnUpdate", function(_, elapsed)
        if not Runtime.state.running or not Runtime.state.rotationCallback then
            return
        end

        Runtime.state.elapsedSinceTick = Runtime.state.elapsedSinceTick + elapsed
        Runtime:ProcessPendingCast()

        if Runtime.state.elapsedSinceTick < Runtime.state.tickRate then
            return
        end

        Runtime.state.elapsedSinceTick = 0
        Runtime:UpdateObjects()

        local ok, err = pcall(Runtime.state.rotationCallback)
        if not ok then
            Runtime:Error("Rotation error: " .. tostring(err))
        end
    end)

    self:UpdateObjects(true)
    return true
end

function Runtime:Stop()
    self.state.running = false
    self.state.pendingCast = nil
    if self.state.frame then
        self.state.frame:SetScript("OnUpdate", nil)
    end
    return true
end

DebugPrint("Runtime loaded")

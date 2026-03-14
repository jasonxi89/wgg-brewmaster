--[[
================================================================================
  Brewmaster Standalone - Pure WGG Brewmaster Rotation
  Version: 1.0.3

  Requires:
    - Warden framework
  Optional but recommended:
    - TankKnowledge_Standalone.lua
    - TankListEditor_Standalone.lua
    - BossAwareness_Standalone.lua
    - BossTimers_Standalone.lua

  Commands:
    /bm
    /bm start
    /bm stop
    /bm status
================================================================================
]]

local MODULE_VERSION = "2.1.3"

-- Capture WGG object at file top level (... only works here, not inside functions)
local _WGG_FROM_LOADER = ...
do
    local src = _WGG_FROM_LOADER or _G.WGG
    if src and type(src) ~= "string" then
        local aliases = {
            WGG_FileExists = "FileExists",
            WGG_FileRead = "FileRead",
            WGG_FileWrite = "FileWrite",
            WGG_DirExists = "DirExists",
            WGG_CreateDir = "CreateDir",
            WGG_JsonEncode = "JsonEncode",
        }
        for globalName, methodName in pairs(aliases) do
            if not _G[globalName] and type(src[methodName]) == "function" then
                _G[globalName] = src[methodName]
            end
        end
    end
end

local function Print(msg)
    print("|cFF00FFFF[Brewmaster]|r " .. tostring(msg))
end

local function Success(msg)
    print("|cFF00FF00[Brewmaster]|r " .. tostring(msg))
end

local function ErrorPrint(msg)
    print("|cFFFF5555[Brewmaster]|r " .. tostring(msg))
end

local function Bootstrap(attempt)
    attempt = attempt or 0

    if not _G.warden or not _G.warden.Spell then
        if C_Timer and C_Timer.After and attempt < 120 then
            C_Timer.After(0.5, function()
                local ok, err = pcall(Bootstrap, attempt + 1)
                if not ok then
                    print("|cFFFF5555[Brewmaster] Bootstrap error: " .. tostring(err) .. "|r")
                end
            end)
            return
        end

        ErrorPrint("Timed out waiting for warden framework")
        return
    end

    local warden = _G.warden
    local tickHandle = nil

    -- Warden compatibility helpers
    local function GetUnitToken(unit)
        if not unit then return nil end
        -- Try common tokens by matching GUID
        local guid = unit.guid
        if not guid then return nil end
        local tokens = {"target", "focus", "mouseover", "boss1", "boss2", "boss3", "boss4", "boss5"}
        for i = 1, 40 do tokens[#tokens+1] = "nameplate" .. i end
        for i = 1, 4 do tokens[#tokens+1] = "party" .. i end
        for i = 1, 40 do tokens[#tokens+1] = "raid" .. i end
        for _, token in ipairs(tokens) do
            if UnitGUID(token) == guid then return token end
        end
        return nil
    end

    local function IterateEnemies(callback)
        local list = warden.allEnemies or warden.enemies
        if not list then return end
        if list.loop then
            list.loop(callback)
        else
            for _, enemy in ipairs(list) do
                callback(enemy)
            end
        end
    end

    local function GetClosestEnemy(range)
        local closest, closestDist = nil, range or 35
        IterateEnemies(function(enemy)
            if enemy.exists and not enemy.dead and enemy.distance and enemy.distance < closestDist then
                closestDist = enemy.distance
                closest = enemy
            end
        end)
        return closest
    end

    local function GetEnemiesInRange(range)
        local result = {}
        IterateEnemies(function(enemy)
            if enemy.exists and not enemy.dead and enemy.distance and enemy.distance <= (range or 35) then
                result[#result + 1] = enemy
            end
        end)
        return result
    end

    local RotationInfo = {
        name = "BrewmasterStandalone",
        class = "MONK",
        spec = "Brewmaster",
        author = "WGG",
        version = MODULE_VERSION,
        description = "Pure WGG Brewmaster rotation with shared tank knowledge",
    }

    local DefaultConfig = {
        redStaggerHealthThreshold = 80,
        fortifyingBrewThreshold = 30,
        blackOxBrewHealthThreshold = 30,
        blackOxBrewPurifyChargesThreshold = 0.7,
        autoFaceTarget = false,
        kegSmashMaxRange = 10,
        kegSmashPullMinRange = 5,
        kegSmashPullMaxRange = 15,
        kegSmashPullEnergy = 60,
        comboKegSmashEnergy = 40,
        comboTigerPalmEnergy = 25,
        defaultKegSmashEnergy = 40,
        meleeRangeTolerance = 8.5,
        meleeFacingHalfArc = math.pi / 2,
        explodingKegClusterRadius = 8,
        burstNiuzaoWindow = 8,
        routineCelestialBrewHP = 80,
        routineCelestialInfusionHP = 75,
        invokeNiuzaoMinTTD = 20,
        invokeNiuzaoMinFlurryStacks = 30,
        interruptMaxRemaining = 0.8,
        spikeResponseWindow = 1.5,
        enablePullLogic = true,
        useProvokePull = true,
        useCracklingJadeLightningPull = true,
        useCombatProvoke = true,
        useBlackOxStatueAoETwitter = true,
        blackOxStatueTauntRadius = 8,
        blackOxStatueTauntMinEnemies = 2,
        useBlackOxBrew = true,
        useCelestialBrew = true,
        useCelestialInfusion = true,
        useBreathOfFire = true,
        useExplodingKeg = true,
        useInvokeNiuzao = true,
        useTouchOfDeath = true,
        useSpearHandStrike = true,
        useLegSweepInterrupt = true,
        interruptAll = true,
        autoManageStagger = true,
        maxTargetRange = 35,
    }

    local Config = {}
    for k, v in pairs(DefaultConfig) do
        Config[k] = v
    end

    local EXPLODING_KEG_SPELL_IDS = {325153, 214326}

    local function FindKnownSpellID(candidateSpellIDs)
        for _, spellID in ipairs(candidateSpellIDs or {}) do
            if (IsPlayerSpell and IsPlayerSpell(spellID)) or (IsSpellKnown and IsSpellKnown(spellID, false)) then
                return spellID
            end
        end

        return nil
    end

    local explodingKegSpellID = FindKnownSpellID(EXPLODING_KEG_SPELL_IDS) or EXPLODING_KEG_SPELL_IDS[1]

    local Spells = {
        BlackOxBrew = warden.Spell(115399, { beneficial = true, ignoreFacing = true, ignoreGCD = true }),
        KegSmash = warden.Spell(121253, { targeted = true, damage = "physical" }),
        InvokeNiuzao = warden.Spell(132578, { beneficial = true, ignoreFacing = true }),
        TouchOfDeath = warden.Spell(322109, { targeted = true, damage = "physical" }),
        BlackoutKick = warden.Spell(205523, { targeted = true, damage = "physical" }),
        CelestialBrew = warden.Spell(322507, { beneficial = true, ignoreFacing = true }),
        CelestialInfusion = warden.Spell(1241059, { beneficial = true, ignoreFacing = true }),
        BreathOfFire = warden.Spell(115181, { targeted = true, damage = "fire" }),
        ExplodingKeg = warden.Spell(explodingKegSpellID, { damage = "physical", radius = 8 }),
        ChiBurst = warden.Spell(123986, { targeted = true, damage = "magic" }),
        TigerPalm = warden.Spell(100780, { targeted = true, damage = "physical" }),
        PurifyingBrew = warden.Spell(119582, { beneficial = true, ignoreFacing = true, ignoreGCD = true }),
        FortifyingBrew = warden.Spell(115203, { beneficial = true, ignoreFacing = true, ignoreGCD = true }),
        Provoke = warden.Spell(115546, { targeted = true, ignoreGCD = true }),
        CracklingJadeLightning = warden.Spell(117952, { targeted = true, damage = "magic" }),
        SpearHandStrike = warden.Spell(116705, { targeted = true, interrupt = true, ignoreMoving = true, ignoreGCD = true }),
        LegSweep = warden.Spell(119381, { cc = "stun", ignoreFacing = true }),
    }

    local function RefreshExplodingKegSpell()
        local resolvedSpellID = FindKnownSpellID(EXPLODING_KEG_SPELL_IDS)
        if not resolvedSpellID then
            return false
        end

        if Spells.ExplodingKeg.id ~= resolvedSpellID then
            Spells.ExplodingKeg.id = resolvedSpellID
        end

        if C_Spell and C_Spell.GetSpellName then
            Spells.ExplodingKeg.name = C_Spell.GetSpellName(resolvedSpellID) or Spells.ExplodingKeg.name
        elseif GetSpellInfo then
            Spells.ExplodingKeg.name = GetSpellInfo(resolvedSpellID) or Spells.ExplodingKeg.name
        end

        return true
    end

    local BLACKOUT_COMBO_BUFF = 228563
    local BREATH_OF_FIRE_DOT = 123725
    local SOBER_BUFF = 215479
    local FLURRY_STRIKES_BUFF = 470670
    local BLACK_OX_STATUE_NPC_IDS = {
        [61146] = true,
        [61305] = true,
    }

    local StateCache = {
        lastUpdate = 0,
        updateInterval = 0.03,
        playerHP = 100,
        playerMaxHP = 1,
        playerEnergy = 0,
        playerMaxEnergy = 100,
        playerInCombat = false,
        playerCasting = false,
        playerChanneling = false,
        staggerAmount = 0,
        staggerPercent = 0,
        isHeavyStagger = false,
        isMediumStagger = false,
        hasBlackoutCombo = false,
        hasSoberBuff = false,
        hasBreathOfFireDot = false,
        flurryStrikesStacks = 0,
        flurryTrackingAvailable = false,
        purifyingBrewCharges = 0,
        purifyingBrewFractionalCharges = 0,
        kegSmashCharges = 0,
        kegSmashMaxCharges = 1,
        kegSmashFractionalCharges = 0,
        targetExists = false,
        targetHP = 100,
        targetHealthAbs = 0,
        targetIsEnemy = false,
        targetIsDead = false,
        targetDistance = math.huge,
        targetTTD = math.huge,
        enemiesInMelee = 0,
        enemiesIn8y = 0,
        enemiesIn10y = 0,
        hasBlackoutComboTalent = false,
        hasChiBurstTalent = false,
        hasExplodingKegTalent = false,
        hasInvokeNiuzaoTalent = false,
        hasBlackOxBrewTalent = false,
        hasCelestialBrewTalent = false,
        hasCelestialInfusionTalent = false,
        hasBreathOfFireTalent = false,
    }

    local talentsDetected = false
    -- (pendingBreathAfterKegSmash removed: BoF is now independent priority)
    local TTDHistory = {}
    local running = false
    local lastTalentCheck = 0
    local IsTargetInMeleeRange
    local ShouldUseSpikeFallbackPurifying
    local burstNiuzaoPending = false
    local burstNiuzaoWindowExpiresAt = 0
    local lastCombatState = false
    local toggleButton = nil
    local togglePanel = nil

    local function SetBackdrop(frame, bgColor, borderColor)
        if not frame or type(frame.SetBackdrop) ~= "function" then
            return
        end

        frame:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true,
            tileSize = 16,
            edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })

        local bg = bgColor or {0.06, 0.06, 0.07, 0.96}
        local border = borderColor or {0.22, 0.22, 0.24, 1}
        frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
        frame:SetBackdropBorderColor(border[1], border[2], border[3], border[4] or 1)
    end

    local Logger = {
        config = {
            enabled = true,
            exportInterval = 0.25,
            maxEntries = 2500,
            realtimeMaxEntries = 200,
            blockedThrottle = 0.4,
            stallThrottle = 0.5,
            logDir = "C:\\WGG\\logs\\",
            realtimeFile = "brewmaster_standalone_realtime.json",
            lastCombatFile = "brewmaster_standalone_last_combat.json",
            fallbackRealtimeFile = "C:\\WGG\\brewmaster_standalone_realtime.json",
            fallbackCombatFile = "C:\\WGG\\brewmaster_standalone_last_combat.json",
        },
        entries = {},
        sessionId = "unknown",
        sessionStart = 0,
        lastFlush = 0,
        lastBlockedByKey = {},
        lastStallAt = 0,
        inCombat = false,
        combatStartedAt = 0,
        dirty = false,
        flushElapsed = 0,
        flushFrame = nil,
        lastRealtimePath = nil,
        lastCombatPath = nil,
        lastWritePath = nil,
        lastWriteOk = true,
        lastWriteError = nil,
    }

    local function RoundNumber(value, decimals)
        if type(value) ~= "number" then
            return value
        end

        local factor = 10 ^ (decimals or 0)
        return math.floor((value * factor) + 0.5) / factor
    end

    local function MergeTables(base, extra)
        if type(extra) ~= "table" then
            return base
        end

        for key, value in pairs(extra) do
            base[key] = value
        end

        return base
    end

    local function IsExternalSpellPending()
        if warden and warden.IsGroundCursorPending then
            local ok, pending = pcall(function()
                return warden.IsGroundCursorPending()
            end)
            if ok then
                return pending == true
            end
        end

        if SpellIsTargeting and SpellIsTargeting() then
            return true
        end

        return false
    end

    local function NormalizeAngle(angle)
        if type(angle) ~= "number" then
            return nil
        end

        local fullCircle = 2 * math.pi
        angle = angle % fullCircle
        if angle < 0 then
            angle = angle + fullCircle
        end
        return angle
    end

    local function GetFacingDeltaToTarget(target)
        if not target or not target.exists or not (warden and warden.player) then
            return nil
        end

        local player = warden and warden.player or nil
        if not player or not player.exists then
            return nil
        end

        local playerX, playerY = player.x, player.y
        local targetX, targetY = target.x, target.y
        local playerFacing = NormalizeAngle((warden.player.rotation or 0))
        if not playerX or not playerY or not targetX or not targetY or not playerFacing then
            return nil
        end

        local angleToTarget = NormalizeAngle(math.atan2(targetY - playerY, targetX - playerX))
        if not angleToTarget then
            return nil
        end

        local angleDiff = math.abs(angleToTarget - playerFacing)
        if angleDiff > math.pi then
            angleDiff = (2 * math.pi) - angleDiff
        end
        return angleDiff
    end

    local function IsFacingTarget(target, halfArc)
        local angleDiff = GetFacingDeltaToTarget(target)
        if angleDiff == nil then
            return true, nil
        end

        local allowedHalfArc = tonumber(halfArc) or tonumber(Config.meleeFacingHalfArc) or (math.pi / 2)
        return angleDiff <= allowedHalfArc, angleDiff
    end

    local function RequiresFacingCheck(spell)
        if not spell or not spell.id then
            return false
        end

        return spell.id == Spells.BlackoutKick.id
            or spell.id == Spells.TigerPalm.id
            or spell.id == Spells.KegSmash.id
            or spell.id == Spells.BreathOfFire.id
            or spell.id == Spells.TouchOfDeath.id
    end

    local function JsonEscapeString(value)
        value = tostring(value or "")
        value = value:gsub("\\", "\\\\")
        value = value:gsub('"', '\\"')
        value = value:gsub("\r", "\\r")
        value = value:gsub("\n", "\\n")
        value = value:gsub("\t", "\\t")
        return '"' .. value .. '"'
    end

    local function IsSequentialArray(value)
        if type(value) ~= "table" then
            return false
        end

        local maxIndex = 0
        local count = 0
        for key in pairs(value) do
            if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
                return false
            end
            if key > maxIndex then
                maxIndex = key
            end
            count = count + 1
        end

        return maxIndex == count
    end

    local function EncodeJSONFallback(value)
        local valueType = type(value)
        if valueType == "string" then
            return JsonEscapeString(value)
        end

        if valueType == "number" or valueType == "boolean" then
            return tostring(value)
        end

        if value == nil then
            return "null"
        end

        if valueType ~= "table" then
            return JsonEscapeString(tostring(value))
        end

        local parts = {}
        if IsSequentialArray(value) then
            for index = 1, #value do
                parts[#parts + 1] = EncodeJSONFallback(value[index])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end

        for key, child in pairs(value) do
            parts[#parts + 1] = JsonEscapeString(tostring(key)) .. ":" .. EncodeJSONFallback(child)
        end

        return "{" .. table.concat(parts, ",") .. "}"
    end

    local function EncodeJSON(value)
        if type(_G.WGG_JsonEncode) == "function" then
            local ok, encoded = pcall(_G.WGG_JsonEncode, value)
            if ok and type(encoded) == "string" and encoded ~= "" then
                return encoded
            end
        end

        return EncodeJSONFallback(value)
    end

    function Logger:EnsureDirectory()
        if type(_G.WGG_DirExists) == "function" then
            local ok, exists = pcall(_G.WGG_DirExists, self.config.logDir)
            if ok and exists then
                return true
            end
        end

        if type(_G.WGG_CreateDir) == "function" then
            pcall(_G.WGG_CreateDir, self.config.logDir)
        end

        if type(_G.WGG_DirExists) == "function" then
            local ok, exists = pcall(_G.WGG_DirExists, self.config.logDir)
            if ok and exists then
                return true
            end
        end

        return false
    end

    function Logger:GetRealtimePath()
        if self:EnsureDirectory() then
            return self.config.logDir .. self.config.realtimeFile
        end

        return self.config.fallbackRealtimeFile
    end

    function Logger:GetLastCombatPath()
        if self:EnsureDirectory() then
            return self.config.logDir .. self.config.lastCombatFile
        end

        return self.config.fallbackCombatFile
    end

    function Logger:PeekRealtimePath()
        return self.lastRealtimePath or (self.config.logDir .. self.config.realtimeFile)
    end

    function Logger:PeekLastCombatPath()
        return self.lastCombatPath or (self.config.logDir .. self.config.lastCombatFile)
    end

    function Logger:EnsureFlushFrame()
        if type(CreateFrame) ~= "function" then
            return nil
        end

        local frame = _G.WGG_BrewmasterStandaloneLogFlushFrame
        if not frame or type(frame.SetScript) ~= "function" then
            frame = CreateFrame("Frame", "WGG_BrewmasterStandaloneLogFlushFrame", UIParent)
        end

        frame:SetScript("OnUpdate", function(_, elapsed)
            if not Logger.config.enabled or not Logger.dirty then
                Logger.flushElapsed = 0
                return
            end

            Logger.flushElapsed = (Logger.flushElapsed or 0) + (elapsed or 0)
            if Logger.flushElapsed >= Logger.config.exportInterval then
                Logger.flushElapsed = 0
                Logger:Flush(true, nil, Logger.config.realtimeMaxEntries)
            end
        end)

        self.flushFrame = frame
        return frame
    end

    function Logger:ResetSession()
        self.entries = {}
        self.sessionId = date and date("%Y%m%d_%H%M%S") or tostring(math.floor((GetTime() or 0) * 1000))
        self.sessionStart = GetTime() or 0
        self.lastFlush = 0
        self.lastBlockedByKey = {}
        self.lastStallAt = 0
        self.inCombat = false
        self.combatStartedAt = 0
        self.dirty = false
        self.flushElapsed = 0
        self.lastWriteOk = true
        self.lastWriteError = nil
        self:EnsureFlushFrame()
    end

    function Logger:TrimEntries()
        local entryCount = #self.entries
        local overflow = entryCount - self.config.maxEntries
        if overflow <= 0 then
            return
        end

        local trimmed = {}
        for index = overflow + 1, entryCount do
            trimmed[#trimmed + 1] = self.entries[index]
        end

        self.entries = trimmed
    end

    function Logger:BuildTargetSnapshot(target)
        if not target or not target.exists then
            return nil
        end

        local token = GetUnitToken(target)
        local castName = nil
        local facingOk, facingDelta = IsFacingTarget(target)
        if token then
            castName = select(1, UnitCastingInfo(token)) or select(1, UnitChannelInfo(token))
        end

        return {
            token = token or "none",
            name = token and (UnitName(token) or "Unknown") or "Unknown",
            guid = target.guid or "none",
            distance = RoundNumber(target.distance, 2),
            hpPercent = RoundNumber(target.hp, 1),
            dead = target.dead or false,
            enemy = target.enemy or false,
            castingSpell = castName,
            facingOk = facingOk,
            facingDelta = RoundNumber(facingDelta, 3),
        }
    end

    function Logger:BuildSnapshot(target)
        local player = warden and warden.player or nil
        local px, py, pz = nil, nil, nil
        if player and player.exists then
            px, py, pz = player.x, player.y, player.z
        end

        local castDelayRemaining = 0
        local gcdRemaining = 0
        local gcdDuration = 0
        local gcdModRate = 1
        local runtimePendingCast = nil
        local runtimeGroundClick = nil
        local pendingCursor = IsExternalSpellPending()
        if warden and warden.state and warden.config then
            castDelayRemaining = math.max(0, (warden.config.minCastDelay or 0) - ((GetTime() or 0) - (warden.state.lastCastTime or 0)))
        end
        if warden and warden.GetGCDInfo then
            local gcdInfo = warden.GetGCDInfo()
            gcdRemaining = gcdInfo.remaining or 0
            if gcdInfo.duration and gcdInfo.duration > 0 then
                gcdDuration = gcdInfo.duration
                gcdModRate = gcdInfo.modRate or 1
            else
                gcdDuration = gcdInfo.lastKnownDuration or 0
                gcdModRate = gcdInfo.lastKnownModRate or 1
            end
        elseif warden and warden.GetGCD then
            gcdRemaining = warden.GetGCD()
        end
        if warden and warden.GetPendingCastInfo then
            runtimePendingCast = warden.GetPendingCastInfo()
        end
        if warden and warden.GetLastGroundClickDebug then
            runtimeGroundClick = warden.GetLastGroundClickDebug()
        end

        return {
            running = running,
            pending = pendingCursor or runtimePendingCast ~= nil,
            pendingCursor = pendingCursor,
            pendingCast = runtimePendingCast,
            groundPending = runtimePendingCast and runtimePendingCast.castType == "ground" or false,
            groundClick = runtimeGroundClick and {
                method = runtimeGroundClick.method,
                reason = runtimeGroundClick.reason,
                worldX = RoundNumber(runtimeGroundClick.worldX, 1),
                worldY = RoundNumber(runtimeGroundClick.worldY, 1),
                worldZ = RoundNumber(runtimeGroundClick.worldZ, 1),
                screenX = RoundNumber(runtimeGroundClick.screenX, 1),
                screenY = RoundNumber(runtimeGroundClick.screenY, 1),
                ndcX = RoundNumber(runtimeGroundClick.ndcX, 3),
                ndcY = RoundNumber(runtimeGroundClick.ndcY, 3),
                pendingSpellId = runtimeGroundClick.pendingSpellId,
                attempt = runtimeGroundClick.attempt,
                age = RoundNumber(runtimeGroundClick.age, 3),
            } or nil,
            player = {
                hp = UnitHealth("player") or 0,
                hpMax = StateCache.playerMaxHP or (UnitHealthMax("player") or 1),
                hpPercent = RoundNumber(StateCache.playerHP, 1),
                energy = StateCache.playerEnergy,
                energyMax = StateCache.playerMaxEnergy,
                staggerPercent = RoundNumber(StateCache.staggerPercent, 1),
                heavyStagger = StateCache.isHeavyStagger,
                mediumStagger = StateCache.isMediumStagger,
                casting = StateCache.playerCasting,
                channeling = StateCache.playerChanneling,
                moving = (GetUnitSpeed and ((GetUnitSpeed("player") or 0) > 0)) or false,
                facing = RoundNumber(warden and warden.player and (warden.player.rotation or 0) or nil, 2),
                castDelayRemaining = RoundNumber(castDelayRemaining, 3),
                gcdDuration = RoundNumber(gcdDuration, 3),
                gcdModRate = RoundNumber(gcdModRate, 3),
                gcdRemaining = RoundNumber(gcdRemaining, 3),
                x = RoundNumber(px, 1),
                y = RoundNumber(py, 1),
                z = RoundNumber(pz, 1),
            },
            target = self:BuildTargetSnapshot(target),
            resources = {
                kegCharges = StateCache.kegSmashCharges,
                kegFractional = RoundNumber(StateCache.kegSmashFractionalCharges, 2),
                purifyCharges = RoundNumber(StateCache.purifyingBrewFractionalCharges, 2),
                enemiesInMelee = StateCache.enemiesInMelee,
                enemiesIn8y = StateCache.enemiesIn8y,
                enemiesIn10y = StateCache.enemiesIn10y,
                hasSoberBuff = StateCache.hasSoberBuff,
                hasBreathOfFireDot = StateCache.hasBreathOfFireDot,
            },
        }
    end

    function Logger:BuildExport(limit)
        local logs = self.entries
        if type(limit) == "number" and limit > 0 and #logs > limit then
            logs = {}
            local startIndex = (#self.entries - limit) + 1
            for index = startIndex, #self.entries do
                logs[#logs + 1] = self.entries[index]
            end
        end

        return {
            meta = {
                version = MODULE_VERSION,
                sessionId = self.sessionId,
                sessionStart = self.sessionStart,
                now = GetTime() or 0,
                totalEntries = #self.entries,
                exportedEntries = #logs,
                running = running,
                inCombat = self.inCombat,
            },
            logs = logs,
        }
    end

    function Logger:Flush(force, path, limit)
        if type(_G.WGG_FileWrite) ~= "function" then
            self.lastWriteOk = false
            self.lastWriteError = "WGG_FileWrite unavailable"
            self.lastWritePath = path or self:PeekRealtimePath()
            return false, nil, "WGG_FileWrite unavailable"
        end

        if not force and not self.dirty then
            return true, path or self:GetRealtimePath(), nil
        end

        local now = GetTime() or 0
        if not force and (now - (self.lastFlush or 0)) < self.config.exportInterval then
            return false, path or self:GetRealtimePath(), "throttled"
        end

        self:TrimEntries()
        local fullPath = path or self:GetRealtimePath()
        local ok, writeResult = pcall(_G.WGG_FileWrite, fullPath, EncodeJSON(self:BuildExport(limit)))
        if not ok or not writeResult then
            self.lastWriteOk = false
            self.lastWriteError = ok and "write_failed" or tostring(writeResult)
            self.lastWritePath = fullPath
            return false, fullPath, ok and "write_failed" or tostring(writeResult)
        end

        self.lastFlush = now
        self.dirty = false
        self.lastWriteOk = true
        self.lastWriteError = nil
        self.lastWritePath = fullPath
        if fullPath == self:GetRealtimePath() then
            self.lastRealtimePath = fullPath
        elseif fullPath == self:GetLastCombatPath() then
            self.lastCombatPath = fullPath
        end

        return true, fullPath, nil
    end

    function Logger:Log(category, message, data, target, forceFlush)
        if not self.config.enabled then
            return
        end

        if self.sessionStart == 0 then
            self:ResetSession()
        end

        local entry = {
            timestamp = GetTime() or 0,
            sessionTime = (GetTime() or 0) - (self.sessionStart or 0),
            category = category,
            message = message,
            data = data or {},
            snapshot = self:BuildSnapshot(target),
        }

        self.entries[#self.entries + 1] = entry
        self.dirty = true
        if forceFlush == true then
            self:Flush(true, nil, self.config.realtimeMaxEntries)
        end
    end

    function Logger:LogBlocked(spell, target, context, reason, extra)
        if not self.config.enabled then
            return
        end

        local key = table.concat({
            tostring(spell and spell.id or "unknown"),
            tostring(context or "unknown"),
            tostring(reason or "unknown"),
        }, ":")

        local now = GetTime() or 0
        local lastLoggedAt = self.lastBlockedByKey[key] or 0
        if (now - lastLoggedAt) < self.config.blockedThrottle then
            return
        end

        self.lastBlockedByKey[key] = now
        self:Log("spell_blocked", spell and spell.name or "Unknown", MergeTables({
            context = context,
            spellId = spell and spell.id or 0,
            spellName = spell and spell.name or "Unknown",
            reason = reason or "unknown",
        }, extra), target)
    end

    function Logger:HandleCombatState(target)
        if not self.config.enabled then
            return
        end

        if StateCache.playerInCombat and not self.inCombat then
            self.inCombat = true
            self.combatStartedAt = GetTime() or 0
            self:Log("combat", "Combat started", {}, target, true)
        elseif not StateCache.playerInCombat and self.inCombat then
            local duration = (GetTime() or 0) - (self.combatStartedAt or 0)
            self.inCombat = false
            self.combatStartedAt = 0
            self:Log("combat", "Combat ended", {
                duration = RoundNumber(duration, 2),
            }, target, true)
            self:Flush(true, self:GetLastCombatPath())
        end
    end

    function Logger:GetStatus()
        return {
            enabled = self.config.enabled,
            entries = #self.entries,
            realtimePath = self:PeekRealtimePath(),
            lastCombatPath = self:PeekLastCombatPath(),
            sessionId = self.sessionId,
            lastWriteOk = self.lastWriteOk,
            lastWriteError = self.lastWriteError,
            lastWritePath = self.lastWritePath,
        }
    end

    Logger:ResetSession()

    local function GetTankKnowledge()
        return _G.WGG_TankKnowledge
    end

    local function GetBossAwareness()
        return _G.BossAwareness
    end

    local function GetBossTimers()
        return _G.BossTimers
    end

    local function BuildActionData(spell, context, extra)
        return MergeTables({
            context = context,
            spellId = spell and spell.id or 0,
            spellName = spell and spell.name or "Unknown",
        }, extra)
    end

    local function GetSpellGate(spell, target)
        local castable, reason = spell:Castable(target)
        return {
            canCast = castable == true,
            reason = reason,
            cooldown = RoundNumber(spell.cd, 2),
        }
    end

    local function LogSpellIssued(spell, target, context, extra)
        local runtimePendingCast = warden and warden.GetPendingCastInfo and warden.GetPendingCastInfo() or nil
        Logger:Log("spell_issued", spell and spell.name or "Unknown", MergeTables(
            BuildActionData(spell, context, extra),
            runtimePendingCast and {pendingCast = runtimePendingCast} or nil
        ), target)
    end

    local function TryTargetCast(spell, target, context, extra)
        if target and RequiresFacingCheck(spell) then
            local facingOk, facingDelta = IsFacingTarget(target)
            if facingOk == false then
                local facingData = MergeTables({
                    facingDelta = RoundNumber(facingDelta, 3),
                    allowedHalfArc = RoundNumber(tonumber(Config.meleeFacingHalfArc) or (math.pi / 2), 3),
                }, extra)
                Logger:LogBlocked(spell, target, context, "bad_facing", facingData)
                return false, "bad_facing"
            end
        end

        local castable, reason = spell:Castable(target)
        if not castable then
            Logger:LogBlocked(spell, target, context, reason, extra)
            return false, reason
        end

        if spell:Cast(target) then
            LogSpellIssued(spell, target, context, extra)
            return true, nil
        end

        Logger:LogBlocked(spell, target, context, "cast_returned_false", extra)
        return false, "cast_returned_false"
    end

    local function TrySelfCast(spell, context, extra)
        local castable, reason = spell:Castable()
        if not castable then
            Logger:LogBlocked(spell, warden.player, context, reason, extra)
            return false, reason
        end

        if spell:Cast() then
            LogSpellIssued(spell, warden.player, context, extra)
            return true, nil
        end

        Logger:LogBlocked(spell, warden.player, context, "self_cast_returned_false", extra)
        return false, "self_cast_returned_false"
    end

    local function TryGroundCast(spell, target, x, y, z, context, extra)
        local castable, reason = spell:Castable(target)
        if not castable then
            Logger:LogBlocked(spell, target, context, reason, extra)
            return false, reason
        end

        if type(spell.AoECast) ~= "function" then
            Logger:LogBlocked(spell, target, context, "aoe_cast_unavailable", extra)
            return false, "aoe_cast_unavailable"
        end

        local casted, aoeReason = spell:AoECast(x, y, z, target)
        if casted then
            LogSpellIssued(spell, target, context, MergeTables({
                groundPosition = {
                    x = RoundNumber(x, 1),
                    y = RoundNumber(y, 1),
                    z = RoundNumber(z, 1),
                },
            }, extra))
            return true, nil
        end

        Logger:LogBlocked(spell, target, context, aoeReason or "aoe_cast_returned_false", extra)
        return false, aoeReason or "aoe_cast_returned_false"
    end

    local function LogStall(target, context, extra)
        if not Logger.config.enabled then
            return
        end

        local now = GetTime() or 0
        if (now - (Logger.lastStallAt or 0)) < Logger.config.stallThrottle then
            return
        end

        Logger.lastStallAt = now
        Logger:Log("stall", "No action selected", MergeTables({
            context = context,
            kegSmash = GetSpellGate(Spells.KegSmash, target),
            breathOfFire = StateCache.hasBreathOfFireTalent and GetSpellGate(Spells.BreathOfFire, target) or nil,
            blackoutKick = GetSpellGate(Spells.BlackoutKick, target),
            tigerPalm = GetSpellGate(Spells.TigerPalm, target),
            explodingKeg = StateCache.hasExplodingKegTalent and GetSpellGate(Spells.ExplodingKeg, target) or nil,
            invokeNiuzao = StateCache.hasInvokeNiuzaoTalent and GetSpellGate(Spells.InvokeNiuzao) or nil,
        }, extra), target)
    end

    local function IsDead(unit)
        if not unit or not unit.exists then
            return true
        end
        return unit.dead
    end

    local function IsEnemy(unit)
        return unit and unit.exists and unit.enemy and not IsDead(unit)
    end

    local function GetExplodingKegCastPosition(target)
        if not IsEnemy(target) then
            return nil
        end

        local targetX, targetY, targetZ = target.x, target.y, target.z
        if not targetX or not targetY or not targetZ then
            return nil
        end

        local clusterRadius = tonumber(Config.explodingKegClusterRadius) or 8
        local requireCombat = target.combat
        local sumX, sumY, sumZ = 0, 0, 0
        local count = 0

        IterateEnemies(function(enemy)
            if IsEnemy(enemy) then
                local nearTarget = enemy.distanceTo and enemy.distanceTo(target)
                if nearTarget and nearTarget <= clusterRadius and (not requireCombat or enemy.combat) then
                    local ex, ey, ez = enemy.x, enemy.y, enemy.z
                    if ex and ey and ez then
                        sumX = sumX + ex
                        sumY = sumY + ey
                        sumZ = sumZ + ez
                        count = count + 1
                    end
                end
            end
        end)

        if count < 1 then
            return targetX, targetY, targetZ, 1
        end

        return sumX / count, sumY / count, sumZ / count, count
    end

    local lastExplodingKegPos = nil  -- {x, y, z, time} for draw overlay

    local function CastExplodingKeg(target, context)
        local x, y, z, clusterCount = GetExplodingKegCastPosition(target)
        if not x or not y or not z then
            Logger:LogBlocked(Spells.ExplodingKeg, target, context or "exploding_keg", "no_ground_position")
            return false, "no_ground_position"
        end

        local casted = TryGroundCast(Spells.ExplodingKeg, target, x, y, z, context or "exploding_keg", {
            clusterCount = clusterCount or 1,
        })
        if casted then
            lastExplodingKegPos = { x = x, y = y, z = z, time = GetTime() }
        end
        return casted
    end

    local function DetectTalents()
        StateCache.hasBlackoutComboTalent = IsPlayerSpell(196736)
        StateCache.hasChiBurstTalent = IsPlayerSpell(123986) or IsPlayerSpell(460485)
        StateCache.hasExplodingKegTalent = RefreshExplodingKegSpell()
        StateCache.hasInvokeNiuzaoTalent = IsPlayerSpell(132578)
        StateCache.hasBlackOxBrewTalent = IsPlayerSpell(115399)
        StateCache.hasCelestialBrewTalent = IsPlayerSpell(322507)
        StateCache.hasCelestialInfusionTalent = IsPlayerSpell(1241059)
        StateCache.hasBreathOfFireTalent = IsPlayerSpell(115181)
    end

    local function GetFractionalSpellCharges(spellOrId)
        local spellID = type(spellOrId) == "table" and spellOrId.id or spellOrId
        local spellObj = type(spellOrId) == "table" and spellOrId or nil
        local charges, maxCharges = 0, 1
        local startTime, duration, modRate = 0, 0, 1
        local hasChargeInfo = false

        if C_Spell and C_Spell.GetSpellCharges and spellID then
            local info = C_Spell.GetSpellCharges(spellID)
            if info then
                charges = info.currentCharges or 0
                maxCharges = info.maxCharges or 1
                startTime = info.cooldownStartTime or info.chargeStart or 0
                duration = info.cooldownDuration or info.chargeDuration or 0
                modRate = info.chargeModRate or 1
                hasChargeInfo = true
            end
        elseif GetSpellCharges and spellID then
            charges, maxCharges, startTime, duration, modRate = GetSpellCharges(spellID)
            hasChargeInfo = charges ~= nil or maxCharges ~= nil
            charges = charges or 0
            maxCharges = maxCharges or 1
            startTime = startTime or 0
            duration = duration or 0
            modRate = modRate or 1
        end

        if not hasChargeInfo then
            local currentCharges = 1
            local fractionalCharges = 1
            if spellObj and spellObj.cd > 0 then
                currentCharges = 0
                local cooldown = spellObj.cd
                local cooldownDuration = spellObj.cdduration
                if cooldownDuration and cooldownDuration > 0 then
                    fractionalCharges = math.max(0, math.min(1, 1 - (cooldown / cooldownDuration)))
                else
                    fractionalCharges = 0
                end
            end
            return fractionalCharges, 1, currentCharges
        end

        local fractionalCharges = charges
        if maxCharges > 0 and charges < maxCharges and startTime > 0 and duration > 0 then
            local elapsed = (GetTime() - startTime) * modRate
            fractionalCharges = charges + math.max(0, math.min(1, elapsed / duration))
        end

        return fractionalCharges, maxCharges, charges
    end

    local function UpdateTargetTTD(target)
        if not target or not target.exists or target.dead then
            return 0
        end

        local guid = target.guid
        local currentHealth = target.health
        if not guid or guid == "" or currentHealth <= 0 then
            return math.huge
        end

        local now = GetTime()
        local history = TTDHistory[guid]
        if not history then
            history = {samples = {}}
            TTDHistory[guid] = history
        end

        local samples = history.samples
        if #samples == 0 or (now - samples[#samples].time) >= 0.25 then
            samples[#samples + 1] = {time = now, health = currentHealth}
        else
            samples[#samples].time = now
            samples[#samples].health = currentHealth
        end

        while #samples > 12 do
            table.remove(samples, 1)
        end

        while #samples > 0 and (now - samples[1].time) > 6 do
            table.remove(samples, 1)
        end

        if #samples < 2 then
            return math.huge
        end

        local oldest = samples[1]
        local newest = samples[#samples]
        local elapsed = newest.time - oldest.time
        local damageDone = oldest.health - newest.health
        if elapsed <= 0.25 or damageDone <= 0 then
            return math.huge
        end

        local dps = damageDone / elapsed
        if dps <= 0 then
            return math.huge
        end

        return newest.health / dps
    end

    local function GetBestTarget()
        -- Only use current target if it's a living enemy in range
        if warden.target and IsEnemy(warden.target) and (warden.target.distance or math.huge) <= Config.maxTargetRange then
            return warden.target
        end

        -- No valid enemy target (target is self, friendly, dead, or no target) → don't auto-select
        return nil
    end

    local function UpdateStateCache(activeTarget)
        local currentTime = GetTime()
        if currentTime - StateCache.lastUpdate < StateCache.updateInterval then
            return
        end

        if not talentsDetected or (currentTime - lastTalentCheck) >= 5 then
            DetectTalents()
            talentsDetected = true
            lastTalentCheck = currentTime
        end

        local player = warden.player
        local target = activeTarget

        if player and player.exists then
            StateCache.playerHP = player.hp
            StateCache.playerMaxHP = player.hpmax
            StateCache.playerEnergy = UnitPower("player", 3)
            StateCache.playerMaxEnergy = UnitPowerMax("player", 3)
            StateCache.playerInCombat = player.combat
            StateCache.playerCasting = UnitCastingInfo("player") ~= nil
            StateCache.playerChanneling = UnitChannelInfo("player") ~= nil
            StateCache.hasBlackoutCombo = player.buff(BLACKOUT_COMBO_BUFF) or false
            StateCache.hasSoberBuff = player.buff(SOBER_BUFF) or false
            StateCache.flurryStrikesStacks = player.buffStacks(FLURRY_STRIKES_BUFF) or 0
            StateCache.flurryTrackingAvailable = StateCache.flurryStrikesStacks > 0 or (player.buff(FLURRY_STRIKES_BUFF) or false)
            StateCache.staggerAmount = UnitStagger and (UnitStagger("player") or 0) or 0
            StateCache.staggerPercent = StateCache.playerMaxHP > 0 and (StateCache.staggerAmount / StateCache.playerMaxHP * 100) or 0
            StateCache.isHeavyStagger = StateCache.staggerPercent > 60
            StateCache.isMediumStagger = StateCache.staggerPercent > 30 and StateCache.staggerPercent <= 60
            StateCache.purifyingBrewFractionalCharges, _, StateCache.purifyingBrewCharges = GetFractionalSpellCharges(Spells.PurifyingBrew)
            StateCache.kegSmashFractionalCharges, StateCache.kegSmashMaxCharges, StateCache.kegSmashCharges = GetFractionalSpellCharges(Spells.KegSmash)
        end

        if target and target.exists then
            StateCache.targetExists = true
            StateCache.targetHP = target.hp
            StateCache.targetHealthAbs = target.health
            StateCache.targetIsEnemy = target.enemy
            StateCache.targetIsDead = IsDead(target)
            StateCache.targetDistance = target.distance or math.huge
            if not StateCache.targetIsDead then
                StateCache.hasBreathOfFireDot = target.debuff(BREATH_OF_FIRE_DOT) or false
                StateCache.targetTTD = UpdateTargetTTD(target)
            else
                StateCache.hasBreathOfFireDot = false
                StateCache.targetTTD = 0
            end
        else
            StateCache.targetExists = false
            StateCache.targetHP = 100
            StateCache.targetHealthAbs = 0
            StateCache.targetIsEnemy = false
            StateCache.targetIsDead = false
            StateCache.targetDistance = math.huge
            StateCache.targetTTD = math.huge
            StateCache.hasBreathOfFireDot = false
        end

        StateCache.enemiesInMelee = 0
        StateCache.enemiesIn8y = 0
        StateCache.enemiesIn10y = 0
        IterateEnemies(function(enemy)
            if enemy.exists and not IsDead(enemy) then
                local dist = enemy.distance
                if dist then
                    if IsTargetInMeleeRange(enemy) then
                        StateCache.enemiesInMelee = StateCache.enemiesInMelee + 1
                    end

                    if dist <= 10 then
                        StateCache.enemiesIn10y = StateCache.enemiesIn10y + 1
                        if dist <= 8 then
                            StateCache.enemiesIn8y = StateCache.enemiesIn8y + 1
                        end
                    end
                end
            end
        end)


        StateCache.lastUpdate = currentTime
    end

    local function FaceTarget(target, maxDistance)
        if not target or not target.exists then
            return
        end

        if not Config.autoFaceTarget then
            return
        end

        local canFaceRaw = type(_G.WGG_SetFacingRaw) == "function"
        local canFaceXYZ = type(_G.WGG_SetFacing) == "function"
        if not (warden and warden.player) or (not canFaceRaw and not canFaceXYZ) then
            return
        end

        local distance = target.distance
        if maxDistance and distance and distance > maxDistance then
            return
        end

        local playerFacing = (warden.player.rotation or 0)
        local targetX, targetY, targetZ = target.x, target.y, target.z
        local playerX, playerY = nil, nil
        if warden.player then
            playerX, playerY = warden.player.x, warden.player.y
        end
        if not playerFacing or not targetX or not targetY or not playerX or not playerY then
            return
        end

        local angleToTarget = math.atan2(targetY - playerY, targetX - playerX)
        if angleToTarget < 0 then
            angleToTarget = angleToTarget + (2 * math.pi)
        end
        if playerFacing < 0 then
            playerFacing = playerFacing + (2 * math.pi)
        end

        local angleDiff = math.abs(angleToTarget - playerFacing)
        if angleDiff > math.pi then
            angleDiff = (2 * math.pi) - angleDiff
        end

        if angleDiff > (math.pi / 4) then
            if canFaceRaw then
                pcall(_G.WGG_SetFacingRaw, target)
            elseif canFaceXYZ then
                pcall(_G.WGG_SetFacing, targetX, targetY, targetZ or 0, 0)
            end
        end
    end

    local function CastKegSmash(target, context, maxRangeOverride)
        if target then
            local distance = target.distance
            local maxRange = tonumber(maxRangeOverride) or tonumber(Config.kegSmashMaxRange) or 10
            if distance and distance > maxRange then
                Logger:LogBlocked(Spells.KegSmash, target, context or "keg_smash", "beyond_configured_range", {
                    distance = RoundNumber(distance, 2),
                    maxRange = maxRange,
                })
                return false, "beyond_configured_range"
            end
        end

        local casted, reason = TryTargetCast(Spells.KegSmash, target, context or "keg_smash")
        if casted then
            return true, nil
        end
        return false, reason
    end

    local function CastBreathOfFire(target, context)
        if not StateCache.hasBreathOfFireTalent then
            return false, "not_known"
        end

        if StateCache.enemiesInMelee < 1 then
            Logger:LogBlocked(Spells.BreathOfFire, target, context or "breath_of_fire", "no_enemy_in_melee", {
                enemiesInMelee = StateCache.enemiesInMelee,
            })
            return false, "no_enemy_in_melee"
        end

        local casted, reason = TryTargetCast(Spells.BreathOfFire, target, context or "breath_of_fire")
        if casted then
            return true, nil
        end

        return false, reason
    end

    local function GetTrackedInterruptTarget()
        local knowledge = GetTankKnowledge()
        if not knowledge then
            return nil
        end

        for _, enemy in ipairs(GetEnemiesInRange(5) or {}) do
            if enemy.exists and not enemy.dead then
                local token = GetUnitToken(enemy)
                if token and token ~= "" then
                    local _, _, _, _, castEndTime, _, _, notInterruptible, spellId = UnitCastingInfo(token)
                    local _, _, _, _, channelEndTime, _, notInterruptibleCh, spellIdCh = UnitChannelInfo(token)

                    local trackedSpellId = nil
                    local remaining = 0
                    local interruptible = false

                    if spellId then
                        trackedSpellId = spellId
                        remaining = math.max(0, (castEndTime - GetTime() * 1000) / 1000)
                        interruptible = not notInterruptible
                    elseif spellIdCh then
                        trackedSpellId = spellIdCh
                        remaining = math.max(0, (channelEndTime - GetTime() * 1000) / 1000)
                        interruptible = not notInterruptibleCh
                    end

                    local entry = trackedSpellId and knowledge:GetInterruptEntry(trackedSpellId) or nil
                    if entry and interruptible then
                        local maxRemaining = Config.interruptMaxRemaining
                        if type(entry) == "table" and entry.maxRemaining then
                            maxRemaining = entry.maxRemaining
                        end

                        if remaining > 0 and remaining <= maxRemaining then
                            return enemy, trackedSpellId, remaining
                        end
                    end
                end
            end
        end

        return nil
    end

    local function TryConfiguredInterrupt()
        if not Config.useSpearHandStrike then
            return false
        end

        -- 1. Try whitelist-based interrupt (TankKnowledge)
        local enemy, trackedSpellId, remaining = GetTrackedInterruptTarget()
        if enemy then
            FaceTarget(enemy, 8)
            local kicked = TryTargetCast(Spells.SpearHandStrike, enemy, "interrupt_tracked", {
                trackedSpellId = trackedSpellId,
                castRemaining = RoundNumber(remaining, 2),
            })
            if kicked then return true end

            -- Leg Sweep fallback when SHS on CD
            if Config.useLegSweepInterrupt
                and Spells.LegSweep and Spells.LegSweep.known
                and (enemy.distance or 999) <= 6
                and TrySelfCast(Spells.LegSweep, "leg_sweep_interrupt_tracked_fallback")
            then
                return true
            end
        end

        -- 2. Interrupt-all fallback: kick any interruptable cast in melee range
        if Config.interruptAll then
            local maxRemaining = tonumber(Config.interruptMaxRemaining) or 0.8
            local bestEnemy, bestRemaining = nil, 999
            IterateEnemies(function(e)
                if not e.exists or e.dead or (e.distance or 999) > 5 then return end

                -- Use warden properties first (more reliable than token lookup)
                local isCasting = e.casting or e.channeling
                local canInterrupt = e.interruptable
                local rem = e.casttimeleft or e.channeltimeleft or 999

                if not isCasting then return end
                if canInterrupt == false then return end

                -- If warden properties unavailable, fall back to token-based check
                if rem == 999 then
                    local token = GetUnitToken(e)
                    if token then
                        local _, _, _, _, castEnd, _, _, notInterruptible = UnitCastingInfo(token)
                        local _, _, _, _, chanEnd, _, notInterruptibleCh = UnitChannelInfo(token)
                        local now = GetTime() * 1000
                        if castEnd and not notInterruptible then
                            rem = (castEnd - now) / 1000
                        elseif chanEnd and not notInterruptibleCh then
                            rem = (chanEnd - now) / 1000
                        end
                    end
                end

                if rem > 0 and rem <= maxRemaining and rem < bestRemaining then
                    bestRemaining = rem
                    bestEnemy = e
                end
            end)
            if bestEnemy then
                FaceTarget(bestEnemy, 8)
                -- Try Spear Hand Strike first
                local kicked = TryTargetCast(Spells.SpearHandStrike, bestEnemy, "interrupt_all", {
                    castRemaining = RoundNumber(bestRemaining, 2),
                })
                if kicked then return true end

                -- Leg Sweep fallback: SHS on CD, enemy in 6y, stun to interrupt
                if Config.useLegSweepInterrupt
                    and Spells.LegSweep and Spells.LegSweep.known
                    and (bestEnemy.distance or 999) <= 6
                    and TrySelfCast(Spells.LegSweep, "leg_sweep_interrupt_fallback")
                then
                    return true
                end
            end
        end

        return false
    end

    local function GetUpcomingSpikeResponseType()
        local knowledge = GetTankKnowledge()
        if not knowledge then
            return nil
        end

        local function resolveEntry(spellId)
            if not spellId then
                return nil
            end

            local entry = knowledge:GetTankBusterEntry(spellId)
            if not entry then
                return nil
            end

            local damageType = tostring(entry.damageType or "other"):lower()
            if damageType ~= "physical" then
                damageType = "other"
            end

            return {
                damageType = damageType,
                leadTime = tonumber(entry.leadTime) or Config.spikeResponseWindow,
                severity = entry.severity,
                note = entry.note,
            }
        end

        local function isInWindow(entry, remaining)
            if not entry or not remaining or remaining <= 0 then
                return false
            end

            local window = tonumber(entry.leadTime) or Config.spikeResponseWindow
            return remaining <= window
        end

        local bossAwareness = GetBossAwareness()
        if bossAwareness and bossAwareness.GetBossCast then
            local cast = bossAwareness:GetBossCast()
            if cast and cast.spellId and cast.remaining then
                local entry = resolveEntry(cast.spellId)
                if entry and isInWindow(entry, cast.remaining) then
                    return entry.damageType, cast.spellId, cast.remaining, entry
                end
            end
        end

        local bossTimers = GetBossTimers()
        if bossTimers and bossTimers.InEncounter and bossTimers:InEncounter() and bossTimers.GetAllUpcoming then
            for _, timer in ipairs(bossTimers:GetAllUpcoming() or {}) do
                local entry = resolveEntry(timer.spellId)
                if entry and isInWindow(entry, timer.remaining) then
                    return entry.damageType, timer.spellId, timer.remaining, entry
                end
            end
        end

        return nil
    end

    local function HandleSpikeResponse()
        local spikeType = GetUpcomingSpikeResponseType()
        if spikeType == "physical" then
            if TrySelfCast(Spells.FortifyingBrew, "spike_response_physical_fortifying_brew") then
                return true
            end
        elseif spikeType == "other" then
            if Config.useCelestialInfusion
                and StateCache.hasCelestialInfusionTalent
                and TrySelfCast(Spells.CelestialInfusion, "spike_response_other_celestial_infusion")
            then
                return true
            end
        end

        if spikeType ~= nil
            and ShouldUseSpikeFallbackPurifying()
            and TrySelfCast(Spells.PurifyingBrew, "spike_response_fallback_purifying_brew")
        then
            return true
        end

        return false
    end

    local function HasConfiguredSpikeSoon()
        return GetUpcomingSpikeResponseType() ~= nil
    end

    local function ShouldUseRoutineCelestialBrew()
        if HasConfiguredSpikeSoon() then
            return false
        end

        if StateCache.isHeavyStagger then
            return true
        end

        if StateCache.isMediumStagger and StateCache.playerHP < 90 then
            return true
        end

        return StateCache.playerHP < Config.routineCelestialBrewHP
    end

    local function ShouldUseRoutineCelestialInfusion()
        if HasConfiguredSpikeSoon() then
            return false
        end

        if StateCache.isHeavyStagger then
            return true
        end

        if StateCache.isMediumStagger and StateCache.playerHP < 85 then
            return true
        end

        return StateCache.playerHP < Config.routineCelestialInfusionHP
    end

    local function IsSpellFullyOnCooldown(spell)
        return spell and (not ((spell.charges or 0) > 0)) and spell.cd > 0
    end

    local function ShouldUseNormalCelestialInfusion()
        return Config.useCelestialInfusion
            and StateCache.hasCelestialInfusionTalent
            and StateCache.hasSoberBuff
    end

    local function ShouldUseNormalBlackOxBrew()
        if not Config.useBlackOxBrew or not StateCache.hasBlackOxBrewTalent then
            return false
        end

        local purifyingBrewOnCooldown = StateCache.purifyingBrewFractionalCharges < 1
        local celestialInfusionOnCooldown = not StateCache.hasCelestialInfusionTalent
            or IsSpellFullyOnCooldown(Spells.CelestialInfusion)

        return purifyingBrewOnCooldown and celestialInfusionOnCooldown
    end

    local function ShouldUseNormalPurifyingBrew()
        return Config.autoManageStagger
            and StateCache.isHeavyStagger
            and StateCache.playerHP < 80
    end

    local function ShouldUseFallbackTigerPalm(target)
        if not IsEnemy(target) or not IsTargetInMeleeRange(target) then
            return false
        end

        local blackoutKickCooldown = Spells.BlackoutKick.cd or 0
        -- Brewmaster Monk has a fixed 1.0s GCD (energy spec, not reduced by haste)
        local BREWMASTER_GCD = 1.0
        return blackoutKickCooldown > BREWMASTER_GCD
    end

    local function IsSpellUnavailableForSpikeResponse(spell, enabled)
        if not enabled or not spell then
            return true
        end

        if not spell.known then
            return true
        end

        if spell.cd > 0 and not ((spell.charges or 0) > 0) then
            return true
        end

        return not spell.usable
    end

    local function ShouldUseSpikeFallbackPurifying()
        local fortifyingUnavailable = IsSpellUnavailableForSpikeResponse(Spells.FortifyingBrew, true)
        local celestialInfusionUnavailable = IsSpellUnavailableForSpikeResponse(
            Spells.CelestialInfusion,
            Config.useCelestialInfusion and StateCache.hasCelestialInfusionTalent
        )

        return fortifyingUnavailable and celestialInfusionUnavailable
    end

    local function GetSpellRangeCheckResult(spell, target)
        if not spell or not target then
            return nil
        end

        local token = GetUnitToken(target)
        if not token or token == "" then
            return nil
        end

        if C_Spell and C_Spell.IsSpellInRange and (spell.id or spell.name) then
            local ok, inRange = pcall(C_Spell.IsSpellInRange, spell.id or spell.name, token)
            if ok and inRange ~= nil then
                return inRange == true or inRange == 1
            end
        end

        if IsSpellInRange and spell.name then
            local ok, inRange = pcall(IsSpellInRange, spell.name, token)
            if ok and inRange ~= nil then
                return inRange == 1
            end
        end

        return nil
    end

    IsTargetInMeleeRange = function(target)
        if not target or not target.exists or target.dead then
            return false
        end

        local meleeRangeResult = GetSpellRangeCheckResult(Spells.BlackoutKick, target)
        if meleeRangeResult == nil then
            meleeRangeResult = GetSpellRangeCheckResult(Spells.TigerPalm, target)
        end
        if meleeRangeResult ~= nil then
            return meleeRangeResult
        end

        local distance = target.distance
        local tolerance = tonumber(Config.meleeRangeTolerance) or 8.5
        return distance and distance <= tolerance or false
    end

    local function GetNPCIDFromGUID(guid)
        if type(guid) ~= "string" or guid == "" then
            return nil
        end

        local npcId = select(6, strsplit("-", guid))
        return tonumber(npcId or "")
    end

    local function BuildGroupMemberMap()
        local members = {}

        local function addUnit(token)
            if not token or not UnitExists(token) then
                return
            end

            local guid = UnitGUID(token)
            if not guid or guid == "" then
                return
            end

            members[guid] = {
                token = token,
                role = (UnitGroupRolesAssigned and UnitGroupRolesAssigned(token)) or "NONE",
            }
        end

        addUnit("player")
        if IsInRaid() then
            for i = 1, 40 do
                addUnit("raid" .. i)
            end
        else
            for i = 1, 4 do
                addUnit("party" .. i)
            end
        end

        return members
    end

    local function GetEnemyTargetToken(enemy)
        local enemyToken = GetUnitToken(enemy)
        if not enemyToken or enemyToken == "" then
            return nil
        end

        local targetToken = enemyToken .. "target"
        if UnitExists(targetToken) then
            return targetToken
        end

        return nil
    end

    local function GetCombatTauntTargetInfo(enemy, groupMembers)
        if not enemy or not enemy.exists or enemy.dead or not enemy.enemy or not enemy.combat then
            return nil
        end

        local enemyToken = GetUnitToken(enemy)
        if not enemyToken or enemyToken == "" then
            return nil
        end

        local targetToken = GetEnemyTargetToken(enemy)
        if not targetToken or UnitIsUnit(targetToken, "player") then
            return nil
        end

        local targetGuid = UnitGUID(targetToken)
        local targetInfo = targetGuid and groupMembers[targetGuid] or nil
        if not targetInfo or (targetInfo.role ~= "HEALER" and targetInfo.role ~= "DAMAGER") then
            return nil
        end

        return {
            enemy = enemy,
            enemyToken = enemyToken,
            targetToken = targetToken,
            targetRole = targetInfo.role,
            targetGuid = targetGuid,
        }
    end

    local function GetBestCombatTauntCandidate(primaryTarget)
        local groupMembers = BuildGroupMemberMap()
        local candidates = {}
        local primaryCandidate = nil

        IterateEnemies(function(enemy)
            local info = GetCombatTauntTargetInfo(enemy, groupMembers)
            if info then
                candidates[#candidates + 1] = info
                if primaryTarget and enemy.guid == primaryTarget.guid then
                    primaryCandidate = info
                end
            end
        end)

        if #candidates == 0 then
            return nil, nil
        end

        if primaryCandidate then
            return primaryCandidate, candidates
        end

        local best = candidates[1]
        local bestDistance = best.enemy.distance or math.huge
        for i = 2, #candidates do
            local candidate = candidates[i]
            local distance = candidate.enemy.distance or math.huge
            if distance < bestDistance then
                best = candidate
                bestDistance = distance
            end
        end

        return best, candidates
    end

    local function FindBlackOxStatue()
        local best = nil
        local bestDistance = math.huge

        local scanList = warden.pets or warden.units
        if scanList and scanList.loop then
            scanList.loop(function(obj)
                local npcId = obj.id or obj.objectid
                if npcId and BLACK_OX_STATUE_NPC_IDS[npcId] then
                    local distance = obj.distance or math.huge
                    if distance < bestDistance then
                        best = obj
                        bestDistance = distance
                    end
                end
            end)
        end

        return best
    end

    local function CountTauntCandidatesNearStatue(statue, candidates)
        local count = 0
        local radius = tonumber(Config.blackOxStatueTauntRadius) or 8

        for _, candidate in ipairs(candidates or {}) do
            local distance = candidate.enemy.distanceTo(statue)
            if distance and distance <= radius then
                count = count + 1
            end
        end

        return count
    end

    local function ManageCombatTaunts(primaryTarget)
        if not Config.useCombatProvoke then
            return false
        end

        local bestCandidate, candidates = GetBestCombatTauntCandidate(primaryTarget)
        if not bestCandidate then
            return false
        end

        if Config.useBlackOxStatueAoETwitter then
            local statue = FindBlackOxStatue()
            if statue then
                local statueTauntCount = CountTauntCandidatesNearStatue(statue, candidates)
                if statueTauntCount >= (tonumber(Config.blackOxStatueTauntMinEnemies) or 2) then
                    if TryTargetCast(Spells.Provoke, statue, "combat_provoke_black_ox_statue", {
                        tauntCount = statueTauntCount,
                        statueToken = GetUnitToken(statue),
                    }) then
                        return true
                    end
                end
            end
        end

        return TryTargetCast(Spells.Provoke, bestCandidate.enemy, "combat_provoke_single_target", {
            enemyToken = bestCandidate.enemyToken,
            targetToken = bestCandidate.targetToken,
            targetRole = bestCandidate.targetRole,
        })
    end

    local function ShouldUseBurstNiuzao()
        if not Config.useInvokeNiuzao or not StateCache.hasInvokeNiuzaoTalent then
            return false
        end

        if not StateCache.hasSoberBuff then
            return false
        end

        local flurryStacks = StateCache.flurryStrikesStacks
        local minFlurryStacks = tonumber(Config.invokeNiuzaoMinFlurryStacks) or 30

        if burstNiuzaoPending and flurryStacks >= minFlurryStacks then
            return true
        end

        local now = GetTime() or 0
        if burstNiuzaoPending
            and burstNiuzaoWindowExpiresAt > 0
            and (burstNiuzaoWindowExpiresAt - now) < 2
        then
            return true
        end

        if flurryStacks >= 50 then
            return true
        end

        return false
    end

    local function ShouldUseCracklingJadeLightningPull()
        return Config.useCracklingJadeLightningPull
            and StateCache.hasSoberBuff
    end

    local function UpdateBurstNiuzaoState()
        local inCombat = StateCache.playerInCombat == true
        local now = GetTime() or 0
        if inCombat and not lastCombatState then
            burstNiuzaoPending = true
            burstNiuzaoWindowExpiresAt = now + (tonumber(Config.burstNiuzaoWindow) or 8)
        elseif not inCombat then
            burstNiuzaoPending = true
            burstNiuzaoWindowExpiresAt = 0
        elseif burstNiuzaoPending and burstNiuzaoWindowExpiresAt > 0 and now > burstNiuzaoWindowExpiresAt then
            burstNiuzaoPending = false
            burstNiuzaoWindowExpiresAt = 0
        end

        lastCombatState = inCombat
    end

    local function HandlePull(target)
        if not Config.enablePullLogic or StateCache.playerInCombat or not IsEnemy(target) then
            return false
        end

        local distance = target.distance
        if not distance then
            return false
        end

        local targetInMeleeRange = IsTargetInMeleeRange(target)

        FaceTarget(target, 12)

        if targetInMeleeRange and TryTargetCast(Spells.BlackoutKick, target, "pull_blackout_kick") then
            return true
        end

        if not targetInMeleeRange
            and distance <= Config.kegSmashPullMaxRange
            and StateCache.playerEnergy >= Config.kegSmashPullEnergy
            and CastKegSmash(target, "pull_keg_smash", Config.kegSmashPullMaxRange)
        then
            return true
        end

        if Config.useCracklingJadeLightningPull
            and not StateCache.hasSoberBuff
            and distance > Config.kegSmashPullMaxRange
        then
            Logger:LogBlocked(Spells.CracklingJadeLightning, target, "pull_crackling_jade_lightning", "missing_sober_buff", {
                soberBuff = false,
                distance = RoundNumber(distance, 2),
            })
        end

        if ShouldUseCracklingJadeLightningPull()
            and TryTargetCast(Spells.CracklingJadeLightning, target, "pull_crackling_jade_lightning", {
                soberBuff = true,
            })
        then
            return true
        end

        LogStall(target, "pull_no_action", {
            distance = RoundNumber(distance, 2),
            hasSoberBuff = StateCache.hasSoberBuff,
            enoughEnergyForPullKeg = StateCache.playerEnergy >= Config.kegSmashPullEnergy,
        })
        return false
    end

    local function ManageDefensives()
        if Config.useBlackOxBrew
            and StateCache.hasBlackOxBrewTalent
            and StateCache.playerHP < Config.blackOxBrewHealthThreshold
            and StateCache.purifyingBrewFractionalCharges < Config.blackOxBrewPurifyChargesThreshold
            and TrySelfCast(Spells.BlackOxBrew, "black_ox_brew_emergency")
        then
            return true
        end

        if HandleSpikeResponse() then
            return true
        end

        if StateCache.playerHP < Config.fortifyingBrewThreshold then
            if TrySelfCast(Spells.FortifyingBrew, "fortifying_brew_low_hp") then
                return true
            end
        end

        return false
    end

    local lastKegSmashTime = 0
    local niuzaoActive = false
    local niuzaoExpiry = 0

    local function CoreRotation(target)
        if not IsEnemy(target) then
            return false
        end

        local distance = target.distance
        if not distance then
            return false
        end

        if distance <= 12 then
            FaceTarget(target, 12)
        end

        -- Ensure auto attack is running
        if IsTargetInMeleeRange(target) then
            local isAttacking = IsCurrentSpell and IsCurrentSpell(6603)
            if not isAttacking then
                local cp = _G.WGG_CallProtected or (_G.WGG and _G.WGG.CallProtected)
                if cp then
                    pcall(cp, StartAttack)
                end
            end
        end

        local now = GetTime() or 0

        -- Update Niuzao active state
        if niuzaoActive and now > niuzaoExpiry then
            niuzaoActive = false
        end

        -- Priority 0: Emergency defensives
        if ManageDefensives() then
            return true
        end

        -- Priority 1: Interrupt tracked casts
        if TryConfiguredInterrupt() then
            return true
        end

        -- Burst mode: during Niuzao, BoF gets elevated priority (城壁之智: triggers 9x Flurry Strikes)
        if niuzaoActive and Config.useBreathOfFire and StateCache.hasBreathOfFireTalent
            and not StateCache.hasBreathOfFireDot
        then
            local casted = CastBreathOfFire(target, "burst_breath_of_fire")
            if casted then
                lastKegSmashTime = 0  -- burst BoF satisfies the KS→BoF combo
                return true
            end
        end

        -- Priority 2: KS→BoF forced combo (KS resets BoF CD, so only GCD can block it)
        -- Safety: if BoF is disabled, clear combo state immediately
        if lastKegSmashTime > 0 and not Config.useBreathOfFire then
            lastKegSmashTime = 0
        end
        if Config.useBreathOfFire and lastKegSmashTime > 0 then
            if (now - lastKegSmashTime) < 1.5 then
                local casted, reason = CastBreathOfFire(target, "post_keg_breath")
                if casted then
                    lastKegSmashTime = 0
                    return true
                end
                -- Check why BoF failed
                local bofCD = Spells.BreathOfFire and Spells.BreathOfFire.cd or 999
                if reason == "no_enemy_in_melee" or reason == "not_known" then
                    -- Structural block (kiting/no talent) → abandon combo immediately
                    lastKegSmashTime = 0
                elseif bofCD <= 0 then
                    -- BoF CD=0, transient block (GCD/facing) → wait
                    return false
                elseif (now - lastKegSmashTime) >= 1.0 then
                    -- BoF on real CD, waited 1s → give up
                    lastKegSmashTime = 0
                else
                    -- BoF on real CD, still waiting
                    return false
                end
            else
                -- 1.5s window expired without BoF — safety reset to prevent permanent KS lockout
                lastKegSmashTime = 0
            end
        end

        -- Priority 3: Keg Smash at 2 charges (prevent waste)
        -- Skip if waiting for KS→BoF combo (don't override lastKegSmashTime with new KS)
        if lastKegSmashTime == 0
            and StateCache.kegSmashCharges >= 2
            and StateCache.playerEnergy >= Config.comboKegSmashEnergy
        then
            if CastKegSmash(target, "keg_smash_prevent_overcap") then
                lastKegSmashTime = now
                return true
            end
        end

        -- Priority 4: Blackout Combo branch (BC buff active)
        -- Skip BC→KS if waiting for KS→BoF combo
        if StateCache.hasBlackoutCombo and lastKegSmashTime == 0 then
            -- BC + KS has charges or nearly ready → save BC for KS, wait for energy
            if StateCache.kegSmashFractionalCharges >= 0.7 then
                if StateCache.playerEnergy >= Config.comboKegSmashEnergy then
                    if CastKegSmash(target, "blackout_combo_keg_smash") then
                        lastKegSmashTime = now
                        return true
                    end
                end
                -- Wait for energy — use Chi Burst as filler while waiting
                if StateCache.hasChiBurstTalent then
                    local casted = TryTargetCast(Spells.ChiBurst, target, "chi_burst_while_waiting_energy")
                    if casted then return true end
                end
                LogStall(target, "waiting_for_blackout_combo_keg_smash", {
                    distance = RoundNumber(distance, 2),
                    playerEnergy = StateCache.playerEnergy,
                    requiredEnergy = Config.comboKegSmashEnergy,
                    kegSmashCharges = RoundNumber(StateCache.kegSmashFractionalCharges, 2),
                })
                return false
            end

            -- BC + KS no charges → consume BC with Tiger Palm
            if StateCache.playerEnergy >= Config.comboTigerPalmEnergy then
                local casted = TryTargetCast(Spells.TigerPalm, target, "blackout_combo_tiger_palm")
                if casted then return true end
            end
        end

        -- Priority 5: Blackout Kick on CD
        local blackoutKickCasted, blackoutKickReason = TryTargetCast(Spells.BlackoutKick, target, "blackout_kick_on_cooldown")
        if blackoutKickCasted then
            return true
        end
        if blackoutKickReason == "out_of_range" or blackoutKickReason == "bad_facing" then
            LogStall(target, "waiting_for_blackout_kick_range", {
                distance = RoundNumber(distance, 2),
                facingDelta = RoundNumber(GetFacingDeltaToTarget(target), 3),
                reason = blackoutKickReason,
            })
            return false
        end

        -- Priority 6: Breath of Fire (if not already covered by KS→BoF combo)
        if Config.useBreathOfFire
            and StateCache.hasBreathOfFireTalent
            and not StateCache.hasBreathOfFireDot
        then
            local casted = CastBreathOfFire(target, "breath_of_fire_no_dot")
            if casted then return true end
        end

        -- Priority 7: Keg Smash with 1 charge (skip if waiting for KS→BoF)
        if lastKegSmashTime == 0
            and StateCache.kegSmashFractionalCharges >= 1
            and StateCache.playerEnergy >= Config.defaultKegSmashEnergy
        then
            if CastKegSmash(target, "keg_smash_single_charge") then
                lastKegSmashTime = now
                return true
            end
        end

        -- Priority 8: Burst Niuzao
        if ShouldUseBurstNiuzao() and TrySelfCast(Spells.InvokeNiuzao, "invoke_niuzao_with_sober") then
            burstNiuzaoPending = false
            burstNiuzaoWindowExpiresAt = 0
            niuzaoActive = true
            niuzaoExpiry = now + 25  -- Niuzao lasts 25 seconds
            return true
        end

        -- Priority 9: Exploding Keg
        if Config.useExplodingKeg
            and StateCache.hasExplodingKegTalent
            and StateCache.kegSmashFractionalCharges < 1
            and CastExplodingKeg(target, "exploding_keg_after_empty_keg")
        then
            return true
        end

        -- Priority 10: Touch of Death
        if Config.useTouchOfDeath and target.combat then
            local targetHealth = target.health
            local playerHealth = UnitHealth("player") or 0
            if targetHealth > 0 and targetHealth <= playerHealth then
                local casted = TryTargetCast(Spells.TouchOfDeath, target, "touch_of_death_low_target_health")
                if casted then return true end
            end
        end

        -- Priority 11: Chi Burst
        if StateCache.hasChiBurstTalent and TryTargetCast(Spells.ChiBurst, target, "chi_burst") then
            return true
        end

        -- Priority 12: Celestial Infusion with Sober
        if ShouldUseNormalCelestialInfusion()
            and TrySelfCast(Spells.CelestialInfusion, "celestial_infusion_with_sober")
        then
            return true
        end

        -- Priority 13: Black Ox Brew (resource recovery)
        if ShouldUseNormalBlackOxBrew()
            and TrySelfCast(Spells.BlackOxBrew, "black_ox_brew_when_purify_and_infusion_cd")
        then
            return true
        end

        -- Priority 14: Purifying Brew (routine stagger management)
        if ShouldUseNormalPurifyingBrew()
            and TrySelfCast(Spells.PurifyingBrew, "purifying_brew_red_stagger_hp_not_full")
        then
            return true
        end

        -- Priority 15: Tiger Palm filler (only when KS has no charges)
        if ShouldUseFallbackTigerPalm(target)
            and StateCache.kegSmashFractionalCharges < 0.5
            and TryTargetCast(Spells.TigerPalm, target, "fallback_tiger_palm")
        then
            return true
        end

        LogStall(target, "core_rotation_fallthrough", {
            distance = RoundNumber(distance, 2),
            hasBlackoutCombo = StateCache.hasBlackoutCombo,
        })
        return false
    end

    local function MainRotation()
        local player = warden.player
        local bestTarget = GetBestTarget()

        UpdateStateCache(bestTarget)
        UpdateBurstNiuzaoState()
        Logger:HandleCombatState(bestTarget)

        if not player or not player.exists then
            return
        end

        if StateCache.playerCasting or StateCache.playerChanneling then
            LogStall(bestTarget, "player_casting_or_channeling", {
                playerCasting = StateCache.playerCasting,
                playerChanneling = StateCache.playerChanneling,
            })
            return
        end

        local spellPending = IsExternalSpellPending()
        local runtimePendingInfo = warden and warden.GetPendingCastInfo and warden.GetPendingCastInfo() or nil
        local runtimePending = runtimePendingInfo ~= nil
        local groundPending = runtimePendingInfo and runtimePendingInfo.castType == "ground"
        if (spellPending and not runtimePending) or groundPending then
            LogStall(bestTarget, "spell_pending", {
                spellPending = spellPending,
                groundPending = groundPending == true,
                runtimePendingCastType = runtimePendingInfo and runtimePendingInfo.castType or nil,
            })
            return
        end

        if ManageCombatTaunts(bestTarget) then
            return
        end

        if StateCache.playerInCombat and not bestTarget then
            if ManageDefensives() then
                return
            end
            LogStall(nil, "in_combat_without_target")
            return
        end

        if not bestTarget then
            return
        end

        if not StateCache.playerInCombat then
            HandlePull(bestTarget)
            return
        end

        CoreRotation(bestTarget)
    end

    local function SyncRunningState()
        if warden then
            running = warden._bmRunning == true
        end
        return running
    end

    local function UpdateToggleButton()
        if not toggleButton or type(toggleButton.SetText) ~= "function" then
            return
        end

        SyncRunningState()
        local panel = togglePanel
        if running then
            toggleButton:SetText("Stop Rotation")
        else
            toggleButton:SetText("Start Rotation")
        end

        local statusText = panel and panel.statusText or nil
        if statusText and type(statusText.SetText) == "function" then
            if running then
                statusText:SetText("|cFF00FF00Running|r")
            else
                statusText:SetText("|cFFFF5555Stopped|r")
            end
        end

        if panel and panel.headerTexture and type(panel.headerTexture.SetColorTexture) == "function" then
            if running then
                panel.headerTexture:SetColorTexture(0.12, 0.62, 0.38, 0.95)
                SetBackdrop(panel, {0.05, 0.08, 0.07, 0.96}, {0.14, 0.72, 0.44, 1})
            else
                panel.headerTexture:SetColorTexture(0.40, 0.15, 0.15, 0.95)
                SetBackdrop(panel, {0.06, 0.06, 0.07, 0.96}, {0.24, 0.24, 0.28, 1})
            end
        end
    end

    local function StartRotation()
        talentsDetected = false
        lastTalentCheck = 0
        burstNiuzaoPending = true
        burstNiuzaoWindowExpiresAt = 0
        lastCombatState = false
        TTDHistory = {}
        Logger:ResetSession()

        local knowledge = GetTankKnowledge()
        if knowledge and knowledge.EnsureLoaded then
            knowledge:EnsureLoaded()
        end

        tickHandle = warden.onTick(function()
            MainRotation()
        end)
        running = true
        if warden then warden._bmRunning = true end
        Logger:Log("rotation", "Rotation started", {
            loggerPath = Logger:PeekRealtimePath(),
        }, warden.player, true)
        Success("Brewmaster standalone rotation started")
        UpdateToggleButton()
        return true
    end

    local function StopRotation()
        Logger:Log("rotation", "Rotation stopping", {
            loggerPath = Logger:PeekRealtimePath(),
        }, warden.player, true)
        if tickHandle then
            tickHandle.cancel()
            tickHandle = nil
        end
        do
            running = false
            if warden then warden._bmRunning = false end
            burstNiuzaoPending = false
            burstNiuzaoWindowExpiresAt = 0
            lastCombatState = false
            if Logger.config.enabled then
                Logger:Flush(true, Logger:GetLastCombatPath())
                Logger:Flush(true)
            end
            Success("Brewmaster standalone rotation stopped")
        end
        UpdateToggleButton()
        return true
    end

    local function ToggleRotation()
        SyncRunningState()
        if running then
            return StopRotation()
        end
        return StartRotation()
    end

    local function EnsureToggleButton()
        if type(CreateFrame) ~= "function" or not UIParent then
            return nil
        end

        local panel = _G.WGG_BrewmasterStandaloneTogglePanel
        local button = _G.WGG_BrewmasterStandaloneToggleButton
        local panelNeedsCreate = not panel
            or type(panel.SetPoint) ~= "function"
            or type(panel.SetScript) ~= "function"
            or type(panel.CreateFontString) ~= "function"
        local needsCreate = not button
            or type(button.SetText) ~= "function"
            or type(button.SetScript) ~= "function"
            or type(button.SetPoint) ~= "function"

        local oldPoint, oldRelativeTo, oldRelativePoint, oldX, oldY = nil, nil, nil, 0, 0
        if panelNeedsCreate and button and type(button.GetNumPoints) == "function" and button:GetNumPoints() > 0 then
            oldPoint, oldRelativeTo, oldRelativePoint, oldX, oldY = button:GetPoint(1)
        end

        if panelNeedsCreate then
            panel = CreateFrame("Frame", "WGG_BrewmasterStandaloneTogglePanel", UIParent, "BackdropTemplate")
        end

        if needsCreate then
            button = CreateFrame("Button", "WGG_BrewmasterStandaloneToggleButton", panel, "UIPanelButtonTemplate")
        end

        panel:SetSize(190, 152)
        panel:SetMovable(true)
        panel:RegisterForDrag("LeftButton")
        panel:SetClampedToScreen(true)
        panel:SetFrameStrata("MEDIUM")
        panel:EnableMouse(true)
        SetBackdrop(panel, {0.06, 0.06, 0.07, 0.96}, {0.24, 0.24, 0.28, 1})

        if panelNeedsCreate or (type(panel.GetNumPoints) == "function" and panel:GetNumPoints() == 0) then
            panel:ClearAllPoints()
            if oldPoint then
                panel:SetPoint(oldPoint, oldRelativeTo or UIParent, oldRelativePoint or oldPoint, oldX or 0, oldY or 0)
            else
                panel:SetPoint("CENTER", UIParent, "CENTER", 0, -180)
            end
        end

        panel:SetScript("OnDragStart", function(self)
            if type(IsShiftKeyDown) == "function" and IsShiftKeyDown() then
                self:StartMoving()
            end
        end)
        panel:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
        end)
        panel:SetScript("OnHide", function(self)
            self:StopMovingOrSizing()
        end)

        local header = panel.headerTexture
        if not header and type(panel.CreateTexture) == "function" then
            header = panel:CreateTexture(nil, "ARTWORK")
            panel.headerTexture = header
        end

        if header then
            header:ClearAllPoints()
            header:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -4)
            header:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -4, -4)
            header:SetHeight(22)
            header:SetColorTexture(0.40, 0.15, 0.15, 0.95)
        end

        local titleText = panel.titleText
        if not titleText and type(panel.CreateFontString) == "function" then
            titleText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            panel.titleText = titleText
        end

        if titleText then
            titleText:ClearAllPoints()
            titleText:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -9)
            titleText:SetFont("Fonts\\ARIALN.TTF", 12, "OUTLINE")
            titleText:SetText("Brewmaster")
        end

        local statusText = panel.statusText
        local needsStatusText = not statusText
            or type(statusText.SetText) ~= "function"
            or type(statusText.SetPoint) ~= "function"

        if needsStatusText and type(panel.CreateFontString) == "function" then
            statusText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            panel.statusText = statusText
        end

        if statusText and type(statusText.SetPoint) == "function" then
            statusText:ClearAllPoints()
            statusText:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -12, -9)
            statusText:SetFont("Fonts\\ARIALN.TTF", 11, "OUTLINE")
            statusText:Show()
        end

        local hintText = panel.hintText
        if not hintText and type(panel.CreateFontString) == "function" then
            hintText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            panel.hintText = hintText
        end

        if hintText then
            hintText:ClearAllPoints()
            hintText:SetPoint("BOTTOM", panel, "BOTTOM", 0, 8)
            hintText:SetFont("Fonts\\ARIALN.TTF", 10, "")
            hintText:SetText("|cFF9FA6B2Click to toggle  |  Shift+Drag move|r")
            hintText:Show()
        end

        button:SetParent(panel)
        button:SetSize(146, 28)
        button:ClearAllPoints()
        button:SetPoint("BOTTOM", panel, "BOTTOM", 0, 28)
        button:SetFrameStrata("MEDIUM")
        button:EnableMouse(true)
        button:RegisterForClicks("AnyUp")
        button:SetScript("OnClick", function()
            ToggleRotation()
        end)
        button:SetScript("OnDragStart", nil)
        button:SetScript("OnDragStop", nil)
        button:SetScript("OnHide", nil)

        if button.statusText and button.statusText ~= panel.statusText and type(button.statusText.Hide) == "function" then
            button.statusText:Hide()
        end

        -- Burst toggle button
        local burstBtn = panel.burstToggle
        if not burstBtn then
            burstBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
            panel.burstToggle = burstBtn
        end
        burstBtn:SetSize(68, 22)
        burstBtn:ClearAllPoints()
        burstBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 18, 56)
        burstBtn:SetText(Config.useInvokeNiuzao and "|cFF00FF00Burst|r" or "|cFFFF5555Burst|r")
        burstBtn:SetScript("OnClick", function()
            Config.useInvokeNiuzao = not Config.useInvokeNiuzao
            burstBtn:SetText(Config.useInvokeNiuzao and "|cFF00FF00Burst|r" or "|cFFFF5555Burst|r")
        end)

        -- Interrupt All toggle button
        local intBtn = panel.intAllToggle
        if not intBtn then
            intBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
            panel.intAllToggle = intBtn
        end
        intBtn:SetSize(68, 22)
        intBtn:ClearAllPoints()
        intBtn:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -18, 56)
        intBtn:SetText(Config.interruptAll and "|cFF00FF00Int All|r" or "|cFFFF5555Int All|r")
        intBtn:SetScript("OnClick", function()
            Config.interruptAll = not Config.interruptAll
            intBtn:SetText(Config.interruptAll and "|cFF00FF00Int All|r" or "|cFFFF5555Int All|r")
        end)

        -- Leg Sweep interrupt fallback toggle
        local sweepBtn = panel.legSweepToggle
        if not sweepBtn then
            sweepBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
            panel.legSweepToggle = sweepBtn
        end
        sweepBtn:SetSize(146, 22)
        sweepBtn:ClearAllPoints()
        sweepBtn:SetPoint("BOTTOM", panel, "BOTTOM", 0, 82)
        sweepBtn:SetText(Config.useLegSweepInterrupt and "|cFF00FF00Leg Sweep Int|r" or "|cFFFF5555Leg Sweep Int|r")
        sweepBtn:SetScript("OnClick", function()
            Config.useLegSweepInterrupt = not Config.useLegSweepInterrupt
            sweepBtn:SetText(Config.useLegSweepInterrupt and "|cFF00FF00Leg Sweep Int|r" or "|cFFFF5555Leg Sweep Int|r")
        end)

        panel:Show()
        button:Show()

        togglePanel = panel
        toggleButton = button
        UpdateToggleButton()
        return button
    end

    local function PrintLoggerStatus()
        local status = Logger:GetStatus()
        Print("Logger enabled: " .. tostring(status.enabled))
        Print("Logger entries: " .. tostring(status.entries))
        Print("Logger realtime path: " .. tostring(status.realtimePath))
        Print("Logger last combat path: " .. tostring(status.lastCombatPath))
        Print("Logger last write ok: " .. tostring(status.lastWriteOk))
        if status.lastWriteError then
            Print("Logger last write error: " .. tostring(status.lastWriteError))
        end
        if status.lastWritePath then
            Print("Logger last write path: " .. tostring(status.lastWritePath))
        end
    end

    local function HandleLogCommand(args)
        local action = args[2] or "status"
        if action == "on" or action == "start" then
            Logger.config.enabled = true
            Logger:ResetSession()
            Logger:Log("logger", "Logger enabled", {}, warden.player, true)
            Print("Logger enabled")
        elseif action == "off" or action == "stop" then
            Logger:Log("logger", "Logger disabled", {}, warden.player, true)
            Logger:Flush(true, Logger:GetLastCombatPath())
            Logger:Flush(true)
            Logger.config.enabled = false
            Print("Logger disabled")
        elseif action == "flush" then
            local ok, path, err = Logger:Flush(true)
            if ok then
                Print("Logger flushed: " .. tostring(path))
            else
                ErrorPrint("Logger flush failed: " .. tostring(err))
            end
        elseif action == "clear" then
            Logger:ResetSession()
            Logger:Flush(true)
            Print("Logger buffer cleared")
        else
            PrintLoggerStatus()
        end
    end

    local function GetNestedFieldType(root, fieldName)
        if not root then
            return "nil"
        end

        local ok, value = pcall(function()
            return root[fieldName]
        end)
        if not ok then
            return "error"
        end

        return type(value)
    end

    local function ShouldIncludeWGGDebugKey(name, includeAll)
        if includeAll then
            return true
        end

        local lowerName = tostring(name or ""):lower()
        return lowerName:find("click", 1, true)
            or lowerName:find("pending", 1, true)
            or lowerName:find("spell", 1, true)
            or lowerName:find("ground", 1, true)
            or lowerName:find("cursor", 1, true)
            or lowerName:find("targeting", 1, true)
            or lowerName:find("interact", 1, true)
    end

    local function AppendWGGDebugEntry(entries, name, value, includeAll)
        if type(name) ~= "string" or not ShouldIncludeWGGDebugKey(name, includeAll) then
            return
        end

        entries[#entries + 1] = {
            name = name,
            valueType = type(value),
        }
    end

    local function SortWGGDebugEntries(entries)
        table.sort(entries, function(a, b)
            return tostring(a.name) < tostring(b.name)
        end)
        return entries
    end

    local function CollectWGGGlobalEntries(includeAll)
        local entries = {}
        for name, value in pairs(_G) do
            if type(name) == "string" and name:match("^WGG_") then
                AppendWGGDebugEntry(entries, name, value, includeAll)
            end
        end

        return SortWGGDebugEntries(entries)
    end

    local function CollectWGGTableEntries(includeAll)
        local entries = {}
        local root = _G.WGG

        local function collectFromTable(tbl)
            if type(tbl) ~= "table" then
                return
            end

            local ok = pcall(function()
                for name, value in pairs(tbl) do
                    AppendWGGDebugEntry(entries, name, value, includeAll)
                end
            end)

            if not ok then
                return
            end
        end

        if type(root) == "table" then
            collectFromTable(root)
        elseif type(root) == "userdata" then
            local meta = getmetatable(root)
            if type(meta) == "table" and type(meta.__index) == "table" then
                collectFromTable(meta.__index)
            end
        end

        return SortWGGDebugEntries(entries)
    end

    local function CollectTableEntries(root, includeAll)
        local entries = {}

        local function collectFromTable(tbl)
            if type(tbl) ~= "table" then
                return
            end

            local ok = pcall(function()
                for name, value in pairs(tbl) do
                    AppendWGGDebugEntry(entries, name, value, includeAll)
                end
            end)

            if not ok then
                return
            end
        end

        if type(root) == "table" then
            collectFromTable(root)
        elseif type(root) == "userdata" then
            local meta = getmetatable(root)
            if type(meta) == "table" and type(meta.__index) == "table" then
                collectFromTable(meta.__index)
            end
        end

        return SortWGGDebugEntries(entries)
    end

    local function PrintWGGEntryBlock(title, entries, truncatedHint)
        Print(title .. ": " .. tostring(#entries))
        if #entries == 0 then
            Print("  (none)")
            return
        end

        for _, entry in ipairs(entries) do
            Print("  " .. tostring(entry.name) .. " (" .. tostring(entry.valueType) .. ")")
        end

        if truncatedHint then
            Print("  " .. truncatedHint)
        end
    end

    local function PrintWGGKeysDebug(includeAll)
        local globalEntries = CollectWGGGlobalEntries(includeAll)
        local tableEntries = CollectWGGTableEntries(includeAll)

        Print("WGG keys debug" .. (includeAll and " (all)" or " (filtered)"))
        Print("  _G.WGG type: " .. tostring(type(_G.WGG)))
        if not includeAll then
            Print("  Filter: click/pending/spell/ground/cursor/targeting/interact")
        end

        PrintWGGEntryBlock("Global WGG_* keys", globalEntries, includeAll and nil or "Use /bm debug wggkeys all for full dump")
        PrintWGGEntryBlock("_G.WGG keys", tableEntries, includeAll and nil or "Use /bm debug wggkeys all for full dump")
    end

    local function PrintWGGAPIDebug(includeAll)
        local entries = CollectTableEntries(_G.WGG_API, includeAll)

        Print("WGG_API debug" .. (includeAll and " (all)" or " (filtered)"))
        Print("  _G.WGG_API type: " .. tostring(type(_G.WGG_API)))
        if not includeAll then
            Print("  Filter: click/pending/spell/ground/cursor/targeting/interact")
        end

        PrintWGGEntryBlock("_G.WGG_API keys", entries, includeAll and nil or "Use /bm debug wggapi all for full dump")
    end

    local function PrintAPIDebug()
        local gcdInfo = warden and warden.GetGCDInfo and warden.GetGCDInfo() or nil
        if type(gcdInfo) ~= "table" then
            gcdInfo = nil
        end
        local loader = _G.WGG_StandaloneLoader
        local wggType = type(_G.WGG)
        local wggClickType = type(_G.WGG_Click)
        local wggPendingType = type(_G.WGG_IsSpellPending)
        local lastGroundClick = warden and warden.GetLastGroundClickDebug and warden.GetLastGroundClickDebug() or nil
        local groundClickTrace = warden and warden.GetGroundClickTrace and warden.GetGroundClickTrace() or nil
        local wggMethodClickType = GetNestedFieldType(_G.WGG, "Click")
        local wggMethodPendingType = GetNestedFieldType(_G.WGG, "IsSpellPending")
        local wggAPIType = type(_G.WGG_API)
        local wggAPIMouseClickType = GetNestedFieldType(_G.WGG_API, "MouseClick")
        local wggAPIObjectInteractType = GetNestedFieldType(_G.WGG_API, "ObjectInteract")
        local wggAPIW2SType = GetNestedFieldType(_G.WGG_API, "W2S")
        local wggAPINDCToScreenType = GetNestedFieldType(_G.WGG_API, "NDCToScreen")
        local wggAPIPendingType = GetNestedFieldType(_G.WGG_API, "PendingSpellID")
        local currentPendingSpellId = warden and warden.GetExternalPendingSpellID and warden.GetExternalPendingSpellID() or nil
        local currentGroundCursorPending = warden and warden.IsGroundCursorPending and warden.IsGroundCursorPending() or false
        local hasGroundClickPath = wggClickType == "function"
            or wggMethodClickType == "function"
            or wggAPIObjectInteractType == "function"
            or (wggAPIMouseClickType == "function" and wggAPIW2SType == "function" and wggAPINDCToScreenType == "function")

        Print("Debug API:")
        Print("  Loader version: " .. tostring(loader and loader.VERSION or "nil"))
        Print("  warden version: " .. tostring(warden and warden.VERSION or "nil"))
        Print("  _G.WGG type: " .. tostring(wggType))
        Print("  _G.WGG_Click type: " .. tostring(wggClickType))
        Print("  _G.WGG.Click type: " .. tostring(wggMethodClickType))
        Print("  _G.WGG_IsSpellPending type: " .. tostring(wggPendingType))
        Print("  _G.WGG.IsSpellPending type: " .. tostring(wggMethodPendingType))
        Print("  _G.WGG_API type: " .. tostring(wggAPIType))
        Print("  _G.WGG_API.MouseClick type: " .. tostring(wggAPIMouseClickType))
        Print("  _G.WGG_API.ObjectInteract type: " .. tostring(wggAPIObjectInteractType))
        Print("  _G.WGG_API.W2S type: " .. tostring(wggAPIW2SType))
        Print("  _G.WGG_API.NDCToScreen type: " .. tostring(wggAPINDCToScreenType))
        Print("  _G.WGG_API.PendingSpellID type: " .. tostring(wggAPIPendingType))
        Print("  SpellIsTargeting type: " .. tostring(type(SpellIsTargeting)))
        Print("  C_Timer.After type: " .. tostring(C_Timer and type(C_Timer.After) or "nil"))
        Print("  Ground click path available: " .. tostring(hasGroundClickPath))
        Print("  Ground cursor pending now: " .. tostring(currentGroundCursorPending))
        Print("  Current pendingSpellId: " .. tostring(currentPendingSpellId))

        if gcdInfo then
            Print("  GCD remaining: " .. tostring(RoundNumber(gcdInfo.remaining or 0, 3)))
            Print("  GCD duration: " .. tostring(RoundNumber((gcdInfo.duration and gcdInfo.duration > 0) and gcdInfo.duration or (gcdInfo.lastKnownDuration or 0), 3)))
            Print("  GCD modRate: " .. tostring(RoundNumber((gcdInfo.modRate and gcdInfo.modRate > 0) and gcdInfo.modRate or (gcdInfo.lastKnownModRate or 1), 3)))
        end

        if type(lastGroundClick) == "table" then
            Print("  Last ground click method: " .. tostring(lastGroundClick.method))
            Print("  Last ground click reason: " .. tostring(lastGroundClick.reason))
            Print("  Last ground click attempt: " .. tostring(lastGroundClick.attempt))
            Print("  Last ground click age: " .. tostring(RoundNumber(lastGroundClick.age, 3)))
            if lastGroundClick.screenX or lastGroundClick.screenY then
                Print("  Last ground click screen: " .. tostring(RoundNumber(lastGroundClick.screenX, 1)) .. ", " .. tostring(RoundNumber(lastGroundClick.screenY, 1)))
            end
            if lastGroundClick.worldX or lastGroundClick.worldY or lastGroundClick.worldZ then
                Print("  Last ground click world: "
                    .. tostring(RoundNumber(lastGroundClick.worldX, 1)) .. ", "
                    .. tostring(RoundNumber(lastGroundClick.worldY, 1)) .. ", "
                    .. tostring(RoundNumber(lastGroundClick.worldZ, 1)))
            end
            if lastGroundClick.pendingSpellId then
                Print("  Last ground click pendingSpellId: " .. tostring(lastGroundClick.pendingSpellId))
            end
        end

        if type(groundClickTrace) == "table" and #groundClickTrace > 0 then
            local startIndex = math.max(1, #groundClickTrace - 7)
            for index = startIndex, #groundClickTrace do
                local entry = groundClickTrace[index]
                if type(entry) == "table" then
                    Print("  Ground trace " .. tostring(index) .. ": "
                        .. tostring(entry.method) .. " / "
                        .. tostring(entry.reason) .. " / attempt="
                        .. tostring(entry.attempt))
                    if entry.screenX or entry.screenY then
                        Print("    screen=" .. tostring(RoundNumber(entry.screenX, 1)) .. ", " .. tostring(RoundNumber(entry.screenY, 1)))
                    end
                    if entry.ndcX or entry.ndcY then
                        Print("    ndc=" .. tostring(RoundNumber(entry.ndcX, 3)) .. ", " .. tostring(RoundNumber(entry.ndcY, 3)))
                    end
                end
            end
        end

        if not hasGroundClickPath then
            ErrorPrint("Ground click API missing across WGG/WGG_API: Exploding Keg cannot auto-place")
        end
    end

    local function HandleDebugCommand(args)
        local action = args[2] or ""
        if action == "api" then
            PrintAPIDebug()
        elseif action == "wggkeys" then
            PrintWGGKeysDebug(args[3] == "all")
        elseif action == "wggapi" then
            PrintWGGAPIDebug(args[3] == "all")
        else
            Print("Debug commands:")
            Print("  /bm debug api - Show WGG ground-cast API status")
            Print("  /bm debug wggkeys - Show relevant WGG keys")
            Print("  /bm debug wggkeys all - Show all visible WGG keys")
            Print("  /bm debug wggapi - Show WGG_API keys")
            Print("  /bm debug wggapi all - Show all visible WGG_API keys")
        end
    end

    local function SlashHandler(msg)
        local raw = tostring(msg or ""):lower():match("^%s*(.-)%s*$")
        local args = {}
        for word in raw:gmatch("%S+") do
            args[#args + 1] = word
        end

        local cmd = args[1] or ""
        if cmd == "" or cmd == "toggle" then
            ToggleRotation()
        elseif cmd == "start" then
            StartRotation()
        elseif cmd == "stop" then
            StopRotation()
        elseif cmd == "status" then
            SyncRunningState()
            Print("Running: " .. tostring(running))
            Print("TankKnowledge: " .. tostring(GetTankKnowledge() ~= nil))
            Print("BossAwareness: " .. tostring(GetBossAwareness() ~= nil))
            Print("BossTimers: " .. tostring(GetBossTimers() ~= nil))
            PrintLoggerStatus()
        elseif cmd == "log" then
            HandleLogCommand(args)
        elseif cmd == "burst" then
            Config.useInvokeNiuzao = not Config.useInvokeNiuzao
            Print("Burst (Niuzao): " .. (Config.useInvokeNiuzao and "|cFF00FF00ON|r" or "|cFFFF5555OFF|r"))
        elseif cmd == "intall" then
            Config.interruptAll = not Config.interruptAll
            Print("Interrupt All: " .. (Config.interruptAll and "|cFF00FF00ON|r" or "|cFFFF5555OFF|r"))
        elseif cmd == "debug" then
            HandleDebugCommand(args)
        else
            Print("Commands:")
            Print("  /bm - Toggle rotation")
            Print("  /bm start - Start rotation")
            Print("  /bm stop - Stop rotation")
            Print("  /bm status - Show status")
            Print("  /bm burst - Toggle burst (Niuzao)")
            Print("  /bm intall - Toggle interrupt all")
            Print("  /bm log - Show logger status")
            Print("  /bm log on|off|flush|clear")
            Print("  /bm debug wggapi - Show WGG_API keys")
        end
    end

    _G.SLASH_WGGBREWMASTER1 = "/bm"
    _G.SLASH_WGGBREWMASTER2 = "/brewmaster"
    _G.SLASH_WGGBREWMASTER3 = "/wggbm"
    _G.SlashCmdList["WGGBREWMASTER"] = SlashHandler

    _G.WGG_BrewmasterStandalone = {
        VERSION = MODULE_VERSION,
        Start = StartRotation,
        Stop = StopRotation,
        Toggle = ToggleRotation,
        EnsureToggleButton = EnsureToggleButton,
        Logger = Logger,
        warden = warden,
        Info = RotationInfo,
    }

    EnsureToggleButton()

    -- Draw: using WGG_API raw draw (works reliably, warden.Draw callbacks don't render)
    local drawFrame = CreateFrame("Frame")
    local DRAW_API = _G.WGG_API
    drawFrame:SetScript("OnUpdate", function()
        if not running or not DRAW_API then return end
        local player = warden.player
        if not player or not player.exists or player.dead then return end

        local px, py, pz = player.x, player.y, player.z
        if not px or not py or not pz then return end

        local facing = player.rotation or 0
        local seg = 32

        -- Breath of Fire cone (only show when BoF is off CD and in combat)
        local bofCD = Spells.BreathOfFire and Spells.BreathOfFire.cd or 999
        if bofCD <= 0 and player.combat then
            local bofRange = 12
            local halfAngle = math.pi / 4  -- 45 deg each side = 90 deg total
            local lx = px + bofRange * math.cos(facing - halfAngle)
            local ly = py + bofRange * math.sin(facing - halfAngle)
            local rx = px + bofRange * math.cos(facing + halfAngle)
            local ry = py + bofRange * math.sin(facing + halfAngle)
            DRAW_API.DrawLine(px, py, pz, lx, ly, pz, 1, 0.4, 0, 0.8, 3, 0)
            DRAW_API.DrawLine(px, py, pz, rx, ry, pz, 1, 0.4, 0, 0.8, 3, 0)
            DRAW_API.DrawArc(px, py, pz, bofRange, facing, halfAngle * 2, 1, 0.4, 0, 0.6, 2, 0, seg)
        end

        -- Exploding Keg landing zone (red circle, shows for 2s after cast to warn about pulling mobs out)
        if lastExplodingKegPos then
            local elapsed = (GetTime() or 0) - (lastExplodingKegPos.time or 0)
            if elapsed < 2 then
                local ekRadius = tonumber(Config.explodingKegClusterRadius) or 8
                local alpha = 0.8 * (1 - elapsed / 2)  -- fade out over 2s
                DRAW_API.DrawCircle(lastExplodingKegPos.x, lastExplodingKegPos.y, lastExplodingKegPos.z, ekRadius, 1, 0.1, 0, alpha, 5, 0, 0, 48)
            else
                lastExplodingKegPos = nil
            end
        end
    end)

    Success("Brewmaster v" .. MODULE_VERSION .. " loaded. Commands: /bm, /brewmaster")
end

local bsOk, bsErr = pcall(Bootstrap)
if not bsOk then
    ErrorPrint("Bootstrap error: " .. tostring(bsErr))
end

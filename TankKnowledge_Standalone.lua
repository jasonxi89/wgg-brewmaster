--[[
================================================================================
  TankKnowledge Standalone - Shared Tank Interrupt / Tank Buster Database
  Version: 1.0.0

  Zero VanFW dependency. Uses WGG file + JSON API only.
  Shared by all tank scripts via C:\WGG\cfg\tank_shared_lists.json
================================================================================
]]

local TK = {}
local VERSION = "1.0.0"

if _G.WGG_TankKnowledge and _G.WGG_TankKnowledge.VERSION then
    print("|cFFFFFF00[TankKnowledge]|r Replacing v" .. _G.WGG_TankKnowledge.VERSION .. " with v" .. VERSION)
end

if not _G.WGG_JsonEncode or not _G.WGG_JsonDecode or not _G.WGG_FileRead or not _G.WGG_FileWrite then
    print("|cFFFF0000[TankKnowledge]|r Missing WGG JSON/File API. Module disabled.")
    return
end

_G.WGG_TankKnowledge = TK
TK.VERSION = VERSION

TK.config = {
    cfgDir = "C:\\WGG\\cfg",
    dataPath = "C:\\WGG\\cfg\\tank_shared_lists.json",
    loadRetryCooldown = 5,
    debug = false,
}

TK.state = {
    loaded = false,
    data = nil,
    lastLoadErrorAt = 0,
}

local function DebugPrint(msg)
    if TK.config.debug then
        print("|cFF88CCFF[TankKnowledge]|r " .. tostring(msg))
    end
end

local function ErrorPrint(msg)
    print("|cFFFF5555[TankKnowledge]|r " .. tostring(msg))
end

local function CanReadFile(path)
    if type(_G.WGG_FileRead) ~= "function" then
        return false
    end

    local ok, content = pcall(_G.WGG_FileRead, path)
    return ok and type(content) == "string" and content ~= ""
end

local function FileLooksPresent(path)
    if type(_G.WGG_FileExists) == "function" then
        local ok, exists = pcall(_G.WGG_FileExists, path)
        if ok and exists == true then
            return true
        end
    end

    return CanReadFile(path)
end

local function CreateDefaultData()
    return {
        version = VERSION,
        interrupts = {},
        tankBusters = {},
    }
end

local function MarkLoadFailure()
    TK.state.loaded = false
    TK.state.lastLoadErrorAt = GetTime and GetTime() or 0
end

local function ClearLoadFailure()
    TK.state.lastLoadErrorAt = 0
end

local function NormalizeSpellKey(spellId)
    local num = tonumber(spellId)
    if not num or num <= 0 then
        return nil
    end
    return tostring(math.floor(num + 0.5))
end

local function NormalizeInterruptEntry(entry)
    entry = type(entry) == "table" and entry or {}
    return {
        maxRemaining = tonumber(entry.maxRemaining) or 0.8,
        priority = tostring(entry.priority or "high"),
        note = tostring(entry.note or ""),
    }
end

local function NormalizeTankBusterEntry(entry)
    entry = type(entry) == "table" and entry or {}

    local damageType = tostring(entry.damageType or "other"):lower()
    if damageType ~= "physical" and damageType ~= "magic" and damageType ~= "mixed" and damageType ~= "other" then
        damageType = "other"
    end

    local severity = tostring(entry.severity or "high"):lower()
    if severity ~= "low" and severity ~= "medium" and severity ~= "high" and severity ~= "critical" then
        severity = "high"
    end

    return {
        damageType = damageType,
        severity = severity,
        leadTime = tonumber(entry.leadTime) or 1.5,
        note = tostring(entry.note or ""),
    }
end

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
    if not str or str == "" then
        return nil
    end

    local ok, result = pcall(function()
        local tableStr = _G.WGG_JsonDecode(str)
        if not tableStr then
            return nil
        end

        if type(tableStr) == "table" then
            return tableStr
        end

        if not IsSafeDecodedTableString(tableStr) then
            ErrorPrint("Decoded table string failed safety validation")
            return nil
        end

        local chunkSource = tableStr
        if not chunkSource:match("^%s*return[%s{]") then
            chunkSource = "return " .. chunkSource
        end

        local fn, err = loadstring(chunkSource)
        if not fn then
            ErrorPrint("loadstring failed: " .. tostring(err))
            return nil
        end

        return fn()
    end)

    if ok then
        return result
    end

    return nil
end

function TK:NormalizeData(data)
    data = type(data) == "table" and data or {}

    local normalized = CreateDefaultData()
    normalized.version = tostring(data.version or VERSION)

    if type(data.interrupts) == "table" then
        for spellId, entry in pairs(data.interrupts) do
            local key = NormalizeSpellKey(spellId)
            if key then
                normalized.interrupts[key] = NormalizeInterruptEntry(entry)
            end
        end
    end

    if type(data.tankBusters) == "table" then
        for spellId, entry in pairs(data.tankBusters) do
            local key = NormalizeSpellKey(spellId)
            if key then
                normalized.tankBusters[key] = NormalizeTankBusterEntry(entry)
            end
        end
    end

    return normalized
end

function TK:EnsureFile()
    if _G.WGG_DirExists then
        local ok, dirExists = pcall(_G.WGG_DirExists, self.config.cfgDir)
        dirExists = ok and dirExists == true
        if not dirExists then
            if not _G.WGG_CreateDir then
                ErrorPrint("WGG_CreateDir missing and cfg directory does not exist")
                return false
            end

            if not _G.WGG_CreateDir(self.config.cfgDir) then
                ErrorPrint("Failed to create cfg directory")
                return false
            end
        end
    end

    if not FileLooksPresent(self.config.dataPath) then
        local payload = EncodeJSON(CreateDefaultData())
        if not payload or payload == "" then
            ErrorPrint("Failed to encode default data")
            return false
        end

        if not _G.WGG_FileWrite(self.config.dataPath, payload) then
            ErrorPrint("Failed to create data file")
            return false
        end
    end

    return true
end

function TK:Load()
    if not self:EnsureFile() then
        MarkLoadFailure()
        return false
    end

    local content = _G.WGG_FileRead(self.config.dataPath)
    if not content or content == "" then
        ErrorPrint("Shared tank data file is empty")
        MarkLoadFailure()
        return false
    end

    local parsed = DecodeJSON(content)
    if type(parsed) ~= "table" then
        ErrorPrint("Failed to parse shared tank data")
        MarkLoadFailure()
        return false
    end

    self.state.data = self:NormalizeData(parsed)
    self.state.loaded = true
    ClearLoadFailure()
    DebugPrint("Shared tank data loaded")
    return true
end

function TK:Reload()
    self.state.loaded = false
    self.state.lastLoadErrorAt = 0
    return self:Load()
end

function TK:EnsureLoaded()
    if self.state.loaded and self.state.data then
        return true
    end

    if self.state.lastLoadErrorAt > 0 and GetTime then
        if (GetTime() - self.state.lastLoadErrorAt) < self.config.loadRetryCooldown then
            return false
        end
    end

    return self:Load()
end

function TK:Save()
    if not self:EnsureFile() then
        MarkLoadFailure()
        return false
    end

    self.state.data = self:NormalizeData(self.state.data or CreateDefaultData())

    local payload = EncodeJSON(self.state.data)
    if not payload or payload == "" then
        ErrorPrint("Failed to encode data")
        MarkLoadFailure()
        return false
    end

    if not _G.WGG_FileWrite(self.config.dataPath, payload) then
        ErrorPrint("Failed to write data file")
        MarkLoadFailure()
        return false
    end

    self.state.loaded = true
    ClearLoadFailure()
    return true
end

function TK:GetData()
    if not self:EnsureLoaded() then
        return nil
    end

    self.state.data = self.state.data or CreateDefaultData()
    return self.state.data
end

function TK:GetInterruptEntry(spellId)
    local key = NormalizeSpellKey(spellId)
    local data = self:GetData()
    if not key or not data then
        return nil
    end
    return data.interrupts[key]
end

function TK:SetInterruptEntry(spellId, maxRemaining, priority, note)
    local key = NormalizeSpellKey(spellId)
    local data = self:GetData()
    if not key or not data then
        return false
    end

    data.interrupts[key] = NormalizeInterruptEntry({
        maxRemaining = maxRemaining,
        priority = priority,
        note = note,
    })

    return self:Save()
end

function TK:RemoveInterruptEntry(spellId)
    local key = NormalizeSpellKey(spellId)
    local data = self:GetData()
    if not key or not data then
        return false
    end

    data.interrupts[key] = nil
    return self:Save()
end

function TK:GetTankBusterEntry(spellId)
    local key = NormalizeSpellKey(spellId)
    local data = self:GetData()
    if not key or not data then
        return nil
    end
    return data.tankBusters[key]
end

function TK:SetTankBusterEntry(spellId, damageType, severity, leadTime, note)
    local key = NormalizeSpellKey(spellId)
    local data = self:GetData()
    if not key or not data then
        return false
    end

    data.tankBusters[key] = NormalizeTankBusterEntry({
        damageType = damageType,
        severity = severity,
        leadTime = leadTime,
        note = note,
    })

    return self:Save()
end

function TK:RemoveTankBusterEntry(spellId)
    local key = NormalizeSpellKey(spellId)
    local data = self:GetData()
    if not key or not data then
        return false
    end

    data.tankBusters[key] = nil
    return self:Save()
end

function TK:GetSortedInterrupts()
    local result = {}
    local data = self:GetData()
    if not data then
        return result
    end

    for spellId, entry in pairs(data.interrupts) do
        result[#result + 1] = {
            spellId = spellId,
            maxRemaining = tonumber(entry.maxRemaining) or 0.8,
            priority = tostring(entry.priority or "high"),
            note = tostring(entry.note or ""),
        }
    end

    table.sort(result, function(a, b)
        return tonumber(a.spellId) < tonumber(b.spellId)
    end)

    return result
end

function TK:GetSortedTankBusters()
    local result = {}
    local data = self:GetData()
    if not data then
        return result
    end

    for spellId, entry in pairs(data.tankBusters) do
        result[#result + 1] = {
            spellId = spellId,
            damageType = tostring(entry.damageType or "other"),
            severity = tostring(entry.severity or "high"),
            leadTime = tonumber(entry.leadTime) or 1.5,
            note = tostring(entry.note or ""),
        }
    end

    table.sort(result, function(a, b)
        return tonumber(a.spellId) < tonumber(b.spellId)
    end)

    return result
end

function TK:BuildInterruptPreview()
    local entries = self:GetSortedInterrupts()
    if #entries == 0 then
        return "No interrupt entries."
    end

    local lines = {}
    for _, entry in ipairs(entries) do
        lines[#lines + 1] = string.format(
            "%s | %.1fs | %s | %s",
            entry.spellId,
            entry.maxRemaining,
            entry.priority,
            entry.note ~= "" and entry.note or "-"
        )
    end

    return table.concat(lines, "\n")
end

function TK:BuildTankBusterPreview()
    local entries = self:GetSortedTankBusters()
    if #entries == 0 then
        return "No tank buster entries."
    end

    local lines = {}
    for _, entry in ipairs(entries) do
        lines[#lines + 1] = string.format(
            "%s | %s | %s | %.1fs | %s",
            entry.spellId,
            entry.damageType,
            entry.severity,
            entry.leadTime,
            entry.note ~= "" and entry.note or "-"
        )
    end

    return table.concat(lines, "\n")
end

TK:EnsureFile()
TK:EnsureLoaded()
DebugPrint("TankKnowledge standalone loaded")

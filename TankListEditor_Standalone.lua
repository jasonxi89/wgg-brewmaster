--[[
================================================================================
  TankListEditor Standalone - Shared Tank List UI
  Version: 1.0.0

  Zero VanFW dependency. Requires TankKnowledge_Standalone.lua.
  Commands:
    /tanklists
    /tanklists reload
    /tanklists path
================================================================================
]]

local Editor = {}
local VERSION = "1.0.0"
local FRAME_NAME = "WGGTankListEditorFrame"
local DEFAULT_FRAME_WIDTH = 960
local DEFAULT_FRAME_HEIGHT = 560
local FRAME_MARGIN = 40

local function Print(msg)
    print("|cFF00FFFF[TankListEditor]|r " .. tostring(msg))
end

local function ErrorPrint(msg)
    print("|cFFFF5555[TankListEditor]|r " .. tostring(msg))
end

local function Trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function InitializeModule()
    local TK = _G.WGG_TankKnowledge
    if not TK then
        return false
    end

    if _G.WGG_TankListEditor and _G.WGG_TankListEditor.VERSION then
        Print("Replacing v" .. _G.WGG_TankListEditor.VERSION .. " with v" .. VERSION)
    end

    _G.WGG_TankListEditor = Editor
    Editor.VERSION = VERSION
    Editor.TK = TK
    Editor.frame = Editor.frame or _G[FRAME_NAME]
    Editor.widgets = Editor.widgets or {}

    function Editor:GetTK()
        return _G.WGG_TankKnowledge or self.TK
    end

    function Editor:ApplyFrameFit()
        if not self.frame or not UIParent then
            return
        end

        local parentWidth = UIParent:GetWidth() or 0
        local parentHeight = UIParent:GetHeight() or 0
        local scale = 1

        if parentWidth > 0 and parentHeight > 0 then
            local widthScale = (parentWidth - FRAME_MARGIN) / DEFAULT_FRAME_WIDTH
            local heightScale = (parentHeight - FRAME_MARGIN) / DEFAULT_FRAME_HEIGHT
            if widthScale > 0 and heightScale > 0 then
                scale = math.min(1, widthScale, heightScale)
            end
        end

        self.frame:SetScale(scale)
        self.frame:SetClampedToScreen(true)
    end

    local function SetBackdrop(frame, bgColor, borderColor)
        frame:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true,
            tileSize = 16,
            edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        frame:SetBackdropColor(unpack(bgColor or {0.08, 0.08, 0.08, 0.95}))
        frame:SetBackdropBorderColor(unpack(borderColor or {0.2, 0.2, 0.2, 1}))
    end

    local function CreateLabel(parent, text, size, color)
        local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetFont("Fonts\\ARIALN.TTF", size or 12, "OUTLINE")
        label:SetText(text or "")
        if color then
            label:SetTextColor(color[1], color[2], color[3], color[4] or 1)
        else
            label:SetTextColor(1, 1, 1, 1)
        end
        label:SetJustifyH("LEFT")
        return label
    end

    local function CreateEditField(parent, labelText, width, defaultValue)
        local container = CreateFrame("Frame", nil, parent, "BackdropTemplate")
        container:SetSize(width, 42)

        local label = CreateLabel(container, labelText, 11)
        label:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)

        local input = CreateFrame("EditBox", nil, container, "BackdropTemplate")
        input:SetSize(width, 24)
        input:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, 0)
        input:SetFont("Fonts\\ARIALN.TTF", 12, "")
        input:SetTextColor(1, 1, 1, 1)
        input:SetAutoFocus(false)
        input:SetTextInsets(6, 6, 4, 4)
        input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        input:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        SetBackdrop(input, {0.12, 0.12, 0.12, 0.95}, {0.25, 0.25, 0.25, 1})

        if defaultValue ~= nil then
            input:SetText(tostring(defaultValue))
        end

        return container, input
    end

    local function CreateButton(parent, text, width, height, onClick)
        local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        button:SetSize(width, height or 24)
        button:SetText(text)
        button:SetScript("OnClick", onClick)
        return button
    end

    local function CreatePreviewBox(parent, title, width, height)
        local container = CreateFrame("Frame", nil, parent, "BackdropTemplate")
        container:SetSize(width, height)
        SetBackdrop(container, {0.09, 0.09, 0.09, 0.95}, {0.2, 0.2, 0.2, 1})

        local label = CreateLabel(container, title, 12)
        label:SetPoint("TOPLEFT", container, "TOPLEFT", 8, -8)

        local scroll = CreateFrame("ScrollFrame", nil, container, "BackdropTemplate")
        scroll:SetPoint("TOPLEFT", container, "TOPLEFT", 8, -28)
        scroll:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -28, 8)

        local scrollBar = CreateFrame("Slider", nil, scroll, "UIPanelScrollBarTemplate")
        scrollBar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 4, -16)
        scrollBar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 4, 16)
        scrollBar:SetMinMaxValues(0, 0)
        scrollBar:SetValueStep(16)
        scrollBar:SetValue(0)
        scrollBar:SetScript("OnValueChanged", function(_, value)
            scroll:SetVerticalScroll(value)
        end)

        local edit = CreateFrame("EditBox", nil, scroll)
        edit:SetMultiLine(true)
        edit:SetAutoFocus(false)
        edit:EnableMouse(true)
        edit:SetFont("Fonts\\ARIALN.TTF", 11, "")
        edit:SetTextColor(0.9, 0.9, 0.9, 1)
        edit:SetWidth(width - 50)
        edit:SetJustifyH("LEFT")
        edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        edit:SetScript("OnTextChanged", function(self)
            self:SetHeight(math.max(height - 40, self:GetStringHeight() + 20))
            local maxScroll = math.max(0, self:GetHeight() - scroll:GetHeight())
            scrollBar:SetMinMaxValues(0, maxScroll)
        end)

        scroll:SetScrollChild(edit)
        scroll:EnableMouseWheel(true)
        scroll:SetScript("OnMouseWheel", function(_, delta)
            local current = scroll:GetVerticalScroll()
            local minVal, maxVal = scrollBar:GetMinMaxValues()
            local nextValue = math.max(minVal, math.min(maxVal, current - (delta * 24)))
            scrollBar:SetValue(nextValue)
        end)

        return container, edit
    end

    function Editor:RefreshPreviews()
        if not self.frame then
            return
        end

        local tk = self:GetTK()
        if not tk or not tk:EnsureLoaded() then
            self.widgets.interruptPreview:SetText("Failed to load shared tank data.")
            self.widgets.tankBusterPreview:SetText("Failed to load shared tank data.")
            return
        end

        self.widgets.interruptPreview:SetText(tk:BuildInterruptPreview())
        self.widgets.tankBusterPreview:SetText(tk:BuildTankBusterPreview())
    end

    function Editor:ClearInterruptInputs()
        self.widgets.interruptSpellId:SetText("")
        self.widgets.interruptMaxRemaining:SetText("0.8")
        self.widgets.interruptPriority:SetText("high")
        self.widgets.interruptNote:SetText("")
    end

    function Editor:ClearTankBusterInputs()
        self.widgets.tankBusterSpellId:SetText("")
        self.widgets.tankBusterDamageType:SetText("physical")
        self.widgets.tankBusterSeverity:SetText("high")
        self.widgets.tankBusterLeadTime:SetText("1.5")
        self.widgets.tankBusterNote:SetText("")
    end

    function Editor:AddOrUpdateInterrupt()
        local spellId = Trim(self.widgets.interruptSpellId:GetText())
        local maxRemaining = Trim(self.widgets.interruptMaxRemaining:GetText())
        local priority = Trim(self.widgets.interruptPriority:GetText())
        local note = Trim(self.widgets.interruptNote:GetText())

        if spellId == "" then
            ErrorPrint("Interrupt spellId is required")
            return
        end

        local tk = self:GetTK()
        if tk and tk:SetInterruptEntry(spellId, maxRemaining, priority, note) then
            Print("Interrupt entry saved: " .. spellId)
            self:RefreshPreviews()
        else
            ErrorPrint("Failed to save interrupt entry")
        end
    end

    function Editor:RemoveInterrupt()
        local spellId = Trim(self.widgets.interruptSpellId:GetText())
        if spellId == "" then
            ErrorPrint("Interrupt spellId is required")
            return
        end

        local tk = self:GetTK()
        if tk and tk:RemoveInterruptEntry(spellId) then
            Print("Interrupt entry removed: " .. spellId)
            self:RefreshPreviews()
        else
            ErrorPrint("Failed to remove interrupt entry")
        end
    end

    function Editor:AddOrUpdateTankBuster()
        local spellId = Trim(self.widgets.tankBusterSpellId:GetText())
        local damageType = Trim(self.widgets.tankBusterDamageType:GetText())
        local severity = Trim(self.widgets.tankBusterSeverity:GetText())
        local leadTime = Trim(self.widgets.tankBusterLeadTime:GetText())
        local note = Trim(self.widgets.tankBusterNote:GetText())

        if spellId == "" then
            ErrorPrint("Tank buster spellId is required")
            return
        end

        local tk = self:GetTK()
        if tk and tk:SetTankBusterEntry(spellId, damageType, severity, leadTime, note) then
            Print("Tank buster entry saved: " .. spellId)
            self:RefreshPreviews()
        else
            ErrorPrint("Failed to save tank buster entry")
        end
    end

    function Editor:RemoveTankBuster()
        local spellId = Trim(self.widgets.tankBusterSpellId:GetText())
        if spellId == "" then
            ErrorPrint("Tank buster spellId is required")
            return
        end

        local tk = self:GetTK()
        if tk and tk:RemoveTankBusterEntry(spellId) then
            Print("Tank buster entry removed: " .. spellId)
            self:RefreshPreviews()
        else
            ErrorPrint("Failed to remove tank buster entry")
        end
    end

    function Editor:ReloadKnowledge()
        local tk = self:GetTK()
        if tk and tk:Reload() then
            self:RefreshPreviews()
            Print("Tank shared lists reloaded")
            return true
        end

        self:RefreshPreviews()
        ErrorPrint("Tank shared lists reload failed")
        return false
    end

    function Editor:CreateFrame()
        if self.frame then
            return self.frame
        end

        local existingFrame = _G[FRAME_NAME]
        local existingWidgets = existingFrame and existingFrame._wggTankListEditorWidgets or nil
        if existingFrame
            and existingFrame._wggTankListEditorBuilt
            and existingWidgets
            and existingWidgets.interruptPreview
            and existingWidgets.tankBusterPreview
        then
            self.frame = existingFrame
            self.widgets = existingWidgets
            self:ApplyFrameFit()
            return existingFrame
        end

        local tk = self:GetTK()
        local frame = existingFrame or CreateFrame("Frame", FRAME_NAME, UIParent, "BackdropTemplate")
        frame:SetSize(DEFAULT_FRAME_WIDTH, DEFAULT_FRAME_HEIGHT)
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        frame:SetFrameStrata("HIGH")
        frame:SetMovable(true)
        frame:SetClampedToScreen(true)
        frame:EnableMouse(true)
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", frame.StartMoving)
        frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
        frame:Hide()
        SetBackdrop(frame, {0.06, 0.06, 0.06, 0.96}, {0.1, 0.8, 0.55, 1})
        self.frame = frame

        local title = CreateLabel(frame, "Tank Shared Lists", 15)
        title:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -16)

        local subtitle = CreateLabel(frame, "Standalone WGG editor for all tank specs.", 11, {0.7, 0.7, 0.7, 1})
        subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)

        local pathText = CreateLabel(frame, tk and tk.config.dataPath or "TankKnowledge not loaded", 10, {0.5, 0.9, 0.8, 1})
        pathText:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -4)

        local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
        closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)

        local leftPanel = CreateFrame("Frame", nil, frame)
        leftPanel:SetSize(440, 480)
        leftPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -70)

        local rightPanel = CreateFrame("Frame", nil, frame)
        rightPanel:SetSize(440, 480)
        rightPanel:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -16, -70)

        local interruptTitle = CreateLabel(leftPanel, "Interrupt List", 13)
        interruptTitle:SetPoint("TOPLEFT", leftPanel, "TOPLEFT", 0, 0)

        local intSpellContainer, intSpellId = CreateEditField(leftPanel, "Spell ID", 120)
        intSpellContainer:SetPoint("TOPLEFT", interruptTitle, "BOTTOMLEFT", 0, -12)

        local intRemainContainer, intRemain = CreateEditField(leftPanel, "Max Remaining", 120, "0.8")
        intRemainContainer:SetPoint("LEFT", intSpellContainer, "RIGHT", 12, 0)

        local intPriorityContainer, intPriority = CreateEditField(leftPanel, "Priority", 120, "high")
        intPriorityContainer:SetPoint("LEFT", intRemainContainer, "RIGHT", 12, 0)

        local intNoteContainer, intNote = CreateEditField(leftPanel, "Note", 440, "")
        intNoteContainer:SetPoint("TOPLEFT", intSpellContainer, "BOTTOMLEFT", 0, -10)

        local interruptSave = CreateButton(leftPanel, "Add / Update", 120, 24, function()
            Editor:AddOrUpdateInterrupt()
        end)
        interruptSave:SetPoint("TOPLEFT", intNoteContainer, "BOTTOMLEFT", 0, -12)

        local interruptRemove = CreateButton(leftPanel, "Remove", 90, 24, function()
            Editor:RemoveInterrupt()
        end)
        interruptRemove:SetPoint("LEFT", interruptSave, "RIGHT", 10, 0)

        local interruptClear = CreateButton(leftPanel, "Clear", 70, 24, function()
            Editor:ClearInterruptInputs()
        end)
        interruptClear:SetPoint("LEFT", interruptRemove, "RIGHT", 10, 0)

        local interruptHint = CreateLabel(leftPanel, "Format: spellId + maxRemaining(sec) + priority + note", 10, {0.7, 0.7, 0.7, 1})
        interruptHint:SetPoint("TOPLEFT", interruptSave, "BOTTOMLEFT", 0, -8)

        local interruptPreviewBox, interruptPreview = CreatePreviewBox(leftPanel, "Current Interrupt Entries", 440, 280)
        interruptPreviewBox:SetPoint("TOPLEFT", interruptHint, "BOTTOMLEFT", 0, -12)

        local tankTitle = CreateLabel(rightPanel, "Tank Buster List", 13)
        tankTitle:SetPoint("TOPLEFT", rightPanel, "TOPLEFT", 0, 0)

        local tbSpellContainer, tbSpellId = CreateEditField(rightPanel, "Spell ID", 100)
        tbSpellContainer:SetPoint("TOPLEFT", tankTitle, "BOTTOMLEFT", 0, -12)

        local tbTypeContainer, tbType = CreateEditField(rightPanel, "Damage Type", 100, "physical")
        tbTypeContainer:SetPoint("LEFT", tbSpellContainer, "RIGHT", 10, 0)

        local tbSeverityContainer, tbSeverity = CreateEditField(rightPanel, "Severity", 100, "high")
        tbSeverityContainer:SetPoint("LEFT", tbTypeContainer, "RIGHT", 10, 0)

        local tbLeadContainer, tbLead = CreateEditField(rightPanel, "Lead Time", 100, "1.5")
        tbLeadContainer:SetPoint("LEFT", tbSeverityContainer, "RIGHT", 10, 0)

        local tbNoteContainer, tbNote = CreateEditField(rightPanel, "Note", 440, "")
        tbNoteContainer:SetPoint("TOPLEFT", tbSpellContainer, "BOTTOMLEFT", 0, -10)

        local tankSave = CreateButton(rightPanel, "Add / Update", 120, 24, function()
            Editor:AddOrUpdateTankBuster()
        end)
        tankSave:SetPoint("TOPLEFT", tbNoteContainer, "BOTTOMLEFT", 0, -12)

        local tankRemove = CreateButton(rightPanel, "Remove", 90, 24, function()
            Editor:RemoveTankBuster()
        end)
        tankRemove:SetPoint("LEFT", tankSave, "RIGHT", 10, 0)

        local tankClear = CreateButton(rightPanel, "Clear", 70, 24, function()
            Editor:ClearTankBusterInputs()
        end)
        tankClear:SetPoint("LEFT", tankRemove, "RIGHT", 10, 0)

        local tankHint = CreateLabel(rightPanel, "damageType: physical/magic/mixed/other | severity: low/medium/high/critical", 10, {0.7, 0.7, 0.7, 1})
        tankHint:SetPoint("TOPLEFT", tankSave, "BOTTOMLEFT", 0, -8)

        local tankPreviewBox, tankPreview = CreatePreviewBox(rightPanel, "Current Tank Buster Entries", 440, 280)
        tankPreviewBox:SetPoint("TOPLEFT", tankHint, "BOTTOMLEFT", 0, -12)

        local reloadButton = CreateButton(frame, "Reload File", 110, 24, function()
            Editor:ReloadKnowledge()
        end)
        reloadButton:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 16)

        local refreshButton = CreateButton(frame, "Refresh Preview", 120, 24, function()
            Editor:RefreshPreviews()
        end)
        refreshButton:SetPoint("LEFT", reloadButton, "RIGHT", 10, 0)

        local helpText = CreateLabel(frame, "/tanklists to toggle | Shared file for all tank specs", 11, {0.7, 0.7, 0.7, 1})
        helpText:SetPoint("LEFT", refreshButton, "RIGHT", 16, 0)

        self.widgets.interruptSpellId = intSpellId
        self.widgets.interruptMaxRemaining = intRemain
        self.widgets.interruptPriority = intPriority
        self.widgets.interruptNote = intNote
        self.widgets.interruptPreview = interruptPreview

        self.widgets.tankBusterSpellId = tbSpellId
        self.widgets.tankBusterDamageType = tbType
        self.widgets.tankBusterSeverity = tbSeverity
        self.widgets.tankBusterLeadTime = tbLead
        self.widgets.tankBusterNote = tbNote
        self.widgets.tankBusterPreview = tankPreview

        frame._wggTankListEditorBuilt = true
        frame._wggTankListEditorWidgets = self.widgets

        self:ClearInterruptInputs()
        self:ClearTankBusterInputs()
        self:RefreshPreviews()
        self:ApplyFrameFit()

        return frame
    end

    function Editor:Toggle()
        local frame = self:CreateFrame()
        self:ApplyFrameFit()
        if frame:IsShown() then
            frame:Hide()
        else
            self:RefreshPreviews()
            frame:Show()
        end
    end

    local function SlashHandler(msg)
        msg = Trim((msg or ""):lower())

        if msg == "" or msg == "toggle" or msg == "gui" then
            Editor:Toggle()
        elseif msg == "reload" then
            Editor:ReloadKnowledge()
        elseif msg == "path" then
            local tk = Editor:GetTK()
            if tk and tk.config and tk.config.dataPath then
                Print("Tank knowledge path: " .. tk.config.dataPath)
            else
                ErrorPrint("TankKnowledge not loaded")
            end
        else
            Print("Commands:")
            Print("  /tanklists - Toggle editor")
            Print("  /tanklists reload - Reload shared file")
            Print("  /tanklists path - Print shared file path")
        end
    end

    _G.SLASH_WGGTANKLISTS1 = "/tanklists"
    _G.SLASH_WGGTANKLISTS2 = "/tankdb"
    _G.SlashCmdList["WGGTANKLISTS"] = SlashHandler

    Print("Standalone editor loaded. Commands: /tanklists, /tankdb")
    return true
end

local function Bootstrap(attempt)
    attempt = attempt or 0

    if InitializeModule() then
        return
    end

    if not C_Timer or not C_Timer.After then
        ErrorPrint("TankKnowledge_Standalone.lua must load before this module")
        return
    end

    if attempt >= 20 then
        ErrorPrint("Timed out waiting for WGG_TankKnowledge")
        return
    end

    C_Timer.After(0.5, function()
        Bootstrap(attempt + 1)
    end)
end

Bootstrap(0)

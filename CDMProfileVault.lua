-- CDMProfileVault.lua
print("CDMProfileVault: Lua file loaded")

local ADDON_NAME = ...
local SV_NAME = "CDMProfileVaultDB"

-- =========================
-- Addon comms (share/import)
-- =========================
local COMM_PREFIX = "CDMPV1"
local SEP = "\31" -- Unit Separator (safe; profile strings may contain '|')
local CHUNK_SIZE = 220
local SEND_INTERVAL = 0.02

local PendingIncoming = {}   -- [id] = {from, className, profileName, total, parts={}, got={}, gotCount=0, recvChannel}
local CompletedShares = {}   -- [id] = {from, className, profileName, text, receivedAt}
local PendingAccept = nil    -- {id, from, className, profileName, text}

local sendQueue = {}
local sendTicker = nil

local function EnsurePrefixRegistered()
  if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    pcall(C_ChatInfo.RegisterAddonMessagePrefix, COMM_PREFIX)
  else
    pcall(RegisterAddonMessagePrefix, COMM_PREFIX)
  end
end

local function SafeSendAddonMessage(msg, channel, target)
  EnsurePrefixRegistered()
  if C_ChatInfo and C_ChatInfo.SendAddonMessage then
    if channel == "WHISPER" then
      C_ChatInfo.SendAddonMessage(COMM_PREFIX, msg, channel, target)
    else
      C_ChatInfo.SendAddonMessage(COMM_PREFIX, msg, channel)
    end
  else
    SendAddonMessage(COMM_PREFIX, msg, channel, target)
  end
end

local function EnqueueSend(channel, target, msg)
  sendQueue[#sendQueue + 1] = { ch = channel, to = target, msg = msg }
  if sendTicker then return end

  if not C_Timer or not C_Timer.NewTicker then
    local item = table.remove(sendQueue, 1)
    if item then SafeSendAddonMessage(item.msg, item.ch, item.to) end
    return
  end

  sendTicker = C_Timer.NewTicker(SEND_INTERVAL, function()
    if #sendQueue == 0 then
      sendTicker:Cancel()
      sendTicker = nil
      return
    end
    local item = table.remove(sendQueue, 1)
    if item then
      SafeSendAddonMessage(item.msg, item.ch, item.to)
    end
  end)
end

local function MakeShareId()
  local t = time()
  local r = math.random(1000, 9999)
  return tostring(t) .. "-" .. tostring(r)
end

local function Trim(s)
  if not s then return "" end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function SanitizeField(s)
  s = s or ""
  s = s:gsub("\n", " ")
  return s
end

local function ChatPrint(msg)
  if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    DEFAULT_CHAT_FRAME:AddMessage(msg)
  else
    print(msg)
  end
end

local function ShareLink(id)
  return "|Hcdmpv:" .. id .. "|h|cff00ff00[Click to import]|r|h"
end

local function GetMyFullName()
  local n, r = UnitFullName("player")
  if r and r ~= "" then return n .. "-" .. r end
  return n
end

local function StartShare(className, profileName, text, channel, target)
  if not text or text == "" then
    print("CDMProfileVault: Nothing to share (empty string).")
    return
  end

  EnsurePrefixRegistered()

  local id = MakeShareId()
  className = SanitizeField(className)
  profileName = SanitizeField(profileName)

  -- Split into chunks
  local parts = {}
  for i = 1, #text, CHUNK_SIZE do
    parts[#parts + 1] = text:sub(i, i + CHUNK_SIZE - 1)
  end

  -- META: M<SEP>id<SEP>class<SEP>name<SEP>totalParts
  EnqueueSend(channel, target, table.concat({ "M", id, className, profileName, tostring(#parts) }, SEP))

  -- DATA: D<SEP>id<SEP>idx<SEP>payload
  for idx, chunk in ipairs(parts) do
    EnqueueSend(channel, target, table.concat({ "D", id, tostring(idx), chunk }, SEP))
  end

  if channel == "WHISPER" then
    print("CDMProfileVault: Sent share to " .. (target or "?") .. ".")
  else
    print("CDMProfileVault: Sent share to " .. channel .. ".")
  end
end

-- =========================
-- Data
-- =========================
local CLASSES = {
  "Death Knight",
  "Demon Hunter",
  "Druid",
  "Evoker",
  "Hunter",
  "Mage",
  "Monk",
  "Paladin",
  "Priest",
  "Rogue",
  "Shaman",
  "Warlock",
  "Warrior",
}

local CLASS_FILE = {
  ["Death Knight"] = "DEATHKNIGHT",
  ["Demon Hunter"] = "DEMONHUNTER",
  ["Druid"] = "DRUID",
  ["Evoker"] = "EVOKER",
  ["Hunter"] = "HUNTER",
  ["Mage"] = "MAGE",
  ["Monk"] = "MONK",
  ["Paladin"] = "PALADIN",
  ["Priest"] = "PRIEST",
  ["Rogue"] = "ROGUE",
  ["Shaman"] = "SHAMAN",
  ["Warlock"] = "WARLOCK",
  ["Warrior"] = "WARRIOR",
}

local FILE_TO_DISPLAY = {}
for display, file in pairs(CLASS_FILE) do
  FILE_TO_DISPLAY[file] = display
end

local CLASS_ICON_TEXTURE = "Interface\\TargetingFrame\\UI-Classes-Circles"
local CLASS_ICON_TEX_W, CLASS_ICON_TEX_H = 256, 256

local function ClassIconMarkup(className, size)
  local file = CLASS_FILE[className]
  if not file or not CLASS_ICON_TCOORDS or not CLASS_ICON_TCOORDS[file] then
    return ""
  end
  local c = CLASS_ICON_TCOORDS[file]
  local l = math.floor(c[1] * CLASS_ICON_TEX_W + 0.5)
  local r = math.floor(c[2] * CLASS_ICON_TEX_W + 0.5)
  local t = math.floor(c[3] * CLASS_ICON_TEX_H + 0.5)
  local b = math.floor(c[4] * CLASS_ICON_TEX_H + 0.5)

  size = size or 16
  return string.format("|T%s:%d:%d:0:0:%d:%d:%d:%d:%d:%d|t",
    CLASS_ICON_TEXTURE, size, size,
    CLASS_ICON_TEX_W, CLASS_ICON_TEX_H,
    l, r, t, b
  )
end

local FIXED_DATE_FORMAT = "%d %b %Y"

local DEFAULTS = {
  settings = {
    minimap = { show = true, angle = 225 },
  },
  classes = {},
}

local function DeepCopyDefaults(src, dst)
  if type(src) ~= "table" then return src end
  if type(dst) ~= "table" then dst = {} end
  for k, v in pairs(src) do
    if type(v) == "table" then
      dst[k] = DeepCopyDefaults(v, dst[k])
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
  return dst
end

local DB

local function FormatTimestamp(ts)
  if not ts or ts <= 0 then return "Never" end
  return date(FIXED_DATE_FORMAT, ts)
end

-- =========================
-- Style helpers
-- =========================
local function AddToUISpecialFrames(frameName)
  if not UISpecialFrames then return end
  for i = 1, #UISpecialFrames do
    if UISpecialFrames[i] == frameName then return end
  end
  tinsert(UISpecialFrames, frameName)
end

local function ApplyFlatBackground(frame, r, g, b, a)
  r, g, b, a = r or 0.18, g or 0.18, b or 0.18, a or 1.0
  if frame.__cdm_bg then
    frame.__cdm_bg:SetColorTexture(r, g, b, a)
    return
  end
  local bg = frame:CreateTexture(nil, "BACKGROUND", nil, 7)
  bg:SetAllPoints(true)
  bg:SetColorTexture(r, g, b, a)
  frame.__cdm_bg = bg
end

local function ApplySharpBorder(frame, thickness)
  thickness = thickness or 2
  if frame.__cdm_border then return end
  frame.__cdm_border = {}

  local function makeTex()
    local t = frame:CreateTexture(nil, "BORDER")
    t:SetColorTexture(0, 0, 0, 1)
    return t
  end

  local top = makeTex()
  top:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
  top:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
  top:SetHeight(thickness)

  local bottom = makeTex()
  bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
  bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
  bottom:SetHeight(thickness)

  local left = makeTex()
  left:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
  left:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
  left:SetWidth(thickness)

  local right = makeTex()
  right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
  right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
  right:SetWidth(thickness)

  frame.__cdm_border.top = top
  frame.__cdm_border.bottom = bottom
  frame.__cdm_border.left = left
  frame.__cdm_border.right = right
end

local function StripInputBoxArt(editbox)
  if editbox.Left then editbox.Left:SetAlpha(0) end
  if editbox.Middle then editbox.Middle:SetAlpha(0) end
  if editbox.Right then editbox.Right:SetAlpha(0) end
  if editbox.LeftDisabled then editbox.LeftDisabled:SetAlpha(0) end
  if editbox.MiddleDisabled then editbox.MiddleDisabled:SetAlpha(0) end
  if editbox.RightDisabled then editbox.RightDisabled:SetAlpha(0) end
end

-- =========================
-- Profile safety system
-- =========================
local function NormalizeProfile(p)
  if not p then return end
  if p.name == nil then p.name = "" end
  if p.text == nil then p.text = "" end
  if p.lastPasted == nil then p.lastPasted = 0 end
  if p.lastSavedName == nil then p.lastSavedName = p.name end
  if p.lastSavedText == nil then p.lastSavedText = p.text end
  if p.sharedFrom == nil then p.sharedFrom = nil end
  if p.sharedAt == nil then p.sharedAt = nil end
end

local function SafetyRestoreProfileIfEmptied(p)
  if not p then return end
  NormalizeProfile(p)
  if p.name == "" and (p.lastSavedName or "") ~= "" then p.name = p.lastSavedName end
  if p.text == "" and (p.lastSavedText or "") ~= "" then p.text = p.lastSavedText end
end

local function InitDB()
  _G[SV_NAME] = _G[SV_NAME] or {}
  DB = DeepCopyDefaults(DEFAULTS, _G[SV_NAME])

  DB.classes = DB.classes or {}
  for _, className in ipairs(CLASSES) do
    DB.classes[className] = DB.classes[className] or { profiles = {} }
    DB.classes[className].profiles = DB.classes[className].profiles or {}
    for i = 1, #(DB.classes[className].profiles) do
      NormalizeProfile(DB.classes[className].profiles[i])
    end
  end
end

local function EnsureProfilesForClass(className)
  DB.classes[className] = DB.classes[className] or { profiles = {} }
  DB.classes[className].profiles = DB.classes[className].profiles or {}
  local profiles = DB.classes[className].profiles
  for i = 1, #profiles do NormalizeProfile(profiles[i]) end
  return profiles
end

local function RestoreAllProfilesIfEmptied()
  if not DB or not DB.classes then return end
  for _, className in ipairs(CLASSES) do
    local c = DB.classes[className]
    if c and c.profiles then
      for i = 1, #c.profiles do
        SafetyRestoreProfileIfEmptied(c.profiles[i])
      end
    end
  end
end

-- =========================
-- Minimap button
-- =========================
local MinimapButton

local function UpdateMinimapButtonPosition()
  if not MinimapButton then return end
  local angle = tonumber(DB.settings.minimap.angle) or 225
  local rad = math.rad(angle)
  local x = math.cos(rad) * 80
  local y = math.sin(rad) * 80
  MinimapButton:ClearAllPoints()
  MinimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function UpdateMinimapButtonVisibility()
  if not MinimapButton then return end
  if DB.settings.minimap.show then MinimapButton:Show() else MinimapButton:Hide() end
end

local function CreateMinimapButton(toggleMainFrameFunc)
  MinimapButton = CreateFrame("Button", "CDMProfileVaultMinimapButton", Minimap)
  MinimapButton:SetSize(32, 32)
  MinimapButton:SetFrameStrata("MEDIUM")
  MinimapButton:EnableMouse(true)
  MinimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  MinimapButton:RegisterForDrag("LeftButton")

  local icon = MinimapButton:CreateTexture(nil, "BACKGROUND")
  icon:SetAllPoints(true)
  icon:SetTexture("Interface\\Icons\\INV_Misc_Note_01")

  local border = MinimapButton:CreateTexture(nil, "OVERLAY")
  border:SetAllPoints(true)
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

  MinimapButton:SetScript("OnClick", function(_, button)
    if button == "LeftButton" then
      toggleMainFrameFunc()
    else
      DB.settings.minimap.show = not DB.settings.minimap.show
      UpdateMinimapButtonVisibility()
      print("CDMProfileVault minimap button: " .. (DB.settings.minimap.show and "shown" or "hidden"))
    end
  end)

  MinimapButton:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local cx, cy = GetCursorPosition()
      local scale = UIParent:GetScale()
      cx, cy = cx / scale, cy / scale
      local dx, dy = cx - mx, cy - my
      DB.settings.minimap.angle = math.deg(math.atan2(dy, dx))
      UpdateMinimapButtonPosition()
    end)
  end)

  MinimapButton:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
  end)

  UpdateMinimapButtonPosition()
  UpdateMinimapButtonVisibility()
end

-- =========================
-- Dropdown helper (class only)
-- =========================
local function CreateDropdownButton(parent, width, height)
  local ok, dd = pcall(CreateFrame, "DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
  if ok and dd then
    dd:SetSize(width, height)
    return dd
  end
  return nil
end

local function CreateLegacyUIDropDown(parent, width)
  if not UIDropDownMenu_CreateInfo then return nil end
  local dd = CreateFrame("Frame", nil, parent, "UIDropDownMenuTemplate")
  UIDropDownMenu_SetWidth(dd, width)
  return dd
end

-- =========================
-- UI state
-- =========================
local UI = {
  frame = nil,

  classDropdown = nil,
  classDropdownType = nil,
  classIconTex = nil,

  minimapCheck = nil,

  listScroll = nil,
  listChild = nil,
  profileButtons = {},

  selectedClass = CLASSES[1],
  selectedProfileIndex = nil,

  nameEdit = nil,
  textEdit = nil,

  lastPastedLabel = nil,
  sharedByLabel = nil,

  deleteBtn = nil,
  copyBtn = nil,
  shareBtn = nil,
  pasteBtn = nil,
  saveBtn = nil,

  expectingPaste = false,
  copyFrame = nil,
}

local ROW_H = 24

local function GetProfiles()
  return EnsureProfilesForClass(UI.selectedClass)
end

local function GetSelectedProfile()
  if not UI.selectedProfileIndex then return nil end
  local p = GetProfiles()[UI.selectedProfileIndex]
  if p then NormalizeProfile(p) end
  return p
end

local function SafetyRestoreCurrentProfileIfEmptied()
  local p = GetSelectedProfile()
  if not p then return end
  SafetyRestoreProfileIfEmptied(p)
end

local function UpdateClassDropdownText()
  if not UI.classDropdown then return end
  if UI.classDropdownType == "new" then
    UI.classDropdown:OverrideText(UI.selectedClass)
  else
    UIDropDownMenu_SetText(UI.classDropdown, UI.selectedClass)
  end
end

local function SetClassIconTexture(className)
  if not UI.classIconTex then return end
  local file = CLASS_FILE[className]
  if file and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[file] then
    UI.classIconTex:SetTexture(CLASS_ICON_TEXTURE)
    UI.classIconTex:SetTexCoord(unpack(CLASS_ICON_TCOORDS[file]))
    UI.classIconTex:Show()
  else
    UI.classIconTex:Hide()
  end
end

local function SetButtonsEnabled(enabled)
  if enabled then
    UI.nameEdit:Enable()
    UI.textEdit:Enable()
    UI.copyBtn:Enable()
    UI.shareBtn:Enable()
    UI.pasteBtn:Enable()
    UI.saveBtn:Enable()
    UI.deleteBtn:Enable()
  else
    UI.nameEdit:Disable()
    UI.textEdit:Disable()
    UI.copyBtn:Disable()
    UI.shareBtn:Disable()
    UI.pasteBtn:Disable()
    UI.saveBtn:Disable()
    UI.deleteBtn:Disable()
  end
end

local function UpdateSharedByLabel(p)
  if not UI.sharedByLabel then return end
  if p and p.sharedFrom then
    local who = Ambiguate(p.sharedFrom, "short")
    local when = p.sharedAt and FormatTimestamp(p.sharedAt) or "?"
    UI.sharedByLabel:SetText("Shared by: " .. who .. " (" .. when .. ")")
    UI.sharedByLabel:Show()
  else
    UI.sharedByLabel:SetText("")
    UI.sharedByLabel:Hide()
  end
end

local function UpdateEditor()
  local p = GetSelectedProfile()
  if not p then
    UI.nameEdit:SetText("")
    UI.textEdit:SetText("")
    UI.lastPastedLabel:SetText("Last pasted: Never")
    UpdateSharedByLabel(nil)
    SetButtonsEnabled(false)
    return
  end

  SafetyRestoreProfileIfEmptied(p)

  SetButtonsEnabled(true)
  UI.nameEdit:SetText(p.name or "")
  UI.textEdit:SetText(p.text or "")
  UI.lastPastedLabel:SetText("Last pasted: " .. FormatTimestamp(p.lastPasted))
  UpdateSharedByLabel(p)
end

local function AutoSaveName()
  local p = GetSelectedProfile()
  if not p then return end
  p.name = UI.nameEdit:GetText() or ""
end

local function AutoSaveText()
  local p = GetSelectedProfile()
  if not p then return end
  p.text = UI.textEdit:GetText() or ""
end

local function RefreshList()
  local profiles = GetProfiles()

  for i = 1, #profiles do
    if not UI.profileButtons[i] then
      local btn = CreateFrame("Button", nil, UI.listChild)
      btn:SetHeight(ROW_H)
      btn:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
      btn:SetPoint("TOPRIGHT", -6, -(i - 1) * ROW_H)
      btn:RegisterForClicks("LeftButtonUp")

      btn.hl = btn:CreateTexture(nil, "BACKGROUND")
      btn.hl:SetAllPoints(true)
      btn.hl:SetColorTexture(1, 1, 1, 0.10)
      btn.hl:Hide()

      btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
      btn.text:SetPoint("LEFT", 6, 0)
      btn.text:SetJustifyH("LEFT")

      btn:SetScript("OnClick", function(self)
        SafetyRestoreCurrentProfileIfEmptied()
        UI.selectedProfileIndex = self.index
        UpdateEditor()
        RefreshList()
      end)

      UI.profileButtons[i] = btn
    end
  end

  for i = 1, #UI.profileButtons do
    local btn = UI.profileButtons[i]
    local p = profiles[i]
    if p then
      NormalizeProfile(p)
      btn:Show()
      btn.index = i

      local displayName = (p.name and p.name ~= "" and p.name) or ("Profile " .. i)
      if p.sharedFrom then
        displayName = displayName .. " (" .. Ambiguate(p.sharedFrom, "short") .. ")"
      end

      btn.text:SetText(displayName)
      if UI.selectedProfileIndex == i then btn.hl:Show() else btn.hl:Hide() end
    else
      btn:Hide()
      btn.index = nil
    end
  end

  UI.listChild:SetHeight(math.max(1, #profiles * ROW_H))
end

local function SelectClass(className)
  SafetyRestoreCurrentProfileIfEmptied()

  UI.selectedClass = className
  UI.selectedProfileIndex = nil
  UpdateClassDropdownText()
  SetClassIconTexture(className)
  UpdateEditor()
  RefreshList()
end

local function JumpToPlayerClass()
  local _, classFile = UnitClass("player")
  if not classFile then return end
  local display = FILE_TO_DISPLAY[classFile]
  if display and display ~= UI.selectedClass then
    SelectClass(display)
  elseif display then
    UpdateClassDropdownText()
    SetClassIconTexture(display)
  end
end

-- =========================
-- StaticPopups (overwrite every load)
-- =========================

StaticPopupDialogs["CDM_PROFILEVAULT_DELETE_PROFILE"] = {
  text = "Delete profile '%s'?",
  button1 = "Delete",
  button2 = "Cancel",
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,
  OnAccept = function(self, data)
    data = data or self.data
    if not data or not data.className or not data.index then return end
    local className = data.className
    local idx = data.index

    local profiles = EnsureProfilesForClass(className)
    if not profiles[idx] then return end
    table.remove(profiles, idx)

    if UI.selectedClass ~= className then return end
    UI.selectedProfileIndex = (#profiles > 0) and math.min(idx, #profiles) or nil

    UpdateEditor()
    RefreshList()
  end,
}

StaticPopupDialogs["CDM_PROFILEVAULT_SHARE_TO"] = {
  text = "Share this profile.\n\nEnter player name (Name-Realm) to whisper.\nLeave blank to send to Party/Raid.",
  button1 = "Send",
  button2 = "Cancel",
  hasEditBox = true,
  editBoxWidth = 220,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,

  OnShow = function(self, data)
    self.data = data
    local eb = self.editBox or self.EditBox
    if eb then
      eb:SetText((data and data.defaultTarget) or "")
      eb:HighlightText()
      eb:SetFocus()
    end
  end,

  OnAccept = function(self, data)
    data = data or self.data
    if not data or not data.payload then return end

    local eb = self.editBox or self.EditBox
    local target = Trim(eb and eb:GetText() or "")

    local channel, whisperTarget = nil, nil

    if target ~= "" then
      channel = "WHISPER"
      whisperTarget = target
      if not target:find("-", 1, true) then
        print("CDMProfileVault: Note: If the player is on another realm, use Name-Realm.")
      end
    else
      local inInstRaid = IsInRaid and IsInRaid(LE_PARTY_CATEGORY_INSTANCE)
      local inInstParty = IsInGroup and IsInGroup(LE_PARTY_CATEGORY_INSTANCE)

      if inInstRaid or inInstParty then
        channel = "INSTANCE_CHAT"
      elseif IsInRaid() then
        channel = "RAID"
      elseif IsInGroup() then
        channel = "PARTY"
      else
        print("CDMProfileVault: Not in a group. Enter a player name to share.")
        return
      end
    end

    StartShare(data.payload.className, data.payload.profileName, data.payload.text, channel, whisperTarget)
  end,

  EditBoxOnEnterPressed = function(editBox)
    local dialog = editBox.owningDialog or editBox:GetParent()
    if type(StaticPopup_OnClick) == "function" then
      StaticPopup_OnClick(dialog, 1)
      return
    end
  end,
}

StaticPopupDialogs["CDM_PROFILEVAULT_ACCEPT_SHARE"] = {
  text = "Accept shared profile?",
  button1 = "Accept",
  button2 = "Decline",
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
  preferredIndex = 3,

  -- FIX: some builds have self.Text not self.text
  OnShow = function(self)
    if not PendingAccept then return end
    local who = Ambiguate(PendingAccept.from or "?", "short")

    local textRegion = self.text or self.Text
    if not textRegion then return end

    textRegion:SetText(
      "Accept profile from:\n\n" .. who ..
      "\n\nClass: " .. (PendingAccept.className or "?") ..
      "\nName: " .. (PendingAccept.profileName or "?")
    )
  end,

  OnAccept = function()
    if not PendingAccept then return end

    local id = PendingAccept.id
    local className = PendingAccept.className
    local profName = PendingAccept.profileName
    local text = PendingAccept.text
    local from = PendingAccept.from

    if not className or not DB.classes or not DB.classes[className] then
      print("CDMProfileVault: Could not import (unknown class).")
      PendingAccept = nil
      return
    end

    local profiles = EnsureProfilesForClass(className)
    local p = {
      name = profName or "Shared Profile",
      text = text or "",
      lastPasted = time(),
      lastSavedName = profName or "Shared Profile",
      lastSavedText = text or "",
      sharedFrom = from,
      sharedAt = time(),
    }
    NormalizeProfile(p)
    table.insert(profiles, p)

    print("CDMProfileVault: Imported shared profile from " .. Ambiguate(from or "?", "short") .. ".")

    -- IMPORTANT: do NOT clear CompletedShares[id] anymore (so links don't "expire")
    -- if id then CompletedShares[id] = nil end

    if UI.frame and UI.frame:IsShown() then
      SelectClass(className)
      UI.selectedProfileIndex = #EnsureProfilesForClass(className)
      UpdateEditor()
      RefreshList()
    end

    PendingAccept = nil
  end,

  OnCancel = function()
    PendingAccept = nil
  end,
}

-- =========================
-- Class dropdown
-- =========================
local function SetupClassDropdown(parent, labelFrame)
  local dd = CreateDropdownButton(parent, 240, 30)
  if dd then
    UI.classDropdown = dd
    UI.classDropdownType = "new"
    dd:SetPoint("LEFT", labelFrame, "RIGHT", 10, -2)
    dd:SetDefaultText("Select class")
    dd:OverrideText(UI.selectedClass)

    dd:SetupMenu(function(_, root)
      root:CreateTitle("Select class")
      for _, className in ipairs(CLASSES) do
        local text = ClassIconMarkup(className, 16) .. " " .. className
        root:CreateButton(text, function() SelectClass(className) end)
      end
    end)
    return
  end

  local legacy = CreateLegacyUIDropDown(parent, 200)
  if legacy then
    UI.classDropdown = legacy
    UI.classDropdownType = "legacy"
    legacy:SetPoint("LEFT", labelFrame, "RIGHT", -10, -10)
    UIDropDownMenu_SetText(legacy, UI.selectedClass)

    UIDropDownMenu_Initialize(legacy, function(self, level)
      local info = UIDropDownMenu_CreateInfo()
      for _, className in ipairs(CLASSES) do
        local file = CLASS_FILE[className]
        info.text = className
        info.checked = (className == UI.selectedClass)
        info.icon = CLASS_ICON_TEXTURE
        info.iconTexCoords = (file and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[file]) or nil
        info.func = function() SelectClass(className) end
        UIDropDownMenu_AddButton(info, level)
      end
    end)
  end
end

-- =========================
-- Copy popup
-- =========================
local function ShowCopyFrame(text)
  if not UI.copyFrame then
    local f = CreateFrame("Frame", "CDMProfileVaultCopyFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetSize(560, 320)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:Hide()

    ApplyFlatBackground(f, 0.18, 0.18, 0.18, 1.0)
    ApplySharpBorder(f, 2)
    AddToUISpecialFrames("CDMProfileVaultCopyFrame")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("Copy String (Ctrl+C)")

    local sf = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 12, -34)
    sf:SetPoint("BOTTOMRIGHT", -34, 12)

    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true)
    eb:SetFontObject("ChatFontNormal")
    eb:SetWidth(500)
    eb:SetAutoFocus(false)
    eb:EnableMouse(true)
    eb:SetScript("OnEscapePressed", function() f:Hide() end)

    sf:SetScrollChild(eb)
    f.editBox = eb

    UI.copyFrame = f
  end

  UI.copyFrame:Show()
  UI.copyFrame.editBox:SetText(text or "")
  UI.copyFrame.editBox:SetFocus()
  UI.copyFrame.editBox:HighlightText()
end

-- =========================
-- UI
-- =========================
local function CreateUI()
  local f = CreateFrame("Frame", "CDMProfileVaultFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  f:SetSize(780, 540)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetToplevel(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetClampedToScreen(true)
  f:Hide()

  AddToUISpecialFrames("CDMProfileVaultFrame")

  ApplyFlatBackground(f, 0.18, 0.18, 0.18, 1.0)
  ApplySharpBorder(f, 2)

  UI.frame = f

  f:HookScript("OnHide", function()
    SafetyRestoreCurrentProfileIfEmptied()
  end)

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -4, -4)
  close:SetScript("OnClick", function()
    SafetyRestoreCurrentProfileIfEmptied()
    f:Hide()
  end)

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  title:SetPoint("TOP", 0, -10)
  title:SetText("CDMProfileVault")

  local headerLine = f:CreateTexture(nil, "BORDER")
  headerLine:SetColorTexture(0, 0, 0, 1)
  headerLine:SetPoint("TOPLEFT", 2, -40)
  headerLine:SetPoint("TOPRIGHT", -2, -40)
  headerLine:SetHeight(2)

  local mm = CreateFrame("CheckButton", nil, f, "ChatConfigCheckButtonTemplate")
  mm:SetPoint("TOPRIGHT", close, "TOPLEFT", -14, -2)
  mm:SetChecked(DB.settings.minimap.show and true or false)
  mm.Text:SetText("Minimap")
  mm.Text:ClearAllPoints()
  mm.Text:SetPoint("RIGHT", mm, "LEFT", -6, 0)
  UI.minimapCheck = mm
  mm:SetScript("OnClick", function(self)
    DB.settings.minimap.show = self:GetChecked() and true or false
    UpdateMinimapButtonVisibility()
  end)

  local classLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  classLabel:SetPoint("TOPLEFT", 12, -54)
  classLabel:SetText("Class")
  SetupClassDropdown(f, classLabel)

  UI.classIconTex = f:CreateTexture(nil, "ARTWORK")
  UI.classIconTex:SetSize(18, 18)
  UI.classIconTex:SetPoint("LEFT", UI.classDropdown, "RIGHT", 8, 0)
  SetClassIconTexture(UI.selectedClass)

  local topY = -92
  local bottomPad = 12
  local leftW = 280
  local gap = 12

  local listPanel = CreateFrame("Frame", nil, f)
  listPanel:SetPoint("TOPLEFT", 12, topY)
  listPanel:SetPoint("BOTTOMLEFT", 12, bottomPad)
  listPanel:SetWidth(leftW)
  ApplyFlatBackground(listPanel, 0.15, 0.15, 0.15, 1.0)
  ApplySharpBorder(listPanel, 2)

  local rightPanel = CreateFrame("Frame", nil, f)
  rightPanel:SetPoint("TOPLEFT", listPanel, "TOPRIGHT", gap, 0)
  rightPanel:SetPoint("TOPRIGHT", -12, topY)
  rightPanel:SetPoint("BOTTOMRIGHT", -12, bottomPad)
  ApplyFlatBackground(rightPanel, 0.15, 0.15, 0.15, 1.0)
  ApplySharpBorder(rightPanel, 2)

  local listTitle = listPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  listTitle:SetPoint("TOPLEFT", 10, -10)
  listTitle:SetText("Profiles")

  local listHint = listPanel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  listHint:SetPoint("LEFT", listTitle, "RIGHT", 8, 0)
  listHint:SetText("(click to edit)")

  local addBtn = CreateFrame("Button", nil, listPanel)
  addBtn:SetSize(20, 20)
  addBtn:SetPoint("TOPRIGHT", -10, -8)
  addBtn:SetNormalTexture("Interface\\Buttons\\UI-PlusButton-UP")
  addBtn:SetPushedTexture("Interface\\Buttons\\UI-PlusButton-DOWN")
  addBtn:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight", "ADD")
  addBtn:SetScript("OnClick", function()
    local profiles = GetProfiles()
    local p = { name = "New Profile", text = "", lastPasted = 0 }
    NormalizeProfile(p)
    table.insert(profiles, p)
    UI.selectedProfileIndex = #profiles
    UpdateEditor()
    RefreshList()
  end)

  local scroll = CreateFrame("ScrollFrame", nil, listPanel, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 10, -32)
  scroll:SetPoint("BOTTOMRIGHT", -28, 10)
  UI.listScroll = scroll

  local child = CreateFrame("Frame", nil, scroll)
  child:SetHeight(1)
  child:SetWidth(240)
  scroll:SetScrollChild(child)
  UI.listChild = child

  scroll:SetScript("OnSizeChanged", function(self)
    local w = self:GetWidth()
    if w and w > 1 then UI.listChild:SetWidth(w) end
  end)

  local right = CreateFrame("Frame", nil, rightPanel)
  right:SetPoint("TOPLEFT", 12, -12)
  right:SetPoint("BOTTOMRIGHT", -12, 12)

  local nameLabel = right:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  nameLabel:SetPoint("TOPLEFT", 0, 0)
  nameLabel:SetText("Profile name")

  local nameWrap = CreateFrame("Frame", nil, right)
  nameWrap:SetPoint("TOPLEFT", 0, -18)
  nameWrap:SetPoint("TOPRIGHT", -24, -18)
  nameWrap:SetHeight(24)
  ApplyFlatBackground(nameWrap, 0.10, 0.10, 0.10, 1.0)
  ApplySharpBorder(nameWrap, 2)

  local nameEdit = CreateFrame("EditBox", nil, nameWrap, "InputBoxTemplate")
  nameEdit:SetAllPoints(true)
  nameEdit:SetAutoFocus(false)
  nameEdit:SetFontObject("ChatFontNormal")
  nameEdit:SetTextInsets(6, 6, 0, 0)
  nameEdit:EnableMouse(true)
  StripInputBoxArt(nameEdit)

  nameEdit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  nameEdit:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
    if UI.frame then UI.frame:Hide() end
  end)
  nameEdit:SetScript("OnTextChanged", function(_, userInput)
    if userInput then
      AutoSaveName()
      RefreshList()
    end
  end)
  UI.nameEdit = nameEdit

  nameEdit:SetScript("OnTabPressed", function()
    if UI.textEdit and UI.textEdit:IsEnabled() then UI.textEdit:SetFocus() end
  end)

  nameWrap:EnableMouse(true)
  nameWrap:SetScript("OnMouseDown", function()
    if UI.nameEdit and UI.nameEdit:IsEnabled() then UI.nameEdit:SetFocus() end
  end)
  nameLabel:EnableMouse(true)
  nameLabel:SetScript("OnMouseDown", function()
    if UI.nameEdit and UI.nameEdit:IsEnabled() then UI.nameEdit:SetFocus() end
  end)

  local stringLabel = right:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  stringLabel:SetPoint("TOPLEFT", 0, -54)
  stringLabel:SetText("Profile string")

  local BUTTON_ROW_H = 30
  local INFO_ROW_H = 18
  local INFO_GAP = 8
  local BOTTOM_ZONE = BUTTON_ROW_H + INFO_ROW_H + INFO_GAP + 8

  local textWrap = CreateFrame("Frame", nil, right)
  textWrap:SetPoint("TOPLEFT", 0, -72)
  textWrap:SetPoint("BOTTOMRIGHT", -24, BOTTOM_ZONE)
  ApplyFlatBackground(textWrap, 0.10, 0.10, 0.10, 1.0)
  ApplySharpBorder(textWrap, 2)

  local sf = CreateFrame("ScrollFrame", nil, textWrap, "UIPanelScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", 6, -6)
  sf:SetPoint("BOTTOMRIGHT", -24, 6)
  sf:EnableMouse(true)

  local textEdit = CreateFrame("EditBox", nil, sf)
  textEdit:SetMultiLine(true)
  textEdit:SetFontObject("ChatFontNormal")
  textEdit:SetWidth(430)
  textEdit:SetAutoFocus(false)
  textEdit:EnableMouse(true)

  textEdit:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
    if UI.frame then UI.frame:Hide() end
  end)

  sf:SetScrollChild(textEdit)
  UI.textEdit = textEdit

  textEdit:SetScript("OnTabPressed", function()
    if UI.nameEdit and UI.nameEdit:IsEnabled() then UI.nameEdit:SetFocus() end
  end)

  textEdit:SetScript("OnTextChanged", function(_, userInput)
    if userInput then AutoSaveText() end
    if userInput and UI.expectingPaste and UI.selectedProfileIndex then
      UI.expectingPaste = false
      local p = GetSelectedProfile()
      if p then
        p.lastPasted = time()
        UI.lastPastedLabel:SetText("Last pasted: " .. FormatTimestamp(p.lastPasted))
      end
    end
  end)

  textWrap:EnableMouse(true)
  textWrap:SetScript("OnMouseDown", function()
    if UI.textEdit and UI.textEdit:IsEnabled() then UI.textEdit:SetFocus() end
  end)
  sf:SetScript("OnMouseDown", function()
    if UI.textEdit and UI.textEdit:IsEnabled() then UI.textEdit:SetFocus() end
  end)
  stringLabel:EnableMouse(true)
  stringLabel:SetScript("OnMouseDown", function()
    if UI.textEdit and UI.textEdit:IsEnabled() then UI.textEdit:SetFocus() end
  end)

  UI.sharedByLabel = right:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  UI.sharedByLabel:SetPoint("BOTTOMLEFT", 0, BUTTON_ROW_H + 24)
  UI.sharedByLabel:SetText("")
  UI.sharedByLabel:Hide()

  local last = right:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  last:SetPoint("BOTTOMLEFT", 0, BUTTON_ROW_H + 6)
  last:SetText("Last pasted: Never")
  UI.lastPastedLabel = last

  local BTN_W = 80

  local saveBtn = CreateFrame("Button", nil, right, "UIPanelButtonTemplate")
  saveBtn:SetSize(BTN_W, 26)
  saveBtn:SetPoint("BOTTOMRIGHT", 0, 0)
  saveBtn:SetText("Save")
  UI.saveBtn = saveBtn
  saveBtn:SetScript("OnClick", function()
    local p = GetSelectedProfile()
    if not p then return end
    NormalizeProfile(p)

    p.name = UI.nameEdit:GetText() or ""
    p.text = UI.textEdit:GetText() or ""

    p.lastSavedName = p.name
    p.lastSavedText = p.text

    RefreshList()
    print("CDMProfileVault: saved.")
  end)

  local pasteBtn = CreateFrame("Button", nil, right, "UIPanelButtonTemplate")
  pasteBtn:SetSize(BTN_W, 26)
  pasteBtn:SetPoint("RIGHT", saveBtn, "LEFT", -8, 0)
  pasteBtn:SetText("Paste")
  UI.pasteBtn = pasteBtn
  pasteBtn:SetScript("OnClick", function()
    if not UI.selectedProfileIndex then return end
    UI.expectingPaste = true
    UI.textEdit:SetFocus()
    UI.textEdit:HighlightText()
    print("CDMProfileVault: Press Ctrl+V to paste into the string box.")
  end)

  local copyBtn = CreateFrame("Button", nil, right, "UIPanelButtonTemplate")
  copyBtn:SetSize(BTN_W, 26)
  copyBtn:SetPoint("RIGHT", pasteBtn, "LEFT", -8, 0)
  copyBtn:SetText("Copy")
  UI.copyBtn = copyBtn
  copyBtn:SetScript("OnClick", function()
    local p = GetSelectedProfile()
    if not p then return end
    SafetyRestoreProfileIfEmptied(p)
    ShowCopyFrame(p.text or "")
  end)

  local shareBtn = CreateFrame("Button", nil, right, "UIPanelButtonTemplate")
  shareBtn:SetSize(BTN_W, 26)
  shareBtn:SetPoint("RIGHT", copyBtn, "LEFT", -8, 0)
  shareBtn:SetText("Share")
  UI.shareBtn = shareBtn
  shareBtn:SetScript("OnClick", function()
    local p = GetSelectedProfile()
    if not p then return end
    SafetyRestoreProfileIfEmptied(p)

    local profileName = (p.name and p.name ~= "" and p.name) or ("Profile " .. UI.selectedProfileIndex)
    local payload = p.text or ""
    if payload == "" then
      print("CDMProfileVault: Nothing to share (empty string).")
      return
    end

    local defaultTarget = ""
    if UnitExists("target") and UnitIsPlayer("target") then
      local n, r = UnitName("target")
      if n and r and r ~= "" then defaultTarget = n .. "-" .. r
      elseif n then defaultTarget = n end
    end

    StaticPopup_Show("CDM_PROFILEVAULT_SHARE_TO", nil, nil, {
      defaultTarget = defaultTarget,
      payload = { className = UI.selectedClass, profileName = profileName, text = payload },
    })
  end)

  local deleteBtn = CreateFrame("Button", nil, right, "UIPanelButtonTemplate")
  deleteBtn:SetSize(BTN_W, 26)
  deleteBtn:SetPoint("RIGHT", shareBtn, "LEFT", -8, 0)
  deleteBtn:SetText("Delete")
  UI.deleteBtn = deleteBtn
  deleteBtn:SetScript("OnClick", function()
    if not UI.selectedProfileIndex then return end
    local p = GetSelectedProfile()
    local name = (p and p.name and p.name ~= "" and p.name) or ("Profile " .. UI.selectedProfileIndex)
    StaticPopup_Show("CDM_PROFILEVAULT_DELETE_PROFILE", name, nil, { className = UI.selectedClass, index = UI.selectedProfileIndex })
  end)

  UpdateEditor()
  RefreshList()
end

-- =========================
-- Toggle / slash
-- =========================
local function ToggleMainFrame()
  if not UI.frame then return end
  if UI.frame:IsShown() then
    SafetyRestoreCurrentProfileIfEmptied()
    UI.frame:Hide()
  else
    JumpToPlayerClass()
    UI.frame:Show()
    RefreshList()
  end
end

SLASH_CDMPROFILEVAULT1 = "/cdmv"
SLASH_CDMPROFILEVAULT2 = "/cdmprofilevault"
SlashCmdList["CDMPROFILEVAULT"] = function()
  ToggleMainFrame()
end

-- =========================
-- Clickable chat link handler
-- =========================
local function HandleShareLinkClick(id)
  if not id or id == "" then return end
  local data = CompletedShares[id]
  if not data then
    print("CDMProfileVault: That share is no longer available.")
    return
  end

  if not (UI.frame and UI.frame:IsShown()) then
    ToggleMainFrame()
  end

  PendingAccept = {
    id = id,
    from = data.from,
    className = data.className,
    profileName = data.profileName,
    text = data.text,
  }
  StaticPopup_Show("CDM_PROFILEVAULT_ACCEPT_SHARE")
end

if not _G.CDMPV_SetItemRefWrapped then
  _G.CDMPV_SetItemRefWrapped = true
  local orig = SetItemRef
  SetItemRef = function(link, text, button, chatFrame)
    local linkType, id = strsplit(":", link, 2)
    if linkType == "cdmpv" then
      HandleShareLinkClick(id)
      return
    end
    return orig(link, text, button, chatFrame)
  end
end

-- =========================
-- Incoming comms handler
-- =========================
local function OnAddonMessage(prefix, msg, channel, sender)
  if prefix ~= COMM_PREFIX then return end
  if not msg or msg == "" then return end
  if not sender or sender == "" then return end

  local myFull = GetMyFullName()
  if sender == myFull then return end

  local typ = msg:sub(1, 1)

  if typ == "M" then
    local _, id, className, profileName, total = strsplit(SEP, msg, 5)
    total = tonumber(total or "0") or 0
    if not id or id == "" or total <= 0 then return end

    PendingIncoming[id] = {
      from = sender,
      className = className or "Unknown",
      profileName = profileName or "Shared Profile",
      total = total,
      parts = {},
      got = {},
      gotCount = 0,
      recvChannel = channel,
    }
    return
  end

  if typ == "D" then
    local _, id, idx, payload = strsplit(SEP, msg, 4)
    if not id or not PendingIncoming[id] then return end
    local p = PendingIncoming[id]
    idx = tonumber(idx or "0") or 0
    if idx <= 0 or idx > p.total then return end

    if not p.got[idx] then
      p.got[idx] = true
      p.parts[idx] = payload or ""
      p.gotCount = p.gotCount + 1
    end

    if p.gotCount >= p.total then
      local full = table.concat(p.parts, "")
      PendingIncoming[id] = nil

      local ch = p.recvChannel
      if ch == "PARTY" or ch == "RAID" or ch == "WHISPER" or ch == "INSTANCE_CHAT" then
        CompletedShares[id] = {
          from = p.from,
          className = p.className,
          profileName = p.profileName,
          text = full,
          receivedAt = time(),
        }

        local who = Ambiguate(p.from, "short")
        ChatPrint(string.format(
          "|cff00ff00[CDMProfileVault]|r %s shared: %s / %s %s",
          who,
          p.className or "?",
          p.profileName or "?",
          ShareLink(id)
        ))
      end
    end
    return
  end
end

-- =========================
-- Boot + Logout safety
-- =========================
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_LOGIN")
loader:RegisterEvent("PLAYER_LOGOUT")
loader:RegisterEvent("CHAT_MSG_ADDON")
loader:SetScript("OnEvent", function(_, event, a1, a2, a3, a4)
  if event == "ADDON_LOADED" then
    if a1 ~= ADDON_NAME then return end

    EnsurePrefixRegistered()
    InitDB()

    UI.selectedClass = UI.selectedClass or CLASSES[1]
    EnsureProfilesForClass(UI.selectedClass)

    CreateUI()
    CreateMinimapButton(ToggleMainFrame)

    if AddonCompartmentFrame and AddonCompartmentFrame.RegisterAddon then
      pcall(AddonCompartmentFrame.RegisterAddon, AddonCompartmentFrame, {
        text = "CDMProfileVault",
        icon = "Interface\\Icons\\INV_Misc_Note_01",
        notCheckable = true,
        func = function() ToggleMainFrame() end,
      })
    end

    print("CDMProfileVault loaded. Use /cdmv to open.")
    return
  end

  if event == "PLAYER_LOGIN" then
    EnsurePrefixRegistered()
    return
  end

  if event == "PLAYER_LOGOUT" then
    RestoreAllProfilesIfEmptied()
    SafetyRestoreCurrentProfileIfEmptied()
    return
  end

  if event == "CHAT_MSG_ADDON" then
    local prefix, msg, channel, sender = a1, a2, a3, a4
    OnAddonMessage(prefix, msg, channel, sender)
    return
  end
end)

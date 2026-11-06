-- SpellEfficiency: adds "damage per mana" and "damage per second of cast time" to spell tooltips.
-- Values come from the tooltip itself (damage range in the description, mana cost, cast time).
local ADDON, ns = ...

local COLOR = "|cff7fd4ff"
local defaults = { enabled = true, debug = false }

local function IsSecret(v) return issecretvalue ~= nil and issecretvalue(v) end

local function fmt(v)
  if v >= 100 then return ("%.0f"):format(v) end
  if v >= 10 then return ("%.1f"):format(v) end
  return ("%.2f"):format(v)
end

local function secs(v) return (("%.2f"):format(v):gsub("%.?0+$", "")) end

-- Reads every line of a named tooltip; returns left texts, right texts.
local function ReadLines(tooltip)
  local name = tooltip.GetName and tooltip:GetName()
  if not name then return nil end
  local left, right = {}, {}
  for i = 1, tooltip:NumLines() do
    local l = _G[name .. "TextLeft" .. i]
    local r = _G[name .. "TextRight" .. i]
    local lt = l and l:GetText()
    local rt = r and r:IsShown() and r:GetText()
    if lt and not IsSecret(lt) then left[#left + 1] = lt end
    if rt and not IsSecret(rt) then right[#right + 1] = rt end
  end
  return left, right
end

local function ManaCost(spellID)
  if not (spellID and C_Spell and C_Spell.GetSpellPowerCost) then return nil end
  local ok, costs = pcall(C_Spell.GetSpellPowerCost, spellID)
  if not ok or type(costs) ~= "table" then return nil end
  local manaType = Enum and Enum.PowerType and Enum.PowerType.Mana or 0
  for _, c in ipairs(costs) do
    if not IsSecret(c.cost) and (c.type == manaType or c.name == "MANA") and c.cost and c.cost > 0 then
      return c.cost
    end
  end
  return nil
end

local function CastSeconds(spellID)
  if not (spellID and C_Spell and C_Spell.GetSpellInfo) then return nil end
  local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
  if ok and type(info) == "table" and info.castTime and not IsSecret(info.castTime) and info.castTime > 0 then
    return info.castTime / 1000
  end
  return nil
end

-- Computes average amount, per-mana and per-cast-second values from a spell's tooltip lines.
local function Metrics(left, right, spellID)
  if not left or #left == 0 then return nil end
  local all = {}
  for _, t in ipairs(left) do all[#all + 1] = t end
  for _, t in ipairs(right) do all[#all + 1] = t end
  local header = ns.ParseHeader(all)

  -- Description = every left line after the name, joined as sentences.
  -- Right-hand texts go last so a duration shown there ("15 sec duration") is found too.
  local text = table.concat(left, ". ", 2)
  if #right > 0 then text = text .. ". " .. table.concat(right, ". ") end
  local parsed = ns.Parse(text)
  local kind, bucket = "damage", parsed.damage
  if not bucket.found and parsed.heal.found then kind, bucket = "heal", parsed.heal end
  if not bucket.found then return nil end
  local total = bucket.direct + bucket.periodic
  if total <= 0 then return nil end

  local m = { kind = kind, bucket = bucket, total = total }
  m.mana = ManaCost(spellID) or header.mana
  m.castTime = CastSeconds(spellID) or header.castTime
  if m.castTime then
    m.timeNote = secs(m.castTime) .. " s"
  elseif header.channeled and bucket.duration then
    m.castTime, m.timeNote = bucket.duration, "kanalisiert " .. secs(bucket.duration) .. " s"
  end
  if m.mana and m.mana > 0 then m.perMana = total / m.mana end
  if m.castTime and m.castTime > 0 then m.perSecond = total / m.castTime end
  return m
end

-- Spellbook index: spell name -> { [rank] = spellID }; rebuilt after SPELLS_CHANGED.
local rankIndex

local function RankOf(spellID)
  if not (C_Spell and C_Spell.GetSpellSubtext) then return nil end
  local ok, sub = pcall(C_Spell.GetSpellSubtext, spellID)
  if not ok or type(sub) ~= "string" or IsSecret(sub) then return nil end
  return tonumber(sub:match("(%d+)"))
end

local function BuildRankIndex()
  rankIndex = {}
  local SB = C_SpellBook
  if not (SB and SB.GetNumSpellBookSkillLines and SB.GetSpellBookSkillLineInfo and SB.GetSpellBookItemInfo) then return end
  local bank = Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
  local spellType = Enum.SpellBookItemType and Enum.SpellBookItemType.Spell
  for line = 1, SB.GetNumSpellBookSkillLines() do
    local lineInfo = SB.GetSpellBookSkillLineInfo(line)
    if lineInfo then
      for slot = lineInfo.itemIndexOffset + 1, lineInfo.itemIndexOffset + lineInfo.numSpellBookItems do
        local info = SB.GetSpellBookItemInfo(slot, bank)
        if info and info.spellID and not info.isPassive and (not spellType or info.itemType == spellType) then
          local rank = tonumber((info.subName or ""):match("(%d+)")) or RankOf(info.spellID)
          if rank and info.name and info.name ~= "" then
            rankIndex[info.name] = rankIndex[info.name] or {}
            rankIndex[info.name][rank] = info.spellID
          end
        end
      end
    end
  end
end

-- Highest known rank below the given spell's rank: spellID, rank.
local function PreviousRank(spellID)
  if not spellID then return nil end
  local rank = RankOf(spellID)
  if not rank or rank <= 1 then return nil end
  local name = C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
  if not name or IsSecret(name) then return nil end
  if not rankIndex then BuildRankIndex() end
  local ranks = rankIndex[name]
  if not ranks then return nil end
  for r = rank - 1, 1, -1 do
    if ranks[r] and ranks[r] ~= spellID then return ranks[r], r end
  end
  return nil
end

local function TooltipLinesOf(spellID)
  if not (C_TooltipInfo and C_TooltipInfo.GetSpellByID) then return nil end
  local ok, data = pcall(C_TooltipInfo.GetSpellByID, spellID)
  if not ok or type(data) ~= "table" or type(data.lines) ~= "table" then return nil end
  local left, right = {}, {}
  for _, line in ipairs(data.lines) do
    if line.leftText == nil and line.args and TooltipUtil and TooltipUtil.SurfaceArgs then
      TooltipUtil.SurfaceArgs(line)
    end
    local lt, rt = line.leftText, line.rightText
    if type(lt) == "string" and not IsSecret(lt) and lt ~= "" then left[#left + 1] = lt end
    if type(rt) == "string" and not IsSecret(rt) and rt ~= "" then right[#right + 1] = rt end
  end
  return left, right
end

-- " (+12% zu Rang 2)" in green, or red when the new rank is worse.
local function Delta(new, old, prevRank)
  if not (new and old and old > 0 and prevRank) then return "" end
  local pct = (new / old - 1) * 100
  local color = pct >= 0.05 and "|cff40ff40" or (pct <= -0.05 and "|cffff6060" or "|cffcccccc")
  return (" %s(%+.1f%% zu Rang %d)|r%s"):format(color, pct, prevRank, COLOR)
end

local function AddLines(tooltip, spellID)
  local left, right = ReadLines(tooltip)
  local m = Metrics(left, right, spellID)
  if not m then return end

  local prev, prevRank
  local prevID, r = PreviousRank(spellID)
  if prevID then
    local pl, pr = TooltipLinesOf(prevID)
    local pm = Metrics(pl, pr, prevID)
    if pm and pm.kind == m.kind then prev, prevRank = pm, r end
  end

  local bucket = m.bucket
  local word = m.kind == "heal" and "Heilung" or "Schaden"
  -- Periodic part = whole damage over the full duration.
  local overTime
  if bucket.perTickOnly then
    overTime = "pro Tick, Dauer unbekannt"
  elseif bucket.duration then
    overTime = "über " .. secs(bucket.duration) .. " s"
  else
    overTime = "über Zeit"
  end
  local avgText = fmt(m.total)
  if bucket.periodic > 0 and bucket.direct > 0 then
    avgText = avgText .. (" (%s direkt + %s %s)"):format(fmt(bucket.direct), fmt(bucket.periodic), overTime)
  elseif bucket.periodic > 0 then
    avgText = avgText .. (" (%s)"):format(overTime)
  end

  tooltip:AddLine(" ")
  tooltip:AddLine(COLOR .. "Ø " .. word .. ": " .. avgText .. Delta(m.total, prev and prev.total, prevRank) .. "|r")
  if m.perMana then
    tooltip:AddLine(COLOR .. word .. " pro Mana: " .. fmt(m.perMana)
      .. Delta(m.perMana, prev and prev.perMana, prevRank) .. "|r")
  end
  if m.perSecond then
    tooltip:AddLine(COLOR .. word .. " pro Sek. Zauberzeit: " .. fmt(m.perSecond) .. " (" .. m.timeNote .. ")"
      .. Delta(m.perSecond, prev and prev.perSecond, prevRank) .. "|r")
  end

  if SpellEfficiencyDB.debug then
    print(("|cff7fd4ffSpellEfficiency|r id=%s %s=%s direct=%s periodic=%s dur=%s mana=%s cast=%s prev=%s(R%s)"):format(
      tostring(spellID), m.kind, fmt(m.total), fmt(bucket.direct), fmt(bucket.periodic),
      tostring(bucket.duration), tostring(m.mana), tostring(m.castTime), tostring(prevID), tostring(r)))
  end
end

local function OnSpellTooltip(tooltip, data)
  if not SpellEfficiencyDB or not SpellEfficiencyDB.enabled then return end
  if not tooltip or (tooltip.IsForbidden and tooltip:IsForbidden()) or not tooltip.AddLine then return end
  local spellID = data and data.id
  if IsSecret(spellID) then spellID = nil end
  local ok, err = pcall(AddLines, tooltip, spellID)
  if not ok and SpellEfficiencyDB.debug then print("|cffff5555SpellEfficiency error:|r " .. tostring(err)) end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("SPELLS_CHANGED")
frame:SetScript("OnEvent", function(_, event, name)
  if event == "SPELLS_CHANGED" then rankIndex = nil return end
  if name ~= ADDON then return end
  SpellEfficiencyDB = SpellEfficiencyDB or {}
  for k, v in pairs(defaults) do
    if SpellEfficiencyDB[k] == nil then SpellEfficiencyDB[k] = v end
  end
  if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Spell, OnSpellTooltip)
  else
    print("|cffff5555SpellEfficiency:|r TooltipDataProcessor fehlt, Addon inaktiv.")
  end
  frame:UnregisterEvent("ADDON_LOADED")
end)

SLASH_SPELLEFFICIENCY1 = "/spelleff"
SLASH_SPELLEFFICIENCY2 = "/se"
SlashCmdList.SPELLEFFICIENCY = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  if msg == "debug" then
    SpellEfficiencyDB.debug = not SpellEfficiencyDB.debug
    print("|cff7fd4ffSpellEfficiency|r Debug: " .. (SpellEfficiencyDB.debug and "an" or "aus"))
  else
    SpellEfficiencyDB.enabled = not SpellEfficiencyDB.enabled
    print("|cff7fd4ffSpellEfficiency|r Tooltip-Zeilen: " .. (SpellEfficiencyDB.enabled and "an" or "aus"))
  end
end

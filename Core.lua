-- SpellEfficiency: adds "damage per mana" and "damage per second of cast time" to spell tooltips.
-- Values come from the tooltip itself (damage range in the description, mana cost, cast time).
--
-- In combat the client can hand out "secret" values; comparing or doing math with one raises an error.
-- Every API value goes through Safe(), the spellbook rank index is only rebuilt out of combat, and the
-- last good result per spell is cached, so a combat hover can always fall back to it.
local ADDON, ns = ...

local COLOR = "|cff7fd4ff"
local defaults = { enabled = true, debug = false }
local MAX_ERRORS = 20

local function IsSecret(v) return issecretvalue ~= nil and issecretvalue(v) end
local function Safe(v) if IsSecret(v) then return nil end return v end
local function InCombat() return InCombatLockdown and InCombatLockdown() or false end

local function fmt(v)
  if v >= 100 then return ("%.0f"):format(v) end
  if v >= 10 then return ("%.1f"):format(v) end
  return ("%.2f"):format(v)
end

local function secs(v) return (("%.2f"):format(v):gsub("%.?0+$", "")) end

-- Keeps the last errors (deduplicated) in the saved variables; /se errors shows them.
local function LogError(where, err, spellID)
  local db = SpellEfficiencyDB
  if not db then return end
  db.errors = db.errors or {}
  local msg = tostring(err):sub(1, 300)
  local combat = InCombat()
  for _, e in ipairs(db.errors) do
    if e.where == where and e.msg == msg then
      e.count = (e.count or 1) + 1
      e.last = date("%Y-%m-%d %H:%M:%S")
      e.combat = e.combat or combat
      return
    end
  end
  table.insert(db.errors, 1, { where = where, msg = msg, spellID = spellID, combat = combat, count = 1,
    last = date("%Y-%m-%d %H:%M:%S") })
  while #db.errors > MAX_ERRORS do table.remove(db.errors) end
  if db.debug then print("|cffff5555SpellEfficiency error (" .. where .. "):|r " .. msg) end
end

-- Reads every line of a named tooltip; returns left texts, right texts.
local function ReadLines(tooltip)
  local name = tooltip.GetName and Safe(tooltip:GetName())
  if not name then return nil end
  local left, right = {}, {}
  for i = 1, tooltip:NumLines() do
    local l = _G[name .. "TextLeft" .. i]
    local r = _G[name .. "TextRight" .. i]
    local lt = l and Safe(l:GetText())
    local rt = r and r:IsShown() and Safe(r:GetText())
    if type(lt) == "string" then left[#left + 1] = lt end
    if type(rt) == "string" then right[#right + 1] = rt end
  end
  return left, right
end

local function ManaCost(spellID)
  if not (spellID and C_Spell and C_Spell.GetSpellPowerCost) then return nil end
  local ok, costs = pcall(C_Spell.GetSpellPowerCost, spellID)
  if not ok or type(Safe(costs)) ~= "table" then return nil end
  local manaType = Enum and Enum.PowerType and Enum.PowerType.Mana or 0
  for _, c in ipairs(costs) do
    local ctype, cname, cost = Safe(c.type), Safe(c.name), Safe(c.cost)
    if (ctype == manaType or cname == "MANA") and type(cost) == "number" and cost > 0 then
      return cost
    end
  end
  return nil
end

local function CastSeconds(spellID)
  if not (spellID and C_Spell and C_Spell.GetSpellInfo) then return nil end
  local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
  if not ok or type(Safe(info)) ~= "table" then return nil end
  local castTime = Safe(info.castTime)
  if type(castTime) == "number" and castTime > 0 then return castTime / 1000 end
  return nil
end

-- Computes average amount, per-mana and per-cast-second values from a spell's tooltip lines.
local function Metrics(left, right, spellID)
  if not left or #left == 0 then return nil end
  right = right or {}
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
    m.castTime, m.timeNote = bucket.duration, "channeled " .. secs(bucket.duration) .. " s"
  end
  if m.mana and m.mana > 0 then m.perMana = total / m.mana end
  if m.castTime and m.castTime > 0 then m.perSecond = total / m.castTime end
  return m
end

-- Spellbook index: spell name -> { [rank] = spellID }. Marked dirty by SPELLS_CHANGED and rebuilt
-- only out of combat; in combat the previous index stays in use.
local rankIndex, rankDirty = nil, true
local knownSpells = {}

local function RankOf(spellID)
  if not (C_Spell and C_Spell.GetSpellSubtext) then return nil end
  local ok, sub = pcall(C_Spell.GetSpellSubtext, spellID)
  sub = ok and Safe(sub)
  if type(sub) ~= "string" then return nil end
  return tonumber(sub:match("(%d+)"))
end

local function BuildRankIndex()
  local SB = C_SpellBook
  if not (SB and SB.GetNumSpellBookSkillLines and SB.GetSpellBookSkillLineInfo and SB.GetSpellBookItemInfo) then
    rankIndex, rankDirty = {}, false
    return
  end
  local index, spells = {}, {}
  local bank = Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
  local spellType = Enum.SpellBookItemType and Enum.SpellBookItemType.Spell
  local numLines = Safe(SB.GetNumSpellBookSkillLines()) or 0
  for line = 1, numLines do
    local lineInfo = SB.GetSpellBookSkillLineInfo(line)
    local offset = lineInfo and Safe(lineInfo.itemIndexOffset)
    local count = lineInfo and Safe(lineInfo.numSpellBookItems)
    if offset and count then
      for slot = offset + 1, offset + count do
        local ok, info = pcall(SB.GetSpellBookItemInfo, slot, bank)
        if ok and info then
          local id, name, sub = Safe(info.spellID), Safe(info.name), Safe(info.subName)
          local passive, itemType = Safe(info.isPassive), Safe(info.itemType)
          if id and not passive and (not spellType or itemType == spellType) then
            spells[#spells + 1] = id
            local rank = tonumber((type(sub) == "string" and sub or ""):match("(%d+)")) or RankOf(id)
            if rank and type(name) == "string" and name ~= "" then
              index[name] = index[name] or {}
              index[name][rank] = id
            end
          end
        end
      end
    end
  end
  rankIndex, rankDirty, knownSpells = index, false, spells
end

local function EnsureRankIndex()
  if (rankDirty or not rankIndex) and not InCombat() then
    local ok, err = pcall(BuildRankIndex)
    if not ok then LogError("rank index", err) end
  end
  return rankIndex
end

-- Highest known rank below the given spell's rank: spellID, rank.
local function PreviousRank(spellID)
  if not spellID then return nil end
  local rank = RankOf(spellID)
  if not rank or rank <= 1 then return nil end
  local name = C_Spell.GetSpellName and Safe(C_Spell.GetSpellName(spellID))
  if type(name) ~= "string" then return nil end
  local index = EnsureRankIndex()
  local ranks = index and index[name]
  if not ranks then return nil end
  for r = rank - 1, 1, -1 do
    if ranks[r] and ranks[r] ~= spellID then return ranks[r], r end
  end
  return nil
end

local function TooltipLinesOf(spellID)
  if not (C_TooltipInfo and C_TooltipInfo.GetSpellByID) then return nil end
  local ok, data = pcall(C_TooltipInfo.GetSpellByID, spellID)
  if not ok or type(Safe(data)) ~= "table" or type(Safe(data.lines)) ~= "table" then return nil end
  local left, right = {}, {}
  for _, line in ipairs(data.lines) do
    if line.leftText == nil and line.args and TooltipUtil and TooltipUtil.SurfaceArgs then
      pcall(TooltipUtil.SurfaceArgs, line)
    end
    local lt, rt = Safe(line.leftText), Safe(line.rightText)
    if type(lt) == "string" and lt ~= "" then left[#left + 1] = lt end
    if type(rt) == "string" and rt ~= "" then right[#right + 1] = rt end
  end
  return left, right
end

-- Last good result per spell: { m = metrics, prev = metrics of previous rank, prevRank = n }.
local cache = {}

local function Compute(left, right, spellID)
  local m = Metrics(left, right, spellID)
  if not m then return nil end
  local result = { m = m }
  -- The rank comparison is optional: if it fails, the base lines still show.
  local ok, err = pcall(function()
    local prevID, r = PreviousRank(spellID)
    if prevID then
      local pl, pr = TooltipLinesOf(prevID)
      local pm = Metrics(pl, pr, prevID)
      if pm and pm.kind == m.kind then result.prev, result.prevRank, result.prevID = pm, r, prevID end
    end
  end)
  if not ok then
    LogError("previous rank", err, spellID)
    local old = spellID and cache[spellID]
    if old then result.prev, result.prevRank, result.prevID = old.prev, old.prevRank, old.prevID end
  end
  return result
end

-- Fills the cache for every spellbook spell out of combat, a few per frame, so a spell hovered first in
-- combat can still use cached values if the live read fails.
local warmQueue, warming = {}, false
local function WarmStep()
  if InCombat() then warming = false return end
  for _ = 1, 5 do
    local id = table.remove(warmQueue)
    if not id then warming = false return end
    local ok, res = pcall(function()
      local l, r = TooltipLinesOf(id)
      return Compute(l, r, id)
    end)
    if ok and res then cache[id] = res elseif not ok then LogError("warm", res, id) end
  end
  C_Timer.After(0.05, WarmStep)
end

local function WarmCache()
  if InCombat() or not C_Timer then return end
  EnsureRankIndex()
  warmQueue = {}
  for _, id in ipairs(knownSpells) do warmQueue[#warmQueue + 1] = id end
  if not warming then warming = true C_Timer.After(0.5, WarmStep) end
end

-- " (+12% vs. Rank 2)" in green, or red when the new rank is worse.
local function Delta(new, old, prevRank)
  if not (new and old and old > 0 and prevRank) then return "" end
  local pct = (new / old - 1) * 100
  local color = pct >= 0.05 and "|cff40ff40" or (pct <= -0.05 and "|cffff6060" or "|cffcccccc")
  return (" %s(%+.1f%% vs. Rank %d)|r%s"):format(color, pct, prevRank, COLOR)
end

local function Render(tooltip, result)
  local m, prev, prevRank = result.m, result.prev, result.prevRank
  local bucket = m.bucket
  local word = m.kind == "heal" and "Healing" or "Damage"
  -- Periodic part = whole damage over the full duration.
  local overTime
  if bucket.perTickOnly then
    overTime = "per tick, duration unknown"
  elseif bucket.duration then
    overTime = "over " .. secs(bucket.duration) .. " s"
  else
    overTime = "over time"
  end
  local avgText = fmt(m.total)
  if bucket.periodic > 0 and bucket.direct > 0 then
    avgText = avgText .. (" (%s direct + %s %s)"):format(fmt(bucket.direct), fmt(bucket.periodic), overTime)
  elseif bucket.periodic > 0 then
    avgText = avgText .. (" (%s)"):format(overTime)
  end

  tooltip:AddLine(" ")
  tooltip:AddLine(COLOR .. "Avg " .. word:lower() .. ": " .. avgText .. Delta(m.total, prev and prev.total, prevRank) .. "|r")
  if m.perMana then
    tooltip:AddLine(COLOR .. word .. " per mana: " .. fmt(m.perMana)
      .. Delta(m.perMana, prev and prev.perMana, prevRank) .. "|r")
  end
  if m.perSecond then
    tooltip:AddLine(COLOR .. word .. " per sec of cast time: " .. fmt(m.perSecond) .. " (" .. m.timeNote .. ")"
      .. Delta(m.perSecond, prev and prev.perSecond, prevRank) .. "|r")
  end
end

local function AddLines(tooltip, spellID)
  local result
  local ok, res = pcall(function()
    local left, right = ReadLines(tooltip)
    return Compute(left, right, spellID)
  end)
  if ok and res then
    result = res
    -- In combat the rank can be unreadable; keep the comparison from the last good read.
    local old = spellID and cache[spellID]
    if not res.prev and old and old.prev and old.m.kind == res.m.kind then
      res.prev, res.prevRank, res.prevID = old.prev, old.prevRank, old.prevID
    end
    if spellID then cache[spellID] = res end
  else
    if not ok then LogError("tooltip", res, spellID) end
    result = spellID and cache[spellID]
  end
  if not result then return end
  Render(tooltip, result)

  if SpellEfficiencyDB.debug then
    local m, b = result.m, result.m.bucket
    print(("|cff7fd4ffSpellEfficiency|r id=%s %s=%s direct=%s periodic=%s dur=%s mana=%s cast=%s prev=%s(R%s)%s"):format(
      tostring(spellID), m.kind, fmt(m.total), fmt(b.direct), fmt(b.periodic), tostring(b.duration),
      tostring(m.mana), tostring(m.castTime), tostring(result.prevID), tostring(result.prevRank),
      (ok and res) and "" or " [cached]"))
  end
end

local function OnSpellTooltip(tooltip, data)
  if not SpellEfficiencyDB or not SpellEfficiencyDB.enabled then return end
  if not tooltip or (tooltip.IsForbidden and tooltip:IsForbidden()) or not tooltip.AddLine then return end
  local spellID = data and Safe(data.id)
  if type(spellID) ~= "number" then spellID = nil end
  local ok, err = pcall(AddLines, tooltip, spellID)
  if not ok then LogError("render", err, spellID) end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("SPELLS_CHANGED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:SetScript("OnEvent", function(_, event, name)
  if event == "SPELLS_CHANGED" then
    rankDirty = true
    if not InCombat() then WarmCache() end
    return
  end
  if event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_REGEN_ENABLED" then
    if rankDirty or event == "PLAYER_ENTERING_WORLD" then WarmCache() end
    return
  end
  if name ~= ADDON then return end
  SpellEfficiencyDB = SpellEfficiencyDB or {}
  for k, v in pairs(defaults) do
    if SpellEfficiencyDB[k] == nil then SpellEfficiencyDB[k] = v end
  end
  if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Spell, OnSpellTooltip)
  else
    print("|cffff5555SpellEfficiency:|r TooltipDataProcessor missing, addon inactive.")
  end
  frame:UnregisterEvent("ADDON_LOADED")
end)

SLASH_SPELLEFFICIENCY1 = "/spelleff"
SLASH_SPELLEFFICIENCY2 = "/se"
SlashCmdList.SPELLEFFICIENCY = function(msg)
  msg = (msg or ""):lower():match("^%s*(.-)%s*$")
  if msg == "debug" then
    SpellEfficiencyDB.debug = not SpellEfficiencyDB.debug
    print("|cff7fd4ffSpellEfficiency|r Debug: " .. (SpellEfficiencyDB.debug and "on" or "off"))
  elseif msg == "errors" then
    local errors = SpellEfficiencyDB.errors or {}
    if #errors == 0 then print("|cff7fd4ffSpellEfficiency|r No errors recorded.") end
    for _, e in ipairs(errors) do
      print(("|cff7fd4ffSpellEfficiency|r %s x%d %s spell=%s %s: %s"):format(e.last or "?", e.count or 1,
        e.combat and "[combat]" or "", tostring(e.spellID), e.where or "?", e.msg or "?"))
    end
  elseif msg == "errors clear" then
    SpellEfficiencyDB.errors = {}
    print("|cff7fd4ffSpellEfficiency|r Errors cleared.")
  else
    SpellEfficiencyDB.enabled = not SpellEfficiencyDB.enabled
    print("|cff7fd4ffSpellEfficiency|r Tooltip lines: " .. (SpellEfficiencyDB.enabled and "on" or "off"))
  end
end

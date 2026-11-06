-- SpellEfficiency: parses spell tooltip text (enUS) into average damage / healing amounts.
-- Pure Lua, no game API, so it can be tested outside the client.
local _, ns = ...
ns = ns or {}

local function num(s) return tonumber(s) end

local function averageRanges(text)
  return (text:gsub("(%d+%.?%d*)%s+to%s+(%d+%.?%d*)", function(a, b)
    local v = (num(a) + num(b)) / 2
    return (("%.2f"):format(v):gsub("%.?0+$", ""))
  end))
end

-- Normalise the text: strip colour codes, join lines into sentences, drop thousands separators,
-- replace "X to Y" with the average and drop the school word ("40 Shadow damage" -> "40 damage").
function ns.Normalize(text)
  local t = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|n", " ")
  t = t:gsub("\r", ""):gsub("\n", " ")
  -- "58." at a sentence end must not read as the decimal number "58."
  t = (t .. " "):gsub("(%d)%.(%s)", "%1 .%2")
  t = t:gsub("(%d),(%d%d%d)", "%1%2")
  t = averageRanges(t)
  t = t:gsub("(%d) (%u%a+) and (%u%a+) damage", "%1 damage")
  t = t:gsub("(%d) (%u%a+) damage", "%1 damage")
  return t
end

-- Spell duration from anywhere in the tooltip ("Lasts 15 sec.", "15 sec duration", "Duration: 15 sec").
local function findDuration(fullText)
  local d = fullText:match("[Ll]asts (%d+%.?%d*) sec") or fullText:match("(%d+%.?%d*) sec duration")
    or fullText:match("[Dd]uration:? (%d+%.?%d*) sec")
  if d then return num(d) end
  d = fullText:match("[Ll]asts (%d+%.?%d*) min") or fullText:match("(%d+%.?%d*) min duration")
  return d and num(d) * 60
end

-- Classifies one "N damage" hit by the words that follow it, up to the next amount in the sentence.
-- Returns total, isPeriodic, duration (seconds or nil), perTickOnly; nil total = ignore (self damage).
-- Periodic totals are always the whole damage over the full duration.
local function classify(amount, tail, fullText)
  if tail:match("^%s*to %a*self") or tail:match("^%s*to you") or tail:match("^%s*to the caster") then
    return nil
  end
  -- Per-tick wording first: "5 damage every 3 sec (for|over) 15 sec", "26 damage each second for 3 sec".
  local iv = tail:match("every (%d+%.?%d*) sec")
  if not iv and (tail:match("every second") or tail:match("each second") or tail:match("per second")) then iv = "1" end
  if iv then
    local dur = tail:match("for (%d+%.?%d*) sec") or tail:match("over (%d+%.?%d*) sec") or findDuration(fullText)
    if dur then return amount * num(dur) / num(iv), true, num(dur) end
    return amount, true, nil, true
  end
  -- "40 damage over 12 sec" already is the total.
  local d = tail:match("over (%d+%.?%d*) sec")
  if d then return amount, true, num(d) end
  return amount, false, nil
end

local function newBucket() return { direct = 0, periodic = 0, duration = nil, found = false } end

local function add(bucket, total, periodic, dur, perTickOnly)
  bucket.found = true
  if periodic then
    bucket.periodic = bucket.periodic + total
    if dur and (not bucket.duration or dur > bucket.duration) then bucket.duration = dur end
    if perTickOnly then bucket.perTickOnly = true end
  else
    bucket.direct = bucket.direct + total
  end
end

-- Returns { damage = bucket, heal = bucket }; bucket.found tells whether anything was parsed.
function ns.Parse(text)
  local result = { damage = newBucket(), heal = newBucket() }
  if type(text) ~= "string" or text == "" then return result end
  local t = ns.Normalize(text)
  for rawSentence in (t .. " "):gmatch("(.-)%.%s+") do
    local sentence = rawSentence
    local lower = sentence:lower()
    if not lower:find("absorb") then
      local isHeal = lower:find("heal") ~= nil
      local bucket = isHeal and result.heal or result.damage
      if isHeal and not sentence:find("%d damage") then
        -- "Heals a friendly target for 47 to 58 and another 98 over 21 sec." has no "damage" word:
        -- mark the amounts after "for" / "another" / "additional" so the loop below reads them.
        sentence = sentence:gsub("(%a+) (%d+%.?%d*)(%s*)(%a*)", function(word, n, sp, nextWord)
          local w = word:lower()
          if (w == "for" or w == "another" or w == "additional") and not nextWord:match("^sec") then
            return word .. " " .. n .. " damage" .. sp .. nextWord
          end
        end)
      end
      local pos = 1
      while true do
        local s, e, amount = sentence:find("(%d+%.?%d*) damage", pos)
        if not s then break end
        local tail = sentence:sub(e + 1)
        local nextAmount = tail:find("%d+%.?%d* damage")
        if nextAmount then tail = tail:sub(1, nextAmount - 1) end
        local total, periodic, dur, perTickOnly = classify(num(amount), tail, t)
        if total then add(bucket, total, periodic, dur, perTickOnly) end
        pos = e + 1
      end
    end
  end
  return result
end

-- Cast time / mana from the tooltip header lines, used when the spell API gives nothing.
function ns.ParseHeader(lines)
  local info = {}
  for _, line in ipairs(lines) do
    local m = line:match("^(%d[%d,]*) Mana")
    if m and not info.mana then info.mana = num((m:gsub(",", ""))) end
    local c = line:match("^(%d+%.?%d*) sec cast")
    if c then info.castTime = num(c) end
    if line:match("^Instant") then info.instant = true end
    if line:match("^Channeled") then info.channeled = true end
  end
  return info
end

return ns

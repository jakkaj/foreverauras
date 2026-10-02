-- Preserve countdown and desaturation timers during Shoot's shared cooldown.
if not ForeverAuras.IsLibsOK() then return end
local _, Private = ...
local expiryTimer, refreshQueued
local snapshots, castAfterShot = {}, {}
local shotAt, lastShotUpdate = -math.huge, -math.huge
local window = 3

local function PublicSpell(id)
  return not issecretvalue(id) and type(id) == "number"
end

local function Refresh()
  if refreshQueued then return end
  refreshQueued = true
  C_Timer.After(0, function()
    refreshQueued = nil
    Private.ScanEvents("FA_WAND_TEXT_REFRESH")
    Private.ScanEvents("FA_CDM_REFRESH")
  end)
end

local function Clear()
  wipe(snapshots)
  wipe(castAfterShot)
  shotAt, lastShotUpdate = -math.huge, -math.huge
  if expiryTimer then expiryTimer:Cancel(); expiryTimer = nil end
end

-- Whether Shoot's shared cooldown currently holds copied timers.
local function Holding()
  return GetTime() - shotAt < window
end

-- Refreshes rescan every spell cooldown and CDM display, so they only run when
-- the held timers change: a hold starts or ends, or a spell joins or leaves it.
-- Continuous wanding inside one hold changes nothing and needs no rescan.
local function NoteShot()
  local now = GetTime()
  local changed = not Holding()
  -- Duplicate shot events must not clear a subsequent cast.
  if now - lastShotUpdate > 0.05 then
    shotAt = now
    -- Spells cast since the previous shot are held again from this shot on.
    if next(castAfterShot) then changed = true end
    wipe(castAfterShot)
  end
  lastShotUpdate = now
  if expiryTimer then expiryTimer:Cancel() end
  expiryTimer = C_Timer.NewTimer(window, function()
    expiryTimer = nil
    Refresh()
  end)
  if changed then Refresh() end
end

local function OnEvent(_, event, unit, baseSpellID, spellID)
  if event == "PLAYER_ENTERING_WORLD" then
    Clear()
    Refresh()
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" and unit == "player" then
    -- Outside a hold no timer is copied, so casts there change nothing shown.
    local holding = Holding()
    if not PublicSpell(spellID) then
      -- An unidentified cast cannot safely be attributed to a tracked spell.
      Clear()
      if holding then Refresh() end
    elseif spellID == 5019 then
      NoteShot()
    else
      local released = holding and not castAfterShot[spellID]
      castAfterShot[spellID] = true
      if released then Refresh() end
    end
  elseif event == "SPELL_UPDATE_COOLDOWN" and ((PublicSpell(unit) and unit == 5019) or (PublicSpell(baseSpellID) and baseSpellID == 5019)) then
    -- Only an active public flag identifies a new shot rather than its expiry.
    local info = C_Spell.GetSpellCooldown(5019)
    if info and not issecretvalue(info.isActive) and info.isActive == true then NoteShot() end
  end
end

-- Select before recharge/loss-of-control timers; Blizzard expires the copied duration.
function Private.GetWandCooldownDuration(spellID, duration, source)
  if not PublicSpell(spellID) or spellID == 5019 then return duration end
  -- Keep CDM and Spell trigger samples separate.
  local key = (source or "spell") .. ":" .. spellID
  local holding = GetTime() - shotAt < window and not castAfterShot[spellID]
  if holding then
    -- The second return identifies a copied timer without reading its contents.
    return snapshots[key] or duration, snapshots[key] ~= nil
  end
  if duration and duration.Copy then
    snapshots[key] = duration:Copy()
  else
    snapshots[key] = nil
  end
  return duration
end

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", OnEvent)
frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
frame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")

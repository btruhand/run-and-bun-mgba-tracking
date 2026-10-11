-- Spike 0 probe 2: read-only. Load via Tools > Scripting > File > Load script, then play.
-- Logs battle events and answers the open questions in docs/MEMORY_MAP.md:
--   * does RAM trainer id N correspond to gTrainers entry N or N+1? (matches the enemy party against the ROM)
--   * is the "enemy HP -> 0" signal clean, and which of my mons is credited?
--   * which trainer-flag bits change when a fight is won?
--   * where are the badge flags? (console: snap() before the badge, diff() after)

local PARTY, COUNT, ENEMY = 0x2023a98, 0x2023a95, 0x2023cf0
local BATTLE_MONS, BM_SIZE = 0x20233fc, 0x5c      -- species +0, hp +0x2a, level +0x2c, maxHP +0x2e
local IN_BATTLE = 0x30022c0 + 0x439               -- bit 1
local OPPONENT_A = 0x20381ae
local BATTLE_TYPE = 0x2023364
local SB1_PTR = 0x3005d9c
local TRAINER_FLAGS = 0x16b4                      -- sb1 offset of trainer flag 0
local SPECIES_NAMES = 0x083a0f80
local TRAINERS, TRAINER_STRIDE, TRAINER_COUNT = 0x08398884, 0x28, 865
local LEADERS = { Roxanne=1, Brawly=1, Wattson=1, Flannery=1, Norman=1, Winona=1, Juan=1 }

local PERM = {
  {0,1,2,3},{0,1,3,2},{0,2,1,3},{0,3,1,2},{0,2,3,1},{0,3,2,1},
  {1,0,2,3},{1,0,3,2},{2,0,1,3},{3,0,1,2},{2,0,3,1},{3,0,2,1},
  {1,2,0,3},{1,3,0,2},{2,1,0,3},{3,1,0,2},{2,3,0,1},{3,2,0,1},
  {1,2,3,0},{1,3,2,0},{2,1,3,0},{3,1,2,0},{2,3,1,0},{3,2,1,0},
}

local function log(fmt, ...) console:log(string.format(fmt, ...)) end

local function gba_str(addr, n)
  local s = ""
  for i = 0, n - 1 do
    local c = emu:read8(addr + i)
    if c == 0xFF then break end
    if c >= 0xBB and c <= 0xD4 then s = s .. string.char(65 + c - 0xBB)
    elseif c >= 0xD5 and c <= 0xEE then s = s .. string.char(97 + c - 0xD5)
    elseif c >= 0xA1 and c <= 0xAA then s = s .. string.char(48 + c - 0xA1)
    elseif c == 0 then s = s .. " "
    else s = s .. "?" end
  end
  return s
end

local function species_name(id) return gba_str(SPECIES_NAMES + id * 11, 11) end

local function species_of(addr)
  local pid, ot = emu:read32(addr), emu:read32(addr + 4)
  if pid == 0 and ot == 0 then return nil end
  local pos = PERM[pid % 24 + 1][1]
  return (emu:read32(addr + 32 + pos * 12) ~ pid ~ ot) & 0xFFFF
end

local function trainer_name(i) return gba_str(TRAINERS + i * TRAINER_STRIDE, 12) end

local function trainer_flag(id)
  local sb1 = emu:read32(SB1_PTR)
  return (emu:read8(sb1 + TRAINER_FLAGS + (id >> 3)) >> (id & 7)) & 1
end

-- Which gTrainers entries have a party containing every enemy species?
local function match_trainers(species)
  local out = {}
  for i = 1, TRAINER_COUNT - 1 do
    local e = TRAINERS + i * TRAINER_STRIDE
    local size, ptr = emu:read32(e - 0xC), emu:read32(e - 8)
    if size == #species and ptr >= 0x08000000 and ptr < 0x0a000000 then
      local blob = emu:readRange(ptr, size * 0x28)
      local all = true
      for _, sp in ipairs(species) do
        if not blob:find(string.char(sp & 0xFF, sp >> 8), 1, true) then all = false break end
      end
      if all then out[#out + 1] = i end
    end
  end
  return out
end

local function enemy_species()
  local t = {}
  for i = 0, 5 do
    local sp = species_of(ENEMY + i * 100)
    if sp then t[#t + 1] = sp end
  end
  return t
end

-- Index of the party mon matching a BattleMon (species + level + max HP), or nil.
local function party_index_of(battler)
  local b = BATTLE_MONS + battler * BM_SIZE
  local sp, lvl, maxhp = emu:read16(b), emu:read8(b + 0x2c), emu:read16(b + 0x2e)
  for i = 0, emu:read8(COUNT) - 1 do
    local a = PARTY + i * 100
    if species_of(a) == sp and emu:read8(a + 84) == lvl and emu:read16(a + 88) == maxhp then return i end
  end
end

-- ---- flag diffing (console: snap(), diff()) --------------------------------

local SB1_SPAN = 0x4000
local SKIP = { {0x234, 0x4c0}, {0x4e0, 0xd60}, {0x1940, 0x1a40} } -- party, bag/PC, noisy block (seen changing every few minutes)
local function skipped(o) for _, r in ipairs(SKIP) do if o >= r[1] and o < r[2] then return true end end end

local snapshot
function snap()
  snapshot = emu:readRange(emu:read32(SB1_PTR), SB1_SPAN)
  log("snapshot taken (%d bytes)", #snapshot)
end

function diff()
  if not snapshot then log("run snap() first") return end
  local now = emu:readRange(emu:read32(SB1_PTR), SB1_SPAN)
  local n = 0
  for o = 0, SB1_SPAN - 1 do
    local a, b = snapshot:byte(o + 1), now:byte(o + 1)
    if a ~= b and not skipped(o) then
      local set, clr = {}, {}
      for k = 0, 7 do
        local x, y = (a >> k) & 1, (b >> k) & 1
        if y == 1 and x == 0 then set[#set + 1] = k elseif x == 1 and y == 0 then clr[#clr + 1] = k end
      end
      log("sb1+0x%04x %02x->%02x set[%s] cleared[%s]", o, a, b, table.concat(set, ","), table.concat(clr, ","))
      n = n + 1
    end
  end
  log("%d changed bytes (outside skipped ranges)", n)
end

-- ---- battle watcher --------------------------------------------------------

-- gBattleMons is rewritten in pieces on a switch-in (seen: new species with the dead mon's hp/maxHP/level
-- for up to ~2 seconds), so an hp drop only counts when species, level, maxHP and personality (+0x4c) are unchanged since the last frame.
local function identity(b)
  local a = BATTLE_MONS + b * BM_SIZE
  return emu:read16(a) .. ":" .. emu:read8(a + 0x2c) .. ":" .. emu:read16(a + 0x2e) .. ":" .. emu:read32(a + 0x4c)
end

local ident, killed = {}, {}
local inBattle, hp, flagsAtStart, oppAtStart = false, {}, nil, nil

local function on_battle_start()
  local opp = emu:read16(OPPONENT_A)
  local sp = enemy_species()
  local names = {}
  for _, s in ipairs(sp) do names[#names + 1] = species_name(s) end
  log("== battle start: gBattleTypeFlags=%08x opponent_A=%d enemy party=[%s]", emu:read32(BATTLE_TYPE), opp, table.concat(names, ", "))
  log("   gTrainers[%d]=%q  gTrainers[%d]=%q  gTrainers[%d]=%q", opp - 1, trainer_name(opp - 1), opp, trainer_name(opp), opp + 1, trainer_name(opp + 1))
  local m = match_trainers(sp)
  local ms = {}
  for _, i in ipairs(m) do ms[#ms + 1] = string.format("%d(%s)", i, trainer_name(i)) end
  log("   party-matching table entries: %s  => entry - opponent_A = %s", table.concat(ms, " "), #m == 1 and tostring(m[1] - opp) or "ambiguous (wild battle?)")
  log("   trainer flag for id %d: %d", opp, trainer_flag(opp))
  oppAtStart = opp
  flagsAtStart = emu:readRange(emu:read32(SB1_PTR) + 0x1614, 0x300)
  ident, killed = {}, {}
  for b = 0, 3 do
    hp[b] = emu:read16(BATTLE_MONS + b * BM_SIZE + 0x2a)
    ident[b] = identity(b)
  end
end

local function on_battle_end()
  log("== battle end: trainer flag for id %d now %d", oppAtStart, trainer_flag(oppAtStart))
  local now = emu:readRange(emu:read32(SB1_PTR) + 0x1614, 0x300)
  for o = 0, 0x2ff do
    local a, b = flagsAtStart:byte(o + 1), now:byte(o + 1)
    if a ~= b then log("   flag byte sb1+0x%04x %02x->%02x", 0x1614 + o, a, b) end
  end
end

-- Index of the enemy party mon matching an enemy battler (by personality, BattleMon +0x4c), or nil.
local function enemy_index_of(battler)
  local pid = emu:read32(BATTLE_MONS + battler * BM_SIZE + 0x4c)
  for i = 0, 5 do
    if emu:read32(ENEMY + i * 100) == pid and pid ~= 0 then return i end
  end
end

local function check_kills()
  for b = 0, 3 do
    local addr = BATTLE_MONS + b * BM_SIZE
    local cur = emu:read16(addr + 0x2a)
    local prev = hp[b] or cur
    local id = identity(b)
    local same = ident[b] == nil or ident[b] == id
    ident[b] = id
    if prev > 0 and cur == 0 and not same then
      log("   (ignored hp drop on battler %d: identity changed, mid switch-in)", b)
    elseif prev > 0 and cur == 0 then
      local sp = emu:read16(addr)
      local slot = b % 2 == 1 and enemy_index_of(b) or nil
      if slot and killed[slot] then
        log("   (ignored repeat kill of enemy party slot %d)", slot)
      elseif b % 2 == 1 then
        if slot then killed[slot] = true end
        local who = party_index_of(0) or -1
        local whoName = who >= 0 and species_name(species_of(PARTY + who * 100)) or "?"
        local who2 = (emu:read16(BATTLE_MONS + 2 * BM_SIZE + 0x2a) > 0) and party_index_of(2) or nil
        log("   KILL: enemy battler %d (%s) -> credited player party index %d (%s)%s", b, species_name(sp), who, whoName,
            who2 and string.format(" [partner party index %d]", who2) or "")
      else
        log("   my battler %d (%s) fainted", b, species_name(sp))
      end
    end
    hp[b] = cur
  end
end

-- Frame-level trace of battler 0 and 1 (species / hp / level / maxHP), logged only when a value changes.
-- Set TRACE = false to silence it.
local TRACE = true
local frame, last = 0, {}
local function trace()
  for b = 0, 1 do
    local a = BATTLE_MONS + b * BM_SIZE
    local sp, hpv, lvl, mx = emu:read16(a), emu:read16(a + 0x2a), emu:read8(a + 0x2c), emu:read16(a + 0x2e)
    local key = sp .. ":" .. hpv .. ":" .. lvl .. ":" .. mx
    if last[b] ~= key then
      last[b] = key
      log("   f%d b%d species=%d(%s) hp=%d/%d lvl=%d", frame, b, sp, species_name(sp), hpv, mx, lvl)
    end
  end
end

local function on_frame()
  frame = frame + 1
  local ib = (emu:read8(IN_BATTLE) >> 1) & 1 == 1
  if TRACE and ib then trace() end
  if ib and not inBattle then inBattle = true on_battle_start()
  elseif not ib and inBattle then inBattle = false on_battle_end() end
  if inBattle then check_kills() end
end

if PROBE2_CB then callbacks:remove(PROBE2_CB) end
PROBE2_CB = callbacks:add("frame", on_frame)
log("probe2 loaded. Play a fight; use snap() / diff() in this console around a badge.")

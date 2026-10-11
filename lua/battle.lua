-- Battle tracker. Call step() every frame; it emits events through emit(event):
--   kill   {pid, split, trainer, key, enemy, ambiguous?}   an enemy mon in a trainer battle fainted
--   death  {pid}                                           one of your mons fainted (committed when the battle ends)
--   split  {badges}                                        a gym leader was beaten (leaders defeated, 0..8)
-- `mem` is anything with read8/read16/read32/readRange (mGBA's emu, or a fake in tests).
-- Event ids, run and play time are added by the caller.
--
-- Two facts from real play shape this (docs/MEMORY_MAP.md, "Detecting kills"):
--  * gBattleMons is rewritten in pieces on a switch-in, so an hp drop to 0 only counts when the mon's
--    identity (species, level, max hp, personality, ot id) is unchanged since the previous frame.
--  * gTrainerBattleOpponent_A keeps the last trainer after a battle, so "trainer battle" comes from
--    gBattleTypeFlags (bit 3), not from the opponent id.

local A = require("addresses")
local G = require("gen3")

local B = {}
B.__index = B

local TRAINER_BATTLE, DOUBLE_BATTLE = 0x8, 0x1

local function same_mon(a, b)
  return a.species == b.species and a.level == b.level and a.max_hp == b.max_hp
    and a.personality == b.personality and a.ot_id == b.ot_id
end

function B.new(mem, emit, log)
  return setmetatable({ mem = mem, emit = emit, log = log or function() end, active = false }, B)
end

-- Forget the current battle without emitting anything (play time jumped: a savestate or save was loaded).
function B:reset()
  self.active = false
  self.snap, self.killed, self.fainted, self.faint_order = nil, nil, nil, nil
end

function B:start()
  local mem = self.mem
  local flags = mem:read32(A.battle_type)
  self.active = true
  self.double = flags & DOUBLE_BATTLE ~= 0
  self.trainer = flags & TRAINER_BATTLE ~= 0
  self.opponent = mem:read16(A.opponent_a)
  self.leaders = G.leaders_defeated(mem)
  self.killed, self.fainted, self.faint_order = {}, {}, {}
  self.snap = {}
  for b = 0, 3 do self.snap[b] = G.battle_mon(mem, b) end
  self.log(string.format("battle start: flags=%08x %s%s", flags,
    self.trainer and string.format("trainer %d (%s)", self.opponent, G.trainer_name(mem, self.opponent)) or "wild",
    self.double and " double" or ""))
end

-- Index of the enemy party mon with this personality / ot id, or nil.
function B:enemy_slot(mon)
  if mon.personality == 0 then return nil end
  for i = 0, 5 do
    local a = A.enemy_party + i * A.mon_size
    if self.mem:read32(a) == mon.personality and self.mem:read32(a + 4) == mon.ot_id then return i end
  end
end

-- Which of your battlers gets the credit for a kill happening now: the one on the field. In singles that is
-- battler 0. In doubles without a known attacker, the leftmost battler that was alive; `ambiguous` if both were.
function B:credit()
  local alive = {}
  for _, b in ipairs(self.double and { 0, 2 } or { 0 }) do
    if self.snap[b].hp > 0 then alive[#alive + 1] = b end
  end
  local b = alive[1] or 0
  return self.snap[b], #alive > 1
end

function B:on_enemy_ko(b, mon)
  local slot = self:enemy_slot(mon)
  if slot and self.killed[slot] then
    self.log(string.format("ignored repeat kill of enemy slot %d", slot))
    return
  end
  if slot then self.killed[slot] = true end
  local killer, ambiguous = self:credit()
  local species = G.species_name(self.mem, mon.species)
  local trainer = G.trainer_name(self.mem, self.opponent)
  local ev = {
    type = "kill",
    pid = G.pid_string(killer.personality, killer.ot_id),
    split = math.min(self.leaders + 1, 9),
    trainer = tostring(self.opponent),
    key = self.opponent .. ":" .. (slot or species),
    enemy = trainer ~= "" and (trainer .. "'s " .. species) or species,
  }
  if ambiguous then ev.ambiguous = true end
  self.emit(ev)
end

function B:on_player_faint(mon)
  local pid = G.pid_string(mon.personality, mon.ot_id)
  if not self.fainted[pid] then
    self.fainted[pid] = true
    self.faint_order[#self.faint_order + 1] = pid
  end
end

function B:scan()
  local mem = self.mem
  local now = {}
  for b = 0, 3 do now[b] = G.battle_mon(mem, b) end
  for b = 0, (self.double and 3 or 1) do
    local prev, cur = self.snap[b], now[b]
    if prev.hp > 0 and cur.hp == 0 then
      if not same_mon(prev, cur) then
        self.log(string.format("ignored hp drop on battler %d: identity changed (switch-in)", b))
      elseif b % 2 == 1 then
        if self.trainer then self:on_enemy_ko(b, prev) end
      else
        self:on_player_faint(prev)
      end
    end
  end
  self.snap = now
end

function B:finish()
  self.active = false
  for _, pid in ipairs(self.faint_order) do self.emit({ type = "death", pid = pid }) end
  local leaders = G.leaders_defeated(self.mem)
  if leaders > self.leaders then self.emit({ type = "split", badges = leaders }) end
  self.log(string.format("battle end: %d fainted, leaders %d -> %d", #self.faint_order, self.leaders, leaders))
  self.snap, self.killed, self.fainted, self.faint_order = nil, nil, nil, nil
end

function B:step()
  local in_battle = (self.mem:read8(A.in_battle) >> 1) & 1 == 1
  if in_battle and not self.active then self:start()
  elseif not in_battle and self.active then self:finish() end
  if self.active then self:scan() end
end

return B

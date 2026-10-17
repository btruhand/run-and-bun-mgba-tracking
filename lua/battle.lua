-- Battle tracker. Call step() every frame; it emits events through emit(event):
--   kill   {pid, split, trainer, key, enemy, killedBy?, fallback?, ambiguous?}   an enemy mon in a trainer battle fainted
--          killedBy: what killed it: "attack" (one of yours), "friendly fire" (the enemy's other battler), "self inflicted"
--          (its own: recoil, Explosion); hazard / weather / status are not detected yet
--          fallback: how the credit was picked when it wasn't your attacker ("leftmost"); ambiguous: a fallback with both
--          of yours alive. The two are independent: a fallback kill can carry a killedBy of its own
--   death  {pid, killedBy?}                                one of your mons fainted (committed when the battle ends)
--          killedBy: "attack" (an enemy's), "friendly fire" (your other battler's), "self inflicted" (its own: recoil,
--          Explosion); left out when not known
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

-- What killed the enemy battler b (the event's `killedBy`), or nil when not known, and your battler it was an attack
-- of. gBattlerAttacker is one of yours (battler 0 in singles, 0 or 2 in doubles): "attack"; b itself: "self inflicted"
-- (recoil, Explosion); the enemy's other battler: "friendly fire". The byte keeps its last value, so a hazard / weather
-- / status KO can read as one of these until a turn-phase signal tells them apart.
function B:killed_by(b)
  local attacker = self.mem:read8(A.battler_attacker)
  for _, mine in ipairs(self.double and { 0, 2 } or { 0 }) do
    if attacker == mine then return "attack", mine end
  end
  if attacker == b then return "self inflicted" end
  if self.double and attacker == (b ~ 2) then return "friendly fire" end
end

-- Which of your battlers gets the credit, and the fallback rule (the event's `fallback`) when one picked it. An attack
-- of yours credits the attacker. Any other kill, known or not, takes the leftmost of your battlers that was alive;
-- `ambiguous` if more than one was.
function B:credit(b)
  local killed_by, attacker = self:killed_by(b)
  if killed_by == "attack" then return self.snap[attacker], killed_by, nil, false end
  local alive = {}
  for _, mine in ipairs(self.double and { 0, 2 } or { 0 }) do
    if self.snap[mine].hp > 0 then alive[#alive + 1] = mine end
  end
  return self.snap[alive[1] or 0], killed_by, "leftmost", #alive > 1
end

function B:on_enemy_ko(b, mon)
  local slot = self:enemy_slot(mon)
  if slot and self.killed[slot] then
    self.log(string.format("ignored repeat kill of enemy slot %d", slot))
    return
  end
  if slot then self.killed[slot] = true end
  local killer, killed_by, fallback, ambiguous = self:credit(b)
  local species = G.species_name(self.mem, mon.species)
  local trainer = G.trainer_name(self.mem, self.opponent)
  local ev = {
    type = "kill",
    pid = G.pid_string(killer.personality, killer.ot_id),
    split = math.min(self.leaders + 1, 9),
    trainer = tostring(self.opponent),
    key = self.opponent .. ":" .. (slot or species),
    enemy = trainer ~= "" and (trainer .. "'s " .. species) or species,
    killedBy = killed_by,
    fallback = fallback,
  }
  if ambiguous then ev.ambiguous = true end
  self.emit(ev)
end

-- What killed your battler b: an enemy battler's attack, your other battler's (friendly fire, doubles) or its own
-- (self inflicted: recoil, Explosion, Life Orb). Nil when not known. The same caveat as for kills: the byte keeps its
-- last value after a hazard / weather / status faint.
function B:player_killed_by(b)
  local attacker = self.mem:read8(A.battler_attacker)
  if attacker % 2 == 1 then return "attack" end
  if attacker == b then return "self inflicted" end
  if self.double and attacker == (b ~ 2) then return "friendly fire" end
end

function B:on_player_faint(b, mon)
  local pid = G.pid_string(mon.personality, mon.ot_id)
  if not self.fainted[pid] then
    self.fainted[pid] = { killed_by = self:player_killed_by(b) }
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
        self:on_player_faint(b, prev)
      end
    end
  end
  self.snap = now
end

function B:finish()
  self.active = false
  for _, pid in ipairs(self.faint_order) do
    self.emit({ type = "death", pid = pid, killedBy = self.fainted[pid].killed_by })
  end
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

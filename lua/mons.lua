-- Mon tracker: catches, including the starter. Call step() every frame; it emits through emit(event):
--   catch  {pid, species, nick, location}   a mon joined you (party or PC box)
-- `mem` is anything with read8/read16/read32/readRange (mGBA's emu, or a fake in tests).
-- Event ids, run and play time are added by the caller.
--
-- Where catches come from (docs/MEMORY_MAP.md, "Behaviors that matter"):
--  * A battle that ends with gBattleOutcome = caught. The game writes the caught mon to the party or a box after
--    the nickname prompt, before the battle ends, so at the end it is looked up there by personality + OT id
--    (taken from the enemy party) and read with its final nickname.
--  * Outside battle, a party scan every SCAN_EVERY frames: a mon not seen before, with your OT id, read the same
--    with a valid checksum on two scans in a row. This is the starter (given by script before the first battle).
--    In-game trades also land in the party, but with another OT id; they are logged and left for the trade code.
--
-- Mons already there when tracking starts, or after a savestate / save load (reset), are recorded as known
-- without emitting anything: the sheet may already have them (rows entered by hand have no id, so a catch would
-- add a duplicate row), and the `sync` snapshot is what reconciles them. A mon (personality + OT id) is emitted
-- at most once per timeline; the sheet also ignores a catch for an id it already has. Catching a species you
-- already have is allowed (a new mon, a new row) and only logged.

local A = require("addresses")
local G = require("gen3")

local M = {}
M.__index = M

local CAUGHT = 7
local SCAN_EVERY = 30   -- frames between party scans (twice a second)
local LOOKUP_SCANS = 20 -- scans (~10 s) to keep looking for a caught mon that has not been stored yet

function M.new(mem, emit, log)
  local self = setmetatable({ mem = mem, emit = emit, log = log or function() end }, M)
  self:reset()
  return self
end

-- Forget what was seen (play time jumped: a savestate or save was loaded). The next step re-reads the party and
-- boxes as known, silently.
function M:reset()
  self.known = nil      -- pid -> true, mons that need no catch event; nil until seeded
  self.foreign = {}     -- pid -> true, mons with another OT id already logged
  self.species = {}     -- species id -> true, for the repeated-species note
  self.pending = {}     -- pid -> species, new party mons waiting for a second matching scan
  self.lookups = nil    -- caught enemy mons not found in the party or boxes yet: { ids = {pid...}, tries }
  self.enemies = nil    -- enemy party ids captured when the battle started
  self.in_battle = nil
  self.frame = 0
  self.last_party = nil
end

-- Calls fn(addr, box) for every occupied party slot and PC box slot (by the unencrypted personality / OT id,
-- so a slot that is mid-rewrite still counts).
function M:each_slot(fn)
  local mem = self.mem
  for i = 0, 5 do
    local a = A.party + i * A.mon_size
    if mem:read32(a) ~= 0 or mem:read32(a + 4) ~= 0 then fn(a, false) end
  end
  local storage = G.storage(mem)
  if not storage then return end
  local base = storage + A.box_mons
  local raw = mem:readRange(base, A.box_slots * A.box_mon_size)
  for s = 0, A.box_slots - 1 do
    local pid, ot = string.unpack("<I4I4", raw, s * A.box_mon_size + 1)
    if pid ~= 0 or ot ~= 0 then fn(base + s * A.box_mon_size, true) end
  end
end

function M:seed()
  self.known = {}
  local n = 0
  self:each_slot(function(a, box)
    local m = G.read_mon(self.mem, a, box)
    self.known[m.pid] = true
    if m.valid then self.species[m.species] = true end
    n = n + 1
  end)
  self.log(string.format("%d mons already in the party and boxes (not sent)", n))
end

-- Personality + OT id of every enemy party mon, as pid strings.
function M:enemy_ids()
  local ids = {}
  for i = 0, 5 do
    local a = A.enemy_party + i * A.mon_size
    local pid, ot = self.mem:read32(a), self.mem:read32(a + 4)
    if pid ~= 0 or ot ~= 0 then ids[#ids + 1] = G.pid_string(pid, ot) end
  end
  return ids
end

function M:caught(m)
  self.known[m.pid] = true
  local species = G.species_name(self.mem, m.species)
  if self.species[m.species] then self.log("note: another " .. species .. " (" .. m.pid .. "); sending it as a new mon") end
  self.species[m.species] = true
  self.emit({ type = "catch", pid = m.pid, species = species, nick = m.nick, location = G.map_name(self.mem, m.met_location) })
end

function M:battle_ended()
  local outcome = self.mem:read8(A.battle_outcome)
  local ids = {}
  if outcome == CAUGHT then
    -- The enemy party is still intact after the battle; it also covers a tracker started mid-battle.
    local seen = {}
    for _, list in ipairs({ self.enemies or {}, self:enemy_ids() }) do
      for _, id in ipairs(list) do
        if not seen[id] and not self.known[id] then seen[id] = true ids[#ids + 1] = id end
      end
    end
  end
  self.enemies = nil
  if #ids > 0 then
    self.lookups = { ids = ids, tries = 0 }
    self:look_up()
  end
end

-- Finds the caught mon in the party or boxes. Only one mon is caught per battle, so the first match ends it.
function M:look_up()
  local want = {}
  for _, id in ipairs(self.lookups.ids) do want[id] = true end
  local found, unreadable
  self:each_slot(function(a, box)
    if found then return end
    local id = G.pid_string(self.mem:read32(a), self.mem:read32(a + 4))
    if want[id] then
      local m = G.read_mon(self.mem, a, box)
      if m.valid then found = m else unreadable = true end
    end
  end)
  if found then
    self.lookups = nil
    self:caught(found)
    return
  end
  self.lookups.tries = self.lookups.tries + 1
  if self.lookups.tries > LOOKUP_SCANS then
    self.log("battle ended caught, but the mon is not in the party or boxes (" .. table.concat(self.lookups.ids, ", ") .. ")")
    self.lookups = nil
  elseif unreadable then
    self.log("caught mon found mid-rewrite; reading it again on the next scan")
  end
end

function M:scan()
  local mem = self.mem
  if self.lookups then self:look_up() end -- first, so a caught mon found here is known before the party loop
  local raw = mem:readRange(A.party, 6 * A.mon_size)
  if raw == self.last_party and next(self.pending) == nil then return end
  self.last_party = raw
  local here = {}
  for i = 0, 5 do
    local m = G.read_mon(mem, A.party + i * A.mon_size)
    if m and not self.known[m.pid] and not self.foreign[m.pid] then
      here[m.pid] = true
      if m.valid and not m.egg then
        if self.pending[m.pid] ~= m.species then
          self.pending[m.pid] = m.species -- first sighting (or it changed): wait for the next scan
        elseif m.ot_id ~= G.trainer_id(mem) then
          self.pending[m.pid] = nil
          self.foreign[m.pid] = true
          self.log("new party mon " .. m.pid .. " (" .. G.species_name(mem, m.species) .. ") has another OT id; a trade, not sent")
        else
          self.pending[m.pid] = nil
          self:caught(m)
        end
      end
    end
  end
  for pid in pairs(self.pending) do
    if not here[pid] then self.pending[pid] = nil end
  end
end

function M:step()
  if not self.known then self:seed() end
  local in_battle = (self.mem:read8(A.in_battle) >> 1) & 1 == 1
  if in_battle and not self.in_battle then self.enemies = self:enemy_ids()
  elseif not in_battle and self.in_battle then self:battle_ended() end
  self.in_battle = in_battle
  -- No party scan in battle: a mon caught into a free party slot is there before its nickname is set.
  self.frame = self.frame + 1
  if not in_battle and self.frame % SCAN_EVERY == 0 then self:scan() end
end

return M

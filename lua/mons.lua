-- Mon tracker: catches (including the starter) and evolutions. Call step() every frame; it emits through emit(event):
--   catch  {pid, species, nick, location}   a mon joined you (party or PC box)
--   evolve {pid, from, to, nick?}           a known party mon changed species; nick only if the game renamed it
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
--    A mon that appears in a slot another mon was in, with that mon gone from the party, is not a catch: a script can
--    overwrite a slot with a temporary mon that has your OT id (see mark_temporary).
--
-- Evolutions come from the same party scan: a known mon whose species differs from its last valid read, with the
-- new species read the same with a valid checksum on two scans in a row. Mons only evolve in the party (after a
-- battle, or from an item), so boxes are not watched. The game renames a mon that still has its species name
-- (Scatterbug -> Spewpa) on the same frame as the species; that new name goes in `nick`. A change that keeps the
-- species name (a form change) is only logged.
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
M.LOAD_SETTLE = 60  -- frames to let a save load finish before reading what is already there (see reset)
local LOOKUP_SCANS = 20 -- scans (~10 s) to keep looking for a caught mon that has not been stored yet

function M.new(mem, emit, log)
  local self = setmetatable({ mem = mem, emit = emit, log = log or function() end }, M)
  self:reset()
  return self
end

-- Forget what was seen (play time jumped: a savestate or save was loaded). The next step re-reads the party and
-- boxes as known, silently. After a real save load the play time is valid a few frames before the party is copied in,
-- so the caller passes `settle`: frames to wait before that read (nothing is stepped meanwhile), or every mon that
-- then appears would look new and be sent as a catch.
function M:reset(settle)
  self.settle = settle or 0
  self.known = nil      -- pid -> {species, nick} from the last valid read (empty until one), mons that need no
                        -- catch event; nil until seeded
  self.foreign = {}     -- pid -> true, mons with another OT id already logged
  self.temporary = {}   -- pid -> true, mons that took the slot of a mon that left the party
  self.slots = nil      -- pid of each party slot at the last scan (nil for an empty slot), 0..5
  self.species = {}     -- species id -> true, for the repeated-species note
  self.pending = {}     -- pid -> species, new party mons waiting for a second matching scan
  self.evolving = {}    -- pid -> species, known party mons with a new species waiting for a second matching scan
  self.lookups = nil    -- caught enemy mons not found in the party or boxes yet: { ids = {pid...}, tries }
  self.enemies = nil    -- enemy party ids captured when the battle started
  self.in_battle = nil
  self.frame = 0
  self.last_party = nil
end

function M:each_slot(fn) G.each_slot(self.mem, fn) end

function M:seed()
  self.known = {}
  local n = 0
  self:each_slot(function(a, box)
    local m = G.read_mon(self.mem, a, box)
    self.known[m.pid] = {}
    if m.valid and not m.egg then
      self.known[m.pid] = { species = m.species, nick = m.nick }
      self.species[m.species] = true
    end
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
  self.known[m.pid] = { species = m.species, nick = m.nick }
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

-- A valid, non-egg party read of a known mon `k`: records its species and nickname, or sends the evolution once
-- the new species has read the same on two scans.
function M:check_species(k, m)
  if k.species == nil or k.species == m.species then
    self.evolving[m.pid] = nil
    k.species, k.nick = m.species, m.nick -- first valid read, or a rename (Name Rater): nothing to send
    return
  end
  if self.evolving[m.pid] ~= m.species then
    self.evolving[m.pid] = m.species -- first sighting (or it changed): wait for the next scan
    return
  end
  self.evolving[m.pid] = nil
  local from, to = G.species_name(self.mem, k.species), G.species_name(self.mem, m.species)
  if from == to then
    self.log(string.format("%s (%s) changed form (%d -> %d); not sent", to, m.pid, k.species, m.species))
  else
    self.emit({ type = "evolve", pid = m.pid, from = from, to = to, nick = m.nick ~= k.nick and m.nick or nil })
  end
  self.species[m.species] = true
  k.species, k.nick = m.species, m.nick
end

-- A script can put a temporary mon into an occupied party slot, count unchanged, and put the real one back later. The
-- temporary mon has your OT id and OT name, so nothing in the mon says it is not yours. What gives it away is how it
-- arrives. A mon of yours only enters the party by being appended (a catch, a withdraw) or at the start (the starter,
-- count 0), never into a slot that held another mon which has left the party. So a new pid in a slot whose previous
-- pid is gone from the party is temporary, whatever its checksum reads.
-- Example (observed): Wally's catching tutorial overwrites slot 0 with a Zigzagoon for the whole scene
-- (docs/MEMORY_MAP.md).
-- "Zigzagoon (pid)" for the log; the pid alone when the species is not known (a mon read mid-rewrite, or never read).
function M:label(pid, species)
  if not species then return pid end
  return string.format("%s (%s)", G.species_name(self.mem, species), pid)
end

function M:mark_temporary()
  local mem = self.mem
  local slots, here = {}, {}
  for i = 0, 5 do
    local a = A.party + i * A.mon_size
    local pid, ot = mem:read32(a), mem:read32(a + 4)
    if pid ~= 0 or ot ~= 0 then
      slots[i] = G.pid_string(pid, ot)
      here[slots[i]] = true
    end
  end
  for i = 0, 5 do
    local prev, now = self.slots and self.slots[i], slots[i]
    if prev and now and prev ~= now and not here[prev] and not self.known[now] and not self.temporary[now] then
      self.temporary[now] = true
      local m, k = G.read_mon(mem, A.party + i * A.mon_size), self.known[prev]
      self.log(string.format("party slot %d now holds %s, a temporary mon that took the place of %s; not a catch", i,
        self:label(now, m and m.valid and m.species or nil), self:label(prev, k and k.species)))
    end
  end
  self.slots = slots
end

function M:scan()
  local mem = self.mem
  if self.lookups then self:look_up() end -- first, so a caught mon found here is known before the party loop
  local raw = mem:readRange(A.party, 6 * A.mon_size)
  if raw == self.last_party and next(self.pending) == nil and next(self.evolving) == nil then return end
  self.last_party = raw
  self:mark_temporary()
  local here = {}
  for i = 0, 5 do
    local m = G.read_mon(mem, A.party + i * A.mon_size)
    if m then here[m.pid] = true end
    local k = m and self.known[m.pid]
    if k then
      if m.valid and not m.egg then self:check_species(k, m) end
    elseif m and not self.foreign[m.pid] and not self.temporary[m.pid] then
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
  for _, waiting in ipairs({ self.pending, self.evolving }) do
    for pid in pairs(waiting) do
      if not here[pid] then waiting[pid] = nil end
    end
  end
end

function M:step()
  if self.settle > 0 then
    self.settle = self.settle - 1
    return
  end
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

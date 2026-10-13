-- Fake memory for tests: a sparse byte table with mGBA's read API, plus helpers that write the structures
-- the tracker reads (party mons, battle mons, flags, ROM name tables) at the real Run & Bun addresses.

local A = require("addresses")
local G = require("gen3")

local F = {}
F.__index = F

function F.new()
  local f = setmetatable({ b = {} }, F)
  -- save blocks live in EWRAM; the pointers are what the game keeps in IWRAM
  f.sb1, f.sb2, f.storage = 0x2024cbc, 0x2024018, 0x2028848
  f:write32(A.sb1_ptr, f.sb1)
  f:write32(A.sb2_ptr, f.sb2)
  f:write32(A.storage_ptr, f.storage)
  f:write32(f.sb2 + A.sb2_trainer_id, 0xF9D040AF) -- the OT id the mon helpers default to
  return f
end

-- Like the GBA bus: a misaligned read returns the aligned value rotated right by 8 * (a % size).
-- (Run id was once read with a misaligned read32 and came back as 0x000140AF instead of 0xF9D040AF.)
function F:read8(a) return self.b[a] or 0 end
function F:read16(a)
  local base = a & ~1
  local v = self:read8(base) | self:read8(base + 1) << 8
  if a & 1 == 1 then v = ((v >> 8) | (v << 8)) & 0xFFFF end
  return v
end
function F:read32(a)
  local base = a & ~3
  local v = self:read16(base) | self:read16(base + 2) << 16
  local r = (a & 3) * 8
  if r > 0 then v = ((v >> r) | (v << (32 - r))) & 0xFFFFFFFF end
  return v
end
function F:readRange(a, n)
  local t = {}
  for i = 0, n - 1 do t[#t + 1] = string.char(self.b[a + i] or 0) end
  return table.concat(t)
end

function F:write8(a, v) self.b[a] = v & 0xFF end
function F:write16(a, v) self:write8(a, v) self:write8(a + 1, v >> 8) end
function F:write32(a, v) self:write16(a, v) self:write16(a + 2, v >> 16) end

-- Gen 3 string, padded with 0xFF up to `size` bytes.
function F:write_string(a, s, size)
  for i = 0, size - 1 do self:write8(a + i, 0xFF) end
  for i = 1, #s do
    local c = s:byte(i)
    local g
    if c >= 65 and c <= 90 then g = 0xBB + c - 65
    elseif c >= 97 and c <= 122 then g = 0xD5 + c - 97
    elseif c >= 48 and c <= 57 then g = 0xA1 + c - 48
    elseif c == 32 then g = 0x00
    elseif c == 39 then g = 0xB4
    else error("cannot encode " .. s) end
    self:write8(a + i - 1, g)
  end
end

-- ROM name tables ---------------------------------------------------------------------------------------

function F:species_name(id, name) self:write_string(A.species_names + id * 11, name, 11) end

-- Map section name: the table entry points at a string somewhere in ROM.
function F:map_name(id, name)
  local str = 0x08700000 + id * 32
  self:write32(A.map_names + id * 8 + 4, str)
  self:write_string(str, name, 30)
end

-- RAM trainer id -> the gTrainers entry (id + 1) holds the name
function F:trainer_name(id, name)
  self:write_string(A.trainers + (id + A.trainer_entry_offset) * A.trainer_stride, name, 12)
end

-- Party structs --------------------------------------------------------------------------------------------

-- Writes a mon struct with encrypted, shuffled substructs and a valid checksum, like the game does: 100 bytes,
-- or the first 80 for a PC box slot (`box`). `bad_checksum` imitates the frame where the game is rewriting it;
-- `egg` sets the egg flag.
function F:mon(addr, m, box)
  local pid, ot = m.personality, m.ot_id or 0xF9D040AF
  local key, perm = pid ~ ot, G.PERM[pid % 24 + 1]
  self:write32(addr, pid)
  self:write32(addr + 4, ot)
  self:write_string(addr + 8, m.nick or "", 10)
  self:write8(addr + 19, m.egg and 0x06 or 0x02)
  local words = { [0] = { m.species, 0, 0 }, [1] = { 0, 0, 0 }, [2] = { 0, 0, 0 }, [3] = { (m.met_location or 0) << 8, 0, 0 } }
  local sum = 0
  for t = 0, 3 do
    for i = 0, 2 do
      local w = words[t][i + 1]
      sum = sum + (w & 0xFFFF) + (w >> 16)
      self:write32(addr + 32 + perm[t + 1] * 12 + i * 4, w ~ key)
    end
  end
  self:write16(addr + 28, (sum + (m.bad_checksum and 1 or 0)) & 0xFFFF)
  if box then return end
  self:write8(addr + 84, m.level or 5)
  self:write16(addr + 86, m.hp or 20)
  self:write16(addr + 88, m.max_hp or 20)
end

function F:clear(addr, size) for i = 0, size - 1 do self.b[addr + i] = nil end end

function F:party_mon(slot, m) self:mon(A.party + slot * A.mon_size, m) end
function F:party_empty(slot) self:clear(A.party + slot * A.mon_size, A.mon_size) end

-- PC box slot (box 1-14, slot 0-29).
function F:box_addr(box, slot) return self.storage + A.box_mons + ((box - 1) * 30 + slot) * A.box_mon_size end
function F:box_mon(box, slot, m) self:mon(self:box_addr(box, slot), m, true) end
function F:box_empty(box, slot) self:clear(self:box_addr(box, slot), A.box_mon_size) end

function F:enemy_mon(slot, m) self:mon(A.enemy_party + slot * A.mon_size, m) end

-- Battle state ------------------------------------------------------------------------------------------------

function F:in_battle(on) self:write8(A.in_battle, on and 0x02 or 0x00) end
function F:battle_type(flags) self:write32(A.battle_type, flags) end
function F:opponent(id) self:write16(A.opponent_a, id) end
function F:outcome(v) self:write8(A.battle_outcome, v) end

function F:battle_mon(b, m)
  local a, f = A.battle_mons + b * A.battle_mon_size, A.bm
  self:write16(a + f.species, m.species)
  self:write16(a + f.hp, m.hp)
  self:write8(a + f.level, m.level or 5)
  self:write16(a + f.max_hp, m.max_hp or m.hp)
  self:write32(a + f.personality, m.personality)
  self:write32(a + f.ot_id, m.ot_id or 0xF9D040AF)
end

function F:trainer_flag(id, on)
  local a = self.sb1 + A.trainer_flags + (id >> 3)
  local bit = 1 << (id & 7)
  self:write8(a, on == false and (self:read8(a) & ~bit) or (self:read8(a) | bit))
end

function F:play_time(h, m, s)
  self:write16(self.sb2 + A.sb2_play_time, h)
  self:write8(self.sb2 + A.sb2_play_time + 2, m)
  self:write8(self.sb2 + A.sb2_play_time + 3, s)
end

return F

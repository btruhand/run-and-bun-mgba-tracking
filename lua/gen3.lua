-- Gen 3 decoding on top of a memory object: anything with read8/read16/read32/readRange(addr, len),
-- which is mGBA's `emu` (and the fake memory the tests use).

local A = require("addresses")

local G = {}

-- Substructs (0 growth, 1 attacks, 2 EVs, 3 misc) sit in an order that depends on personality % 24.
-- PERM[p % 24 + 1][type + 1] is the slot (0..3) that holds substruct `type`.
local PERM = {
  {0,1,2,3},{0,1,3,2},{0,2,1,3},{0,3,1,2},{0,2,3,1},{0,3,2,1},
  {1,0,2,3},{1,0,3,2},{2,0,1,3},{3,0,1,2},{2,0,3,1},{3,0,2,1},
  {1,2,0,3},{1,3,0,2},{2,1,0,3},{3,1,0,2},{2,3,0,1},{3,2,0,1},
  {1,2,3,0},{1,3,2,0},{2,1,3,0},{3,1,2,0},{2,3,1,0},{3,2,1,0},
}
G.PERM = PERM

local PUNCT = { [0x00] = " ", [0xAB] = "!", [0xAC] = "?", [0xAD] = ".", [0xAE] = "-", [0xB4] = "'", [0xB8] = ",", [0xBA] = "/" }

function G.decode_string(mem, addr, n)
  local out = {}
  for i = 0, n - 1 do
    local c = mem:read8(addr + i)
    if c == 0xFF then break end
    if c >= 0xBB and c <= 0xD4 then out[#out + 1] = string.char(65 + c - 0xBB)
    elseif c >= 0xD5 and c <= 0xEE then out[#out + 1] = string.char(97 + c - 0xD5)
    elseif c >= 0xA1 and c <= 0xAA then out[#out + 1] = string.char(48 + c - 0xA1)
    else out[#out + 1] = PUNCT[c] or "?" end
  end
  return table.concat(out)
end

function G.pid_string(personality, ot_id)
  return string.format("0x%08X:0x%08X", personality, ot_id)
end

-- A Pokémon struct (party layout, 100 bytes). Returns nil for an empty slot.
function G.read_mon(mem, addr)
  local pid, ot = mem:read32(addr), mem:read32(addr + 4)
  if pid == 0 and ot == 0 then return nil end
  local key = pid ~ ot
  local perm = PERM[pid % 24 + 1]
  local function word(substruct, i) return mem:read32(addr + 32 + perm[substruct + 1] * 12 + i * 4) ~ key end
  local misc0 = word(3, 0)
  return {
    personality = pid,
    ot_id = ot,
    pid = G.pid_string(pid, ot),
    species = word(0, 0) & 0xFFFF,
    nick = G.decode_string(mem, addr + 8, 10),
    met_location = (misc0 >> 8) & 0xFF,
    level = mem:read8(addr + 84),
    hp = mem:read16(addr + 86),
    max_hp = mem:read16(addr + 88),
  }
end

-- gBattleMons[b]: the fields the battle tracker needs, read raw (no decoding).
function G.battle_mon(mem, b)
  local a, f = A.battle_mons + b * A.battle_mon_size, A.bm
  return {
    species = mem:read16(a + f.species),
    hp = mem:read16(a + f.hp),
    level = mem:read8(a + f.level),
    max_hp = mem:read16(a + f.max_hp),
    personality = mem:read32(a + f.personality),
    ot_id = mem:read32(a + f.ot_id),
  }
end

function G.species_name(mem, id) return G.decode_string(mem, A.species_names + id * 11, 11) end

-- RAM trainer id -> name (gTrainers is indexed by id + 1).
function G.trainer_name(mem, id)
  local entry = id + A.trainer_entry_offset
  if entry < 0 or entry >= A.trainer_count then return "" end
  return G.decode_string(mem, A.trainers + entry * A.trainer_stride, 12)
end

function G.map_name(mem, id)
  if id == 255 then return "Fateful Encounter" end
  local ptr = mem:read32(A.map_names + id * 8 + 4)
  if ptr < 0x08000000 or ptr >= 0x0a000000 then return "" end
  return G.decode_string(mem, ptr, 30)
end

local function sb(mem, ptr_addr)
  local p = mem:read32(ptr_addr)
  if p < 0x02000000 or p >= 0x02040000 then return nil end -- not loaded yet (title screen, new game intro)
  return p
end

function G.trainer_flag(mem, id)
  local sb1 = sb(mem, A.sb1_ptr)
  if not sb1 then return false end
  return (mem:read8(sb1 + A.trainer_flags + (id >> 3)) >> (id & 7)) & 1 == 1
end

-- How many of the eight gym leaders are defeated (0..8). The split is this + 1.
function G.leaders_defeated(mem)
  local n = 0
  for _, id in ipairs(A.gym_leaders) do
    if G.trainer_flag(mem, id) then n = n + 1 end
  end
  return n
end

-- In-game play time in seconds, or nil before a save is loaded.
function G.play_time(mem)
  local s = sb(mem, A.sb2_ptr)
  if not s then return nil end
  return mem:read16(s + A.sb2_play_time) * 3600 + mem:read8(s + A.sb2_play_time + 2) * 60 + mem:read8(s + A.sb2_play_time + 3)
end

-- Identifies the save (trainer id + secret id), or nil before a save is loaded.
function G.run_id(mem)
  local s = sb(mem, A.sb2_ptr)
  if not s then return nil end
  -- The id sits at a 2-byte aligned offset, and a misaligned read32 returns a rotated word on the GBA bus.
  local o = s + A.sb2_trainer_id
  return string.format("0x%08X", mem:read16(o) | mem:read16(o + 2) << 16)
end

-- True if the loaded ROM looks like the 1.0.7 the addresses were found for.
function G.verify(mem)
  local checks = {
    { "species #1", G.species_name(mem, 1), "Bulbasaur" },
    { "trainer #1", G.decode_string(mem, A.trainers + A.trainer_stride, 12), "Sawyer" },
    { "map #0", G.map_name(mem, 0), "Littleroot Town" },
  }
  for _, c in ipairs(checks) do
    if c[2] ~= c[3] then return false, string.format("%s is %q, expected %q", c[1], c[2], c[3]) end
  end
  return true
end

return G

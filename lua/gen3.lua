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

local PUNCT = {
  [0x00] = " ", [0xAB] = "!", [0xAC] = "?", [0xAD] = ".", [0xAE] = "-", [0xB4] = "'", [0xB8] = ",", [0xBA] = "/",
  [0x1B] = "é", [0xB5] = "♂", [0xB6] = "♀", [0xF0] = ":", -- Flabébé, Pokémon; Nidoran♂/♀; Type: Null
}

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

-- The substruct checksum (u16 at +28) is the sum of the 48 decrypted bytes taken as u16s. The game decrypts a mon
-- in place while it works on it, so for single frames the substructs are garbage and this fails.
function G.checksum_ok(mem, addr)
  local key, sum = mem:read32(addr) ~ mem:read32(addr + 4), 0
  for i = 0, 11 do
    local w = mem:read32(addr + 32 + i * 4) ~ key
    sum = sum + (w & 0xFFFF) + (w >> 16)
  end
  return sum & 0xFFFF == mem:read16(addr + 28)
end

-- A Pokémon struct (party layout, 100 bytes; `box` for the 80-byte PC layout, which has no level or HP).
-- Returns nil for an empty slot. `valid` is false while the game is rewriting it (see G.checksum_ok); species,
-- nickname and met location are only meaningful when it is true. Identity (`pid`) is always readable.
function G.read_mon(mem, addr, box)
  local pid, ot = mem:read32(addr), mem:read32(addr + 4)
  if pid == 0 and ot == 0 then return nil end
  local key = pid ~ ot
  local perm = PERM[pid % 24 + 1]
  local function word(substruct, i) return mem:read32(addr + 32 + perm[substruct + 1] * 12 + i * 4) ~ key end
  local misc0 = word(3, 0)
  local flags = mem:read8(addr + 19) -- bit 0 bad egg, bit 1 has species, bit 2 egg
  local m = {
    personality = pid,
    ot_id = ot,
    pid = G.pid_string(pid, ot),
    species = word(0, 0) & 0xFFFF,
    nick = G.decode_string(mem, addr + 8, 10),
    met_location = (misc0 >> 8) & 0xFF,
    egg = flags & 0x04 ~= 0,
    valid = flags & 0x03 == 0x02 and G.checksum_ok(mem, addr),
  }
  if not box then
    m.level, m.hp, m.max_hp = mem:read8(addr + 84), mem:read16(addr + 86), mem:read16(addr + 88)
  end
  return m
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

-- Species names are sent as the sheet spells them: its Species dropdown only takes the names in the Sprites tab
-- (column D), and the sprite lookup uses them too.
-- The ROM keeps 10 characters, so it shortens longer names:
local FULL_NAMES = {
  Barraskewd = "Barraskewda", Basclegion = "Basculegion", Blacphalon = "Blacephalon", Centskorch = "Centiskorch",
  Corvknight = "Corviknight", Corvsquire = "Corvisquire", Crabminabl = "Crabominable", Flechinder = "Fletchinder",
  Polteageis = "Polteageist", Stonjourne = "Stonjourner",
}
-- The sheet's own spellings:
local SHEET_NAMES = { ["Flabébé"] = "Flabebe", ["Nidoran♀"] = "Nidoran-F", ["Nidoran♂"] = "Nidoran-M" }
-- Forms the ROM names alike but the sheet tells apart, by species id (read from each id's types and base stats):
local FORM_NAMES = {
  [741] = "Oricorio-Baile", [1169] = "Oricorio-Pom", [1170] = "Oricorio-Pau", [1171] = "Oricorio-Sensu",
  [745] = "Lycanroc Midday", [1173] = "Lycanroc Midnight", [1174] = "Lycanroc Dusk",
  [892] = "Urshifu Single", [1230] = "Urshifu Rapid",
}

function G.species_name(mem, id)
  if FORM_NAMES[id] then return FORM_NAMES[id] end
  local name = G.decode_string(mem, A.species_names + id * 11, 11)
  name = FULL_NAMES[name] or name
  return SHEET_NAMES[name] or name
end

-- RAM trainer id -> name.
function G.trainer_name(mem, id)
  if id < 0 or id >= A.trainer_count then return "" end
  return G.decode_string(mem, A.trainers + id * A.trainer_stride, 12)
end

function G.map_name(mem, id)
  if id == 255 then return "Fateful Encounter" end
  if id >= A.map_count then return "" end
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

-- RAM trainer ids of every trainer whose defeated flag is set, in ascending order (nil before a save is loaded).
function G.defeated_trainers(mem)
  local sb1 = sb(mem, A.sb1_ptr)
  if not sb1 then return nil end
  local raw = mem:readRange(sb1 + A.trainer_flags, (A.trainer_count + 7) // 8)
  local ids = {}
  for id = 0, A.trainer_count - 1 do
    if (raw:byte((id >> 3) + 1) >> (id & 7)) & 1 == 1 then ids[#ids + 1] = id end
  end
  return ids
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

-- The player's trainer id + secret id (u32, the OT id of mons you caught), or nil before a save is loaded.
function G.trainer_id(mem)
  local s = sb(mem, A.sb2_ptr)
  if not s then return nil end
  -- The id sits at a 2-byte aligned offset, and a misaligned read32 returns a rotated word on the GBA bus.
  local o = s + A.sb2_trainer_id
  return mem:read16(o) | mem:read16(o + 2) << 16
end

-- Identifies the save (trainer id + secret id), or nil before a save is loaded.
function G.run_id(mem)
  local id = G.trainer_id(mem)
  return id and string.format("0x%08X", id)
end

-- Calls fn(addr, box) for every occupied party slot and PC box slot (by the unencrypted personality / OT id, so a
-- slot that is mid-rewrite still counts). Returns false if the PC storage isn't loaded (the party is still visited).
function G.each_slot(mem, fn)
  for i = 0, 5 do
    local a = A.party + i * A.mon_size
    if mem:read32(a) ~= 0 or mem:read32(a + 4) ~= 0 then fn(a, false) end
  end
  local storage = G.storage(mem)
  if not storage then return false end
  local base = storage + A.box_mons
  local raw = mem:readRange(base, A.box_slots * A.box_mon_size)
  for s = 0, A.box_slots - 1 do
    local pid, ot = string.unpack("<I4I4", raw, s * A.box_mon_size + 1)
    if pid ~= 0 or ot ~= 0 then fn(base + s * A.box_mon_size, true) end
  end
  return true
end

-- Address of the PC storage (gPokemonStorage), or nil before a save is loaded.
function G.storage(mem)
  return sb(mem, A.storage_ptr)
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
  -- the poison turn-damage script starts with `printstring STRINGID_HURTBYPOISON` (0x10, 0x2a, 0x00), the burn one
  -- (0x0833ac7a) with `printstring STRINGID_HURTBYBURN` (0x10, 0x30, 0x00)
  local function printstring(a, id) return mem:read8(a) == 0x10 and mem:read8(a + 1) == id and mem:read8(a + 2) == 0 end
  local lo = A.status_dmg_script[1]
  if not (printstring(lo, 0x2a) and printstring(lo + 0x3a, 0x30)) then
    return false, "the poison / burn battle script is not where expected"
  end
  return true
end

return G

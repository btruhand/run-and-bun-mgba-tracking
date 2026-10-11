-- Spike 0 probe: read-only. Load via mGBA Tools > Scripting > File > Load script,
-- with Run & Bun 1.0.7 running and a save loaded. Prints to the scripting console.

local PARTY, COUNT = 0x2023a98, 0x2023a95   -- 1141 code refs in ROM; same as the community exporter
local SB_CANDIDATES = { 0x3005d9c, 0x3005da0 } -- adjacent IWRAM pointers (vanilla: SaveBlock1Ptr, SaveBlock2Ptr)
local NAMES = 0x083a0f80                       -- species names, 11 bytes each, index 0 is "??????????"

local PERM = {
  {0,1,2,3},{0,1,3,2},{0,2,1,3},{0,3,1,2},{0,2,3,1},{0,3,2,1},
  {1,0,2,3},{1,0,3,2},{2,0,1,3},{3,0,1,2},{2,0,3,1},{3,0,2,1},
  {1,2,0,3},{1,3,0,2},{2,1,0,3},{3,1,0,2},{2,3,0,1},{3,2,0,1},
  {1,2,3,0},{1,3,2,0},{2,1,3,0},{3,1,2,0},{2,3,1,0},{3,2,1,0},
}

local function gba_str(addr, n)
  local s = ""
  for i = 0, n - 1 do
    local c = emu:read8(addr + i)
    if c == 0xFF then break end
    if c >= 0xBB and c <= 0xD4 then s = s .. string.char(65 + c - 0xBB)
    elseif c >= 0xD5 and c <= 0xEE then s = s .. string.char(97 + c - 0xD5)
    elseif c >= 0xA1 and c <= 0xAA then s = s .. string.char(48 + c - 0xA1)
    elseif c == 0 then s = s .. " "
    else s = s .. string.format("<%02x>", c) end
  end
  return s
end

local function sub(addr, pid, ot, idx) -- decrypted 12 bytes of substruct `idx` (0=growth,1=attacks,2=EVs,3=misc)
  local key = pid ~ ot
  local pos = PERM[pid % 24 + 1][idx + 1] -- table maps substruct type -> slot position
  local w = {}
  for i = 0, 2 do w[i] = emu:read32(addr + 32 + pos * 12 + i * 4) ~ key end
  return w
end

console:log("--- party ---")
local n = emu:read8(COUNT)
console:log("count=" .. n)
for i = 0, math.min(n, 6) - 1 do
  local a = PARTY + i * 100
  local pid, ot = emu:read32(a), emu:read32(a + 4)
  local g, m = sub(a, pid, ot, 0), sub(a, pid, ot, 3)
  local species = g[0] & 0xFFFF
  console:log(string.format("[%d] pid=%08X ot=%08X species=%d (%s) nick=%q lvl=%d hp=%d/%d metLoc=%d",
    i, pid, ot, species, gba_str(NAMES + species * 11, 11), gba_str(a + 8, 10),
    emu:read8(a + 84), emu:read16(a + 86), emu:read16(a + 88), (m[0] >> 8) & 0xFF))
end

console:log("--- save block pointer candidates ---")
for _, p in ipairs(SB_CANDIDATES) do
  console:log(string.format("[%08X] -> %08X", p, emu:read32(p)))
end

console:log("--- play time (SaveBlock2 +0x0E, hours u16 / min u8 / sec u8) if candidate is SB2 ---")
for _, p in ipairs(SB_CANDIDATES) do
  local sb = emu:read32(p)
  if sb >= 0x02000000 and sb < 0x02040000 then
    console:log(string.format("via %08X: %dh %dm %ds", p, emu:read16(sb + 0x0E), emu:read8(sb + 0x10), emu:read8(sb + 0x11)))
  end
end

-- Tracker tests, no emulator, ROM or save needed:  lua tests/lua/run.lua   (npm run test:lua)
-- Scenarios marked "observed" replay frame sequences logged from real fights (docs/MEMORY_MAP.md).

local root = debug.getinfo(1, "S").source:match("^@(.*)/tests/lua/run%.lua$") or "."
package.path = root .. "/lua/?.lua;" .. root .. "/tests/lua/?.lua;" .. package.path

local A = require("addresses")
local G = require("gen3")
local J = require("json")
local Battle = require("battle")
local Fake = require("fakemem")

local failures, passed = 0, 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1 print("ok   " .. name)
  else failures = failures + 1 print("FAIL " .. name .. "\n     " .. tostring(err):gsub("\n", "\n     ")) end
end

local function eq(got, want, what)
  if got ~= want then error(string.format("%s: got %s, want %s", what or "value", tostring(got), tostring(want)), 2) end
end

local function types(events)
  local t = {}
  for _, e in ipairs(events) do t[#t + 1] = e.type end
  return table.concat(t, ",")
end

-- Your mons (from the real party) and a few enemies.
local PIPLUP = { personality = 0x262E1B25, species = 393, level = 12, hp = 38, max_hp = 38 }
local GOSSI  = { personality = 0x84B13217, species = 829, level = 12, hp = 32, max_hp = 32 }
local SIZZLE = { personality = 0x128A564B, species = 850, level = 12, hp = 37, max_hp = 37 }

-- A fresh world: trainer `opp` (a regular trainer unless flagged), enemy party, your lead in battler 0.
local function world(opts)
  opts = opts or {}
  local m = Fake.new()
  m:species_name(1, "Bulbasaur")
  m:species_name(393, "Piplup")
  m:species_name(684, "Swirlix")
  m:species_name(327, "Spinda")
  m:trainer_name(615, "Lyle")
  m:trainer_name(265, "Brawly")
  m:battle_type(opts.flags or 0x8)
  m:opponent(opts.opponent or 615)
  m:battle_mon(0, PIPLUP)
  for i, e in ipairs(opts.enemies or {}) do m:enemy_mon(i - 1, e) end
  if opts.enemies then m:battle_mon(1, opts.enemies[1]) end
  local events, w = {}, nil
  w = { mem = m, events = events }
  w.battle = Battle.new(m, function(e) events[#events + 1] = e end)
  function w.step(n) for _ = 1, n or 1 do w.battle:step() end end
  function w.begin() m:in_battle(true) w.step() end
  function w.finish() m:in_battle(false) w.step() end
  function w.enemy(slot, mon, hp) -- put an enemy mon in battler 1 with the given hp
    local b = {}
    for k, v in pairs(mon) do b[k] = v end
    b.hp = hp
    m:battle_mon(1, b)
    w.step()
  end
  return w
end

local function enemy(pid, species, hp, level)
  return { personality = pid, species = species, level = level or 7, hp = hp, max_hp = hp }
end

local SWIRLIX = enemy(0x60A47E01, 684, 27)
local SPINDA = { personality = 0x60A47E02, species = 327, level = 8, hp = 30, max_hp = 30 }

-- ---------------------------------------------------------------------------------------------------------------------

test("a trainer kill is credited to the mon on the field, in the current split", function()
  local w = world({ enemies = { SWIRLIX } })
  w.begin()
  w.enemy(0, SWIRLIX, 15)
  w.enemy(0, SWIRLIX, 5)
  eq(#w.events, 0, "no event before the kill")
  w.enemy(0, SWIRLIX, 0)
  eq(#w.events, 1, "events")
  local e = w.events[1]
  eq(e.type, "kill", "type")
  eq(e.pid, "0x262E1B25:0xF9D040AF", "pid")
  eq(e.split, 1, "split")
  eq(e.trainer, "615", "trainer")
  eq(e.key, "615:0", "key")
  eq(e.enemy, "Lyle's Swirlix", "enemy")
  eq(e.ambiguous, nil, "ambiguous")
end)

test("observed: switch-in glitch (Swirlix -> Spinda) gives exactly two kills", function()
  local w = world({ enemies = { SWIRLIX, SPINDA } })
  w.begin()
  w.enemy(0, SWIRLIX, 9)
  w.enemy(0, SWIRLIX, 0)                              -- real kill
  w.enemy(1, SPINDA, 30)                              -- replacement arrives
  -- two frames later: Spinda's species with the dead Swirlix's hp / max hp / level
  w.mem:battle_mon(1, { species = 327, hp = 0, max_hp = 27, level = 7, personality = SPINDA.personality })
  w.step()
  w.enemy(0, SWIRLIX, 0)                              -- the whole dead Swirlix is back
  w.enemy(1, SPINDA, 30)                              -- settles
  w.mem:battle_mon(0, GOSSI) w.step()                 -- you switch before the real kill
  w.enemy(1, SPINDA, 1)
  w.enemy(1, SPINDA, 0)                               -- real kill
  eq(types(w.events), "kill,kill", "events")
  eq(w.events[1].key, "615:0", "first key")
  eq(w.events[1].pid, "0x262E1B25:0xF9D040AF", "first credit")
  eq(w.events[2].key, "615:1", "second key")
  eq(w.events[2].pid, "0x84B13217:0xF9D040AF", "second credit goes to the mon that was out, not the one at the glitch")
end)

test("observed: the glitch also fires when the stale data is a whole other mon (Yanma after Clobbopus)", function()
  local CLOB = { personality = 0x60A47E03, species = 852, level = 9, hp = 30, max_hp = 30 }
  local YANMA = { personality = 0x60A47E04, species = 193, level = 9, hp = 33, max_hp = 33 }
  local KRAB = enemy(0x60A47E05, 98, 27, 9)
  local w = world({ enemies = { KRAB, CLOB, YANMA } })
  w.begin()
  w.enemy(0, KRAB, 1)
  w.enemy(0, KRAB, 0)                                 -- real kill
  w.enemy(1, CLOB, 30)
  w.mem:battle_mon(1, { species = 852, hp = 0, max_hp = 27, level = 9, personality = CLOB.personality })
  w.step()                                            -- Clobbopus with Krabby's hp / max hp
  w.enemy(2, YANMA, 33)
  w.mem:battle_mon(1, { species = 193, hp = 0, max_hp = 27, level = 9, personality = YANMA.personality })
  w.step()                                            -- Yanma with Krabby's hp / max hp
  w.enemy(2, YANMA, 33)
  w.enemy(2, YANMA, 0)                                -- real kill
  eq(types(w.events), "kill,kill", "events")
end)

test("two enemy mons that look alike are told apart by personality", function()
  local a, b = enemy(0x60A47E10, 684, 10), enemy(0x60A47E11, 684, 10)
  local w = world({ enemies = { a, b } })
  w.begin()
  w.enemy(0, a, 0)
  w.enemy(1, b, 10)
  w.enemy(1, b, 0)
  eq(types(w.events), "kill,kill", "events")
  eq(w.events[2].key, "615:1", "second key")
end)

test("an enemy slot is credited once even if its hp drops to 0 again", function()
  local w = world({ enemies = { SWIRLIX } })
  w.begin()
  w.enemy(0, SWIRLIX, 5)
  w.enemy(0, SWIRLIX, 0)
  w.enemy(0, SWIRLIX, 5)
  w.enemy(0, SWIRLIX, 0)
  eq(types(w.events), "kill", "events")
end)

test("wild battles give no kills, but a faint still becomes a death", function()
  local w = world({ flags = 0x0, enemies = { SWIRLIX } })
  w.begin()
  w.enemy(0, SWIRLIX, 0)
  w.mem:battle_mon(0, { species = 393, hp = 0, level = 12, max_hp = 38, personality = PIPLUP.personality })
  w.step()
  eq(#w.events, 0, "nothing mid-battle")
  w.finish()
  eq(types(w.events), "death", "events")
  eq(w.events[1].pid, "0x262E1B25:0xF9D040AF", "pid")
end)

test("deaths are committed when the battle ends, once per mon", function()
  local w = world({ enemies = { SWIRLIX } })
  w.begin()
  local p = { species = 393, level = 12, max_hp = 38, personality = PIPLUP.personality }
  p.hp = 10 w.mem:battle_mon(0, p) w.step()
  p.hp = 0 w.mem:battle_mon(0, p) w.step()
  eq(#w.events, 0, "no death yet")
  w.step(5)
  w.finish()
  eq(types(w.events), "death", "events")
end)

test("observed: a lost fight emits kills and deaths but no split", function()
  local w = world({ enemies = { SWIRLIX, SPINDA } })
  w.begin()
  w.enemy(0, SWIRLIX, 0)                              -- Gossifleur-era kill, Piplup is in battler 0
  for _, mon in ipairs({ PIPLUP, GOSSI, SIZZLE }) do
    local m = { species = mon.species, level = 12, max_hp = mon.max_hp, personality = mon.personality }
    m.hp = mon.max_hp w.mem:battle_mon(0, m) w.step()
    m.hp = 0 w.mem:battle_mon(0, m) w.step()
  end
  w.finish()
  eq(types(w.events), "kill,death,death,death", "events")
  eq(w.events[2].pid, "0x262E1B25:0xF9D040AF", "first death")
  eq(w.events[4].pid, "0x128A564B:0xF9D040AF", "last death")
end)

test("a player switch moves the credit to the new mon", function()
  local w = world({ enemies = { SWIRLIX } })
  w.begin()
  local p = { species = 393, level = 12, max_hp = 38, personality = PIPLUP.personality, hp = 0 }
  w.mem:battle_mon(0, p) w.step()                     -- Piplup faints
  w.mem:battle_mon(0, GOSSI) w.step()                 -- Gossifleur comes in
  w.enemy(0, SWIRLIX, 0)
  local kill = w.events[#w.events]
  eq(kill.type, "kill", "type")
  eq(kill.pid, "0x84B13217:0xF9D040AF", "credited to Gossifleur")
end)

test("a self-KO on the same frame still credits your mon", function()
  local w = world({ enemies = { SWIRLIX } })
  w.begin()
  w.mem:battle_mon(0, { species = 393, hp = 0, level = 12, max_hp = 38, personality = PIPLUP.personality })
  w.enemy(0, SWIRLIX, 0)
  w.finish()
  eq(types(w.events), "kill,death", "events")
  eq(w.events[1].pid, "0x262E1B25:0xF9D040AF", "pid")
end)

test("beating a gym leader: the fight counts for the current split, then a split event fires", function()
  local w = world({ opponent = 265, enemies = { SWIRLIX } })
  w.mem:trainer_flag(264)                             -- first leader already beaten
  w.begin()
  w.enemy(0, SWIRLIX, 0)
  eq(w.events[1].split, 2, "kill split")
  w.mem:trainer_flag(265)                             -- the game sets the flag as the battle ends
  w.finish()
  eq(types(w.events), "kill,split", "events")
  eq(w.events[2].badges, 2, "badges")
end)

test("beating an ordinary trainer sends no split event", function()
  local w = world({ enemies = { SWIRLIX } })
  w.begin()
  w.enemy(0, SWIRLIX, 0)
  w.mem:trainer_flag(615)
  w.finish()
  eq(types(w.events), "kill", "events")
end)

test("doubles: the leftmost live mon gets the credit and the guess is flagged", function()
  local w = world({ flags = 0x9, enemies = { SWIRLIX } })
  w.mem:battle_mon(2, GOSSI)
  w.begin()
  w.enemy(0, SWIRLIX, 0)
  eq(w.events[1].pid, "0x262E1B25:0xF9D040AF", "pid")
  eq(w.events[1].ambiguous, true, "ambiguous")
end)

test("doubles: with one of your mons down the credit is certain", function()
  local w = world({ flags = 0x9, enemies = { SWIRLIX } })
  w.mem:battle_mon(0, { species = 393, hp = 0, level = 12, max_hp = 38, personality = PIPLUP.personality })
  w.mem:battle_mon(2, GOSSI)
  w.begin()
  w.enemy(0, SWIRLIX, 0)
  eq(w.events[1].pid, "0x84B13217:0xF9D040AF", "pid")
  eq(w.events[1].ambiguous, nil, "ambiguous")
end)

test("reset (a savestate was loaded) drops the battle without emitting anything", function()
  local w = world({ enemies = { SWIRLIX } })
  w.begin()
  w.mem:battle_mon(0, { species = 393, hp = 0, level = 12, max_hp = 38, personality = PIPLUP.personality })
  w.step()
  w.battle:reset()
  w.finish()
  eq(#w.events, 0, "events")
end)

test("starting mid-battle (script loaded during a fight) tracks from the current state", function()
  local w = world({ enemies = { SWIRLIX } })
  w.enemy(0, SWIRLIX, 12)
  w.begin()
  w.enemy(0, SWIRLIX, 0)
  eq(types(w.events), "kill", "events")
end)

-- decoding ------------------------------------------------------------------------------------------------------------------

test("party structs decode for every substruct order", function()
  for r = 0, 23 do
    local m = Fake.new()
    m:species_name(1, "Bulbasaur")
    m:mon(A.party, { personality = 0x1000 + r, species = 850, nick = "Sizzlipede", level = 12, hp = 37, max_hp = 37, met_location = 18 })
    local mon = G.read_mon(m, A.party)
    eq(mon.species, 850, "species for p%24=" .. r)
    eq(mon.met_location, 18, "met location for p%24=" .. r)
    eq(mon.nick, "Sizzlipede", "nick")
    eq(mon.level, 12, "level")
  end
  eq(G.read_mon(Fake.new(), A.party), nil, "empty slot")
end)

test("trainer flags: id 615 is byte 0x1700 bit 7, id 333 is byte 0x16dd bit 5", function()
  local m = Fake.new()
  m:trainer_flag(615)
  m:trainer_flag(333)
  eq(m:read8(m.sb1 + 0x1700), 0x80, "615")
  eq(m:read8(m.sb1 + 0x16dd), 0x20, "333")
  eq(G.trainer_flag(m, 615), true, "615 read")
  eq(G.trainer_flag(m, 616), false, "616 read")
end)

test("leaders defeated counts only the eight gym leaders", function()
  local m = Fake.new()
  m:trainer_flag(264) m:trainer_flag(271) m:trainer_flag(318)
  eq(G.leaders_defeated(m), 2, "count")
end)

test("trainer names come from entry id + 1", function()
  local m = Fake.new()
  m:trainer_name(615, "Lyle")
  eq(G.trainer_name(m, 615), "Lyle", "name")
end)

test("met location 255 reads as Fateful Encounter", function()
  eq(G.map_name(Fake.new(), 255), "Fateful Encounter", "name")
end)

test("play time and run id come from SaveBlock2, and are nil before a save is loaded", function()
  local m = Fake.new()
  m:play_time(2, 2, 13)
  m:write32(m.sb2 + A.sb2_trainer_id, 0xF9D040AF)
  eq(G.play_time(m), 2 * 3600 + 2 * 60 + 13, "play time")
  eq(G.run_id(m), "0xF9D040AF", "run id")
  m:write32(A.sb2_ptr, 0)
  eq(G.play_time(m), nil, "play time before load")
  eq(G.run_id(m), nil, "run id before load")
end)

test("json encodes sorted keys, arrays, and escapes", function()
  eq(J.encode({ type = "kill", split = 2, ok = true, list = { 1, 2 }, s = 'a"b' }),
     '{"list":[1,2],"ok":true,"s":"a\\"b","split":2,"type":"kill"}', "json")
end)

print(string.format("\n%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)

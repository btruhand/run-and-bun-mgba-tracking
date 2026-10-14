-- Tracker tests, no emulator, ROM or save needed:  lua tests/lua/run.lua   (npm run test:lua)
-- Scenarios marked "observed" replay frame sequences logged from real fights (docs/MEMORY_MAP.md).

local root = debug.getinfo(1, "S").source:match("^@(.*)/tests/lua/run%.lua$") or "."
package.path = root .. "/lua/?.lua;" .. root .. "/tests/lua/?.lua;" .. package.path

local A = require("addresses")
local G = require("gen3")
local J = require("json")
local Battle = require("battle")
local Mons = require("mons")
local Fake = require("fakemem")
local RelayClient = require("relay_client")

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

-- catches -------------------------------------------------------------------------------------------------------------------

local OWN = 0xF9D040AF
local STARTER = { personality = 0x7578D7BE, species = 393, nick = "Piplup", met_location = 255, level = 5 }
local POOCH = { personality = 0x971781E7, species = 261, nick = "Poochyena", met_location = 16, level = 3 }
local POOCH2 = { personality = 0x11223344, species = 261, nick = "Poochyena", met_location = 17, level = 3 }
local TEAM = {
  { personality = 0x2EEA2110, species = 390, nick = "Ukiuki", met_location = 255 },
  { personality = 0xD62A9858, species = 850, nick = "Sizzlipede", met_location = 1 },
  { personality = 0xFF0FF940, species = 427, nick = "Buneary", met_location = 16 },
  { personality = 0xFD2AC5D5, species = 16, nick = "Pidgey", met_location = 17 },
  { personality = 0x6BC3D0FD, species = 664, nick = "Scatterbug", met_location = 18 },
  { personality = 0x056A2CDA, species = 283, nick = "Surskit", met_location = 0 },
}

local function with(mon, fields)
  local c = {}
  for k, v in pairs(mon) do c[k] = v end
  for k, v in pairs(fields) do c[k] = v end
  return c
end

-- A world for the mon tracker: `party` mons in slots 0.., `boxed` mons in box 1. Nothing is stepped yet, so the
-- first step() sees this as what was there when tracking started.
local function mworld(opts)
  opts = opts or {}
  local m = Fake.new()
  for id, name in pairs({ [393] = "Piplup", [261] = "Poochyena", [390] = "Chimchar", [850] = "Sizzlipede", [664] = "Scatterbug", [665] = "Spewpa", [666] = "Vivillon", [10250] = "Vivillon" }) do m:species_name(id, name) end
  m:map_name(16, "Route 101")
  m:map_name(17, "Route 102")
  for i, mon in ipairs(opts.party or {}) do m:party_mon(i - 1, mon) end
  for i, mon in ipairs(opts.boxed or {}) do m:box_mon(1, i - 1, mon) end
  local w = { mem = m, events = {}, logs = {} }
  w.mons = Mons.new(m, function(e) w.events[#w.events + 1] = e end, function(s) w.logs[#w.logs + 1] = s end)
  function w.step(n) for _ = 1, n or 1 do w.mons:step() end end
  function w.scans(n) w.step(30 * (n or 1)) end
  function w.battle(enemies) -- a wild battle starts against these enemy party mons
    for i, e in ipairs(enemies) do m:enemy_mon(i - 1, e) end
    m:outcome(0)
    m:in_battle(true)
    w.step()
  end
  function w.end_battle(outcome)
    m:outcome(outcome)
    w.step(10)
    m:in_battle(false)
    w.step()
  end
  function w.logged(pattern)
    for _, s in ipairs(w.logs) do if s:find(pattern) then return true end end
    return false
  end
  return w
end

test("the starter is sent once it reads the same on two party scans", function()
  local w = mworld()
  w.step()
  w.mem:party_mon(0, STARTER)
  w.scans(1)
  eq(#w.events, 0, "events after one scan")
  w.scans(1)
  eq(types(w.events), "catch", "events")
  local e = w.events[1]
  eq(e.pid, "0x7578D7BE:0xF9D040AF", "pid")
  eq(e.species, "Piplup", "species")
  eq(e.nick, "Piplup", "nick")
  eq(e.location, "Fateful Encounter", "location")
  w.scans(10)
  eq(#w.events, 1, "sent once")
end)

test("observed: the starter arrives ~130 frames before the first battle and is sent before it starts", function()
  local w = mworld()
  w.step(200) -- the starter choice screen, empty party
  w.mem:party_mon(0, STARTER)
  w.step(120)
  w.mem:party_mon(0, with(STARTER, { bad_checksum = true })) -- one frame mid-rewrite as the battle is set up
  w.step()
  w.mem:party_mon(0, STARTER)
  eq(types(w.events), "catch", "sent before the battle")
  w.mem:in_battle(true)
  w.step(300)
  w.mem:outcome(1)
  w.mem:in_battle(false)
  w.scans(4)
  eq(#w.events, 1, "the first battle adds nothing")
end)

test("mons already in the party and boxes when tracking starts are not sent", function()
  local w = mworld({ party = TEAM, boxed = { POOCH } })
  w.scans(5)
  eq(#w.events, 0, "events")
  w.mem:party_empty(1) -- a deposit compacts the party: Buneary moves up, Sizzlipede goes to the box
  w.mem:box_mon(1, 1, TEAM[2])
  w.scans(3)
  eq(#w.events, 0, "events after a deposit")
end)

test("observed: a wild catch with a full party is sent when the battle ends, read from its box slot", function()
  local w = mworld({ party = TEAM })
  w.scans(2)
  w.battle({ POOCH })
  w.step(600)
  w.mem:box_mon(1, 0, with(POOCH, { nick = "Pooch" })) -- written after the nickname prompt, still in battle
  w.end_battle(7)
  eq(types(w.events), "catch", "events")
  eq(w.events[1].pid, "0x971781E7:0xF9D040AF", "pid")
  eq(w.events[1].species, "Poochyena", "species")
  eq(w.events[1].nick, "Pooch", "nickname from the stored copy")
  eq(w.events[1].location, "Route 101", "location")
  w.scans(5)
  eq(#w.events, 1, "sent once")
end)

test("a wild catch into a free party slot is sent once, with the nickname given after the catch", function()
  local w = mworld({ party = { TEAM[1] } })
  w.scans(1)
  w.battle({ POOCH })
  w.mem:party_mon(1, POOCH) -- added at "Gotcha!", nickname not chosen yet
  w.step(400)
  w.mem:party_mon(1, with(POOCH, { nick = "Fang" }))
  w.end_battle(7)
  w.scans(5)
  eq(types(w.events), "catch", "events")
  eq(w.events[1].nick, "Fang", "nick")
end)

test("a battle that ends won or ran sends no catch", function()
  local w = mworld({ party = { TEAM[1] } })
  w.battle({ POOCH })
  w.end_battle(1)
  w.battle({ POOCH2 })
  w.end_battle(4)
  w.scans(3)
  eq(#w.events, 0, "events")
end)

test("frames where a mon is being rewritten never make a catch", function()
  local w = mworld({ party = TEAM })
  w.mem:party_mon(0, with(TEAM[1], { bad_checksum = true, species = 17845 })) -- a known mon read mid-rewrite
  w.scans(3)
  eq(#w.events, 0, "known mon")
  local w2 = mworld()
  w2.step()
  w2.mem:party_mon(0, with(STARTER, { bad_checksum = true }))
  w2.scans(3)
  eq(#w2.events, 0, "new mon, unreadable")
  w2.mem:party_mon(0, STARTER)
  w2.scans(2)
  eq(types(w2.events), "catch", "new mon once readable")
end)

test("a known mon that is briefly in neither the party nor a box is not a catch when it comes back", function()
  local w = mworld({ party = { TEAM[1] }, boxed = { TEAM[2] } })
  w.scans(1)
  w.mem:box_empty(1, 0) -- withdraw: the box slot empties ~47 frames before the party slot fills
  w.scans(2)
  w.mem:party_mon(1, TEAM[2])
  w.scans(3)
  eq(#w.events, 0, "events")
end)

test("the same mon is sent at most once; another mon of the same species is a new catch", function()
  local w = mworld({ party = { TEAM[1] } })
  w.battle({ POOCH })
  w.mem:party_mon(1, POOCH)
  w.end_battle(7)
  w.mem:party_empty(1) -- deposited, then withdrawn again
  w.mem:box_mon(1, 0, POOCH)
  w.scans(2)
  w.mem:box_empty(1, 0)
  w.mem:party_mon(1, POOCH)
  w.scans(2)
  eq(#w.events, 1, "same mon")
  w.battle({ POOCH2 })
  w.mem:box_mon(1, 0, POOCH2)
  w.end_battle(7)
  eq(types(w.events), "catch,catch", "another Poochyena")
  eq(w.events[2].pid, "0x11223344:0xF9D040AF", "second pid")
  eq(w.logged("another Poochyena"), true, "repeat species logged")
end)

test("after a savestate load the mons in it are known; a catch replayed after the load is sent again", function()
  local w = mworld({ party = { TEAM[1] } })
  w.battle({ POOCH })
  w.mem:party_mon(1, POOCH)
  w.end_battle(7)
  w.mons:reset() -- loaded a later state that already has the Poochyena: nothing to send
  w.scans(3)
  eq(#w.events, 1, "known after load")
  w.mem:party_empty(1)
  w.mons:reset() -- loaded a state from before the catch, and caught it again
  w.battle({ POOCH })
  w.mem:party_mon(1, POOCH)
  w.end_battle(7)
  eq(types(w.events), "catch,catch", "sent again (the sheet ignores the repeat id)")
end)

test("a caught mon that never shows up is given up on without an event", function()
  local w = mworld({ party = { TEAM[1] } })
  w.battle({ POOCH })
  w.end_battle(7)
  w.scans(25)
  eq(#w.events, 0, "events")
  eq(w.logged("not in the party or boxes"), true, "logged")
  eq(w.mons.lookups, nil, "stopped looking")
end)

test("a new party mon with another OT id (an in-game trade) is logged once, not sent as a catch", function()
  local w = mworld({ party = { TEAM[1] } })
  w.scans(1)
  w.mem:party_mon(1, with(POOCH, { ot_id = 0x12345678 }))
  w.scans(5)
  eq(#w.events, 0, "events")
  local n = 0
  for _, s in ipairs(w.logs) do if s:find("another OT id") then n = n + 1 end end
  eq(n, 1, "logged once")
end)

test("an egg is not sent until it hatches", function()
  local w = mworld({ party = { TEAM[1] } })
  w.scans(1)
  w.mem:party_mon(1, with(POOCH, { egg = true }))
  w.scans(4)
  eq(#w.events, 0, "egg")
  w.mem:party_mon(1, POOCH)
  w.scans(2)
  eq(types(w.events), "catch", "hatched")
end)

test("a tracker started mid-battle still sends the catch", function()
  local w = mworld({ party = TEAM })
  for i, e in ipairs({ POOCH }) do w.mem:enemy_mon(i - 1, e) end
  w.mem:in_battle(true)
  w.step(5)
  w.mem:box_mon(1, 0, POOCH)
  w.end_battle(7)
  eq(types(w.events), "catch", "events")
end)

test("a caught mon read mid-rewrite when the battle ends is sent on a later scan with its real data", function()
  local w = mworld({ party = TEAM })
  w.battle({ POOCH })
  w.mem:box_mon(1, 0, with(POOCH, { nick = "Pooch", species = 46918, bad_checksum = true }))
  w.end_battle(7)
  eq(#w.events, 0, "not sent while unreadable")
  w.mem:box_mon(1, 0, with(POOCH, { nick = "Pooch" }))
  w.scans(1)
  eq(types(w.events), "catch", "events")
  eq(w.events[1].species, "Poochyena", "species")
end)

test("a catch already stored when tracking (re)started is not sent at the battle's end", function()
  local w = mworld({ party = TEAM, boxed = { POOCH } }) -- e.g. a state loaded after the nickname prompt
  for i, e in ipairs({ POOCH }) do w.mem:enemy_mon(i - 1, e) end
  w.mem:in_battle(true)
  w.step(5)
  w.end_battle(7)
  w.scans(3)
  eq(#w.events, 0, "events")
end)

-- evolutions -------------------------------------------------------------------------------------------------------------

local SCATTERBUG = TEAM[5]

test("observed: an evolution is sent once, with the default nickname the game gave the new species", function()
  local w = mworld({ party = TEAM })
  w.scans(2)
  w.mem:party_mon(4, with(SCATTERBUG, { level = 9 })) -- Endless Candy, L9
  w.scans(4)                                           -- the evolution scene
  w.mem:party_mon(4, with(SCATTERBUG, { species = 46919, bad_checksum = true, level = 9 })) -- one frame mid-write
  w.step()
  w.mem:party_mon(4, with(SCATTERBUG, { species = 665, nick = "Spewpa", level = 9 }))
  w.scans(1)
  eq(#w.events, 0, "not sent after one scan")
  w.scans(1)
  eq(types(w.events), "evolve", "events")
  local e = w.events[1]
  eq(e.pid, "0x6BC3D0FD:0xF9D040AF", "pid")
  eq(e.from, "Scatterbug", "from")
  eq(e.to, "Spewpa", "to")
  eq(e.nick, "Spewpa", "nick")
  w.scans(10)
  eq(#w.events, 1, "sent once")
end)

test("a nicknamed mon evolves without a nick in the event", function()
  local w = mworld({ party = { with(SCATTERBUG, { nick = "Dusty" }) } })
  w.scans(1)
  w.mem:party_mon(0, with(SCATTERBUG, { species = 665, nick = "Dusty" }))
  w.scans(2)
  eq(types(w.events), "evolve", "events")
  eq(w.events[1].nick, nil, "nick")
end)

test("a mon caught this session, then evolved, sends catch then evolve", function()
  local w = mworld({ party = { TEAM[1] } })
  w.battle({ SCATTERBUG })
  w.mem:party_mon(1, SCATTERBUG)
  w.end_battle(7)
  w.scans(2)
  w.mem:party_mon(1, with(SCATTERBUG, { species = 665, nick = "Spewpa" }))
  w.scans(2)
  eq(types(w.events), "catch,evolve", "events")
  eq(w.events[2].from, "Scatterbug", "from")
end)

test("a boxed mon withdrawn and then evolved is sent", function()
  local w = mworld({ party = { TEAM[1] }, boxed = { SCATTERBUG } })
  w.scans(1)
  w.mem:box_empty(1, 0)
  w.mem:party_mon(1, SCATTERBUG)
  w.scans(2)
  w.mem:party_mon(1, with(SCATTERBUG, { species = 665, nick = "Spewpa" }))
  w.scans(2)
  eq(types(w.events), "evolve", "events")
end)

test("a species read on only one scan, or with a failed checksum, is not an evolution", function()
  local w = mworld({ party = TEAM })
  w.scans(1)
  w.mem:party_mon(4, with(SCATTERBUG, { species = 665 })) -- one scan only, then back
  w.scans(1)
  w.mem:party_mon(4, SCATTERBUG)
  w.scans(3)
  w.mem:party_mon(4, with(SCATTERBUG, { species = 17845, bad_checksum = true }))
  w.scans(5)
  eq(#w.events, 0, "events")
end)

test("a mon that leaves the party between the two scans is not sent", function()
  local w = mworld({ party = { TEAM[1], SCATTERBUG } })
  w.scans(1)
  w.mem:party_mon(1, with(SCATTERBUG, { species = 665 }))
  w.scans(1)
  w.mem:party_empty(1)
  w.scans(1)
  eq(next(w.mons.evolving), nil, "forgotten")
  eq(#w.events, 0, "events")
end)

test("a form change that keeps the species name is logged, not sent", function()
  local w = mworld({ party = { with(SCATTERBUG, { species = 666, nick = "Vivillon" }) } })
  w.scans(1)
  w.mem:party_mon(0, with(SCATTERBUG, { species = 10250, nick = "Vivillon" }))
  w.scans(3)
  eq(#w.events, 0, "events")
  eq(w.logged("changed form"), true, "logged")
end)

test("after a savestate load an already evolved mon is not sent; evolving again after loading an earlier state is", function()
  local w = mworld({ party = { SCATTERBUG } })
  w.scans(1)
  w.mem:party_mon(0, with(SCATTERBUG, { species = 665, nick = "Spewpa" }))
  w.mons:reset() -- a later state, already evolved
  w.scans(3)
  eq(#w.events, 0, "known as Spewpa after the load")
  w.mem:party_mon(0, SCATTERBUG)
  w.mons:reset() -- an earlier state, then it evolves again
  w.scans(1)
  w.mem:party_mon(0, with(SCATTERBUG, { species = 665, nick = "Spewpa" }))
  w.scans(2)
  eq(types(w.events), "evolve", "sent again (the sheet sets the same species)")
end)

test("a mon unreadable when tracking started is recorded on its first valid read, not sent", function()
  local w = mworld({ party = { with(SCATTERBUG, { species = 17845, bad_checksum = true }) } })
  w.step()
  w.mem:party_mon(0, SCATTERBUG)
  w.scans(4)
  eq(#w.events, 0, "events")
end)

test("box slots decode with the 80-byte layout and a failed checksum marks a mon unreadable", function()
  local m = Fake.new()
  m:box_mon(3, 7, POOCH)
  local mon = G.read_mon(m, m:box_addr(3, 7), true)
  eq(mon.species, 261, "species")
  eq(mon.valid, true, "valid")
  eq(mon.level, nil, "no level in a box")
  m:box_mon(3, 7, with(POOCH, { bad_checksum = true }))
  eq(G.read_mon(m, m:box_addr(3, 7), true).valid, false, "bad checksum")
  eq(G.storage(m), 0x2028848, "storage")
end)

test("met locations past the map table read as empty", function()
  eq(G.map_name(Fake.new(), 254), "", "254")
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

-- A fake of mGBA's `socket` API with one relay that can be listening or not, and can close the connection.
local function fake_net()
  local net = { listening = true, connects = 0, sent = {}, wrote_after_close = false }
  function net.tcp()
    local s = {}
    function s:connect()
      net.connects = net.connects + 1
      if not net.listening then return nil, "CONNECTION_REFUSED" end
      net.conn, net.peer_closed = self, false
      return 1
    end
    function s:hasdata() return net.conn == self and net.peer_closed end -- the relay never writes; readable = closed
    function s:send(data)
      if self.closed then error("send on a closed socket") end
      if net.peer_closed then net.wrote_after_close = true end
      if net.short then return 3 end
      net.sent[#net.sent + 1] = data
      return #data
    end
    function s:close() self.closed = true end
    return s
  end
  function net.relay_stops() net.peer_closed, net.listening = true, false end
  return net
end

local function client(net)
  local logs = {}
  local c = RelayClient.new(38765, function(m) logs[#logs + 1] = m end, net)
  return c, logs
end

test("the relay client connects on the first frame and sends one line per event", function()
  local net = fake_net()
  local c = client(net)
  c:step()
  eq(c:send('{"type":"kill"}'), true, "sent")
  c:send('{"type":"death"}')
  eq(table.concat(net.sent), '{"type":"kill"}\n{"type":"death"}\n', "bytes")
end)

test("without a relay, events are not sent and it retries every two seconds, warning once", function()
  local net = fake_net()
  net.listening = false
  local c, logs = client(net)
  for _ = 1, 240 do c:step() end
  eq(net.connects, 2, "connect attempts in 240 frames")
  local ok, why = c:send("x")
  eq(ok, false, "send")
  eq(why, "relay not connected", "why")
  eq(#logs, 1, "warned once")
  net.listening = true
  for _ = 1, 120 do c:step() end
  eq(c:send("y"), true, "sent once the relay is up")
  eq(table.concat(net.sent), "y\n", "bytes")
end)

test("a connection the relay closed is never written to again (SIGPIPE would kill mGBA)", function()
  local net = fake_net()
  local c, logs = client(net)
  c:step()
  net.relay_stops()
  eq(c:send("x"), false, "closed in the same frame, before step() saw it")
  c:step()
  eq(net.wrote_after_close, false, "no write after the relay closed")
  eq(logs[#logs], "disconnected; reconnecting every 2 s", "log")
  net.listening = true
  for _ = 1, 120 do c:step() end
  eq(c:send("y"), true, "reconnected")
end)

test("after a relay restart the next event goes through, without one being dropped to notice", function()
  local net = fake_net()
  local c = client(net)
  c:step()
  net.relay_stops()
  c:step()
  net.listening = true
  for _ = 1, 120 do c:step() end
  eq(c:send("x"), true, "sent on the new connection")
end)

test("a short write closes the connection, so the relay drops the partial line", function()
  local net = fake_net()
  local c = client(net)
  c:step()
  net.short = true
  local ok, why = c:send("hello")
  eq(ok, false, "send")
  eq(why, "send failed: partial write", "why")
  eq(c.sock, nil, "closed")
end)

print(string.format("\n%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)

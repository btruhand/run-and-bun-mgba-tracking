-- Tracker tests, no emulator, ROM or save needed:  lua tests/lua/run.lua   (npm run test:lua)
-- Scenarios marked "observed" replay frame sequences logged from real fights (docs/MEMORY_MAP.md).

local root = debug.getinfo(1, "S").source:match("^@(.*)/tests/lua/run%.lua$") or "."
package.path = root .. "/lua/?.lua;" .. root .. "/tests/lua/?.lua;" .. package.path

local A = require("addresses")
local G = require("gen3")
local J = require("json")
local Battle = require("battle")
local Mons = require("mons")
local Sync = require("sync")
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
  eq(e.killedBy, "attack", "killedBy")
  eq(e.fallback, nil, "fallback")
  eq(e.ambiguous, nil, "ambiguous")
end)

test("singles: an enemy that faints from its own move (recoil) is self inflicted, credited to your mon as a fallback", function()
  local w = world({ enemies = { SWIRLIX } })
  w.begin()
  w.mem:attacker(1)
  w.enemy(0, SWIRLIX, 0)
  eq(w.events[1].pid, "0x262E1B25:0xF9D040AF", "pid")
  eq(w.events[1].killedBy, "self inflicted", "killedBy")
  eq(w.events[1].fallback, "leftmost", "fallback")
  eq(w.events[1].ambiguous, nil, "ambiguous")
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

test("doubles: your mon killed by an enemy's attack, by your partner's (friendly fire), or by itself (self inflicted)", function()
  local function faint(attacker, b)
    local w = world({ flags = 0x9, enemies = { SWIRLIX } })
    w.mem:battle_mon(2, GOSSI)
    w.begin()
    w.mem:attacker(attacker)
    local mon = b == 0 and PIPLUP or GOSSI
    w.mem:battle_mon(b, { species = mon.species, hp = 0, level = 12, max_hp = mon.max_hp, personality = mon.personality })
    w.step()
    w.finish()
    eq(types(w.events), "death", "events")
    return w.events[1]
  end
  eq(faint(1, 0).killedBy, "attack", "enemy battler 1 on battler 0")
  eq(faint(3, 2).killedBy, "attack", "enemy battler 3 on battler 2")
  eq(faint(2, 0).killedBy, "friendly fire", "battler 2 on battler 0")
  eq(faint(0, 2).killedBy, "friendly fire", "battler 0 on battler 2")
  eq(faint(0, 0).killedBy, "self inflicted", "battler 0 on itself")
  eq(faint(2, 2).killedBy, "self inflicted", "battler 2 on itself")
  eq(faint(0, 0).pid, "0x262E1B25:0xF9D040AF", "pid")
end)

test("singles: your mon killed by the enemy's attack is killedBy attack, by itself is self inflicted", function()
  local function faint(attacker)
    local w = world({ enemies = { SWIRLIX } })
    w.begin()
    w.mem:attacker(attacker)
    w.mem:battle_mon(0, { species = 393, hp = 0, level = 12, max_hp = 38, personality = PIPLUP.personality })
    w.step()
    w.finish()
    return w.events[1]
  end
  eq(faint(1).killedBy, "attack", "enemy")
  eq(faint(0).killedBy, "self inflicted", "itself")
end)

test("verify rejects a ROM whose poison / burn damage script is elsewhere", function()
  local m = Fake.new()
  m:species_name(1, "Bulbasaur")
  m:trainer_name(1, "Sawyer")
  m:map_name(0, "Littleroot Town")
  eq(G.verify(m), true, "the expected ROM")
  m:write8(A.status_dmg_script[1] + 0x3a + 1, 0x31)
  local ok, why = G.verify(m)
  eq(ok, false, "burn message id changed")
  eq(why, "the poison / burn battle script is not where expected", "why")
end)

-- Observed (docs/MEMORY_MAP.md, "Detecting status KOs"): a burned Pidgey at 1 hp, end of turn. gBattlerAttacker and
-- gBattlerTarget are both the burned battler itself, and hp reaches 0 with the script just past `datahpupdate`.
local BURN_FAINT = 0x0833ac55

test("observed: your mon killed by burn damage is killedBy status, though gBattlerAttacker is itself", function()
  local w = world({ enemies = { SWIRLIX } })
  w.begin()
  w.mem:attacker(0)
  w.mem:battlescript(0x0833ac7a) -- BattleScript_BurnTurnDmg
  w.step()
  w.mem:battlescript(BURN_FAINT)
  w.mem:battle_mon(0, { species = 393, hp = 0, level = 12, max_hp = 38, personality = PIPLUP.personality })
  w.step()
  w.mem:battlescript(0x08339926)
  w.step()
  w.finish()
  eq(types(w.events), "death", "events")
  eq(w.events[1].killedBy, "status", "killedBy")
end)

-- Toxic and regular poison were observed in this same tail (hp 1 -> 0 at 0x0833ac55, attacker 0). This only checks that
-- the range counts a faint at the poison entry's own message.
test("a faint at the start of the poison damage script (its message) is killedBy status too", function()
  local w = world({ enemies = { SWIRLIX } })
  w.begin()
  w.mem:attacker(0)
  w.mem:battlescript(A.status_dmg_script[1] + 3)
  w.mem:battle_mon(0, { species = 393, hp = 0, level = 12, max_hp = 38, personality = PIPLUP.personality })
  w.step()
  w.finish()
  eq(w.events[1].killedBy, "status", "killedBy")
end)

test("the same faint outside the status damage script stays self inflicted (recoil)", function()
  for _, ptr in ipairs({ 0x0833ac3f, 0x0833ac61, 0x08336fa5, 0 }) do -- just before, just past, an attack, none
    local w = world({ enemies = { SWIRLIX } })
    w.begin()
    w.mem:attacker(0)
    w.mem:battlescript(ptr)
    w.mem:battle_mon(0, { species = 393, hp = 0, level = 12, max_hp = 38, personality = PIPLUP.personality })
    w.step()
    w.finish()
    eq(w.events[1].killedBy, "self inflicted", string.format("killedBy at %08x", ptr))
  end
end)

test("a faint a frame after the script moved on still counts, two frames after does not", function()
  local function faint_after(frames)
    local w = world({ enemies = { SWIRLIX } })
    w.begin()
    w.mem:attacker(0)
    w.mem:battlescript(BURN_FAINT)
    w.step()
    w.mem:battlescript(0x08339926)
    w.step(frames - 1)
    w.mem:battle_mon(0, { species = 393, hp = 0, level = 12, max_hp = 38, personality = PIPLUP.personality })
    w.step()
    w.finish()
    return w.events[1].killedBy
  end
  eq(faint_after(1), "status", "next frame")
  eq(faint_after(2), "self inflicted", "two frames later")
end)

test("an enemy that burns to death is a kill with killedBy status, credited to the mon on the field", function()
  local w = world({ enemies = { SWIRLIX } })
  w.begin()
  w.mem:attacker(1) -- the burned enemy itself
  w.mem:battlescript(BURN_FAINT)
  w.enemy(0, SWIRLIX, 0)
  eq(types(w.events), "kill", "events")
  eq(w.events[1].pid, "0x262E1B25:0xF9D040AF", "pid")
  eq(w.events[1].killedBy, "status", "killedBy")
  eq(w.events[1].fallback, "leftmost", "fallback")
  eq(w.events[1].ambiguous, nil, "ambiguous")
end)

test("doubles: an enemy burned to death is a status kill that falls back, flagged when both of yours are alive", function()
  local w = world({ flags = 0x9, enemies = { SWIRLIX } })
  w.mem:battle_mon(2, GOSSI)
  w.begin()
  w.mem:attacker(1)
  w.mem:battlescript(BURN_FAINT)
  w.enemy(0, SWIRLIX, 0)
  eq(w.events[1].killedBy, "status", "killedBy")
  eq(w.events[1].fallback, "leftmost", "fallback")
  eq(w.events[1].ambiguous, true, "ambiguous")
end)

test("a death keeps the cause of the first faint of the mon", function()
  local w = world({ flags = 0x9, enemies = { SWIRLIX } })
  w.mem:battle_mon(2, GOSSI)
  w.begin()
  local down = { species = 393, hp = 0, level = 12, max_hp = 38, personality = PIPLUP.personality }
  w.mem:attacker(2)
  w.mem:battle_mon(0, down) w.step()
  w.mem:battle_mon(0, PIPLUP) w.step()
  w.mem:attacker(1)
  w.mem:battle_mon(0, down) w.step()
  w.finish()
  eq(#w.events, 1, "events")
  eq(w.events[1].killedBy, "friendly fire", "killedBy")
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
  local w = world({ opponent = 265, enemies = { SWIRLIX } }) -- Roxanne, the second gym in Run & Bun
  w.mem:trainer_flag(266)                             -- Brawly already beaten
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

test("observed: doubles kill is credited to gBattlerAttacker, not the leftmost mon", function()
  -- Luxray (battler 0) and Floatzel (battler 2) both alive; the attacker byte went 2, 3, 1, 0 over a real turn
  local w = world({ flags = 0x9, enemies = { SWIRLIX } })
  w.mem:battle_mon(2, GOSSI)
  w.begin()
  w.mem:attacker(2)
  w.enemy(0, SWIRLIX, 0)
  eq(w.events[1].pid, "0x84B13217:0xF9D040AF", "pid")
  eq(w.events[1].killedBy, "attack", "killedBy")
  eq(w.events[1].fallback, nil, "fallback")
  eq(w.events[1].ambiguous, nil, "ambiguous")
end)

test("doubles: the leftmost attacker is credited with its partner alive", function()
  local w = world({ flags = 0x9, enemies = { SWIRLIX } })
  w.mem:battle_mon(2, GOSSI)
  w.begin()
  w.mem:attacker(0)
  w.enemy(0, SWIRLIX, 0)
  eq(w.events[1].pid, "0x262E1B25:0xF9D040AF", "pid")
  eq(w.events[1].killedBy, "attack", "killedBy")
  eq(w.events[1].fallback, nil, "fallback")
  eq(w.events[1].ambiguous, nil, "ambiguous")
end)

test("doubles: an attacker that fainted in the same turn (Explosion) still gets the kill", function()
  local w = world({ flags = 0x9, enemies = { SWIRLIX } })
  w.mem:battle_mon(2, GOSSI)
  w.begin()
  w.mem:attacker(2)
  w.mem:battle_mon(2, { species = 829, hp = 0, level = 12, max_hp = 32, personality = GOSSI.personality })
  w.step()
  w.enemy(0, SWIRLIX, 0)
  eq(w.events[1].pid, "0x84B13217:0xF9D040AF", "pid")
  eq(w.events[1].killedBy, "attack", "killedBy")
  eq(w.events[1].fallback, nil, "fallback")
  eq(w.events[1].ambiguous, nil, "ambiguous")
end)

test("doubles: the enemy's own partner (friendly fire) falls back to the leftmost live mon, flagged", function()
  local w = world({ flags = 0x9, enemies = { SWIRLIX } })
  w.mem:battle_mon(2, GOSSI)
  w.begin()
  w.mem:attacker(3)
  w.enemy(0, SWIRLIX, 0)
  eq(w.events[1].pid, "0x262E1B25:0xF9D040AF", "pid")
  eq(w.events[1].killedBy, "friendly fire", "killedBy")
  eq(w.events[1].fallback, "leftmost", "fallback")
  eq(w.events[1].ambiguous, true, "ambiguous")
end)

test("doubles: an enemy that faints from its own move (recoil) is self inflicted, falls back, flagged", function()
  local w = world({ flags = 0x9, enemies = { SWIRLIX } })
  w.mem:battle_mon(2, GOSSI)
  w.begin()
  w.mem:attacker(1)
  w.enemy(0, SWIRLIX, 0)
  eq(w.events[1].pid, "0x262E1B25:0xF9D040AF", "pid")
  eq(w.events[1].killedBy, "self inflicted", "killedBy")
  eq(w.events[1].fallback, "leftmost", "fallback")
  eq(w.events[1].ambiguous, true, "ambiguous")
end)

test("doubles: a fallback with one of your mons down is certain", function()
  local w = world({ flags = 0x9, enemies = { SWIRLIX } })
  w.mem:battle_mon(0, { species = 393, hp = 0, level = 12, max_hp = 38, personality = PIPLUP.personality })
  w.mem:battle_mon(2, GOSSI)
  w.begin()
  w.mem:attacker(1)
  w.enemy(0, SWIRLIX, 0)
  eq(w.events[1].pid, "0x84B13217:0xF9D040AF", "pid")
  eq(w.events[1].killedBy, "self inflicted", "killedBy")
  eq(w.events[1].fallback, "leftmost", "fallback")
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

test("observed: a save load whose party arrives after the play time sends nothing for the mons in it", function()
  local w = mworld()
  w.step(5)
  w.mons:reset(Mons.LOAD_SETTLE) -- play time is valid, the party is not copied in yet
  w.step(10)
  for i, mon in ipairs(TEAM) do w.mem:party_mon(i - 1, mon) end
  w.step(Mons.LOAD_SETTLE)
  w.scans(5)
  eq(#w.events, 0, "events")
  eq(w.logged("mons already in the party"), true, "seeded after the party arrived")
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

test("species names are sent as the sheet spells them", function()
  local m = Fake.new()
  local names = { [851] = "Centskorch", [823] = "Corvknight", [740] = "Crabminabl", [669] = "Flabébé", [29] = "Nidoran♀",
    [32] = "Nidoran♂", [772] = "Type: Null", [850] = "Sizzlipede", [741] = "Oricorio", [1170] = "Oricorio",
    [745] = "Lycanroc", [1174] = "Lycanroc", [892] = "Urshifu", [1230] = "Urshifu", [666] = "Vivillon", [1114] = "Vivillon" }
  for id, name in pairs(names) do m:species_name(id, name) end
  for id, want in pairs({
    [851] = "Centiskorch", [823] = "Corviknight", [740] = "Crabominable", -- shortened by the ROM
    [669] = "Flabebe", [29] = "Nidoran-F", [32] = "Nidoran-M",           -- é, ♀, ♂ decoded, then the sheet's spelling
    [772] = "Type: Null",                                                -- : decoded
    [741] = "Oricorio-Baile", [1170] = "Oricorio-Pau", [745] = "Lycanroc Midday", [1174] = "Lycanroc Dusk",
    [892] = "Urshifu Single", [1230] = "Urshifu Rapid",                  -- forms the sheet tells apart
    [850] = "Sizzlipede", [666] = "Vivillon", [1114] = "Vivillon",        -- as the ROM has them
  }) do
    eq(G.species_name(m, id), want, names[id] .. " (#" .. id .. ")")
  end
end)

test("nicknames and map names decode é, ♀, ♂ and : as themselves", function()
  local m = Fake.new()
  m:write_string(0x02001000, "Nidoran♀", 10)
  eq(G.decode_string(m, 0x02001000, 10), "Nidoran♀", "nickname")
  m:map_name(135, "POKéMON MANSION")
  eq(G.map_name(m, 135), "POKéMON MANSION", "map name")
end)

test("observed: Sizzlipede evolves into the ROM's Centskorch and is sent as Centiskorch, keeping the game's nickname", function()
  local w = mworld({ party = { TEAM[2] } })
  w.mem:species_name(851, "Centskorch")
  w.scans(1)
  w.mem:party_mon(0, with(TEAM[2], { species = 851, nick = "Centskorch" }))
  w.scans(2)
  eq(types(w.events), "evolve", "events")
  local e = w.events[1]
  eq(e.from, "Sizzlipede", "from")
  eq(e.to, "Centiskorch", "to")
  eq(e.nick, "Centskorch", "nick (what the game stored)")
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

test("leaders defeated counts only the eight gym leaders, Roxanne (265) to Juan (272)", function()
  local m = Fake.new()
  m:trainer_flag(265) m:trainer_flag(272)
  m:trainer_flag(264) m:trainer_flag(273) m:trainer_flag(318) -- Drake, Jerry, Calvin
  eq(G.leaders_defeated(m), 2, "count")
end)

test("trainer names come from the gTrainers entry with the same index as the RAM id", function()
  local m = Fake.new()
  m:trainer_name(318, "Calvin")
  m:trainer_name(319, "Mikey")
  eq(G.trainer_name(m, 318), "Calvin", "name")
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

-- sync snapshot -----------------------------------------------------------------------------------------------------

local function sworld()
  local m = Fake.new()
  for id, name in pairs({ [393] = "Piplup", [261] = "Poochyena", [850] = "Sizzlipede" }) do m:species_name(id, name) end
  m:map_name(16, "Route 101")
  m:map_name(17, "Route 102")
  m:party_mon(0, { personality = 0x262E1B25, species = 393, nick = "Pengwin", level = 12, hp = 31, max_hp = 38, met_location = 16 })
  m:party_mon(1, { personality = 0x0BA1EC41, species = 261, level = 5, hp = 0, max_hp = 20, met_location = 17 })
  m:box_mon(1, 3, { personality = 0x128A564B, species = 850, nick = "Sizzle", met_location = 17 })
  return m
end

test("a sync snapshot has every mon in the party and boxes, with where it is and its HP", function()
  local snap = assert(Sync.snapshot(sworld()))
  eq(snap.type, "sync", "type")
  eq(snap.complete, true, "complete")
  eq(#snap.mons, 3, "mons")
  local by = {}
  for _, m in ipairs(snap.mons) do by[m.pid] = m end
  local p = by["0x262E1B25:0xF9D040AF"]
  eq(p.species, "Piplup", "species")
  eq(p.nick, "Pengwin", "nick")
  eq(p.location, "Route 101", "location")
  eq(p.where, "party", "where")
  eq(p.hp, 31, "hp")
  eq(by["0x0BA1EC41:0xF9D040AF"].hp, 0, "a fainted party mon has hp 0")
  local b = by["0x128A564B:0xF9D040AF"]
  eq(b.where, "box", "box mon")
  eq(b.hp, nil, "box mons have no hp")
  eq(b.location, "Route 102", "box mon location")
end)

test("a sync snapshot lists the defeated trainers and the badge count", function()
  local m = sworld()
  m:trainer_flag(615) m:trainer_flag(2) m:trainer_flag(864) m:trainer_flag(265) m:trainer_flag(267)
  local snap = assert(Sync.snapshot(m))
  eq(table.concat(snap.defeated, ","), "2,265,267,615,864", "defeated")
  eq(snap.badges, 2, "badges")
end)

test("a sync snapshot with nothing in it still has lists, which JSON writes as arrays", function()
  local m = Fake.new()
  local snap = assert(Sync.snapshot(m))
  eq(#snap.mons, 0, "mons")
  eq(snap.badges, 0, "badges")
  eq(J.encode(snap), '{"badges":0,"complete":true,"defeated":[],"mons":[],"type":"sync"}', "json")
end)

test("a sync snapshot leaves eggs out", function()
  local m = sworld()
  m:party_mon(2, { personality = 0x11112222, species = 261, egg = true })
  eq(#assert(Sync.snapshot(m)).mons, 3, "mons")
end)

test("a mon that can't be read right now cancels the snapshot instead of being left out", function()
  local m = sworld()
  m:party_mon(1, { personality = 0x0BA1EC41, species = 261, bad_checksum = true })
  local snap, why = Sync.snapshot(m)
  eq(snap, nil, "snapshot")
  assert(why:find("0x0BA1EC41:0xF9D040AF", 1, true), why)
end)

test("a sync snapshot waits for the end of a battle", function()
  local m = sworld()
  m:in_battle(true)
  local snap, why = Sync.snapshot(m)
  eq(snap, nil, "snapshot")
  assert(why:find("battle"), why)
  m:in_battle(false)
  assert(Sync.snapshot(m))
end)

test("no sync snapshot before a save is loaded", function()
  local m = Fake.new()
  m:write32(A.sb2_ptr, 0)
  local snap, why = Sync.snapshot(m)
  eq(snap, nil, "snapshot")
  eq(why, "no save loaded", "why")
  m = Fake.new()
  m:write32(A.sb1_ptr, 0)
  eq((Sync.snapshot(m)), nil, "no trainer flags either")
  m = Fake.new()
  m:write32(A.storage_ptr, 0)
  eq((Sync.snapshot(m)), nil, "no PC boxes either")
end)

-- syncToTracker (tracker.lua, loaded the way mGBA does, on fake globals) ------------------------------------------------

-- Loads tracker.lua against a fake mGBA: `emu` is fake memory, `console` and `callbacks` record what they get, and
-- `socket` is a relay that records every line sent to it (or refuses the connection when `listening` is false).
local function tracker_world(opts)
  opts = opts or {}
  local m = sworld()
  m:species_name(1, "Bulbasaur")
  m:trainer_name(1, "Sawyer")
  m:map_name(0, "Littleroot Town")
  m:play_time(1, 0, 0)
  local w = { mem = m, logs = {}, sent = {}, listening = opts.listening ~= false }
  local net = {}
  function net.tcp()
    local sock = {}
    function sock:connect() if w.listening then return true end return nil, "refused" end
    function sock:hasdata() return false end
    function sock:send(line) w.sent[#w.sent + 1] = line return #line end
    function sock:close() end
    return sock
  end
  local saved = {}
  for _, k in ipairs({ "emu", "console", "callbacks", "socket" }) do saved[k] = _G[k] end
  _G.emu = m
  w.buffers = {}
  _G.console = {
    log = function(_, msg) w.logs[#w.logs + 1] = msg end,
    createBuffer = function(_, name)
      local b = { name = name, rows_text = {}, cleared = 0 }
      function b:clear() self.cleared = self.cleared + 1 self.rows_text = {} end
      function b:setSize(cols, rows) self.cols, self.rows = cols, rows end
      function b:moveCursor(x, y) self.x, self.y = x, y end
      function b:print(t)
        assert(not t:find("\n", 1, true), "a newline inside print() mangles the layout in mGBA")
        local row = self.rows_text[self.y] or ""
        self.rows_text[self.y] = row:sub(1, self.x) .. t
      end
      w.buffers[#w.buffers + 1] = b
      return b
    end,
  }
  _G.callbacks = { add = function(_, _, fn) w.frame = fn return 1 end, remove = function() end }
  _G.socket = net
  dofile(root .. "/lua/tracker.lua")
  w.sync = _G.syncToTracker
  function w.frames(n) for _ = 1, n or 1 do w.frame() end end
  function w.logged(pattern)
    for _, l in ipairs(w.logs) do if l:find(pattern) then return true end end
    return false
  end
  function w.close()
    for k, v in pairs(saved) do _G[k] = v end
    _G.syncToTracker, _G.TRACKER_HELP, _G.TRACKER_CB, _G.TRACKER_RELAY, _G.TRACKER_SESSION, _G.TRACKER_SEQ = nil, nil, nil, nil, nil
  end
  w.frames(2) -- the first frame connects to the relay
  return w
end

local function with_tracker(opts, fn)
  local w = tracker_world(opts)
  local ok, err = pcall(fn, w)
  w.close()
  if not ok then error(err, 0) end
end

local function decode_sent(line)
  -- the snapshot's fields, read back out of the one line the relay got
  local t = {}
  t.type = line:match('"type":"(%w+)"')
  t.run = line:match('"run":"([^"]+)"')
  t.playTime = tonumber(line:match('"playTime":(%d+)'))
  t.id = line:match('"id":"([^"]+)"')
  return t
end

test("syncToTracker sends one sync with the run, an id and the play time, and says what it sent", function()
  with_tracker({}, function(w)
    eq(w.sync(), true, "sent")
    eq(#w.sent, 1, "lines")
    local ev = decode_sent(w.sent[1])
    eq(ev.type, "sync", "type")
    eq(ev.run, "0xF9D040AF", "run")
    eq(ev.playTime, 3600, "play time")
    assert(ev.id:find("^0xF9D040AF:%x+%.1$"), ev.id)
    assert(w.sent[1]:find('"complete":true', 1, true), w.sent[1])
    assert(w.sent[1]:find('"pid":"0x128A564B:0xF9D040AF"', 1, true), "a box mon is in it")
    assert(w.logged("sync: sent 3 mons, 0 defeated trainers, 0 badges"), "log")
  end)
end)

test("syncToTracker stamps the play time of now, not of the last frame", function()
  with_tracker({}, function(w)
    w.mem:play_time(1, 0, 2) -- two seconds on, no frame in between
    w.sync()
    eq(decode_sent(w.sent[1]).playTime, 3602, "play time")
  end)
end)

test("syncToTracker sends nothing in a battle, and the console says why", function()
  with_tracker({}, function(w)
    w.mem:in_battle(true)
    eq(w.sync(), false, "sent")
    eq(#w.sent, 0, "lines")
    assert(w.logged("sync: not sent %(in battle"), "log")
  end)
end)

test("syncToTracker sends nothing while a mon is unreadable", function()
  with_tracker({}, function(w)
    w.mem:party_mon(1, { personality = 0x0BA1EC41, species = 261, bad_checksum = true })
    eq(w.sync(), false, "sent")
    eq(#w.sent, 0, "lines")
    assert(w.logged("sync: not sent %(couldn't read 0x0BA1EC41"), "log")
    w.mem:party_mon(1, { personality = 0x0BA1EC41, species = 261 })
    eq(w.sync(), true, "sent on the next try")
  end)
end)

test("syncToTracker without a relay reports it was not sent", function()
  with_tracker({ listening = false }, function(w)
    eq(w.sync(), false, "sent")
    eq(#w.sent, 0, "lines")
    assert(w.logged("not sent: relay not connected"), "log")
    assert(not w.logged("sync: sent"), "no success message")
  end)
end)

test("loading the script puts the help text in its own buffer, with syncToTracker and the how-to-use link", function()
  with_tracker({}, function(w)
    eq(#w.buffers, 1, "buffers")
    local b = w.buffers[1]
    eq(b.name, "Auto-tracker help text", "name")
    local text = {}
    for y = 0, b.rows - 1 do
      local line = b.rows_text[y] or ""
      assert(#line <= b.cols, "line wider than the buffer: " .. line)
      text[#text + 1] = line
    end
    text = table.concat(text, "\n")
    assert(text:find("syncToTracker()", 1, true), "syncToTracker")
    assert(text:find("https://github.com/btruhand/run-and-bun-mgba-tracking#how-to-use", 1, true), "link")
    for y in pairs(b.rows_text) do assert(y >= 0 and y < b.rows, "row outside the buffer: " .. y) end
  end)
end)

test("reloading the script reuses the help buffer instead of adding another", function()
  with_tracker({}, function(w)
    dofile(root .. "/lua/tracker.lua")
    eq(#w.buffers, 1, "buffers")
    eq(w.buffers[1].cleared, 2, "cleared on each load")
    assert(w.buffers[1].rows_text[0]:find("Auto-tracker help", 1, true), "still filled")
  end)
end)

test("a sync does not go out by itself, not even after a play-time jump", function()
  with_tracker({}, function(w)
    w.frames(60)
    w.mem:play_time(0, 5, 0) -- a savestate from earlier was loaded
    w.frames(60)
    assert(w.logged("play time jumped"), "the jump was seen")
    eq(#w.sent, 0, "nothing sent")
  end)
end)

test("syncToTracker's ids keep counting with the other events", function()
  with_tracker({}, function(w)
    w.sync()
    w.sync()
    local a, b = decode_sent(w.sent[1]).id, decode_sent(w.sent[2]).id
    assert(a ~= b, "two syncs have two ids")
    assert(a:find("%.1$") and b:find("%.2$"), a .. " " .. b)
  end)
end)

print(string.format("\n%d passed, %d failed", passed, failures))
os.exit(failures == 0 and 0 or 1)

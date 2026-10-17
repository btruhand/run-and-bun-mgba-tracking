-- The `sync` snapshot: what the game has right now, for the sheet to reconcile its event log against (DESIGN.md,
-- "Savestates & old saves"). snapshot(mem) returns the event without id, run and play time (the caller adds them),
-- or nil and the reason it can't be taken:
--   sync {mons:[{pid, species, nick, location, where, hp?}], defeated:[trainerId...], badges, complete:true}
--
-- It is all or nothing. The sheet takes a mon that is missing from `mons` as gone from the game and undoes its
-- catch, so a mon that can't be read right now (the game is rewriting it) cancels the snapshot instead of being left
-- out. Eggs are left out on purpose: they aren't sent until they hatch, so the sheet has no row for them. The
-- snapshot also waits for the end of a battle: a trainer's defeated flag is only set then, and the sheet would take
-- a kill from the fight in progress back.
-- `mem` is anything with read8/read16/read32/readRange (mGBA's emu, or a fake in tests).

local A = require("addresses")
local G = require("gen3")

local S = {}

function S.snapshot(mem)
  if G.play_time(mem) == nil or G.run_id(mem) == nil then return nil, "no save loaded" end
  if (mem:read8(A.in_battle) >> 1) & 1 == 1 then return nil, "in battle; try again after it ends" end

  local mons, unreadable = {}, {}
  local complete = G.each_slot(mem, function(addr, box)
    local m = G.read_mon(mem, addr, box)
    if not m.valid then
      unreadable[#unreadable + 1] = m.pid
    elseif not m.egg then
      mons[#mons + 1] = {
        pid = m.pid,
        species = G.species_name(mem, m.species),
        nick = m.nick,
        location = G.map_name(mem, m.met_location),
        where = box and "box" or "party",
        hp = (not box) and m.hp or nil, -- PC mons have no HP
      }
    end
  end)
  if not complete then return nil, "the PC boxes aren't loaded" end
  if #unreadable > 0 then
    return nil, "couldn't read " .. table.concat(unreadable, ", ") .. " (mid-rewrite, or a bad egg); try again"
  end

  local defeated = G.defeated_trainers(mem)
  if not defeated then return nil, "no save loaded" end
  return {
    type = "sync",
    mons = mons,
    defeated = defeated,
    badges = G.leaders_defeated(mem),
    complete = true,
  }
end

return S

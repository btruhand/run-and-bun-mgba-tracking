# Spike 0 log: how the memory map was found

A record of the method and the evidence, so each address in [../MEMORY_MAP.md](../MEMORY_MAP.md) can be trusted or re-derived. Nothing here is needed to run the tracker.

## Method

No symbol map exists for Run & Bun 1.0.7, so addresses came from three sources, cheapest first:

1. **The ROM file, statically.** Species and map names are in the ROM as Gen 3 charset strings; the EWRAM/IWRAM addresses code refers to appear as 32-bit literals. Counting how often each literal occurs in the ROM (a proxy for how widely used a global is) pointed at the real globals: `0x02023a98` appears 1141 times, `0x02020630` 1655, `0x030022c0` (`gMain`, the same as vanilla Emerald) 814.
2. **Savestates, offline.** mGBA savestates are PNGs with the full emulator state in a `gbAs` chunk. Decompressing it (EWRAM at `0x21000`, IWRAM at `0x19000`) allows reading and diffing any RAM without launching the emulator. Pairs from the same timeline (before / after a fight) isolate what a fight changes.
3. **Live probes in mGBA** (`lua/spike/probe.lua`, `probe2.lua`), read-only: decode the party, log battle events with a frame trace, and diff SaveBlock1 on demand (`snap()` / `diff()`).
4. **Driving the game from outside** (`lua/dev/remote.lua` + `tools/remote.py`): the script runs Lua chunks dropped in `.remote/cmd.lua`, so a session can press buttons, take screenshots, save states and install per-frame watchers without anyone at the keyboard. Loaded once by hand; it can reload itself afterwards.

A small Lua harness (a mock `emu` reading from the ROM file and a decompressed state) let probes and the tracker be exercised on real data before running them in mGBA.

## Timeline

| Step | Result |
|------|--------|
| Community exporter script | Party at `0x02023a98`, count at `0x02023a95`; its species-name table address is wrong for 1.0.7 |
| Probe 1 in mGBA | Party decodes; `0x03005da0` gives sane play time so it is `gSaveBlock2Ptr`, `0x03005d9c` is `gSaveBlock1Ptr`. A first decode bug (substruct permutation inverted) was a probe error, not a game quirk |
| Map names | Pointer table at `0x086a1960`, 8-byte entries; met location id indexes it; `255` is "Fateful Encounter" (the starter) |
| Four savestates | `gBattleMons` at `0x020233fc` (entry size `0x5c`), `gEnemyParty` at `0x02023cf0`, `gMain.inBattle` at `+0x439`; `BattleMon` field offsets from matching the party mon's stats |
| Two overworld states either side of a fight | Four bits changed in SaveBlock1. Opponent id candidate `0x020381ae` (0 before a fight, 318 during and after). Bit `318 % 8 = 6` of byte `318 / 8 = 39` lined up with one of the four changes, fixing the flag block at `sb1 + 0x16b4` |
| Matching enemy parties against `gTrainers` | Concluded RAM id = entry − 1 (318 → entry 319, also 603, 615, 333). **Wrong**, see the next row |
| Live fight with trainer 318 (2026-10-14) | The game showed "Youngster Calvin" while the tracker named the trainer "Mikey". Entry 318 is Calvin and its party pointer at `name + 0x20` lists the enemy team (Poochyena, Lillipup, Rookidee); the earlier match read the party fields at `name - 0xC` / `name - 8`, which belong to the previous entry. Flag bit 318 set by the win. RAM id = entry; gym leader ids corrected from 264-271 to 265-272 |
| Probe 2 in mGBA | Confirmed flag bytes at `0x16db`, `0x16ff`, `0x1700`, `0x16dd` for ids 318, 603, 615, 333; `gBattleTypeFlags` `0x08` for trainers |
| Kill detection | First version counted any `hp > 0 → 0`. Live traces showed false kills on switch-ins (see below). Fixed with the identity check |
| Tracker | Run id came back as `0x000140AF`. Two causes in sequence: a misaligned `read32` (GBA bus rotates it), and mGBA's `require` cache keeping the old module after a reload. Final: `0xF9D040AF` |

| Battery save (`.sav`) parsed offline | Box section layout is vanilla (box names at storage offset 33604). New run, trainer id `0xE6066523`, six in the party, boxes empty |
| Pointer next to the save blocks | `0x03005da4` holds `0x02028848` in all six older savestates, and `0x02028848 + 33604` is where "BOX1" sits: `gPokemonStoragePtr` |
| Remote-driven session on the new save | Endless Candy Scatterbug L3 → L9 → Spewpa; deposit / move / withdraw in the PC; catch a wild Poochyena into Box 1 with a full party. A watcher logged every party and box change with checksums (`fixtures/private/r2-trace-evolve-pc-catch.log`); savestates at each step are `fixtures/private/r2-*.ss` |

| `gBattleOutcome` | EWRAM snapshots at the battle menu and after fleeing: three bytes went 0 → 4. Only `0x02023716` is referenced by the ROM's code (65 times; the others 0 and 1). Savestates confirm it: 7 after the Poochyena catch, 1 after an old trainer win, 0 during battles, and it keeps its value after the battle. A byte-diff at "Gotcha!" missed it because the outcome is only written after the nickname prompt |

## Kill detection evidence

Live traces of the enemy's `gBattleMons` slot (frame number, species, hp/maxHP, level):

```
f9721  Swirlix  0/27 lvl7      real death
f9960  Spinda  30/30 lvl8      replacement arrives
f9962  Spinda   0/27 lvl7      species of the new mon, hp/maxHP/level of the dead one
f9965  Swirlix  0/27 lvl7      the dead mon is back
f10072 Spinda  30/30 lvl8      settles
```

```
f53859 Krabby  0/27 lvl9       stale, for ~106 frames
f53965 Yanma  33/33 lvl9       settles
```

A bare "enemy hp reached 0" rule credited a kill at the stale frames. Requiring species, level, max hp, personality and OT id to match the previous frame rejects them. The `BattleMon` personality (`+0x4c`) and OT id (`+0x58`) also identify the enemy party slot exactly. Debouncing was rejected because the glitch lasts about 2 seconds.

## Catch and evolution evidence

Frame trace from the remote session (party slot 4, then 3 after a deposit compacted the party; `chk` is the substruct checksum):

```
f3745  party[4] Scatterbug(664) nick=Scatterbug lvl=9 chk=ok        candy, L9
f3867  cb2=0816e5d5                                                 evolution scene starts
f5176  party[4] ????(46919)     nick=Scatterbug met=167 chk=BAD     one frame mid-write
f5177  party[4] Spewpa(665)     nick=Spewpa     met=18  chk=ok      species and default nickname change together
```

```
f19579 party[1] empty                                               Store (deposit) Sizzlipede
f19580 party[1..4] shift up, party[5] empty; box 1 slot 0 Sizzlipede
f21308 partyCount 6 -> 5                                            only when the box screen closes
f23136 box 1 slot 0 empty                                           Move: picked up
f24324 box 1 slot 0 Sizzlipede                                      put down
f25392 box 1 slot 0 empty                                           Withdraw
f25439 party[5] Sizzlipede                                          47 frames later
```

```
f45608 partyCount=3, party[3] chk=BAD                               "Gotcha!" (one frame)
f50088 box 1 slot 0 Poochyena(261) met=16 chk=ok                    after declining a nickname, still in battle
f51678 cb2=080a3e6d                                                 back in the overworld
```

## Things that did not work

- Using the vanilla Emerald addresses: none match.
- Treating `gTrainerBattleOpponent_A` as "this is a trainer battle": it keeps the last trainer in wild battles.
- Guessing badge flag positions from vanilla flag numbers (`0x867+` → `sb1 + 0x1720`): the byte is identical across saves. Not needed anyway, since the split comes from leader flags.
- Calling `emu` from a coroutine in mGBA: "Function called from invalid context". The remote proxies each `emu` call back to the frame callback.
- `emu:addKeys` as a per-frame press: keys stay down until `clearKeys`, so the second press of the same key never registers.
- Clicking mGBA's menus with `osascript` (to load a script without the user): blocked without Accessibility permission (`-1719`).
- Diffing savestates from different timelines: the SaveBlock1 diff was unreadable noise (bag contents re-encrypted, many flags). Only pairs from one session were usable.

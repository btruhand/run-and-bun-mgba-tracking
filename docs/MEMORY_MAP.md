# Run & Bun 1.0.7 memory map

Base: pokeemerald-expansion (game code `BPEE`). Addresses are for the 32 MiB 1.0.7 ROM kept in `fixtures/private`, and live in code in [`lua/addresses.lua`](../lua/addresses.lua). How each one was found and checked is in [`lua_progress/spike-log.md`](lua_progress/spike-log.md).

Status key: **live** = read correctly in mGBA during play; **state** = checked against savestates only; **static** = read from the ROM file only.

## RAM

### Party

| What | Address | Status | Notes |
|------|---------|--------|-------|
| `gPlayerPartyCount` | `0x02023a95` | live | u8 |
| `gPlayerParty` | `0x02023a98` | live | 6 × 100 bytes |
| `gEnemyParty` | `0x02023cf0` | live | party + 600; used to find which enemy slot a battler is |

### Save blocks

Both are pointers into EWRAM; the targets move, so always dereference.

| What | Address | Status | Notes |
|------|---------|--------|-------|
| `gSaveBlock1Ptr` | `0x03005d9c` | live | |
| `gSaveBlock2Ptr` | `0x03005da0` | live | |
| SB2 trainer id | `sb2 + 0x0a` | live | u32 = TID \| SID << 16, equals the OT id of your own mons. Misaligned for a u32: read it as two u16 |
| SB2 play time | `sb2 + 0x0e` | live | u16 hours, u8 minutes, u8 seconds |
| SB1 party copy | `sb1 + 0x234` count, `sb1 + 0x238` mons | state | same as vanilla |
| Trainer-defeated flags | `sb1 + 0x16b4`, bit `id` | live | byte `id / 8`, bit `id % 8`, over RAM trainer ids. Consistent with `FLAG = 0x500 + id` and the flags array starting at `sb1 + 0x1614` |

### Battle

| What | Address | Status | Notes |
|------|---------|--------|-------|
| `gMain.inBattle` | `0x030022c0 + 0x439`, bit 1 | live | `0x02` in battle, `0` outside |
| `gBattleTypeFlags` | `0x02023364` | live | u32. Bit 3 (`0x8`) = trainer battle, bit 0 = double. Seen: `0x08` and `0x0c` for trainers, `0x00` for wild |
| `gTrainerBattleOpponent_A` | `0x020381ae` | live | u16 RAM trainer id. **Not cleared after a battle**: in a wild battle it still holds the last trainer |
| `gBattleMons` | `0x020233fc` | live | `BattleMon` is `0x5c` bytes; battler 0 = you, 1 = opponent, 2/3 = partners in doubles |

`BattleMon` fields (offsets within one entry):

| Offset | Field |
|--------|-------|
| `+0x00` | species (u16) |
| `+0x2a` | hp (u16) |
| `+0x2c` | level (u8) |
| `+0x2e` | max hp (u16) |
| `+0x4c` | personality (u32) |
| `+0x58` | OT id (u32) |

## Mon struct (party layout, 100 bytes)

- `+0` personality u32, `+4` OT id u32, `+8` nickname (10 bytes, Gen 3 charset), `+20` OT name.
- `+32` four 12-byte substructs, shuffled by `personality % 24` and XORed with `otId ^ personality`. The permutation table maps substruct type (growth, attacks, EVs, misc) to slot position. Implemented in `lua/gen3.lua`.
- Growth word 0: species (u16, expansion numbering, e.g. Sizzlipede 850) and held item.
- Misc word 0: bits 8-15 are the met location (a map section id). The starter has `255`, shown as "Fateful Encounter".
- Party-only fields: status `+80`, level `+84`, HP `+86`, max HP `+88`.

## ROM tables

| What | ROM address | Status | Notes |
|------|-------------|--------|-------|
| Species names | `0x083a0f80` | live | 11 bytes each, indexed by species id |
| Map section names | `0x086a1960` | state | 213 entries of 8 bytes, name pointer at `+4`, indexed by met location |
| `gTrainers` | `0x08398884` (name field of entry 0) | live | 865 entries of `0x28` bytes. Party size u32 at `name - 0xC`, party pointer at `name - 8` |

**RAM trainer id = `gTrainers` index − 1.** The game's `gTrainerBattleOpponent_A` is one less than the table entry holding that trainer's party. Confirmed on four trainers by matching the enemy party against the table: 318 → Mikey (319), 603 → Haley (604), 615 → Lyle (616), 333 → Gavi (334). Trainer flags use the RAM id.

Gym and League trainers (RAM ids, derived from the table with the −1 offset; **not yet seen live** — the first gym leader win will confirm them):

| Trainer | Table index | RAM id |
|---------|-------------|--------|
| Roxanne | 265 | 264 |
| Brawly | 266 | 265 |
| Wattson | 267 | 266 |
| Flannery | 268 | 267 |
| Norman | 269 | 268 |
| Winona | 270 | 269 |
| Tate & Liza | 271 | 270 |
| Juan | 272 | 271 |
| Sidney, Phoebe, Glacia, Drake | 261-264 | 260-263 |
| Wallace | 335 | 334 |

Table entries 770-801 repeat each leader in groups of four, and 844-847 repeat the Elite Four. They look like rematch or variant entries, not first fights.

## Behaviors that matter

- **`gBattleMons` is rewritten in pieces on a switch-in.** A replacement is briefly shown with the previous mon's hp, max hp and level (observed: `Spinda hp=30/30 lvl=8`, then `Spinda hp=0/27 lvl=7`, then the old Swirlix again, then Spinda for good). The glitch can last ~2 seconds (stale Krabby sat in the slot for ~106 frames). A kill is an enemy `hp > 0 → 0` drop only if species, level, max hp, personality and OT id are the same as on the previous frame.
- **`gTrainerBattleOpponent_A` goes stale**, so "trainer battle" must come from `gBattleTypeFlags`, not from a nonzero opponent id.
- **Unaligned reads are rotated.** mGBA's `emu:read32` at an address that isn't a multiple of 4 returns the aligned word rotated. Reading the trainer id (`sb2 + 0x0a`) as one u32 gave `0x000140AF` instead of `0xF9D040AF`. Use two u16 reads.
- The trainer flag is set on the same frame `gMain.inBattle` clears; it stays 0 after a lost fight.

## Not found yet

- **PC boxes** (`gPokemonStorage`). The community exporter lists `0x02028848`, which appears twice in the ROM's code, but it is unchecked. Needed for catches in boxes and for `sync`.
- **`gBattlerAttacker`**, to credit doubles kills exactly instead of "leftmost live mon, `ambiguous`".
- **Badge flags.** Not needed (the split comes from leader flags). Vanilla numbering puts them at `sb1 + 0x1720`, but that byte is identical in an early game and a later save, so the numbering differs.
- `gBattleOutcome`, `gTrainerBattleOpponent_B`, `gBattlerPartyIndexes`: not needed so far.

## Dead ends

- The community exporter's `speciesNameTable = 0x3185c8` is not a name table in 1.0.7. Its party and count addresses are right.
- Vanilla Emerald addresses (e.g. `gPlayerParty` `0x020244EC`) do not apply: nothing matches.

## Reading savestates offline

An mGBA savestate is a PNG with a zlib-compressed `gbAs` chunk (397312 bytes decompressed). EWRAM starts at offset `0x21000` and IWRAM at `0x19000`, so any RAM address can be read without the emulator. Re-saving the PNG in an image editor drops the chunk and destroys the state.

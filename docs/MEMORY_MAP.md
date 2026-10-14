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

The SB1 party copy is the party **as of the last save**, not the live party: during play it goes stale (a mon held in the PC cursor was found there, in its old slot). Always read `gPlayerParty`.

### PC boxes

| What | Address | Status | Notes |
|------|---------|--------|-------|
| `gPokemonStoragePtr` | `0x03005da4` | live | the pointer after `gSaveBlock2Ptr`; points to `0x02028848` in every state seen so far (dereference anyway) |
| current box | `storage + 0` | live | u8 |
| box mons | `storage + 4` | live | 14 boxes × 30 slots × 80 bytes, box-major (`4 + (box * 30 + slot) * 80`) |
| box names | `storage + 0x8344` | state | 14 × 9 bytes ("BOX1".."BOX14"); wallpapers follow |

The layout is vanilla Emerald's. The battery save (`.sav`) stores it the same way in sections 5-13 (box names at section 13, offset 1860).

### Screens

| What | Address | Status | Notes |
|------|---------|--------|-------|
| `gMain.callback2` | `0x030022c4` | live | u32 pointer to the current screen's main callback |

Values seen: overworld (also with the start menu open) `0x080a3e6d`, bag `0x081dc105`, party menu `0x081e195d`, evolution scene `0x0816e5d5`, PC box screen `0x080e62a9`, battle `0x0803816d`. Short-lived values appear between screens.

### Battle

| What | Address | Status | Notes |
|------|---------|--------|-------|
| `gMain.inBattle` | `0x030022c0 + 0x439`, bit 1 | live | `0x02` in battle, `0` outside |
| `gBattleTypeFlags` | `0x02023364` | live | u32. Bit 3 (`0x8`) = trainer battle, bit 0 = double. Seen: `0x08` and `0x0c` for trainers, `0x00` and `0x04` for wild (bit 2 is not a trainer marker), `0x10` / `0x14` for the scripted first battle. Bit 2 (`0x04`) is added a couple of frames after `gMain.inBattle` sets, so the value read on the battle's first frame lacks it (`0x00` wild, `0x10` first battle); the trainer bit is already there (`0x08` for the rival) |
| `gTrainerBattleOpponent_A` | `0x020381ae` | live | u16 RAM trainer id. **Not cleared after a battle**: in a wild battle it still holds the last trainer |
| `gBattleOutcome` | `0x02023716` | live | u8, vanilla values: `0` during a battle, `1` won, `4` ran, `7` caught (others unseen). Set at the end of the battle script (for a catch: after the nickname prompt, not at "Gotcha!"). Reset to 0 when a battle starts and **kept after it ends**, so read it when `gMain.inBattle` clears. 65 references in the ROM's code |
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
- `+19` flags byte: `0x02` (has species) on every mon seen. Vanilla also has bad egg `0x01` and egg `0x04`; the egg bit is unconfirmed here.
- `+28` checksum u16: the sum of the 24 decrypted u16 halves of the four substructs (vanilla algorithm, matches every stable read).
- Party-only fields: status `+80`, level `+84`, HP `+86`, max HP `+88`. A box mon is the first 80 bytes.

## ROM tables

| What | ROM address | Status | Notes |
|------|-------------|--------|-------|
| Species names | `0x083a0f80` | live | 11 bytes each, indexed by species id |
| Map section names | `0x086a1960` | state | 213 entries of 8 bytes, name pointer at `+4`, indexed by met location |
| `gTrainers` | `0x08398884` (name field of entry 0) | live | 865 entries of `0x28` bytes, indexed by RAM trainer id. Party size at `name + 0x1C`, party pointer at `name + 0x20` |

**RAM trainer id = `gTrainers` index.** `gTrainerBattleOpponent_A` indexes the table directly, as in vanilla. Confirmed live on trainer 318: the game shows "Youngster Calvin", entry 318's name is Calvin, its party pointer (`name + 0x20`) lists Calvin's Poochyena, Lillipup and Rookidee, and winning sets flag bit 318. An earlier reading took the party fields at `name - 0xC` / `name - 8`, which are the end of the *previous* entry, and concluded the id was one less than the entry; that was wrong. Trainer flags use the same id.

Gym and League trainers (RAM id = table index; **not yet seen live** — the first gym leader win will confirm them):

| Trainer | RAM id |
|---------|--------|
| Roxanne | 265 |
| Brawly | 266 |
| Wattson | 267 |
| Flannery | 268 |
| Norman | 269 |
| Winona | 270 |
| Tate & Liza | 271 |
| Juan | 272 |
| Sidney, Phoebe, Glacia, Drake | 261-264 |
| Wallace | 335 |

Table entries 770-801 repeat each leader in groups of four, and 844-847 repeat the Elite Four. They look like rematch or variant entries, not first fights.

## Behaviors that matter

- **`gBattleMons` is rewritten in pieces on a switch-in.** A replacement is briefly shown with the previous mon's hp, max hp and level (observed: `Spinda hp=30/30 lvl=8`, then `Spinda hp=0/27 lvl=7`, then the old Swirlix again, then Spinda for good). The glitch can last ~2 seconds (stale Krabby sat in the slot for ~106 frames). A kill is an enemy `hp > 0 → 0` drop only if species, level, max hp, personality and OT id are the same as on the previous frame.
- **`gTrainerBattleOpponent_A` goes stale**, so "trainer battle" must come from `gBattleTypeFlags`, not from a nonzero opponent id.
- **Unaligned reads are rotated.** mGBA's `emu:read32` at an address that isn't a multiple of 4 returns the aligned word rotated. Reading the trainer id (`sb2 + 0x0a`) as one u32 gave `0x000140AF` instead of `0xF9D040AF`. Use two u16 reads.
- The trainer flag is set on the same frame `gMain.inBattle` clears; it stays 0 after a lost fight.
- **A mon's data is decrypted in place while the game works on it.** For a single frame the substructs read as garbage and **the checksum fails** (seen when opening the party menu, on every level up, at the evolution and in battle). Species and met location read wrong on that frame. Accept a scanned mon only when its checksum is valid.
- **`gPlayerPartyCount` is not reliable.** In the PC it stays at the old value until the box screen closes (6 after a deposit with slot 5 empty; 5 after a withdraw with six mons). In battle it read 3 for one frame while the game recounted. Scan all six slots and treat a slot with personality and OT id 0 as empty.
- **Party slots move.** A deposit compacts the party on the next frame (every later mon shifts up one slot). Track mons by personality + OT id, never by slot.
- **A mon can be in neither the party nor a box.** Withdraw: the box slot empties about 47 frames before the mon appears in the party. Move Pokémon: picking a mon up empties its slot until it is put down (it sits in a heap buffer, seen at `0x02005340`). A disappearance is not a release.
- **Evolution** (Endless Candy, Scatterbug → Spewpa at L9): species and nickname (it still had the default name) change on the same frame, partway through the evolution scene (`callback2 = 0x0816e5d5`), before "Congratulations". The frame before is a failed-checksum read. Declining the new move afterwards does not change anything else.
- **Catch with a full party**: nothing changes at "Gotcha!". The mon is written to the first free box slot right after the nickname prompt, while `gMain.inBattle` is still set. It has the player's OT id and the route as met location (Poochyena, met 16 = Route 101).
- **Starter**: given by script when you pick it, before the first battle, and it can't be swapped afterwards. Traced on a new game: the choice screen is `callback2 = 0x08164079` with an empty party (count 0); 3 frames after confirming, party slot 0 holds the starter (met location 255, level 5, the run's OT id, nickname = species name, valid checksum) and the count becomes 1, all on the same frame. The first battle starts about 130 frames later (`inBattle` set), after one failed-checksum frame. That fight (Galarian Zigzagoon L2 in a new game) has `gBattleTypeFlags = 0x14` (vanilla `IS_MASTER | FIRST_BATTLE`), no trainer bit.
- `gMain.inBattle` (`+0x439`) bit 0 flickers on for single frames outside battle (party menu, PC). The tracker only reads bit 1.

## Not found yet

- **`gBattlerAttacker`**, to credit doubles kills exactly instead of "leftmost live mon, `ambiguous`".
- **Badge flags.** Not needed (the split comes from leader flags). Vanilla numbering puts them at `sb1 + 0x1720`, but that byte is identical in an early game and a later save, so the numbering differs.
- `gTrainerBattleOpponent_B`, `gBattlerPartyIndexes`: not needed so far.

## Dead ends

- The community exporter's `speciesNameTable = 0x3185c8` is not a name table in 1.0.7. Its party and count addresses are right.
- Vanilla Emerald addresses (e.g. `gPlayerParty` `0x020244EC`) do not apply: nothing matches.

## Reading savestates offline

An mGBA savestate is a PNG with a zlib-compressed `gbAs` chunk (397312 bytes decompressed). EWRAM starts at offset `0x21000` and IWRAM at `0x19000`, so any RAM address can be read without the emulator. Re-saving the PNG in an image editor drops the chunk and destroys the state.

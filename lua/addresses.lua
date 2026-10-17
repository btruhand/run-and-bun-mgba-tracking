-- Memory map for Pokémon Run & Bun 1.0.7 (see docs/MEMORY_MAP.md for how each was found and checked).
-- Everything else reads addresses from here, so another ROM version fails the check in gen3.verify
-- instead of silently reading garbage.

return {
  -- party
  party_count = 0x2023a95,
  party       = 0x2023a98,   -- 6 * 100 bytes
  enemy_party = 0x2023cf0,   -- 6 * 100 bytes
  mon_size    = 100,

  -- battle
  in_battle    = 0x30022c0 + 0x439,  -- gMain.inBattle, bit 1
  battle_type  = 0x2023364,          -- gBattleTypeFlags: bit 0 double, bit 3 trainer
  opponent_a   = 0x20381ae,          -- gTrainerBattleOpponent_A (u16); NOT cleared after a battle
  battle_mons  = 0x20233fc,
  battle_mon_size = 0x5c,
  battler_attacker = 0x2023594,      -- gBattlerAttacker (u8, battler 0..3); gBattlerTarget is the next byte
  battle_outcome = 0x2023716,        -- gBattleOutcome (u8): 1 won, 4 ran, 7 caught; kept after the battle
  bm = { species = 0x00, hp = 0x2a, level = 0x2c, max_hp = 0x2e, personality = 0x4c, ot_id = 0x58 },

  -- save blocks (pointers, dereference on every read)
  sb1_ptr = 0x3005d9c,
  sb2_ptr = 0x3005da0,
  storage_ptr = 0x3005da4, -- gPokemonStoragePtr (PC boxes)
  sb2_trainer_id = 0x0a,   -- u32: trainer id | secret id << 16, equals the OT id of your own mons
  sb2_play_time  = 0x0e,   -- u16 hours, u8 minutes, u8 seconds
  trainer_flags  = 0x16b4, -- sb1 offset of the trainer-defeated flag for trainer id 0

  -- PC boxes (offsets from the storage pointer's target)
  box_mons     = 4,     -- 14 boxes * 30 slots, box-major
  box_slots    = 14 * 30,
  box_mon_size = 80,

  -- ROM tables
  species_names  = 0x083a0f80, -- 11 bytes per name, indexed by species id
  trainers       = 0x08398884, -- gTrainers, name field of entry 0; indexed by RAM trainer id
  trainer_stride = 0x28,
  trainer_count  = 865,
  map_names      = 0x086a1960, -- 8-byte entries, name pointer at +4, indexed by met location
  map_count      = 213,

  -- RAM trainer ids of the eight gym leaders, in table order (Roxanne .. Juan; Run & Bun fights Brawly first, see
  -- docs/DESIGN.md "Splits"). The split is how many of these are defeated, so the order doesn't matter
  gym_leaders = { 265, 266, 267, 268, 269, 270, 271, 272 },
}

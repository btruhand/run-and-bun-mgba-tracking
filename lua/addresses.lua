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
  bm = { species = 0x00, hp = 0x2a, level = 0x2c, max_hp = 0x2e, personality = 0x4c, ot_id = 0x58 },

  -- save blocks (pointers, dereference on every read)
  sb1_ptr = 0x3005d9c,
  sb2_ptr = 0x3005da0,
  sb2_trainer_id = 0x0a,   -- u32: trainer id | secret id << 16, equals the OT id of your own mons
  sb2_play_time  = 0x0e,   -- u16 hours, u8 minutes, u8 seconds
  trainer_flags  = 0x16b4, -- sb1 offset of the trainer-defeated flag for trainer id 0

  -- ROM tables
  species_names  = 0x083a0f80, -- 11 bytes per name, indexed by species id
  trainers       = 0x08398884, -- gTrainers, name field of entry 0
  trainer_stride = 0x28,
  trainer_count  = 865,
  trainer_entry_offset = 1,    -- gTrainers entry = RAM trainer id + 1 (checked on four trainers)
  map_names      = 0x086a1960, -- 8-byte entries, name pointer at +4, indexed by met location

  -- RAM trainer ids of the eight gym leaders (Roxanne .. Juan); the split is how many of these are defeated
  gym_leaders = { 264, 265, 266, 267, 268, 269, 270, 271 },
}

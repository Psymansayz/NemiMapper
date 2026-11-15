-- The box round each node's, key's, door's and the Pahtli plant's model, by the game's location name: { west,
-- east, south, north, height } in fine units (512 a tile), unturned (rotation 0) and from the middle of the
-- tiles it stands on. Measured in game (2026-11-15, 19 forests): every copy of a location has the same box, turned
-- with it; only its floor follows the ground, which the highlight does not use.
-- A node is announced as its MultiLoc (the name without _OP or _NOOP), given the usable form's box. The statue
-- without its staff and the picked plant were never seen as locations, so they take the whole form's box.

local CONTENT = "RAID1_FOREST_DEADEND_CONTENT_"

return {
    [CONTENT .. "ALTAR"] = { -351, 279, -240, 203, 1044 },
    [CONTENT .. "ALTAR_OP"] = { -351, 279, -240, 203, 1044 },
    [CONTENT .. "ALTAR_NOOP"] = { -351, 279, -240, 203, 1044 },
    [CONTENT .. "CHEST"] = { -277, 277, -255, 100, 365 },
    [CONTENT .. "CHEST_OP"] = { -277, 277, -255, 100, 365 },
    [CONTENT .. "CHEST_NOOP"] = { -277, 277, -255, 148, 491 },
    [CONTENT .. "FLOWERS"] = { -300, 328, -307, 283, 761 },
    [CONTENT .. "FLOWERS_OP"] = { -300, 328, -307, 283, 761 },
    [CONTENT .. "FLOWERS_NOOP"] = { -300, 328, -307, 283, 761 },
    [CONTENT .. "FUNGUS"] = { -162, 231, -201, 224, 401 },
    [CONTENT .. "FUNGUS_OP"] = { -162, 231, -201, 224, 401 },
    [CONTENT .. "FUNGUS_NOOP"] = { -162, 231, -201, 224, 401 },
    [CONTENT .. "KNIGHT"] = { -149, 149, -92, 52, 789 },
    [CONTENT .. "KNIGHT_OP"] = { -149, 149, -92, 52, 789 },
    [CONTENT .. "KNIGHT_NOOP"] = { -149, 149, -92, 52, 789 },
    [CONTENT .. "MONK"] = { -357, 189, -388, 379, 828 },
    [CONTENT .. "MONK_OP"] = { -357, 189, -388, 379, 828 },
    [CONTENT .. "MONK_NOOP"] = { -357, 189, -388, 379, 180 },
    [CONTENT .. "MUSHROOMS"] = { -248, 248, -240, 232, 308 },
    [CONTENT .. "MUSHROOMS_OP"] = { -248, 248, -240, 232, 308 },
    [CONTENT .. "MUSHROOMS_NOOP"] = { -248, 248, -240, 232, 308 },
    [CONTENT .. "ORE"] = { -213, 215, -231, 233, 572 },
    [CONTENT .. "ORE_OP"] = { -213, 215, -231, 233, 572 },
    [CONTENT .. "ORE_NOOP"] = { -213, 215, -231, 232, 261 },
    [CONTENT .. "POOL"] = { -224, 224, -224, 224, 656 },
    [CONTENT .. "POOL_OP"] = { -224, 224, -224, 224, 656 },
    [CONTENT .. "POOL_NOOP"] = { -224, 224, -224, 224, 656 },
    RAID1_FOREST_DOOR1 = { -552, 387, -1593, 1328, 2858 },
    RAID1_FOREST_DOOR2 = { -346, 228, -1098, 1027, 1707 },
    RAID1_FOREST_DOOR3 = { -232, 148, -716, 685, 694 },
    RAID1_FOREST_DOOR4 = { -319, 337, -1037, 985, 855 },
    RAID1_FOREST_DOOR5 = { -361, 277, -1114, 1072, 784 },
    RAID1_FOREST_DOOR6 = { -381, 387, -1593, 1328, 2125 },
    RAID1_FOREST_KEY1 = { -141, 139, -175, 171, 637 },
    RAID1_FOREST_KEY2 = { -228, 118, -283, 235, 970 },
    RAID1_FOREST_KEY4 = { -284, 240, -366, 263, 855 },
    RAID1_FOREST_KEY4_NOSTAFF = { -284, 240, -366, 263, 855 },
    RAID1_FOREST_KEY5 = { -252, 271, -338, 254, 474 },
    RAID1_GOEBIE_MINIQUEST_FRUIT = { -341, 508, -264, 331, 1298 },
    RAID1_GOEBIE_MINIQUEST_FRUIT_NO_OP = { -341, 508, -264, 331, 1298 },
    RAID1_GOEBIE_MINIQUEST_FRUIT_MULTI = { -341, 508, -264, 331, 1298 },
}

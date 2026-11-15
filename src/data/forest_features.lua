-- What the plugin looks for in a Nemi Forest, by the game's names for its locations and NPCs (id.Loc, id.NPC).
--
--   key        the feature's icon (resources/<key>.png) and its entry in src/data/icon_sizes.lua
--   locations  the locations that are this feature
--   npcs       the NPCs that are this feature; a forest has one of each at most (forest.lua relies on it)
--   addedAs    the location the server adds when it is not one of `locations`. It is a MultiLoc that the client
--              shows as one of them by a variable, and identifies the feature before the client resolves it.
--   skill      the skill a node trains, which picks its legend icon (HITMARK_ICON_SKILL_<SKILL>)
--   toolItem   the tool's item name (id.Obj)
--   followMessages snippets of the info box or dialogue text shown when an NPC tool follows the player; any one
--              matches. Without them, an NPC tool next to the player counts as following.
--   followsOnTalk  the NPC tool follows whoever talks to it, so its name heading a dialogue line, while it is beside
--              the player, counts as following too
--   claimed    the VarBit (var.VarPlayer) set once the node's XP is claimed today
--   colour     a puzzle pair's colour, for its icon outlines (tools/make_map_art.ps1) and its route
--   boxHeight  the in-world highlight's height in fine units, where the default does not fit

local ForestFeatures = {}

-- Returns a skill node's feature.
-- A node shows as _OP while usable today and _NOOP once used. Its claim is the VarBit RAID1_FOREST_<claimed>, on
-- RAID1_FOREST_PLAYER_PERM_VARP1 alongside the goebie reputation (RAID1_GOEBIE_REP), which each claim raises by 3.
local function node(key, name, content, skill, claimed)
    local location = "RAID1_FOREST_DEADEND_CONTENT_" .. content
    return {
        key = key, name = name, skill = skill, claimed = "RAID1_FOREST_" .. claimed,
        locations = { location .. "_OP", location .. "_NOOP" }, usedLocations = { location .. "_NOOP" },
        addedAs = location,
    }
end

-- A node's in-world highlight colour, by skill.
ForestFeatures.skillColours = {
    prayer = 0x2F6FD6FF, farming = 0x6FD35AFF, mining = 0xD9A066FF, dungeoneering = 0xC07CFFFF,
}

-- The nine skill nodes, in legend order.
ForestFeatures.nodes = {
    node("chest", "Chest", "CHEST", "dungeoneering", "CHEST"),
    node("fungus", "Fungal growth", "FUNGUS", "farming", "FUNGUS"),
    node("flowers", "Flowers", "FLOWERS", "farming", "FLOWERS"),
    node("mushrooms", "Mushrooms", "MUSHROOMS", "farming", "MUSHROOM"),
    node("rocks", "Red rocks", "ORE", "mining", "ORE"),
    node("obelisk", "Obelisk", "ALTAR", "prayer", "TOTEM"),
    node("explorer", "Explorer", "KNIGHT", "prayer", "KNIGHT"),
    node("monk", "Dead monk", "MONK", "prayer", "MONK"),
    node("pool", "Water pool", "POOL", "prayer", "POOL"),
}

-- The order the forest hands out node kinds. Reading zones row by row from the south, each row west to east,
-- each node is the next kind in this cycle, starting from a point that varies per forest. This held in all 15
-- logged forests. A kind skipped between two consecutive nodes means a node was missed.
ForestFeatures.nodeRotation = {
    "obelisk", "pool", "explorer", "monk", "fungus", "chest", "mushrooms", "rocks", "flowers",
}

-- The nodes in rotation order, the order the scout window and the ribbon page list them in.
ForestFeatures.nodesInRotation = {}
for _, key in ipairs(ForestFeatures.nodeRotation) do
    for _, node in ipairs(ForestFeatures.nodes) do
        if node.key == key then ForestFeatures.nodesInRotation[#ForestFeatures.nodesInRotation + 1] = node end
    end
end

-- The targets of Trinks' tasks. The plant can only be picked while on its task.
--   questStruct  the task's struct, which the enum RAID1_GOEBIE_IDS_TO_STRUCTS maps to
--                RAID1_GOEBIE_CURRENT_QUEST's value
--   doneVar      the VarBit that becomes non-zero once the target is done (1 on killing the Traitor)
--   doneItem     the backpack item that shows it is done instead, since picking the fruit sets no variable
ForestFeatures.trinksTasks = {
    {
        key = "pahtli", name = "Pahtli plant", questStruct = "RAID1_GOEBIE_MINIQUEST_10",
        doneItem = "RAID1_GOEBIE_MINIQUEST_FRUIT",
        locations = { "RAID1_GOEBIE_MINIQUEST_FRUIT", "RAID1_GOEBIE_MINIQUEST_FRUIT_NO_OP" },
        addedAs = "RAID1_GOEBIE_MINIQUEST_FRUIT_MULTI",
    },
    { key = "traitor", name = "Traitor", npcs = { "RAID1_GOEBIE_TRAITOR" }, boxHeight = 975,
        questStruct = "RAID1_GOEBIE_MINIQUEST_9",
        doneVar = "RAID1_GOEBIE_NPC_SUBTASK" },
}

-- Each puzzle's tool, its source (the game's "key") and the barrier it opens (the game's "door").
-- An opened barrier becomes an unlisted location, so it drops off the map.
ForestFeatures.tools = {
    {
        tool = "Burning log", toolItem = "RAID1_FOREST_KEY1", colour = 0xFF8A1EFF,
        source = { key = "fire_pit", name = "Fire pit", locations = { "RAID1_FOREST_KEY1" } },
        barrier = { key = "web", name = "Web", locations = { "RAID1_FOREST_DOOR1" }, boxHeight = 1400 },
    },
    {
        tool = "Mysterious axe", toolItem = "RAID1_FOREST_KEY5", colour = 0xC77DFFFF,
        source = { key = "mysterious_weapon", name = "Mysterious weapon", locations = { "RAID1_FOREST_KEY5" } },
        barrier = { key = "barricade", name = "Barricade", locations = { "RAID1_FOREST_DOOR5" } },
    },
    {
        -- Info box: "The Lightning ball is already following you."
        -- Chatbox: "The Lightning ball seems to follow you..."
        tool = "Lightning", colour = 0x4FD8FFFF,
        followMessages = { "is already following you", "seems to follow you", "interested in following" },
        source = { key = "lightning", name = "Lightning", npcs = { "RAID1_FOREST_KEY3" }, boxHeight = 650 },
        barrier = { key = "pillars", name = "Pillars", locations = { "RAID1_FOREST_DOOR3" } },
    },
    {
        tool = "Raider axe", toolItem = "RAID1_FOREST_KEY2", colour = 0xFF5A4FFF,
        source = { key = "axe_in_stake", name = "Axe in stake", locations = { "RAID1_FOREST_KEY2" } },
        barrier = { key = "bound_logs", name = "Bound logs", locations = { "RAID1_FOREST_DOOR2" } },
    },
    {
        tool = "Mysterious staff", toolItem = "RAID1_FOREST_KEY4", colour = 0x7DDC5AFF,
        -- The statue remains, without its staff, once the staff is taken.
        source = {
            key = "mysterious_statue", name = "Mysterious statue",
            locations = { "RAID1_FOREST_KEY4", "RAID1_FOREST_KEY4_NOSTAFF" },
        },
        barrier = { key = "statues", name = "Mysterious statues", locations = { "RAID1_FOREST_DOOR4" } },
    },
    {
        -- Its line: "Hey! I'll follow you, lead me to my leader's portal ..."
        -- Once it follows, talking to it again gives another line, hence followsOnTalk.
        tool = "Lost goebie", colour = 0xFF7AD1FF, followMessages = { "I'll follow you" }, followsOnTalk = true,
        source = { key = "goebie", name = "Lost goebie", npcs = { "RAID1_FOREST_KEY6" }, boxHeight = 650 },
        -- The client caches an image by file name once loaded, so a redrawn icon needs a new name or a client
        -- restart. That is why this one is not called "portal".
        barrier = { key = "portal_light", name = "Portal", locations = { "RAID1_FOREST_DOOR6" } },
    },
}

-- The most monsters one forest can spawn, per the wiki. They spawn as the player walks into dead ends.
-- Any NPC with an Attack option that is not a familiar and not listed above counts.
ForestFeatures.monstersAtMost = 25

-- Trinks gives this many tasks a day.
ForestFeatures.tasksADay = 3
-- Each task, by RAID1_GOEBIE_CURRENT_QUEST's value, for the ribbon page: a short name (the RuneScape Wiki's, as
-- the game's structs hold no text) and the parts counted for it, each with the count the task asks for and a word
-- for the progress line. A part is a VarBit of RAID1_REPEATABLE_CONTENT (var: the game counts NPCs and locations
-- there) or an item carried (item: the scraps and the driftwood change no variable while gathered). The VarBits,
-- items and targets were seen in game, except Clear Rocks' target, which is the wiki's.
-- The Pahtli plant's task counts nothing: the fruit held shows it done.
local NPCS, LOCATIONS = "RAID1_GOEBIE_NPC_SUBTASK", "RAID1_GOEBIE_LOC_SUBTASK"
ForestFeatures.trinksDailyTasks = {
    { name = "Kill Airut", parts = { { var = NPCS, of = 10, what = "Airut" } } },
    { name = "Salvage Scraps",                                                             -- ruined tents in Kanatah
        parts = { { item = "RAID1_GOEBIE_MINIQUEST_SCRAPS", of = 5, what = "scraps" } } },
    { name = "Repair Fences", parts = { { var = LOCATIONS, of = 10, what = "fences" } } }, -- around Kanatah
    { name = "Clear Rocks", parts = { { var = LOCATIONS, of = 10, what = "rocks" } } },    -- north-west of Kanatah
    { name = "Light Beacon", parts = { { var = LOCATIONS, of = 1, what = "beacon" } } },   -- north of the east entrance
    { name = "Collect Driftwood",                                                          -- returned to Trinks
        parts = { { item = "RAID1_GOEBIE_MINIQUEST_DRIFTWOOD", of = 10, what = "driftwood" } } },
    { name = "Otot Message", parts = { { var = NPCS, of = 1, what = "message" } } },       -- delivered to Acca Otot
    { name = "Free Goebies",                                                              -- caged by the Airut
        parts = { { var = NPCS, of = 5, what = "Airut" }, { var = LOCATIONS, of = 5, what = "freed" } } },
    { name = "Traitor", parts = { { var = NPCS, of = 1, what = "Traitor" } } },           -- in the forest
    { name = "Pahtli Plant", parts = {} },                                                 -- its fruit, in the forest
}

-- A feature's colour, for its routes, rows and boxes: a node's skill's, a puzzle's pair's, or Trinks' tasks'.
local TASK_COLOUR = 0xE9B93EFF
function ForestFeatures.colourOf(feature)
    if feature.kind == "node" then return ForestFeatures.skillColours[feature.skill] end
    if feature.isPuzzle then return feature.pair.colour end
    return TASK_COLOUR
end

return ForestFeatures

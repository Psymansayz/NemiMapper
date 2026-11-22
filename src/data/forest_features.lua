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
--              matches
--   refusals   Lua patterns of the text shown when an NPC tool follows another player, capturing that player's name
--   claimed    the VarBit (var.VarPlayer) set once the node's XP is claimed today
--   colour     a puzzle pair's colour, for its icon outlines (tools/make_map_art.ps1) and its route
--   boxHeight  the in-world highlight's height in fine units, where its saved box's does not fit
--   kind       "node", "task", "source" (a puzzle's key) or "barrier" (its door), set below, with isPuzzle for the
--              last two and pair, their puzzle
--   layer      the order the map draws the kinds in, doors first

local Settings = require("src/data/settings")

local ForestFeatures = {}

-- Returns a skill node's feature.
-- A node shows as _OP while usable today and _NOOP once used.
local function node(key, name, content, skill, claimed)
    local location = "RAID1_FOREST_DEADEND_CONTENT_" .. content
    return {
        key = key, name = name, skill = skill, claimed = "RAID1_FOREST_" .. claimed,
        locations = { location .. "_OP", location .. "_NOOP" },
        addedAs = location,
    }
end

-- The nine skill nodes, in legend order.
-- The game's names for a node differ from each other and from what the player sees, so each is given.
--   key      the plugin's name for the node: its icon and its key in ForestFeatures.byKey
--   name     the name the legend shows
--   content  the game's location name, RAID1_FOREST_DEADEND_CONTENT_<content>
--   skill    the skill it trains
--   claimed  the game's VarBit set once its XP is claimed today, RAID1_FOREST_<claimed>
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

-- The order the forest spawns nodes. Reading zones row by row from the south, each row west to east,
-- each node is the next kind in this cycle, starting from a point that varies per forest. 
-- A kind skipped between two consecutive nodes means a node was missed.
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

-- Trinks' daily tasks.
--   questStruct  the task's struct, which the enum RAID1_GOEBIE_IDS_TO_STRUCTS maps to
--                RAID1_GOEBIE_CURRENT_QUEST's value
--   parts        what the game counts toward the task: a VarBit (var) or backpack items (item), up to `of`
local NPCS, LOCATIONS = "RAID1_GOEBIE_NPC_SUBTASK", "RAID1_GOEBIE_LOC_SUBTASK"
ForestFeatures.dailyTasks = {
    { name = "Kill Airut", questStruct = "RAID1_GOEBIE_MINIQUEST_1",
        parts = { { var = NPCS, of = 10, what = "Airut" } } },
    { name = "Salvage Scraps", questStruct = "RAID1_GOEBIE_MINIQUEST_2",   -- ruined tents in Kanatah
        parts = { { item = "RAID1_GOEBIE_MINIQUEST_SCRAPS", of = 5, what = "scraps" } } },
    { name = "Repair Fences", questStruct = "RAID1_GOEBIE_MINIQUEST_3",    -- around Kanatah
        parts = { { var = LOCATIONS, of = 10, what = "fences" } } },
    { name = "Clear Rocks", questStruct = "RAID1_GOEBIE_MINIQUEST_4",      -- north-west of Kanatah
        parts = { { var = LOCATIONS, of = 10, what = "rocks" } } },
    { name = "Light Beacon", questStruct = "RAID1_GOEBIE_MINIQUEST_5",     -- north of the east entrance
        parts = { { var = LOCATIONS, of = 1, what = "beacon" } } },
    { name = "Collect Driftwood", questStruct = "RAID1_GOEBIE_MINIQUEST_6", -- returned to Trinks
        parts = { { item = "RAID1_GOEBIE_MINIQUEST_DRIFTWOOD", of = 10, what = "driftwood" } } },
    { name = "Otot Message", questStruct = "RAID1_GOEBIE_MINIQUEST_7",     -- delivered to Acca Otot
        parts = { { var = NPCS, of = 1, what = "message" } } },
    { name = "Free Goebies", questStruct = "RAID1_GOEBIE_MINIQUEST_8",     -- caged by the Airut
        parts = { { var = NPCS, of = 5, what = "Airut" }, { var = LOCATIONS, of = 5, what = "freed" } } },
    { key = "traitor", name = "Traitor", questStruct = "RAID1_GOEBIE_MINIQUEST_9",
        parts = { { var = NPCS, of = 1, what = "Traitor" } }, npcs = { "RAID1_GOEBIE_TRAITOR" } },
    { key = "pahtli", name = "Pahtli Plant", questStruct = "RAID1_GOEBIE_MINIQUEST_10",
        parts = { { item = "RAID1_GOEBIE_MINIQUEST_FRUIT", of = 1, what = "fruit" } },
        locations = { "RAID1_GOEBIE_MINIQUEST_FRUIT", "RAID1_GOEBIE_MINIQUEST_FRUIT_NO_OP" },
        addedAs = "RAID1_GOEBIE_MINIQUEST_FRUIT_MULTI" },
}
-- These two have addiitonal navigation in the forest.
ForestFeatures.trinksTasks = { ForestFeatures.dailyTasks[10], ForestFeatures.dailyTasks[9] }

-- Each puzzle's tool, its source ("key") and the barrier it opens ("door").
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
        -- Following another player, its info box says "That seems to be following <name> at the moment."
        tool = "Lightning", colour = 0x4FD8FFFF,
        followMessages = { "is already following you", "seems to follow you", "interested in following" },
        refusals = { "seems to be following (.-) at the moment" },
        source = { key = "lightning", name = "Lightning", npcs = { "RAID1_FOREST_KEY3" } },
        barrier = { key = "pillars", name = "Pillars", locations = { "RAID1_FOREST_DOOR3" } },
    },
    {
        tool = "Raider axe", toolItem = "RAID1_FOREST_KEY2", colour = 0xFF5A4FFF,
        source = { key = "axe_in_stake", name = "Axe in stake", locations = { "RAID1_FOREST_KEY2" } },
        barrier = { key = "bound_logs", name = "Bound logs", locations = { "RAID1_FOREST_DOOR2" } },
    },
    {
        tool = "Mysterious staff", toolItem = "RAID1_FOREST_KEY4", colour = 0x7DDC5AFF,
        -- The NO_STAFF statue still visually has a staff, but the object changes.
        source = {
            key = "mysterious_statue", name = "Mysterious statue",
            locations = { "RAID1_FOREST_KEY4", "RAID1_FOREST_KEY4_NOSTAFF" },
        },
        barrier = { key = "statues", name = "Mysterious statues", locations = { "RAID1_FOREST_DOOR4" } },
    },
    {
        -- Its line: "Hey! I'll follow you, lead me to my leader's portal ...", and once it follows: "I'm following you,
        -- have you seen the portal I can use to get out of here yet?" (matched that far, as a refusal starts the same
        -- and the player named may be "you..."). Following another player, it says "Sorry, I'm following <name> right
        -- now, they found me first!" instead.
        tool = "Lost goebie", colour = 0xFF7AD1FF,
        followMessages = { "I'll follow you", "I'm following you, have you seen" },
        refusals = { "following (.-) right now, they found me first" },
        source = { key = "goebie", name = "Lost goebie", npcs = { "RAID1_FOREST_KEY6" } },
        barrier = { key = "portal_light", name = "Portal", locations = { "RAID1_FOREST_DOOR6" } },
    },
}

-- The most monsters one forest can spawn
-- Any NPC with an Attack option that is not a familiar and not listed above counts.
ForestFeatures.monstersAtMost = 25
-- Maximum number of Trinks' tasks per day
ForestFeatures.tasksADay = 3

ForestFeatures.entranceSigns = {
    { key = "sign_otot", side = "north", colour = 0xF7E1A0FF },
    { key = "sign_kanatah", side = "east", colour = 0xF7E1A0FF },
}

ForestFeatures.all, ForestFeatures.byKey = {}, {}
local function describe(feature, kind, layer)
    feature.kind, feature.layer, feature.isPuzzle = kind, layer, kind == "source" or kind == "barrier"
    ForestFeatures.all[#ForestFeatures.all + 1] = feature
    ForestFeatures.byKey[feature.key] = feature
end
for _, toolPair in ipairs(ForestFeatures.tools) do
    describe(toolPair.barrier, "barrier", 1)
    describe(toolPair.source, "source", 2)
    toolPair.barrier.pair, toolPair.source.pair = toolPair, toolPair
end
for _, task in ipairs(ForestFeatures.trinksTasks) do describe(task, "task", 3) end
for _, node in ipairs(ForestFeatures.nodes) do describe(node, "node", 4) end

-- The setting holding each skill's node colour.
local SKILL_COLOUR_SETTING = {
    prayer = "prayerColour", farming = "farmingColour", mining = "miningColour", dungeoneering = "dungeoneeringColour",
}

-- Returns a feature's colour, for its routes, rows and boxes: its skill's or Trinks' tasks', as set, or its puzzle
-- pair's.
function ForestFeatures.colourOf(feature)
    if feature.kind == "node" then return Settings[SKILL_COLOUR_SETTING[feature.skill]] end
    if feature.isPuzzle then return feature.pair.colour end
    return Settings.tasksColour
end

return ForestFeatures

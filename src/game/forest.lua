-- The Nemi Forest the player is in: its zones, bounds, walkable tiles, what is in it, and where the player is.
-- The forest is an instance whose zones are copied from one map square; that is how it is recognised.

local ForestFeatures = require("src/data/forest_features")
local GameIds = require("src/game/game_ids")
local ForestGrid = require("src/game/forest_grid")
local StandingHeights = require("src/game/standing_heights")
local DialogueText = require("src/game/dialogue_text")
local DrawDistance = require("src/game/draw_distance")
local ModelBounds = require("src/game/model_bounds")

local Forest = {}

local SUBSCRIPTION = "nemi_mapper_forest"
local ZONE_SIZE = 8 -- tiles: a region is built of zones
local ZONES_PER_MAP_SQUARE = 8
local MAP_SQUARE_SIZE = 64 -- tiles
-- The map square the forest's zones are copied from.
local TEMPLATE_SQUARE_X, TEMPLATE_SQUARE_Z = 65, 10
-- South-west tile of the template zone in the middle of each opening (entrance and exit).
-- A forest zone copied from it is an opening on the forest's edge.
local OPENING_SOURCE_X, OPENING_SOURCE_Z = 4200, 664
local ARRIVAL_TICKS = 10 -- server ticks for a new region's zones to become readable
-- Server ticks after a region's creation during which added locations count as the server's announcement (it
-- arrives on ticks 0-2). Later additions are changes.
local ANNOUNCING_TICKS = 4
local SETTLING_TICKS = 8 -- server ticks to keep scanning after the last find or change
-- Server ticks after the last find before the search shows as done, when the announcement was missed (the plugin
-- loaded inside the forest). Finds arrive over the first 2-4 ticks, never more than 2 apart.
-- Scans still run for SETTLING_TICKS, since some locations arrive without an event, so a late find still shows.
local SHOWN_SETTLED_AFTER = 4
-- Server ticks to look for NPCs after the player enters another zone: they reach the client only near the player,
-- and a teleport's surroundings load a tick later.
local ZONE_SCAN_TICKS = 3
local SAME_NPC_DISTANCE = 16 -- tiles
local NPC_DRIFTED = 2 -- tiles an NPC must drift from its marker before the marker moves
-- Minimum server ticks between an NPC marker's moves.
-- The lightning wanders about a tile a tick, and each move redraws routes.
local NPC_MOVE_TICKS = 2

Forest.isInside = false
Forest.isSearching = false -- more may still be found
Forest.bounds = nil     -- { minX, minZ, width, length } in tiles; nil outside a forest
Forest.zones = {}       -- [n] = { x, z, sourceX, sourceZ }: south-west tiles of a zone and of the zone it copies
Forest.grid = nil       -- the forest's walkable tiles (src/game/forest_grid.lua), once its zones' turns are settled
Forest.zoneTurns = nil  -- zone index -> quarter turns, as last worked out, settled or not: for the map's pictures
Forest.openings = {}    -- [n] = { x, z }: the mouth of each opening (entrance, exit)
Forest.standingByZone = {}  -- "x,z" of a zone -> what stands on its tiles (src/game/standing_heights.lua);
                            -- shows which way the zone was turned
Forest.found = {}       -- [n] = { feature, x, z, width, length, isUsed }: centre in tiles, size, and for a node
                        -- whether it was used today; drawn in this order
Forest.countOf = {}     -- feature key -> how many were found
Forest.doorsGone = {}   -- barrier key -> true once a found barrier is gone (its puzzle is done)
Forest.monstersSpawned = 0 -- hostile monsters spawned in this forest, each entity counted once
Forest.following = {}   -- source key -> true while that NPC tool follows the player; kept until leaving the forest
Forest.followingVersion = 0 -- counts changes to following, for what keeps an answer that depends on it
Forest.ticks = 0         -- server ticks counted while a region is watched
Forest.keysHeldBefore = {} -- source key -> true: tools held when last checked (src/game/tools_held.lua)
Forest.keysUsedAt = {}  -- source key -> the tick its tool was used on its barrier
Forest.playerTile = nil -- { x, z }: the player's tile, while within the forest's bounds
Forest.entryTile = nil  -- { x, z }: the player's first tile within the forest's bounds
Forest.onEntered = nil  -- called once when a forest is recognised
Forest.onLeft = nil     -- called when the forest is left
Forest.onChanged = nil  -- called when what was found changes, and when the search ends
Forest.onMoved = nil    -- called when the player's tile changes
Forest.onMonstersChanged = nil -- called when a monster spawns (only the count changed)
Forest.onInventoryChanged = nil -- called when the backpack or worn items change, once the player's tile is known
Forest.onNpcMoved = nil -- called with a found NPC's entry when its marker moves (only its x, z changed)

local featureOfLocID, featureOfNpcID = {}, {}
local featureAddedAs = {} -- location id the server adds -> its feature, when that is not one of its locations
local followMessages = {} -- game message -> source key of the NPC that then follows the player
for _, toolPair in ipairs(ForestFeatures.tools) do
    for _, message in ipairs(toolPair.followMessages or {}) do followMessages[message] = toolPair.source.key end
end
local usedLocIDs = {} -- location id of a node used today -> true
-- Each node's VarBit for XP claimed today, and the base variable they belong to, which is what the server sends.
-- A node whose VarBit the game does not know has none, so only its used form tells.
local claimedVariableOf, claimedBaseID = {}, nil
for _, node in ipairs(ForestFeatures.nodes) do
    local variable = GameIds.playerVariable(node.claimed)
    claimedVariableOf[node.key] = variable
    if variable ~= nil and variable.baseVar ~= nil then claimedBaseID = variable.baseVar.id end
end

-- Lists a feature under its game ids, with its kind ("node", "task", "source" or "barrier") and layer (a higher one
-- is drawn over a lower one).
local function list(feature, kind, layer)
    feature.kind, feature.layer = kind, layer
    feature.isPuzzle = kind == "source" or kind == "barrier"
    for _, name in ipairs(feature.locations or {}) do
        local locID = GameIds.resolve("Loc", name)
        if locID ~= nil then featureOfLocID[locID] = feature end
    end
    for _, name in ipairs(feature.usedLocations or {}) do
        local locID = GameIds.resolve("Loc", name)
        if locID ~= nil then usedLocIDs[locID] = true end
    end
    for _, name in ipairs(feature.npcs or {}) do
        local npcID = GameIds.resolve("NPC", name)
        if npcID ~= nil then featureOfNpcID[npcID] = feature end
    end
    if feature.addedAs ~= nil then
        local locID = GameIds.resolve("Loc", feature.addedAs)
        if locID ~= nil then featureAddedAs[locID] = feature end
    end
end

for _, toolPair in ipairs(ForestFeatures.tools) do
    list(toolPair.barrier, "barrier", 1)
    list(toolPair.source, "source", 2)
    toolPair.barrier.pair, toolPair.source.pair = toolPair, toolPair
end
for _, task in ipairs(ForestFeatures.trinksTasks) do list(task, "task", 3) end
for _, node in ipairs(ForestFeatures.nodes) do list(node, "node", 4) end

-- What the forest has shown so far. Things stay known out of sight; only a change at their tile removes them.
local locationsFound = {} -- packed coordinate -> { feature, x, z }
local npcsFound = {}      -- [n] = { feature, x, z }: where each was first seen
local monstersSeen = {}   -- entity uid -> true, so a monster back in view is not a new spawn
local foundChanged = false
-- The grid's inputs (the zones' standing heights) changed since it was built.
-- Other changes (a find, a claim, a task, a follower) publish with the grid kept.
local gridStale = false
local arrivalTicksLeft = 0
local settlingTicksLeft = 0
local zoneScanTicksLeft = 0

-- Nodes whose XP was claimed today: read on entering the forest, whenever the server sends their base variable,
-- and for the ribbon page's count.
local claimedNow = {} -- node key -> true
local taskItemsHeld = {} -- task -> true while its doneItem is held, as last checked
-- The player's current Trinks' task and its base variable, which is what the server sends.
-- Both are nil if the game does not know the task variable, and then every task counts as active.
local currentQuest = GameIds.playerVariable("RAID1_GOEBIE_CURRENT_QUEST")
local currentQuestBaseID = currentQuest ~= nil and currentQuest.baseVar ~= nil and currentQuest.baseVar.id or nil

local function readClaimed()
    claimedNow = {}
    for key, variable in pairs(claimedVariableOf) do
        if variable.value ~= 0 then claimedNow[key] = true end
    end
end

-- Each task's current-quest value, from the game's enum, read under pcall.
-- A task without one counts as always on and is reported like an unknown name.
local questOf = {}
for _, task in ipairs(ForestFeatures.trinksTasks) do
    local found, quest = pcall(function()
        return config.Enum.RAID1_GOEBIE_IDS_TO_STRUCTS:GetInputValues(config.Struct[task.questStruct])[1]
    end)
    if found and quest ~= nil then
        questOf[task] = quest
    else
        GameIds.noteUnknown("Struct", task.questStruct)
    end
end

-- Each task's VarBit marking its target's part done, and the item it gives, if any and known to the game.
local doneVariableOf, doneItemOf = {}, {}
for _, task in ipairs(ForestFeatures.trinksTasks) do
    if task.doneVar ~= nil then doneVariableOf[task] = GameIds.playerVariable(task.doneVar) end
    if task.doneItem ~= nil then doneItemOf[task] = GameIds.resolve("Obj", task.doneItem) end
end

-- Items in the backpack and worn equipment (WORN is skipped if the game does not know it): item id -> true. In
-- the forest it is read at most once a server tick, since inventories change only with server packets, and again
-- after an inventory changes. Outside the forest it is read on every call.
local HELD_INVENTORY_IDS = { config.Inv.INV.id, GameIds.resolve("Inv", "WORN") }
local isHeldInventory = {}
for _, inventoryID in ipairs(HELD_INVENTORY_IDS) do isHeldInventory[inventoryID] = true end
local itemsHeldNow, itemsHeldTick = nil, nil
function Forest.itemsHeld()
    if itemsHeldNow ~= nil and Forest.isInside and itemsHeldTick == Forest.ticks then return itemsHeldNow end
    local items = {}
    for _, inventoryID in ipairs(HELD_INVENTORY_IDS) do
        for _, slot in ipairs(Inventory.Find(inventoryID):GetSlots()) do
            -- an empty slot holds object id -1
            if slot.obj ~= nil and slot.obj.id >= 0 then items[slot.obj.id] = true end
        end
    end
    itemsHeldNow, itemsHeldTick = items, Forest.ticks
    return items
end

local function holdsDoneItem(task)
    local itemID = doneItemOf[task]
    return itemID ~= nil and Forest.itemsHeld()[itemID] == true
end

-- Returns a task's value of RAID1_GOEBIE_CURRENT_QUEST, or nil if the game's enum does not give it.
function Forest.questOf(task)
    return questOf[task]
end

-- Returns the tile of a found thing's south-west corner, from its centre and size.
function Forest.southWestOf(entry)
    return math.floor(entry.x - entry.width / 2), math.floor(entry.z - entry.length / 2)
end

-- Returns whether the player is on a Trinks' task, read live from the game's variable.
function Forest.isOnTask(task)
    return currentQuest == nil or questOf[task] == nil or currentQuest.value == questOf[task]
end

-- Returns whether the player needs a Trinks' task's target now: on that task, with that part not done yet.
function Forest.isTaskActive(task)
    if not Forest.isOnTask(task) or holdsDoneItem(task) then return false end
    local doneVariable = doneVariableOf[task]
    return doneVariable == nil or doneVariable.value == 0
end

-- Reads which nodes the player has claimed today from the game's variables, which are live outside the forest
-- too, and returns how many. isNodeClaimed then answers for each.
function Forest.readClaimedToday()
    readClaimed()
    local count = 0
    for _ in pairs(claimedNow) do count = count + 1 end
    return count
end

-- Trinks' tasks done today.
local tasksDoneVariable = GameIds.playerVariable("RAID1_GOEBIE_QUESTS_COMPLETE_TODAY")
local tasksDoneBaseID = tasksDoneVariable ~= nil and tasksDoneVariable.baseVar ~= nil and tasksDoneVariable.baseVar.id
    or nil
function Forest.tasksDoneToday()
    return tasksDoneVariable ~= nil and tasksDoneVariable.value or 0
end

-- The VarBits the game counts a task's parts in, and the items it counts by, by name, where the game knows them.
local partVariableOf, partItemOf = {}, {}
for _, task in ipairs(ForestFeatures.trinksDailyTasks) do
    for _, part in ipairs(task.parts) do
        if part.var ~= nil and partVariableOf[part.var] == nil then
            partVariableOf[part.var] = GameIds.playerVariable(part.var)
        end
        if part.item ~= nil and partItemOf[part.item] == nil then
            partItemOf[part.item] = GameIds.resolve("Obj", part.item)
        end
    end
end

-- Returns whether a change to inventoryID may alter the current task's progress: inventoryID is the backpack, and the
-- task counts items carried.
function Forest.taskCountsItems(inventoryID)
    if inventoryID ~= config.Inv.INV.id or currentQuest == nil then return false end
    local task = ForestFeatures.trinksDailyTasks[currentQuest.value]
    if task == nil then return false end
    for _, part in ipairs(task.parts) do
        if part.item ~= nil then return true end
    end
    for _, forestTask in ipairs(ForestFeatures.trinksTasks) do
        if questOf[forestTask] == currentQuest.value and doneItemOf[forestTask] ~= nil then return true end
    end
    return false
end

-- Returns the current Trinks' task, or nil while the player has none: its name, its parts as counted ({ what,
-- count, of }) and whether it is done and ready to hand in, which is every part at its target, or the fruit held
-- for the Pahtli plant's task.
-- A task value the list lacks is "task" and its number, with no parts.
function Forest.currentTask()
    if currentQuest == nil or currentQuest.value == 0 then return nil end
    local quest = currentQuest.value
    local task = ForestFeatures.trinksDailyTasks[quest]
    if task == nil then return { name = "task " .. quest, parts = {}, done = false } end
    local parts, done = {}, true
    for index, part in ipairs(task.parts) do
        local count = 0
        if part.var ~= nil then
            local variable = partVariableOf[part.var]
            count = variable ~= nil and variable.value or 0
        elseif partItemOf[part.item] ~= nil then
            count = Inventory.Find(config.Inv.INV.id):GetTotal(partItemOf[part.item])
        end
        parts[index] = { what = part.what, count = count, of = part.of }
        done = done and count >= part.of
    end
    -- The backpack is read directly, as the ribbon page may ask before the forest's own inventory listener drops
    -- the items held this tick (Forest.itemsHeld).
    local backpack = Inventory.Find(config.Inv.INV.id)
    for _, forestTask in ipairs(ForestFeatures.trinksTasks) do
        local itemID = doneItemOf[forestTask]
        if questOf[forestTask] == quest and itemID ~= nil then done = backpack:GetTotal(itemID) > 0 end
    end
    return { name = task.name, parts = parts, done = done }
end

-- Returns the base variables the server sends for the claims, the current task and the tasks done, which the
-- ribbon page's status follows.
function Forest.dailyVariableIDs()
    return claimedBaseID, currentQuestBaseID, tasksDoneBaseID
end

-- Returns whether the XP of nodeKey's node was claimed today, as last read.
function Forest.isNodeClaimed(nodeKey)
    return claimedNow[nodeKey] == true
end

-- The NPC tools that follow whoever talks to them (followsOnTalk), with their names as a dialogue box heads their
-- lines. A name the game does not give leaves that NPC to its follow messages.
local SPEAKER_DISTANCE = 4 -- tiles: the player stands beside an NPC to talk to it, and it may step away
local followSpeakers = {} -- [n] = { sourceKey, npcID, name }
for _, toolPair in ipairs(ForestFeatures.tools) do
    if toolPair.followsOnTalk then
        for _, npcName in ipairs(toolPair.source.npcs) do
            local npcID = GameIds.resolve("NPC", npcName)
            if npcID ~= nil then
                followSpeakers[#followSpeakers + 1] = {
                    sourceKey = toolPair.source.key, npcID = npcID, name = config.NPC.FromID(npcID).name,
                }
            end
        end
    end
end

-- Returns whether an NPC of config npcID stands within SPEAKER_DISTANCE of the player.
local function npcBesidePlayer(npcID)
    local player = Forest.playerTile
    if player == nil then return false end
    for _, npcEntity in ipairs(NPCList.ByConfigID(npcID)) do
        local coord = npcEntity.coordGrid
        if math.abs(coord.x - player.x) <= SPEAKER_DISTANCE and math.abs(coord.z - player.z) <= SPEAKER_DISTANCE then
            return true
        end
    end
    return false
end

local function noteFollowing(sourceKey)
    Forest.following[sourceKey] = true
    Forest.followingVersion = Forest.followingVersion + 1
    foundChanged = true
end

-- Notes a follower when the text contains one of the data's follow messages, or is the name heading the line of
-- an NPC that follows whoever talks to it, while one stands beside the player. The plugin can forget a follower
-- (reloaded, or the forest entered again), and the line such an NPC says once it follows is not its first, so
-- talking to it again restores it.
local function noteFollowText(text)
    for message, sourceKey in pairs(followMessages) do
        if not Forest.following[sourceKey] and text:find(message, 1, true) then noteFollowing(sourceKey) end
    end
    local plainText = (text:gsub("<[^>]*>", ""))
    for _, speaker in ipairs(followSpeakers) do
        if not Forest.following[speaker.sourceKey] and plainText == speaker.name and npcBesidePlayer(speaker.npcID) then
            noteFollowing(speaker.sourceKey)
        end
    end
end

-- Reads the info box and the dialogue box for follow messages, while something may still follow.
-- The lightning's message shows in the info box, the goebie's in the dialogue box.
local function readDialogue()
    for _, sourceKey in pairs(followMessages) do
        if not Forest.following[sourceKey] then
            for _, text in ipairs(DialogueText.open()) do noteFollowText(text) end
            return
        end
    end
end

-- The server's announcement. Every node, key and barrier arrives as a LocAdded event in one burst on the
-- region's first ticks (0-2, sometimes after the forest is entered), before the client loads any of them. Scans
-- only see what the client loads, which a low draw distance limits to nearby zones, so an announced feature
-- counts as found from the event alone, and a scan later fills in its bounds and used form. A server tick
-- with nothing new completes the announcement and ends the search. Later events at those tiles are changes (a
-- barrier cut, a key taken). Nodes are announced as their MultiLoc (`addedAs`).
local announced = {}      -- packed coordinate -> entry of the feature announced there, as in `locationsFound`
local announcedInBurst = 0 -- features announced in the first burst
local announcedSinceTick = 0
local announcementsEnded = false
local searchEnded = false -- the search has shown as done once this entry; it does not come back
local announcingTicksLeft = 0 -- server ticks to wait for the burst; set only on a region's creation

-- NPCEntityAdded can give an entity with no uid or no tile yet, so it is retried next server tick and left to the
-- scans if it still lacks either (seen in game: an entity with neither, 2026-11-15).
local npcsWaiting = {} -- [n] = an NPC entity given with no uid or no tile

-- Counts a hostile monster: an attackable NPC that is neither a familiar nor one of the forest's own NPCs (the
-- traitor is attackable but is a task). Each entity counts once, by uid.
local function noteMonster(npcEntity)
    local npcConfig = npcEntity.config
    if npcConfig.attackOpIndex < 0 or npcConfig.isFamiliar then return end
    if npcEntity.uid == nil then
        npcsWaiting[#npcsWaiting + 1] = npcEntity
        return
    end
    if monstersSeen[npcEntity.uid] then return end
    monstersSeen[npcEntity.uid] = true
    Forest.monstersSpawned = Forest.monstersSpawned + 1
    if Forest.onMonstersChanged then Forest.onMonstersChanged() end
end

local function noteNpc(npcEntity)
    local feature = featureOfNpcID[npcEntity.configID]
    if feature == nil then return noteMonster(npcEntity) end
    local coord = npcEntity.coordGrid
    if coord == nil then
        npcsWaiting[#npcsWaiting + 1] = npcEntity
        return
    end
    -- An NPC back in view is a new entity, so one near a known NPC of its kind is taken to be the same one. Its
    -- marker stays where it was seen until it drifts far (followNpcs). The world highlight follows the live entity
    -- (highlights.lua). A forest has at most one of each NPC listed (the lightning, the lost goebie, the Traitor), so
    -- one seen far from its marker has moved while out of view: the marker moves to it rather than a second one being
    -- added.
    for _, known in ipairs(npcsFound) do
        if known.feature == feature then
            if math.abs(known.x - coord.x) > SAME_NPC_DISTANCE or math.abs(known.z - coord.z) > SAME_NPC_DISTANCE then
                known.x, known.z = coord.x + 0.5, coord.z + 0.5
                if Forest.onNpcMoved then Forest.onNpcMoved(known) end
            end
            return
        end
    end
    npcsFound[#npcsFound + 1] = {
        feature = feature, x = coord.x + 0.5, z = coord.z + 0.5, width = 1, length = 1, isNpc = true,
        npcID = npcEntity.configID, -- to find the live entity for the highlight
    }
    foundChanged = true
end

-- Returns a found location's entry: its centre in tiles, its size and shape as placed (width and length turned
-- with it), whether it is a node's used form, and the box round its model (src/game/model_bounds.lua).
local function locationEntry(feature, locID, coord, rotation, width, length, shapeType)
    return {
        feature = feature, x = coord.x + width / 2, z = coord.z + length / 2, width = width, length = length,
        shapeType = shapeType, isUsedForm = usedLocIDs[locID] == true,
        bounds = ModelBounds.of(locID, rotation, width, length),
    }
end

-- Reads the standing heights of zones not read yet, and returns whether any zone was read.
-- A zone reads as nothing standing until the client loads its models, which for a far zone waits until the player
-- comes nearer, so it is retried as the player moves. A zone whose template has nothing standing (open ground) is
-- never read, as it cannot tell its turn: each read is 128 height calls.
local function readStanding()
    local level = Player.GetEntity().coordGrid.level
    local anyRead = false
    for _, zone in ipairs(Forest.zones) do
        local zoneKey = zone.x .. "," .. zone.z
        if Forest.standingByZone[zoneKey] == nil and ForestGrid.hasStanding(zone.sourceX .. "_" .. zone.sourceZ) then
            Forest.standingByZone[zoneKey] = StandingHeights.read(level, zone.x, zone.z)
            anyRead = anyRead or Forest.standingByZone[zoneKey] ~= nil
        end
    end
    return anyRead
end

-- Notes every NPC the client holds: the forest's own, and monsters to count.
local function scanNpcs()
    for _, npcEntity in ipairs(NPCList.All()) do noteNpc(npcEntity) end
end

-- Scans every location the client holds. Asking the game for a config's locations, minus hidden ones, finds only
-- those within about 45 tiles, though the client holds the whole forest's from the entrance; so this reads the
-- full list and counts hidden ones.
-- Locations arrive over the first server ticks, so scans continue until nothing new turns up for a while.
local function scan()
    -- only a find or a change to one restarts the settling, not a claim or follower noted earlier
    local changedBefore = foundChanged
    foundChanged = false
    for _, location in ipairs(LocList.All()) do
        local feature = featureOfLocID[location.configID]
        if feature ~= nil then
            local coord = location.coordGrid
            local packedCoord = coord:ToPacked()
            local known = locationsFound[packedCoord]
            local isUsedForm = usedLocIDs[location.configID] == true
            if known == nil or known.feature ~= feature or known.isUsedForm ~= isUsedForm then
                local entry = locationEntry(feature, location.configID, coord, location.rotationType, location.width,
                    location.length, location.shapeType)
                -- first seen: fill in its announced entry, so plans and routes keep the same object
                local announcedEntry = announced[packedCoord]
                if known == nil and announcedEntry ~= nil and announcedEntry.feature == feature then
                    for field, value in pairs(entry) do announcedEntry[field] = value end
                    entry = announcedEntry
                end
                locationsFound[packedCoord] = entry
                foundChanged = true
            end
        end
    end
    if readStanding() then gridStale = true end
    scanNpcs()
    if foundChanged then settlingTicksLeft = SETTLING_TICKS end
    foundChanged = foundChanged or changedBefore
end

-- Returns every location found: those scanned, plus those announced but not yet loaded by the client.
local function locationEntries()
    local entries = {}
    for _, entry in pairs(locationsFound) do entries[#entries + 1] = entry end
    for packedCoord, entry in pairs(announced) do
        if locationsFound[packedCoord] == nil then entries[#entries + 1] = entry end
    end
    return entries
end

-- Builds the forest's grid, keeping the last one built if the new one is the same, so routes and plan searches
-- cached on it stay valid.
-- Forest.grid stays nil until a grid is settled (every zone whose turn matters turned by its heights) or
-- GRID_WAIT_TICKS have passed since entering, so the map's zones, the routes and the plans are not worked out on
-- the unturned zones of the first ticks, while the zones load.
local GRID_WAIT_TICKS = 6 -- about four seconds; at Medium draw distance a forest's zones load within three ticks
local builtGrid = nil -- the last grid built, held back from Forest.grid until settled or due
local gridDueTick = 0 -- the server tick from which an unsettled grid is used
local function buildGrid()
    gridStale = false
    local grid = ForestGrid.build(Forest.zones, Forest.bounds, Forest.standingByZone)
    if ForestGrid.same(builtGrid, grid) then return end
    builtGrid, Forest.zoneTurns = grid, grid.turns
    if grid.settled or Forest.ticks >= gridDueTick then Forest.grid = grid end
    -- every zone's heights are in, so the draw distance raised to load them can come down
    if grid.settled then DrawDistance.restore() end
end

local function publish()
    foundChanged = false
    local found, countOf = locationEntries(), {}
    for _, entry in ipairs(npcsFound) do found[#found + 1] = entry end
    -- Nodes over tools; within a layer, southern over northern.
    table.sort(found, function(first, second)
        if first.feature.layer ~= second.feature.layer then return first.feature.layer < second.feature.layer end
        if first.z ~= second.z then return first.z > second.z end
        return first.x < second.x
    end)
    for _, entry in ipairs(found) do
        countOf[entry.feature.key] = (countOf[entry.feature.key] or 0) + 1
        -- used if its form or its variable says so: the variable is surer, the form may lag
        if entry.feature.kind == "node" then
            entry.isUsed = entry.isUsedForm or claimedNow[entry.feature.key] == true
        end
    end
    for _, toolPair in ipairs(ForestFeatures.tools) do
        local barrierKey = toolPair.barrier.key
        if (Forest.countOf[barrierKey] or 0) > 0 and countOf[barrierKey] == nil then
            Forest.doorsGone[barrierKey] = true
        end
    end
    Forest.found, Forest.countOf = found, countOf
    -- The grid is rebuilt with its changed inputs, and with any zones' heights read since.
    if gridStale then
        readStanding()
        buildGrid()
    end
    if Forest.onChanged then Forest.onChanged() end
end

-- Returns the region's copied zones, their bounds and its openings, or nil until the region can be read.
-- A zone nothing was copied into has a source level below 0.
local function readRegion()
    local squares = World.GetMapSquareBounds()
    local firstZoneX = math.floor(squares.x) * ZONES_PER_MAP_SQUARE
    local firstZoneZ = math.floor(squares.y) * ZONES_PER_MAP_SQUARE
    local zonesWide = math.floor(squares.width) * ZONES_PER_MAP_SQUARE
    local zonesLong = math.floor(squares.height) * ZONES_PER_MAP_SQUARE
    local level = Player.GetEntity().coordGrid.level
    local zones = {}
    local minX, minZ, maxX, maxZ = nil, nil, nil, nil
    for zoneX = firstZoneX, firstZoneX + zonesWide - 1 do
        for zoneZ = firstZoneZ, firstZoneZ + zonesLong - 1 do
            local source = World.GetRegionSourceForCoordGrid(CoordGrid.new(level,
                zoneX // ZONES_PER_MAP_SQUARE, zoneZ // ZONES_PER_MAP_SQUARE,
                zoneX % ZONES_PER_MAP_SQUARE * ZONE_SIZE, zoneZ % ZONES_PER_MAP_SQUARE * ZONE_SIZE))
            if source ~= nil and source.level >= 0 then
                local x, z = zoneX * ZONE_SIZE, zoneZ * ZONE_SIZE
                zones[#zones + 1] = { x = x, z = z, sourceX = source.x, sourceZ = source.z }
                minX, maxX = math.min(minX or x, x), math.max(maxX or x, x)
                minZ, maxZ = math.min(minZ or z, z), math.max(maxZ or z, z)
            end
        end
    end
    if #zones == 0 then return nil end
    -- an opening's mouth: the middle of its zone's side on the forest's edge, or the zone's middle if on no edge
    local openings = {}
    for _, zone in ipairs(zones) do
        if zone.sourceX == OPENING_SOURCE_X and zone.sourceZ == OPENING_SOURCE_Z then
            local half, last = ZONE_SIZE // 2, ZONE_SIZE - 1
            local mouth = { x = zone.x + half, z = zone.z + half }
            if zone.z == maxZ then mouth.z = zone.z + last
            elseif zone.z == minZ then mouth.z = zone.z
            elseif zone.x == maxX then mouth.x = zone.x + last
            elseif zone.x == minX then mouth.x = zone.x end
            openings[#openings + 1] = mouth
        end
    end
    return {
        zones = zones,
        bounds = { minX = minX, minZ = minZ, width = maxX - minX + ZONE_SIZE, length = maxZ - minZ + ZONE_SIZE },
        openings = openings,
    }
end

-- Returns whether the player's zone is copied from the forest's template square, or nil while its source cannot be
-- read yet (the zone not loaded, or the player not yet moved into the region).
-- Every zone of a forest is copied from the template square, so the player's own zone tells the forest from another
-- region with one lookup.
local function playerZoneIsForest()
    local source = World.GetRegionSourceForCoordGrid(Player.GetEntity().coordGrid)
    if source == nil or source.level < 0 then return nil end
    return source.x // MAP_SQUARE_SIZE == TEMPLATE_SQUARE_X and source.z // MAP_SQUARE_SIZE == TEMPLATE_SQUARE_Z
end

local function followPlayer()
    -- the player is briefly unavailable while the world changes
    if not Player.IsAvailable() then return end
    local coord = Player.GetEntity().coordGrid
    local x, z = coord.x, coord.z
    local bounds, last = Forest.bounds, Forest.playerTile
    if x < bounds.minX or z < bounds.minZ or x >= bounds.minX + bounds.width or z >= bounds.minZ + bounds.length then
        return
    end
    if last ~= nil and last.x == x and last.z == z then return end
    Forest.playerTile = { x = x, z = z }
    if Forest.entryTile == nil then Forest.entryTile = Forest.playerTile end
    -- on each new zone: the zones' heights not read yet are tried again, and NPCs nearer looked for
    if last == nil or last.x // ZONE_SIZE ~= x // ZONE_SIZE or last.z // ZONE_SIZE ~= z // ZONE_SIZE then
        zoneScanTicksLeft = ZONE_SCAN_TICKS
        if readStanding() then
            buildGrid()
            if Forest.onChanged then Forest.onChanged() end
        end
    end
    if Forest.onMoved then Forest.onMoved() end
end

-- The template caches (forest_grid.lua) outlive a forest, as every forest reuses them, but five minutes after
-- leaving the player is unlikely to enter another soon, so they go then and the next entry makes them again.
-- The client has no clock, so the time is counted in server ticks, listened to only while the countdown runs;
-- entering again stops it. The lobby, where no ticks come, drops them at once.
local EXPIRY_SUBSCRIPTION = "nemi_mapper_forest_expiry"
local EXPIRY_TICKS = 500 -- about five minutes
local expiryTicksLeft = 0
local function stopExpiry()
    if expiryTicksLeft <= 0 then return end
    expiryTicksLeft = 0
    Event.ServerLogic.Unsubscribe(EXPIRY_SUBSCRIPTION)
end
local function onExpiryTick()
    expiryTicksLeft = expiryTicksLeft - 1
    if expiryTicksLeft > 0 then return end
    Event.ServerLogic.Unsubscribe(EXPIRY_SUBSCRIPTION)
    ForestGrid.forgetTemplates()
end
local function expireTemplatesLater()
    if expiryTicksLeft <= 0 then Event.ServerLogic.Subscribe(EXPIRY_SUBSCRIPTION, onExpiryTick) end
    expiryTicksLeft = EXPIRY_TICKS
end

-- Drops everything of a forest: on leaving, as the instance is gone once the player leaves, and on entering the
-- next. The grid goes with the searches cached on it (routes.lua, solve_plan.lua).
local function forgetForest()
    Forest.zones, Forest.bounds, Forest.openings = {}, nil, {}
    Forest.found, Forest.countOf, Forest.doorsGone, Forest.following = {}, {}, {}, {}
    Forest.followingVersion = Forest.followingVersion + 1
    Forest.keysHeldBefore, Forest.keysUsedAt = {}, {}
    Forest.standingByZone = {}
    Forest.grid, builtGrid, Forest.zoneTurns = nil, nil, nil -- built by the publish after the first scan on entering
    Forest.playerTile, Forest.entryTile = nil, nil
    Forest.monstersSpawned = 0
    locationsFound, npcsFound, monstersSeen, taskItemsHeld, itemsHeldNow = {}, {}, {}, {}, nil
    npcsWaiting, searchEnded = {}, false
end

local function stopWatching()
    Event.ServerLogic.Unsubscribe(SUBSCRIPTION)
    Event.VarTransmit.Unsubscribe(SUBSCRIPTION)
    Event.LocAdded.Unsubscribe(SUBSCRIPTION)
    Event.LocRemoved.Unsubscribe(SUBSCRIPTION)
    Event.NPCEntityAdded.Unsubscribe(SUBSCRIPTION)
    Event.InventoryUpdated.Unsubscribe(SUBSCRIPTION)
    announced = {}
    DrawDistance.restore()
    if Forest.isInside then
        Forest.isInside, Forest.isSearching = false, false
        forgetForest()
        if Forest.onLeft then Forest.onLeft() end
        expireTemplatesLater()
    end
end

-- Drops what was announced or found on a tile with the given shape: the location is gone, or another has replaced
-- it, like a door's remains (DOOR*_OPEN, _CUT, _ONFIRE) or the statues removed. The events alone tell, so nothing is
-- scanned again.
local function dropAt(packedCoord, shapeType)
    local announcedEntry, known = announced[packedCoord], locationsFound[packedCoord]
    if announcedEntry ~= nil and announcedEntry.shapeType == shapeType then
        announced[packedCoord] = nil
        foundChanged = true
    end
    if known ~= nil and known.shapeType == shapeType then
        locationsFound[packedCoord] = nil
        foundChanged = true
    end
end

-- Notes a feature added, which counts as found from the event alone (see `announced`); a location found there
-- takes its form, staying the same object. Any other location added replaces one of the same shape on its tile.
-- During the first burst, features count toward the announcement.
local function onLocationAdded(event)
    local config, coord = event.config, event.coordGrid
    local packedCoord = coord:ToPacked()
    local feature = featureOfLocID[config.id] or featureAddedAs[config.id]
    if feature == nil then return dropAt(packedCoord, event.shapeType) end
    local width, length = config.width, config.length
    -- a config's size is unrotated; a quarter turn swaps it
    if event.rotationType % 2 == 1 then width, length = length, width end
    local entry = locationEntry(feature, config.id, coord, event.rotationType, width, length, event.shapeType)
    announced[packedCoord] = entry
    local known = locationsFound[packedCoord]
    if known ~= nil then
        for field, value in pairs(entry) do known[field] = value end
    end
    foundChanged = true
    if announcingTicksLeft > 0 and not announcementsEnded then
        announcedInBurst, announcedSinceTick = announcedInBurst + 1, announcedSinceTick + 1
    end
end

local function onLocationRemoved(event)
    dropAt(event.coordGrid:ToPacked(), event.shapeType)
end

local function enter(region)
    stopExpiry()
    forgetForest()
    Forest.isInside = true
    gridDueTick = Forest.ticks + GRID_WAIT_TICKS
    Forest.zones, Forest.bounds, Forest.openings = region.zones, region.bounds, region.openings
    foundChanged, gridStale, settlingTicksLeft = true, true, SETTLING_TICKS
    Event.NPCEntityAdded.Subscribe(SUBSCRIPTION, function(event) noteNpc(event.npcEntity) end)
    -- Every inventory the server sends fires this (each item gathered at a node, the bank, the coin pouch), but
    -- only the backpack and worn items hold tools and task items.
    Event.InventoryUpdated.Subscribe(SUBSCRIPTION, function(event)
        if not isHeldInventory[event.inv.id] then return end
        itemsHeldNow = nil
        if Forest.playerTile ~= nil and Forest.onInventoryChanged then Forest.onInventoryChanged() end
        -- a task's item gained or lost: publish next tick, for the legend and highlights
        for task in pairs(doneItemOf) do
            local holds = holdsDoneItem(task)
            if holds ~= (taskItemsHeld[task] == true) then
                taskItemsHeld[task] = holds
                foundChanged = true
            end
        end
    end)
    for task in pairs(doneItemOf) do taskItemsHeld[task] = holdsDoneItem(task) end
    -- a node claimed: the server sends the variable, and the node is republished as used
    readClaimed()
    Event.VarTransmit.Subscribe(SUBSCRIPTION, function(event)
        if claimedBaseID ~= nil and event.var.id == claimedBaseID then
            readClaimed()
            foundChanged = true
        end
        -- a task taken or finished in the forest
        if event.var.id == currentQuestBaseID then foundChanged = true end
    end)
    -- The draw distance goes up to High until the grid settles (draw_distance.lua). Only from Low does the server then
    -- send more (the far map squares, a tick later): that is waited for as a second announcement, and quiet ticks end
    -- the search if none comes. From Medium the server has sent the whole forest already, so nothing is waited for.
    if DrawDistance.raise() then
        announcedInBurst, announcedSinceTick, announcementsEnded = 0, 0, false
        announcingTicksLeft = ANNOUNCING_TICKS
    end
    if Forest.onEntered then Forest.onEntered() end
end

-- Retries the NPCs given with no uid or no tile, a server tick later, if they have both now.
local function noteWaitingNpcs()
    if #npcsWaiting == 0 then return end
    local waiting = npcsWaiting
    npcsWaiting = {}
    for _, npcEntity in ipairs(waiting) do
        if npcEntity.uid ~= nil and npcEntity.coordGrid ~= nil then noteNpc(npcEntity) end
    end
end

-- A found NPC that drifts from its marker (the lightning wanders) has the marker moved to it, so its route ends at
-- it. Checked once a server tick, moved at most every NPC_MOVE_TICKS. This is not a change to what was found, as
-- the map only moves the marker, redraws its route to the NPC and notes a tool now held.
local npcMoveTicksLeft = 0
local function followNpcs()
    npcMoveTicksLeft = npcMoveTicksLeft - 1
    if npcMoveTicksLeft > 0 then return end
    for _, entry in ipairs(npcsFound) do
        for _, npcEntity in ipairs(NPCList.ByConfigID(entry.npcID)) do
            local coord = npcEntity.coordGrid
            local offX, offZ = math.abs(coord.x + 0.5 - entry.x), math.abs(coord.z + 0.5 - entry.z)
            if npcEntity.isValid and offX <= SAME_NPC_DISTANCE and offZ <= SAME_NPC_DISTANCE
                and (offX > NPC_DRIFTED or offZ > NPC_DRIFTED) then
                entry.x, entry.z = coord.x + 0.5, coord.z + 0.5
                npcMoveTicksLeft = NPC_MOVE_TICKS
                if Forest.onNpcMoved then Forest.onNpcMoved(entry) end
            end
        end
    end
end

-- Runs once per server tick while a region is watched: waits until the region is recognised as the forest, then
-- scans until the search settles, and follows the player.
local function onServerTick()
    Forest.ticks = Forest.ticks + 1
    -- a tick with nothing new announced, after some was, completes the announcement
    if not announcementsEnded and announcedInBurst > 0 and announcedSinceTick == 0 then
        announcementsEnded = true
    end
    announcedSinceTick = 0
    announcingTicksLeft = announcingTicksLeft - 1
    if not Forest.isInside then
        local isForest = nil
        if World.IsAvailable() and Player.IsAvailable() then isForest = playerZoneIsForest() end
        if not isForest then
            arrivalTicksLeft = arrivalTicksLeft - 1
            if isForest == false or arrivalTicksLeft <= 0 then stopWatching() end
            return
        end
        enter(readRegion())
    end
    -- Everything is scanned while the forest settles; after that a new zone is looked over for NPCs only, as the
    -- locations' changes come as events.
    if settlingTicksLeft > 0 then
        settlingTicksLeft = settlingTicksLeft - 1
        scan()
    elseif zoneScanTicksLeft > 0 then
        zoneScanTicksLeft = zoneScanTicksLeft - 1
        scanNpcs()
    end
    local wasSearching = Forest.isSearching
    -- Done once the announcement is complete; otherwise after a few quiet ticks since the last find.
    -- A find after that (a door opening, when the plugin loaded inside the forest) does not start it again.
    Forest.isSearching = not announcementsEnded and not searchEnded
        and settlingTicksLeft > SETTLING_TICKS - SHOWN_SETTLED_AFTER
    -- the search ending is a change too: the windows show whether it is still going
    if wasSearching and not Forest.isSearching then foundChanged, searchEnded = true, true end
    readDialogue()
    noteWaitingNpcs()
    followNpcs()
    -- An unsettled grid held back is used once due, as a zone may never load (a draw distance below Medium).
    if Forest.grid == nil and builtGrid ~= nil and Forest.ticks >= gridDueTick then
        Forest.grid, foundChanged = builtGrid, true
    end
    if foundChanged then publish() end
    followPlayer()
end

-- Listens for added locations from the region's creation, since the server announces the forest's contents
-- before the region can be read.
-- isNew is false when the plugin loaded inside the region, after its announcement.
local function watchRegion(isNew)
    arrivalTicksLeft = ARRIVAL_TICKS
    announced, announcedInBurst, announcedSinceTick, announcementsEnded = {}, 0, 0, false
    announcingTicksLeft = isNew and ANNOUNCING_TICKS or 0
    Event.ServerLogic.Subscribe(SUBSCRIPTION, onServerTick)
    Event.LocAdded.Subscribe(SUBSCRIPTION, onLocationAdded)
    Event.LocRemoved.Subscribe(SUBSCRIPTION, onLocationRemoved)
end

-- Returns the active Trinks' tasks that are NPCs and not yet seen, as NPCs only reach the client near the player.
function Forest.tasksUnseen()
    local unseen = {}
    for _, task in ipairs(ForestFeatures.trinksTasks) do
        if task.npcs ~= nil and (Forest.countOf[task.key] or 0) == 0 and Forest.isTaskActive(task) then
            unseen[#unseen + 1] = task
        end
    end
    return unseen
end

-- Returns the puzzles whose barrier is found but not its key, as NPC keys (the lightning, the lost goebie) only reach
-- the client near the player.
function Forest.keysUnseen()
    local unseen = {}
    for _, toolPair in ipairs(ForestFeatures.tools) do
        if (Forest.countOf[toolPair.barrier.key] or 0) > 0 and (Forest.countOf[toolPair.source.key] or 0) == 0
            and not Forest.doorsGone[toolPair.barrier.key] then
            unseen[#unseen + 1] = toolPair
        end
    end
    return unseen
end

-- Returns whether any found barrier still stands.
function Forest.barriersLeft()
    for _, toolPair in ipairs(ForestFeatures.tools) do
        if (Forest.countOf[toolPair.barrier.key] or 0) > 0 then return true end
    end
    return false
end

-- The nodes the rotation (ForestFeatures.nodeRotation) says were missed: for each pair of found nodes adjacent in
-- reading order (zone rows south to north, each west to east), the features of the kinds skipped between them.
-- A node missed before the first or after the last cannot be detected.
local rotationIndexOf, rotationFeatures = {}, {}
for index, key in ipairs(ForestFeatures.nodeRotation) do
    rotationIndexOf[key] = index - 1
    for _, node in ipairs(ForestFeatures.nodes) do
        if node.key == key then rotationFeatures[index] = node end
    end
end
function Forest.nodesMissedByRotation()
    local nodes = {}
    for _, entry in ipairs(Forest.found) do
        if entry.feature.kind == "node" then
            nodes[#nodes + 1] = {
                feature = entry.feature, x = Forest.southWestOf(entry), z = select(2, Forest.southWestOf(entry)),
            }
        end
    end
    table.sort(nodes, function(first, second)
        local firstRow, secondRow = first.z // ZONE_SIZE, second.z // ZONE_SIZE
        if firstRow ~= secondRow then return firstRow < secondRow end
        if first.x ~= second.x then return first.x < second.x end
        return first.z < second.z
    end)
    local kinds, missed = #rotationFeatures, {}
    for position = 2, #nodes do
        local from = rotationIndexOf[nodes[position - 1].feature.key]
        local step = (rotationIndexOf[nodes[position].feature.key] - from) % kinds
        -- the same kind twice in a row is a full lap apart
        if step == 0 then step = kinds end
        for skipped = 1, step - 1 do missed[#missed + 1] = rotationFeatures[(from + skipped) % kinds + 1] end
    end
    return missed
end

-- Returns the scout window's counts: node kinds found, plus kinds the rotation says were missed and none was found
-- of (once the search settles); total nodes found; the missed nodes' features in rotation order; and the kinds
-- counted as missed (key -> true).
function Forest.scoutCounts()
    local kinds, total = Forest.nodeCounts()
    local missed, missedKinds = Forest.isSearching and {} or Forest.nodesMissedByRotation(), {}
    for _, feature in ipairs(missed) do
        if (Forest.countOf[feature.key] or 0) == 0 and not missedKinds[feature.key] then
            missedKinds[feature.key] = true
            kinds = kinds + 1
        end
    end
    return kinds, total, missed, missedKinds
end

-- Returns how many of the nine node kinds the forest has, and how many nodes in total (a kind can appear twice).
function Forest.nodeCounts()
    local kinds, total = 0, 0
    for _, node in ipairs(ForestFeatures.nodes) do
        local count = Forest.countOf[node.key] or 0
        total = total + count
        if count > 0 then kinds = kinds + 1 end
    end
    return kinds, total
end

function Forest.start()
    Event.RegionCreated.Subscribe(SUBSCRIPTION, function()
        stopWatching()
        watchRegion(true)
    end)
    Event.WorldCreated.Subscribe(SUBSCRIPTION, stopWatching)
    -- the plugin may load with the player already in the forest
    if World.IsAvailable() and World.IsRegion() then watchRegion(false) end
end

-- Called on leaving the game and at shutdown: nothing is listened for, and the template caches go at once.
function Forest.stop()
    Event.RegionCreated.Unsubscribe(SUBSCRIPTION)
    Event.WorldCreated.Unsubscribe(SUBSCRIPTION)
    stopWatching()
    stopExpiry()
    ForestGrid.forgetTemplates()
end

return Forest

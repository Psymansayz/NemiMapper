-- The Nemi Forest the player is in: its zones, bounds, walkable tiles, what is in it, and where the player is.

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
local OPENING_SOURCE_X, OPENING_SOURCE_Z = 4200, 664
local ARRIVAL_TICKS = 10 -- server ticks for a new region's zones to become readable
-- Server ticks after a region's creation during which added locations count as the server's announcement (it
-- arrives on ticks 0-2). Later additions are changes.
local ANNOUNCING_TICKS = 4
local SETTLING_TICKS = 8 -- server ticks to keep scanning after the last find or change
-- Server ticks after the last find before the search shows as done, when the announcement was missed (the plugin
-- loaded inside the forest). Finds arrive over the first 2-4 ticks, never more than 2 apart.
-- Scans still run for SETTLING_TICKS, so a late find still shows.
local SHOWN_SETTLED_AFTER = 4
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
Forest.found = {}       -- [n] = { feature, x, z, width, length', isUsed }: centre in tiles, size, and for a node
                        -- whether it was used today; drawn in this order
Forest.countOf = {}     -- feature key -> how many were found
Forest.doorsGone = {}   -- barrier key -> true once a found barrier is gone (its puzzle is done)
Forest.monstersSpawned = 0 -- hostile monsters spawned in this forest, each entity counted once
Forest.following = {}   -- source key -> true while that NPC tool follows the player; kept until leaving the forest
-- source key -> the name of the player that NPC tool follows, as its refusal gave it (lower case); the plans leave it
-- out (forest_stops.lua) until that player leaves, it follows this player, or the forest is left
Forest.keysTaken = {}
Forest.ticks = 0         -- server ticks counted while a region is watched
Forest.npcArrivals = 0   -- counts the server ticks on which arrived NPCs were looked for (highlights.lua)
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
local refusals = {} -- pattern of a game message, capturing a player's name -> source key of the NPC following them
for _, toolPair in ipairs(ForestFeatures.tools) do
    for _, message in ipairs(toolPair.followMessages or {}) do followMessages[message] = toolPair.source.key end
    for _, message in ipairs(toolPair.refusals or {}) do refusals[message] = toolPair.source.key end
end

-- Each node's VarBit for XP claimed today, and the base variable they belong to
local claimedVariableOf, claimedBaseID = {}, nil
for _, node in ipairs(ForestFeatures.nodes) do
    local variable = GameIds.playerVariable(node.claimed)
    claimedVariableOf[node.key] = variable
    if variable ~= nil and variable.baseVar ~= nil then claimedBaseID = variable.baseVar.id end
end

-- Lists a feature under its game ids, with its kind ("node", "task", "source" or "barrier") and drawn layer on the map.
local function list(feature, kind, layer)
    feature.kind, feature.layer = kind, layer
    feature.isPuzzle = kind == "source" or kind == "barrier"
    for _, name in ipairs(feature.locations or {}) do
        local locID = GameIds.resolve("Loc", name)
        if locID ~= nil then featureOfLocID[locID] = feature end
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

-- What the forest has shown so far. Features stay known out of sight; only a change at their tile removes them.
local locationsFound = {} -- packed coordinate -> { feature, x, z }
local npcsFound = {}      -- [n] = { feature, x, z }: where each one's marker is
local monstersSeen = {}   -- entity uid -> true, so a monster back in view is not a new spawn
local foundChanged = false
-- The grid's inputs (the zones' standing heights) changed since it was built.
local gridStale = false
local arrivalTicksLeft = 0
local settlingTicksLeft = 0
-- NPCEntityAdded arrives a tick early, so this signals to check the NPC list on the next server tick.
local npcsArrived = false

-- Nodes whose XP was claimed today: read on entering the forest, whenever the server sends their base variable,
-- and for the ribbon page's count.
local claimedNow = {} -- node key -> true
local taskItemsHeld = {} -- task -> true while its doneItem is held, as last checked
-- The player's current Trinks' task and its base variable, which is what the server sends.
local currentQuest = GameIds.playerVariable("RAID1_GOEBIE_CURRENT_QUEST")
local currentQuestBaseID = currentQuest ~= nil and currentQuest.baseVar ~= nil and currentQuest.baseVar.id or nil

local function readClaimed()
    claimedNow = {}
    for key, variable in pairs(claimedVariableOf) do
        if variable.value ~= 0 then claimedNow[key] = true end
    end
end

-- Each task's current-quest value  from the game's enum.
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

-- Each task's VarBit marking its target's part done, and the item it gives, if any.
local doneVariableOf, doneItemOf = {}, {}
for _, task in ipairs(ForestFeatures.trinksTasks) do
    if task.doneVar ~= nil then doneVariableOf[task] = GameIds.playerVariable(task.doneVar) end
    if task.doneItem ~= nil then doneItemOf[task] = GameIds.resolve("Obj", task.doneItem) end
end

-- Items in the backpack and worn equipment: item id -> true.
-- Inside the forest updated whenever the inventory changes, 
-- Outside the forest only when the current Trinks tasks needs it and the ribbon window is open.
local HELD_INVENTORY_IDS = { config.Inv.INV.id, GameIds.resolve("Inv", "WORN") }
local isHeldInventory = {}
for _, inventoryID in ipairs(HELD_INVENTORY_IDS) do isHeldInventory[inventoryID] = true end
local itemsHeldNow = nil
function Forest.itemsHeld()
    if itemsHeldNow ~= nil and Forest.isInside then return itemsHeldNow end
    local items = {}
    for _, inventoryID in ipairs(HELD_INVENTORY_IDS) do
        for _, slot in ipairs(Inventory.Find(inventoryID):GetSlots()) do
            -- an empty slot holds object id -1
            if slot.obj ~= nil and slot.obj.id >= 0 then items[slot.obj.id] = true end
        end
    end
    if Forest.isInside then itemsHeldNow = items end
    return items
end

local function holdsDoneItem(task)
    local itemID = doneItemOf[task]
    return itemID ~= nil and Forest.itemsHeld()[itemID] == true
end

-- Returns a task's value in RAID1_GOEBIE_CURRENT_QUEST.
function Forest.questOf(task)
    return questOf[task]
end

-- Returns the tile of a found feature's south-west corner, from its centre and size.
function Forest.southWestOf(entry)
    return math.floor(entry.x - entry.width / 2), math.floor(entry.z - entry.length / 2)
end

-- Returns whether the player is on a Trinks' task.
function Forest.isOnTask(task)
    return currentQuest ~= nil and questOf[task] ~= nil and currentQuest.value == questOf[task]
end

-- Returns whether the player needs a Trinks' task's target now: on that task, with that part not done yet.
function Forest.isTaskActive(task)
    if not Forest.isOnTask(task) or holdsDoneItem(task) then return false end
    local doneVariable = doneVariableOf[task]
    return doneVariable == nil or doneVariable.value == 0
end

-- Reads which nodes the player has claimed today
function Forest.readClaimedToday()
    readClaimed()
    local count = 0
    for _ in pairs(claimedNow) do count = count + 1 end
    return count
end

-- Number of Trinks' tasks done today.
local tasksDoneVariable = GameIds.playerVariable("RAID1_GOEBIE_QUESTS_COMPLETE_TODAY")
local tasksDoneBaseID = tasksDoneVariable ~= nil and tasksDoneVariable.baseVar ~= nil and tasksDoneVariable.baseVar.id
    or nil
function Forest.tasksDoneToday()
    return tasksDoneVariable ~= nil and tasksDoneVariable.value or 0
end

-- The VarBits the game counts a task's parts in, and the items it counts.
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

-- Returns whether the current task counts items carried in the backpack, so a change to it may alter its progress.
function Forest.taskCountsItems()
    if currentQuest == nil then return false end
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

-- Returns the current Trinks' task: its name, its parts as counted
-- and whether it is done and ready to hand in.
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
    -- the items held this tick (Forest.itemsHeld).
    local backpack = Inventory.Find(config.Inv.INV.id)
    for _, forestTask in ipairs(ForestFeatures.trinksTasks) do
        local itemID = doneItemOf[forestTask]
        if questOf[forestTask] == quest and itemID ~= nil then done = backpack:GetTotal(itemID) > 0 end
    end
    return { name = task.name, parts = parts, done = done }
end

-- Returns the base variables the server sends for the claims, the current task and the tasks done.
function Forest.dailyVariableIDs()
    return claimedBaseID, currentQuestBaseID, tasksDoneBaseID
end

function Forest.isNodeClaimed(nodeKey)
    return claimedNow[nodeKey] == true
end

-- A taken NPC tool is free again once the player it follows leaves the forest.
local PLAYERS_SUBSCRIPTION = "nemi_mapper_forest_players"
local playersRemoved = false

-- Returns a player's name removing all formatting.
local function comparableName(name)
    local plain = name:gsub("<br>", " "):gsub("<[^>]*>", ""):gsub("\194\160", " "):gsub("%s+", " ")
    return (plain:match("^%s*(.-)%s*$"):lower())
end

-- Returns whether a player named <holder> is in the client's list.
local function playerListed(holder)
    for _, playerEntity in ipairs(PlayerList.All()) do
        if comparableName(playerEntity.displayName or "") == holder then return true end
    end
    return false
end

local listenToPlayers -- defined below

-- Frees the keys whose holders are no longer listed
-- Not a direct callback as players may only leave the list one tick after the event.
local function freeKeysOfPlayersGone()
    if not playersRemoved then return end
    playersRemoved = false
    for sourceKey, holder in pairs(Forest.keysTaken) do
        if not playerListed(holder) then
            Forest.keysTaken[sourceKey] = nil
            foundChanged = true
        end
    end
    listenToPlayers()
end

local function onPlayerRemoved()
    playersRemoved = true
end

-- Listens for players leaving while a key is taken.
listenToPlayers = function()
    if next(Forest.keysTaken) ~= nil then
        Event.PlayerEntityRemoved.Subscribe(PLAYERS_SUBSCRIPTION, onPlayerRemoved)
    else
        Event.PlayerEntityRemoved.Unsubscribe(PLAYERS_SUBSCRIPTION)
    end
end

local function noteFollowing(sourceKey)
    Forest.following[sourceKey] = true
    Forest.keysTaken[sourceKey] = nil
    listenToPlayers()
    foundChanged = true
end

-- Notes a follower when texts indicate it is following the player or refuses due to following annother player.
local function noteFollowTexts(shownTexts)
    local texts = {}
    for index, text in ipairs(shownTexts) do texts[index] = (text:gsub("<br>", " "):gsub("\194\160", " ")) end
    local refused = {} -- source key -> the name of the player its NPC follows
    for _, text in ipairs(texts) do
        for pattern, sourceKey in pairs(refusals) do
            local holder = text:match(pattern)
            if holder ~= nil then refused[sourceKey] = comparableName(holder) end
        end
    end
    for sourceKey, holder in pairs(refused) do
        if Forest.keysTaken[sourceKey] ~= holder and playerListed(holder) then
            Forest.keysTaken[sourceKey] = holder
            listenToPlayers()
            foundChanged = true
        end
    end
    for _, text in ipairs(texts) do
        for message, sourceKey in pairs(followMessages) do
            if not Forest.following[sourceKey] and text:find(message, 1, true) then noteFollowing(sourceKey) end
        end
    end
end

-- Reads the info box and the dialogue box for follow messages
local function readDialogue()
    for _, sourceKey in pairs(followMessages) do
        if not Forest.following[sourceKey] then return noteFollowTexts(DialogueText.open()) end
    end
end

-- The server's announcement. Every node, key and barrier arrives as a LocAdded event in one burst on the
-- region's first ticks (0-2, sometimes after the forest is entered), before the client loads any of them. Scans
-- only see what the client loads, which a low draw distance limits to nearby zones, so an announced feature
-- counts as found from the event alone, with its saved box (src/game/model_bounds.lua); after a reload, when the
-- announcement has passed, scans find the forest instead. A server tick with nothing new completes the announcement
-- and ends the search. Later events at those tiles are changes (a barrier cut, a key taken). Nodes are announced as
-- their MultiLoc (`addedAs`).
local announced = {}      -- packed coordinate -> entry of the feature announced there, as in `locationsFound`
local announcedInBurst = 0 -- features announced in the first burst
local announcedSinceTick = 0
local announcementsEnded = false
local searchEnded = false -- the search has shown as done once this entry; it does not come back
local announcingTicksLeft = 0 -- server ticks to wait for the burst; set only on a region's creation

-- Counts a hostile monster: an attackable NPC that is neither a familiar nor one of the forest's own NPCs (the
-- traitor is attackable but is a task). Each entity counts once, by uid.
local function noteMonster(npcEntity)
    local npcConfig = npcEntity.config
    if npcConfig.attackOpIndex < 0 or npcConfig.isFamiliar then return end
    if monstersSeen[npcEntity.uid] then return end
    monstersSeen[npcEntity.uid] = true
    Forest.monstersSpawned = Forest.monstersSpawned + 1
    if Forest.onMonstersChanged then Forest.onMonstersChanged() end
end

local function noteNpc(npcEntity)
    local feature = featureOfNpcID[npcEntity.configID]
    if feature == nil then return noteMonster(npcEntity) end
    local coord = npcEntity.coordGrid
    -- An NPC back in view is a new entity, but a forest has at most one of each NPC listed (the lightning, the lost
    -- goebie, the Traitor), so the marker moves to it rather than a second one being added. 
    -- Nearer, its marker follows once it drifts more than NPC_DRIFTED tiles. 
    -- The 3d box highlight follows the live entity exactly.
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
-- with it), and the box around its model (src/game/model_bounds.lua).
local function locationEntry(feature, locID, coord, rotation, width, length, shapeType)
    return {
        feature = feature, x = coord.x + width / 2, z = coord.z + length / 2, width = width, length = length,
        shapeType = shapeType, bounds = ModelBounds.of(locID, rotation, width, length),
    }
end

-- Reads the standing heights of zones not read yet, and returns whether any zone was read.
-- A zone reads as nothing standing until the client loads its models, which for a far zone waits until the player
-- comes nearer, so it is retried as the player moves.
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

-- With the plugin reloaded inside a forest, the server's announcement has passed, so only scans find its nodes, keys
-- and doors. On a fresh entry the announcement gives everything the scans would, so the locations are scanned only 
-- if the events are missed.
local announcementMissed = false
local NO_LOCATIONS = {}

-- Scans every location the client holds, unless the announcement gave them, and reads the zones' standing heights
-- and the NPCs. Asking the game for a config's locations, minus hidden ones, finds only those within about 45 tiles,
-- though the client holds the whole forest's from the entrance; so this reads the full list and counts hidden ones.
-- Locations and heights arrive over the first server ticks, so scans continue until nothing new turns up for a while.
local function scan()
    -- only a find or new change restarts the settling
    local changedBefore = foundChanged
    foundChanged = false
    local scansLocations = announcementMissed or next(announced) == nil
    for _, location in ipairs(scansLocations and LocList.All() or NO_LOCATIONS) do
        local feature = featureOfLocID[location.configID]
        if feature ~= nil then
            local coord = location.coordGrid
            local packedCoord = coord:ToPacked()
            local known = locationsFound[packedCoord]
            if known == nil or known.feature ~= feature then
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
local GRID_WAIT_TICKS = 6 -- about four seconds; at High draw distance (raised on entering) the zones load in 3 ticks
local builtGrid = nil -- the last grid built, held back from Forest.grid until settled or due
-- With the plugin reloaded inside a forest, the server's announcement has passed, so only the scans find its nodes, keys
-- and doors: the draw distance raised on entering stays up until they settle as well as the grid, as the client
-- lets far squares go below Medium. Otherwise it comes down as soon as the grid settles.
local restoreAfterScans = false
local gridDueTick = 0 -- the server tick from which an unsettled grid is used
local function buildGrid()
    gridStale = false
    local grid = ForestGrid.build(Forest.zones, Forest.bounds, Forest.standingByZone)
    if ForestGrid.same(builtGrid, grid) then return end
    builtGrid, Forest.zoneTurns = grid, grid.turns
    if grid.settled or Forest.ticks >= gridDueTick then Forest.grid = grid end
    -- every zone's heights are in, so the draw distance raised to load them can come down
    if Forest.grid == grid and (not restoreAfterScans or settlingTicksLeft == 0) then
        restoreAfterScans = false
        DrawDistance.restore()
    end
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
        -- used once its claim variable says so
        if entry.feature.kind == "node" then entry.isUsed = claimedNow[entry.feature.key] == true end
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

-- Determines if the instance the player entered is a forest by looking at the region source of the player's tile.
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
    -- on each new zone: the zones' heights not read yet are tried again
    if last == nil or last.x // ZONE_SIZE ~= x // ZONE_SIZE or last.z // ZONE_SIZE ~= z // ZONE_SIZE then
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
-- entering again stops it.
local EXPIRY_SUBSCRIPTION = "nemi_mapper_forest_expiry"
local EXPIRY_TICKS = 500 -- five minutes
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

-- Drops everything of a forest on leaving, as the instance is gone once all players leave. The grid goes with the
-- searches cached on it (routes.lua, solve_plan.lua).
local function forgetForest()
    Forest.zones, Forest.bounds, Forest.openings = {}, nil, {}
    Forest.found, Forest.countOf, Forest.doorsGone, Forest.following = {}, {}, {}, {}
    Forest.keysTaken, playersRemoved = {}, false
    Forest.standingByZone = {}
    Forest.grid, builtGrid, Forest.zoneTurns = nil, nil, nil -- built by the publish after the first scan on entering
    Forest.playerTile, Forest.entryTile = nil, nil
    Forest.monstersSpawned = 0
    locationsFound, npcsFound, monstersSeen, taskItemsHeld, itemsHeldNow = {}, {}, {}, {}, nil
    npcsArrived, searchEnded = false, false
end

local function stopWatching()
    Event.ServerLogic.Unsubscribe(SUBSCRIPTION)
    Event.VarTransmit.Unsubscribe(SUBSCRIPTION)
    Event.LocAdded.Unsubscribe(SUBSCRIPTION)
    Event.LocRemoved.Unsubscribe(SUBSCRIPTION)
    Event.NPCEntityAdded.Unsubscribe(SUBSCRIPTION)
    Event.InventoryUpdated.Unsubscribe(SUBSCRIPTION)
    Event.PlayerEntityRemoved.Unsubscribe(PLAYERS_SUBSCRIPTION)
    announced = {}
    DrawDistance.restore()
    if Forest.isInside then
        Forest.isInside, Forest.isSearching = false, false
        forgetForest()
        if Forest.onLeft then Forest.onLeft() end
        expireTemplatesLater()
    end
end

-- Drops doors when annother player opens them.
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

-- Notes a feature added, another location added replaces one of the same shape on its tile.
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
    Forest.isInside = true
    gridDueTick = Forest.ticks + GRID_WAIT_TICKS
    Forest.zones, Forest.bounds, Forest.openings = region.zones, region.bounds, region.openings
    foundChanged, gridStale, settlingTicksLeft = true, true, SETTLING_TICKS
    Event.NPCEntityAdded.Subscribe(SUBSCRIPTION, function() npcsArrived = true end)
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

-- A found NPC that drifts from its marker has the marker moved to it, so its route ends at
-- it. Checked once a server tick, moved at most every NPC_MOVE_TICKS to reduce recalculations.
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
    -- a tick with nothing new announced completes the announcement
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
    -- While the forest settles, the zones' heights and the NPCs are read each tick, and the locations too until
    -- something is announced; after that the locations' changes come as events, and NPCs are looked for when some
    -- arrive.
    if settlingTicksLeft > 0 then
        settlingTicksLeft = settlingTicksLeft - 1
        scan()
        if settlingTicksLeft == 0 and restoreAfterScans and Forest.grid ~= nil then
            restoreAfterScans = false
            DrawDistance.restore()
        end
    elseif npcsArrived then
        scanNpcs()
    end
    if npcsArrived then
        npcsArrived = false
        Forest.npcArrivals = Forest.npcArrivals + 1
    end
    local wasSearching = Forest.isSearching
    Forest.isSearching = not announcementsEnded and not searchEnded
        and settlingTicksLeft > SETTLING_TICKS - SHOWN_SETTLED_AFTER
    -- the search ending is a change too: the windows show whether it is still going
    if wasSearching and not Forest.isSearching then foundChanged, searchEnded = true, true end
    readDialogue()
    freeKeysOfPlayersGone()
    followNpcs()
    -- An unsettled grid held back is used once if the forest doesn't settle after gridDueTick.
    if Forest.grid == nil and builtGrid ~= nil and Forest.ticks >= gridDueTick then
        Forest.grid, foundChanged = builtGrid, true
        if not restoreAfterScans or settlingTicksLeft == 0 then
            restoreAfterScans = false
            DrawDistance.restore()
        end
    end
    -- Heights read by a scan change the grid without a find
    if foundChanged or gridStale then publish() end
    followPlayer()
end

-- Listens for added locations from the region's creation
-- isNew is false when the plugin loaded inside the forest, after its announcement.
local function watchRegion(isNew)
    arrivalTicksLeft = ARRIVAL_TICKS
    restoreAfterScans, announcementMissed = not isNew, not isNew
    announced, announcedInBurst, announcedSinceTick, announcementsEnded = {}, 0, 0, false
    announcingTicksLeft = isNew and ANNOUNCING_TICKS or 0
    Event.ServerLogic.Subscribe(SUBSCRIPTION, onServerTick)
    Event.LocAdded.Subscribe(SUBSCRIPTION, onLocationAdded)
    Event.LocRemoved.Subscribe(SUBSCRIPTION, onLocationRemoved)
end

-- Returns the active Trinks' tasks that are NPCs and not yet seen, as NPCs only load near the player.
function Forest.tasksUnseen()
    local unseen = {}
    for _, task in ipairs(ForestFeatures.trinksTasks) do
        if task.npcs ~= nil and (Forest.countOf[task.key] or 0) == 0 and Forest.isTaskActive(task) then
            unseen[#unseen + 1] = task
        end
    end
    return unseen
end

-- Returns the puzzles whose barrier is found but not its key, as NPC keys only load near the player.
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
            local x, z = Forest.southWestOf(entry)
            nodes[#nodes + 1] = { feature = entry.feature, x = x, z = z }
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

-- Returns how many of the nine node kinds the forest has, and how many nodes in total.
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

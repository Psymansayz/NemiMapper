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

Forest.isInside = false
Forest.isSearching = false -- more may still be found
Forest.bounds = nil     -- { minX, minZ, width, length } in tiles; nil outside a forest
Forest.zones = {}       -- [n] = { x, z, sourceX, sourceZ, templateKey }: south-west tiles of a zone and of the zone
                        -- it copies, and that zone's key in the template data ("x_z")
Forest.grid = nil       -- the forest's walkable tiles (src/game/forest_grid.lua), once its zones' turns are settled
Forest.zoneTurns = nil  -- zone index -> quarter turns, as last worked out, settled or not: for the map's pictures
Forest.openings = {}    -- [n] = { x, z }: the mouth of each opening (entrance, exit)
Forest.standingByZone = {}  -- "x,z" of a zone -> what stands on its tiles (src/game/standing_heights.lua);
                            -- shows which way the zone was turned
Forest.found = {}       -- [n] = an entry (locationEntry, noteNpc), and for a node isUsed: whether it was used
                        -- today; drawn in this order
Forest.countOf = {}     -- feature key -> how many were found
Forest.doorsGone = {}   -- barrier key -> true once a found barrier is gone (its puzzle is done)
Forest.monstersSpawned = 0 -- hostile monsters spawned in this forest, each entity counted once
Forest.following = {}   -- source key -> true while that NPC tool follows the player; kept until leaving the forest
-- source key -> the name of the player that NPC tool follows, as its refusal gave it (lower case); the plans leave it
-- out (forest_stops.lua) until that player leaves, it follows this player, or the forest is left
Forest.keysTaken = {}
Forest.ticks = 0         -- server ticks counted while a region is watched
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
    claimedBaseID = GameIds.baseIDOf(variable) or claimedBaseID
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
local locationsFound = {} -- packed coordinate -> entry (locationEntry), scanned or announced
local npcsFound = {}      -- [n] = entry (noteNpc), at its marker
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
local currentQuestBaseID = GameIds.baseIDOf(currentQuest)

-- Reads which nodes the player has claimed today, and returns how many.
function Forest.readClaimedToday()
    claimedNow = {}
    local count = 0
    for key, variable in pairs(claimedVariableOf) do
        if variable.value ~= 0 then claimedNow[key], count = true, count + 1 end
    end
    return count
end

-- Each task's current-quest value from the game's enum.
local questOf = {}
for _, task in ipairs(ForestFeatures.trinksTasks) do
    -- an unknown struct's name reads as nil
    local struct = config.Struct[task.questStruct]
    local quest = struct and config.Enum.RAID1_GOEBIE_IDS_TO_STRUCTS:GetInputValues(struct)[1]
    if quest ~= nil then
        questOf[task] = quest
    else
        GameIds.noteUnknown("Struct", task.questStruct)
    end
end

-- Each task's VarBit marking its target's part done, and the item it gives, if any.
local doneVariableOf, doneItemOf = {}, {}
local doneItemOfQuest = {} -- a forest task's current-quest value -> the item that shows it done
local doneBaseIDs = {} -- the done variables' base variables, which are what the server sends
for _, task in ipairs(ForestFeatures.trinksTasks) do
    if task.doneVar ~= nil then
        local variable = GameIds.playerVariable(task.doneVar)
        doneVariableOf[task] = variable
        local baseID = GameIds.baseIDOf(variable)
        if baseID ~= nil then doneBaseIDs[baseID] = true end
    end
    if task.doneItem ~= nil then
        doneItemOf[task] = GameIds.resolve("Obj", task.doneItem)
        if questOf[task] ~= nil then doneItemOfQuest[questOf[task]] = doneItemOf[task] end
    end
end

-- Items in the backpack and worn equipment: item id -> true.
-- Inside the forest they are kept until the inventory changes; outside it they are read on each call.
local HELD_INVENTORY_IDS = { config.Inv.INV.id, GameIds.resolve("Inv", "WORN") }
local isHeldInventory = {}
for _, inventoryID in ipairs(HELD_INVENTORY_IDS) do isHeldInventory[inventoryID] = true end
local itemsHeldNow = nil
function Forest.itemsHeld()
    if itemsHeldNow ~= nil then return itemsHeldNow end
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

-- Returns the tile of a found feature's south-west corner, from its centre and size.
function Forest.southWestOf(entry)
    return math.floor(entry.x - entry.width / 2), math.floor(entry.z - entry.length / 2)
end

-- Returns whether the player needs a Trinks' task's target now: on that task, with that part not done yet.
function Forest.isTaskActive(task)
    if currentQuest == nil or questOf[task] == nil or currentQuest.value ~= questOf[task] or holdsDoneItem(task) then
        return false
    end
    local doneVariable = doneVariableOf[task]
    return doneVariable == nil or doneVariable.value == 0
end

-- Number of Trinks' tasks done today.
local tasksDoneVariable = GameIds.playerVariable("RAID1_GOEBIE_QUESTS_COMPLETE_TODAY")
local tasksDoneBaseID = GameIds.baseIDOf(tasksDoneVariable)
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
    return doneItemOfQuest[currentQuest.value] ~= nil
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
    -- a forest task (the Pahtli plant) has no parts and is done once its item is held
    local itemID = doneItemOfQuest[quest]
    if itemID ~= nil then done = Inventory.Find(config.Inv.INV.id):GetTotal(itemID) > 0 end
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

local function onPlayerRemoved()
    playersRemoved = true
end

-- Listens for players leaving while a key is taken.
local function listenToPlayers()
    if next(Forest.keysTaken) ~= nil then
        Event.PlayerEntityRemoved.Subscribe(PLAYERS_SUBSCRIPTION, onPlayerRemoved)
    else
        Event.PlayerEntityRemoved.Unsubscribe(PLAYERS_SUBSCRIPTION)
    end
end

-- Frees the keys whose holders are no longer listed.
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

-- Returns whether an NPC tool was found that does not follow the player while its door stands, so the info box or
-- the dialogue box may say that it now follows, or that it follows another player.
local function npcToolWaiting()
    for _, entry in ipairs(npcsFound) do
        local feature = entry.feature
        if feature.kind == "source" and not Forest.following[feature.key]
            and not Forest.doorsGone[feature.pair.barrier.key] then
            return true
        end
    end
    return false
end

-- Reads the info box and the dialogue box, while an NPC tool waits (npcToolWaiting), for a follow message or a
-- refusal as it follows another player.
local function readDialogue()
    if not npcToolWaiting() then return end
    local texts = {}
    for index, text in ipairs(DialogueText.open()) do texts[index] = (text:gsub("<br>", " "):gsub("\194\160", " ")) end
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
            if not Forest.following[sourceKey] and text:find(message, 1, true) then
                Forest.following[sourceKey], Forest.keysTaken[sourceKey] = true, nil
                listenToPlayers()
                foundChanged = true
            end
        end
    end
end

-- The server's announcement. Every node, key and barrier arrives as a LocAdded event in one burst on the
-- region's first ticks (0-2, sometimes after the forest is entered), before the client loads any of them. Scans
-- only see what the client loads, which a low draw distance limits to nearby zones, so an announced feature
-- counts as found from the event alone, with its saved box (src/game/model_bounds.lua); after a reload, when the
-- announcement has passed, scans find the forest instead. A server tick with nothing new completes the announcement
-- and ends the search. Later events at those tiles are changes (a barrier cut, a key taken). Nodes are announced as
-- their MultiLoc (`addedAs`).
local anyAnnounced = false -- a feature was announced, so the locations are not scanned
local announcedInBurst = false -- a feature was announced in the first burst
local announcedThisTick = false
local announcementsEnded = false
local announcingTicksLeft = 0 -- server ticks to wait for the burst; set only on a region's creation

-- Counts a hostile monster: an attackable NPC that is neither a familiar nor one of the forest's own NPCs (the
-- traitor is attackable but is a task). Each entity counts once, by uid.
local function noteMonster(npcEntity)
    local npcConfig = npcEntity.config
    if npcConfig.attackOpIndex < 0 or npcConfig.isFamiliar then return end
    if monstersSeen[npcEntity.uid] then return end
    monstersSeen[npcEntity.uid] = true
    Forest.monstersSpawned = Forest.monstersSpawned + 1
    Forest.onMonstersChanged()
end

local function noteNpc(npcEntity)
    local feature = featureOfNpcID[npcEntity.configID]
    if feature == nil then return noteMonster(npcEntity) end
    -- An NPC back in view is a new entity, but a forest has at most one of each NPC listed (the lightning, the lost
    -- goebie, the Traitor), so it keeps its marker, which followNpcs moves to it.
    for _, known in ipairs(npcsFound) do
        if known.feature == feature then return end
    end
    local coord = npcEntity.coordGrid
    npcsFound[#npcsFound + 1] = {
        feature = feature, x = coord.x + 0.5, z = coord.z + 0.5, width = 1, length = 1, isNpc = true,
        npcID = npcEntity.configID,
        npcEntity = npcEntity, -- the live entity, kept by followNpcs for the highlight
        bounds = ModelBounds.of(feature, 0, 1, 1),
    }
    foundChanged = true
end

-- Returns a found location's entry: its centre in tiles, its size and shape as placed (width and length turned
-- with it), and the box around its model (src/game/model_bounds.lua).
local function locationEntry(feature, coord, rotation, width, length, shapeType)
    return {
        feature = feature, x = coord.x + width / 2, z = coord.z + length / 2, width = width, length = length,
        shapeType = shapeType, bounds = ModelBounds.of(feature, rotation, width, length),
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
        if Forest.standingByZone[zoneKey] == nil and ForestGrid.hasStanding(zone.templateKey) then
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

-- Scans every location the client holds, unless the announcement gave them, and reads the zones' standing heights
-- and the NPCs. Asking the game for a config's locations, minus hidden ones, finds only those within about 45 tiles,
-- though the client holds the whole forest's from the entrance; so this reads the full list and counts hidden ones.
-- Locations and heights arrive over the first server ticks, so scans continue until nothing new turns up for a while.
local function scan()
    -- only a find or new change restarts the settling
    local changedBefore = foundChanged
    foundChanged = false
    if announcementMissed or not anyAnnounced then
        for _, location in ipairs(LocList.All()) do
            local feature = featureOfLocID[location.configID]
            if feature ~= nil then
                local coord = location.coordGrid
                local packedCoord = coord:ToPacked()
                local known = locationsFound[packedCoord]
                if known == nil or known.feature ~= feature then
                    locationsFound[packedCoord] = locationEntry(feature, coord, location.rotationType,
                        location.width, location.length, location.shapeType)
                    foundChanged = true
                end
            end
        end
    end
    if readStanding() then gridStale = true end
    scanNpcs()
    if foundChanged then settlingTicksLeft = SETTLING_TICKS end
    foundChanged = foundChanged or changedBefore
end

-- The grid is rebuilt when its inputs change, keeping the last one built if the new one would be the same, so routes
-- and plan searches cached on it stay valid. The server tick puts it in Forest.grid once it is settled (every zone
-- whose turn matters turned by its heights) or GRID_WAIT_TICKS have passed since entering, so the map's zones, the
-- routes and the plans are not worked out on the unturned zones of the first ticks, while the zones load.
local GRID_WAIT_TICKS = 6 -- about four seconds; at High draw distance (raised on entering) the zones load in 3 ticks
local builtGrid = nil -- the last grid built, held back from Forest.grid until settled or due
local gridDueTick = 0 -- the server tick from which an unsettled grid is used

local function publish()
    foundChanged = false
    local found, countOf = {}, {}
    for _, entry in pairs(locationsFound) do found[#found + 1] = entry end
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
    Forest.onChanged()
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
                zones[#zones + 1] = { x = x, z = z, sourceX = source.x, sourceZ = source.z,
                templateKey = source.x .. "_" .. source.z }
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
    local coord = Player.GetEntity().coordGrid
    local x, z = coord.x, coord.z
    local bounds, last = Forest.bounds, Forest.playerTile
    if x < bounds.minX or z < bounds.minZ or x >= bounds.minX + bounds.width or z >= bounds.minZ + bounds.length then
        return
    end
    if last ~= nil and last.x == x and last.z == z then return end
    Forest.playerTile = { x = x, z = z }
    if Forest.entryTile == nil then Forest.entryTile = Forest.playerTile end
    -- on each new zone: the zones' heights not read yet are tried again, and the grid built on the next tick
    if last == nil or last.x // ZONE_SIZE ~= x // ZONE_SIZE or last.z // ZONE_SIZE ~= z // ZONE_SIZE then
        if readStanding() then gridStale = true end
    end
    Forest.onMoved()
end

-- Drops everything of a forest on leaving, as the instance is gone once all players leave. The grid goes with the
-- searches cached on it (routes.lua, solve_plan.lua).
local function forgetForest()
    Forest.zones, Forest.bounds, Forest.openings = {}, nil, {}
    Forest.found, Forest.countOf, Forest.doorsGone, Forest.following = {}, {}, {}, {}
    Forest.keysTaken, playersRemoved = {}, false
    Forest.standingByZone = {}
    Forest.grid, builtGrid, Forest.zoneTurns = nil, nil, nil
    Forest.playerTile, Forest.entryTile = nil, nil
    Forest.monstersSpawned = 0
    npcsFound, monstersSeen, taskItemsHeld, itemsHeldNow = {}, {}, {}, nil
    npcsArrived = false
end

local function stopWatching()
    Event.ServerLogic.Unsubscribe(SUBSCRIPTION)
    Event.VarTransmit.Unsubscribe(SUBSCRIPTION)
    Event.LocAdded.Unsubscribe(SUBSCRIPTION)
    Event.LocRemoved.Unsubscribe(SUBSCRIPTION)
    Event.NPCEntityAdded.Unsubscribe(SUBSCRIPTION)
    Event.InventoryUpdated.Unsubscribe(SUBSCRIPTION)
    Event.PlayerEntityRemoved.Unsubscribe(PLAYERS_SUBSCRIPTION)
    -- also announced before entering, so dropped whether entered or not
    locationsFound, anyAnnounced = {}, false
    DrawDistance.restore()
    if Forest.isInside then
        Forest.isInside, Forest.isSearching = false, false
        forgetForest()
        Forest.onLeft()
        ForestGrid.forgetTemplates()
    end
end

-- Drops doors when another player opens them.
local function dropAt(packedCoord, shapeType)
    local known = locationsFound[packedCoord]
    if known ~= nil and known.shapeType == shapeType then
        locationsFound[packedCoord] = nil
        foundChanged = true
    end
end

-- Notes a feature added. Another location added replaces one of the same shape on its tile.
local function onLocationAdded(event)
    local config, coord = event.config, event.coordGrid
    local packedCoord = coord:ToPacked()
    local feature = featureOfLocID[config.id] or featureAddedAs[config.id]
    if feature == nil then return dropAt(packedCoord, event.shapeType) end
    local width, length = config.width, config.length
    -- a config's size is unrotated; a quarter turn swaps it
    if event.rotationType % 2 == 1 then width, length = length, width end
    local entry = locationEntry(feature, coord, event.rotationType, width, length, event.shapeType)
    -- a change at a known tile updates its entry in place, so plans and routes keep the same object
    local known = locationsFound[packedCoord]
    if known ~= nil then
        for field, value in pairs(entry) do known[field] = value end
    else
        locationsFound[packedCoord] = entry
    end
    anyAnnounced, foundChanged = true, true
    if announcingTicksLeft > 0 and not announcementsEnded then
        announcedInBurst, announcedThisTick = true, true
    end
end

local function onLocationRemoved(event)
    dropAt(event.coordGrid:ToPacked(), event.shapeType)
end

local function enter(region)
    Forest.isInside, Forest.isSearching = true, true
    gridDueTick = Forest.ticks + GRID_WAIT_TICKS
    Forest.zones, Forest.bounds, Forest.openings = region.zones, region.bounds, region.openings
    foundChanged, gridStale, settlingTicksLeft = true, true, SETTLING_TICKS
    Event.NPCEntityAdded.Subscribe(SUBSCRIPTION, function() npcsArrived = true end)
    -- Every inventory the server sends fires this (each item gathered at a node, the bank, the coin pouch), but
    -- only the backpack and worn items hold tools and task items.
    Event.InventoryUpdated.Subscribe(SUBSCRIPTION, function(event)
        if not isHeldInventory[event.inv.id] then return end
        itemsHeldNow = nil
        if Forest.playerTile ~= nil then Forest.onInventoryChanged() end
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
    Forest.readClaimedToday()
    Event.VarTransmit.Subscribe(SUBSCRIPTION, function(event)
        if event.var.id == claimedBaseID then
            Forest.readClaimedToday()
            foundChanged = true
        end
        -- a task's target done (the Traitor killed). The current task changes only at Trinks, outside the forest.
        if doneBaseIDs[event.var.id] then foundChanged = true end
    end)
    -- The draw distance goes up to High until the grid settles (draw_distance.lua). Only from Low does the server then
    -- send more (the far map squares, a tick later): that is waited for as a second announcement, and quiet ticks end
    -- the search if none comes. From Medium the server has sent the whole forest already, so nothing is waited for.
    if DrawDistance.raise() then
        announcedInBurst, announcedThisTick, announcementsEnded = false, false, false
        announcingTicksLeft = ANNOUNCING_TICKS
    end
    Forest.onEntered()
end

-- Moves each found NPC's marker to its tile once a server tick, so its route ends at it.
local function followNpcs()
    for _, entry in ipairs(npcsFound) do
        -- the forest has one of each, listed only while in view
        local npcEntity = NPCList.ByConfigID(entry.npcID)[1]
        if npcEntity ~= nil then
            entry.npcEntity = npcEntity
            local coord = npcEntity.coordGrid
            local x, z = coord.x + 0.5, coord.z + 0.5
            if entry.x ~= x or entry.z ~= z then
                entry.x, entry.z = x, z
                Forest.onNpcMoved(entry)
            end
        end
    end
end

-- Runs once per server tick while a region is watched: waits until the region is recognised as the forest, then
-- scans until the search settles, and follows the player.
local function onServerTick()
    Forest.ticks = Forest.ticks + 1
    -- a tick with nothing new announced completes the announcement
    if not announcementsEnded and announcedInBurst and not announcedThisTick then announcementsEnded = true end
    announcedThisTick = false
    announcingTicksLeft = announcingTicksLeft - 1
    if not Forest.isInside then
        local isForest = nil
        if World.IsAvailable() and Player.IsAvailable() then isForest = playerZoneIsForest() end
        if not isForest then
            arrivalTicksLeft = arrivalTicksLeft - 1
            if isForest == false or arrivalTicksLeft <= 0 then stopWatching() end
            return
        end
        local region = readRegion()
        if region == nil then return end
        enter(region)
    end
    -- the scans read the player's level, and the player is briefly unavailable while the world changes
    if not Player.IsAvailable() then return end
    -- While the forest settles, the zones' heights and the NPCs are read each tick, and the locations too until
    -- something is announced; after that the locations' changes come as events, and NPCs are looked for when some
    -- arrive.
    if settlingTicksLeft > 0 then
        settlingTicksLeft = settlingTicksLeft - 1
        scan()
    elseif npcsArrived then
        scanNpcs()
    end
    npcsArrived = false
    -- the search ending is a change too, as the windows show whether it is still going; it does not come back
    if Forest.isSearching and (announcementsEnded or settlingTicksLeft <= SETTLING_TICKS - SHOWN_SETTLED_AFTER) then
        Forest.isSearching, foundChanged = false, true
    end
    readDialogue()
    freeKeysOfPlayersGone()
    followNpcs()
    -- heights read by a scan or a step may change the grid without a find
    if gridStale then
        gridStale = false
        local grid = ForestGrid.build(Forest.zones, Forest.bounds, Forest.standingByZone, builtGrid)
        if grid ~= builtGrid then builtGrid, Forest.zoneTurns, foundChanged = grid, grid.turns, true end
    end
    -- an unsettled grid is held back until gridDueTick
    if builtGrid ~= nil and Forest.grid ~= builtGrid and (builtGrid.settled or Forest.ticks >= gridDueTick) then
        Forest.grid, foundChanged = builtGrid, true
    end
    if foundChanged then publish() end
    followPlayer()
    -- After a reload only the scans find the nodes, keys and doors, so the draw distance stays up until they settle
    -- too, as the client lets far squares go below Medium.
    if Forest.grid ~= nil and (not announcementMissed or settlingTicksLeft == 0) then DrawDistance.restore() end
end

-- Listens for added locations from the region's creation.
-- isNew is false when the plugin loaded inside the forest, after its announcement.
local function watchRegion(isNew)
    arrivalTicksLeft = ARRIVAL_TICKS
    announcementMissed = not isNew
    announcedInBurst, announcedThisTick, announcementsEnded = false, false, false
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
local rotationFeatures, rotationIndexOf = ForestFeatures.nodesInRotation, {}
for index, node in ipairs(rotationFeatures) do rotationIndexOf[node.key] = index - 1 end
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

-- Called on leaving the game and at shutdown: nothing is listened for, and a forest is left.
function Forest.stop()
    Event.RegionCreated.Unsubscribe(SUBSCRIPTION)
    Event.WorldCreated.Unsubscribe(SUBSCRIPTION)
    stopWatching()
end

return Forest

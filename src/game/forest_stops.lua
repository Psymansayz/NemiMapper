-- Turns the things found in the forest into stops for the route plans (SolvePlan) to visit.
-- Identifies each thing's tiles, the stops for NAVIGATE (unclaimed nodes and the current task's target) and for SOLVE
-- (the puzzles' keys and doors), the keys and doors a tour to some targets needs, and the keys and doors that no tour
-- to the nodes needs. The map window's routes and the world's 3D boxes both use it.
-- NAVIGATE's plan is kept until something it depends on changes.

-- Terms used throughout the plugin for getting the player somewhere:
--   stop    one place a plan must or may visit: a node, a task's target, a key or a door
--   target  what one route ends at: a stop, a thing clicked on the map or in a legend, or an opening
--   tour    one order of visiting all of a plan's stops; the planner compares tours by the tiles walked
--   plan    the choice of the next stop, from the best tour. Only NAVIGATE and SOLVE have one.
--   route   the tiles walked to one target, drawn on the map and the ground: the chosen route (a click or a
--           plan's next stop) or the final route (from the entrance past every node to the exit)
--   leg     the walk between two stops within a tour, used only for its distance
-- So a plan picks the next stop by comparing tours, and the route is the tiles that reach it, its target.

local ForestFeatures = require("src/data/forest_features")
local Forest = require("src/game/forest")
local SolvePlan = require("src/game/solve_plan")

local ForestStops = {}

-- Returns a found thing as tiles: the x and z of its south-west corner, and every tile it covers, as it can be
-- reached from beside any of them.
local function tilesOfEntry(entry)
    local left, bottom = Forest.southWestOf(entry)
    local footprint = {}
    for z = bottom, bottom + entry.length - 1 do
        for x = left, left + entry.width - 1 do footprint[#footprint + 1] = { x = x, z = z } end
    end
    return { x = left, z = bottom, tiles = footprint }
end

-- Returns the found things of a kind (and key), as tilesOfEntry gives them.
function ForestStops.tilesOfKind(kind, key)
    local tiles = {}
    for _, entry in ipairs(Forest.found) do
        if entry.feature.kind == kind and (key == nil or entry.feature.key == key) then
            tiles[#tiles + 1] = tilesOfEntry(entry)
        end
    end
    return tiles
end

-- Returns the opening whose mouth is on the forest's north or east edge (side), or nil.
function ForestStops.openingOn(side)
    local bounds = Forest.bounds
    for _, opening in ipairs(Forest.openings) do
        if (side == "north" and opening.z == bounds.minZ + bounds.length - 1)
            or (side == "east" and opening.x == bounds.minX + bounds.width - 1) then
            return opening
        end
    end
    return nil
end

-- Returns the barriers' tiles, which routes to a tool or barrier do not cross.
function ForestStops.barrierTiles()
    local blocked = {}
    for _, entry in ipairs(Forest.found) do
        if entry.feature.kind == "barrier" then
            for _, tile in ipairs(tilesOfEntry(entry).tiles) do
                local index = Forest.grid:index(tile.x, tile.z)
                if index ~= nil then blocked[index] = true end
            end
        end
    end
    return blocked
end

-- Returns the thing a route ends at: the one of a kind (and key) nearest the route's last tile.
function ForestStops.entryAtEnd(route, kind, key)
    local last = route[#route]
    local best, bestDistance = nil, nil
    for _, entry in ipairs(Forest.found) do
        if entry.feature.kind == kind and (key == nil or entry.feature.key == key) then
            local distance = math.max(math.abs(entry.x - 0.5 - last.x), math.abs(entry.z - 0.5 - last.z))
            if bestDistance == nil or distance < bestDistance then best, bestDistance = entry, distance end
        end
    end
    return best
end

-- Returns whether a key or door is still needed: its puzzle is not done, and it is not a key held by the player.
function ForestStops.isPuzzleLeft(entry, held)
    local feature = entry.feature
    return not Forest.doorsGone[feature.pair.barrier.key] and not (feature.kind == "source" and held[feature.key])
end

-- Returns a found thing as a plan stop, with its tiles and the colour of the route to it.
function ForestStops.stopOf(kind, entry, colour)
    local stop = tilesOfEntry(entry)
    stop.kind, stop.colour, stop.entry = kind, colour, entry
    return stop
end

-- Returns the stop of entry among stops if a plan may keep going to it, or nil to plan afresh.
-- A door whose key is not held (its needs) is not kept, so the plan fetches the key first.
function ForestStops.keptStop(stops, entry)
    if entry == nil then return nil end
    for _, stop in ipairs(stops) do
        if stop.entry == entry and stop.needs == nil then return stop end
    end
    return nil
end

-- Returns the mapping plan's stops: every found node not claimed today, and the active task's target (the same trip).
function ForestStops.mapStops()
    local stops = {}
    for _, entry in ipairs(Forest.found) do
        local feature = entry.feature
        if (feature.kind == "node" and not entry.isUsed)
            or (feature.kind == "task" and Forest.isTaskActive(feature)) then
            stops[#stops + 1] = ForestStops.stopOf("key", entry, ForestFeatures.colourOf(feature))
        end
    end
    return stops
end

-- Returns the puzzles' stops.
-- Each unfinished puzzle has its key as a stop while the player lacks it. 
-- A barrier is a stop if its key is found or held.
-- Solving needs all of them, mapping only those on the routes to the nodes.
function ForestStops.solveStops(held)
    -- The first found of each puzzle feature, in one pass.
    local firstOf = {}
    for _, entry in ipairs(Forest.found) do
        if entry.feature.isPuzzle and firstOf[entry.feature] == nil then firstOf[entry.feature] = entry end
    end
    local stops = {}
    for _, toolPair in ipairs(ForestFeatures.tools) do
        if not Forest.doorsGone[toolPair.barrier.key] then
            local keyEntry, doorEntry = firstOf[toolPair.source], firstOf[toolPair.barrier]
            local keyStop = keyEntry and not held[toolPair.source.key]
                and ForestStops.stopOf("key", keyEntry, toolPair.colour) or nil
            local doorStop = doorEntry and ForestStops.stopOf("door", doorEntry, toolPair.colour) or nil
            if keyStop ~= nil then stops[#stops + 1] = keyStop end
            if doorStop ~= nil and (keyStop ~= nil or held[toolPair.source.key]) then
                doorStop.needs = keyStop
                stops[#stops + 1] = doorStop
            end
        end
    end
    return stops
end

-- Returns the tiles of barriers which the plan never crosses.
function ForestStops.tilesNotInPlan(stops, blocked)
    local inPlan = {}
    for _, stop in ipairs(stops) do
        if stop.kind == "door" then
            for _, tile in ipairs(stop.tiles) do inPlan[Forest.grid:index(tile.x, tile.z) or -1] = true end
        end
    end
    local left = {}
    for index in pairs(blocked) do
        if not inPlan[index] then left[index] = true end
    end
    return left
end

-- Returns the stops of a tour through the targets, which must be visited, plus the puzzle stops it needs.
-- The barriers on the routes to the targets and their keys are required.
-- Other keys are added where they cost nothing.
-- Also returns the barriers on those routes whose keys are unseen, as stops to walk to.
-- A target that is itself a puzzle stop counts as that stop.
function ForestStops.stopsToward(targets, player, held)
    local stops, mustVisit, isStop, isTarget = {}, {}, {}, {}
    local puzzleStops = ForestStops.solveStops(held)
    for _, target in ipairs(targets) do isTarget[target.entry] = target end
    for _, stop in ipairs(puzzleStops) do isStop[stop.entry] = true end
    for _, target in ipairs(targets) do
        if not isStop[target.entry] then
            stops[#stops + 1] = target
            mustVisit[target] = true
        end
    end
    for _, stop in ipairs(puzzleStops) do
        stops[#stops + 1] = stop
        if isTarget[stop.entry] then mustVisit[stop] = true end
    end
    local keylessDoors = {}
    for _, entry in ipairs(Forest.found) do
        if entry.feature.kind == "barrier" and not isStop[entry] then
            keylessDoors[#keylessDoors + 1] = ForestStops.stopOf("door", entry, entry.feature.pair.colour)
        end
    end
    return SolvePlan.neededStops(Forest.grid, player, stops, mustVisit, keylessDoors)
end

-- Returns the puzzle entries that mappingStops does not require.
local function unneededAmong(mappingStops, held)
    local required, unneeded = {}, {}
    for _, stop in ipairs(mappingStops) do
        if not stop.optional then required[stop.entry] = true end
    end
    for _, stop in ipairs(ForestStops.solveStops(held)) do
        if not required[stop.entry] then unneeded[stop.entry] = true end
    end
    return unneeded
end

-- Returns what NAVIGATE's stops depend on, as a string: the unclaimed nodes, active tasks and unfinished puzzles
-- found, and the tools in held.
local signatureOf = { found = nil, held = nil, signature = nil }
local function planSignature(held)
    local heldKeys = {}
    for key in pairs(held) do heldKeys[#heldKeys + 1] = key end
    table.sort(heldKeys)
    local heldKey = table.concat(heldKeys, " ")
    if signatureOf.found == Forest.found and signatureOf.held == heldKey then return signatureOf.signature end
    local parts = { heldKey }
    for _, entry in ipairs(Forest.found) do
        local feature = entry.feature
        if (feature.kind == "node" and not entry.isUsed) or (feature.kind == "task" and Forest.isTaskActive(feature))
            or (feature.isPuzzle and not Forest.doorsGone[feature.pair.barrier.key]) then
            parts[#parts + 1] = tostring(entry)
        end
    end
    signatureOf.found, signatureOf.held, signatureOf.signature = Forest.found, heldKey, table.concat(parts, " ")
    return signatureOf.signature
end

-- Returns NAVIGATE's stops from the player's tile with the tools in held, and the doors with unseen keys on the way.
-- They are kept until planSignature, the grid or the player's tile changes, as several callers ask at once.
local kept = {}
local function keptPlan(held)
    local player = Forest.isInside and Forest.playerTile or nil
    if player == nil or Forest.grid == nil then return nil end
    local signature = planSignature(held)
    if kept.signature ~= signature or kept.grid ~= Forest.grid or kept.player ~= player then
        kept.signature, kept.grid, kept.player = signature, Forest.grid, player
        kept.stops, kept.keylessNeeded = ForestStops.stopsToward(ForestStops.mapStops(), player, held)
        kept.unneeded = nil
    end
    return kept
end

-- Drops the kept plan and the signature on leaving the forest.
function ForestStops.forget()
    kept = {}
    signatureOf.found, signatureOf.held, signatureOf.signature = nil, nil, nil
end

local NONE = {}

-- Returns the mapping plan's stops and the keyless barriers on the way (see keptPlan).
function ForestStops.mappingStopsNow(held)
    local plan = keptPlan(held)
    if plan == nil then return NONE, NONE end
    return plan.stops, plan.keylessNeeded
end

-- Returns the puzzle entries no route to an unclaimed node needs.
function ForestStops.unneededNow(held)
    local plan = keptPlan(held)
    if plan == nil then return NONE end
    if plan.unneeded == nil then plan.unneeded = unneededAmong(plan.stops, held) end
    return plan.unneeded
end

return ForestStops

-- Turns the features found in the forest into stops for the route plans (SolvePlan) to visit.
-- Identifies each feature's tiles, the stops for NAVIGATE (unclaimed nodes and the current task's target) and for SOLVE
-- (the puzzles' keys and doors), the keys and doors a tour to some targets needs, and the keys and doors that no tour
-- to the nodes needs.

-- Terms used throughout the plugin for getting the player somewhere:
--   stop    one place a plan must or may visit: a node, a task's target, a key or a door
--   target  what one route ends at: a stop, a feature clicked on the map or in a legend, or an opening
--   tour    one order of visiting all of a plan's stops; the planner compares tours by the tiles walked
--   plan    the choice of the next stop, from the best tour. Only NAVIGATE and SOLVE have one.
--   route   the tiles walked to one target, drawn on the map and the ground: the chosen route (a click or a
--           plan's next stop) or the final route (from the entrance past every node to the exit)
--   leg     the walk between two stops within a tour, used only for its distance
-- So a plan picks the next stop by comparing tours, and the route is the tiles that lead to its target.

local ForestFeatures = require("src/data/forest_features")
local Forest = require("src/game/forest")
local SolvePlan = require("src/game/solve_plan")

local ForestStops = {}

-- Returns a found feature as tiles: the x and z of its south-west corner, and every tile it covers, as it can be
-- reached from beside any of them.
local function tilesOfEntry(entry)
    local left, bottom = Forest.southWestOf(entry)
    local footprint = {}
    for z = bottom, bottom + entry.length - 1 do
        for x = left, left + entry.width - 1 do footprint[#footprint + 1] = { x = x, z = z } end
    end
    return { x = left, z = bottom, tiles = footprint }
end

-- Returns whether a key's or door's puzzle is unsolved: its door still stands.
local function isUnsolved(feature)
    return not Forest.doorsGone[feature.pair.barrier.key]
end

-- Returns whether a found feature is a mapping stop: a node not claimed today, or the active task's target.
local function isMapStop(entry)
    local feature = entry.feature
    return (feature.kind == "node" and not entry.isUsed) or (feature.kind == "task" and Forest.isTaskActive(feature))
end

-- Returns the found features for which isStop(entry) is true, as stops.
function ForestStops.stopsWhere(isStop)
    local stops = {}
    for _, entry in ipairs(Forest.found) do
        if isStop(entry) then stops[#stops + 1] = ForestStops.stopOf(entry) end
    end
    return stops
end

-- Returns the found features of a kind (and key) as stops.
function ForestStops.stopsOfKind(kind, key)
    return ForestStops.stopsWhere(function(entry)
        return entry.feature.kind == kind and (key == nil or entry.feature.key == key)
    end)
end

-- Returns the opening whose mouth is on the forest's north or east edge (side).
function ForestStops.openingOn(side)
    local bounds = Forest.bounds
    for _, opening in ipairs(Forest.openings) do
        if (side == "north" and opening.z == bounds.minZ + bounds.length - 1)
            or (side == "east" and opening.x == bounds.minX + bounds.width - 1) then
            return opening
        end
    end
end

-- Returns the barriers' tiles, which routes to a tool or barrier do not cross.
function ForestStops.barrierTiles()
    local blocked = {}
    for _, barrier in ipairs(ForestStops.stopsOfKind("barrier")) do
        for _, tile in ipairs(barrier.tiles) do
            blocked[Forest.grid:index(tile.x, tile.z)] = true
        end
    end
    return blocked
end

-- Returns whether two sets (key -> true) hold the same keys: a route's stops by entry, or the tools held by source key.
function ForestStops.sameSet(first, second)
    for key in pairs(first) do
        if not second[key] then return false end
    end
    for key in pairs(second) do
        if not first[key] then return false end
    end
    return true
end

-- Returns whether a key or door is still needed.
function ForestStops.isPuzzleLeft(entry, held)
    local feature = entry.feature
    return isUnsolved(feature) and not (feature.kind == "source" and held[feature.key])
end

-- Returns whether a key or door is still needed and not among unneeded (entry -> true).
function ForestStops.isPuzzleNeeded(entry, held, unneeded)
    return not unneeded[entry] and ForestStops.isPuzzleLeft(entry, held)
end

-- Returns a found feature as a plan stop, with its tiles and the colour of the route to it. A barrier is a door
-- stop, anything else a key stop (visited without a key first).
function ForestStops.stopOf(entry)
    local stop = tilesOfEntry(entry)
    stop.kind = entry.feature.kind == "barrier" and "door" or "key"
    stop.colour, stop.entry = ForestFeatures.colourOf(entry.feature), entry
    return stop
end

-- Returns the stop in stops at entry, if it waits for no key first.
function ForestStops.keptStop(stops, entry)
    for _, stop in ipairs(stops) do
        if stop.entry == entry and stop.needs == nil then return stop end
    end
end

function ForestStops.isWorkLeft(feature)
    if feature.kind == "node" then return not Forest.isNodeClaimed(feature.key) end
    if feature.kind == "source" then return isUnsolved(feature) end
    return feature.kind == "task" and Forest.isTaskActive(feature)
end

-- Returns the puzzles' stops.
-- Each unfinished puzzle has its key as a stop while the player lacks it, unless another player has it.
-- A barrier is a stop if its key is a stop or is held.
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
            local keyStop = keyEntry and not held[toolPair.source.key] and not Forest.keysTaken[toolPair.source.key]
                and ForestStops.stopOf(keyEntry) or nil
            local doorStop = doorEntry and ForestStops.stopOf(doorEntry) or nil
            if keyStop ~= nil then stops[#stops + 1] = keyStop end
            if doorStop ~= nil and (keyStop ~= nil or held[toolPair.source.key]) then
                doorStop.needs = keyStop
                stops[#stops + 1] = doorStop
            end
        end
    end
    return stops
end

-- Returns the stops of the doors whose key is neither seen nor held, which SOLVE walks toward the forest's centre to
-- find when nothing else is left to reach.
function ForestStops.unseenKeyDoors(held)
    local doors = {}
    for _, toolPair in ipairs(Forest.keysUnseen()) do
        if not held[toolPair.source.key] then
            for _, entry in ipairs(Forest.found) do
                if entry.feature == toolPair.barrier then
                    doors[#doors + 1] = ForestStops.stopOf(entry)
                    break
                end
            end
        end
    end
    return doors
end

-- Returns the stops of the keys following another player.
-- A plan goes to one only when nothing else it could reach is left.
function ForestStops.takenKeyStops()
    return ForestStops.stopsWhere(function(entry)
        local feature = entry.feature
        return feature.kind == "source" and Forest.keysTaken[feature.key] and isUnsolved(feature)
    end)
end

-- Returns the tiles of barriers which the plan never crosses.
function ForestStops.tilesNotInPlan(stops, blocked)
    local inPlan = {}
    for _, stop in ipairs(stops) do
        if stop.kind == "door" then
            for _, tile in ipairs(stop.tiles) do inPlan[Forest.grid:index(tile.x, tile.z)] = true end
        end
    end
    local left = {}
    for index in pairs(blocked) do
        if not inPlan[index] then left[index] = true end
    end
    return left
end

-- Returns a plan toward the targets: { stops, unseenKeyDoors, takenKeys, puzzleStops }. stops are the targets, which
-- must be visited, plus the puzzle stops on the way; unseenKeyDoors the doors on the way whose key is not seen yet;
-- takenKeys the source keys on the way that another player has (key -> true); puzzleStops every puzzle stop.
function ForestStops.stopsToward(targets, player, held)
    local stops, mustVisit, isStop, isTarget = {}, {}, {}, {}
    local puzzleStops = ForestStops.solveStops(held)
    for _, target in ipairs(targets) do isTarget[target.entry] = true end
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
            keylessDoors[#keylessDoors + 1] = ForestStops.stopOf(entry)
        end
    end
    local needed, keylessNeeded = SolvePlan.neededStops(Forest.grid, player, stops, mustVisit, keylessDoors)
    local plan = { stops = needed, unseenKeyDoors = {}, takenKeys = {}, puzzleStops = puzzleStops }
    for _, door in ipairs(keylessNeeded) do
        local sourceKey = door.entry.feature.pair.source.key
        if Forest.keysTaken[sourceKey] then
            plan.takenKeys[sourceKey] = true
        else
            plan.unseenKeyDoors[#plan.unseenKeyDoors + 1] = door
        end
    end
    return plan
end

-- Returns what NAVIGATE's stops depend on, as a string: the unclaimed nodes, active tasks and unfinished puzzles
-- found, the tools in held and the keys another player has.
local function planSignature(held)
    local parts = {}
    for key in pairs(held) do parts[#parts + 1] = key end
    for key in pairs(Forest.keysTaken) do parts[#parts + 1] = "taken:" .. key end
    table.sort(parts)
    for _, entry in ipairs(Forest.found) do
        if isMapStop(entry) or (entry.feature.isPuzzle and isUnsolved(entry.feature)) then
            parts[#parts + 1] = tostring(entry)
        end
    end
    return table.concat(parts, " ")
end

local NONE = {}
local NO_PLAN = { stops = NONE, unseenKeyDoors = NONE, takenKeys = NONE, unneeded = NONE }

-- Returns NAVIGATE's plan (stopsToward) toward every found node not claimed today and the active task's target, with
-- unneeded: the puzzle entries it does not need.
-- The player is never past a standing barrier, and the forest's few loops never lead round one, so the barriers on
-- the way to each stop are the same from any tile the player can reach: the plan is worked out again only when the
-- signature changes.
local kept = NO_PLAN
function ForestStops.mappingPlan(held)
    local player = Forest.playerTile
    if player == nil or Forest.grid == nil then return NO_PLAN end
    local signature = planSignature(held)
    if kept.signature ~= signature or kept.grid ~= Forest.grid then
        kept = ForestStops.stopsToward(ForestStops.stopsWhere(isMapStop), player, held)
        kept.signature, kept.grid = signature, Forest.grid
        local required = {}
        for _, stop in ipairs(kept.stops) do required[stop.entry] = true end
        kept.unneeded = {}
        for _, stop in ipairs(kept.puzzleStops) do
            if not required[stop.entry] then kept.unneeded[stop.entry] = true end
        end
    end
    return kept
end

-- Drops the kept plan on leaving the forest.
function ForestStops.forget()
    kept = NO_PLAN
end

return ForestStops

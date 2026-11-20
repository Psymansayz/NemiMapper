-- Which stop to go to next: the first stop of the shortest tour of every stop

local Routes = require("src/game/routes")

local SolvePlan = {}

local INFINITE = math.huge
local MISSED = 1000000 -- a stop no order reaches costs more than any tour's tiles

-- Returns tiles as a set of grid indexes.
local function tilesOf(grid, tiles)
    local indexes = {}
    for _, tile in ipairs(tiles) do
        local index = grid:index(tile.x, tile.z)
        if index ~= nil then indexes[index] = true end
    end
    return indexes
end

-- Returns the distances from a search's start to each stop.
local function distancesFrom(grid, found, stops)
    local distances = {}
    for index, stop in ipairs(stops) do
        local _, distance = Routes.nearest(found, Routes.tilesRound(grid, stop))
        distances[index] = distance and distance + 1 or INFINITE -- and the step onto the stop
    end
    return distances
end

local function stopKey(stop) return stop.kind .. stop.x .. "," .. stop.z end

-- Returns the distances from a stop to each of stops, searching only when one is not known.
-- Stops stay put, so replanning after the player moves, takes a key or claims a node only searches from the player.
-- With the same barriers shut (doorsKey), a stop's search always has the same blocked tiles (blockedFor(stop)), so
-- distances are kept by stop until a barrier opens.
local function distancesFromStop(grid, stop, stops, doorsKey, blockedFor)
    local cache = grid.stopDistances
    if cache == nil or cache.doorsKey ~= doorsKey then
        cache = { doorsKey = doorsKey, byStop = {} }
        grid.stopDistances = cache
    end
    local key = stopKey(stop)
    local known = cache.byStop[key]
    if known == nil then
        known = {}
        cache.byStop[key] = known
    end
    local distances, allKnown = {}, true
    for index, target in ipairs(stops) do
        distances[index] = known[stopKey(target)]
        allKnown = allKnown and distances[index] ~= nil
    end
    if allKnown then return distances end
    distances = distancesFrom(grid, Routes.search(grid, stop.tiles, blockedFor(stop), true), stops)
    for index, target in ipairs(stops) do known[stopKey(target)] = distances[index] end
    return distances
end

-- Returns the stop to go to first, and the search from the player with every barrier shut (Routes.search with
-- parents), for the route to that stop.
-- stops: [n] = { kind = "key" or "door", x, z (the feature's tile), tiles (every tile it stands on), needs = the
-- key stop a door needs, or nil when the key is held, group = a node's key, shared by its copies, optional = true
-- for a stop the tour may leave out }.
-- player: { x, z }. alwaysBlocked: tile index -> true for tiles never to cross (barriers that are not stops).
function SolvePlan.nextStop(grid, player, stops, alwaysBlocked)
    local stopCount = #stops
    if stopCount == 0 then return nil end
    local indexOf = {}
    for index, stop in ipairs(stops) do indexOf[stop] = index end
    -- One claim uses every copy of a node, so visiting one copy visits its group: groupBits[n] is stop n's bit and
    -- its copies'.
    local bitsOfGroup, groupBits = {}, {}
    for index, stop in ipairs(stops) do
        if stop.group ~= nil then bitsOfGroup[stop.group] = (bitsOfGroup[stop.group] or 0) | (1 << index) end
    end
    for index, stop in ipairs(stops) do groupBits[index] = bitsOfGroup[stop.group] or (1 << index) end
    -- Every barrier blocks the way except the one a search starts from.
    local doorIndexes, doorMask = {}, 0 -- barrier stop -> its tiles' grid indexes; the barriers' bits
    for index, stop in ipairs(stops) do
        if stop.kind == "door" then
            doorIndexes[stop], doorMask = tilesOf(grid, stop.tiles), doorMask | (1 << index)
        end
    end
    local function blockedBut(openStop)
        local blocked = {}
        for index in pairs(alwaysBlocked) do blocked[index] = true end
        for door, indexes in pairs(doorIndexes) do
            if door ~= openStop then
                for index in pairs(indexes) do blocked[index] = true end
            end
        end
        return blocked
    end
    -- base[a][b]: the distance from stop a (0: the player) to stop b with every barrier but a shut.
    local allShut = blockedBut(nil)
    local shutIndexes = {}
    for index in pairs(allShut) do shutIndexes[#shutIndexes + 1] = index end
    table.sort(shutIndexes)
    local doorsKey = table.concat(shutIndexes, " ")
    local playerSearch = Routes.search(grid, { player }, allShut)
    local base = { [0] = distancesFrom(grid, playerSearch, stops) }
    for index, stop in ipairs(stops) do base[index] = distancesFromStop(grid, stop, stops, doorsKey, blockedBut) end
    -- Distances with the doors visited so far open
    local joinedByMask = {}
    local function joined(visitedMask)
        visitedMask = visitedMask & doorMask
        local walking = joinedByMask[visitedMask]
        if walking ~= nil then return walking end
        walking = {}
        for from = 0, stopCount do
            walking[from] = {}
            for to = 1, stopCount do walking[from][to] = base[from][to] end
        end
        for door = 1, stopCount do
            if visitedMask & (1 << door) ~= 0 then
                for from = 0, stopCount do
                    local toDoor = walking[from][door]
                    if toDoor < INFINITE then
                        for to = 1, stopCount do
                            local through = toDoor + walking[door][to]
                            if through < walking[from][to] then walking[from][to] = through end
                        end
                    end
                end
            end
        end
        joinedByMask[visitedMask] = walking
        return walking
    end
    local allVisited = (1 << (stopCount + 1)) - 2 -- bits 1 to stopCount
    local requiredMask = 0 -- the stops a tour must visit: all but the optional ones
    for index, stop in ipairs(stops) do
        if not stop.optional then requiredMask = requiredMask | (1 << index) end
    end
    -- The cheapest way to visit the rest from a stop, cached by the stop and the stops visited, and the stop to go
    -- to next.
    -- A required stop left unvisited costs MISSED, so a tour takes every one some order can reach before it counts
    -- tiles.
    -- The rest, out of reach or behind a door whose key is behind that door, are left out.
    local remembered = {}
    local function cheapest(at, visitedMask)
        if visitedMask & requiredMask == requiredMask then return 0 end
        local key = at * (allVisited + 1) + visitedMask
        if remembered[key] ~= nil then return remembered[key] end
        local best, bestFirst = INFINITE, nil
        local walking = joined(visitedMask)[at]
        for following = 1, stopCount do
            local stop = stops[following]
            local unvisited = visitedMask & (1 << following) == 0
            local keyHeld = stop.needs == nil or visitedMask & (1 << indexOf[stop.needs]) ~= 0
            if unvisited and keyHeld and walking[following] < INFINITE then
                local cost = walking[following] + cheapest(following, visitedMask | groupBits[following])
                -- A tie goes to the nearer next stop, so a key on the way is picked up, not passed.
                if cost < best or (cost == best and walking[following] < walking[bestFirst]) then
                    best, bestFirst = cost, following
                end
            end
        end
        if best == INFINITE then
            best = 0
            for index = 1, stopCount do
                if (requiredMask & ~visitedMask) & (1 << index) ~= 0 then best = best + MISSED end
            end
        end
        remembered[key] = best
        return best, bestFirst
    end
    -- no other call starts at the player (0), so this one is never found remembered and gives the first stop
    local _, first = cheapest(0, 0)
    return first and stops[first], playerSearch
end

-- Returns the stops a tour of the mustVisit stops needs.
-- keylessDoors: barriers whose keys are not seen yet, so they are not stops. Ways are traced through them too:
-- blocking them would make a node behind one of them, and another barrier on the way, look out of reach, and that
-- other barrier look unneeded.
function SolvePlan.neededStops(grid, player, stops, mustVisit, keylessDoors)
    local found = Routes.search(grid, { player })
    local doorAt = {} -- tile index -> the barrier on it
    for _, list in ipairs({ stops, keylessDoors }) do
        for _, stop in ipairs(list) do
            if stop.kind == "door" then
                for index in pairs(tilesOf(grid, stop.tiles)) do doorAt[index] = stop end
            end
        end
    end
    local function doorsOnWayTo(stop)
        local tile = Routes.nearest(found, Routes.tilesRound(grid, stop))
        local doors, index = {}, tile and tile.index
        while index ~= nil do
            if doorAt[index] ~= nil then doors[#doors + 1] = doorAt[index] end
            index = found.parent[index]
        end
        return doors
    end
    -- Each stop needed, "required" or "optional". A node with several copies needs only one visited, so the doors and
    -- keys on the way to a copy are optional: the plan opens one only if that copy adds the fewest tiles.
    local needed, copies = {}, {}
    local function need(stop, optional)
        local state = optional and "optional" or "required"
        if needed[stop] == "required" or needed[stop] == state then return end
        needed[stop] = state
        for _, door in ipairs(doorsOnWayTo(stop)) do
            need(door, optional)
            if door.needs ~= nil then need(door.needs, optional) end
        end
    end
    for _, stop in ipairs(stops) do
        if mustVisit[stop] and stop.group ~= nil then copies[stop.group] = (copies[stop.group] or 0) + 1 end
    end
    for _, stop in ipairs(stops) do
        if mustVisit[stop] then
            local duplicated = stop.group ~= nil and copies[stop.group] > 1
            need(stop, duplicated)
            needed[stop] = "required" -- (a copy is covered by visiting any of its group)
        end
    end
    local function neededAmong(list)
        local kept = {}
        for _, stop in ipairs(list) do
            if needed[stop] then
                stop.optional = needed[stop] == "optional" or nil
                kept[#kept + 1] = stop
            end
        end
        return kept
    end
    return neededAmong(stops), neededAmong(keylessDoors)
end

return SolvePlan

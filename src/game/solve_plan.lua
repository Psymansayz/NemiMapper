-- Which stop to go to next: the first stop of the shortest tour of every stop

local Routes = require("src/game/routes")

local SolvePlan = {}

local INFINITE = math.huge
-- Searches from stops cached on a grid before the cache is cleared. A door opening changes the
-- blocked tiles of every stop's search, so the cache is cleared then; this cap is a safeguard.
local SEARCHES_KEPT = 64

-- Returns tiles as a set of grid indexes.
local function tilesOf(grid, tiles)
    local indexes = {}
    for _, tile in ipairs(tiles) do
        local index = grid:index(tile.x, tile.z)
        if index ~= nil then indexes[index] = true end
    end
    return indexes
end

-- Returns a search from startTiles.
-- Stops stay put, so replanning after the player moves, takes a key or claims a node only searches from the player.
local function searchFromStop(grid, startTiles, blocked, doorsKey)
    local parts = {}
    for _, tile in ipairs(startTiles) do parts[#parts + 1] = tile.x .. "," .. tile.z end
    local blockedIndexes = {}
    for index in pairs(blocked) do blockedIndexes[#blockedIndexes + 1] = index end
    table.sort(blockedIndexes)
    local key = table.concat(parts, " ") .. "|" .. table.concat(blockedIndexes, " ")
    local searches = grid.stopSearches
    if searches == nil or searches.doorsKey ~= doorsKey then
        searches = { count = 0, byKey = {}, doorsKey = doorsKey }
        grid.stopSearches = searches
    end
    local found = searches.byKey[key]
    if found == nil then
        if searches.count >= SEARCHES_KEPT then
            searches.byKey, searches.count = {}, 0
        end
        found = Routes.search(grid, startTiles, blocked, true)
        searches.byKey[key], searches.count = found, searches.count + 1
    end
    return found
end

-- Returns the distances from a search's start to each stop, avoiding the blocked tiles.
local function distancesFrom(grid, found, stops, blocked)
    local distances = {}
    for index, stop in ipairs(stops) do
        local _, distance = Routes.nearest(found, Routes.tilesRound(grid, stop, blocked))
        distances[index] = distance and distance + 1 or INFINITE
    end
    return distances
end

-- Returns the stop to go to first; stops as SolvePlan.nextStop takes them.
local function plan(grid, player, stops, alwaysBlocked, playerSearch)
    local stopCount = #stops
    if stopCount == 0 then return nil, playerSearch end
    local indexOf = {}
    for index, stop in ipairs(stops) do indexOf[stop] = index end
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
    if playerSearch == nil then playerSearch = Routes.search(grid, { player }, allShut) end
    local base = { [0] = distancesFrom(grid, playerSearch, stops, allShut) }
    for index, stop in ipairs(stops) do
        local blocked = blockedBut(stop)
        base[index] = distancesFrom(grid, searchFromStop(grid, stop.tiles, blocked, doorsKey), stops, blocked)
    end
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
    local allVisited = 0
    for index in ipairs(stops) do allVisited = allVisited | (1 << index) end
    -- Find the stops some order can reach, taking them in any possible order until no more can be.
    -- The rest, out of reach or behind a door whose key is behind that door, are left out with whatever needs them.
    local doable, doableMask, taken = {}, 0, true
    while taken do
        taken = false
        local reach = joined(doableMask)[0]
        for index, stop in ipairs(stops) do
            if not doable[stop] and reach[index] < INFINITE and (stop.needs == nil or doable[stop.needs]) then
                doable[stop], doableMask, taken = true, doableMask | (1 << index), true
            end
        end
    end
    if doableMask ~= allVisited then
        -- a barrier left out stays shut, so its tiles are blocked
        local left, stillBlocked = {}, alwaysBlocked
        for _, stop in ipairs(stops) do
            if doable[stop] then
                left[#left + 1] = stop
            elseif stop.kind == "door" then
                if stillBlocked == alwaysBlocked then
                    stillBlocked = {}
                    for index in pairs(alwaysBlocked) do stillBlocked[index] = true end
                end
                for index in pairs(doorIndexes[stop]) do stillBlocked[index] = true end
            end
        end
        return plan(grid, player, left, stillBlocked, playerSearch)
    end
    -- The order stops are tried in, which breaks ties: keys first, as picking one up early costs nothing and
    -- opens the way, then the rest.
    local isKey = {}
    for _, stop in ipairs(stops) do
        if stop.needs ~= nil then isKey[stop.needs] = true end
    end
    local tried = {}
    for index, stop in ipairs(stops) do
        if isKey[stop] then tried[#tried + 1] = index end
    end
    for index, stop in ipairs(stops) do
        if not isKey[stop] then tried[#tried + 1] = index end
    end
    -- The cheapest way to visit the rest from a stop, cached by the stop and the stops visited, and the tour's
    -- first stop.
    local remembered, firstStop = {}, nil
    local function cheapest(at, visitedMask)
        if visitedMask == allVisited then return 0 end
        local key = at * (allVisited + 1) + visitedMask
        if remembered[key] ~= nil then return remembered[key] end
        local best, bestFirst = INFINITE, nil
        local walking = joined(visitedMask)[at]
        for _, following in ipairs(tried) do
            local stop = stops[following]
            local unvisited = visitedMask & (1 << following) == 0
            local keyHeld = stop.needs == nil or visitedMask & (1 << indexOf[stop.needs]) ~= 0
            if unvisited and keyHeld and walking[following] < INFINITE then
                local cost = walking[following] + cheapest(following, visitedMask | (1 << following))
                -- A tie goes to the nearer next stop, so a key on the way is picked up, not passed.
                -- An incomplete tour (INFINITE) does not tie with having no candidate yet.
                if cost < best or (cost == best and bestFirst ~= nil and walking[following] < walking[bestFirst]) then
                    best, bestFirst = cost, following
                end
            end
        end
        remembered[key] = best
        if key == 0 then firstStop = bestFirst end
        return best
    end
    if cheapest(0, 0) == INFINITE then return nil, playerSearch end
    return stops[firstStop], playerSearch
end

-- Returns the stops a tour of the mustVisit stops needs.
-- keylessDoors: barriers whose keys are not seen yet, so they are not stops. Ways are traced through them too:
-- blocking them would make a node behind one of them, and another barrier on the way, look out of reach, and that
-- other barrier look unneeded.
function SolvePlan.neededStops(grid, player, stops, mustVisit, keylessDoors)
    local found = Routes.search(grid, { player })
    local doorAt = {} -- tile index -> the barrier on it
    for _, stop in ipairs(stops) do
        if stop.kind == "door" then
            for index in pairs(tilesOf(grid, stop.tiles)) do doorAt[index] = stop end
        end
    end
    for _, door in ipairs(keylessDoors) do
        for index in pairs(tilesOf(grid, door.tiles)) do doorAt[index] = door end
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
    local needed = {}
    local function need(stop)
        if needed[stop] then return end
        needed[stop] = true
        for _, door in ipairs(doorsOnWayTo(stop)) do
            need(door)
            if door.needs ~= nil then need(door.needs) end
        end
    end
    for _, stop in ipairs(stops) do
        if mustVisit[stop] then need(stop) end
    end
    local kept = {}
    for _, stop in ipairs(stops) do
        if needed[stop] then kept[#kept + 1] = stop end
    end
    local keylessNeeded = {}
    for _, door in ipairs(keylessDoors) do
        if needed[door] then keylessNeeded[#keylessNeeded + 1] = door end
    end
    return kept, keylessNeeded
end

-- stops: [n] = { kind = "key" or "door", x, z (the feature's tile), tiles (every tile it stands on), needs = the
-- key stop a door needs, or nil when the key is held }.
-- player: { x, z }. blocked: tile index -> true for tiles never to cross (barriers that are not stops), or nil.
-- Returns the stop to go to first, and the search from the player with every barrier shut (Routes.search with
-- parents), for the route to that stop.
local NONE = {}
function SolvePlan.nextStop(grid, player, stops, blocked)
    return plan(grid, player, stops, blocked or NONE)
end

return SolvePlan

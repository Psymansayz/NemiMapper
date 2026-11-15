-- Routes over the forest's walkable tiles: the final route from the entrance past every node to the exit, and
-- the route from the player to the nearest of some things (a node, task, key, door or opening).

local Routes = {}

-- The four orthogonal steps, then the diagonals, which are only allowed between two open sides.
local STEPS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local DIAGONAL_STEPS = { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
local WIDER = 2 -- tiles: a thing with no open tile beside it (a misread tile) is reached from this close

-- Returns a tile's steps, as a flat list of triples: the walkable tile stepped to and the two side tiles a diagonal
-- passes between (0 for an orthogonal step).
-- They are cached on the grid on first use, as a grid's walkable tiles never change and working out steps in every
-- search would take most of its time.
-- Unwalkable tiles have steps too, as a search may start on a thing's own tiles.
local function stepsFrom(grid, index)
    local steps = grid.steps
    if steps == nil then
        steps = {}
        grid.steps = steps
    end
    local list = steps[index]
    if list ~= nil then return list end
    local x, z = grid:tile(index)
    list = {}
    for _, step in ipairs(STEPS) do
        local nextIndex = grid:index(x + step[1], z + step[2])
        if nextIndex ~= nil and grid.walkable[nextIndex] then
            list[#list + 1], list[#list + 2], list[#list + 3] = nextIndex, 0, 0
        end
    end
    for _, step in ipairs(DIAGONAL_STEPS) do
        local nextIndex = grid:index(x + step[1], z + step[2])
        local sideX, sideZ = grid:index(x + step[1], z), grid:index(x, z + step[2])
        if nextIndex ~= nil and grid.walkable[nextIndex] and sideX ~= nil and grid.walkable[sideX]
            and sideZ ~= nil and grid.walkable[sideZ] then
            list[#list + 1], list[#list + 2], list[#list + 3] = nextIndex, sideX, sideZ
        end
    end
    steps[index] = list
    return list
end

local NONE = {}

-- Returns a breadth-first search from startTiles: each tile's distance and the tile it was reached from
-- (left out with distancesOnly).
-- blocked: tile index -> true for extra tiles not to cross.
local function search(grid, startTiles, blocked, distancesOnly)
    local distance, parent, queue = {}, not distancesOnly and {} or nil, {}
    blocked = blocked or NONE
    for _, tile in ipairs(startTiles) do
        local index = grid:index(tile.x, tile.z)
        if index ~= nil and distance[index] == nil then
            distance[index] = 0
            queue[#queue + 1] = index
        end
    end
    local stepsByTile = grid.steps or NONE
    local first, last = 1, #queue
    while first <= last do
        local index = queue[first]
        first = first + 1
        local list, nextDistance = stepsByTile[index], distance[index] + 1
        if list == nil then
            list = stepsFrom(grid, index)
            stepsByTile = grid.steps
        end
        for position = 1, #list, 3 do
            local nextIndex, sideA = list[position], list[position + 1]
            if not blocked[nextIndex] and (sideA == 0 or not (blocked[sideA] or blocked[list[position + 2]])) then
                if distance[nextIndex] == nil then
                    distance[nextIndex] = nextDistance
                    if parent ~= nil then parent[nextIndex] = index end
                    last = last + 1
                    queue[last] = nextIndex
                end
            end
        end
    end
    return { grid = grid, distance = distance, parent = parent }
end

-- Adds a tile to tilesRound's list (added: the indexes listed, onThing: the thing's own) if it is new, walkable
-- and not blocked.
local function addTileRound(grid, tiles, added, onThing, blocked, x, z)
    local index = grid:index(x, z)
    if index ~= nil and not added[index] and not onThing[index] and grid.walkable[index] and not blocked[index] then
        added[index] = true
        tiles[#tiles + 1] = { x = x, z = z, index = index }
    end
end

-- Returns the walkable tiles a thing is used from: those orthogonally beside it, as the game does not allow using
-- doors, keys or nodes diagonally, or failing any, those within WIDER of it.
-- thing: a tile (x, z), with tiles listing every tile it stands on when there are several.
local function tilesRound(grid, thing, blocked)
    blocked = blocked or NONE
    local footprint, onThing = thing.tiles or { thing }, {}
    for _, tile in ipairs(footprint) do onThing[grid:index(tile.x, tile.z) or 0] = true end
    local tiles, added = {}, {}
    for _, tile in ipairs(footprint) do
        for _, step in ipairs(STEPS) do
            addTileRound(grid, tiles, added, onThing, blocked, tile.x + step[1], tile.z + step[2])
        end
    end
    if #tiles > 0 then return tiles end
    for _, tile in ipairs(footprint) do
        for aroundZ = tile.z - WIDER, tile.z + WIDER do
            for aroundX = tile.x - WIDER, tile.x + WIDER do
                addTileRound(grid, tiles, added, onThing, blocked, aroundX, aroundZ)
            end
        end
    end
    return tiles
end

-- Returns the nearest of the tiles in a search, and its distance.
local function nearest(found, tiles)
    local best, bestDistance = nil, nil
    for _, tile in ipairs(tiles) do
        local distance = found.distance[tile.index]
        if distance ~= nil and (bestDistance == nil or distance < bestDistance) then
            best, bestDistance = tile, distance
        end
    end
    return best, bestDistance
end

-- Returns a way's tiles reduced to its corners, as routes are drawn.
local function straightPieces(tiles)
    local pieces = {}
    for position, tile in ipairs(tiles) do
        local previous, following = tiles[position - 1], tiles[position + 1]
        local straightOn = previous ~= nil and following ~= nil
            and following.x - tile.x == tile.x - previous.x and following.z - tile.z == tile.z - previous.z
        if not straightOn then pieces[#pieces + 1] = tile end
    end
    return pieces
end

-- Returns the tiles from the search's start to a tile, found by walking back.
-- With stopAt (index -> true), the walk stops at the first tile in it, including that tile, and
-- adds the tiles walked to it.
local function wayBack(found, index, stopAt)
    local backwards = {}
    while index ~= nil and not (stopAt and stopAt[index]) do
        backwards[#backwards + 1] = index
        if stopAt then stopAt[index] = true end
        index = found.parent[index]
    end
    if index ~= nil then backwards[#backwards + 1] = index end
    local tiles, count = {}, #backwards
    for position = count, 1, -1 do
        local x, z = found.grid:tile(backwards[position])
        tiles[count - position + 1] = { x = x, z = z }
    end
    return tiles
end

-- Returns the final route: the ways from the entrance to each reachable node and to the exit (nil for none), as a
-- list of routes, each a list of tiles: the farthest first, whole from the entrance, then each other from where it
-- leaves the tree to its end.
-- Searching each leg apart can find other equally short ways through open ground, which would draw loops and
-- parallel lines, so the ways come from one search and form a tree, with no way drawn twice or alongside another.
-- Nodes shut in by rocks or behind a barrier the final route ignores, and an unreachable exit, are left out, so
-- every piece drawn can be walked.
function Routes.finalRoute(grid, entrance, exit, nodeTiles)
    local found = search(grid, { entrance })
    local targets = {}
    for _, tile in ipairs(nodeTiles) do
        local reached = nearest(found, tilesRound(grid, tile))
        if reached ~= nil then targets[#targets + 1] = reached.index end
    end
    if exit ~= nil then
        -- the exit is an open tile in the forest's edge, so the route ends on it
        local exitIndex = grid:index(exit.x, exit.z)
        local reached = found.distance[exitIndex] ~= nil and { index = exitIndex }
            or nearest(found, tilesRound(grid, exit))
        if reached ~= nil then targets[#targets + 1] = reached.index end
    end
    table.sort(targets, function(first, second)
        local firstDistance, secondDistance = found.distance[first], found.distance[second]
        if firstDistance ~= secondDistance then return firstDistance > secondDistance end
        return first < second
    end)
    local inTree, routes = {}, {}
    for _, index in ipairs(targets) do
        -- from where the way leaves the tree so far, or the entrance, to the end; an end on the way to another
        -- is already drawn
        local tiles = wayBack(found, index, inTree)
        if #tiles >= 2 then routes[#routes + 1] = straightPieces(tiles) end
    end
    return routes
end

-- For the solving plan (src/game/solve_plan.lua), which searches from many places.
Routes.search, Routes.tilesRound, Routes.nearest = search, tilesRound, nearest

-- Returns the route from the start of found (a search with parents) to the nearest of targetTiles (things as
-- tilesRound takes them), avoiding blocked, the tiles the search avoided: its corner tiles and its length in steps, or
-- nil if none can be reached.
function Routes.routeFrom(found, grid, targetTiles, blocked)
    local best, bestDistance = nil, nil
    for _, target in ipairs(targetTiles) do
        local tile, distance = nearest(found, tilesRound(grid, target, blocked))
        if tile ~= nil and (bestDistance == nil or distance < bestDistance) then best, bestDistance = tile, distance end
    end
    if best == nil then return nil end
    return straightPieces(wayBack(found, best.index)), bestDistance
end

-- Returns the route from the tile from to the nearest of targetTiles, avoiding the tiles in blocked.
function Routes.routeTo(grid, from, targetTiles, blocked)
    return Routes.routeFrom(search(grid, { from }, blocked), grid, targetTiles, blocked)
end

-- Returns the route from the tile from toward the grid's centre, which is the forest's, avoiding the tiles in
-- blocked: to the reachable tile nearest the centre (the lowest index of those as near), or nil if none is.
function Routes.routeTowardCentre(grid, from, blocked)
    local found = search(grid, { from }, blocked)
    local centreX, centreZ = grid.minX + grid.width / 2, grid.minZ + grid.length / 2
    local bestIndex, bestDistance = nil, nil
    for index in pairs(found.distance) do
        local x, z = grid:tile(index)
        local distance = (x + 0.5 - centreX) ^ 2 + (z + 0.5 - centreZ) ^ 2
        if bestDistance == nil or distance < bestDistance or (distance == bestDistance and index < bestIndex) then
            bestIndex, bestDistance = index, distance
        end
    end
    if bestIndex == nil then return nil end
    return straightPieces(wayBack(found, bestIndex))
end

return Routes

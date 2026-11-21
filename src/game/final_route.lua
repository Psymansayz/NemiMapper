-- The final route: from the opening the player entered by (the one nearer their first tile) past every node to the
-- other. Redoing it on each node found would cost a search per node, so it is worked out once per forest entry, once
-- the search ends and the grid settles, and kept, which also keeps it unchanged when the map reopens.
-- It is worked out only when first asked for, so not while a route is chosen.

local Forest = require("src/game/forest")
local Routes = require("src/game/routes")
local ForestStops = require("src/game/forest_stops")

local FinalRoute = {}

local workedOut = nil -- the routes worked out for this forest entry

local function workOut()
    local grid, entry = Forest.grid, Forest.entryTile
    local openings = {}
    for _, opening in ipairs(Forest.openings) do openings[#openings + 1] = opening end
    table.sort(openings, function(first, second)
        local firstDistance = math.max(math.abs(first.x - entry.x), math.abs(first.z - entry.z))
        local secondDistance = math.max(math.abs(second.x - entry.x), math.abs(second.z - entry.z))
        return firstDistance < secondDistance
    end)
    -- Nodes and location tasks (the Pahtli plant) stay put.
    -- NPC tasks (the Traitor) walk about, so a route worked out once leaves them out.
    local targets = ForestStops.stopsWhere(function(found)
        local feature = found.feature
        return feature.kind == "node" or (feature.kind == "task" and feature.locations ~= nil)
    end)
    return Routes.finalRoute(grid, openings[1] or entry, openings[2], targets)
end

-- Returns the final route's pieces (Routes.finalRoute), worked out on the first call once it can be.
function FinalRoute.routes()
    if workedOut == nil and Forest.entryTile ~= nil and not Forest.isSearching and Forest.grid ~= nil
        and Forest.grid.settled then
        workedOut = workOut()
    end
    return workedOut
end

-- Drops it, on leaving the forest.
function FinalRoute.forget()
    workedOut = nil
end

return FinalRoute

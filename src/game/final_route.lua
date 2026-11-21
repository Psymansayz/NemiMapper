-- The final route: from the opening the player entered by (the one nearer their first tile) past every node to the
-- other. Redoing it on each node found would cost a search per node, so it is worked out once per forest entry, once
-- the search ends and the grid settles, and kept, which also keeps it unchanged when the map reopens or the player
-- leaves. It is only for sharing, so it is worked out on the next server tick rather than share a frame with
-- NAVIGATE's plan, and only while it is wanted.

local Forest = require("src/game/forest")
local Routes = require("src/game/routes")
local ForestStops = require("src/game/forest_stops")

local FinalRoute = {}

local SUBSCRIPTION = "nemi_mapper_final_route"
local workedOut = nil -- { entry, routes } for the last forest entered, keyed by its entry tile

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
    workedOut = { entry = entry, routes = Routes.finalRoute(grid, openings[1] or entry, openings[2], targets) }
end

local function canWorkOut()
    return Forest.entryTile ~= nil and not Forest.isSearching and Forest.grid ~= nil and Forest.grid.settled
end

-- Returns the final route's pieces (Routes.finalRoute) once worked out for this forest entry. Until then it is worked
-- out on the next server tick, if isWanted() still says so then, and onReady is called.
function FinalRoute.routes(isWanted, onReady)
    if Forest.entryTile == nil then return nil end
    if workedOut ~= nil and workedOut.entry == Forest.entryTile then return workedOut.routes end
    if not canWorkOut() then return nil end
    -- Subscribing again while waiting replaces the same subscription.
    Event.ServerLogic.Subscribe(SUBSCRIPTION, function()
        Event.ServerLogic.Unsubscribe(SUBSCRIPTION)
        if canWorkOut() and isWanted() then
            workOut()
            onReady()
        end
    end)
    return nil
end

-- Stops waiting to work it out, when the map closes.
function FinalRoute.stopWaiting()
    Event.ServerLogic.Unsubscribe(SUBSCRIPTION)
end

-- Drops it, on leaving the forest.
function FinalRoute.forget()
    workedOut = nil
end

return FinalRoute

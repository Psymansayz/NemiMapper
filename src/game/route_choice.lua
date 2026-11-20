-- The route chosen and where it leads: a feature or an entrance sign clicked on the map or in a legend (shown), or
-- a plan (NAVIGATE's mapping or SOLVE's solving). It draws the route on the ground and the beam on its target, map
-- open or not, and keeps the route for the map to draw (drawn). One route is chosen at a time.
-- A search on every step would cost too much, so the route is kept and worked out again only when the forest, the
-- choice or the tools held change or the player strays from it.

local ForestFeatures = require("src/data/forest_features")
local Forest = require("src/game/forest")
local Routes = require("src/game/routes")
local ForestStops = require("src/game/forest_stops")
local SolvePlan = require("src/game/solve_plan")
local Highlights = require("src/game/highlights")
local ToolsHeld = require("src/game/tools_held")
local Settings = require("src/data/settings")

local RouteChoice = {}

local OFF_ROUTE_TILES = 3 -- straying this far from the drawn route recalculates it

RouteChoice.shown = nil -- the key of the feature or sign chosen: a node's, a task's, a puzzle's source key or a sign's
RouteChoice.solving, RouteChoice.mapping = false, false
-- The route, while one is chosen and reachable: { tiles, colour, target, stops (entry -> true), keysUnseen (names),
-- ahead (the tiles still ahead of the player), trimmedX, trimmedZ (where the ground route was last cut back) }.
RouteChoice.drawn = nil
RouteChoice.onDrawn = nil -- called after each update and each cut back of drawn, for the map to draw it (main.lua)

-- What a choice by key leads to: a legend row's feature or a puzzle's key.
local featureOf = {}
for _, list in ipairs({ ForestFeatures.nodes, ForestFeatures.trinksTasks }) do
    for _, feature in ipairs(list) do featureOf[feature.key] = feature end
end
for _, toolPair in ipairs(ForestFeatures.tools) do featureOf[toolPair.source.key] = toolPair.source end

local EMPTY = {}
local waitsFor = nil -- a feature chosen with work left (unclaimed, active), whose choice drops once that is done
local plans = {} -- plan name -> its last next stop, kept while its inputs stay the same
local takenShown = {} -- the keys taken at the last forest change, by source key

function RouteChoice.isChosen()
    return RouteChoice.solving or RouteChoice.mapping or RouteChoice.shown ~= nil
end

-- Returns the next stop of the named plan.
local function plannedStop(name, player, stops, blocked)
    -- The plan is kept whatever the player's tile, until the player leaves the drawn route or its inputs change.
    -- The tools held and the doors gone change the stops or the blocked tiles, so they need no place of their own.
    -- Stops are told apart by found feature, so a key's NPC first seen is a new stop but one that drifts is not.
    local stopsAt, blockedAt = {}, {}
    for _, stop in ipairs(stops) do
        stopsAt[#stopsAt + 1] = tostring(stop.entry) .. stop.kind
            .. (stop.needs and ("<" .. tostring(stop.needs.entry)) or "")
    end
    for index in pairs(blocked) do blockedAt[#blockedAt + 1] = index end
    table.sort(blockedAt)
    local state = table.concat(stopsAt, " ") .. "|" .. table.concat(blockedAt, " ") .. "|" .. tostring(Forest.grid)
    local plan = plans[name]
    if plan == nil or plan.state ~= state then
        local stop, playerSearch = SolvePlan.nextStop(Forest.grid, player, stops, blocked)
        plan = { state = state, stop = stop, search = playerSearch, searchFrom = player }
        plans[name] = plan
    end
    return plan.stop, plan.searchFrom == player and plan.search or nil
end

-- Returns a route's tiles as RouteChoice.drawn, or nil without tiles.
local function drawnRoute(tiles, colour, target, stops, keysUnseen)
    return tiles and { tiles = tiles, colour = colour, target = target, stops = stops, keysUnseen = keysUnseen }
end

-- Returns the chosen route from the player (RouteChoice.drawn).
-- A plan keeps the last route's target (keep) while it is still a stop, so only finishing it, leaving the route or
-- choosing again switch targets.
local function chosenRoute(player, keep)
    local held, blocked = ToolsHeld.held, ForestStops.barrierTiles()
    -- Returns the stops a plan must visit, as entry -> true, with the doors waiting for an unseen key.
    local function stopsOf(plan)
        local entries = {}
        for _, stop in ipairs(plan.stops) do entries[stop.entry] = true end
        for _, door in ipairs(plan.unseenKeyDoors) do entries[door.entry] = true end
        return entries
    end
    -- Returns the route to the next stop of the named plan (ForestStops.stopsToward). With no stop to reach, it goes to
    -- a key another player has, or toward the forest's centre to find the keys not yet seen.
    local function routeByPlan(name, plan)
        local stops = plan.stops
        local stop, playerSearch = ForestStops.keptStop(stops, keep), nil
        if stop == nil then
            stop, playerSearch = plannedStop(name, player, stops, ForestStops.tilesNotInPlan(stops, blocked))
        end
        if stop == nil then
            for _, takenStop in ipairs(ForestStops.takenKeyStops()) do
                if plan.takenKeys[takenStop.entry.feature.key] then
                    local route = Routes.routeTo(Forest.grid, player, { takenStop }, blocked)
                    if route ~= nil then
                        return drawnRoute(route, takenStop.colour, takenStop.entry, { [takenStop.entry] = true })
                    end
                end
            end
            local doors = plan.unseenKeyDoors
            if #doors == 0 then return nil end
            local keysUnseen = {}
            for _, door in ipairs(doors) do keysUnseen[#keysUnseen + 1] = door.entry.feature.pair.source.name end
            return drawnRoute(Routes.routeTowardCentre(Forest.grid, player, blocked), doors[1].colour, nil,
                stopsOf(plan), keysUnseen)
        end
        -- A kept plan's stop has the tiles its NPC was found on, but the route goes to where the NPC is now.
        local target = stop.entry.isNpc and ForestStops.stopOf(stop.entry) or stop
        local route
        if playerSearch ~= nil then
            route = Routes.routeFrom(playerSearch, { target })
        else
            route = Routes.routeTo(Forest.grid, player, { target }, blocked)
        end
        local entries = stopsOf(plan)
        entries[stop.entry] = true
        return drawnRoute(route, stop.colour, stop.entry, entries)
    end

    -- Returns the route to the nearest of targets (stops) past no barrier, or else the named plan's toward the one
    -- nearest with the barriers open.
    local function routeOrPlan(targets, name)
        local route, reached = Routes.routeTo(Forest.grid, player, targets, blocked)
        if route ~= nil then return drawnRoute(route, reached.colour, reached.entry, { [reached.entry] = true }) end
        local openRoute, openReached = Routes.routeTo(Forest.grid, player, targets)
        if openRoute == nil then return nil end
        return routeByPlan(name, ForestStops.stopsToward({ openReached }, player, held))
    end
    local function routeToThing(kind, key)
        return routeOrPlan(ForestStops.stopsOfKind(kind, key), "to " .. key)
    end
    if RouteChoice.mapping then return routeByPlan("nodes", ForestStops.mappingPlan(held)) end
    if RouteChoice.solving then
        return routeByPlan("puzzles", { stops = ForestStops.solveStops(held),
            unseenKeyDoors = ForestStops.unseenKeyDoors(held), takenKeys = Forest.keysTaken })
    end
    for _, sign in ipairs(ForestFeatures.entranceSigns) do
        if sign.key == RouteChoice.shown then
            -- the opening's mouth stands as the route's target
            local opening = ForestStops.openingOn(sign.side)
            if opening == nil then return nil end
            local mouth = { x = opening.x, z = opening.z, tiles = { opening }, kind = "key", colour = sign.colour,
                entry = opening }
            return routeOrPlan({ mouth }, "to " .. sign.key)
        end
    end
    local rowFeature = featureOf[RouteChoice.shown]
    if rowFeature == nil then return nil end
    if not rowFeature.isPuzzle then return routeToThing(rowFeature.kind, rowFeature.key) end
    local toolPair = rowFeature.pair
    if Forest.doorsGone[toolPair.barrier.key] then return nil end
    local target = held[toolPair.source.key] and toolPair.barrier or toolPair.source
    local drawn
    if target == toolPair.source and (Forest.countOf[target.key] or 0) == 0 then
        -- a key not found yet is looked for toward the forest's centre
        drawn = drawnRoute(Routes.routeTowardCentre(Forest.grid, player, blocked), ForestFeatures.colourOf(target),
            nil, {}, { target.name })
    else
        drawn = routeToThing(target.kind, target.key)
    end
    if drawn == nil then return nil end
    -- A puzzle chosen is its key and its door, whichever the route leads to now, so both are its stops.
    for _, entry in ipairs(Forest.found) do
        if entry.feature == toolPair.source or entry.feature == toolPair.barrier then drawn.stops[entry] = true end
    end
    return drawn
end

-- Returns whether a plan has anything left, which is unclaimed nodes for mapping or unfinished puzzles for solving.
-- When not, its choice drops.
local function planHasWork()
    if RouteChoice.mapping then
        -- Keys and barriers the routes to the nodes do not need are not work.
        return #ForestStops.mappingPlan(ToolsHeld.held).stops > 0
    end
    -- A barrier gone is gone for good, so a found one still stands.
    return not RouteChoice.solving or Forest.barriersLeft()
end

-- Works out the chosen route again, with the beam on its target and the route on the ground. With afresh, a plan
-- may switch target; otherwise it keeps its target while that is a stop.
function RouteChoice.update(afresh)
    -- The grid is missing on the tick the player enters, until the forest's first publish.
    if (RouteChoice.mapping or RouteChoice.solving) and Forest.grid ~= nil and Forest.playerTile ~= nil
        and not planHasWork() then
        RouteChoice.mapping, RouteChoice.solving = false, false
    end
    if waitsFor ~= nil and RouteChoice.shown == waitsFor.key and not ForestStops.isWorkLeft(waitsFor) then
        RouteChoice.shown, waitsFor = nil, nil
    end
    local player, drawn = Forest.playerTile, nil
    if Forest.grid ~= nil and player ~= nil and RouteChoice.isChosen() then
        drawn = chosenRoute(player, not afresh and RouteChoice.drawn and RouteChoice.drawn.target or nil)
    end
    RouteChoice.drawn = drawn
    -- An opening is not a feature found, so it gets no beam.
    local target = drawn and drawn.target
    Highlights.showTarget(target and target.feature and target or nil, drawn and drawn.stops or EMPTY)
    Highlights.showRoute(drawn and drawn.tiles, drawn and drawn.colour)
    RouteChoice.onDrawn()
end

-- Chooses one route, clearing the other choices: shown (a feature's or a sign's key), solving or mapping.
function RouteChoice.choose(shown, solving, mapping)
    RouteChoice.shown, RouteChoice.solving, RouteChoice.mapping = shown, solving, mapping
    local feature = featureOf[shown]
    waitsFor = feature ~= nil and ForestStops.isWorkLeft(feature) and feature or nil
    RouteChoice.update(true)
end

-- Chooses a feature's or sign's route, or drops it when it is the one chosen.
function RouteChoice.toggle(key)
    RouteChoice.choose(RouteChoice.shown ~= key and key or nil, false, false)
end

-- Starts NAVIGATE's plan, unless it is on or the map is a shared one, which shows only the final route.
function RouteChoice.startMapping()
    if RouteChoice.mapping or Settings.mapSharingMode then return end
    RouteChoice.choose(nil, false, true)
end

-- Returns where route passes nearest to tile, and the position of the next corner after it.
local function nearestOnRoute(route, tile)
    local bestDistance, bestX, bestZ, bestNext = nil, nil, nil, nil
    for position = 1, #route do
        local from, to = route[position], route[position + 1] or route[position]
        local stepX, stepZ = to.x - from.x, to.z - from.z
        local steps = math.max(math.abs(stepX), math.abs(stepZ))
        stepX, stepZ = stepX > 0 and 1 or stepX < 0 and -1 or 0, stepZ > 0 and 1 or stepZ < 0 and -1 or 0
        for step = 0, steps do
            local x, z = from.x + stepX * step, from.z + stepZ * step
            local distance = math.max(math.abs(x - tile.x), math.abs(z - tile.z))
            if bestDistance == nil or distance < bestDistance then
                bestDistance, bestX, bestZ, bestNext = distance, x, z, position + 1
            end
        end
    end
    -- The last tile is found as the last piece's end, but it is the route's end.
    local last = route[#route]
    if bestX == last.x and bestZ == last.z then bestNext = #route + 1 end
    return bestDistance, { x = bestX, z = bestZ }, bestNext
end

-- Called when the player steps: on the route, what is left of it runs from the tile nearest the player; off it, or
-- with the tools held changed (heldChanged), the route is worked out again.
-- A choice with no route waits for a forest change: only a key not found yet leaves a target out of reach.
function RouteChoice.showPlayer(heldChanged)
    if heldChanged then return RouteChoice.showHeld() end
    local drawn = RouteChoice.drawn
    if drawn == nil then return end
    local distance, routeTile, nextCorner = nearestOnRoute(drawn.tiles, Forest.playerTile)
    if distance > OFF_ROUTE_TILES then
        plans = {}
        return RouteChoice.update(true)
    end
    if nextCorner > #drawn.tiles then return end
    drawn.ahead = { routeTile }
    for position = nextCorner, #drawn.tiles do drawn.ahead[#drawn.ahead + 1] = drawn.tiles[position] end
    -- The ground route is cut back at each tile walked along it (highlights.lua).
    if drawn.trimmedX ~= routeTile.x or drawn.trimmedZ ~= routeTile.z then
        drawn.trimmedX, drawn.trimmedZ = routeTile.x, routeTile.z
        Highlights.trimRoute(drawn.ahead)
        RouteChoice.onDrawn()
    end
end

-- Called when the tools held change without a step: the route follows them, and a plan may switch target.
function RouteChoice.showHeld()
    if RouteChoice.isChosen() then RouteChoice.update(true) end
end

-- Called when the forest changes. A key freed (the player who had it left the forest) may now be on the shortest
-- way, and so may the tools held (heldChanged), so a plan may switch target instead of keeping it.
function RouteChoice.showForest(heldChanged)
    local afresh = heldChanged
    for sourceKey in pairs(takenShown) do
        if not Forest.keysTaken[sourceKey] then afresh = true end
    end
    takenShown = {}
    for sourceKey in pairs(Forest.keysTaken) do takenShown[sourceKey] = true end
    if RouteChoice.isChosen() then RouteChoice.update(afresh) end
end

-- Called when a found NPC (entry) moves: a route leading to it follows it.
function RouteChoice.showNpcMoved(entry)
    if RouteChoice.drawn ~= nil and RouteChoice.drawn.target == entry then RouteChoice.update() end
end

-- Drops the choice and what was kept for it, on leaving the forest.
function RouteChoice.forget()
    RouteChoice.shown, RouteChoice.solving, RouteChoice.mapping, RouteChoice.drawn = nil, false, false, nil
    waitsFor, plans, takenShown = nil, {}, {}
end

return RouteChoice

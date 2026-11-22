-- The route the player has chosen: to a feature or sign clicked, or by a plan (NAVIGATE or SOLVE).

local ForestFeatures = require("src/data/forest_features")
local Forest = require("src/game/forest")
local Routes = require("src/game/routes")
local ForestStops = require("src/game/forest_stops")
local SolvePlan = require("src/game/solve_plan")
local ToolsHeld = require("src/game/tools_held")
local Settings = require("src/data/settings")

local RouteChoice = {}

local OFF_ROUTE_TILES = 3 -- how far the player may stray before the route is worked out again

-- nil, { plan = "navigate" or "solve" }, or { key } of the feature or sign clicked
RouteChoice.choice = nil
-- The chosen route, for the map and the highlights to draw.
RouteChoice.drawn = nil
-- Called when drawn changes, with true when it was only cut back as the player walked (set by main.lua).
RouteChoice.onDrawn = nil

local waitsFor = nil -- Tracks if we should automatically disable the route when the user interacts with it.
local mappingWaits = false -- NAVIGATE starts when the search ends
-- The last plan worked out.
local plan = nil
local takenShown = {} -- the keys other players held at the last forest change

function RouteChoice.isChosen()
    return RouteChoice.choice ~= nil
end

-- Returns whether the plan ("navigate" or "solve") is chosen.
function RouteChoice.isPlanChosen(plan)
    return RouteChoice.choice ~= nil and RouteChoice.choice.plan == plan
end

-- Returns the key of the feature or sign chosen.
function RouteChoice.keyChosen()
    return RouteChoice.choice and RouteChoice.choice.key
end

-- Returns the named plan's next stop.
local function plannedStop(name, player, stops, blocked)
    -- stops go by found feature, so an NPC that moves is still the same stop
    local stopsAt, blockedAt = {}, {}
    for _, stop in ipairs(stops) do
        stopsAt[#stopsAt + 1] = tostring(stop.entry) .. stop.kind .. (stop.optional and "?" or "")
            .. (stop.needs and ("<" .. tostring(stop.needs.entry)) or "")
    end
    for index in pairs(blocked) do blockedAt[#blockedAt + 1] = index end
    table.sort(blockedAt)
    local state = name .. "|" .. table.concat(stopsAt, " ") .. "|" .. table.concat(blockedAt, " ") .. "|"
        .. tostring(Forest.grid)
    if plan == nil or plan.state ~= state then plan = { state = state, remembered = {} } end
    if plan.searchFrom == nil then
        plan.stop, plan.search = SolvePlan.nextStop(Forest.grid, player, stops, blocked, plan.remembered)
        plan.searchFrom = player
    end
    return plan.stop, plan.searchFrom == player and plan.search or nil
end

-- Returns a route as RouteChoice.drawn, or nil when it has no tiles.
local function drawnRoute(tiles, colour, target, stops, unseen)
    return tiles and { tiles = tiles, colour = colour, target = target, stops = stops, unseen = unseen }
end

-- Returns the colour of the route to stop, read each time as the colour settings may change.
local function colourOf(stop)
    local feature = stop.entry.feature
    return feature ~= nil and ForestFeatures.colourOf(feature) or stop.colour
end

-- Returns the chosen route from player, a plan keeping to its last target (keep) while that is still a stop.
local function chosenRoute(player, keep)
    local held, blocked = ToolsHeld.held, ForestStops.barrierTiles()
    -- Returns plan's stops, including the doors whose keys are unseen.
    local function stopsOf(plan)
        local entries = {}
        for _, stop in ipairs(plan.stops) do entries[stop.entry] = true end
        for _, door in ipairs(plan.unseenKeyDoors) do entries[door.entry] = true end
        return entries
    end
    -- Returns a route toward the forest's centre to find the features in unseen.
    local function routeToFind(unseen)
        local names = {}
        for _, feature in ipairs(unseen) do names[#names + 1] = feature.name end
        return drawnRoute(Routes.routeTowardCentre(Forest.grid, player, blocked), ForestFeatures.colourOf(unseen[1]),
            nil, {}, names)
    end
    -- Returns the route to the named plan's next stop, or failing that to a taken key or toward what is unseen.
    local function routeByPlan(name, plan, findTraitor)
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
                        return drawnRoute(route, colourOf(takenStop), takenStop.entry, { [takenStop.entry] = true })
                    end
                end
            end
            local unseen = {}
            for _, door in ipairs(plan.unseenKeyDoors) do unseen[#unseen + 1] = door.entry.feature.pair.source end
            if findTraitor and Forest.isTraitorUnseen() then unseen[#unseen + 1] = ForestFeatures.byKey.traitor end
            if #unseen == 0 then return nil end
            local drawn = routeToFind(unseen)
            if drawn ~= nil then drawn.stops = stopsOf(plan) end
            return drawn
        end
        -- an NPC may have moved since the plan was made
        local target = stop.entry.isNpc and ForestStops.stopOf(stop.entry) or stop
        local route
        if playerSearch ~= nil then
            route = Routes.routeFrom(playerSearch, { target })
        else
            route = Routes.routeTo(Forest.grid, player, { target }, blocked)
        end
        local entries = stopsOf(plan)
        entries[stop.entry] = true
        return drawnRoute(route, colourOf(stop), stop.entry, entries)
    end

    -- Returns the route to the nearest of targets, opening barriers by the named plan only when it must.
    local function routeOrPlan(targets, name)
        local route, reached = Routes.routeTo(Forest.grid, player, targets, blocked)
        if route ~= nil then return drawnRoute(route, colourOf(reached), reached.entry, { [reached.entry] = true }) end
        local openRoute, openReached = Routes.routeTo(Forest.grid, player, targets)
        if openRoute == nil then return nil end
        return routeByPlan(name, ForestStops.stopsToward({ openReached }, player, held))
    end
    local function routeToThing(kind, key)
        return routeOrPlan(ForestStops.stopsOfKind(kind, key), "to " .. key)
    end
    if RouteChoice.isPlanChosen("navigate") then return routeByPlan("nodes", ForestStops.mappingPlan(held), true) end
    if RouteChoice.isPlanChosen("solve") then
        return routeByPlan("puzzles", { stops = ForestStops.solveStops(held),
            unseenKeyDoors = ForestStops.unseenKeyDoors(held), takenKeys = Forest.keysTaken })
    end
    for _, sign in ipairs(ForestFeatures.entranceSigns) do
        if sign.key == RouteChoice.keyChosen() then
            -- the route ends at the opening's mouth
            local opening = ForestStops.openingOn(sign.side)
            if opening == nil then return nil end
            local mouth = { x = opening.x, z = opening.z, tiles = { opening }, kind = "key", colour = sign.colour,
                entry = opening }
            return routeOrPlan({ mouth }, "to " .. sign.key)
        end
    end
    local rowFeature = ForestFeatures.byKey[RouteChoice.keyChosen()]
    if rowFeature == nil then return nil end
    if rowFeature.key == "traitor" and Forest.isTraitorUnseen() then return routeToFind({ rowFeature }) end
    if not rowFeature.isPuzzle then return routeToThing(rowFeature.kind, rowFeature.key) end
    local toolPair = rowFeature.pair
    if Forest.doorsGone[toolPair.barrier.key] then return nil end
    local target = held[toolPair.source.key] and toolPair.barrier or toolPair.source
    local drawn
    if target == toolPair.source and (Forest.countOf[target.key] or 0) == 0 then
        drawn = routeToFind({ target })
    else
        drawn = routeToThing(target.kind, target.key)
    end
    if drawn == nil then return nil end
    -- a chosen puzzle's key and door are both its stops
    for _, entry in ipairs(Forest.found) do
        if entry.feature == toolPair.source or entry.feature == toolPair.barrier then drawn.stops[entry] = true end
    end
    return drawn
end

-- Returns whether the chosen plan has work left; a plan with none is dropped.
local function planHasWork()
    if RouteChoice.isPlanChosen("navigate") then
        return #ForestStops.mappingPlan(ToolsHeld.held).stops > 0 or Forest.isTraitorUnseen()
    end
    return Forest.barriersLeft()
end

-- Works out the chosen route again with new information.
function RouteChoice.update(afresh)
    local choice = RouteChoice.choice
    if choice ~= nil and choice.plan ~= nil and Forest.grid ~= nil and Forest.playerTile ~= nil
        and not planHasWork() then
        RouteChoice.choice = nil
    end
    if waitsFor ~= nil and RouteChoice.keyChosen() == waitsFor.key and not ForestStops.isWorkLeft(waitsFor) then
        RouteChoice.choice, waitsFor = nil, nil
    end
    local player, drawn = Forest.playerTile, nil
    if Forest.grid ~= nil and player ~= nil and RouteChoice.isChosen() then
        drawn = chosenRoute(player, not afresh and RouteChoice.drawn and RouteChoice.drawn.target or nil)
    end
    RouteChoice.drawn = drawn
    RouteChoice.onDrawn(false)
end

-- Makes choice the chosen route, or drops the route with nil.
local function choose(choice)
    RouteChoice.choice, mappingWaits = choice, false
    local feature = choice and ForestFeatures.byKey[choice.key]
    waitsFor = feature ~= nil and ForestStops.isWorkLeft(feature) and feature or nil
    RouteChoice.update(true)
end

function RouteChoice.clear()
    choose(nil)
end

-- Chooses the route to the feature or sign with key, or drops it if already chosen.
function RouteChoice.toggle(key)
    choose(RouteChoice.keyChosen() ~= key and { key = key } or nil)
end

-- Chooses plan ("navigate" or "solve"), or drops it if already chosen.
function RouteChoice.togglePlan(plan)
    choose(not RouteChoice.isPlanChosen(plan) and { plan = plan } or nil)
end

-- Starts NAVIGATE once the forest's search ends
function RouteChoice.startMappingAfterSearch()
    mappingWaits = true
end

-- Returns the route's tile nearest to <tile>
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
    -- nothing comes after the last tile
    local last = route[#route]
    if bestX == last.x and bestZ == last.z then bestNext = #route + 1 end
    return bestDistance, { x = bestX, z = bestZ }, bestNext
end

-- Called on each step: trims the route to what lies ahead, or works it out again once the player strays.
function RouteChoice.showPlayer()
    local drawn = RouteChoice.drawn
    -- a choice with no route waits for the forest to change
    if drawn == nil then return end
    local distance, routeTile, nextCorner = nearestOnRoute(drawn.tiles, Forest.playerTile)
    if distance > OFF_ROUTE_TILES then
        -- only the plan's next stop is worked out again
        if plan ~= nil then plan.searchFrom = nil end
        return RouteChoice.update(true)
    end
    if nextCorner > #drawn.tiles then return end
    drawn.ahead = { routeTile }
    for position = nextCorner, #drawn.tiles do drawn.ahead[#drawn.ahead + 1] = drawn.tiles[position] end
    if drawn.trimmedX ~= routeTile.x or drawn.trimmedZ ~= routeTile.z then
        drawn.trimmedX, drawn.trimmedZ = routeTile.x, routeTile.z
        RouteChoice.onDrawn(true)
    end
end

-- updates the plan when held tools change.
function RouteChoice.showHeld()
    if RouteChoice.isChosen() then RouteChoice.update(true) end
end

-- updates the plan when new information about the forest is found.
function RouteChoice.showForest(heldChanged)
    local afresh = heldChanged
    for sourceKey in pairs(takenShown) do
        if not Forest.keysTaken[sourceKey] then afresh = true end
    end
    takenShown = {}
    for sourceKey in pairs(Forest.keysTaken) do takenShown[sourceKey] = true end
    if RouteChoice.isChosen() then RouteChoice.update(afresh) end
    if mappingWaits and not Forest.isSearching then
        mappingWaits = false
        if not Settings.mapSharingMode then choose({ plan = "navigate" }) end
    end
end

function RouteChoice.showNpcMoved(entry)
    if RouteChoice.drawn ~= nil and RouteChoice.drawn.target == entry then RouteChoice.update() end
end

-- Drops the choice and what was kept for it, on leaving the forest.
function RouteChoice.forget()
    RouteChoice.choice, RouteChoice.drawn = nil, nil
    waitsFor, plan, takenShown, mappingWaits = nil, nil, {}, false
end

return RouteChoice

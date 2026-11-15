-- World highlights chosen in the settings: nodes in their skill's colour, the keys and barriers still to use in
-- their puzzle's colour, the Traitor, the plant, and the target of the route chosen on the map. Each gets a box,
-- and the route's target also gets a beam of light. Only one beam is drawn, as several crash the client.
-- Locations get ShapeEntities, which the client draws at their tile, aligned with the ground, so nothing runs per
-- frame. A moved ShapeEntity is rebuilt late, and moving one crashes the client, so NPCs (the lightning, a goebie,
-- the Traitor) get ShapeInstances instead, moved to the NPC on each logic tick while an NPC is highlighted.
-- An NPC's box has a fixed size because the client's bounds for it change with its animation.

local ForestFeatures = require("src/data/forest_features")
local Forest = require("src/game/forest")
local ToolsHeld = require("src/game/tools_held")
local Settings = require("src/data/settings")
local ForestStops = require("src/game/forest_stops")

local Highlights = {}

local FINE_UNITS_PER_TILE = 512
local LINE_WIDTH = 4.0
local FILL_ALPHA = 0x90 -- the fill at the default transparency
local HEIGHT_OFFSET = 30.0 -- fine units above the ground, to avoid clipping into it
local BOX_HEIGHT = 1200 -- fine units: taller than the tallest node (the obelisk)
local BOX_OUTSET = 300 -- fine units past a thing's tiles on each side: nodes spread past their tiles
local MODEL_OUTSET = 60 -- fine units past a thing's model bounds on each side
local BEAM_HEIGHT = 7000 -- fine units, about fourteen tiles
local BEAM_INSET = 40 -- fine units: keeps the beam's sheets just inside the box
local BEAM_ALPHA = 0xFF -- at the foot; the beam fades out towards the top
local BEAM_TURN_SPEED = 120.0 -- degrees a second, like the game's loot beams
local LOGIC_TICKS_A_SECOND = 50
local SIZE_STEP = 64 -- fine units: bounds are rounded to steps so similar models share a shape
-- The highlighted NPCs (the lightning, the lost goebie, the Traitor) stand on one tile; the box covers just that.
local NPC_BOX_OUTSET = 0 -- fine units past an NPC's tiles on each side
local NPC_BOX_HEIGHT = 1300 -- fine units, unless the feature sets boxHeight
local NPC_RETRY_TICKS = 25 -- logic ticks between searches for an NPC that is out of view
local DRAW_DISTANCE = 64 * FINE_UNITS_PER_TILE -- the whole forest
local TRACK_SUBSCRIPTION = "nemi_mapper_track"
local ENTITY_PREFIX = "nemi_mapper_"
local ROUTE_ENTITY = "nemi_mapper_route"
local ROUTE_HALF_WIDTH = 48 -- fine units each side of the route ribbon's centre line
local ROUTE_HEIGHT_OFFSET = 40.0
local ROUTE_TILES_PER_FRAME = 12 -- the route is drawn over several frames, starting at the player
local ROUTE_BUILD_SUBSCRIPTION = "nemi_mapper_route_build"

-- Entity name -> { entities (by shape kind), colour, sizeKey }, or for an NPC { instances and
-- instanceNames (by shape kind), colour, entry, npcEntity, tilesASide, transparency, atX, atY, atZ, turn }.
local shown = {}
local tracked = {} -- entity name -> NPC highlight, followed on logic ticks
local beamTarget = nil -- the chosen route's target, or nil for no beam
local routeStops = {} -- the chosen route's stops (entry -> true), boxed by their setting
local NONE = {}
-- "<kind>:<size key>" -> ShapeData, whose origin is the middle of the thing's south-west tile.
-- Emptied when the transparency changes, as every shape is then remade.
local shapes = {}
local shapesTransparency = nil

-- Returns the corners of a thing's tiles at a height, moved in by the inset (out, if negative): left-bottom,
-- right-bottom, right-top, left-top.
local function cornersOf(width, length, height, inset)
    local half = FINE_UNITS_PER_TILE / 2
    local left, bottom = -half + inset, -half + inset
    local right, top = width * FINE_UNITS_PER_TILE - half - inset, length * FINE_UNITS_PER_TILE - half - inset
    return { Vector3.new(left, height, bottom), Vector3.new(right, height, bottom), Vector3.new(right, height, top),
        Vector3.new(left, height, top) }
end

local function colours(count, alpha)
    local list = {}
    for index = 1, count do list[index] = 0xFFFFFF00 | alpha end
    return list
end

-- Returns the box fill's alpha for the transparency setting (percent: 0 opaque, 100 invisible).
-- Up to the default it fades from opaque to FILL_ALPHA, then on to nothing.
-- The lines stay solid.
local function fillAlpha()
    local transparency, default = Settings.highlightTransparency, Settings.numbers.highlightTransparency.default
    if transparency <= default then
        return math.floor(0xFF - (0xFF - FILL_ALPHA) * transparency / default + 0.5)
    end
    return math.floor(FILL_ALPHA * (100 - transparency) / (100 - default) + 0.5)
end

-- A box's twelve edges, as pairs of corners.
local BOX_EDGES = { 0, 1, 1, 2, 2, 3, 3, 0, 4, 5, 5, 6, 6, 7, 7, 4, 0, 4, 1, 5, 2, 6, 3, 7 }
-- A box's floor and four sides, two triangles each.
local BOX_FACES = { 0, 1, 2, 0, 2, 3, 0, 1, 5, 0, 5, 4, 1, 2, 6, 1, 6, 5, 2, 3, 7, 2, 7, 6, 3, 0, 4, 3, 4, 7 }
local function boxCorners(floor, roof)
    return { floor[1], floor[2], floor[3], floor[4], roof[1], roof[2], roof[3], roof[4] }
end
local function edgesOf(floor, roof)
    local shape = ShapeData.new()
    shape.positions = boxCorners(floor, roof)
    shape.lines = BOX_EDGES
    return shape
end
local function facesOf(floor, roof)
    local shape = ShapeData.new()
    shape.positions = boxCorners(floor, roof)
    shape.rgba = colours(8, fillAlpha())
    shape.tris = BOX_FACES
    return shape
end

-- Returns a box in one shape: solid edges, see-through floor and sides.
-- Instances draw nothing of such a shape, so they use edgesOf and facesOf as two shapes instead.
local function boxOf(floor, roof)
    local shape = ShapeData.new()
    -- the corners twice: solid ones for the lines, then see-through ones (8 to 15) for the faces
    local positions, rgba = boxCorners(floor, roof), colours(16, fillAlpha())
    for index = 1, 8 do
        positions[8 + index] = positions[index]
        rgba[index] = 0xFFFFFFFF
    end
    local tris = {}
    for index, corner in ipairs(BOX_FACES) do tris[index] = corner + 8 end
    shape.positions, shape.rgba, shape.lines, shape.tris = positions, rgba, BOX_EDGES, tris
    return shape
end

-- Returns a box round a thing's model bounds when known, or round its tiles.
local function boxShape(entry)
    local bounds = entry.bounds
    if bounds == nil then
        return boxOf(cornersOf(entry.width, entry.length, 0, -BOX_OUTSET),
            cornersOf(entry.width, entry.length, entry.feature.boxHeight or BOX_HEIGHT, -BOX_OUTSET))
    end
    local left, right = bounds.x - MODEL_OUTSET, bounds.X + MODEL_OUTSET
    local bottom, top = bounds.z - MODEL_OUTSET, bounds.Z + MODEL_OUTSET
    local function corners(y)
        return { Vector3.new(left, y, bottom), Vector3.new(right, y, bottom), Vector3.new(right, y, top),
            Vector3.new(left, y, top) }
    end
    return boxOf(corners(0), corners(entry.feature.boxHeight or bounds.height + MODEL_OUTSET))
end

-- Returns a beam of light: two tall sheets crossed at the origin, bright at the foot and fading out at the top.
-- It imitates the game's loot beams, which are spot animations a plugin cannot place.
local function beamOf(halfX, halfZ)
    local shape = ShapeData.new()
    shape.positions = {
        Vector3.new(-halfX, 0, 0), Vector3.new(halfX, 0, 0), Vector3.new(halfX, BEAM_HEIGHT, 0),
        Vector3.new(-halfX, BEAM_HEIGHT, 0),
        Vector3.new(0, 0, -halfZ), Vector3.new(0, 0, halfZ), Vector3.new(0, BEAM_HEIGHT, halfZ),
        Vector3.new(0, BEAM_HEIGHT, -halfZ),
    }
    local foot, top = 0xFFFFFF00 | BEAM_ALPHA, 0xFFFFFF00
    shape.rgba = { foot, foot, top, top, foot, foot, top, top }
    -- each sheet is wound both ways so it shows from either side
    shape.tris = { 0, 1, 2, 0, 2, 3, 2, 1, 0, 3, 2, 0, 4, 5, 6, 4, 6, 7, 6, 5, 4, 7, 6, 4 }
    return shape
end

-- Returns a beam as wide as a thing's box; its entity sits at the box's middle.
local function beamShape(entry)
    local bounds = entry.bounds
    if bounds == nil then
        return beamOf(entry.width * FINE_UNITS_PER_TILE / 2 + BOX_OUTSET - BEAM_INSET,
            entry.length * FINE_UNITS_PER_TILE / 2 + BOX_OUTSET - BEAM_INSET)
    end
    return beamOf((bounds.X - bounds.x) / 2 + MODEL_OUTSET - BEAM_INSET,
        (bounds.Z - bounds.z) / 2 + MODEL_OUTSET - BEAM_INSET)
end

local function stepped(value) return math.floor(value / SIZE_STEP) end

-- Returns what a thing's shapes depend on, as a key: its rounded bounds or its tiles, its box
-- height and the transparency.
local function sizeKeyOf(entry)
    local bounds = entry.bounds
    local height = (entry.feature.boxHeight and ("h" .. entry.feature.boxHeight) or "")
        .. "t" .. Settings.highlightTransparency
    if bounds == nil then return entry.width .. "x" .. entry.length .. height end
    return "b" .. stepped(bounds.x) .. "," .. stepped(bounds.X) .. "," .. stepped(bounds.z) .. ","
        .. stepped(bounds.Z) .. "," .. stepped(bounds.height) .. height
end

local SHAPE_MAKERS = { box = boxShape, beam = beamShape }

-- Returns an NPC's shapes, round its tiles (tilesASide, from its config).
-- The origin is the middle of the floor, which the instance's translation puts at the NPC.
-- The box is two shapes: edges and faces.
local function npcBoxCorners(tilesASide, height)
    local half = tilesASide * FINE_UNITS_PER_TILE / 2 + NPC_BOX_OUTSET
    local function corners(y)
        return { Vector3.new(-half, y, -half), Vector3.new(half, y, -half), Vector3.new(half, y, half),
            Vector3.new(-half, y, half) }
    end
    return corners(0), corners(height)
end
local function npcEdgesShape(tilesASide, height) return edgesOf(npcBoxCorners(tilesASide, height)) end
local function npcFacesShape(tilesASide, height) return facesOf(npcBoxCorners(tilesASide, height)) end
local function npcBeamShape(tilesASide)
    local half = tilesASide * FINE_UNITS_PER_TILE / 2 + NPC_BOX_OUTSET - BEAM_INSET
    return beamOf(half, half)
end
local NPC_SHAPE_MAKERS = { box = npcEdgesShape, faces = npcFacesShape, beam = npcBeamShape }

local function shapeFor(kind, entry, sizeKey)
    if shapesTransparency ~= Settings.highlightTransparency then
        shapes, shapesTransparency = {}, Settings.highlightTransparency
    end
    local key = kind .. ":" .. sizeKey
    local shape = shapes[key]
    if shape == nil then
        shape = SHAPE_MAKERS[kind](entry)
        shapes[key] = shape
    end
    return shape
end

-- Returns whether the settings give a thing a box.
-- The chosen route's stops always get one when their switch is on.
-- held is the set of tools held, by source key.
local function boxWanted(entry, held, unneeded)
    if not Settings.highlightInWorld then return false end
    local feature = entry.feature
    -- a key held or a puzzle solved is never highlighted, even as the route's target
    if feature.isPuzzle and not ForestStops.isPuzzleLeft(entry, held) then return false end
    if (routeStops[entry] or beamTarget == entry) and Settings.highlightTarget then return true end
    if feature.kind == "node" then
        return Settings.highlightNodes and (not entry.isUsed or Settings.highlightUsedNodes)
    end
    if feature.isPuzzle then return Settings.highlightPuzzles and not unneeded[entry] end
    return feature.kind == "task" and Settings.highlightTasks and Forest.isTaskActive(feature)
end

local function beamWanted(entry)
    return not Settings.hideTargetBeam and beamTarget == entry
end

-- Returns whether a thing wants a shape of this kind.
-- An NPC's box is two shapes, its edges ("box") and its faces.
local function isWanted(thing, kind)
    if kind == "beam" then return thing.beam end
    return thing.box
end

-- Returns what to highlight now, as [name] = { entry, colour, x, z, box, beam }.
-- held is the set of tools held, looked up when not given.
local function wanted(held)
    local things = {}
    if not Forest.isInside or Forest.playerTile == nil then return things end
    held = held or ToolsHeld.sourceKeys(Forest.playerTile)
    local unneeded = NONE
    if Settings.highlightInWorld and Settings.highlightPuzzles and not Settings.highlightUnneededPuzzles then
        unneeded = ForestStops.unneededNow(held)
    end
    for _, entry in ipairs(Forest.found) do
        local box, beam = boxWanted(entry, held, unneeded), beamWanted(entry)
        if box or beam then
            local feature = entry.feature
            local left, bottom = Forest.southWestOf(entry)
            -- an NPC moves, so its highlight is named by its kind alone
            local name = ENTITY_PREFIX .. feature.key .. (entry.isNpc and "" or ("_" .. left .. "_" .. bottom))
            things[name] = { entry = entry, colour = ForestFeatures.colourOf(feature), x = left, z = bottom, box = box,
                beam = beam }
        end
    end
    return things
end

-- Places a thing's entity: the box at its south-west tile, the beam at the box's middle, its turning axis.
local function placeEntity(entity, kind, level, left, bottom, entry)
    if kind == "beam" then
        local middleX = (left + entry.width / 2) * FINE_UNITS_PER_TILE
        local middleZ = (bottom + entry.length / 2) * FINE_UNITS_PER_TILE
        if entry.bounds ~= nil then
            local tileMiddleX, tileMiddleZ = (left + 0.5) * FINE_UNITS_PER_TILE, (bottom + 0.5) * FINE_UNITS_PER_TILE
            middleX, middleZ = tileMiddleX + (entry.bounds.x + entry.bounds.X) / 2,
                tileMiddleZ + (entry.bounds.z + entry.bounds.Z) / 2
        end
        entity.coordFine = CoordFine.new(level, middleX, middleZ)
    else
        entity.coordGrid = CoordGrid.new(level, left // 64, bottom // 64, left % 64, bottom % 64)
    end
end

-- Makes one entity of a thing's highlight, placed from its south-west tile (thing.x, thing.z).
local function makeEntity(name, kind, thing, level, sizeKey)
    local entry = thing.entry
    local entity = ShapeList.CreateEntity(name .. "_" .. kind)
    entity:SetShapeData(shapeFor(kind, entry, sizeKey))
    placeEntity(entity, kind, level, thing.x, thing.z, entry)
    if kind == "beam" then
        entity.rotationSpeed = BEAM_TURN_SPEED
    elseif ShapeEntityAlignType ~= nil then
        -- the docs name this enum, but it is unconfirmed in game, so it is skipped if missing
        entity.alignType = ShapeEntityAlignType.OBJECT
    end
    entity.heightOffset = HEIGHT_OFFSET
    entity.lineWidth = LINE_WIDTH
    entity:SetDrawDistance(DRAW_DISTANCE)
    entity.colour = thing.colour
    return entity
end

-- Returns the NPC's live entity: the one kept while valid, or the first valid one of its config.
-- The search runs only every NPC_RETRY_TICKS, as it fails every tick while the NPC is out of view.
local function liveNpc(highlight)
    local entity = highlight.npcEntity
    if entity ~= nil and entity.isValid then return entity end
    highlight.npcEntity = nil
    highlight.retryIn = (highlight.retryIn or 0) - 1
    if highlight.retryIn > 0 then return nil end
    highlight.retryIn = NPC_RETRY_TICKS
    for _, candidate in ipairs(NPCList.ByConfigID(highlight.entry.npcID)) do
        if candidate.isValid then
            highlight.npcEntity = candidate
            return candidate
        end
    end
    return nil
end

-- Sets an NPC box's instance's colour and line width, and draws it over the world, as a depth-tested NPC box is hidden
-- by the NPC's model at any size.
local function styleInstance(instance, colour)
    instance.colour = colour
    instance.lineWidth = LINE_WIDTH
    instance.ignoreDepth = true
end

-- One instance of an NPC's highlight, hidden until followTracked shapes and places it. An instance created
-- under the name of one just destroyed is unknown to the client by that name and draws nothing, so each
-- gets a new name.
local instancesMade = 0
local function makeInstance(highlight, name, kind)
    instancesMade = instancesMade + 1
    local instanceName = name .. "_" .. kind .. "_" .. instancesMade
    local instance = ShapeList.CreateInstance(instanceName)
    assert(instance ~= nil, "the client refused an instance named " .. instanceName)
    highlight.instanceNames[kind] = instanceName
    styleInstance(instance, highlight.colour)
    instance.visible = false
    return instance
end

-- Makes the next tick shape and place an NPC's instances.
local function reshapeSoon(highlight)
    highlight.tilesASide, highlight.atX = nil, nil
end

-- Remakes instances the client has dropped.
local function remakeInstances(name, highlight)
    for kind, instance in pairs(highlight.instances) do
        instance:Destroy() -- likely nothing left to destroy, but this releases the handle
        highlight.instances[kind] = makeInstance(highlight, name, kind)
    end
    reshapeSoon(highlight)
end

local INSTANCE_CHECK_TICKS = 25 -- logic ticks between checks that the client still has the instances
local instanceCheckIn = INSTANCE_CHECK_TICKS

-- Runs each logic tick while an NPC is highlighted: moves its shapes to it (hidden while it is out of view),
-- reshapes them when its size changes, and turns the beam. The client sometimes drops live instances, which
-- then draw nothing and are no longer found by name, so they are checked now and then and remade.
local function followTracked()
    instanceCheckIn = instanceCheckIn - 1
    local checkInstances = instanceCheckIn <= 0
    if checkInstances then instanceCheckIn = INSTANCE_CHECK_TICKS end
    local transparency = Settings.highlightTransparency
    for name, highlight in pairs(tracked) do
        if checkInstances then
            for kind in pairs(highlight.instances) do
                if ShapeList.GetInstance(highlight.instanceNames[kind]) == nil then
                    remakeInstances(name, highlight)
                    break
                end
            end
        end
        local entity = liveNpc(highlight)
        if entity == nil then
            if highlight.atX ~= nil then
                highlight.atX = nil
                for _, instance in pairs(highlight.instances) do instance.visible = false end
            end
        else
            local tilesASide = entity.config.gridSize
            if highlight.tilesASide ~= tilesASide or highlight.transparency ~= transparency then
                highlight.tilesASide, highlight.transparency = tilesASide, transparency
                local height = highlight.entry.feature.boxHeight or NPC_BOX_HEIGHT
                for kind, instance in pairs(highlight.instances) do
                    -- a shape the client refuses would draw nothing
                    assert(instance:SetShapeData(NPC_SHAPE_MAKERS[kind](tilesASide, height)),
                        "the client refused the " .. kind .. " shape of an NPC's highlight")
                    -- It is undocumented whether a new shape keeps the style, and a box shaped a tick after it is
                    -- made can go unseen while the beam shows, so it is restyled.
                    styleInstance(instance, highlight.colour)
                end
            end
            local position = entity.position
            local x, y, z = position.x, position.y, position.z
            if highlight.atX ~= x or highlight.atY ~= y or highlight.atZ ~= z then
                highlight.atX, highlight.atY, highlight.atZ = x, y, z
                for _, instance in pairs(highlight.instances) do
                    instance.translation = Vector3.new(x, y, z)
                    instance.visible = true
                end
            end
            if highlight.instances.beam ~= nil then
                highlight.turn = (highlight.turn + BEAM_TURN_SPEED / LOGIC_TICKS_A_SECOND) % 360
                highlight.instances.beam.rotation = Vector3.new(highlight.turn, 0, 0)
            end
        end
    end
end

local function track(name, highlight)
    if next(tracked) == nil then Event.Logic.Subscribe(TRACK_SUBSCRIPTION, followTracked) end
    tracked[name] = highlight
end

local function untrack(name)
    tracked[name] = nil
    if next(tracked) == nil then Event.Logic.Unsubscribe(TRACK_SUBSCRIPTION) end
end

local function destroyHighlight(name, highlight)
    if highlight.instances ~= nil then
        for _, instance in pairs(highlight.instances) do instance:Destroy() end
        untrack(name)
    else
        for _, entity in pairs(highlight.entities) do entity:Destroy() end
    end
    shown[name] = nil
end

-- Makes, places and colours a location's entities as wanted. Its name holds its tile, so only a new shape moves
-- it: bounds can arrive after the box was made, and the beam's place depends on them.
local function refreshEntities(name, thing, level)
    local entry, colour = thing.entry, thing.colour
    local sizeKey = sizeKeyOf(entry)
    local highlight = shown[name]
    if highlight == nil then
        highlight = { entities = {}, colour = colour, sizeKey = sizeKey }
        shown[name] = highlight
    end
    local entities = highlight.entities
    for kind, entity in pairs(entities) do
        if not isWanted(thing, kind) then
            entity:Destroy()
            entities[kind] = nil
        end
    end
    if highlight.colour ~= colour then
        for _, entity in pairs(entities) do entity.colour = colour end
        highlight.colour = colour
    end
    if highlight.sizeKey ~= sizeKey then
        highlight.sizeKey = sizeKey
        for kind, entity in pairs(entities) do
            entity:SetShapeData(shapeFor(kind, entry, sizeKey))
            placeEntity(entity, kind, level, thing.x, thing.z, entry)
        end
    end
    for kind in pairs(SHAPE_MAKERS) do
        if entities[kind] == nil and isWanted(thing, kind) then
            entities[kind] = makeEntity(name, kind, thing, level, sizeKey)
        end
    end
end

-- Makes and colours an NPC's instances as wanted; followTracked shapes and moves them.
local function refreshInstances(name, thing)
    local highlight = shown[name]
    if highlight == nil then
        highlight = { instances = {}, instanceNames = {}, entry = thing.entry, colour = thing.colour, turn = 0 }
        shown[name] = highlight
        track(name, highlight)
    end
    local instances = highlight.instances
    if highlight.colour ~= thing.colour then
        for _, instance in pairs(instances) do instance.colour = thing.colour end
        highlight.colour = thing.colour
    end
    for kind in pairs(NPC_SHAPE_MAKERS) do
        local isWantedNow = isWanted(thing, kind)
        if isWantedNow and instances[kind] == nil then
            instances[kind] = makeInstance(highlight, name, kind)
            reshapeSoon(highlight)
        elseif not isWantedNow and instances[kind] ~= nil then
            instances[kind]:Destroy()
            instances[kind], highlight.instanceNames[kind] = nil, nil
        end
    end
end

-- Makes the world's highlights match what is wanted. held is the set of tools held, if the caller has it.
function Highlights.refresh(held)
    local things = wanted(held)
    for name, highlight in pairs(shown) do
        if things[name] == nil then destroyHighlight(name, highlight) end
    end
    local level = Forest.isInside and Player.GetEntity().coordGrid.level or 0
    for name, thing in pairs(things) do
        if thing.entry.isNpc then refreshInstances(name, thing) else refreshEntities(name, thing, level) end
    end
end

-- Returns whether two sets (key -> anything) hold the same keys.
local function sameKeys(first, second)
    for key in pairs(first) do
        if second[key] == nil then return false end
    end
    for key in pairs(second) do
        if first[key] == nil then return false end
    end
    return true
end

-- Sets the chosen route's target (a found entry, which gets the beam) and its stops (entry -> true, which get boxes),
-- or nil for no route or the final route.
function Highlights.beamOn(entry, stops)
    stops = stops or NONE
    if beamTarget == entry and sameKeys(routeStops, stops) then return end
    beamTarget, routeStops = entry, stops
    Highlights.refresh()
end

local heldShown = {} -- the tools held at the last refresh from a step or an inventory change, by source key

-- Called on each player step and inventory change; refreshes only when the tools held have changed.
function Highlights.followPlayer()
    if not Forest.isInside or Forest.playerTile == nil then return end
    local held = ToolsHeld.sourceKeys(Forest.playerTile)
    if not sameKeys(held, heldShown) then
        heldShown = held
        Highlights.refresh(held)
    end
end

-- A line's width is in pixels, so its ends fall short at the turns. The chosen route is instead drawn on the
-- ground as a flat ribbon with one quad per tile step, so the entity aligns each point to the ground.
-- The route is redrawn only when it changes, a few tiles a frame from the player's end, so no single frame
-- costs much.
local routeEntity = nil
local routeBuild = nil -- { edges, ribbon, drawn } while the route is being drawn

-- The ribbon's edges at each point (tile middles, in fine units): { left, right }. At a turn both steps share
-- the mitre point, so a diagonal meets a straight step flush. The ends extend by half the width.
local MITRE_LEAST = 0.001 -- normals summing shorter than this mean the route doubled back: no mitre
local MITRE_LONGEST = 3 -- half widths: caps a sharp turn's mitre, which would otherwise grow without limit
local function ribbonEdges(points)
    local count = #points
    local directions, edges = {}, {}
    for index = 1, count - 1 do
        local from, to = points[index], points[index + 1]
        local length = math.sqrt((to.x - from.x) ^ 2 + (to.z - from.z) ^ 2)
        directions[index] = { x = (to.x - from.x) / length, z = (to.z - from.z) / length }
    end
    for index = 1, count do
        local before, after, point = directions[index - 1], directions[index], points[index]
        local offsetX, offsetZ, x, z
        local normalX = before and after and -before.z - after.z
        local normalZ = before and after and before.x + after.x
        local size = normalX and math.sqrt(normalX ^ 2 + normalZ ^ 2) or 0
        if size > MITRE_LEAST then
            local reach = math.min(ROUTE_HALF_WIDTH * MITRE_LONGEST,
                ROUTE_HALF_WIDTH / ((normalX * -before.z + normalZ * before.x) / size))
            offsetX, offsetZ, x, z = normalX / size * reach, normalZ / size * reach, point.x, point.z
        elseif before ~= nil and after ~= nil then
            -- doubled back: no mitre, so keep the incoming step's sides
            offsetX, offsetZ, x, z = -before.z * ROUTE_HALF_WIDTH, before.x * ROUTE_HALF_WIDTH, point.x, point.z
        else
            local direction = after or before
            local outward = after ~= nil and -ROUTE_HALF_WIDTH or ROUTE_HALF_WIDTH
            offsetX, offsetZ = -direction.z * ROUTE_HALF_WIDTH, direction.x * ROUTE_HALF_WIDTH
            x, z = point.x + direction.x * outward, point.z + direction.z * outward
        end
        edges[index] = {
            left = Vector3.new(x + offsetX, 0, z + offsetZ), right = Vector3.new(x - offsetX, 0, z - offsetZ),
        }
    end
    return edges
end

-- Adds the ribbon's quads (one a step, visible from both sides) up to edge last and returns its shape. ribbon:
-- { positions, tris, rgba, reached (the last edge drawn to) }.
local QUAD_TRIS = { 0, 1, 2, 0, 2, 3, 2, 1, 0, 3, 2, 0 }
local function ribbonTo(ribbon, edges, last)
    local positions, tris, rgba = ribbon.positions, ribbon.tris, ribbon.rgba
    for index = ribbon.reached, last - 1 do
        local first = #positions
        positions[first + 1], positions[first + 2] = edges[index].left, edges[index].right
        positions[first + 3], positions[first + 4] = edges[index + 1].right, edges[index + 1].left
        for corner = 1, 4 do rgba[first + corner] = 0xFFFFFFFF end
        local firstTri = #tris
        for position, corner in ipairs(QUAD_TRIS) do tris[firstTri + position] = first + corner end
    end
    ribbon.reached = math.max(ribbon.reached, last)
    local shape = ShapeData.new()
    shape.positions, shape.tris, shape.rgba = positions, tris, rgba
    return shape
end

local function newRibbon()
    return { positions = {}, tris = {}, rgba = {}, reached = 1 }
end

local function stopBuilding()
    if routeBuild ~= nil then
        routeBuild = nil
        Event.Draw.Unsubscribe(ROUTE_BUILD_SUBSCRIPTION)
    end
end

-- Draws one more frame's worth of the route.
-- The edges are the whole route's, so the end drawn so far is already mitred for the next step.
local function buildMore()
    local edges = routeBuild.edges
    routeBuild.drawn = math.min(#edges, routeBuild.drawn + ROUTE_TILES_PER_FRAME)
    routeEntity:SetShapeData(ribbonTo(routeBuild.ribbon, edges, routeBuild.drawn))
    if routeBuild.drawn == #edges then stopBuilding() end
end

-- Returns the target's tile nearest a route's last tile, as x, z, or nil if that tile is on the target.
-- Routes end beside a thing, and one more step onto it makes the route look complete.
local function stepOntoTarget(last)
    local entry = beamTarget
    if entry == nil then return nil end
    local left, bottom = Forest.southWestOf(entry)
    local x = math.max(left, math.min(left + entry.width - 1, last.x))
    local z = math.max(bottom, math.min(bottom + entry.length - 1, last.z))
    if x == last.x and z == last.z then return nil end
    return x, z
end

-- Returns a tile as a point in fine units from an origin tile.
local function pointAt(origin, x, z)
    return { x = (x - origin.x) * FINE_UNITS_PER_TILE, z = (z - origin.z) * FINE_UNITS_PER_TILE }
end

-- Every tile of a route given by its corner tiles, plus a step onto the target, as points from an origin tile.
local routeOrigin = nil -- the tile the route entity sits on
local function routePoints(tiles, origin)
    local positions = { pointAt(origin, tiles[1].x, tiles[1].z) }
    for position = 1, #tiles - 1 do
        local from, to = tiles[position], tiles[position + 1]
        local steps = math.max(math.abs(to.x - from.x), math.abs(to.z - from.z))
        local stepX = to.x > from.x and 1 or to.x < from.x and -1 or 0
        local stepZ = to.z > from.z and 1 or to.z < from.z and -1 or 0
        for step = 1, steps do
            positions[#positions + 1] = pointAt(origin, from.x + stepX * step, from.z + stepZ * step)
        end
    end
    local targetX, targetZ = stepOntoTarget(tiles[#tiles])
    if targetX ~= nil then positions[#positions + 1] = pointAt(origin, targetX, targetZ) end
    return positions
end

-- The route last asked for, as a key. The map redraws its routes whenever the forest changes, and the key is kept
-- through trimming, so the same route asked for again (a redraw while the player follows it) leaves the trimmed
-- ribbon alone instead of remaking it.
local routeShownKey = nil

-- Cuts the part behind the player off the drawn route, given the route ahead from the player. The entity is kept,
-- as remaking it each step makes it blink and costs a frame. A route still being drawn is left to finish.
function Highlights.trimRoute(tiles)
    if routeEntity == nil or routeBuild ~= nil or tiles == nil or #tiles == 0 then return end
    local points = routePoints(tiles, routeOrigin)
    -- with only the player's tile left, the ribbon is kept until the route changes
    if #points < 2 then return end
    routeEntity:SetShapeData(ribbonTo(newRibbon(), ribbonEdges(points), #points))
end

local function routeKey(tiles, colour)
    if tiles == nil then return nil end
    local parts = { tostring(colour), tostring(beamTarget) }
    for _, tile in ipairs(tiles) do parts[#parts + 1] = tile.x .. "," .. tile.z end
    return table.concat(parts, " ")
end

function Highlights.showRoute(tiles, colour)
    local key = routeKey(tiles, colour)
    if routeEntity ~= nil and key ~= nil and key == routeShownKey and not Settings.hideRouteInWorld then return end
    routeShownKey = key
    stopBuilding()
    if routeEntity ~= nil then
        routeEntity:Destroy()
        routeEntity = nil
    end
    if tiles == nil or #tiles == 0 or Settings.hideRouteInWorld or not Forest.isInside then return end
    local first = tiles[1]
    local points = routePoints(tiles, first)
    -- just the player's tile, with nothing to step onto
    if #points < 2 then return end
    routeOrigin = first
    local level = Player.GetEntity().coordGrid.level
    routeEntity = ShapeList.CreateEntity(ROUTE_ENTITY)
    routeEntity.coordGrid = CoordGrid.new(level, first.x // 64, first.z // 64, first.x % 64, first.z % 64)
    if ShapeEntityAlignType ~= nil then routeEntity.alignType = ShapeEntityAlignType.MODEL end
    routeEntity.heightOffset = ROUTE_HEIGHT_OFFSET
    -- depth-tested so it is not drawn over the player and NPCs on it; this lets trees hide it too
    routeEntity.ignoreDepth = false
    routeEntity.colour = colour
    routeEntity:SetDrawDistance(DRAW_DISTANCE)
    -- a shape needs at least one step, and the first frame always draws one as #points >= 2
    routeBuild = { edges = ribbonEdges(points), ribbon = newRibbon(), drawn = 0 }
    Event.Draw.Subscribe(ROUTE_BUILD_SUBSCRIPTION, buildMore)
    buildMore()
end

function Highlights.clear()
    Highlights.showRoute(nil)
    for name, highlight in pairs(shown) do destroyHighlight(name, highlight) end
    shapes, shapesTransparency, heldShown = {}, nil, {}
end

return Highlights

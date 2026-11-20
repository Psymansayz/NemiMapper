-- World highlights as chosen in the settings. Each gets a box, and the route's target may get a lootbeam.

local ForestFeatures = require("src/data/forest_features")
local Forest = require("src/game/forest")
local ToolsHeld = require("src/game/tools_held")
local Settings = require("src/data/settings")
local ForestStops = require("src/game/forest_stops")
local RibbonEdges = require("src/game/ribbon_edges")

local Highlights = {}

local FINE_UNITS_PER_TILE = 512
local LINE_WIDTH = 4.0
local HEIGHT_OFFSET = 30.0 -- fine units above the ground, to avoid clipping into it
local MODEL_OUTSET = 60 -- fine units past a feature's model bounds on each side
local BEAM_HEIGHT = 7000 -- fine units, about fourteen tiles
local BEAM_INSET = 40 -- fine units: keeps the beam's sheets just inside the box
local BEAM_ALPHA = 0xFF -- at the foot; the beam fades out towards the top
local BEAM_TURN_SPEED = 120.0 -- degrees a second, like the game's loot beams
local LOGIC_TICKS_A_SECOND = 50
local SIZE_STEP = 64 -- fine units: bounds are rounded to steps so similar models share a shape
local DRAW_DISTANCE = 64 * FINE_UNITS_PER_TILE -- the whole forest
local TRACK_SUBSCRIPTION = "nemi_mapper_track"
local ENTITY_PREFIX = "nemi_mapper_"
local ROUTE_ENTITY = "nemi_mapper_route"
local SEGMENT_ENTITY = "nemi_mapper_route_segment"
local ROUTE_HALF_WIDTH = 48 -- fine units each side of the route ribbon's centre line
local ROUTE_HEIGHT_OFFSET = 40.0
local ROUTE_TILES_PER_FRAME = 12 -- the route is drawn over several frames, starting at the player
local ROUTE_BUILD_SUBSCRIPTION = "nemi_mapper_route_build"

-- Entity name -> { entities (by shape kind), colour, sizeKey }, or for an NPC { instances (by shape kind), colour,
-- entry, transparency, atX, atY, atZ, turn }.
local shown = {}
local tracked = {} -- entity name -> NPC highlight, followed on logic ticks
local beamTarget = nil -- the chosen route's target, or nil for no beam
local routeStops = {} -- the chosen route's stops (entry -> true), boxed by their setting
local NONE = {}
-- "<kind>:<size key>" -> ShapeData, whose origin is the middle of the feature's south-west tile.
local shapes = {}

local function colours(count, alpha)
    local list = {}
    for index = 1, count do list[index] = 0xFFFFFF00 | alpha end
    return list
end

-- Returns the box fill's alpha for the transparency setting (percent: 0 opaque, 100 invisible).
-- The edges stay solid.
local function fillAlpha()
    return math.floor(0xFF * (100 - Settings.highlightTransparency) / 100 + 0.5)
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
    shape.rgba = colours(8, 0xFF)
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

-- Returns the floor and roof corners of the box round a feature's model bounds: left-bottom, right-bottom,
-- right-top, left-top.
local function floorAndRoof(entry)
    local bounds = entry.bounds
    local left, right = bounds.x - MODEL_OUTSET, bounds.X + MODEL_OUTSET
    local bottom, top = bounds.z - MODEL_OUTSET, bounds.Z + MODEL_OUTSET
    local function corners(y)
        return { Vector3.new(left, y, bottom), Vector3.new(right, y, bottom), Vector3.new(right, y, top),
            Vector3.new(left, y, top) }
    end
    return corners(0), corners(entry.feature.boxHeight or bounds.height + MODEL_OUTSET)
end

-- Returns a beam of light as wide as a feature's box: two tall sheets crossed at the origin, bright at the foot and
-- fading out at the top. Its entity sits at the box's middle.
local function beamShape(entry)
    local bounds = entry.bounds
    local halfX = (bounds.X - bounds.x) / 2 + MODEL_OUTSET - BEAM_INSET
    local halfZ = (bounds.Z - bounds.z) / 2 + MODEL_OUTSET - BEAM_INSET
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

local function stepped(value) return math.floor(value / SIZE_STEP) end

-- Returns what a feature's shapes depend on, as a key: its rounded bounds, its box height and the transparency.
local function sizeKeyOf(entry)
    local bounds = entry.bounds
    local height = (entry.feature.boxHeight and ("h" .. entry.feature.boxHeight) or "")
        .. "t" .. Settings.highlightTransparency
    return "b" .. stepped(bounds.x) .. "," .. stepped(bounds.X) .. "," .. stepped(bounds.z) .. ","
        .. stepped(bounds.Z) .. "," .. stepped(bounds.height) .. height
end

local SHAPE_MAKERS = { box = function(entry) return boxOf(floorAndRoof(entry)) end, beam = beamShape }

-- An NPC's shapes. An NPC's box is centred on its tile's middle, which the instance's translation puts at the NPC.
local NPC_SHAPE_MAKERS = {
    box = function(entry) return edgesOf(floorAndRoof(entry)) end,
    faces = function(entry) return facesOf(floorAndRoof(entry)) end,
    beam = beamShape,
}

local function shapeFor(kind, entry, sizeKey)
    local key = kind .. ":" .. sizeKey
    local shape = shapes[key]
    if shape == nil then
        shape = SHAPE_MAKERS[kind](entry)
        shapes[key] = shape
    end
    return shape
end

-- Returns whether the settings give a feature a box.
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

-- Returns what to highlight now, as [name] = { entry, colour, x, z, box, faces, beam }, each kind true when wanted.
-- An NPC's box is drawn as edges (box) and faces.
local function wanted()
    local wantedHighlights = {}
    if not Forest.isInside or Forest.playerTile == nil then return wantedHighlights end
    local held, unneeded = ToolsHeld.held, NONE
    if Settings.highlightInWorld and Settings.highlightPuzzles and not Settings.highlightUnneededPuzzles then
        unneeded = ForestStops.unneededNow(held)
    end
    for _, entry in ipairs(Forest.found) do
        local box, beam = boxWanted(entry, held, unneeded), not Settings.hideTargetBeam and beamTarget == entry
        if box or beam then
            local feature = entry.feature
            local left, bottom = Forest.southWestOf(entry)
            -- an NPC moves, so its highlight is named by its kind alone
            local name = ENTITY_PREFIX .. feature.key .. (entry.isNpc and "" or ("_" .. left .. "_" .. bottom))
            wantedHighlights[name] = { entry = entry, colour = ForestFeatures.colourOf(feature), x = left, z = bottom,
                box = box, faces = box, beam = beam }
        end
    end
    return wantedHighlights
end

-- Makes one entity of a feature's highlight: the box at its south-west tile (wantedHighlight.x, wantedHighlight.z),
-- the beam at the box's middle.
local function makeEntity(name, kind, wantedHighlight, sizeKey)
    local entry, left, bottom = wantedHighlight.entry, wantedHighlight.x, wantedHighlight.z
    local level = Player.GetEntity().coordGrid.level
    local entity = ShapeList.CreateEntity(name .. "_" .. kind)
    entity:SetShapeData(shapeFor(kind, entry, sizeKey))
    if kind == "beam" then
        local bounds = entry.bounds
        entity.coordFine = CoordFine.new(level, (left + 0.5) * FINE_UNITS_PER_TILE + (bounds.x + bounds.X) / 2,
            (bottom + 0.5) * FINE_UNITS_PER_TILE + (bounds.z + bounds.Z) / 2)
        entity.rotationSpeed = BEAM_TURN_SPEED
    else
        entity.coordGrid = CoordGrid.new(level, left // 64, bottom // 64, left % 64, bottom % 64)
        entity.alignType = ShapeEntityAlignType.OBJECT
    end
    entity.heightOffset = HEIGHT_OFFSET
    entity.lineWidth = LINE_WIDTH
    entity:SetDrawDistance(DRAW_DISTANCE)
    entity.colour = wantedHighlight.colour
    return entity
end

-- Returns an NPC instance's colour. The faces take the fill's alpha from it, as an instance's colour multiplies
-- its shape's.
local function instanceColour(kind, colour)
    return kind == "faces" and (colour & 0xFFFFFF00) | fillAlpha() or colour
end

-- One instance of an NPC's highlight in its style, drawn over the world, hidden until followTracked places it.
local function makeInstance(highlight, name, kind)
    local instance = ShapeList.CreateInstance(name .. "_" .. kind)
    instance:SetShapeData(NPC_SHAPE_MAKERS[kind](highlight.entry))
    instance.colour = instanceColour(kind, highlight.colour)
    instance.lineWidth = LINE_WIDTH
    instance.ignoreDepth = true
    instance.visible = false
    return instance
end

-- Runs each logic tick while an NPC is highlighted: moves its shapes to it, hidden while it is out of view, and
-- turns its beam.
local function followTracked()
    for _, highlight in pairs(tracked) do
        -- the live entity the forest keeps (forest.lua's followNpcs)
        local entity = highlight.entry.npcEntity
        if not entity.isValid then
            if highlight.atX ~= nil then
                highlight.atX = nil
                for _, instance in pairs(highlight.instances) do instance.visible = false end
            end
        else
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

-- Makes, places and colours a location's entities.
local function refreshEntities(name, wantedHighlight)
    local entry, colour = wantedHighlight.entry, wantedHighlight.colour
    local sizeKey = sizeKeyOf(entry)
    local highlight = shown[name]
    if highlight == nil then
        highlight = { entities = {}, colour = colour, sizeKey = sizeKey }
        shown[name] = highlight
    end
    local entities = highlight.entities
    for kind, entity in pairs(entities) do
        if not wantedHighlight[kind] then
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
        for kind, entity in pairs(entities) do entity:SetShapeData(shapeFor(kind, entry, sizeKey)) end
    end
    for kind in pairs(SHAPE_MAKERS) do
        if entities[kind] == nil and wantedHighlight[kind] then
            entities[kind] = makeEntity(name, kind, wantedHighlight, sizeKey)
        end
    end
end

-- Makes and colours an NPC's instances.
local function refreshInstances(name, wantedHighlight)
    local highlight = shown[name]
    local transparency = Settings.highlightTransparency
    if highlight == nil then
        highlight = { instances = {}, entry = wantedHighlight.entry, colour = wantedHighlight.colour, turn = 0,
            transparency = transparency }
        shown[name] = highlight
        track(name, highlight)
    end
    local instances = highlight.instances
    -- only the faces are see-through, by the transparency setting
    if highlight.colour ~= wantedHighlight.colour or highlight.transparency ~= transparency then
        highlight.colour, highlight.transparency = wantedHighlight.colour, transparency
        for kind, instance in pairs(instances) do instance.colour = instanceColour(kind, highlight.colour) end
    end
    for kind in pairs(NPC_SHAPE_MAKERS) do
        local isWantedNow = wantedHighlight[kind]
        if isWantedNow and instances[kind] == nil then
            instances[kind] = makeInstance(highlight, name, kind)
            -- the next tick places it
            highlight.atX = nil
        elseif not isWantedNow and instances[kind] ~= nil then
            instances[kind]:Destroy()
            instances[kind] = nil
        end
    end
end

-- Makes the world's highlights match what the settings ask for.
function Highlights.refresh()
    local wantedHighlights = wanted()
    for name, highlight in pairs(shown) do
        if wantedHighlights[name] == nil then destroyHighlight(name, highlight) end
    end
    for name, wantedHighlight in pairs(wantedHighlights) do
        if wantedHighlight.entry.isNpc then
            refreshInstances(name, wantedHighlight)
        else
            refreshEntities(name, wantedHighlight)
        end
    end
end

function Highlights.beamOn(entry, stops)
    if beamTarget == entry and ForestStops.sameSet(routeStops, stops) then return end
    beamTarget, routeStops = entry, stops
    Highlights.refresh()
end

-- A line's width is in pixels, so its ends fall short at the turns. The chosen route is instead drawn on the
-- ground as a flat ribbon with one quad per tile step, so the entity aligns each point to the ground.
-- The first route is drawn a few tiles a frame from the player's end, so no single frame costs much; a new route
-- takes its place in one step, and walking cuts it back tile by tile.
local routeEntity = nil -- the route, or once the player follows it, the part past the straight run they are on
local segmentEntity = nil -- the straight run the player is on, while a corner lies ahead of it
local routeColour = nil
local routeBuild = nil -- { edges, ribbon, drawn } while the route is being drawn

-- The ribbon's edges at each point (tile middles, in fine units): { left, right }.
local function ribbonEdges(points)
    local count, pointX, pointZ = #points, {}, {}
    for index, point in ipairs(points) do pointX[index], pointZ[index] = point.x, point.z end
    local leftX, leftZ, rightX, rightZ = {}, {}, {}, {}
    RibbonEdges.fill(pointX, pointZ, count, ROUTE_HALF_WIDTH, false, {}, {}, leftX, leftZ, rightX, rightZ)
    local edges = {}
    for index = 1, count do
        edges[index] = {
            left = Vector3.new(leftX[index], 0, leftZ[index]), right = Vector3.new(rightX[index], 0, rightZ[index]),
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

-- Returns the shape of the ribbon's quads from edge first to edge last.
local function ribbonBetween(edges, first, last)
    local ribbon = newRibbon()
    ribbon.reached = first
    return ribbonTo(ribbon, edges, last)
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
-- Routes end beside a feature, and one more step onto it makes the route look complete.
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

local function stepsBetween(from, to) return math.max(math.abs(to.x - from.x), math.abs(to.z - from.z)) end

local routeOrigin = nil -- the tile the route entity sits on
-- Every tile of a route given by its corner tiles, plus a step onto the target, as points from an origin tile;
-- with upTo, only its first upTo points.
local function routePoints(tiles, origin, upTo)
    upTo = upTo or math.huge
    local positions = { pointAt(origin, tiles[1].x, tiles[1].z) }
    for position = 1, #tiles - 1 do
        local from, to = tiles[position], tiles[position + 1]
        local stepX = to.x > from.x and 1 or to.x < from.x and -1 or 0
        local stepZ = to.z > from.z and 1 or to.z < from.z and -1 or 0
        for step = 1, stepsBetween(from, to) do
            if #positions >= upTo then return positions end
            positions[#positions + 1] = pointAt(origin, from.x + stepX * step, from.z + stepZ * step)
        end
    end
    local targetX, targetZ = stepOntoTarget(tiles[#tiles])
    if targetX ~= nil and #positions < upTo then positions[#positions + 1] = pointAt(origin, targetX, targetZ) end
    return positions
end

-- The route last asked for, as a key. The route is worked out again whenever the forest changes, and the key is kept
-- through trimming, so the same route asked for again (while the player follows it) leaves the trimmed ribbon alone
-- instead of remaking it.
local routeShownKey = nil

-- Returns a new entity for the route on its origin tile, in its style.
local function newRouteEntity(name)
    local origin, level = routeOrigin, Player.GetEntity().coordGrid.level
    local entity = ShapeList.CreateEntity(name)
    entity.coordGrid = CoordGrid.new(level, origin.x // 64, origin.z // 64, origin.x % 64, origin.z % 64)
    entity.alignType = ShapeEntityAlignType.MODEL
    entity.heightOffset = ROUTE_HEIGHT_OFFSET
    entity.ignoreDepth = false
    entity.colour = routeColour
    entity:SetDrawDistance(DRAW_DISTANCE)
    return entity
end

local function dropSegment()
    if segmentEntity ~= nil then
        segmentEntity:Destroy()
        segmentEntity = nil
    end
end

local restShownKey = nil -- the corner and the corners after it that routeEntity shows, once trimmed

-- Cuts the part behind the player off the drawn route at each tile walked, given the route ahead from the player
-- (its corner tiles, at least two, or one with a step onto the target). Only the straight run the player is on
-- changes from tile to tile, so it is an entity of its own, reshaped each step, and the rest is reshaped only as a
-- corner is passed. Entities are kept rather than remade, as remaking one makes it blink and costs a frame. A route
-- still being drawn is left to finish.
function Highlights.trimRoute(tiles)
    if routeEntity == nil or routeBuild ~= nil then return end
    -- the point where the run the player is on ends, at the first corner that is not the player's own tile
    local cornerAt, corner = 1, nil
    for position = 1, #tiles - 1 do
        cornerAt = cornerAt + stepsBetween(tiles[position], tiles[position + 1])
        if cornerAt > 1 then
            corner = position + 1
            break
        end
    end
    local restKey = corner and (tiles[corner].x .. "," .. tiles[corner].z .. "/" .. (#tiles - corner))
    -- Only the run changes from step to step, so the rest's points are worked out only when it changes too.
    -- The point after the corner gives the corner's mitre.
    local points = routePoints(tiles, routeOrigin, restKey == restShownKey and cornerAt + 1 or nil)
    local edges = ribbonEdges(points)
    -- on the last run, one entity holds what is left
    if corner == nil or cornerAt >= #points then
        dropSegment()
        restShownKey = nil
        routeEntity:SetShapeData(ribbonBetween(edges, 1, #points))
        return
    end
    -- Both parts take the corner's mitred edge from the same edges, so they meet flush.
    if restKey ~= restShownKey then
        restShownKey = restKey
        routeEntity:SetShapeData(ribbonBetween(edges, cornerAt, #points))
    end
    if segmentEntity == nil then segmentEntity = newRouteEntity(SEGMENT_ENTITY) end
    segmentEntity:SetShapeData(ribbonBetween(edges, 1, cornerAt))
end

local function routeKey(tiles, colour)
    if tiles == nil then return nil end
    local parts = { tostring(colour), tostring(beamTarget) }
    for _, tile in ipairs(tiles) do parts[#parts + 1] = tile.x .. "," .. tile.z end
    return table.concat(parts, " ")
end

-- Draws the chosen route on the ground. A route already drawn takes the new one's shape in
-- place, its entities kept and its origin tile too, so what both routes share is drawn where it was.
-- Only the first route is made from scratch, a few tiles a frame.
function Highlights.showRoute(tiles, colour)
    local key = routeKey(tiles, colour)
    if routeEntity ~= nil and key == routeShownKey and not Settings.hideRouteInWorld then return end
    routeShownKey, restShownKey = key, nil
    stopBuilding()
    local visible = tiles ~= nil and not Settings.hideRouteInWorld
    -- with only the player's tile left and no step onto the target, the ribbon is kept until the route changes
    if visible and routeEntity ~= nil and (#tiles >= 2 or stepOntoTarget(tiles[1]) ~= nil) then
        if routeColour ~= colour then
            routeColour = colour
            routeEntity.colour = colour
            if segmentEntity ~= nil then segmentEntity.colour = colour end
        end
        return Highlights.trimRoute(tiles)
    end
    dropSegment()
    if routeEntity ~= nil then
        routeEntity:Destroy()
        routeEntity = nil
    end
    if not visible then return end
    local first = tiles[1]
    local points = routePoints(tiles, first)
    -- just the player's tile, with nothing to step onto
    if #points < 2 then return end
    routeOrigin, routeColour = first, colour
    routeEntity = newRouteEntity(ROUTE_ENTITY)
    -- a shape needs at least one step, and the first frame always draws one as #points >= 2
    routeBuild = { edges = ribbonEdges(points), ribbon = newRibbon(), drawn = 0 }
    Event.Draw.Subscribe(ROUTE_BUILD_SUBSCRIPTION, buildMore)
    buildMore()
end

function Highlights.clear()
    Highlights.showRoute(nil)
    for name, highlight in pairs(shown) do destroyHighlight(name, highlight) end
    shapes = {}
end

return Highlights

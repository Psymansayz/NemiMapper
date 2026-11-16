-- World highlights as chosen in the settings. Each gets a box, and the route's target may get a lootbeam.

local ForestFeatures = require("src/data/forest_features")
local Forest = require("src/game/forest")
local ToolsHeld = require("src/game/tools_held")
local Settings = require("src/data/settings")
local ForestStops = require("src/game/forest_stops")

local Highlights = {}

local FINE_UNITS_PER_TILE = 512
local LINE_WIDTH = 4.0
local HEIGHT_OFFSET = 30.0 -- fine units above the ground, to avoid clipping into it
local BOX_HEIGHT = 1200 -- fine units: taller than the tallest node (the obelisk)
local BOX_OUTSET = 300 -- fine units past a feature's tiles on each side: nodes spread past their tiles
local MODEL_OUTSET = 60 -- fine units past a feature's model bounds on each side
local BEAM_HEIGHT = 7000 -- fine units, about fourteen tiles
local BEAM_INSET = 40 -- fine units: keeps the beam's sheets just inside the box
local BEAM_ALPHA = 0xFF -- at the foot; the beam fades out towards the top
local BEAM_TURN_SPEED = 120.0 -- degrees a second, like the game's loot beams
local LOGIC_TICKS_A_SECOND = 50
local SIZE_STEP = 64 -- fine units: bounds are rounded to steps so similar models share a shape
-- The highlighted NPCs (the lightning, the lost goebie, the Traitor) stand on one tile; the box covers just that.
local NPC_BOX_OUTSET = 0 -- fine units past an NPC's tiles on each side
local NPC_BOX_HEIGHT = 1300 -- fine units, unless the feature sets boxHeight
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
-- entry, npcEntity, tilesASide, lastTilesASide, transparency, atX, atY, atZ, turn }.
local shown = {}
local tracked = {} -- entity name -> NPC highlight, followed on logic ticks
local beamTarget = nil -- the chosen route's target, or nil for no beam
local routeStops = {} -- the chosen route's stops (entry -> true), boxed by their setting
local NONE = {}
-- "<kind>:<size key>" -> ShapeData, whose origin is the middle of the feature's south-west tile.
-- Emptied when the transparency changes, as every shape is then remade.
local shapes = {}
local shapesTransparency = nil

-- Returns the corners of a feature's tiles at a height, moved in by the inset (out, if negative): left-bottom,
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

-- Returns a box round a feature's model bounds when known, or round its tiles.
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

-- Returns a beam as wide as a feature's box; its entity sits at the box's middle.
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

-- Returns what a feature's shapes depend on, as a key: its rounded bounds or its tiles, its box
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

local function beamWanted(entry)
    return not Settings.hideTargetBeam and beamTarget == entry
end

-- Returns whether a wanted highlight has a beam or box.
local function isWanted(wantedHighlight, kind)
    if kind == "beam" then return wantedHighlight.beam end
    return wantedHighlight.box
end

-- Returns what to highlight now, as [name] = { entry, colour, x, z, box, beam }.
local function wanted(held)
    local wantedHighlights = {}
    if not Forest.isInside or Forest.playerTile == nil then return wantedHighlights end
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
            wantedHighlights[name] = { entry = entry, colour = ForestFeatures.colourOf(feature), x = left, z = bottom,
                box = box, beam = beam }
        end
    end
    return wantedHighlights
end

-- Places a feature's entity: the box at its south-west tile, the beam at the box's middle.
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

-- Makes one entity of a feature's highlight, placed from its south-west tile (wantedHighlight.x, wantedHighlight.z).
local function makeEntity(name, kind, wantedHighlight, level, sizeKey)
    local entry = wantedHighlight.entry
    local entity = ShapeList.CreateEntity(name .. "_" .. kind)
    entity:SetShapeData(shapeFor(kind, entry, sizeKey))
    placeEntity(entity, kind, level, wantedHighlight.x, wantedHighlight.z, entry)
    if kind == "beam" then
        entity.rotationSpeed = BEAM_TURN_SPEED
    elseif ShapeEntityAlignType ~= nil then
        entity.alignType = ShapeEntityAlignType.OBJECT
    end
    entity.heightOffset = HEIGHT_OFFSET
    entity.lineWidth = LINE_WIDTH
    entity:SetDrawDistance(DRAW_DISTANCE)
    entity.colour = wantedHighlight.colour
    return entity
end

-- Returns the NPC's live entity.
-- While the NPC is out of view the search would fail, so it runs again only once NPCs have arrived.
local function liveNpc(highlight)
    local entity = highlight.npcEntity
    if entity ~= nil and entity.isValid then return entity end
    highlight.npcEntity = nil
    if highlight.searchedAt == Forest.npcArrivals then return nil end
    highlight.searchedAt = Forest.npcArrivals
    for _, candidate in ipairs(NPCList.ByConfigID(highlight.entry.npcID)) do
        if candidate.isValid then
            highlight.npcEntity = candidate
            return candidate
        end
    end
    return nil
end

-- Sets an NPC box's instance's colour and line width, and draws it over the world
local function styleInstance(instance, colour)
    instance.colour = colour
    instance.lineWidth = LINE_WIDTH
    instance.ignoreDepth = true
end

-- Shapes an NPC's instance round tilesASide tiles, in its highlight's style.
local function shapeInstance(instance, highlight, kind, tilesASide)
    local height = highlight.entry.feature.boxHeight or NPC_BOX_HEIGHT
    instance:SetShapeData(NPC_SHAPE_MAKERS[kind](tilesASide, height))
    styleInstance(instance, highlight.colour)
end

-- One instance of an NPC's highlight, hidden until followTracked places it.
local instancesMade = 0
local function makeInstance(highlight, name, kind)
    instancesMade = instancesMade + 1
    local instance = ShapeList.CreateInstance(name .. "_" .. kind .. "_" .. instancesMade)
    shapeInstance(instance, highlight, kind, highlight.lastTilesASide or 1)
    instance.visible = false
    return instance
end

-- Makes the next tick shape and place an NPC's instances.
local function reshapeSoon(highlight)
    highlight.tilesASide, highlight.atX = nil, nil
end

-- Runs each logic tick while an NPC is highlighted: moves its shapes to it (hidden while it is out of view),
local function followTracked()
    local transparency = Settings.highlightTransparency
    for _, highlight in pairs(tracked) do
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
                highlight.lastTilesASide = tilesASide
                for kind, instance in pairs(highlight.instances) do
                    shapeInstance(instance, highlight, kind, tilesASide)
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

-- Makes, places and colours a location's entities.
local function refreshEntities(name, wantedHighlight, level)
    local entry, colour = wantedHighlight.entry, wantedHighlight.colour
    local sizeKey = sizeKeyOf(entry)
    local highlight = shown[name]
    if highlight == nil then
        highlight = { entities = {}, colour = colour, sizeKey = sizeKey }
        shown[name] = highlight
    end
    local entities = highlight.entities
    for kind, entity in pairs(entities) do
        if not isWanted(wantedHighlight, kind) then
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
        if entities[kind] == nil and isWanted(wantedHighlight, kind) then
            entities[kind] = makeEntity(name, kind, wantedHighlight, level, sizeKey)
        end
    end
end

-- Makes and colours an NPC's instances;
local function refreshInstances(name, wantedHighlight)
    local highlight = shown[name]
    if highlight == nil then
        highlight = { instances = {}, entry = wantedHighlight.entry, colour = wantedHighlight.colour, turn = 0 }
        shown[name] = highlight
        track(name, highlight)
    end
    local instances = highlight.instances
    if highlight.colour ~= wantedHighlight.colour then
        for _, instance in pairs(instances) do instance.colour = wantedHighlight.colour end
        highlight.colour = wantedHighlight.colour
    end
    for kind in pairs(NPC_SHAPE_MAKERS) do
        local isWantedNow = isWanted(wantedHighlight, kind)
        if isWantedNow and instances[kind] == nil then
            instances[kind] = makeInstance(highlight, name, kind)
            reshapeSoon(highlight)
        elseif not isWantedNow and instances[kind] ~= nil then
            instances[kind]:Destroy()
            instances[kind] = nil
        end
    end
end

-- Makes the world's highlights match what the settings.
function Highlights.refresh(held)
    local wantedHighlights = wanted(held)
    for name, highlight in pairs(shown) do
        if wantedHighlights[name] == nil then destroyHighlight(name, highlight) end
    end
    for name, highlight in pairs(shown) do
        local made = highlight.entities or highlight.instances
        if made.beam ~= nil and not wantedHighlights[name].beam then
            made.beam:Destroy()
            made.beam = nil
        end
    end
    local level = Forest.isInside and Player.GetEntity().coordGrid.level or 0
    for name, wantedHighlight in pairs(wantedHighlights) do
        if wantedHighlight.entry.isNpc then
            refreshInstances(name, wantedHighlight)
        else
            refreshEntities(name, wantedHighlight, level)
        end
    end
end

function Highlights.beamOn(entry, stops)
    stops = stops or NONE
    if beamTarget == entry and ForestStops.sameSet(routeStops, stops) then return end
    beamTarget, routeStops = entry, stops
    Highlights.refresh()
end

local heldShown = {} -- the tools held at the last refresh from a step or an inventory change, by source key

-- Called on each player step and inventory change; refreshes only when the tools held have changed.
function Highlights.followPlayer()
    if not Forest.isInside or Forest.playerTile == nil then return end
    local held = ToolsHeld.sourceKeys(Forest.playerTile)
    if not ForestStops.sameSet(held, heldShown) then
        heldShown = held
        Highlights.refresh(held)
    end
end

-- A line's width is in pixels, so its ends fall short at the turns. The chosen route is instead drawn on the
-- ground as a flat ribbon with one quad per tile step, so the entity aligns each point to the ground.
-- The first route is drawn a few tiles a frame from the player's end, so no single frame costs much; a new route
-- takes its place in one step, and walking cuts it back tile by tile.
local routeEntity = nil -- the route, or once the player follows it, the part past the straight run they are on
local segmentEntity = nil -- the straight run the player is on, while a corner lies ahead of it
local routeColour = nil
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

-- Returns a new entity for the route on its origin tile, in its style.
local function newRouteEntity(name)
    local origin, level = routeOrigin, Player.GetEntity().coordGrid.level
    local entity = ShapeList.CreateEntity(name)
    entity.coordGrid = CoordGrid.new(level, origin.x // 64, origin.z // 64, origin.x % 64, origin.z % 64)
    if ShapeEntityAlignType ~= nil then entity.alignType = ShapeEntityAlignType.MODEL end
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
-- (its corner tiles). Only the straight run the player is on changes from tile to tile, so it is an entity of its
-- own, reshaped each step, and the rest is reshaped only as a corner is passed. Entities are kept rather than
-- remade, as remaking one makes it blink and costs a frame. A route still being drawn is left to finish.
function Highlights.trimRoute(tiles)
    if routeEntity == nil or routeBuild ~= nil or tiles == nil or #tiles == 0 then return end
    local points = routePoints(tiles, routeOrigin)
    -- with only the player's tile left, the ribbon is kept until the route changes
    if #points < 2 then return end
    local edges = ribbonEdges(points)
    -- the point where the run the player is on ends, at the first corner that is not the player's own tile
    local cornerAt, corner = 1, nil
    for position = 1, #tiles - 1 do
        local from, to = tiles[position], tiles[position + 1]
        cornerAt = cornerAt + math.max(math.abs(to.x - from.x), math.abs(to.z - from.z))
        if cornerAt > 1 then
            corner = position + 1
            break
        end
    end
    -- on the last run, one entity holds what is left
    if corner == nil or cornerAt >= #points then
        dropSegment()
        restShownKey = nil
        routeEntity:SetShapeData(ribbonBetween(edges, 1, #points))
        return
    end
    -- Both parts take the corner's mitred edge from the whole route's, so they meet flush.
    local restKey = tiles[corner].x .. "," .. tiles[corner].z .. "/" .. (#tiles - corner)
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
-- place, its entities kept and its origin tile too, so what both routes share is drawn where it was
-- Only the first route is made from scratch, a few tiles a frame.
function Highlights.showRoute(tiles, colour)
    local key = routeKey(tiles, colour)
    if routeEntity ~= nil and key ~= nil and key == routeShownKey and not Settings.hideRouteInWorld then return end
    routeShownKey, restShownKey = key, nil
    stopBuilding()
    local shown = tiles ~= nil and #tiles > 0 and not Settings.hideRouteInWorld and Forest.isInside
    if shown and routeEntity ~= nil and #routePoints(tiles, routeOrigin) >= 2 then
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
    if tiles == nil or #tiles == 0 or Settings.hideRouteInWorld or not Forest.isInside then return end
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
    shapes, shapesTransparency, heldShown = {}, nil, {}
end

return Highlights

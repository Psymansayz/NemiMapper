-- The map itself, in the window's frame: the zones' pictures, the routes, a marker per found feature shown, the
-- entrance signs and the player, clipped at its edges. It draws the route chosen (src/game/route_choice.lua), or the
-- final route when none is chosen.
-- Its functions take the map window's parts (map), whose isOpen is the map window's.

local ForestFeatures = require("src/data/forest_features")
local IconSizes = require("src/data/icon_sizes")
local Forest = require("src/game/forest")
local FinalRoute = require("src/game/final_route")
local ForestStops = require("src/game/forest_stops")
local RibbonEdges = require("src/game/ribbon_edges")
local RouteChoice = require("src/game/route_choice")
local Sets = require("src/game/sets")
local ToolsHeld = require("src/game/tools_held")
local Settings = require("src/data/settings")
local ComponentWrites = require("src/ui/component_writes")
local MapWidgets = require("src/ui/map_widgets")
local MapView = require("src/ui/map_view")
local StatusText = require("src/ui/status_text")

local MapLayer = {}

local setBox, setHidden = ComponentWrites.setBox, ComponentWrites.setHidden
local view = MapView.view

local PACK_MAP_SIZE = 685 -- the pack's map width, at which the icons are drawn at their own size
local ZONE_SIZE = 8 -- tiles
local ROUTE_WIDTH = 7 -- in pack pixels, like the icons
local PLAYER_SIZE = 10
local HOVER_SCALE = 1.25 -- a map icon under the mouse grows by this, about its centre
local FOREST_COLOUR = 0xB98967FF -- under the zones: the open zones' average ground colour
local FINAL_ROUTE_COLOUR = 0xF4F1E6FF
local PLAYER_COLOUR = 0xFF3B30FF
local TEXT_HEIGHT = MapWidgets.TEXT_HEIGHT
local EMPTY = {}

-- Returns the icons' scale on a map of mapSize, drawn at their own size on the pack's.
function MapLayer.iconScale(mapSize)
    return mapSize / PACK_MAP_SIZE
end

-- Returns a forest point (in tiles) as map-layer pixels, north up.
local function tileOnMap(map, x, z)
    local bounds, mapSize = Forest.bounds, map.frame.mapSize
    return math.floor((x - bounds.minX) * mapSize / bounds.width + 0.5),
        math.floor((bounds.minZ + bounds.length - z) * mapSize / bounds.length + 0.5)
end

-- Returns whether the map is hidden, as its X only hides it while a legend's own window is shown. Its zones, routes,
-- markers and player then wait (mapStale) until it shows again, while the legends' windows keep up.
function MapLayer.isHidden(map)
    if map.window.root.hidden ~= true then return false end
    map.mapStale = true
    return true
end

-- Places one sprite per zone, showing the zone it was copied from, turned as the grid has it.
local function placeZones(map)
    local turns = Forest.zoneTurns
    for index, zone in ipairs(Forest.zones) do
        local shown = map.zones[index]
        if shown == nil then
            shown = { sprite = MapWidgets.create(ui.Sprite, map.zoneLayer) }
            map.zones[index] = shown
        end
        local sprite = shown.sprite
        if shown.zone ~= zone then
            shown.zone, shown.angle = zone, nil
            sprite.sprite = MapWidgets.picture("zone_" .. zone.templateKey)
        end
        setHidden(sprite, false)
        local left, bottom = tileOnMap(map, zone.x, zone.z)
        local right, top = tileOnMap(map, zone.x + ZONE_SIZE, zone.z + ZONE_SIZE)
        -- The grid turns clockwise, but in this client a positive sprite angle turns anticlockwise.
        local angle = (4 - (turns and turns[index] or 0)) % 4 * 90
        if shown.angle ~= angle then
            shown.angle = angle
            sprite.rotationDegrees = angle
        end
        setBox(sprite, left, top, right - left, bottom - top)
    end
    for index = #Forest.zones + 1, #map.zones do
        map.zones[index].zone = nil
        setHidden(map.zones[index].sprite, true)
    end
    map.zonesShown, map.zonesTurnedBy = Forest.zones, Forest.zoneTurns
end

local function pixel(value) return math.floor(value + 0.5) end
-- Filled on each draw and reused, so drawing a route makes no tables: its points, the direction after each, and
-- each point's left and right edge points.
local routeArrays = { {}, {}, {}, {}, {}, {}, {}, {} }

-- Fills the route arrays with a route's points on the map, from its corner tiles in order, leaving out a point on the
-- one before. Returns how many there are.
local function routePoints(map, tiles)
    local pointX, pointY = routeArrays[1], routeArrays[2]
    local count = 0
    for _, tile in ipairs(tiles) do
        local x, y = tileOnMap(map, tile.x + 0.5, tile.z + 0.5)
        if count == 0 or x ~= pointX[count] or y ~= pointY[count] then
            count = count + 1
            pointX[count], pointY[count] = x, y
        end
    end
    return count
end

-- Draws a route from its count points (routePoints): its first piece on firstCanvas and the rest on restCanvas.
local function drawRoute(map, count, colour, joinsAtStart, firstCanvas, restCanvas)
    if count < 2 then return end
    local pointX, pointY, directionX, directionY, leftX, leftY, rightX, rightY = table.unpack(routeArrays)
    local half = math.max(2, ROUTE_WIDTH * map.frame.iconScale) / 2
    RibbonEdges.fill(pointX, pointY, count, half, joinsAtStart, directionX, directionY, leftX, leftY, rightX, rightY)
    for position = 1, count do
        leftX[position], leftY[position] = pixel(leftX[position]), pixel(leftY[position])
        rightX[position], rightY[position] = pixel(rightX[position]), pixel(rightY[position])
    end
    local joint = map.restJoint
    if restCanvas ~= nil then
        joint[1], joint[2], joint[3], joint[4] = leftX[2], leftY[2], rightX[2], rightY[2]
    else
        leftX[2], leftY[2], rightX[2], rightY[2] = joint[1], joint[2], joint[3], joint[4]
        count = 2
    end
    for position = 1, count - 1 do
        local canvas, after = position == 1 and firstCanvas or restCanvas, position + 1
        canvas:AddTriangle(leftX[position], leftY[position], rightX[position], rightY[position],
            rightX[after], rightY[after], colour)
        canvas:AddTriangle(leftX[position], leftY[position], rightX[after], rightY[after],
            leftX[after], leftY[after], colour)
    end
end

-- Shows the message indicating the route is leading to the middle of the forest, not a target.
local function showUnseen(map, unseen, colour)
    setHidden(map.unseenLine.text, unseen == nil)
    if unseen ~= nil then
        StatusText.set(map.unseenLine, "Walk to find " .. table.concat(unseen, " and "), colour)
    end
end

-- Draws the chosen route in its target's colour, from the player on, or the final route in white when none is chosen
-- and it is on.
-- A canvas can only be cleared whole, so the piece the player walks along has a canvas of its own (routeStart), and
-- the rest is drawn again only when it changes.
function MapLayer.paintRoutes(map)
    if MapLayer.isHidden(map) then return end
    local drawn = RouteChoice.drawn
    showUnseen(map, drawn and drawn.unseen, drawn and drawn.colour)
    local scale = map.frame.mapSize .. "," .. map.frame.iconScale
    map.routeStart:Clear()
    if drawn ~= nil and view().activeRoute then
        local count = routePoints(map, drawn.ahead or drawn.tiles)
        -- The points after the first are the end of drawn.tiles, so their count tells whether a corner was passed.
        local rest = tostring(drawn.tiles) .. "," .. drawn.colour .. "," .. count .. "," .. scale
        if map.restPainted == rest then return drawRoute(map, count, drawn.colour, false, map.routeStart) end
        map.restPainted = rest
        map.routes:Clear()
        return drawRoute(map, count, drawn.colour, false, map.routeStart, map.routes)
    end
    local final = drawn == nil and Forest.grid ~= nil and view().finalRoute and not RouteChoice.isChosen()
        and FinalRoute.routes() or EMPTY
    local rest = tostring(final) .. "," .. scale
    if map.restPainted == rest then return end
    map.restPainted = rest
    map.routes:Clear()
    -- The first branch starts at the entrance, the others where they leave the tree drawn so far.
    for index, finalRoute in ipairs(final) do
        drawRoute(map, routePoints(map, finalRoute), FINAL_ROUTE_COLOUR, index > 1, map.routes, map.routes)
    end
end

-- Returns the route's stops, which stay shown on the map by their own setting.
local function stopsKeptShown()
    return Settings.alwaysShowTarget and RouteChoice.drawn and RouteChoice.drawn.stops or EMPTY
end

-- Returns whether a found feature is shown on the map.
local function isMarkerShown(map, entry, held, unneeded)
    local shows, feature = view(), entry.feature
    -- The route's stops stay by their own setting, except a key just taken, as the route is about to move on.
    if map.stopsShown[entry] and not (feature.kind == "source" and held[feature.key]) then return true end
    if feature.isPuzzle then
        return shows.puzzleElements and not unneeded[entry] and ForestStops.isPuzzleLeft(entry, held)
    end
    if feature.kind == "node" then return shows.nodes and (shows.usedNodes or not entry.isUsed) end
    if feature.kind == "task" then return shows.tasks or Forest.isTaskActive(feature) end
    return true
end

-- Makes a map sprite choose its route when clicked and grow when hovered.
local function makeRoutable(sprite, placed, keyOf)
    sprite.clickthrough = false
    sprite:Subscribe(ui.Hook.ONCLICK, function()
        MapView.toggleRoute(keyOf())
        return true
    end)
    sprite:Subscribe(ui.Hook.ONMOUSEOVER, function()
        if not MapView.canChooseRoute() then return true end
        local width, height = placed.width * HOVER_SCALE, placed.height * HOVER_SCALE
        setBox(sprite, placed.x + (placed.width - width) / 2, placed.y + (placed.height - height) / 2, width, height)
        return true
    end)
    sprite:Subscribe(ui.Hook.ONMOUSELEAVE, function()
        setBox(sprite, placed.x, placed.y, placed.width, placed.height)
        return true
    end)
end

-- Places a marker at its found feature (entry), at the size placeMarkers gave it.
local function placeMarker(map, marker, entry)
    local x, y = tileOnMap(map, entry.x, entry.z)
    marker.x, marker.y = x - marker.width / 2, y - marker.height / 2
    setBox(marker.sprite, marker.x, marker.y, marker.width, marker.height)
end

-- Places one sprite per found feature shown, kept and reused in drawing order.
local function placeMarkers(map)
    map.markerOf = {} -- entry -> its marker, while shown
    local shown, held = 0, ToolsHeld.held
    local unneeded = view().unneededPuzzles and EMPTY or ForestStops.mappingPlan(held).unneeded
    map.stopsShown = stopsKeptShown()
    for _, entry in ipairs(Forest.found) do
        if isMarkerShown(map, entry, held, unneeded) then
            shown = shown + 1
            local marker = map.markers[shown]
            if marker == nil then
                local sprite = MapWidgets.create(ui.Sprite, map.markerLayer)
                marker = { sprite = sprite }
                map.markers[shown] = marker
                makeRoutable(sprite, marker, function() return marker.routeKey end)
            end
            local feature = entry.feature
            marker.routeKey = feature.isPuzzle and feature.pair.source.key or feature.key
            local key, iconScale = feature.key, map.frame.iconScale
            if marker.key ~= key then
                marker.key, marker.angle = key, nil
                marker.sprite.sprite = MapWidgets.picture(key)
            end
            -- A barrier across an east-west path (longer north to south) is turned to lie across it too.
            local angle = (feature.kind == "barrier" and entry.width < entry.length) and 90 or 0
            if marker.angle ~= angle then
                marker.angle = angle
                marker.sprite.rotationDegrees = angle
            end
            marker.width, marker.height = IconSizes[key].width * iconScale, IconSizes[key].height * iconScale
            placeMarker(map, marker, entry)
            setHidden(marker.sprite, false)
            map.markerOf[entry] = marker
        end
    end
    for index = shown + 1, #map.markers do setHidden(map.markers[index].sprite, true) end
end

-- Places each entrance sign at its opening's clearing, shown by its setting or as a stop of the route.
local function placeSigns(map)
    local stops = map.stopsShown
    for _, sign in ipairs(map.signs) do
        local opening = ForestStops.openingOn(sign.side)
        if opening ~= nil and not view().entranceSigns and not stops[opening] then opening = nil end
        setHidden(sign.sprite, opening == nil)
        if opening ~= nil then
            local scale = map.frame.iconScale
            sign.width, sign.height = IconSizes[sign.key].width * scale, IconSizes[sign.key].height * scale
            -- the north-west corner of the zone north-west of the opening's, and the forest's edge beyond the mouth
            local zoneLeft, zoneTop = tileOnMap(map, opening.x - ZONE_SIZE // 2 - ZONE_SIZE,
                opening.z + ZONE_SIZE // 2 + ZONE_SIZE)
            local edgeX, edgeY = tileOnMap(map, opening.x + 1, opening.z + 1)
            if sign.side == "north" then
                sign.x, sign.y = zoneLeft, edgeY
            else
                sign.x, sign.y = edgeX - sign.width, zoneTop
            end
            setBox(sign.sprite, sign.x, sign.y, sign.width, sign.height)
        end
    end
end

-- Places the markers and signs again, as which are shown follows the tools held and the route's stops.
function MapLayer.placeMarkers(map)
    if MapLayer.isHidden(map) then return end
    placeMarkers(map)
    placeSigns(map)
end

function MapLayer.showPlayer(map)
    if MapLayer.isHidden(map) then return end
    local position = view().playerDot and Forest.playerTile or nil
    setHidden(map.playerMarker, position == nil)
    if position == nil then return end
    local size = math.max(5, PLAYER_SIZE * map.frame.iconScale)
    local x, y = tileOnMap(map, position.x + 0.5, position.z + 0.5)
    setBox(map.playerMarker, x - size / 2, y - size / 2, size, size)
end

-- Shows the route chosen, and the markers and signs shown only as its stops.
function MapLayer.showRoute(map)
    if not Sets.same(stopsKeptShown(), map.stopsShown) then MapLayer.placeMarkers(map) end
    MapLayer.paintRoutes(map)
end

-- Moves a found NPC's (entry) marker with it, if shown.
function MapLayer.showNpcMoved(map, entry)
    local marker = not MapLayer.isHidden(map) and map.markerOf[entry]
    if marker then placeMarker(map, marker, entry) end
end

-- Shows what the forest holds on the map as laid out.
function MapLayer.showFound(map)
    if MapLayer.isHidden(map) then return end
    -- A new grid may turn the zones differently.
    if map.zonesShown ~= Forest.zones or map.zonesTurnedBy ~= Forest.zoneTurns then placeZones(map) end
    MapLayer.paintRoutes(map)
    placeMarkers(map)
    placeSigns(map)
    MapLayer.showPlayer(map)
end

-- Places the map and its notes at the frame's map (map.frame), with every zone placed again at the new size.
function MapLayer.layout(map)
    local frame, mapSize = map.frame, map.frame.mapSize
    setBox(map.layer, frame.mapLeft, frame.mapTop, mapSize, mapSize)
    setBox(map.duplicatesText, 8, mapSize - TEXT_HEIGHT - 6, mapSize - 16, TEXT_HEIGHT)
    setBox(map.unseenLine.text, 8, mapSize - 2 * TEXT_HEIGHT - 6, mapSize - 16, TEXT_HEIGHT)
    map.zonesShown = nil
end

-- Builds the map in content in drawing order: the zones, routes, found features, entrance signs and the player.
function MapLayer.build(map, content)
    map.layer = MapWidgets.create(ui.Layer, content)
    local mapBackground = MapWidgets.create(ui.Rectangle, map.layer)
    mapBackground.fill = true
    mapBackground.rgba = FOREST_COLOUR
    map.zoneLayer = MapWidgets.create(ui.Layer, map.layer)
    map.zones = {}
    map.routes = MapWidgets.create(ui.Canvas, map.layer)
    map.routeStart = MapWidgets.create(ui.Canvas, map.layer)
    map.restJoint, map.restPainted, map.markerOf, map.stopsShown = {}, nil, {}, EMPTY
    map.markerLayer = MapWidgets.create(ui.Layer, map.layer)
    map.markers = {}
    local signLayer = MapWidgets.create(ui.Layer, map.layer)
    for _, filling in ipairs({ mapBackground, map.zoneLayer, map.routes, map.routeStart, map.markerLayer,
        signLayer }) do
        filling:SetSize(0, 0, 1.0, 1.0) -- fills the map layer
    end
    -- A click on a sign chooses or drops the route to its opening.
    map.signs = {}
    for _, sign in ipairs(ForestFeatures.entranceSigns) do
        local shown = { key = sign.key, side = sign.side, sprite = MapWidgets.addIcon(signLayer, sign.key) }
        makeRoutable(shown.sprite, shown, function() return sign.key end)
        map.signs[#map.signs + 1] = shown
    end
    map.playerMarker = MapWidgets.create(ui.Rectangle, map.layer)
    map.playerMarker.fill = true
    map.playerMarker.rgba = PLAYER_COLOUR
    map.duplicatesText = MapWidgets.addText(map.layer, MapWidgets.TEXT_FONT, MapWidgets.TEXT_COLOUR,
        ui.AlignMode.TOPLEFT, "DUPLICATE NODES DO NOT GIVE EXP")
    map.unseenLine = StatusText.new(MapWidgets.addText(map.layer, MapWidgets.TEXT_FONT, MapWidgets.TEXT_COLOUR,
        ui.AlignMode.TOPLEFT))
    setHidden(map.unseenLine.text, true)
end

return MapLayer

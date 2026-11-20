-- The map window, containing a header with the compass, the node legend beside the
-- map and the puzzle legend below it.

local IconSizes = require("src/data/icon_sizes")
local Colours = require("src/ui/colours")
local ForestFeatures = require("src/data/forest_features")
local Forest = require("src/game/forest")
local Routes = require("src/game/routes")
local RibbonEdges = require("src/game/ribbon_edges")
local ForestStops = require("src/game/forest_stops")
local RouteChoice = require("src/game/route_choice")
local ToolsHeld = require("src/game/tools_held")
local WorldNumber = require("src/game/world_number")
local Settings = require("src/data/settings")
local WindowPlace = require("src/ui/window_place")
local StatusText = require("src/ui/status_text")
local SharingButton = require("src/ui/sharing_button")

local MapWindow = {}

local WINDOW_EDGE_WIDTH, WINDOW_EDGE_HEIGHT = 16, 40 -- a PrettyUI window is this much larger than its content
local HEADER_HEIGHT = 36
local HEADER_TEXT_HEIGHT = 26
local EDGE = 8 -- border around and between the frame's parts
local PUZZLE_LEGEND_HEIGHT = 66
local SIMPLE_PUZZLE_LEGEND_HEIGHT = 40 -- with no names under the pictures
-- Simplified legends show the game's paths icon on NAVIGATE and SOLVE instead of their words, so neither button's
-- text sets a least width.
local PATHS_ICON_SPRITE = id.Sprite.RS3_ICON_MENU_PATHS_0
local SIMPLE_SOLVE_BUTTON_WIDTH = SIMPLE_PUZZLE_LEGEND_HEIGHT -- a square column for the icon
local SIMPLE_PAIR_LEAST_WIDTH = 40 -- a puzzle cell holding only its key's picture
-- The legend's width follows the map's, as on the pack's frame (280 beside 685), within limits. Its fonts follow it.
local LEGEND_TO_MAP = 0.41
local LEGEND_MINIMUM_WIDTH, LEGEND_MAXIMUM_WIDTH = 110, 320
local DEFAULT_MAP_SIZE, MINIMUM_MAP_SIZE = 520, 260
local PACK_MAP_SIZE = 685 -- the pack's map width, at which the icons are drawn at their own size
local ZONE_SIZE = 8 -- tiles
-- The game's compass, layered like the minimap's: the ring, with the backing and needle on top. The minimap's needle
-- component draws COMPASSMASK_2, which is only the mask COMPASS is drawn through and shows nothing alone.
local COMPASS_BACKING_SPRITE = id.Sprite.NAVIGATION_BACKING_COMPASS
local COMPASS_SPRITE = id.Sprite.COMPASS
-- PrettyUI's window background, tiled behind the legend row of a node absent from this forest but claimed today, so
-- it stands apart from the red rows still to claim.
local WINDOW_BACKGROUND_SPRITE = id.Sprite.RS3_MODAL_WINDOW_CONTENT_TILE
local COMPASS_RING_SPRITE = id.Sprite.RS3_MINIMAP_CLASSIC_RING_41PX -- the minimap's ring
local COMPASS_SIZE = 50 -- as on the pack's frame, over the corner of the frame and map
-- Sprite sizes in the cache: ring 41, backing 33, COMPASS 51. The game shows COMPASS at full size through a 33 mask,
-- so drawing it at 33 would make the needle too small; all three are centred and scaled together.
local COMPASS_RING_PIXELS, COMPASS_BACKING_PIXELS, COMPASS_NEEDLE_PIXELS = 41, 33, 51
local HEADING_PADDING = 6 -- above and below a legend heading
local TEXT_HEIGHT = 20
local LARGEST_LEGEND_ICON_SCALE = 1.25
-- Simplified legends show only the pictures, which may grow to this many times their size.
local LARGEST_SIMPLE_ICON_SCALE = 2
local SIMPLE_ICON_INSET = 2 -- the gap kept round a simplified row's picture, inside the row's outline
-- The least row height of a node legend in its own window, about a row's height in the smallest frame.
local LEAST_LEGEND_ROW_HEIGHT = 16
local ROUTE_WIDTH = 7 -- in pack pixels, like the icons
local PLAYER_SIZE = 10
local DIMMED_ALPHA = 0.3 -- legend entries absent from the forest, and finished puzzles
local SOLVE_BUTTON_WIDTH = 72 -- as high as the puzzle legend, at its right end
local SOLVE_INSET = 2 -- the SOLVE button's inset within its column
local LEGEND_LINE_INSET = 6 -- inset of the legend's dividers, NAVIGATE and the red covers
local MAP_ROUTE_HEIGHT = 30 -- the NAVIGATE button, at the legend's foot
local RESIZE_END_SUBSCRIPTION = "nemi_mapper_map_resize_end"

local FRAME_COLOUR = 0x09161FFF
local FRAME_LINE_COLOUR = 0x2B3C48FF
local BUTTON_COLOUR = 0x1B4A6BFF -- in the frame's blues
local BUTTON_DOWN_COLOUR = 0x2F7FB3FF
local BUTTON_OVER_COLOUR = 0x245E88FF
local FOREST_COLOUR = 0xB98967FF -- under the zones: the open zones' average ground colour
local FINAL_ROUTE_COLOUR = 0xF4F1E6FF
local PLAYER_COLOUR = 0xFF3B30FF
local TEXT_COLOUR = 0xFFFFFFFF
local HEADING_COLOUR = 0xE9B93EFF
local HINT_COLOUR = Colours.GOLD -- "Walk to find"
local HOVER_SCALE = 1.25 -- a map icon under the mouse grows by this, about its centre
local HOVER_COLOUR = 0xFFFFFFFF -- outline of a clickable row or pair under the mouse
local MISSING_COLOUR = Colours.RED | 0x70 -- translucent red over a node absent from this forest but unclaimed today
local KEY_UNSEEN_TEXT = "Walk to find" -- a key's NPC only reaches the client near the player
local KEY_UNSEEN_NAME = KEY_UNSEEN_TEXT:upper() -- the same on a legend row, whose names are upper case
local TEXT_FONT = id.Font.MUSEO_SANS_13PT_BOLD
local HEADER_FONT = id.Font.MUSEO_SANS_19PT_BOLD
local SMALL_FONT = id.Font.MUSEO_SANS_11PT_REGULAR
MapWindow.onSharingToggled = nil -- called when the title bar's sharing button is clicked

-- Returns the bold fonts of these sizes as { id, size }, largest first, ending with the 11pt font (regular, as the
-- game has no 11pt bold).
-- Legend headings and names use the largest that fits.
local function boldFonts(sizes)
    local fonts = {}
    for _, size in ipairs(sizes) do
        fonts[#fonts + 1] = { id = id.Font["MUSEO_SANS_" .. size .. "PT_BOLD"], size = size }
    end
    fonts[#fonts + 1] = { id = SMALL_FONT, size = 11 }
    return fonts
end
local HEADING_FONTS = boldFonts({ 27, 24, 21, 19, 17, 15, 13 })
local NAME_FONTS = boldFonts({ 24, 21, 19, 17, 15, 13 })
local NAME_TO_ROW = 0.5 -- a name's font is at most this share of its row, so it grows with the legend

-- The open window, or nil. It holds the window, its components' last written state, the content size and the
-- frame's layout. The map draws the route chosen (src/game/route_choice.lua), or the final route when none is chosen.
local parts = nil
local showLegendStates -- defined below

-- Values worked out once per redraw: the view, the puzzle pairs and the legends shown.
local redraw = {}
local function newRedraw()
    redraw = {}
end

-- Returns a picture by its file name, without the extension.
local function picture(name)
    return Plugin.resources[name]
end

local function isOpen()
    if parts ~= nil and ui.Interfaces:GetInterface(parts.window.interfaceID) == nil then parts = nil end
    return parts ~= nil
end

local function create(componentType, parent)
    local component = componentType.new(parent)
    component.clickthrough = true
    return component
end

local function addText(parent, font, colour, alignHorizontal, content)
    local text = create(ui.Text, parent)
    text.font = font
    text.rgba = colour
    text.isShadowed = true
    text.maxLines = 1
    text.alignHorizontal = alignHorizontal
    text.alignVertical = ui.AlignMode.CENTRE
    text.content = content or ""
    return text
end

-- Adds the game sprite spriteID to parent.
local function addGameSprite(parent, spriteID)
    local sprite = create(ui.Sprite, parent)
    sprite.spriteID = spriteID
    return sprite
end

local function addIcon(parent, key)
    local icon = create(ui.Sprite, parent)
    icon.sprite = picture(key)
    return icon
end

-- Places and sizes a component, writing each only when it changes, as each property write has a cost in the client.
-- A component placed through this must not be placed or sized any other way.
local function setBox(component, left, top, width, height)
    local x, y = math.floor(left), math.floor(top)
    local boxWidth, boxHeight = math.max(1, math.floor(width)), math.max(1, math.floor(height))
    local box = parts.boxOf[component]
    if box == nil then
        box = {}
        parts.boxOf[component] = box
    end
    if box[1] ~= x or box[2] ~= y then
        box[1], box[2] = x, y
        component:SetPos(x, y)
    end
    if box[3] ~= boxWidth or box[4] ~= boxHeight then
        box[3], box[4] = boxWidth, boxHeight
        component:SetSize(boxWidth, boxHeight)
    end
end

local function setBoxes(first, second, left, top, width, height)
    setBox(first, left, top, width, height)
    setBox(second, left, top, width, height)
end

local function setHidden(component, isHidden)
    if parts.hiddenOf[component] ~= isHidden then
        parts.hiddenOf[component] = isHidden
        component.hidden = isHidden
    end
end

local function setAllHidden(isHidden, ...)
    for index = 1, select("#", ...) do
        local component = select(index, ...)
        if component ~= nil then setHidden(component, isHidden) end
    end
end

local function setButtonBox(button, left, top, width, height)
    setBox(button.cell, left, top, width, height)
    setBox(button.text, left, top, width, height)
    local size = math.max(1, math.min(width, height) - 8)
    setBox(button.icon, left + (width - size) / 2, top + (height - size) / 2, size, size)
end

local function showButtonParts(button, isShown, simple)
    setHidden(button.cell, not isShown)
    setHidden(button.text, not isShown or simple)
    setHidden(button.icon, not isShown or not simple)
end

-- The game's compass sprites are off centre, so they are inset by COMPASS_INSET.
local COMPASS_INSET = 3 -- pixels
local COMPASS_CENTRE, COMPASS_SCALE = COMPASS_INSET + COMPASS_SIZE / 2, COMPASS_SIZE / COMPASS_RING_PIXELS
local function placeCompassSprite(component, pixels, frame)
    local size = math.floor(pixels * COMPASS_SCALE + 0.5)
    setBox(component, math.floor(frame.left + COMPASS_CENTRE - size / 2 + 0.5),
        math.floor(frame.top + COMPASS_CENTRE - size / 2 + 0.5), size, size)
end

local function setIconIn(icon, key, left, top, width, height, largestScale)
    local size = IconSizes[key]
    local scale = math.min(width / size.width, height / size.height, largestScale)
    local iconWidth, iconHeight = size.width * scale, size.height * scale
    setBox(icon, left + (width - iconWidth) / 2, top + (height - iconHeight) / 2, iconWidth, iconHeight)
end

local function widestText(texts, fontID)
    local widths = parts.textWidths[texts]
    if widths == nil then
        widths = {}
        parts.textWidths[texts] = widths
    end
    if widths[fontID] == nil then
        local font, widest = config.Font.FromID(fontID), 0
        for _, text in ipairs(texts) do widest = math.max(widest, font:GetStringWidth(text)) end
        widths[fontID] = widest
    end
    return widths[fontID]
end

local function fittingFont(fonts, texts, width, largestSize)
    for _, font in ipairs(fonts) do
        if (largestSize == nil or font.size <= largestSize) and widestText(texts, font.id) <= width then
            return font
        end
    end
    return fonts[#fonts]
end

-- Returns a forest point (in tiles) as map-layer pixels, north up.
local function tileOnMap(x, z)
    local bounds, mapSize = Forest.bounds, parts.frame.mapSize
    return math.floor((x - bounds.minX) * mapSize / bounds.width + 0.5),
        math.floor((bounds.minZ + bounds.length - z) * mapSize / bounds.length + 0.5)
end

-- Returns whether the map is hidden, as its X only hides it while a legend's own window is shown. Its zones, routes,
-- markers and player then wait (mapStale) until it shows again, while the legends' windows keep up.
local function mapHidden()
    if parts.window.root.hidden ~= true then return false end
    parts.mapStale = true
    return true
end

-- Places one sprite per zone, showing the zone it was copied from, turned as the grid has it so the picture matches the
-- routes (src/game/forest_grid.lua reads the turns from the zones' standing heights).
-- The pictures show at once and turn as the zones' turns become known (Forest.zoneTurns), before the grid settles.
-- A zone's picture and angle are written only when they change, as this runs on every step of a resize.
local function placeZones()
    if mapHidden() then return end
    local turns = Forest.zoneTurns
    for index, zone in ipairs(Forest.zones) do
        local shown = parts.zones[index]
        if shown == nil then
            shown = { sprite = create(ui.Sprite, parts.zoneLayer) }
            parts.zones[index] = shown
        end
        local sprite = shown.sprite
        if shown.zone ~= zone then
            shown.zone, shown.angle = zone, nil
            sprite.sprite = picture("zone_" .. zone.templateKey)
        end
        setHidden(sprite, false)
        local left, bottom = tileOnMap(zone.x, zone.z)
        local right, top = tileOnMap(zone.x + ZONE_SIZE, zone.z + ZONE_SIZE)
        -- The grid turns clockwise, but in this client a positive sprite angle turns anticlockwise.
        local angle = (4 - (turns and turns[index] or 0)) % 4 * 90
        if shown.angle ~= angle then
            shown.angle = angle
            sprite.rotationDegrees = angle
        end
        setBox(sprite, left, top, right - left, bottom - top)
    end
    for index = #Forest.zones + 1, #parts.zones do
        parts.zones[index].zone = nil
        setHidden(parts.zones[index].sprite, true)
    end
    parts.zonesShown, parts.zonesTurnedBy = Forest.zones, Forest.zoneTurns
end

local function pixel(value) return math.floor(value + 0.5) end
-- Filled on each draw and reused, so drawing a route makes no tables: its points, the direction after each, and
-- each point's left and right edge points.
local routeArrays = { {}, {}, {}, {}, {}, {}, {}, {} }

-- Fills the route arrays with a route's points on the map, from its corner tiles in order, leaving out a point on the
-- one before. Returns how many there are.
local function routePoints(tiles)
    local pointX, pointY = routeArrays[1], routeArrays[2]
    local count = 0
    for _, tile in ipairs(tiles) do
        local x, y = tileOnMap(tile.x + 0.5, tile.z + 0.5)
        if count == 0 or x ~= pointX[count] or y ~= pointY[count] then
            count = count + 1
            pointX[count], pointY[count] = x, y
        end
    end
    return count
end

-- Draws a route from its count points (routePoints): its first piece on firstCanvas and the rest on restCanvas.
-- Without restCanvas the rest stays as drawn, and the first piece ends on the edge points it was drawn with, so the
-- two meet without a seam.
local function drawRoute(count, colour, joinsAtStart, firstCanvas, restCanvas)
    if count < 2 then return end
    local pointX, pointY, directionX, directionY, leftX, leftY, rightX, rightY = table.unpack(routeArrays)
    local half = math.max(2, ROUTE_WIDTH * parts.frame.iconScale) / 2
    RibbonEdges.fill(pointX, pointY, count, half, joinsAtStart, directionX, directionY, leftX, leftY, rightX, rightY)
    for position = 1, count do
        leftX[position], leftY[position] = pixel(leftX[position]), pixel(leftY[position])
        rightX[position], rightY[position] = pixel(rightX[position]), pixel(rightY[position])
    end
    local joint = parts.restJoint
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

-- The final route runs through every node from the opening the player entered by (the one nearer their first tile)
-- to the other. Redoing it on each node found would cost a search per node, so it is worked out once per forest
-- entry, after the search settles, and kept, which also keeps it unchanged when the map reopens or the player
-- leaves. It is only for sharing, so it waits for the next server tick rather than share a frame with NAVIGATE's
-- plan, and is skipped while a route is chosen.
local finalRouteOf = nil -- { entry, routes } for the last forest entered, keyed by its entry tile
local waitForFinalRoute -- defined below paintRoutes, which it calls
local function workOutFinalRoute()
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
    finalRouteOf = { entry = entry, routes = Routes.finalRoute(grid, openings[1] or entry, openings[2], targets) }
end

-- Returns the final route's pieces, once worked out.
local function finalRoutes()
    if Forest.entryTile == nil then return nil end
    if finalRouteOf ~= nil and finalRouteOf.entry == Forest.entryTile then return finalRouteOf.routes end
    if not Forest.isSearching then waitForFinalRoute() end
    return nil
end

local placeMarkers, placeSigns -- defined below

-- Returns what the map should show from the settings.
local function view()
    if redraw.view ~= nil then return redraw.view end
    local sharing = Settings.mapSharingMode
    redraw.view = {
        puzzleElements = not sharing and not (Settings.hideUnneededPuzzles and Settings.hidePuzzleElements),
        puzzleLegend = not sharing and not Settings.hidePuzzleLegend,
        nodeLegend = sharing or not Settings.hideNodeLegend,
        simpleLegends = not sharing and Settings.simplifiedLegends,
        taskLegend = sharing or not Settings.hideTaskLegend, -- the node legend's Trinks' tasks, active or not
        claimedInLegend = sharing or not Settings.hideClaimedLegend, -- the node legend's rows of nodes claimed today
        -- A shared map keeps its legend in the frame, so it shows in a screenshot of the map.
        nodeLegendPopped = not sharing and not Settings.hideNodeLegend and Settings.popOutNodeLegend,
        puzzleLegendPopped = not sharing and not Settings.hidePuzzleLegend and Settings.popOutPuzzleLegend,
        header = sharing, -- the world, count and friends chat: for sharing only
        -- hideNodes counts only while hideUsedNodes, its parent on the settings page, is on
        nodes = sharing or not (Settings.hideUsedNodes and Settings.hideNodes),
        usedNodes = sharing or not Settings.hideUsedNodes,
        unneededPuzzles = not Settings.hideUnneededPuzzles, -- on the map
        unneededPairs = not Settings.hideUnneededPairs, -- in the puzzle legend
        tasks = sharing or not Settings.hideTasks,
        forestNotes = not sharing, -- "Walk to find", and task rows dimmed when not on the task
        outlineAbsent = not sharing and not Settings.hideAbsentMarks, -- red or brown on rows of missing nodes
        mapRoute = not sharing,
        finalRoute = sharing or not Settings.hideFinalRoute,
        activeRoute = sharing or not Settings.hideActiveRoute,
        playerDot = not sharing,
        entranceSigns = sharing or not Settings.hideEntranceSigns,
    }
    return redraw.view
end

local EMPTY = {}

-- Shows, on the map's bottom left above the duplicates note, which keys the route walks toward the forest's centre to
-- find (keysUnseen: their names), in the route's colour, or hides it with none.
local function showKeysUnseen(keysUnseen, colour)
    setHidden(parts.keysUnseenLine.text, keysUnseen == nil)
    if keysUnseen ~= nil then
        StatusText.set(parts.keysUnseenLine, "Walk to find " .. table.concat(keysUnseen, " and "), colour)
    end
end

-- Draws the chosen route in its target's colour, from the player on, or the final route in white when none is chosen
-- and it is on.
-- A canvas can only be cleared whole, so the piece the player walks along has a canvas of its own (routeStart), and
-- the rest is drawn again only when it changes (restPainted): a corner passed, another route, or the map's size.
local function paintRoutes()
    if mapHidden() then return end
    local drawn = RouteChoice.drawn
    showKeysUnseen(drawn and drawn.keysUnseen, drawn and drawn.colour)
    local scale = parts.frame.mapSize .. "," .. parts.frame.iconScale
    parts.routeStart:Clear()
    if drawn ~= nil and view().activeRoute then
        local count = routePoints(drawn.ahead or drawn.tiles)
        -- The points after the first are the end of drawn.tiles, so their count tells whether a corner was passed.
        local rest = tostring(drawn.tiles) .. "," .. drawn.colour .. "," .. count .. "," .. scale
        if parts.restPainted == rest then return drawRoute(count, drawn.colour, false, parts.routeStart) end
        parts.restPainted = rest
        parts.routes:Clear()
        return drawRoute(count, drawn.colour, false, parts.routeStart, parts.routes)
    end
    local final = drawn == nil and Forest.grid ~= nil and view().finalRoute and not RouteChoice.isChosen()
        and finalRoutes() or EMPTY
    local rest = tostring(final) .. "," .. scale
    if parts.restPainted == rest then return end
    parts.restPainted = rest
    parts.routes:Clear()
    -- The first branch starts at the entrance, the others where they leave the tree drawn so far.
    for index, finalRoute in ipairs(final) do
        drawRoute(routePoints(finalRoute), FINAL_ROUTE_COLOUR, index > 1, parts.routes, parts.routes)
    end
end

-- Returns the route's stops, which stay shown on the map by their own setting.
local function stopsKeptShown()
    return Settings.alwaysShowTarget and RouteChoice.drawn and RouteChoice.drawn.stops or EMPTY
end

-- Shows the route chosen: the legend's pressed buttons and outlines, the route, and the icons and signs shown only
-- as its stops.
local function showRoute()
    if not ForestStops.sameSet(stopsKeptShown(), parts.stopsShown) then
        placeMarkers()
        placeSigns()
    end
    showLegendStates()
    paintRoutes()
end

-- Works out and draws the final route on the next server tick, if the map is still open with the final route on
-- and nothing chosen in its place.
local FINAL_ROUTE_SUBSCRIPTION = "nemi_mapper_final_route"
-- Subscribing again while waiting replaces the same subscription.
waitForFinalRoute = function()
    Event.ServerLogic.Subscribe(FINAL_ROUTE_SUBSCRIPTION, function()
        Event.ServerLogic.Unsubscribe(FINAL_ROUTE_SUBSCRIPTION)
        if not isOpen() then return end
        newRedraw()
        if Forest.grid ~= nil and Forest.entryTile ~= nil and not Forest.isSearching and view().finalRoute
            and not RouteChoice.isChosen() then
            workOutFinalRoute()
            paintRoutes()
        end
    end)
end

-- Returns whether a found feature is shown on the map.
local function isMarkerShown(entry, held, unneeded)
    local shows, feature = view(), entry.feature
    -- The route's stops stay by their own setting, except a key just taken, as the route is about to move on.
    if parts.stopsShown[entry] and not (feature.kind == "source" and held[feature.key]) then return true end
    if feature.isPuzzle then return shows.puzzleElements and ForestStops.isPuzzleNeeded(entry, held, unneeded) end
    if feature.kind == "node" then return shows.nodes and (shows.usedNodes or not entry.isUsed) end
    if feature.kind == "task" then return shows.tasks or Forest.isTaskActive(feature) end
    return true
end

-- Returns whether a click on a map icon, sign or legend entry can choose a route: the player is in the forest, and the
-- map is not a shared one, which shows only the final route.
local function canChooseRoute()
    return Forest.isInside and not Settings.mapSharingMode
end

-- Chooses a legend row's, map icon's or entrance sign's route, or drops it on a second click.
local function toggleRoute(key)
    if canChooseRoute() then RouteChoice.toggle(key) end
end

-- Makes a map sprite choose its route when clicked and grow when hovered.
local function makeRoutable(sprite, placed, keyOf)
    sprite.clickthrough = false
    sprite:Subscribe(ui.Hook.ONCLICK, function()
        toggleRoute(keyOf())
        return true
    end)
    sprite:Subscribe(ui.Hook.ONMOUSEOVER, function()
        if not canChooseRoute() then return true end
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
local function placeMarker(marker, entry)
    local x, y = tileOnMap(entry.x, entry.z)
    marker.x, marker.y = x - marker.width / 2, y - marker.height / 2
    setBox(marker.sprite, marker.x, marker.y, marker.width, marker.height)
end

-- Places one sprite per found feature shown, kept and reused in drawing order.
placeMarkers = function()
    if mapHidden() then return end
    parts.markerOf = {} -- entry -> its marker, while shown
    local shown, held = 0, ToolsHeld.held
    local unneeded = view().unneededPuzzles and EMPTY or ForestStops.mappingPlan(held).unneeded
    parts.stopsShown = stopsKeptShown()
    for _, entry in ipairs(Forest.found) do
        if isMarkerShown(entry, held, unneeded) then
            shown = shown + 1
            local marker = parts.markers[shown]
            if marker == nil then
                local sprite = create(ui.Sprite, parts.markerLayer)
                marker = { sprite = sprite }
                parts.markers[shown] = marker
                makeRoutable(sprite, marker, function() return marker.routeKey end)
            end
            local feature = entry.feature
            marker.routeKey = feature.isPuzzle and feature.pair.source.key or feature.key
            local key, iconScale = feature.key, parts.frame.iconScale
            if marker.key ~= key then
                marker.key, marker.angle = key, nil
                marker.sprite.sprite = picture(key)
            end
            -- A barrier across an east-west path (longer north to south) is turned to lie across it too.
            local angle = (feature.kind == "barrier" and entry.width < entry.length) and 90 or 0
            if marker.angle ~= angle then
                marker.angle = angle
                marker.sprite.rotationDegrees = angle
            end
            marker.width, marker.height = IconSizes[key].width * iconScale, IconSizes[key].height * iconScale
            placeMarker(marker, entry)
            setHidden(marker.sprite, false)
            parts.markerOf[entry] = marker
        end
    end
    for index = shown + 1, #parts.markers do setHidden(parts.markers[index].sprite, true) end
end

-- Places each entrance sign at its opening's clearing.
placeSigns = function()
    if mapHidden() then return end
    local stops = parts.stopsShown
    for _, sign in ipairs(parts.signs) do
        local opening = ForestStops.openingOn(sign.side)
        if opening ~= nil and not view().entranceSigns and not stops[opening] then opening = nil end
        setHidden(sign.sprite, opening == nil)
        if opening ~= nil then
            local scale = parts.frame.iconScale
            sign.width, sign.height = IconSizes[sign.key].width * scale, IconSizes[sign.key].height * scale
            -- the north-west corner of the zone north-west of the opening's, and the forest's edge beyond the mouth
            local zoneLeft, zoneTop = tileOnMap(opening.x - ZONE_SIZE // 2 - ZONE_SIZE,
                opening.z + ZONE_SIZE // 2 + ZONE_SIZE)
            local edgeX, edgeY = tileOnMap(opening.x + 1, opening.z + 1)
            if sign.side == "north" then
                sign.x, sign.y = zoneLeft, edgeY
            else
                sign.x, sign.y = edgeX - sign.width, zoneTop
            end
            setBox(sign.sprite, sign.x, sign.y, sign.width, sign.height)
        end
    end
end

local function showPlayer()
    if mapHidden() then return end
    local position = view().playerDot and Forest.playerTile or nil
    setHidden(parts.playerMarker, position == nil)
    if position == nil then return end
    local size = math.max(5, PLAYER_SIZE * parts.frame.iconScale)
    local x, y = tileOnMap(position.x + 0.5, position.z + 0.5)
    setBox(parts.playerMarker, x - size / 2, y - size / 2, size, size)
end

local function setDimmed(isDimmed, ...)
    local alpha = isDimmed and DIMMED_ALPHA or 1
    for index = 1, select("#", ...) do
        local component = select(index, ...)
        if component ~= nil then component.alpha = alpha end
    end
end

local HEADER_SPLIT = 0.62
local function placeHeaderTexts()
    local frame = parts.frame
    local font = config.Font.FromID(HEADER_FONT)
    local countLeft = frame.left + COMPASS_SIZE + 10
    local right = frame.mapLeft + frame.mapSize - 4
    local countNeeded = font:GetStringWidth(parts.countLine.content or "") + 4
    local chatNeeded = font:GetStringWidth(parts.headerLine.content) + 4
    local boundary = math.min(frame.mapLeft + math.floor(frame.mapSize * HEADER_SPLIT), right - chatNeeded)
    boundary = math.min(math.max(boundary, countLeft + countNeeded), right)
    local headerTop = frame.top + (HEADER_HEIGHT - HEADER_TEXT_HEIGHT) / 2
    setBox(parts.countLine.text, countLeft, headerTop, boundary - countLeft, HEADER_TEXT_HEIGHT)
    setBox(parts.headerLine.text, boundary, headerTop, right - boundary, HEADER_TEXT_HEIGHT)
end

local function showCountText()
    local kinds, total = Forest.nodeCounts()
    local countText = "Enter the Forest"
    if Forest.bounds ~= nil then
        local duplicates = total - kinds
        local world = WorldNumber.world
        countText = (world and ("W" .. world .. " ") or "") .. kinds .. "/" .. #ForestFeatures.nodes
        if duplicates > 0 then
            countText = countText .. " (+" .. duplicates .. (duplicates == 1 and " duplicate)" or " duplicates)")
        end
    end
    if parts.countLine.content ~= countText then
        StatusText.set(parts.countLine, countText)
        if parts.headerShown then placeHeaderTexts() end
    end
    return kinds, total
end

-- Shows a legend row's or puzzle's label, writing its text and colour only when they change.
local function showLabel(label, holder, isHint, text, isDimmed)
    if holder.labelText ~= text then
        holder.labelText = text
        label.content = text
    end
    local colourChanged = holder.isHint ~= isHint
    if colourChanged then
        holder.isHint = isHint
        label.rgba = isHint and HINT_COLOUR or TEXT_COLOUR
    end
    if colourChanged or holder.labelDimmed ~= isDimmed then
        holder.labelDimmed = isDimmed
        setDimmed(isDimmed, label)
    end
end

local function showCounts()
    local shows = view()
    local isMapped = Forest.bounds ~= nil
    local kinds, total = showCountText()
    setHidden(parts.duplicatesText, total <= kinds)
    -- A node who is claimed today, and hidden by the setting, counts as absent.
    local unusedOf = {}
    for _, entry in ipairs(Forest.found) do
        if entry.feature.kind == "node" and (shows.usedNodes or not entry.isUsed) then
            unusedOf[entry.feature.key] = (unusedOf[entry.feature.key] or 0) + 1
        end
    end
    for _, row in ipairs(parts.legendRows) do
        -- An absent node still unclaimed today gets a red cover.
        local feature = row.feature
        local foundCount = Forest.countOf[feature.key] or 0
        -- canRoute also needs the player inside and no sharing mode, so no outline shows where a click does nothing.
        row.canRoute = foundCount > 0 and canChooseRoute()
        local count = feature.kind == "node" and (unusedOf[feature.key] or 0) or foundCount
        if feature.kind == "task" and shows.forestNotes and not Forest.isTaskActive(feature) then count = 0 end
        local isDimmed = isMapped and count == 0
        local isAbsentNode = shows.outlineAbsent and isMapped and feature.kind == "node" and foundCount == 0
        row.isNeeded = isAbsentNode and not Forest.isNodeClaimed(feature.key)
        row.isClaimedAbsent = isAbsentNode and Forest.isNodeClaimed(feature.key)
        -- An NPC never seen is far off, so the row says to walk nearer. The hint is not dimmed.
        local isUnseen = shows.forestNotes and isMapped and feature.npcs ~= nil and foundCount == 0
            and Forest.isTaskActive(feature)
        if row.isDimmed ~= isDimmed then
            row.isDimmed = isDimmed
            setDimmed(isDimmed, row.icon, row.skill)
        end
        showLabel(row.name, row, isUnseen, isUnseen and KEY_UNSEEN_NAME or row.nameText, isDimmed and not isUnseen)
    end
    showLegendStates()
    local keyUnseen, held = {}, ToolsHeld.held
    for _, toolPair in ipairs(Forest.keysUnseen()) do keyUnseen[toolPair] = true end
    for _, pair in ipairs(parts.puzzlePairs) do
        local toolPair = pair.toolPair
        local count = (Forest.countOf[toolPair.source.key] or 0) + (Forest.countOf[toolPair.barrier.key] or 0)
        local isDone = Forest.doorsGone[toolPair.barrier.key] == true
        -- A puzzle absent from this forest, or done, is dimmed and ignores clicks, as does any outside the forest.
        local isDimmed = isMapped and (count == 0 or isDone)
        pair.canRoute = not isDimmed and canChooseRoute()
        -- A barrier seen without its key means the key is far off, so the label says to walk nearer.
        local isUnseen = keyUnseen[toolPair] == true
        if pair.isDimmed ~= isDimmed or pair.isKeyUnseen ~= isUnseen then
            setDimmed(isDimmed, pair.barrier)
            setDimmed(isDimmed or isUnseen, pair.source)
        end
        pair.isDimmed, pair.isKeyUnseen = isDimmed, isUnseen
        -- Named by its key until the key is held, then by the door it opens, where it is to be taken.
        local name = held[toolPair.source.key] and toolPair.barrier.name or toolPair.tool
        showLabel(pair.label, pair, isUnseen, isUnseen and KEY_UNSEEN_TEXT or name, isDimmed)
        if shows.simpleLegends then setHidden(pair.label, not (parts.puzzleShown and pair.isShown and isUnseen)) end
    end
end

-- Returns the puzzle legend's pairs shown, once per redraw.
-- While the legend is hidden nothing is left out, no search is made.
local function shownPuzzlePairs()
    if redraw.shownPairs ~= nil then return redraw.shownPairs end
    local shown = parts.puzzlePairs
    local shows = view()
    if shows.puzzleLegend and not shows.unneededPairs and Forest.bounds ~= nil then
        local held = ToolsHeld.held
        local unneeded, needed = ForestStops.mappingPlan(held).unneeded, {}
        for _, entry in ipairs(Forest.found) do
            if entry.feature.isPuzzle and ForestStops.isPuzzleNeeded(entry, held, unneeded) then
                needed[entry.feature.pair] = true
            end
        end
        shown = {}
        for _, pair in ipairs(parts.puzzlePairs) do
            if needed[pair.toolPair] then shown[#shown + 1] = pair end
        end
    end
    redraw.shownPairs = shown
    return shown
end

-- Returns the puzzles shown in the legend, marking the keys held whose cells show their doors' pictures in a
-- simplified legend, as a string to notice a change by.
local function shownPairsKey()
    local held = view().simpleLegends and parts.puzzleShown and ToolsHeld.held or EMPTY
    local keys = {}
    for _, pair in ipairs(shownPuzzlePairs()) do
        local key = pair.toolPair.source.key
        keys[#keys + 1] = held[key] and key .. "*" or key
    end
    return table.concat(keys, " ")
end

-- Returns whether the puzzle legend shows: by its setting, while barriers stand and it has a puzzle to show.
local function puzzleLegendShown()
    if redraw.puzzleLegendShown ~= nil then return redraw.puzzleLegendShown end
    if not view().puzzleLegend then return false end
    local shown = Forest.bounds == nil or Forest.isSearching or Forest.barriersLeft()
    -- The minimum size is worked out before the window and its pairs exist, so the pairs count only once made.
    if parts == nil then return shown end
    redraw.puzzleLegendShown = shown and #shownPuzzlePairs() > 0
    return redraw.puzzleLegendShown
end

local layoutFitting -- defined below fitWindowTo
-- Returns width rounded up, between leastWidth and the node legend's greatest width.
local function clampedLegendWidth(width, leastWidth)
    return math.max(leastWidth, math.min(LEGEND_MAXIMUM_WIDTH, math.ceil(width)))
end

local PUZZLE_WINDOW_LEAST_WIDTH = EDGE + MINIMUM_MAP_SIZE
    + clampedLegendWidth(MINIMUM_MAP_SIZE * LEGEND_TO_MAP, LEGEND_MINIMUM_WIDTH) + WINDOW_EDGE_WIDTH

-- Returns the node legend's least width; a simplified one is as wide as its NAVIGATE button, inside its border.
local function legendMinimumWidth()
    if not view().simpleLegends then return LEGEND_MINIMUM_WIDTH end
    return MAP_ROUTE_HEIGHT + 2
end

-- Returns whether the node legend shows a feature's row.
local function legendRowShown(feature)
    if feature.kind == "task" then return view().taskLegend or Forest.isTaskActive(feature) end
    return view().claimedInLegend or not Forest.isNodeClaimed(feature.key)
end

local LEGEND_LISTS = { ForestFeatures.nodes, ForestFeatures.trinksTasks }
local LEGEND_TITLES = { "SKILL NODES", "TRINKS' TASKS" }
local LEGEND_NAMES = {} -- every row's name, upper case as shown
for _, list in ipairs(LEGEND_LISTS) do
    for _, feature in ipairs(list) do LEGEND_NAMES[#LEGEND_NAMES + 1] = feature.name:upper() end
end

-- Returns the node legend's heading height at a legend's width, and the heading font that fits it.
local function legendHeading(legendWidth)
    local font = fittingFont(HEADING_FONTS, LEGEND_TITLES, math.max(1, legendWidth - 16))
    return view().simpleLegends and 0 or font.size + HEADING_PADDING * 2, font
end

-- Returns the node legend's rows shown: { rows, headings (the tasks' heading goes with any task row shown),
-- hiddenKey (the rows left out, claimed nodes and tasks not active, as a string to notice a change by) }.
local function legendRowsShown()
    if redraw.legendRows ~= nil then return redraw.legendRows end
    local rows, taskRows, hidden = 0, 0, {}
    for _, list in ipairs(LEGEND_LISTS) do
        for _, feature in ipairs(list) do
            if legendRowShown(feature) then
                rows = rows + 1
                if feature.kind == "task" then taskRows = taskRows + 1 end
            else
                hidden[#hidden + 1] = feature.key
            end
        end
    end
    redraw.legendRows = { rows = rows, headings = taskRows > 0 and #LEGEND_LISTS or 1,
        hiddenKey = table.concat(hidden, " ") }
    return redraw.legendRows
end

-- Returns whether the node legend shows: by its setting, while it has a row to show. With every node claimed and
-- left out and no task shown, it goes with NAVIGATE, which has nothing left to do, and the map takes its room.
local function nodeLegendShown()
    return view().nodeLegend and legendRowsShown().rows > 0
end

-- Returns a simplified node legend's width: its widest picture at the rows' height.
local function simpleLegendWidthFor(legendHeight, rowCount)
    rowCount = math.max(1, rowCount or #LEGEND_NAMES)
    local rowHeight = (legendHeight - (view().mapRoute and MAP_ROUTE_HEIGHT or 0)) / rowCount
    local widest = 0
    for _, list in ipairs(LEGEND_LISTS) do
        for _, feature in ipairs(list) do
            local size = IconSizes[feature.key]
            local scale = math.min((rowHeight - SIMPLE_ICON_INSET * 2) / size.height, LARGEST_SIMPLE_ICON_SCALE)
            widest = math.max(widest, size.width * scale)
        end
    end
    return clampedLegendWidth(widest + SIMPLE_ICON_INSET * 2, legendMinimumWidth())
end

-- Returns a node legend's width when in its own window.
local function poppedNodeLegendWidth(legendHeight)
    if view().simpleLegends then return simpleLegendWidthFor(legendHeight, legendRowsShown().rows) end
    return clampedLegendWidth(legendHeight * LEGEND_TO_MAP, LEGEND_MINIMUM_WIDTH)
end

-- Returns the node legend's width in the frame beside a map of mapSize, rounded up.
local function legendWidthFor(mapSize)
    if view().simpleLegends then
        return simpleLegendWidthFor((view().header and HEADER_HEIGHT or EDGE) + mapSize - EDGE)
    end
    return clampedLegendWidth(mapSize * LEGEND_TO_MAP, LEGEND_MINIMUM_WIDTH)
end

local function puzzleLegendHeight()
    return view().simpleLegends and SIMPLE_PUZZLE_LEGEND_HEIGHT or PUZZLE_LEGEND_HEIGHT
end

-- Returns the window size that fits the frame around a map of mapSize.
local function fittedWindowSize(mapSize)
    local shows = view()
    local width = EDGE * 2 + mapSize
    if nodeLegendShown() and not shows.nodeLegendPopped then width = width + EDGE + legendWidthFor(mapSize) end
    local height = (shows.header and HEADER_HEIGHT or EDGE) + mapSize + EDGE
    if puzzleLegendShown() and not shows.puzzleLegendPopped then height = height + puzzleLegendHeight() + EDGE end
    return width + WINDOW_EDGE_WIDTH, height + WINDOW_EDGE_HEIGHT
end

-- Sets the window's minimum to what is shown. PrettyUI's resize handle keeps its own copy of the limits.
local function setMinimumSize(window, width, height)
    window.minWidth, window.minHeight = width, height
    window.resize.minWidth, window.resize.minHeight = width, height
end

-- Shows what the forest holds in the frame as laid out.
local function showFound()
    -- A new grid may turn the zones differently.
    if parts.zonesShown ~= Forest.zones or parts.zonesTurnedBy ~= Forest.zoneTurns then placeZones() end
    paintRoutes()
    placeMarkers()
    placeSigns()
    showPlayer()
    showCounts()
end

-- Returns whether the legends must be laid out again: the puzzle legend coming or going, rows hidden or shown again,
-- the puzzles shown changing, or a simplified cell's picture switching between key and door.
local function needsLayout()
    return parts.puzzleShown ~= puzzleLegendShown() or parts.hiddenRowsKey ~= legendRowsShown().hiddenKey
        or parts.shownPairsKey ~= shownPairsKey()
end

local function showForest()
    newRedraw()
    if needsLayout() then layoutFitting() else showFound() end
end

-- Updates the map for a change in the tools held. The chosen route follows by MapWindow.showRoutes.
local function showHeld()
    if needsLayout() then
        layoutFitting()
    else
        placeMarkers()
        showCounts()
    end
end

-- Writes a button's colours only when they change.
local function showButton(button, isDown)
    local colour = isDown and BUTTON_DOWN_COLOUR or BUTTON_COLOUR
    if button.colour ~= colour then
        button.colour = colour
        button.cell.rgba = colour
    end
    if button.isDown ~= isDown then
        button.isDown = isDown
        button.text.rgba = isDown and HEADING_COLOUR or TEXT_COLOUR
    end
end

-- Draws the node legend's border and the dividers between its rows and between its two lists.
local function drawNodeOverlay(canvas, box)
    canvas:AddOutline(box.left, box.top, box.width, box.height, 1, FRAME_LINE_COLOUR)
    for _, lineY in ipairs(box.lines) do
        canvas:AddLine(box.left + LEGEND_LINE_INSET, lineY, box.left + box.width - LEGEND_LINE_INSET, lineY, 1,
            FRAME_LINE_COLOUR)
    end
end

-- Draws the puzzle legend's border, a divider before each column but the first and before SOLVE, and each cell's arrow.
local function drawPuzzleOverlay(canvas, box)
    canvas:AddOutline(box.left, box.top, box.width, box.height, 1, FRAME_LINE_COLOUR)
    for index = 1, box.pairCount do
        local lineX = index < box.pairCount and math.floor(box.left + index * box.pairWidth) or box.cellsRight
        canvas:AddLine(lineX, box.top + LEGEND_LINE_INSET, lineX, box.top + box.height - LEGEND_LINE_INSET, 1,
            FRAME_LINE_COLOUR)
        if not box.simple then
            local arrowX = math.floor(box.left + (index - 0.5) * box.pairWidth)
            local arrowY = math.floor(box.arrowY)
            canvas:AddTriangle(arrowX - 5, arrowY - 6, arrowX + 6, arrowY, arrowX - 5, arrowY + 6, TEXT_COLOUR)
        end
    end
end

-- Draws the frame's panels and outlines, and the legends' borders, arrows and dividers on an overlay above the cells
-- in the frame, as the cells would cover them if drawn under.
local function drawFrame()
    local canvas, frame = parts.chrome, parts.frame
    canvas:Clear()
    canvas:AddRectangle(frame.left, frame.top, frame.width, frame.height, FRAME_COLOUR)
    canvas:AddOutline(frame.left, frame.top, frame.width, frame.height, 2, FRAME_LINE_COLOUR)
    canvas:AddOutline(frame.mapLeft - 2, frame.mapTop - 2, frame.mapSize + 4, frame.mapSize + 4, 2, FRAME_LINE_COLOUR)
    parts.overlay:Clear()
    if parts.puzzleShown and parts.puzzleHost.window == nil then drawPuzzleOverlay(parts.overlay, parts.puzzleBox) end
    if parts.legendShown and parts.nodeHost.window == nil then drawNodeOverlay(parts.overlay, parts.nodeBox) end
end

-- Outlines the cell whose route is drawn, covers the rows of absent nodes, and shows the buttons pressed or not.
function showLegendStates()
    for _, pair in ipairs(parts.puzzlePairs) do
        setHidden(pair.outline, not parts.puzzleShown or not pair.isShown
            or pair.toolPair.source.key ~= RouteChoice.shown)
    end
    for _, row in ipairs(parts.legendRows) do
        setHidden(row.outline, not row.isShown or row.feature.key ~= RouteChoice.shown)
        setHidden(row.missing, not row.isShown or not row.isNeeded)
        if row.claimedBackground ~= nil then -- (nodes only)
            setHidden(row.claimedBackground, not row.isShown or not row.isClaimedAbsent)
        end
    end
    showButton(parts.solveButton, RouteChoice.solving)
    showButton(parts.mapRouteButton, RouteChoice.mapping)
end

local function layoutNodeLegend(box)
    local shows, showsLegend = view(), parts.legendShown
    local left, legendWidth = box.left, box.width
    -- NAVIGATE and the covers are as wide as the dividers, inside the legend's border, or the legend's whole width
    -- when simplified.
    local lineInset = shows.simpleLegends and 1 or LEGEND_LINE_INSET
    box.lines = {}
    local rowsHeight = box.height - (shows.mapRoute and MAP_ROUTE_HEIGHT or 0)
    local simple = shows.simpleLegends
    local showsTexts = showsLegend and not simple
    local headingHeight, headingFontEntry = legendHeading(legendWidth)
    local legendRows = legendRowsShown()
    local rowsShown, headingsShown = legendRows.rows, legendRows.headings
    local rowHeight = rowsShown > 0 and (rowsHeight - headingHeight * headingsShown) / rowsShown or 0
    -- Kept so the legend's own window can keep its rows as tall when rows come or go.
    if rowsShown > 0 then parts.nodeRowHeight = rowHeight end
    parts.nodeRowCount = rowsShown
    local iconWidth = simple and legendWidth - 12 or math.min(70, rowHeight * 1.5, legendWidth * 0.26)
    local skillWidth = math.min(44, rowHeight * 1.2, legendWidth * 0.16)
    local nameWidth = legendWidth - iconWidth - skillWidth - 24
    -- Names use the largest font the widest name fits, no taller than its share of a row.
    local nameFontEntry = fittingFont(NAME_FONTS, LEGEND_NAMES, math.max(1, nameWidth), rowHeight * NAME_TO_ROW)
    -- Fonts are written only when they change, as this runs on every step of a resize.
    local headingFontChanged, nameFontChanged = parts.headingFont ~= headingFontEntry, parts.nameFont ~= nameFontEntry
    parts.headingFont, parts.nameFont = headingFontEntry, nameFontEntry
    local rowTop = box.top
    local nextRow = 1
    for headingIndex, heading in ipairs(parts.legendHeadings) do
        local headingShown = headingIndex <= headingsShown
        if headingFontChanged then heading.text.font = headingFontEntry.id end
        setHidden(heading.text, not showsTexts or not headingShown)
        setBox(heading.text, left, rowTop, legendWidth, headingHeight)
        if headingShown then rowTop = rowTop + headingHeight end
        for index = nextRow, nextRow + heading.rowCount - 1 do
            local row = parts.legendRows[index]
            -- The outline and red cover are shown or hidden by showLegendStates, which follows.
            local rowShown = legendRowShown(row.feature)
            row.isShown = showsLegend and rowShown
            setAllHidden(not row.isShown, row.cell, row.icon)
            setAllHidden(not showsTexts or not rowShown, row.name, row.skill)
            if rowShown then box.lines[#box.lines + 1] = math.floor(rowTop) end
            setBox(row.cell, left + 1, rowTop, legendWidth - 2, rowHeight)
            setBoxes(row.outline, row.hover, left + 2, rowTop + 1, legendWidth - 4, rowHeight - 2)
            if not row.hover.hidden then row.hover.hidden = true end
            if simple then
                setIconIn(row.icon, row.feature.key, left + SIMPLE_ICON_INSET, rowTop + SIMPLE_ICON_INSET,
                    legendWidth - SIMPLE_ICON_INSET * 2, rowHeight - SIMPLE_ICON_INSET * 2, LARGEST_SIMPLE_ICON_SCALE)
            else
                setIconIn(row.icon, row.feature.key, left + 6, rowTop + 3, iconWidth, rowHeight - 6,
                    LARGEST_LEGEND_ICON_SCALE)
            end
            if nameFontChanged then row.name.font = nameFontEntry.id end
            setBox(row.missing, left + lineInset, rowTop, legendWidth - lineInset * 2, rowHeight)
            if row.claimedBackground ~= nil then
                setBox(row.claimedBackground, left + lineInset, rowTop, legendWidth - lineInset * 2, rowHeight)
            end
            setBox(row.name, left + iconWidth + 12, rowTop, nameWidth, rowHeight)
            if row.skill ~= nil then
                -- The game's icon is square, as large as the column allows.
                local size = math.min(skillWidth, rowHeight - 6)
                setBox(row.skill, left + legendWidth - 6 - (skillWidth + size) / 2,
                    rowTop + (rowHeight - size) / 2, size, size)
            end
            if rowShown then rowTop = rowTop + rowHeight end
        end
        nextRow = nextRow + heading.rowCount
        -- NAVIGATE goes under the node rows, before the tasks.
        if headingIndex == 1 then
            local button = parts.mapRouteButton
            showButtonParts(button, showsLegend and shows.mapRoute, simple)
            setButtonBox(button, left + lineInset, rowTop, legendWidth - lineInset * 2, MAP_ROUTE_HEIGHT - 1)
            if shows.mapRoute then rowTop = rowTop + MAP_ROUTE_HEIGHT end
        end
        if headingIndex < headingsShown then box.lines[#box.lines + 1] = math.floor(rowTop) end
    end
    parts.nodeBox = box
end

local function layoutPuzzleLegend(box)
    local showsPuzzle, top, height = parts.puzzleShown, box.top, box.height
    local simple = view().simpleLegends
    -- The pictures take the height above the names (40 in the frame), or all of it when simplified.
    local iconHeight = simple and height - 8 or math.max(40, height - TEXT_HEIGHT - 6)
    box.simple, box.arrowY = simple, top + 4 + iconHeight / 2
    local solveWidth = simple and SIMPLE_SOLVE_BUTTON_WIDTH or SOLVE_BUTTON_WIDTH
    -- Only the puzzles shown take a cell; the others are hidden.
    local shownPairs = shownPuzzlePairs()
    parts.shownPairsKey = shownPairsKey()
    local isShown = {}
    for _, pair in ipairs(shownPairs) do isShown[pair] = true end
    for _, pair in ipairs(parts.puzzlePairs) do
        pair.isShown = isShown[pair] == true
        if not pair.isShown then setAllHidden(true, pair.cell, pair.source, pair.barrier, pair.label, pair.outline) end
    end
    -- A simplified cell shows its key's picture, or its door's while the key is held, matching the full legend's name.
    local held = ToolsHeld.held
    box.pairCount = math.max(1, #shownPairs)
    box.pairWidth = (box.width - EDGE - solveWidth) / box.pairCount
    box.cellsRight = box.left + box.width - solveWidth
    local cellsRight = box.cellsRight
    for index, pair in ipairs(shownPairs) do
        local cellLeft = math.floor(box.left + (index - 1) * box.pairWidth)
        local cellRight = index < box.pairCount and math.floor(box.left + index * box.pairWidth) or cellsRight
        local middle = box.left + (index - 0.5) * box.pairWidth
        local iconBox = math.min(math.max(54, iconHeight), box.pairWidth / 2 - 12)
        local showsDoorAlone = simple and held[pair.toolPair.source.key] == true
        setHidden(pair.cell, not showsPuzzle)
        setHidden(pair.source, not showsPuzzle or showsDoorAlone)
        setHidden(pair.barrier, not showsPuzzle or (simple and not showsDoorAlone))
        setHidden(pair.label, not showsPuzzle or (simple and not pair.isKeyUnseen))
        -- inside the legend's 1-pixel border, like the node rows, so the border shows
        local cellStart = index == 1 and cellLeft + 1 or cellLeft
        setBox(pair.cell, cellStart, top + 1, cellRight - cellStart, height - 2)
        setBoxes(pair.outline, pair.hover, cellLeft + 1, top + 1, cellRight - cellLeft - 2, height - 2)
        if not pair.hover.hidden then pair.hover.hidden = true end
        if simple then
            local width = box.pairWidth - 12
            local icon, key = pair.source, pair.toolPair.source.key
            if showsDoorAlone then icon, key = pair.barrier, pair.toolPair.barrier.key end
            setIconIn(icon, key, middle - width / 2, top + 4, width, iconHeight, LARGEST_SIMPLE_ICON_SCALE)
        else
            setIconIn(pair.source, pair.toolPair.source.key, middle - 10 - iconBox, top + 4, iconBox, iconHeight, 1)
            setIconIn(pair.barrier, pair.toolPair.barrier.key, middle + 10, top + 4, iconBox, iconHeight, 1)
        end
        -- Simplified, the label is only the unseen key's hint, over the middle of the cell, wrapping onto two lines
        -- as the cell is narrow.
        local labelLines = simple and 2 or 1
        if pair.label.maxLines ~= labelLines then pair.label.maxLines = labelLines end
        if simple then
            setBox(pair.label, cellLeft + 2, top + 1, cellRight - cellLeft - 4, height - 2)
        else
            setBox(pair.label, middle - box.pairWidth / 2, top + height - TEXT_HEIGHT - 1, box.pairWidth, TEXT_HEIGHT)
        end
    end
    local solveButton = parts.solveButton
    showButtonParts(solveButton, showsPuzzle, simple)
    -- inset in its column, clear of the border and divider
    setButtonBox(solveButton, cellsRight + SOLVE_INSET, top + SOLVE_INSET, solveWidth - SOLVE_INSET * 2,
        height - SOLVE_INSET * 2)
    parts.puzzleBox = box
end

-- Lays out a legend in its own window (host): the frame's colour behind it, and its overlay.
local function layoutPopped(host)
    local root = host.window.root
    local box = { left = 0, top = 0, width = root.width - WINDOW_EDGE_WIDTH, height = root.height - WINDOW_EDGE_HEIGHT }
    host.chrome:Clear()
    host.chrome:AddRectangle(0, 0, box.width, box.height, FRAME_COLOUR)
    host.overlay:Clear()
    if host == parts.nodeHost then
        layoutNodeLegend(box)
        drawNodeOverlay(host.overlay, box)
    else
        layoutPuzzleLegend(box)
        drawPuzzleOverlay(host.overlay, box)
    end
    showLegendStates()
end

-- Hides a window without destroying it, as PrettyUI's Close does without destroyOnClose.
-- PrettyUI 1.4.0's Window:Hide will replace it.
local function hideWindow(window)
    window.root.hidden = true
    if window.titleDrag then window.titleDrag.hidden = true end
    window:_SyncOverlays(true)
end

local function legendWindowShown()
    for _, host in ipairs({ parts.nodeHost, parts.puzzleHost }) do
        if host.window ~= nil and host.window.root.hidden ~= true then return true end
    end
    return false
end

-- Closes the map on the next frame if nothing of it shows then: hidden by its X, with no legend window left.
-- A legend window hides as its legend goes, in the middle of a layout, so the map cannot be destroyed there.
local CLOSE_SUBSCRIPTION = "nemi_mapper_map_close"
local function closeWhenNothingShows()
    Event.Draw.Subscribe(CLOSE_SUBSCRIPTION, function()
        Event.Draw.Unsubscribe(CLOSE_SUBSCRIPTION)
        if isOpen() and parts.window.root.hidden == true and not legendWindowShown() then MapWindow.close() end
    end)
end

local function showPoppedWindows()
    for _, host in ipairs({ parts.nodeHost, parts.puzzleHost }) do
        local window = host.window
        if window ~= nil then
            local legendShown = parts.puzzleShown
            if host == parts.nodeHost then legendShown = parts.legendShown end
            local shown = not parts.closedPopped[window] and legendShown
            if shown and window.root.hidden == true then
                window:Show()
            elseif not shown and window.root.hidden ~= true then
                hideWindow(window)
                if parts.window.root.hidden == true and not legendWindowShown() then closeWhenNothingShows() end
            end
        end
    end
end

-- Lays the frame out in the window's content, contentWidth by contentHeight.
local function layout(contentWidth, contentHeight)
    -- A part shown again (the puzzle legend in a new forest, the header in map sharing mode) can raise the minimum.
    -- The window then grows to it, and SetSize lays it out again.
    local minimumWidth, minimumHeight = fittedWindowSize(MINIMUM_MAP_SIZE)
    if parts.window.minWidth ~= minimumWidth or parts.window.minHeight ~= minimumHeight then
        setMinimumSize(parts.window, minimumWidth, minimumHeight)
        local windowWidth, windowHeight = contentWidth + WINDOW_EDGE_WIDTH, contentHeight + WINDOW_EDGE_HEIGHT
        if windowWidth < minimumWidth or windowHeight < minimumHeight then
            return parts.window:SetSize(math.max(windowWidth, minimumWidth), math.max(windowHeight, minimumHeight))
        end
    end
    parts.contentWidth, parts.contentHeight = contentWidth, contentHeight
    local shows = view()
    local showsPuzzle, showsHeader, showsLegend = puzzleLegendShown(), shows.header, nodeLegendShown()
    parts.puzzleShown, parts.legendShown, parts.simpleShown = showsPuzzle, showsLegend, shows.simpleLegends
    parts.headerShown = showsHeader
    local nodePopped, puzzlePopped = parts.nodeHost.window ~= nil, parts.puzzleHost.window ~= nil
    local legendInFrame, puzzleInFrame = showsLegend and not nodePopped, showsPuzzle and not puzzlePopped
    local puzzleLegendTall = puzzleLegendHeight()
    local puzzleHeight = puzzleInFrame and puzzleLegendTall + EDGE or 0
    local headerHeight = showsHeader and HEADER_HEIGHT or EDGE
    local widthRoom = contentWidth - EDGE * 2 - (legendInFrame and EDGE or 0)
    local leastLegendWidth = legendMinimumWidth()
    -- The legend is a share of the map's width but kept between its least and greatest widths, so the map takes
    -- what the legend leaves of the width.
    local mapWidth = widthRoom
    local heightLimit = contentHeight - headerHeight - EDGE - puzzleHeight
    if legendInFrame and shows.simpleLegends then
        -- A simplified legend's width follows the rows' height, so the map's size is found by a few rounds of
        -- giving the map what the legend for that size leaves. Each round moves less than the last.
        mapWidth = math.min(heightLimit, widthRoom - leastLegendWidth)
        for _ = 1, 4 do mapWidth = math.min(heightLimit, widthRoom - legendWidthFor(math.floor(mapWidth))) end
    elseif legendInFrame then
        mapWidth = math.min(widthRoom - leastLegendWidth,
            math.max(widthRoom - LEGEND_MAXIMUM_WIDTH, widthRoom / (1 + LEGEND_TO_MAP)))
    end
    local mapSize = math.floor(math.min(heightLimit, mapWidth))
    local legendWidth = 0
    if legendInFrame and shows.simpleLegends then
        legendWidth = math.min(legendWidthFor(mapSize), widthRoom - mapSize)
    elseif legendInFrame then
        -- rounded up like the fitted width, so a fitted window shows no slack beside the legend
        legendWidth = clampedLegendWidth(math.min(mapSize * LEGEND_TO_MAP, widthRoom - mapSize), leastLegendWidth)
    end
    local frame = {
        width = EDGE * 2 + mapSize + (legendInFrame and legendWidth + EDGE or 0),
        height = headerHeight + mapSize + EDGE + puzzleHeight,
        mapSize = mapSize,
        iconScale = mapSize / PACK_MAP_SIZE,
    }
    frame.left = math.floor((contentWidth - frame.width) / 2)
    frame.top = math.floor((contentHeight - frame.height) / 2)
    frame.mapLeft, frame.mapTop = frame.left + EDGE, frame.top + headerHeight
    parts.frame = frame

    setBox(parts.chrome, 0, 0, contentWidth, contentHeight)
    setBox(parts.map, frame.mapLeft, frame.mapTop, mapSize, mapSize)
    setBox(parts.duplicatesText, 8, mapSize - TEXT_HEIGHT - 6, mapSize - 16, TEXT_HEIGHT)
    setBox(parts.keysUnseenLine.text, 8, mapSize - 2 * TEXT_HEIGHT - 6, mapSize - 16, TEXT_HEIGHT)
    placeCompassSprite(parts.compassRing, COMPASS_RING_PIXELS, frame)
    placeCompassSprite(parts.compassBacking, COMPASS_BACKING_PIXELS, frame)
    placeCompassSprite(parts.compass, COMPASS_NEEDLE_PIXELS, frame)
    setAllHidden(not showsHeader, parts.countLine.text, parts.headerLine.text)
    if showsHeader then placeHeaderTexts() end

    -- A node legend window's height follows its rows: when rows come or go (nodes claimed, another setting), each
    -- row keeps its height, so the window shrinks or grows by the rows'.
    local legendRows = legendRowsShown()
    local rowsNow, headingsNow = legendRows.rows, legendRows.headings
    parts.hiddenRowsKey = legendRows.hiddenKey
    if nodePopped then
        local window = parts.nodeHost.window
        local headingHeight = legendHeading(window.root.width - WINDOW_EDGE_WIDTH)
        local fixedHeight = (shows.mapRoute and MAP_ROUTE_HEIGHT or 0) + headingHeight * headingsNow
            + WINDOW_EDGE_HEIGHT
        local leastHeight = fixedHeight + rowsNow * LEAST_LEGEND_ROW_HEIGHT
        local leastWidth = poppedNodeLegendWidth(leastHeight - WINDOW_EDGE_HEIGHT) + WINDOW_EDGE_WIDTH
        setMinimumSize(window, leastWidth, leastHeight)
        local height = window.root.height
        if parts.nodeRowHeight ~= nil and rowsNow ~= parts.nodeRowCount then
            height = math.floor(fixedHeight + parts.nodeRowHeight * rowsNow + 0.5)
        end
        height = math.max(height, leastHeight)
        local width = math.max(window.root.width, leastWidth)
        if width ~= window.root.width or height ~= window.root.height then window:SetSize(width, height) end
    end
    -- A puzzle legend window's least size follows the simplified legends setting, and the window grows to it.
    if puzzlePopped then
        local window = parts.puzzleHost.window
        local leastWidth = shows.simpleLegends
            and math.max(1, #shownPuzzlePairs()) * SIMPLE_PAIR_LEAST_WIDTH + EDGE + SIMPLE_SOLVE_BUTTON_WIDTH
                + WINDOW_EDGE_WIDTH
            or PUZZLE_WINDOW_LEAST_WIDTH
        local leastHeight = puzzleLegendTall + WINDOW_EDGE_HEIGHT
        setMinimumSize(window, leastWidth, leastHeight)
        if window.root.width < leastWidth or window.root.height < leastHeight then
            window:SetSize(math.max(window.root.width, leastWidth), math.max(window.root.height, leastHeight))
        end
    end
    -- The node legend beside the map, from the frame's top to the map's foot, and the puzzle legend under both.
    if nodePopped then
        layoutPopped(parts.nodeHost)
    else
        layoutNodeLegend({ left = frame.mapLeft + mapSize + EDGE, top = frame.top + EDGE, width = legendWidth,
            height = headerHeight + mapSize - EDGE })
    end
    if puzzlePopped then
        layoutPopped(parts.puzzleHost)
    else
        layoutPuzzleLegend({ left = frame.mapLeft, top = frame.mapTop + mapSize + EDGE, width = frame.width - EDGE * 2,
            height = puzzleLegendTall })
    end
    setBox(parts.overlay, 0, 0, contentWidth, contentHeight)
    drawFrame()
    showPoppedWindows()
    parts.zonesShown = nil -- place every zone again at the new size
    showFound()
end

-- Builds the map's components in drawing order: the frame's panels, then the map layer with the zones, routes, found
-- features, entrance signs and the player clipped at its edges, then the compass, texts and legends on the frame.
local function build(nodeWindow, puzzleWindow)
    local content = parts.window.content
    parts.chrome = create(ui.Canvas, content)
    parts.map = create(ui.Layer, content)
    local mapBackground = create(ui.Rectangle, parts.map)
    mapBackground.fill = true
    mapBackground.rgba = FOREST_COLOUR
    parts.zoneLayer = create(ui.Layer, parts.map)
    parts.zones = {}
    parts.routes = create(ui.Canvas, parts.map)
    parts.routeStart = create(ui.Canvas, parts.map)
    parts.restJoint, parts.restPainted, parts.markerOf = {}, nil, {}
    parts.markerLayer = create(ui.Layer, parts.map)
    parts.markers = {}
    local signLayer = create(ui.Layer, parts.map)
    for _, filling in ipairs({ mapBackground, parts.zoneLayer, parts.routes, parts.routeStart, parts.markerLayer,
        signLayer }) do
        filling:SetSize(0, 0, 1.0, 1.0) -- fills the map layer
    end
    -- A click on a sign chooses or drops the route to its opening.
    parts.signs = {}
    for _, sign in ipairs(ForestFeatures.entranceSigns) do
        local shown = { key = sign.key, side = sign.side, sprite = addIcon(signLayer, sign.key) }
        makeRoutable(shown.sprite, shown, function() return sign.key end)
        parts.signs[#parts.signs + 1] = shown
    end
    parts.playerMarker = create(ui.Rectangle, parts.map)
    parts.playerMarker.fill = true
    parts.playerMarker.rgba = PLAYER_COLOUR
    parts.duplicatesText = addText(parts.map, TEXT_FONT, TEXT_COLOUR, ui.AlignMode.TOPLEFT,
        "DUPLICATE NODES DO NOT GIVE EXP")
    parts.keysUnseenLine = StatusText.new(addText(parts.map, TEXT_FONT, TEXT_COLOUR, ui.AlignMode.TOPLEFT))
    setHidden(parts.keysUnseenLine.text, true)

    -- The ring is filled in the middle, so it goes under the backing and needle.
    parts.compassRing = addGameSprite(content, COMPASS_RING_SPRITE)
    parts.compassBacking = addGameSprite(content, COMPASS_BACKING_SPRITE)
    parts.compass = addGameSprite(content, COMPASS_SPRITE)
    parts.countLine = StatusText.new(addText(content, HEADER_FONT, TEXT_COLOUR, ui.AlignMode.TOPLEFT))
    parts.headerLine = StatusText.new(addText(content, HEADER_FONT, TEXT_COLOUR, ui.AlignMode.BOTTOMRIGHT))
    StatusText.set(parts.headerLine, Settings.headerText)

    -- Returns where a legend draws: the frame, or its own window, with a canvas of its own there for its
    -- background, border and dividers.
    local function hostIn(window)
        if window == nil then return { content = content, chrome = parts.chrome } end
        return { window = window, content = window.content, chrome = create(ui.Canvas, window.content) }
    end
    parts.nodeHost, parts.puzzleHost = hostIn(nodeWindow), hostIn(puzzleWindow)

    -- Adds a legend entry's cell, its click target: a filled rectangle under the entry's icons,
    -- which pass clicks through.
    -- A click draws the route and another drops it.
    -- A click does nothing while cannotClick says so.
    local function addCell(content, key, cannotClick)
        local cell = create(ui.Rectangle, content)
        cell.fill = true
        cell.rgba = FRAME_COLOUR
        cell.clickthrough = false
        cell:Subscribe(ui.Hook.ONCLICK, function()
            if not cannotClick() then toggleRoute(key) end
            return true
        end)
        return cell
    end
    local function addOutline(content, colour)
        local outline = create(ui.Rectangle, content)
        outline.fill = false
        outline.outlineThickness = 2
        outline.rgba = colour
        return outline
    end
    -- Adds a white outline over a cell under the mouse, unless cannotClick says a click there does nothing.
    local function addHover(content, cell, cannotClick)
        local hover = addOutline(content, HOVER_COLOUR)
        hover.hidden = true
        cell:Subscribe(ui.Hook.ONMOUSEOVER, function()
            hover.hidden = cannotClick()
            return true
        end)
        cell:Subscribe(ui.Hook.ONMOUSELEAVE, function()
            hover.hidden = true
            return true
        end)
        return hover
    end
    -- Adds a button in the frame's blues, brighter under the mouse and while pressed.
    local function addButton(content, label, onClick)
        local button = { cell = create(ui.Rectangle, content) }
        button.cell.fill = true
        button.cell.rgba = BUTTON_COLOUR
        button.cell.clickthrough = false
        button.cell:Subscribe(ui.Hook.ONCLICK, function() onClick() return true end)
        button.cell:Subscribe(ui.Hook.ONMOUSEOVER, function()
            if not button.isDown then
                button.colour = BUTTON_OVER_COLOUR
                button.cell.rgba = BUTTON_OVER_COLOUR
            end
            return true
        end)
        button.cell:Subscribe(ui.Hook.ONMOUSELEAVE, function() showButton(button, button.isDown) return true end)
        button.text = addText(content, TEXT_FONT, TEXT_COLOUR, ui.AlignMode.CENTRE, label)
        button.icon = addGameSprite(content, PATHS_ICON_SPRITE)
        return button
    end

    -- The node and task legend. Its NAVIGATE button plans a route through every node not claimed today.
    content = parts.nodeHost.content
    parts.legendHeadings, parts.legendRows = {}, {}
    for listIndex, list in ipairs(LEGEND_LISTS) do
        parts.legendHeadings[#parts.legendHeadings + 1] = {
            text = addText(content, TEXT_FONT, HEADING_COLOUR, ui.AlignMode.CENTRE, LEGEND_TITLES[listIndex]),
            rowCount = #list,
        }
        for _, feature in ipairs(list) do
            local row = { feature = feature, nameText = feature.name:upper() }
            local function cannotRoute() return not row.canRoute end
            row.cell = addCell(content, feature.key, cannotRoute)
            -- over the cell, under the row's picture and name
            if feature.kind == "node" then
                row.claimedBackground = addGameSprite(content, WINDOW_BACKGROUND_SPRITE)
                row.claimedBackground.isTiling = true
            end
            row.icon = addIcon(content, feature.key)
            -- centred between the icon and the skill symbol
            row.name = addText(content, TEXT_FONT, TEXT_COLOUR, ui.AlignMode.CENTRE, row.nameText)
            -- the game's skill icons; the SKILL_<skill> sprites are the daily tasks' set, not these
            if feature.skill ~= nil then
                row.skill = addGameSprite(content, id.Sprite["HITMARK_ICON_SKILL_" .. feature.skill:upper()])
            end
            -- covers the row of a node that is absent but still unclaimed today
            row.missing = create(ui.Rectangle, content)
            row.missing.fill = true
            row.missing.rgba = MISSING_COLOUR
            row.outline = addOutline(content, ForestFeatures.colourOf(feature))
            row.hover = addHover(content, row.cell, cannotRoute)
            parts.legendRows[#parts.legendRows + 1] = row
        end
    end
    -- The buttons' plans need the player in the forest, so they do nothing outside it.
    parts.mapRouteButton = addButton(content, "NAVIGATE", function()
        if Forest.isInside then RouteChoice.choose(nil, false, not RouteChoice.mapping) end
    end)
    if nodeWindow ~= nil then parts.nodeHost.overlay = create(ui.Canvas, content) end

    -- The puzzle legend. Its SOLVE button plans a route through every key and barrier.
    content = parts.puzzleHost.content
    parts.puzzlePairs = {}
    for _, toolPair in ipairs(ForestFeatures.tools) do
        local pair = { toolPair = toolPair }
        local function cannotRoute() return not pair.canRoute end
        pair.cell = addCell(content, toolPair.source.key, cannotRoute)
        pair.source = addIcon(content, toolPair.source.key)
        pair.barrier = addIcon(content, toolPair.barrier.key)
        pair.label = addText(content, SMALL_FONT, TEXT_COLOUR, ui.AlignMode.CENTRE, toolPair.tool)
        pair.outline = addOutline(content, toolPair.colour)
        pair.hover = addHover(content, pair.cell, cannotRoute)
        parts.puzzlePairs[#parts.puzzlePairs + 1] = pair
    end
    if puzzleWindow ~= nil then parts.puzzleHost.overlay = create(ui.Canvas, content) end
    -- The frame's overlay covers the legends in the frame, so it is made after them.
    parts.overlay = create(ui.Canvas, parts.window.content)
    parts.solveButton = addButton(content, "SOLVE", function()
        if Forest.isInside then RouteChoice.choose(nil, not RouteChoice.solving, false) end
    end)
end

-- The legends' own windows.
-- Each opens beside the map the first time (the puzzle legend's under it), and keeps its place and size after.
local LEGEND_DEFAULT_WIDTH = clampedLegendWidth(DEFAULT_MAP_SIZE * LEGEND_TO_MAP, LEGEND_MINIMUM_WIDTH)
local POPPED_WINDOWS = {
    { host = "nodeHost", place = "nodeLegend", title = "Node legend",
        width = LEGEND_DEFAULT_WIDTH + WINDOW_EDGE_WIDTH, defaultHeight = DEFAULT_MAP_SIZE + WINDOW_EDGE_HEIGHT,
        minWidth = LEGEND_MINIMUM_WIDTH + WINDOW_EDGE_WIDTH, minHeight = MINIMUM_MAP_SIZE + WINDOW_EDGE_HEIGHT },
    { host = "puzzleHost", place = "puzzleLegend", title = "Puzzle legend",
        width = EDGE + DEFAULT_MAP_SIZE + LEGEND_DEFAULT_WIDTH + WINDOW_EDGE_WIDTH,
        under = true, minWidth = PUZZLE_WINDOW_LEAST_WIDTH }, -- openPopped sets its height
}

-- Saves the window's place, destroys its legends' own windows, and forgets it.
local function release()
    WindowPlace.remember(parts.window.root, "map")
    for _, popped in ipairs(POPPED_WINDOWS) do
        local window = parts[popped.host].window
        if window ~= nil then
            WindowPlace.remember(window.root, popped.place)
            window:Destroy()
        end
    end
    parts = nil
    Event.ServerLogic.Unsubscribe(FINAL_ROUTE_SUBSCRIPTION)
    Event.Draw.Unsubscribe(RESIZE_END_SUBSCRIPTION)
end

-- Returns the parts around the map in the window's frame (the header, and the legends neither hidden nor in their own
-- windows), as a string to compare.
local function framePartsShown()
    return (parts.headerShown and "header " or "")
        .. (parts.legendShown and parts.nodeHost.window == nil and "node " or "")
        .. (parts.puzzleShown and parts.puzzleHost.window == nil and "puzzle " or "")
        .. (parts.simpleShown and "simple" or "")
end

-- Fits the window to the frame around a map of mapSize, within the plugin layer.
local function fitWindowTo(mapSize)
    local width, height = fittedWindowSize(mapSize)
    parts.window:SetSize(math.min(width, parts.pluginLayer.width), math.min(height, parts.pluginLayer.height))
end

-- Lays the frame out again, fitting the window to it when parts come or go.
layoutFitting = function()
    local mapSize, partsBefore = parts.frame.mapSize, framePartsShown()
    layout(parts.contentWidth, parts.contentHeight)
    if framePartsShown() ~= partsBefore then fitWindowTo(mapSize) end
end

-- Fits the window to the frame once a resize ends, so no background shows.
-- Draw is watched only during a drag.
local function fitAfterResize()
    if not isOpen() then return Event.Draw.Unsubscribe(RESIZE_END_SUBSCRIPTION) end
    if parts.window.resize.dragState ~= nil then return end
    Event.Draw.Unsubscribe(RESIZE_END_SUBSCRIPTION)
    fitWindowTo(parts.frame.mapSize)
end

-- Builds the map again with its legends where the settings now put them, keeping the map's size: the window shrinks
-- as a legend leaves it for its own window, and grows as it comes back.
local function rebuild()
    local mapSize, PrettyUI, pluginLayer = parts.frame.mapSize, parts.PrettyUI, parts.pluginLayer
    MapWindow.close()
    MapWindow.open(PrettyUI, pluginLayer)
    fitWindowTo(mapSize)
end

-- Shrinks or grows the legends' own windows with their legends when simplified legends are turned on or off.
-- The node legend's fits its legend's width at the window's height, leaving no room beside a simplified legend's
-- pictures. The puzzle legend's changes by what the legend gains or loses (SOLVE's column and the line of names) from
-- its size before (puzzleSize).
local function fitPoppedWindows(puzzleSize)
    local simple = view().simpleLegends
    local window = parts.nodeHost.window
    if window ~= nil then
        local width = poppedNodeLegendWidth(window.root.height - WINDOW_EDGE_HEIGHT) + WINDOW_EDGE_WIDTH
        window:SetSize(math.max(width, window.minWidth), window.root.height)
    end
    window = parts.puzzleHost.window
    if window ~= nil then
        local sign = simple and -1 or 1
        local widthChange = SOLVE_BUTTON_WIDTH - SIMPLE_SOLVE_BUTTON_WIDTH
        window:SetSize(math.max(window.minWidth, puzzleSize[1] + sign * widthChange),
            math.max(window.minHeight, puzzleSize[2] + sign * (PUZZLE_LEGEND_HEIGHT - SIMPLE_PUZZLE_LEGEND_HEIGHT)))
    end
end

-- Opens a legend's own window.
-- Its X hides it until the map is opened again; the legend stays out of the map.
-- With the map hidden, the last one closed closes the map.
local function openPopped(popped)
    local mapRoot, pluginLayer = parts.window.root, parts.pluginLayer
    -- The puzzle legend's window is as high as the legend in the frame, at least and at first.
    local minimumHeight, defaultHeight = popped.minHeight, popped.defaultHeight
    if popped.under then
        minimumHeight = puzzleLegendHeight() + WINDOW_EDGE_HEIGHT
        defaultHeight = minimumHeight
    end
    local besideX, besideY = mapRoot.x + mapRoot.width, mapRoot.y
    if popped.under then besideX, besideY = mapRoot.x, mapRoot.y + mapRoot.height end
    local x, y, width, height = WindowPlace.restore(pluginLayer, popped.place, popped.width, defaultHeight, nil,
        besideX, besideY)
    local window = parts.PrettyUI.Window.new(pluginLayer, {
        categoryID = "auto", title = popped.title, x = x, y = y, width = width, height = height,
        minWidth = popped.minWidth, minHeight = minimumHeight,
        resizable = true, scrollable = false,
    })
    window.Close = function(closingWindow)
        hideWindow(closingWindow)
        parts.closedPopped[closingWindow] = true
        if parts.window.root.hidden == true and not legendWindowShown() then MapWindow.close() end
    end
    local setWindowSize = window.SetSize
    window.SetSize = function(resizedWindow, newWidth, newHeight)
        setWindowSize(resizedWindow, newWidth, newHeight)
        layoutPopped(parts[popped.host])
    end
    return window
end

-- Opens the map, or brings it to the front if open.
function MapWindow.open(PrettyUI, pluginLayer)
    if isOpen() then
        parts.window:Show()
        if parts.mapStale then
            parts.mapStale = false
            newRedraw()
            showFound()
        end
        -- Opening the map again brings back the legend windows closed since.
        parts.closedPopped = {}
        showPoppedWindows()
        return
    end
    newRedraw()
    local minimumWidth, minimumHeight = fittedWindowSize(MINIMUM_MAP_SIZE)
    local defaultWidth, defaultHeight = fittedWindowSize(DEFAULT_MAP_SIZE)
    local x, y, width, height = WindowPlace.restore(pluginLayer, "map", defaultWidth, defaultHeight)
    local window = PrettyUI.Window.new(pluginLayer, {
        categoryID = "auto", title = "Nemi Forest map", x = x, y = y, width = width, height = height,
        minWidth = minimumWidth, minHeight = minimumHeight,
        resizable = true, scrollable = false, destroyOnClose = true,
        onClose = release, -- on the X; the window then destroys itself
    })
    parts = { window = window, hiddenOf = {}, boxOf = {}, textWidths = {}, closedPopped = {}, stopsShown = EMPTY,
        PrettyUI = PrettyUI, pluginLayer = pluginLayer }
    -- The X only hides the map while a legend's own window is shown, so that window stays open until its own X.
    local closeWindow = window.Close
    window.Close = function(closingWindow)
        if not legendWindowShown() then return closeWindow(closingWindow) end
        hideWindow(closingWindow)
    end
    parts.sharingButton = SharingButton.add(PrettyUI, window, function() MapWindow.onSharingToggled() end)
    local shows = view()
    build(shows.nodeLegendPopped and openPopped(POPPED_WINDOWS[1]) or nil,
        shows.puzzleLegendPopped and openPopped(POPPED_WINDOWS[2]) or nil)
    -- A window's content takes its new size a moment after a resize, so the layout uses the size passed to
    -- SetSize, which PrettyUI's resize handle calls on each step of a drag.
    local setWindowSize = window.SetSize
    window.SetSize = function(resizedWindow, newWidth, newHeight)
        setWindowSize(resizedWindow, newWidth, newHeight)
        layout(math.max(resizedWindow.minWidth, math.floor(newWidth)) - WINDOW_EDGE_WIDTH,
            math.max(resizedWindow.minHeight, math.floor(newHeight)) - WINDOW_EDGE_HEIGHT)
        if resizedWindow.resize.dragState ~= nil then
            Event.Draw.Subscribe(RESIZE_END_SUBSCRIPTION, fitAfterResize)
        end
    end
    -- PrettyUI clamps the window to its minimum, so the layout takes the size the window got.
    layout(window.root.width - WINDOW_EDGE_WIDTH, window.root.height - WINDOW_EDGE_HEIGHT)
    -- The saved size was fitted to the frame as it was. Settings changed since (a legend hidden, the header) would
    -- leave background around the map, so the window is fitted around the map as laid out now.
    fitWindowTo(parts.frame.mapSize)
end

-- Called when the forest changes: a find, a claim, a follower, the grid or the search ending.
function MapWindow.showForest()
    if isOpen() then showForest() end
end

-- Called when a found NPC (entry) moves: its marker follows, if shown. A route to it follows by MapWindow.showRoutes.
function MapWindow.showNpcMoved(entry)
    local marker = isOpen() and not mapHidden() and parts.markerOf[entry]
    if marker then placeMarker(marker, entry) end
end

-- Called when the tools held change without a step.
function MapWindow.showHeld()
    if not isOpen() then return end
    newRedraw()
    showHeld()
end

-- Called when the forest is left: it is gone, so the map shows none entered.
function MapWindow.showForestLeft()
    finalRouteOf = nil
    if isOpen() then showForest() end
end

-- Called when the player's tile changes: the player marker follows, and the map follows the tools held if they
-- changed (heldChanged). The chosen route follows by MapWindow.showRoutes.
function MapWindow.showPlayer(heldChanged)
    if not isOpen() then return end
    newRedraw()
    showPlayer()
    if heldChanged then showHeld() end
end

-- Called when the route chosen or drawn changes (RouteChoice.onDrawn).
function MapWindow.showRoutes()
    if not isOpen() then return end
    newRedraw()
    showRoute()
end

-- Shows the header text setting.
-- Its text takes new room from the count, and nothing else moves.
local function showHeaderText()
    if parts.headerLine.content == Settings.headerText then return end
    StatusText.set(parts.headerLine, Settings.headerText)
    if parts.headerShown then placeHeaderTexts() end
end

function MapWindow.showHeaderText()
    if isOpen() then showHeaderText() end
end

-- Called when a map display setting changes.
-- The legends, header and buttons may come or go, so the frame is laid out again.
function MapWindow.showSettings()
    if not isOpen() then return end
    parts.sharingButton:show()
    showHeaderText()
    newRedraw()
    local shows = view()
    local nodeWindow, puzzleWindow = parts.nodeHost.window, parts.puzzleHost.window
    if shows.nodeLegendPopped ~= (nodeWindow ~= nil) or shows.puzzleLegendPopped ~= (puzzleWindow ~= nil) then
        return rebuild()
    end
    local wasSimple = parts.simpleShown
    local puzzleRoot = puzzleWindow ~= nil and puzzleWindow.root
    local puzzleSize = puzzleRoot and { puzzleRoot.width, puzzleRoot.height }
    layoutFitting()
    -- Simplified legends take less room too, so the legends' own windows are fitted to them.
    if parts.simpleShown ~= wasSimple then fitPoppedWindows(puzzleSize) end
end

-- Returns whether the map is open and shown.
-- Its X only hides it while a legend's own window is shown.
function MapWindow.isOpen()
    return isOpen() and parts.window.root.hidden ~= true
end

function MapWindow.close()
    Event.Draw.Unsubscribe(CLOSE_SUBSCRIPTION)
    if not isOpen() then return end
    local window = parts.window
    release()
    window:Destroy()
end

return MapWindow

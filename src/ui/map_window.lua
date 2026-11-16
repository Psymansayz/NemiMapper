-- The map window, containing a header with the compass, the node legend beside the
-- map and the puzzle legend below it.

local IconSizes = require("src/data/icon_sizes")
local ForestFeatures = require("src/data/forest_features")
local Forest = require("src/game/forest")
local GameIds = require("src/game/game_ids")
local Routes = require("src/game/routes")
local ForestStops = require("src/game/forest_stops")
local SolvePlan = require("src/game/solve_plan")
local Highlights = require("src/game/highlights")
local ToolsHeld = require("src/game/tools_held")
local WorldNumber = require("src/game/world_number")
local Settings = require("src/data/settings")
local WindowPlace = require("src/ui/window_place")
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
local PATHS_ICON_SPRITE = GameIds.resolve("Sprite", "RS3_ICON_MENU_PATHS_0")
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
local COMPASS_BACKING_SPRITE = GameIds.resolve("Sprite", "NAVIGATION_BACKING_COMPASS")
local COMPASS_SPRITE = GameIds.resolve("Sprite", "COMPASS")
-- PrettyUI's window background, tiled behind the legend row of a node absent from this forest but claimed today, so
-- it stands apart from the red rows still to claim.
local WINDOW_BACKGROUND_SPRITE = GameIds.resolve("Sprite", "RS3_MODAL_WINDOW_CONTENT_TILE")
local COMPASS_RING_SPRITE = GameIds.resolve("Sprite", "RS3_MINIMAP_CLASSIC_RING_41PX") -- the minimap's ring
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
local OFF_ROUTE_TILES = 3 -- straying this far from the drawn route recalculates it
local RESIZE_END_SUBSCRIPTION = "nemi_mapper_map_resize_end"
-- The trail signs at the forest's openings, each on its side's edge pointing out of the forest.
-- A click routes to the sign's opening, as a click on a feature routes to it.
local ENTRANCE_SIGNS = {
    { key = "sign_otot", side = "north" },
    { key = "sign_kanatah", side = "east" },
}
local SIGN_ROUTE_COLOUR = 0xF7E1A0FF -- the signs' painted letters

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
local HINT_COLOUR = 0xF2C66DFF -- "Walk to find"
local HOVER_SCALE = 1.25 -- a map icon under the mouse grows by this, about its centre
local HOVER_COLOUR = 0xFFFFFFFF -- outline of a clickable row or pair under the mouse
local MISSING_COLOUR = 0xE0433A70 -- translucent red over a node absent from this forest but unclaimed today
-- The game's skill icons for the legend's symbols, where <S> is the skill in upper case.
-- The SKILL_<S> sprites are the daily tasks' set, not these.
local SKILL_SPRITE_PATTERN = "HITMARK_ICON_SKILL_<S>"
local function skillSpriteOf(skill)
    return GameIds.resolve("Sprite", (SKILL_SPRITE_PATTERN:gsub("<S>", skill:upper())))
end
local KEY_UNSEEN_TEXT = "Walk to find" -- a key's NPC only reaches the client near the player
local KEY_UNSEEN_NAME = KEY_UNSEEN_TEXT:upper() -- the same on a legend row, whose names are upper case
local TEXT_FONT = id.Font.MUSEO_SANS_13PT_BOLD
local HEADER_FONT = GameIds.resolve("Font", "MUSEO_SANS_19PT_BOLD") or TEXT_FONT
local SMALL_FONT = id.Font.MUSEO_SANS_11PT_REGULAR
MapWindow.onSharingToggled = nil -- called when the title bar's sharing button is clicked

-- Returns the bold fonts of these sizes as { id, size }, largest first, ending with the 11pt font (regular, as the
-- game has no 11pt bold).
-- Legend headings and names use the largest that fits.
local function boldFonts(sizes)
    local fonts = {}
    for _, size in ipairs(sizes) do
        local fontID = GameIds.resolve("Font", "MUSEO_SANS_" .. size .. "PT_BOLD")
        if fontID ~= nil then fonts[#fonts + 1] = { id = fontID, size = size } end
    end
    fonts[#fonts + 1] = { id = SMALL_FONT, size = 11 }
    return fonts
end
local HEADING_FONTS = boldFonts({ 27, 24, 21, 19, 17, 15, 13 })
local NAME_FONTS = boldFonts({ 24, 21, 19, 17, 15, 13 })
local NAME_TO_ROW = 0.5 -- a name's font is at most this share of its row, so it grows with the legend

-- The open window, or nil. It holds the window, every component made (created) with its last written state, the
-- content size, the frame's layout, the route chosen and the plans. build() makes the frame's components and is
-- not run when the pictures are missing. One route is drawn at a time. routeShown is the key of the feature clicked
-- on a legend or the map (a node's, a task's, a puzzle's source key or an entrance sign's), solving means SOLVE is
-- down and mapping means NAVIGATE is down. The final route is drawn only when none of these is set.
local parts = nil
local showLegendStates -- defined below

-- Values worked out once per redraw: the view, the tools held and the puzzle pairs shown.
local redraw = {}
local function newRedraw()
    redraw = {}
end

-- Returns a picture by its file name, with or without the extension.
local function picture(name)
    local resources = Plugin.resources
    return resources and (resources[name] or resources[name .. ".png"])
end

local function isOpen()
    if parts ~= nil and ui.Interfaces:GetInterface(parts.window.interfaceID) == nil then parts = nil end
    return parts ~= nil
end

local function isLaidOut()
    return isOpen() and parts.frame ~= nil
end

local function create(componentType, parent)
    local component = componentType.new(parent)
    component.clickthrough = true
    parts.created[#parts.created + 1] = component
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
    sprite.spriteID = spriteID or -1
    sprite.hidden = spriteID == nil
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
    if button.icon ~= nil then
        local size = math.max(1, math.min(width, height) - 8)
        setBox(button.icon, left + (width - size) / 2, top + (height - size) / 2, size, size)
    end
end

local function showButtonParts(button, isShown, simple)
    local iconShown = simple and button.icon ~= nil
    setHidden(button.cell, not isShown)
    setHidden(button.text, not isShown or iconShown)
    if button.icon ~= nil then setHidden(button.icon, not isShown or not iconShown) end
end

-- properly positions the compass sprites. Note that the game does not center the compass correctly
-- Ninja team, please fix this!
local COMPASS_CENTRE, COMPASS_SCALE = 3 + COMPASS_SIZE / 2, COMPASS_SIZE / COMPASS_RING_PIXELS
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

-- Places one sprite per zone, showing the zone it was copied from, turned as the grid has it so the picture matches the
-- routes (src/game/forest_grid.lua reads the turns from the zones' standing heights).
-- The pictures show at once and turn as the zones' turns become known (Forest.zoneTurns), before the grid settles.
-- A zone's picture and angle are written only when they change, as this runs on every step of a resize.
local function placeZones()
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
            shown.picture = picture("zone_" .. zone.sourceX .. "_" .. zone.sourceZ)
            if shown.picture ~= nil then sprite.sprite = shown.picture end
        end
        setHidden(sprite, shown.picture == nil)
        if shown.picture ~= nil then
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
    end
    for index = #Forest.zones + 1, #parts.zones do
        parts.zones[index].zone = nil
        setHidden(parts.zones[index].sprite, true)
    end
    parts.zonesShown, parts.zonesTurnedBy = Forest.zones, Forest.zoneTurns
end

-- Draws a route (its corner tiles, in order) on the routes canvas. 
local MITRE_LEAST = 0.001 -- when the normals sum to less than this, the route doubled back and gets no mitre
local MITRE_LONGEST = 3 -- in half widths; a sharp turn's mitre grows without limit, so it is capped here
local QUAD_TRIANGLES = { { 1, 2, 3 }, { 1, 3, 4 }, { 3, 2, 1 }, { 4, 3, 1 } }
local function pixel(value) return math.floor(value + 0.5) end
local function drawRoute(tiles, colour, joinsAtStart)
    local half = math.max(2, ROUTE_WIDTH * parts.frame.iconScale) / 2
    local points, directions = {}, {}
    for _, tile in ipairs(tiles) do
        local x, y = tileOnMap(tile.x + 0.5, tile.z + 0.5)
        local last = points[#points]
        if last == nil or x ~= last.x or y ~= last.y then points[#points + 1] = { x = x, y = y } end
    end
    if #points < 2 then return end
    for position = 1, #points - 1 do
        local from, to = points[position], points[position + 1]
        local length = math.sqrt((to.x - from.x) ^ 2 + (to.y - from.y) ^ 2)
        directions[position] = { x = (to.x - from.x) / length, y = (to.y - from.y) / length }
    end
    -- Each point's left and right edge points, on whole pixels.
    local edges = {}
    for position, point in ipairs(points) do
        local before, after = directions[position - 1], directions[position]
        local offsetX, offsetY
        local normalX = before and after and -before.y - after.y
        local normalY = before and after and before.x + after.x
        local size = normalX and math.sqrt(normalX ^ 2 + normalY ^ 2) or 0
        if size > MITRE_LEAST then
            -- The mitre lies along the summed normals, far enough to keep each side half a width from the centre.
            local reach = math.min(half * MITRE_LONGEST, half / ((normalX * -before.y + normalY * before.x) / size))
            offsetX, offsetY = normalX / size * reach, normalY / size * reach
        elseif before ~= nil and after ~= nil then
            -- The route doubled back, so there is no mitre and the incoming piece's sides are kept.
            offsetX, offsetY = -before.y * half, before.x * half
        else
            local direction = after or before
            offsetX, offsetY = -direction.y * half, direction.x * half
            -- An end extends half a width outward, unless it is a start joining another route.
            local outward = after ~= nil and (joinsAtStart and 0 or -half) or half
            point = { x = point.x + direction.x * outward, y = point.y + direction.y * outward }
        end
        edges[position] = { left = { pixel(point.x + offsetX), pixel(point.y + offsetY) },
            right = { pixel(point.x - offsetX), pixel(point.y - offsetY) } }
    end
    local corners = {}
    for position = 1, #points - 1 do
        corners[1], corners[2] = edges[position].left, edges[position].right
        corners[3], corners[4] = edges[position + 1].right, edges[position + 1].left
        -- Both windings, as the canvas's fill direction is unknown.
        for _, triangle in ipairs(QUAD_TRIANGLES) do
            local first, second, third = corners[triangle[1]], corners[triangle[2]], corners[triangle[3]]
            parts.routes:AddTriangle(first[1], first[2], second[1], second[2], third[1], third[2], colour)
        end
    end
end

-- The final route runs through every node from the opening the player entered by (the one nearer their first tile)
-- to the other. Redoing it on each node found would cost a search per node, so it is worked out once per forest
-- entry, after the search settles, and kept, which also keeps it unchanged when the map reopens or the player
-- leaves. It is only for sharing, so it waits for the next server tick rather than share a frame with NAVIGATE's
-- plan, and is skipped while a route is chosen.
local finalRouteOf = nil -- { entry, routes } for the last forest entered, keyed by its entry tile
local finalRouteWaiting = false -- waiting for a server tick to work it out
local waitForFinalRoute -- defined below drawRoutes, which it calls
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
    local targets = ForestStops.tilesOfKind("node")
    for _, task in ipairs(ForestFeatures.trinksTasks) do
        if task.locations ~= nil then
            for _, tile in ipairs(ForestStops.tilesOfKind("task", task.key)) do targets[#targets + 1] = tile end
        end
    end
    finalRouteOf = { entry = entry, routes = Routes.finalRoute(grid, openings[1] or entry, openings[2], targets) }
end

-- Returns the final route's pieces
local function finalRoutes()
    if Forest.grid == nil or Forest.entryTile == nil then return {} end
    if finalRouteOf ~= nil and finalRouteOf.entry == Forest.entryTile then return finalRouteOf.routes end
    if not Forest.isSearching then waitForFinalRoute() end
    return {}
end

-- Returns whether toolPair's route is wanted
local function wantsRoute(toolPair)
    return parts.routeShown == toolPair.source.key and not Forest.doorsGone[toolPair.barrier.key]
end

-- Returns the tools the player holds, by source key.
-- Worked out once per redraw.
local function toolsHeld()
    if redraw.held == nil then
        local player = Forest.isInside and Forest.playerTile or nil
        redraw.held = player and ToolsHeld.sourceKeys(player) or {}
    end
    return redraw.held
end

-- Returns the mapping plan's stops: the tour through every node not claimed today, plus the barriers with unseen keys
-- on the way, from the player's tile with the tools held.
local function mappingStops()
    return ForestStops.mappingStopsNow(toolsHeld())
end

-- Returns the next stop of the named plan
local function plannedStop(name, player, held, stops, blocked)
    -- The plan ignores the player's position. It holds until the player leaves the drawn route or its inputs change.
    -- Stops are told apart by found feature, so a key's NPC first seen is a new stop but one that drifts is not.
    local stopsAt, blockedAt = {}, {}
    for _, stop in ipairs(stops) do
        stopsAt[#stopsAt + 1] = tostring(stop.entry) .. stop.kind
            .. (stop.needs and ("<" .. tostring(stop.needs.entry)) or "")
    end
    for index in pairs(blocked) do blockedAt[#blockedAt + 1] = index end
    table.sort(blockedAt)
    local state = { table.concat(stopsAt, " "), table.concat(blockedAt, " "), Forest.grid }
    for _, toolPair in ipairs(ForestFeatures.tools) do
        state[#state + 1] = (held[toolPair.source.key] and "h" or "-")
            .. (Forest.doorsGone[toolPair.barrier.key] and "g" or "-")
    end
    local plan = parts.plans[name]
    local same = plan ~= nil and #plan.state == #state
    for index = 1, #state do same = same and plan.state[index] == state[index] end
    -- A plan with no stop is retried when the player enters another zone;
    local zone = (player.x // ZONE_SIZE) .. "," .. (player.z // ZONE_SIZE)
    if same and plan.stop == nil and plan.failedIn ~= zone then same = false end
    if not same then
        local stop, playerSearch = SolvePlan.nextStop(Forest.grid, player, stops, blocked)
        plan = { state = state, stop = stop, failedIn = zone, search = playerSearch, searchFrom = player }
        parts.plans[name] = plan
    end
    return plan.stop, plan.searchFrom == player and plan.search or nil
end

local function dropRouteChoice()
    parts.routeShown, parts.solving, parts.mapping = nil, false, false
end

local function routeChosen()
    return parts.solving or parts.mapping or parts.routeShown ~= nil
end

-- Returns the chosen route from the player.
-- A plan keeps the last route's target (keep) while it is still a stop, so only finishing it, leaving the route or
-- choosing again switch targets.
local function chosenRoute(player, keep)
    local held, blocked = toolsHeld(), ForestStops.barrierTiles()
    -- Returns the stops a plan must visit, as entry -> true, with the doors waiting for an unseen key.
    local function stopsOf(stops, keylessNeeded)
        local entries = {}
        for _, stop in ipairs(stops) do entries[stop.entry] = true end
        for _, door in ipairs(keylessNeeded) do entries[door.entry] = true end
        return entries
    end
    -- A route with no stop due to keys not yet seen sends the player to the center of the forest.
    -- If the only stop accessible is a key taken by another player, the route goes to that stop.
    local function routeByPlan(name, stops, keylessNeeded, takenNeeded)
        local stop, playerSearch = ForestStops.keptStop(stops, keep), nil
        if stop == nil then
            stop, playerSearch = plannedStop(name, player, held, stops, ForestStops.tilesNotInPlan(stops, blocked))
        end
        if stop == nil then
            for _, takenStop in ipairs(ForestStops.takenKeyStops()) do
                if takenNeeded[takenStop.entry.feature.key] then
                    local route = Routes.routeTo(Forest.grid, player, { takenStop }, blocked)
                    if route ~= nil then
                        return route, takenStop.colour, takenStop.entry, { [takenStop.entry] = true }
                    end
                end
            end
            if #keylessNeeded == 0 then return nil end
            local keysUnseen = {}
            for _, door in ipairs(keylessNeeded) do
                keysUnseen[#keysUnseen + 1] = door.entry.feature.pair.source.name
            end
            return Routes.routeTowardCentre(Forest.grid, player, blocked), keylessNeeded[1].colour, nil,
                stopsOf(stops, keylessNeeded), keysUnseen
        end
        -- A kept plan's stop has the tiles its NPC was found on, but the route goes to where the NPC is now.
        local target = stop.entry.isNpc and ForestStops.stopOf(stop.kind, stop.entry, stop.colour) or stop
        local route
        if playerSearch ~= nil then
            route = Routes.routeFrom(playerSearch, Forest.grid, { target }, blocked)
        else
            route = Routes.routeTo(Forest.grid, player, { target }, blocked)
        end
        local entries = stopsOf(stops, keylessNeeded)
        entries[stop.entry] = true
        return route, stop.colour, stop.entry, entries
    end

    local function routeOrPlan(tiles, colour, name, targetOf, stopAt)
        local route = Routes.routeTo(Forest.grid, player, tiles, blocked)
        if route ~= nil then
            local target = targetOf(route)
            return route, colour, target, { [target] = true }
        end
        local openRoute = Routes.routeTo(Forest.grid, player, tiles)
        if openRoute == nil then return nil end
        local stops, keylessNeeded, takenNeeded = ForestStops.stopsToward({ stopAt(openRoute) }, player, held)
        return routeByPlan(name, stops, keylessNeeded, takenNeeded)
    end
    -- Returns the route to a feature of a kind and key, aiming for the one nearest with the barriers open.
    local function routeToThing(kind, key, colour)
        return routeOrPlan(ForestStops.tilesOfKind(kind, key), colour, "to " .. key,
            function(route) return ForestStops.entryAtEnd(route, kind, key) end,
            function(openRoute)
                return ForestStops.stopOf(kind == "barrier" and "door" or "key",
                    ForestStops.entryAtEnd(openRoute, kind, key), colour)
            end)
    end
    -- Returns the route to an opening's mouth, which stands as the route's target.
    local function routeToOpening(opening, name)
        local mouth = { x = opening.x, z = opening.z, tiles = { opening }, kind = "key", colour = SIGN_ROUTE_COLOUR,
            entry = opening }
        return routeOrPlan({ mouth }, SIGN_ROUTE_COLOUR, name, function() return opening end,
            function() return mouth end)
    end
    if parts.mapping then
        local stops, keylessNeeded, takenNeeded = mappingStops()
        return routeByPlan("nodes", stops, keylessNeeded, takenNeeded)
    end
    if parts.solving then return routeByPlan("puzzles", ForestStops.solveStops(held), {}, Forest.keysTaken) end
    for _, sign in ipairs(ENTRANCE_SIGNS) do
        if sign.key == parts.routeShown then
            local opening = ForestStops.openingOn(sign.side)
            if opening == nil then return nil end
            return routeToOpening(opening, "to " .. sign.key)
        end
    end
    for _, row in ipairs(parts.legendRows) do
        if row.feature.key == parts.routeShown then
            return routeToThing(row.feature.kind, row.feature.key, ForestFeatures.colourOf(row.feature))
        end
    end
    for _, toolPair in ipairs(ForestFeatures.tools) do
        if wantsRoute(toolPair) then
            local target = held[toolPair.source.key] and toolPair.barrier or toolPair.source
            local route, colour, targetEntry, stops, keysUnseen = routeToThing(target.kind, target.key, toolPair.colour)
            -- A puzzle chosen is its key and its door, whichever the route leads to now, so both are its stops.
            stops = stops or {}
            for _, entry in ipairs(Forest.found) do
                if entry.feature == toolPair.source or entry.feature == toolPair.barrier then stops[entry] = true end
            end
            return route, colour, targetEntry, stops, keysUnseen
        end
    end
    return nil
end

-- Returns where <route> passes nearest to <tile>
local function nearestOnRoute(route, tile)
    local bestDistance, bestTile, bestNext = nil, nil, nil
    for position = 1, #route do
        local from, to = route[position], route[position + 1] or route[position]
        local stepX, stepZ = to.x - from.x, to.z - from.z
        local steps = math.max(math.abs(stepX), math.abs(stepZ))
        stepX, stepZ = stepX > 0 and 1 or stepX < 0 and -1 or 0, stepZ > 0 and 1 or stepZ < 0 and -1 or 0
        for step = 0, steps do
            local routeTile = { x = from.x + stepX * step, z = from.z + stepZ * step }
            local distance = math.max(math.abs(routeTile.x - tile.x), math.abs(routeTile.z - tile.z))
            if bestDistance == nil or distance < bestDistance then
                bestDistance, bestTile, bestNext = distance, routeTile, position + 1
            end
        end
    end
    -- The last tile is found as the last piece's end, but it is the route's end.
    local last = route[#route]
    if bestTile.x == last.x and bestTile.z == last.z then bestNext = #route + 1 end
    return bestDistance, bestTile, bestNext
end

-- Returns whether a plan has anything left, which is unclaimed nodes for mapping or unfinished puzzles for solving.
-- When not, its button releases itself.
local function planHasWork()
    if parts.mapping then
        -- Keys and barriers the routes to the nodes do not need are not work.
        -- The grid is missing on the tick the player enters, until the forest's first publish.
        if not Forest.isInside or Forest.playerTile == nil or Forest.grid == nil then
            return #ForestStops.mapStops() > 0
        end
        return #(mappingStops()) > 0
    end
    if parts.solving then
        for _, toolPair in ipairs(ForestFeatures.tools) do
            if not Forest.doorsGone[toolPair.barrier.key] and (Forest.countOf[toolPair.barrier.key] or 0) > 0 then
                return true
            end
        end
        return false
    end
    return true
end

local placeMarkers, placeSigns, chooseRoute -- defined below

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

local NO_STOPS = {}

-- Shows, on the map's bottom left above the duplicates note, which keys the route walks toward the forest's centre to
-- find (keysUnseen: their names), in the route's colour, or hides it with none. Written only on change.
local function showKeysUnseen(keysUnseen, colour)
    local content = keysUnseen and ("Walk to find " .. table.concat(keysUnseen, " and ")) or nil
    if content == parts.keysUnseenShown and colour == parts.keysUnseenColour then return end
    parts.keysUnseenShown, parts.keysUnseenColour = content, colour
    setHidden(parts.keysUnseenText, content == nil)
    if content ~= nil then
        parts.keysUnseenText.content = content
        parts.keysUnseenText.rgba = colour
    end
end

-- Draws the chosen route in its target's colour, with the world beam on the target, or the final route in white
-- when none is chosen and it is on. A search on every step would cost too much, so the route is kept
-- (parts.routeDrawn) and worked out again only when the forest, the choice or the tools held change or the player
-- strays from it. With afresh, a plan may switch target; otherwise it keeps its target while that is a stop.
local function drawRoutes(afresh)
    afresh = afresh or parts.planAfresh == true
    parts.planAfresh = nil
    parts.routes:Clear()
    if (parts.mapping or parts.solving) and Forest.bounds ~= nil and not planHasWork() then
        -- The plan is finished, so its button releases.
        parts.mapping, parts.solving = false, false
        showLegendStates()
    end
    local player = Forest.isInside and Forest.playerTile or nil
    local route, colour, target, stops, keysUnseen = nil, nil, nil, nil, nil
    if Forest.grid ~= nil and player ~= nil and routeChosen() then
        local keep = not afresh and parts.routeDrawn and parts.routeDrawn.target or nil
        route, colour, target, stops, keysUnseen = chosenRoute(player, keep)
    end
    local stopsBefore = parts.routeDrawn and parts.routeDrawn.stops or NO_STOPS
    stops = route and stops or NO_STOPS
    parts.routeDrawn = route and { tiles = route, colour = colour, target = target, stops = stops } or nil
    -- A stop's icon or sign may be shown only because it is one of the route's stops.
    if Settings.alwaysShowTarget and not ForestStops.sameSet(stops, stopsBefore) then
        placeMarkers()
        placeSigns()
    end
    showKeysUnseen(route and keysUnseen, colour)
    if route ~= nil then
        if view().activeRoute then drawRoute(route, colour) end
    elseif Forest.grid ~= nil and view().finalRoute and not routeChosen() then
        -- The first branch starts at the entrance, the others where they leave the tree drawn so far.
        for index, finalRoute in ipairs(finalRoutes()) do drawRoute(finalRoute, FINAL_ROUTE_COLOUR, index > 1) end
    end
    -- An opening is not a feature found, so it gets no beam.
    Highlights.beamOn(route and target and target.feature and target or nil, stops)
    Highlights.showRoute(route, colour)
end

-- Works out and draws the final route on the next server tick, if the map is still open with the final route on
-- and nothing chosen in its place.
local FINAL_ROUTE_SUBSCRIPTION = "nemi_mapper_final_route"
local function stopWaitingForFinalRoute()
    if not finalRouteWaiting then return end
    finalRouteWaiting = false
    Event.ServerLogic.Unsubscribe(FINAL_ROUTE_SUBSCRIPTION)
end
waitForFinalRoute = function()
    if finalRouteWaiting then return end
    finalRouteWaiting = true
    Event.ServerLogic.Subscribe(FINAL_ROUTE_SUBSCRIPTION, function()
        stopWaitingForFinalRoute()
        if not isOpen() or parts.frame == nil then return end
        newRedraw()
        if Forest.grid ~= nil and Forest.entryTile ~= nil and not Forest.isSearching and view().finalRoute
            and not routeChosen() then
            workOutFinalRoute()
            drawRoutes()
        end
    end)
end

-- Called when the player steps: while on the drawn route, it is redrawn from the tile nearest to the player.
local function followRoute(player)
    local drawn = parts.routeDrawn
    if drawn == nil then return drawRoutes() end
    local distance, routeTile, nextCorner = nearestOnRoute(drawn.tiles, player)
    if distance > OFF_ROUTE_TILES then
        parts.plans = {}
        return drawRoutes(true)
    end
    if nextCorner > #drawn.tiles then return end
    local ahead = { routeTile }
    for position = nextCorner, #drawn.tiles do ahead[#ahead + 1] = drawn.tiles[position] end
    parts.routes:Clear()
    if view().activeRoute then drawRoute(ahead, drawn.colour) end
    -- The world's line is cut back at each tile walked along it (highlights.lua).
    local trimmedAt = routeTile.x .. "," .. routeTile.z
    if drawn.trimmedAt ~= trimmedAt then
        drawn.trimmedAt = trimmedAt
        Highlights.trimRoute(ahead)
    end
end

local function redrawRoutes()
    if parts.routeDrawn ~= nil and Forest.playerTile ~= nil then return followRoute(Forest.playerTile) end
    if routeChosen() then return parts.routes:Clear() end
    drawRoutes()
end

-- Returns whether a found feature is shown on the map.
local function isShown(entry, held, unneeded)
    local shows, feature = view(), entry.feature
    -- The route's stops stay by their own setting, except a key just taken, as the route is about to move on.
    local drawn = parts.routeDrawn
    if Settings.alwaysShowTarget and drawn ~= nil and drawn.stops[entry]
        and not (feature.kind == "source" and held[feature.key]) then
        return true
    end
    if feature.isPuzzle then
        return shows.puzzleElements and not unneeded[entry] and ForestStops.isPuzzleLeft(entry, held)
    end
    if feature.kind == "node" then return shows.nodes and (shows.usedNodes or not entry.isUsed) end
    if feature.kind == "task" then return shows.tasks or Forest.isTaskActive(feature) end
    return true
end

-- Returns whether a click on a map icon, sign or legend entry can choose a route: the player is in the forest, and the
-- map is not a shared one, which shows only the final route.
local function canChooseRoute()
    return Forest.isInside and not Settings.mapSharingMode
end

-- Makes a map sprite larger when hovered.
local function growOnHover(sprite, placed)
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

-- Chooses a legend row's, map icon's or entrance sign's route, or drops it on a second click.
local function toggleRoute(key)
    if not canChooseRoute() then return end
    chooseRoute(parts.routeShown ~= key and key or nil, false, false)
end

-- Makes a map sprite choose its route when clicked and grow when hovered.
local function makeRoutable(sprite, placed, keyOf)
    sprite.clickthrough = false
    sprite:Subscribe(ui.Hook.ONCLICK, function()
        toggleRoute(keyOf())
        return true
    end)
    growOnHover(sprite, placed)
end

-- Places one sprite per found feature shown, kept and reused in drawing order.
placeMarkers = function()
    local shown, held = 0, toolsHeld()
    local unneeded = view().unneededPuzzles and {} or ForestStops.unneededNow(held)
    for _, entry in ipairs(Forest.found) do
        if isShown(entry, held, unneeded) then
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
            local x, y = tileOnMap(entry.x, entry.z)
            marker.width, marker.height = IconSizes[key].width * iconScale, IconSizes[key].height * iconScale
            marker.x, marker.y = x - marker.width / 2, y - marker.height / 2
            setBox(marker.sprite, marker.x, marker.y, marker.width, marker.height)
            setHidden(marker.sprite, false)
        end
    end
    for index = shown + 1, #parts.markers do setHidden(parts.markers[index].sprite, true) end
end

-- Places each entrance sign at its opening's clearing.
placeSigns = function()
    local stops = Settings.alwaysShowTarget and parts.routeDrawn and parts.routeDrawn.stops or NO_STOPS
    for _, sign in ipairs(parts.signs) do
        local opening = Forest.bounds ~= nil and ForestStops.openingOn(sign.side) or nil
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
    local position = Forest.isInside and view().playerDot and Forest.playerTile or nil
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
    local countNeeded = font:GetStringWidth(parts.countContent or "") + 4
    local chatNeeded = font:GetStringWidth(parts.headerTextShown) + 4
    local boundary = math.min(frame.mapLeft + math.floor(frame.mapSize * HEADER_SPLIT), right - chatNeeded)
    boundary = math.min(math.max(boundary, countLeft + countNeeded), right)
    local headerTop = frame.top + (HEADER_HEIGHT - HEADER_TEXT_HEIGHT) / 2
    setBox(parts.countText, countLeft, headerTop, boundary - countLeft, HEADER_TEXT_HEIGHT)
    setBox(parts.headerText, boundary, headerTop, right - boundary, HEADER_TEXT_HEIGHT)
end

local function showCountText()
    local kinds, total = Forest.nodeCounts()
    local countText = "Enter the Forest"
    if Forest.bounds ~= nil then
        local duplicates = total - kinds
        parts.world = WorldNumber.read()
        countText = (parts.world and ("W" .. parts.world .. " ") or "") .. kinds .. "/" .. #ForestFeatures.nodes
        if duplicates > 0 then
            countText = countText .. " (+" .. duplicates .. (duplicates == 1 and " duplicate)" or " duplicates)")
        end
    end
    if parts.countContent ~= countText then
        parts.countContent = countText
        parts.countText.content = countText
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
        row.canRoute = isMapped and foundCount > 0 and canChooseRoute()
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
    local keyUnseen, held = {}, toolsHeld()
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
        local held = toolsHeld()
        local unneeded, needed = ForestStops.unneededNow(held), {}
        for _, entry in ipairs(Forest.found) do
            local feature = entry.feature
            if feature.isPuzzle and not unneeded[entry] and ForestStops.isPuzzleLeft(entry, held) then
                needed[feature.pair] = true
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

-- Returns the puzzles shown in the legend, as a string to notice a change by.
local function shownPairsKey()
    local keys = {}
    for _, pair in ipairs(shownPuzzlePairs()) do keys[#keys + 1] = pair.toolPair.source.key end
    return table.concat(keys, " ")
end

-- Returns the keys held whose cells show their doors' pictures in a simplified puzzle legend, as a
-- string to notice a change by.
local function doorsShownKey()
    if not (view().simpleLegends and parts.puzzleShown) then return "" end
    local held, keys = toolsHeld(), {}
    for _, pair in ipairs(shownPuzzlePairs()) do
        if held[pair.toolPair.source.key] then keys[#keys + 1] = pair.toolPair.source.key end
    end
    return table.concat(keys, " ")
end

-- Returns whether the puzzle legend shows: by its setting, while barriers stand and it has a puzzle to show.
local function puzzleLegendShown()
    if not view().puzzleLegend then return false end
    -- The minimum size is worked out before the window and its pairs exist, so the pairs count only once made.
    if parts ~= nil and parts.puzzlePairs ~= nil and #shownPuzzlePairs() == 0 then return false end
    return Forest.bounds == nil or Forest.isSearching or Forest.barriersLeft()
end

local layoutFitting -- defined below fitWindowTo
-- Returns width rounded up, between leastWidth and the node legend's greatest width.
local function clampedLegendWidth(width, leastWidth)
    return math.max(leastWidth, math.min(LEGEND_MAXIMUM_WIDTH, math.ceil(width)))
end

local PUZZLE_WINDOW_LEAST_WIDTH = EDGE + MINIMUM_MAP_SIZE
    + clampedLegendWidth(MINIMUM_MAP_SIZE * LEGEND_TO_MAP, LEGEND_MINIMUM_WIDTH) + WINDOW_EDGE_WIDTH

local simpleLegendMinimumWidth = nil
local function legendMinimumWidthFor(shows)
    if not shows.simpleLegends then return LEGEND_MINIMUM_WIDTH end
    if simpleLegendMinimumWidth == nil then
        local buttonWidth = PATHS_ICON_SPRITE ~= nil and MAP_ROUTE_HEIGHT
            or config.Font.FromID(TEXT_FONT):GetStringWidth("NAVIGATE") + 16
        simpleLegendMinimumWidth = buttonWidth + 2 -- inside the legend's border
    end
    return simpleLegendMinimumWidth
end

-- Returns whether the node legend shows a feature's row
local function legendRowShown(feature, listIndex, shows)
    if listIndex == 2 then return shows.taskLegend or Forest.isTaskActive(feature) end
    return shows.claimedInLegend or not Forest.isNodeClaimed(feature.key)
end

local LEGEND_LISTS = { ForestFeatures.nodes, ForestFeatures.trinksTasks }

-- Returns the node legend's rows shown, its lists shown (the tasks' heading goes with any task row shown), and the rows
-- it leaves out (claimed nodes, tasks not active) as a string to notice a change by.
local function legendRowsShown(shows)
    local rows, taskRows, hidden = 0, 0, {}
    for listIndex, list in ipairs(LEGEND_LISTS) do
        for _, feature in ipairs(list) do
            if legendRowShown(feature, listIndex, shows) then
                rows = rows + 1
                if listIndex == 2 then taskRows = taskRows + 1 end
            else
                hidden[#hidden + 1] = feature.key
            end
        end
    end
    return rows, taskRows > 0 and #LEGEND_LISTS or 1, table.concat(hidden, " ")
end

-- Returns whether the node legend shows: by its setting, while it has a row to show. With every node claimed and
-- left out and no task shown, it goes with NAVIGATE, which has nothing left to do, and the map takes its room.
local function nodeLegendShown()
    local shows = view()
    return shows.nodeLegend and (legendRowsShown(shows)) > 0
end

-- Returns a simplified node legend's width: its widest picture at the rows' height.
local function simpleLegendWidthFor(legendHeight, shows, rowCount)
    local legendMinimumWidth = legendMinimumWidthFor(shows)
    if rowCount == nil then
        rowCount = 0
        for _, list in ipairs(LEGEND_LISTS) do rowCount = rowCount + #list end
    end
    rowCount = math.max(1, rowCount)
    local rowHeight = (legendHeight - (shows.mapRoute and MAP_ROUTE_HEIGHT or 0)) / rowCount
    local widest = 0
    for _, list in ipairs(LEGEND_LISTS) do
        for _, feature in ipairs(list) do
            local size = IconSizes[feature.key]
            local scale = math.min((rowHeight - SIMPLE_ICON_INSET * 2) / size.height, LARGEST_SIMPLE_ICON_SCALE)
            widest = math.max(widest, size.width * scale)
        end
    end
    return clampedLegendWidth(widest + SIMPLE_ICON_INSET * 2, legendMinimumWidth)
end

-- Returns a node legend's width when in its own window
local function poppedNodeLegendWidth(legendHeight, shows)
    if shows.simpleLegends then return simpleLegendWidthFor(legendHeight, shows, (legendRowsShown(shows))) end
    return clampedLegendWidth(legendHeight * LEGEND_TO_MAP, LEGEND_MINIMUM_WIDTH)
end

-- Returns the node legend's width in the frame beside a map of mapSize, rounded up.
local function legendWidthFor(mapSize, shows)
    if shows.simpleLegends then
        return simpleLegendWidthFor((shows.header and HEADER_HEIGHT or EDGE) + mapSize - EDGE, shows)
    end
    return clampedLegendWidth(mapSize * LEGEND_TO_MAP, LEGEND_MINIMUM_WIDTH)
end

local function puzzleLegendHeight(shows)
    return shows.simpleLegends and SIMPLE_PUZZLE_LEGEND_HEIGHT or PUZZLE_LEGEND_HEIGHT
end

-- Returns the window size that fits the frame around a map of mapSize.
local function fittedWindowSize(mapSize)
    local shows = view()
    local width = EDGE * 2 + mapSize
    if nodeLegendShown() and not shows.nodeLegendPopped then width = width + EDGE + legendWidthFor(mapSize, shows) end
    local height = (shows.header and HEADER_HEIGHT or EDGE) + mapSize + EDGE
    if puzzleLegendShown() and not shows.puzzleLegendPopped then
        height = height + puzzleLegendHeight(shows) + EDGE
    end
    return width + WINDOW_EDGE_WIDTH, height + WINDOW_EDGE_HEIGHT
end

local function minimumSize()
    return fittedWindowSize(MINIMUM_MAP_SIZE)
end

-- Sets the window's minimum to what is shown. PrettyUI's resize handle keeps its own copy of the limits.
local function setMinimumSize(window, width, height)
    window.minWidth, window.minHeight = width, height
    if window.resize ~= nil then window.resize.minWidth, window.resize.minHeight = width, height end
end

-- Shows what the forest holds in the frame as laid out.
-- After a resize (isResize) the routes are drawn again at the new size.
local function showFound(isResize)
    -- A new grid may turn the zones differently.
    if parts.zonesShown ~= Forest.zones or parts.zonesTurnedBy ~= Forest.zoneTurns then placeZones() end
    if isResize then redrawRoutes() else drawRoutes() end
    placeMarkers()
    placeSigns()
    showPlayer()
    showCounts()
end

-- Returns whether the legends must be laid out again: the puzzle legend coming or going, rows hidden or shown again,
-- the puzzles shown changing, or a simplified cell's picture switching between key and door.
local function needsLayout()
    return parts.puzzleShown ~= puzzleLegendShown() or parts.hiddenRowsKey ~= select(3, legendRowsShown(view()))
        or parts.shownPairsKey ~= shownPairsKey() or parts.doorsShownKey ~= doorsShownKey()
end

local function showForest()
    newRedraw()
    -- A key freed (the player who had it left the forest) may now be on the shortest way, so the plans are made again
    -- instead of keeping their targets.
    for sourceKey in pairs(parts.takenShown or NO_STOPS) do
        if not Forest.keysTaken[sourceKey] then parts.plans, parts.planAfresh = {}, true end
    end
    parts.takenShown = {}
    for sourceKey in pairs(Forest.keysTaken) do parts.takenShown[sourceKey] = true end
    if needsLayout() then return layoutFitting() end
    showFound()
end

-- Updates the map as needed if the held tools change.
local function showHeldChange()
    local held = toolsHeld()
    if ForestStops.sameSet(held, parts.heldShown) then return false, false end
    parts.heldShown, parts.plans, parts.planAfresh = held, {}, true
    if needsLayout() then
        layoutFitting()
        return true, true
    end
    placeMarkers()
    showCounts()
    return true, false
end

-- Draws the frame's panels and outlines, with the node legend's border while the legend is in the frame.
local function drawChrome()
    local canvas, frame = parts.chrome, parts.frame
    canvas:Clear()
    canvas:AddRectangle(frame.left, frame.top, frame.width, frame.height, FRAME_COLOUR)
    canvas:AddOutline(frame.left, frame.top, frame.width, frame.height, 2, FRAME_LINE_COLOUR)
    canvas:AddOutline(frame.mapLeft - 2, frame.mapTop - 2, frame.mapSize + 4, frame.mapSize + 4, 2, FRAME_LINE_COLOUR)
    if parts.legendShown and parts.nodeHost.window == nil then
        local box = parts.nodeBox
        canvas:AddOutline(box.left, box.top, box.width, box.height, 1, FRAME_LINE_COLOUR)
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

-- Draws the dividers between the node legend's rows and between its two lists.
local function drawNodeOverlay(canvas, box)
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

-- Draws the legends' arrows and dividers on an overlay above the cells in the frame, as the cells would
-- cover them if drawn under.
local function drawOverlay()
    parts.overlay:Clear()
    if parts.puzzleShown and parts.puzzleHost.window == nil then drawPuzzleOverlay(parts.overlay, parts.puzzleBox) end
    if parts.legendShown and parts.nodeHost.window == nil then drawNodeOverlay(parts.overlay, parts.nodeBox) end
end

-- Draws a legend in its own window (host, in box): the frame's colour behind it, the node legend's border, and
-- the overlay drawOver draws.
local function drawPopped(host, box, drawOver)
    host.chrome:Clear()
    host.chrome:AddRectangle(0, 0, box.width, box.height, FRAME_COLOUR)
    if host == parts.nodeHost then
        host.chrome:AddOutline(box.left, box.top, box.width, box.height, 1, FRAME_LINE_COLOUR)
    end
    host.overlay:Clear()
    drawOver(host.overlay, box)
end

-- Outlines the cell whose route is drawn, covers the rows of absent nodes, and shows the buttons pressed or not.
function showLegendStates()
    for _, pair in ipairs(parts.puzzlePairs) do
        setHidden(pair.outline, not parts.puzzleShown or not pair.isShown
            or pair.toolPair.source.key ~= parts.routeShown)
    end
    for _, row in ipairs(parts.legendRows) do
        setHidden(row.outline, not row.isShown or row.feature.key ~= parts.routeShown)
        setHidden(row.missing, not row.isShown or not row.isNeeded)
        if row.claimedBackground ~= nil then
            setHidden(row.claimedBackground, not row.isShown or not row.isClaimedAbsent)
        end
    end
    showButton(parts.solveButton, parts.solving)
    showButton(parts.mapRouteButton, parts.mapping)
end

-- Chooses one route, clearing the other choices: routeShown, a feature's route (toggleRoute), or a button's
-- plan (solving or mapping).
chooseRoute = function(routeShown, solving, mapping)
    newRedraw()
    parts.routeShown, parts.solving, parts.mapping = routeShown, solving, mapping
    showLegendStates()
    drawRoutes(true)
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
    local headingFontEntry = fittingFont(HEADING_FONTS, parts.legendTitles, math.max(1, legendWidth - 16))
    local headingHeight = simple and 0 or headingFontEntry.size + HEADING_PADDING * 2
    local rowsShown, headingsShown = legendRowsShown(shows)
    local rowHeight = rowsShown > 0 and (rowsHeight - headingHeight * headingsShown) / rowsShown or 0
    -- Kept so the legend's own window can keep its rows as tall when rows come or go.
    if rowsShown > 0 then parts.nodeRowHeight = rowHeight end
    parts.nodeRowCount = rowsShown
    local iconWidth = simple and legendWidth - 12 or math.min(70, rowHeight * 1.5, legendWidth * 0.26)
    local skillWidth = math.min(44, rowHeight * 1.2, legendWidth * 0.16)
    local nameWidth = legendWidth - iconWidth - skillWidth - 24
    -- Names use the largest font the widest name fits, no taller than its share of a row.
    local nameFontEntry = fittingFont(NAME_FONTS, parts.legendNames, math.max(1, nameWidth), rowHeight * NAME_TO_ROW)
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
            local rowShown = legendRowShown(row.feature, headingIndex, shows)
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
    local solveWidth = simple and PATHS_ICON_SPRITE ~= nil and SIMPLE_SOLVE_BUTTON_WIDTH or SOLVE_BUTTON_WIDTH
    -- Only the puzzles shown take a cell; the others are hidden.
    local shownPairs = shownPuzzlePairs()
    parts.shownPairsKey, parts.doorsShownKey = shownPairsKey(), doorsShownKey()
    for _, pair in ipairs(parts.puzzlePairs) do pair.isShown = false end
    for _, pair in ipairs(shownPairs) do pair.isShown = true end
    for _, pair in ipairs(parts.puzzlePairs) do
        if not pair.isShown then setAllHidden(true, pair.cell, pair.source, pair.barrier, pair.label, pair.outline) end
    end
    -- A simplified cell shows its key's picture, or its door's while the key is held, matching the full legend's name.
    local held = toolsHeld()
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
        setAllHidden(not showsPuzzle, pair.cell)
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

local function poppedBox(host)
    local root = host.window.root
    return { left = 0, top = 0, width = root.width - WINDOW_EDGE_WIDTH, height = root.height - WINDOW_EDGE_HEIGHT }
end

local function layoutPopped(host)
    if parts == nil or parts.frame == nil then return end
    local box = poppedBox(host)
    if host == parts.nodeHost then
        layoutNodeLegend(box)
        drawPopped(host, box, drawNodeOverlay)
    else
        layoutPuzzleLegend(box)
        drawPopped(host, box, drawPuzzleOverlay)
    end
    showLegendStates()
end

-- Hides a window without destroying it. will be removed with pretty ui 1.3.0's support for hiding windows.
local function hideWindow(window)
    window.root.hidden = true
    if window.titleDrag then window.titleDrag.hidden = true end
    if window == parts.window and parts.sharingButton ~= nil then parts.sharingButton:hide() end
end

local function showPoppedWindows()
    local mapShown = parts.window.root.hidden ~= true
    for _, host in ipairs({ parts.nodeHost, parts.puzzleHost }) do
        local window = host.window
        if window ~= nil then
            local legendShown = parts.puzzleShown
            if host == parts.nodeHost then legendShown = parts.legendShown end
            local shown = mapShown and not parts.closedPopped[window] and legendShown
            if shown and window.root.hidden == true then
                window:Show()
            elseif not shown and window.root.hidden ~= true then
                hideWindow(window)
            end
        end
    end
end

-- Lays the frame out in the window's content, contentWidth by contentHeight.
local function layout(contentWidth, contentHeight, isResize)
    -- A part shown again (the puzzle legend in a new forest, the header in map sharing mode) can raise the minimum.
    -- The window then grows to it, and SetSize lays it out again, as a resize only if this layout was one.
    local minimumWidth, minimumHeight = minimumSize()
    if parts.window.minWidth ~= minimumWidth or parts.window.minHeight ~= minimumHeight then
        setMinimumSize(parts.window, minimumWidth, minimumHeight)
        local windowWidth, windowHeight = contentWidth + WINDOW_EDGE_WIDTH, contentHeight + WINDOW_EDGE_HEIGHT
        if windowWidth < minimumWidth or windowHeight < minimumHeight then
            parts.layoutAfresh = not isResize
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
    local puzzleLegendTall = puzzleLegendHeight(shows)
    local puzzleHeight = puzzleInFrame and puzzleLegendTall + EDGE or 0
    local headerHeight = showsHeader and HEADER_HEIGHT or EDGE
    local widthRoom = contentWidth - EDGE * 2 - (legendInFrame and EDGE or 0)
    local legendMinimumWidth = legendMinimumWidthFor(shows)
    -- The legend is a share of the map's width but kept between its least and greatest widths, so the map takes
    -- what the legend leaves of the width.
    local mapWidth = widthRoom
    if legendInFrame then
        mapWidth = widthRoom / (1 + LEGEND_TO_MAP)
        if mapWidth * LEGEND_TO_MAP > LEGEND_MAXIMUM_WIDTH then
            mapWidth = widthRoom - LEGEND_MAXIMUM_WIDTH
        elseif mapWidth * LEGEND_TO_MAP < legendMinimumWidth then
            mapWidth = widthRoom - legendMinimumWidth
        end
    end
    local heightLimit = contentHeight - headerHeight - EDGE - puzzleHeight
    if legendInFrame and shows.simpleLegends then
        -- A simplified legend's width follows the rows' height, so the map's size is found by a few rounds of
        -- giving the map what the legend for that size leaves. Each round moves less than the last.
        mapWidth = math.min(heightLimit, widthRoom - legendMinimumWidth)
        for _ = 1, 4 do mapWidth = math.min(heightLimit, widthRoom - legendWidthFor(math.floor(mapWidth), shows)) end
    end
    local mapSize = math.floor(math.min(heightLimit, mapWidth))
    local legendWidth = 0
    if legendInFrame and shows.simpleLegends then
        legendWidth = math.min(legendWidthFor(mapSize, shows), widthRoom - mapSize)
    elseif legendInFrame then
        -- rounded up like the fitted width, so a fitted window shows no slack beside the legend
        legendWidth = clampedLegendWidth(math.min(mapSize * LEGEND_TO_MAP, widthRoom - mapSize), legendMinimumWidth)
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
    setBox(parts.keysUnseenText, 8, mapSize - 2 * TEXT_HEIGHT - 6, mapSize - 16, TEXT_HEIGHT)
    placeCompassSprite(parts.compassRing, COMPASS_RING_PIXELS, frame)
    placeCompassSprite(parts.compassBacking, COMPASS_BACKING_PIXELS, frame)
    placeCompassSprite(parts.compass, COMPASS_NEEDLE_PIXELS, frame)
    setAllHidden(not showsHeader, parts.countText, parts.headerText)
    if showsHeader then placeHeaderTexts() end

    -- A node legend window's height follows its rows: when rows come or go (nodes claimed, another setting), each
    -- row keeps its height, so the window shrinks or grows by the rows'.
    local rowsNow, headingsNow, hiddenRows = legendRowsShown(shows)
    parts.hiddenRowsKey = hiddenRows
    if nodePopped then
        local window = parts.nodeHost.window
        local headingHeight = shows.simpleLegends and 0 or fittingFont(HEADING_FONTS, parts.legendTitles,
            math.max(1, window.root.width - WINDOW_EDGE_WIDTH - 16)).size + HEADING_PADDING * 2
        local fixedHeight = (shows.mapRoute and MAP_ROUTE_HEIGHT or 0) + headingHeight * headingsNow
            + WINDOW_EDGE_HEIGHT
        local leastHeight = fixedHeight + rowsNow * LEAST_LEGEND_ROW_HEIGHT
        local leastWidth = poppedNodeLegendWidth(leastHeight - WINDOW_EDGE_HEIGHT, shows) + WINDOW_EDGE_WIDTH
        setMinimumSize(window, leastWidth, leastHeight)
        local height = window.root.height
        if parts.nodeRowHeight ~= nil and parts.nodeRowCount ~= nil and rowsNow ~= parts.nodeRowCount then
            height = math.floor(fixedHeight + parts.nodeRowHeight * rowsNow + 0.5)
        end
        height = math.max(height, leastHeight)
        local width = math.max(window.root.width, leastWidth)
        if width ~= window.root.width or height ~= window.root.height then window:SetSize(width, height) end
    end
    -- A puzzle legend window's least size follows the simplified legends setting, and the window grows to it.
    if puzzlePopped then
        local window = parts.puzzleHost.window
        local leastWidth = shows.simpleLegends and PATHS_ICON_SPRITE ~= nil
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
    local nodeBox = nodePopped and poppedBox(parts.nodeHost) or { left = frame.mapLeft + mapSize + EDGE,
        top = frame.top + EDGE, width = legendWidth, height = headerHeight + mapSize - EDGE }
    layoutNodeLegend(nodeBox)
    local puzzleBox = puzzlePopped and poppedBox(parts.puzzleHost) or { left = frame.mapLeft,
        top = frame.mapTop + mapSize + EDGE, width = frame.width - EDGE * 2, height = puzzleLegendTall }
    layoutPuzzleLegend(puzzleBox)
    setBox(parts.overlay, 0, 0, contentWidth, contentHeight)
    drawChrome()
    drawOverlay()
    if nodePopped then drawPopped(parts.nodeHost, nodeBox, drawNodeOverlay) end
    if puzzlePopped then drawPopped(parts.puzzleHost, puzzleBox, drawPuzzleOverlay) end
    showPoppedWindows()
    parts.zonesShown = nil -- place every zone again at the new size
    showFound(isResize)
end

-- Builds the map's components in drawing order: the frame's panels, then the map layer with the zones, routes, found
-- features, entrance signs and the player clipped at its edges, then the compass, texts and legends on the frame.
local function build()
    local content = parts.window.content
    parts.chrome = create(ui.Canvas, content)
    parts.map = create(ui.Layer, content)
    local mapBackground = create(ui.Rectangle, parts.map)
    mapBackground.fill = true
    mapBackground.rgba = FOREST_COLOUR
    parts.zoneLayer = create(ui.Layer, parts.map)
    parts.zones = {}
    parts.routes = create(ui.Canvas, parts.map)
    parts.markerLayer = create(ui.Layer, parts.map)
    parts.markers = {}
    local signLayer = create(ui.Layer, parts.map)
    for _, filling in ipairs({ mapBackground, parts.zoneLayer, parts.routes, parts.markerLayer, signLayer }) do
        filling:SetSize(0, 0, 1.0, 1.0) -- fills the map layer
    end
    -- A click on a sign chooses or drops the route to its opening.
    parts.signs = {}
    for _, sign in ipairs(ENTRANCE_SIGNS) do
        local shown = { key = sign.key, side = sign.side, sprite = addIcon(signLayer, sign.key) }
        makeRoutable(shown.sprite, shown, function() return sign.key end)
        parts.signs[#parts.signs + 1] = shown
    end
    parts.playerMarker = create(ui.Rectangle, parts.map)
    parts.playerMarker.fill = true
    parts.playerMarker.rgba = PLAYER_COLOUR
    parts.duplicatesText = addText(parts.map, TEXT_FONT, TEXT_COLOUR, ui.AlignMode.TOPLEFT,
        "DUPLICATE NODES DO NOT GIVE EXP")
    parts.keysUnseenText = addText(parts.map, TEXT_FONT, TEXT_COLOUR, ui.AlignMode.TOPLEFT)
    setHidden(parts.keysUnseenText, true)

    -- The ring is filled in the middle, so it goes under the backing and needle.
    parts.compassRing = addGameSprite(content, COMPASS_RING_SPRITE)
    parts.compassBacking = addGameSprite(content, COMPASS_BACKING_SPRITE)
    parts.compass = addGameSprite(content, COMPASS_SPRITE)
    parts.countText = addText(content, HEADER_FONT, TEXT_COLOUR, ui.AlignMode.TOPLEFT)
    parts.headerText = addText(content, HEADER_FONT, TEXT_COLOUR, ui.AlignMode.BOTTOMRIGHT, Settings.headerText)
    parts.headerTextShown = Settings.headerText

    -- Returns where a legend draws: the frame, or its own window, with a canvas of its own there for its
    -- background, border and dividers.
    local function hostIn(window)
        if window == nil then return { content = content, chrome = parts.chrome } end
        return { window = window, content = window.content, chrome = create(ui.Canvas, window.content) }
    end
    parts.nodeHost, parts.puzzleHost = hostIn(parts.nodeWindow), hostIn(parts.puzzleWindow)

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
        if PATHS_ICON_SPRITE ~= nil then
            button.icon = addGameSprite(content, PATHS_ICON_SPRITE)
            button.icon.hidden = true
        end
        return button
    end

    -- The node and task legend. Its NAVIGATE button plans a route through every node not claimed today.
    content = parts.nodeHost.content
    parts.legendHeadings, parts.legendRows, parts.legendTitles, parts.legendNames = {}, {}, {}, {}
    local legends = { { "SKILL NODES", ForestFeatures.nodes }, { "TRINKS' TASKS", ForestFeatures.trinksTasks } }
    for _, legend in ipairs(legends) do
        parts.legendHeadings[#parts.legendHeadings + 1] = {
            text = addText(content, TEXT_FONT, HEADING_COLOUR, ui.AlignMode.CENTRE, legend[1]),
            rowCount = #legend[2],
        }
        parts.legendTitles[#parts.legendTitles + 1] = legend[1]
        for _, feature in ipairs(legend[2]) do
            local row = { feature = feature, nameText = feature.name:upper() }
            local function cannotRoute() return not row.canRoute end
            row.cell = addCell(content, feature.key, cannotRoute)
            -- over the cell, under the row's picture and name
            if feature.kind == "node" and WINDOW_BACKGROUND_SPRITE ~= nil then
                row.claimedBackground = addGameSprite(content, WINDOW_BACKGROUND_SPRITE)
                row.claimedBackground.isTiling = true
                row.claimedBackground.hidden = true
            end
            row.icon = addIcon(content, feature.key)
            -- centred between the icon and the skill symbol
            row.name = addText(content, TEXT_FONT, TEXT_COLOUR, ui.AlignMode.CENTRE, row.nameText)
            local skillSprite = feature.skill and skillSpriteOf(feature.skill)
            if skillSprite ~= nil then
                row.skill = create(ui.Sprite, content)
                row.skill.spriteID = skillSprite
            end
            -- covers the row of a node that is absent but still unclaimed today
            row.missing = create(ui.Rectangle, content)
            row.missing.fill = true
            row.missing.rgba = MISSING_COLOUR
            row.missing.hidden = true
            row.outline = addOutline(content, ForestFeatures.colourOf(feature))
            row.hover = addHover(content, row.cell, cannotRoute)
            parts.legendRows[#parts.legendRows + 1] = row
            parts.legendNames[#parts.legendNames + 1] = row.nameText
        end
    end
    -- The buttons' plans need the player in the forest, so they do nothing outside it.
    parts.mapRouteButton = addButton(content, "NAVIGATE", function()
        if Forest.isInside then chooseRoute(nil, false, not parts.mapping) end
    end)
    if parts.nodeWindow ~= nil then parts.nodeHost.overlay = create(ui.Canvas, content) end

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
    if parts.puzzleWindow ~= nil then parts.puzzleHost.overlay = create(ui.Canvas, content) end
    -- The frame's overlay covers the legends in the frame, so it is made after them.
    parts.overlay = create(ui.Canvas, parts.window.content)
    parts.solveButton = addButton(content, "SOLVE", function()
        if Forest.isInside then chooseRoute(nil, not parts.solving, false) end
    end)
    parts.plans = {}
end

-- The legends' own windows.
-- Each opens beside the map the first time (the puzzle legend's under it), and keeps its place and size after.
local LEGEND_DEFAULT_WIDTH = clampedLegendWidth(DEFAULT_MAP_SIZE * LEGEND_TO_MAP, LEGEND_MINIMUM_WIDTH)
local POPPED_WINDOWS = {
    { part = "nodeWindow", place = "nodeLegend", title = "Node legend",
        width = LEGEND_DEFAULT_WIDTH + WINDOW_EDGE_WIDTH, defaultHeight = DEFAULT_MAP_SIZE + WINDOW_EDGE_HEIGHT,
        minWidth = LEGEND_MINIMUM_WIDTH + WINDOW_EDGE_WIDTH, minHeight = MINIMUM_MAP_SIZE + WINDOW_EDGE_HEIGHT },
    { part = "puzzleWindow", place = "puzzleLegend", title = "Puzzle legend",
        width = EDGE + DEFAULT_MAP_SIZE + LEGEND_DEFAULT_WIDTH + WINDOW_EDGE_WIDTH,
        under = true, minWidth = PUZZLE_WINDOW_LEAST_WIDTH }, -- openPopped sets its height
}

-- Saves the window's place, destroys its components and its legends' own windows, and forgets it.
-- The window's own Destroy makes the client stall on these components, so they are destroyed one by one, newest first.
local function release()
    WindowPlace.remember(parts.window.root, "map")
    if parts.sharingButton ~= nil then parts.sharingButton:destroy() end
    for index = #parts.created, 1, -1 do parts.created[index]:Destroy() end
    for _, popped in ipairs(POPPED_WINDOWS) do
        local window = parts[popped.part]
        if window ~= nil then
            WindowPlace.remember(window.root, popped.place)
            window:Destroy()
        end
    end
    parts = nil
    stopWaitingForFinalRoute()
    Highlights.beamOn(nil)
    Highlights.showRoute(nil)
    Event.Draw.Unsubscribe(RESIZE_END_SUBSCRIPTION)
end

-- Returns the parts around the map in the window's frame (the header, and the legends neither hidden nor in their own
-- windows), as a string to compare.
local function framePartsShown()
    return (parts.headerShown and "header " or "")
        .. (parts.legendShown and parts.nodeHost.window == nil and "node " or "")
        .. (parts.puzzleShown and parts.puzzleHost.window == nil and "puzzle" or "")
end

-- Fits the window to the frame around a map of mapSize, within the plugin layer.
local function fitWindowTo(mapSize)
    local width, height = fittedWindowSize(mapSize)
    parts.window:SetSize(math.min(width, parts.pluginLayer.width), math.min(height, parts.pluginLayer.height))
end

-- Lays the frame out again. Returns whether it was fitted.
layoutFitting = function()
    local mapSize, partsBefore = parts.frame.mapSize, framePartsShown()
    layout(parts.contentWidth, parts.contentHeight)
    if framePartsShown() == partsBefore then return false end
    fitWindowTo(mapSize)
    return true
end

-- Fits the window to the frame once a resize ends, so no background shows.
-- Draw is watched only during a drag.
local function fitAfterResize()
    if not isLaidOut() then return Event.Draw.Unsubscribe(RESIZE_END_SUBSCRIPTION) end
    local resize = parts.window.resize
    if resize ~= nil and resize.dragState ~= nil then return end
    Event.Draw.Unsubscribe(RESIZE_END_SUBSCRIPTION)
    fitWindowTo(parts.frame.mapSize)
end

-- Builds the map again with its legends where the settings now put them, keeping the route chosen and the map's
-- size: the window shrinks as a legend leaves it for its own window, and grows as it comes back.
local function rebuild()
    local routeShown, solving, mapping = parts.routeShown, parts.solving, parts.mapping
    local hidden, mapSize = parts.window.root.hidden == true, parts.frame.mapSize
    local PrettyUI, pluginLayer = parts.PrettyUI, parts.pluginLayer
    MapWindow.close()
    MapWindow.open(PrettyUI, pluginLayer, hidden)
    if not isOpen() or parts.frame == nil then return end
    fitWindowTo(mapSize)
    if routeShown ~= nil or solving or mapping then chooseRoute(routeShown, solving, mapping) end
end

-- Fits the node legend's own window to the legend's width at the window's height, leaving no room beside a
-- simplified legend's pictures.
local function fitNodeWindow()
    local window = parts.nodeWindow
    local legendHeight = window.root.height - WINDOW_EDGE_HEIGHT
    local width = poppedNodeLegendWidth(legendHeight, view()) + WINDOW_EDGE_WIDTH
    window:SetSize(math.max(width, window.minWidth), window.root.height)
end

-- Shrinks or grows the legends' own windows with their legends when simplified legends are turned on or off.
-- The node legend's fits its legend. The puzzle legend's changes by what the legend gains or loses (SOLVE's column and
-- the line of names) from its size before (puzzleSize).
local function fitPoppedWindows(puzzleSize)
    local simple = view().simpleLegends
    if parts.nodeWindow ~= nil then fitNodeWindow() end
    local window = parts.puzzleWindow
    if window ~= nil then
        local sign = simple and -1 or 1
        local widthChange = PATHS_ICON_SPRITE ~= nil and SOLVE_BUTTON_WIDTH - SIMPLE_SOLVE_BUTTON_WIDTH or 0
        window:SetSize(math.max(window.minWidth, puzzleSize[1] + sign * widthChange),
            math.max(window.minHeight, puzzleSize[2] + sign * (PUZZLE_LEGEND_HEIGHT - SIMPLE_PUZZLE_LEGEND_HEIGHT)))
    end
end

-- Opens a legend's own window.
-- Its X hides it until the map is opened again; the legend stays out of the map.
local function openPopped(popped)
    local mapRoot, pluginLayer = parts.window.root, parts.pluginLayer
    local width = math.min(Settings[popped.place .. "Width"] or popped.width, pluginLayer.width)
    -- The puzzle legend's window is as high as the legend in the frame, at least and at first.
    local minimumHeight, defaultHeight = popped.minHeight, popped.defaultHeight
    if popped.under then
        minimumHeight = puzzleLegendHeight(view()) + WINDOW_EDGE_HEIGHT
        defaultHeight = minimumHeight
    end
    local height = math.min(Settings[popped.place .. "Height"] or defaultHeight, pluginLayer.height)
    local besideX, besideY = mapRoot.x + mapRoot.width, mapRoot.y
    if popped.under then besideX, besideY = mapRoot.x, mapRoot.y + mapRoot.height end
    local x, y = WindowPlace.position(pluginLayer, width, height, Settings[popped.place .. "X"] or besideX,
        Settings[popped.place .. "Y"] or besideY)
    local window = parts.PrettyUI.Window.new(pluginLayer, {
        title = popped.title, x = x, y = y, width = width, height = height,
        minWidth = popped.minWidth, minHeight = minimumHeight,
        resizable = true, scrollable = false,
    })
    window.Close = function(closingWindow)
        hideWindow(closingWindow)
        if parts ~= nil then parts.closedPopped[closingWindow] = true end
    end
    local setWindowSize = window.SetSize
    window.SetSize = function(resizedWindow, newWidth, newHeight)
        setWindowSize(resizedWindow, newWidth, newHeight)
        local host = parts ~= nil and (popped.part == "nodeWindow" and parts.nodeHost or parts.puzzleHost)
        if host and host.window == resizedWindow then layoutPopped(host) end
    end
    return window
end

-- Opens the map, or brings it to the front if open.
-- With hidden, it opens unseen for route guidance with the map setting off, since guidance (the plan, the ground route,
-- the beam and the box) runs in the map.
function MapWindow.open(PrettyUI, pluginLayer, hidden)
    if isOpen() then
        if not hidden then
            parts.window:Show()
            -- Opening the map again brings back the legend windows closed since.
            parts.closedPopped = {}
            if parts.frame ~= nil then showPoppedWindows() end
        end
        return
    end
    newRedraw()
    local minimumWidth, minimumHeight = minimumSize()
    local defaultWidth, defaultHeight = fittedWindowSize(DEFAULT_MAP_SIZE)
    local width = math.min(Settings.mapWidth or defaultWidth, pluginLayer.width)
    local height = math.min(Settings.mapHeight or defaultHeight, pluginLayer.height)
    local x, y = WindowPlace.position(pluginLayer, width, height, Settings.mapX, Settings.mapY)
    local hasPictures = picture("chest") ~= nil
    local window = PrettyUI.Window.new(pluginLayer, {
        title = "Nemi Forest map", x = x, y = y, width = width, height = height,
        minWidth = minimumWidth, minHeight = minimumHeight,
        resizable = hasPictures, scrollable = false, destroyOnClose = true,
        onClose = release, -- on the X; the window then destroys itself
    })
    parts = { window = window, created = {}, hiddenOf = {}, boxOf = {}, textWidths = {}, closedPopped = {},
        PrettyUI = PrettyUI, pluginLayer = pluginLayer }
    -- The X only hides the window while a route is followed in the forest, so the route, beam and box carry on.
    local closeWindow = window.Close
    window.Close = function(closingWindow)
        if parts ~= nil and parts.frame ~= nil and Forest.isInside and routeChosen() then
            hideWindow(closingWindow)
            showPoppedWindows()
        else
            closeWindow(closingWindow)
        end
    end
    parts.sharingButton = SharingButton.add(window, pluginLayer,
        function() return parts ~= nil and parts.window.root.hidden ~= true end,
        function() MapWindow.onSharingToggled() end)
    if not hasPictures then
        window:AddText("The map pictures are not loaded. Run plugins_scan in the client console, then reload "
            .. "the plugin.")
        return
    end
    local shows = view()
    if shows.nodeLegendPopped then parts.nodeWindow = openPopped(POPPED_WINDOWS[1]) end
    if shows.puzzleLegendPopped then parts.puzzleWindow = openPopped(POPPED_WINDOWS[2]) end
    build()
    -- A window's content takes its new size a moment after a resize, so the layout uses the size passed to
    -- SetSize, which PrettyUI's resize handle calls on each step of a drag.
    local setWindowSize = window.SetSize
    window.SetSize = function(resizedWindow, newWidth, newHeight)
        setWindowSize(resizedWindow, newWidth, newHeight)
        local isResize = not parts.layoutAfresh
        parts.layoutAfresh = nil
        layout(math.max(resizedWindow.minWidth, math.floor(newWidth)) - WINDOW_EDGE_WIDTH,
            math.max(resizedWindow.minHeight, math.floor(newHeight)) - WINDOW_EDGE_HEIGHT, isResize)
        if resizedWindow.resize ~= nil and resizedWindow.resize.dragState ~= nil then
            Event.Draw.Subscribe(RESIZE_END_SUBSCRIPTION, fitAfterResize)
        end
    end
    -- PrettyUI clamps the window to its minimum, so the layout takes the size the window got.
    layout(window.root.width - WINDOW_EDGE_WIDTH, window.root.height - WINDOW_EDGE_HEIGHT)
    parts.heldShown = toolsHeld()
    -- The saved size was fitted to the frame as it was. Settings changed since (a legend hidden, the header) would
    -- leave background around the map, so the window is fitted around the map as laid out now.
    fitWindowTo(parts.frame.mapSize)
    if hidden then
        hideWindow(window)
        showPoppedWindows()
    end
end

-- Called when the forest changes: a find, a claim, a follower, the grid or the search ending.
function MapWindow.showForest()
    if isLaidOut() then showForest() end
end

-- Called when a found NPC (entry) moves: its marker follows, and the route is redrawn when it leads to that NPC.
-- A plan keeps its target.
function MapWindow.showNpcMoved(entry)
    if not isOpen() or parts.frame == nil then return end
    newRedraw()
    placeMarkers()
    if parts.routeDrawn ~= nil and parts.routeDrawn.target == entry then drawRoutes() end
end

-- Called when the backpack or worn items change without a step: only the tools held can have
-- changed what the map shows.
function MapWindow.showInventory()
    if not isOpen() or parts.frame == nil then return end
    newRedraw()
    local heldChanged, routesDrawn = showHeldChange()
    if heldChanged and not routesDrawn and routeChosen() then drawRoutes(true) end
end

-- Called when the forest is left: it is gone, so the map shows none entered.
function MapWindow.showForestLeft()
    finalRouteOf = nil
    if not isOpen() or parts.frame == nil then return end
    dropRouteChoice()
    showForest()
    showLegendStates()
end

-- Called when the player's tile changes: the player marker and the routes follow.
function MapWindow.showPlayer()
    if not isOpen() or parts.frame == nil then return end
    newRedraw()
    showPlayer()
    local heldChanged, routesDrawn = showHeldChange()
    -- The final route starts at the opening nearer the player's first tile, so it can be drawn from the first step.
    local routesChange = view().finalRoute and (finalRouteOf == nil or finalRouteOf.entry ~= Forest.entryTile)
    if routeChosen() and not heldChanged then
        followRoute(Forest.playerTile)
    elseif (routesChange or routeChosen()) and not routesDrawn then
        drawRoutes(true)
    end
    -- The world is readable only while the friends list is open, so it is checked on each step until known.
    if parts.world == nil and Forest.bounds ~= nil and WorldNumber.read() ~= nil then showCountText() end
end

-- Called when a route setting changes: the final route on the map, or the chosen route on the ground.
function MapWindow.showRoutes()
    if not isOpen() or parts.frame == nil then return end
    newRedraw()
    drawRoutes()
end

-- Shows the header text setting.
-- Its text takes new room from the count, and nothing else moves.
local function showHeaderText()
    if parts.headerTextShown == Settings.headerText then return end
    parts.headerTextShown = Settings.headerText
    parts.headerText.content = Settings.headerText
    if parts.headerShown then placeHeaderTexts() end
end

function MapWindow.showHeaderText()
    if isOpen() and parts.frame ~= nil then showHeaderText() end
end

-- Called when a map display setting changes.
-- The legends, header and buttons may come or go, so the frame is laid out again.
function MapWindow.showSettings()
    if not isOpen() or parts.frame == nil then return end
    -- A shared map shows the final route.
    -- A chosen route would replace it, and NAVIGATE's or SOLVE's would have no button left to turn it off.
    if Settings.mapSharingMode then dropRouteChoice() end
    if parts.sharingButton ~= nil then parts.sharingButton:show() end
    showHeaderText()
    newRedraw()
    local shows = view()
    if shows.nodeLegendPopped ~= (parts.nodeWindow ~= nil) or shows.puzzleLegendPopped ~= (parts.puzzleWindow ~= nil)
    then
        return rebuild()
    end
    local wasSimple, mapSize = parts.simpleShown, parts.frame.mapSize
    local puzzleRoot = parts.puzzleWindow ~= nil and parts.puzzleWindow.root
    local puzzleSize = puzzleRoot and { puzzleRoot.width, puzzleRoot.height }
    local fitted = layoutFitting()
    -- Simplified legends take less room too, so the window and the legends' own windows are fitted to them.
    if parts.simpleShown ~= wasSimple then
        if not fitted then fitWindowTo(mapSize) end
        fitPoppedWindows(puzzleSize)
    end
end

function MapWindow.startMapping()
    if not isOpen() or parts.frame == nil or parts.mapping or not view().mapRoute then return end
    chooseRoute(nil, false, true)
end

MapWindow.isOpen = isOpen

function MapWindow.hideOrClose()
    if isOpen() then parts.window:Close() end
end

function MapWindow.isShown()
    return isOpen() and parts.window.root.hidden ~= true
end

function MapWindow.close()
    if not isOpen() then return end
    local window = parts.window
    release()
    window:Destroy()
end

return MapWindow

-- The map window: a frame holding the map (src/ui/map_layer.lua), a header with the compass, the node legend beside
-- the map and the puzzle legend below it, each legend there or in its own window (src/ui/legend_windows.lua).

local ForestFeatures = require("src/data/forest_features")
local Forest = require("src/game/forest")
local FinalRoute = require("src/game/final_route")
local WorldNumber = require("src/game/world_number")
local Settings = require("src/data/settings")
local ComponentWrites = require("src/ui/component_writes")
local MapWidgets = require("src/ui/map_widgets")
local MapView = require("src/ui/map_view")
local MapLayer = require("src/ui/map_layer")
local NodeLegend = require("src/ui/node_legend")
local PuzzleLegend = require("src/ui/puzzle_legend")
local LegendWindows = require("src/ui/legend_windows")
local WindowPlace = require("src/ui/window_place")
local StatusText = require("src/ui/status_text")
local SharingButton = require("src/ui/sharing_button")

local MapWindow = {}

local setBox, setHidden, setAllHidden = ComponentWrites.setBox, ComponentWrites.setHidden, ComponentWrites.setAllHidden
local view, newRedraw = MapView.view, MapView.newRedraw

local EDGE_WIDTH, EDGE_HEIGHT = WindowPlace.EDGE_WIDTH, WindowPlace.EDGE_HEIGHT
local EDGE = MapWidgets.EDGE
local HEADER_HEIGHT = 36
local HEADER_TEXT_HEIGHT = 26
local DEFAULT_MAP_SIZE, MINIMUM_MAP_SIZE = MapWidgets.DEFAULT_MAP_SIZE, MapWidgets.MINIMUM_MAP_SIZE
-- The game's compass, layered like the minimap's: the ring, with the backing and needle on top. The minimap's needle
-- component draws COMPASSMASK_2, which is only the mask COMPASS is drawn through and shows nothing alone.
local COMPASS_BACKING_SPRITE = id.Sprite.NAVIGATION_BACKING_COMPASS
local COMPASS_SPRITE = id.Sprite.COMPASS
local COMPASS_RING_SPRITE = id.Sprite.RS3_MINIMAP_CLASSIC_RING_41PX -- the minimap's ring
local COMPASS_SIZE = 50 -- as on the pack's frame, over the corner of the frame and map
-- Sprite sizes in the cache: ring 41, backing 33, COMPASS 51. The game shows COMPASS at full size through a 33 mask,
-- so drawing it at 33 would make the needle too small; all three are centred and scaled together.
local COMPASS_RING_PIXELS, COMPASS_BACKING_PIXELS, COMPASS_NEEDLE_PIXELS = 41, 33, 51
local HEADER_FONT = id.Font.MUSEO_SANS_19PT_BOLD
local RESIZE_END_SUBSCRIPTION = "nemi_mapper_map_resize_end"
MapWindow.onSharingToggled = nil -- called when the title bar's sharing button is clicked

-- The open window, or nil. It holds the window, the frame's layout and its parts, shared with the modules that draw
-- them.
local parts = nil

local function isOpen()
    if parts ~= nil and ui.Interfaces:GetInterface(parts.window.interfaceID) == nil then parts = nil end
    return parts ~= nil
end

-- The game's compass sprites are off centre, so they are inset by COMPASS_INSET.
local COMPASS_INSET = 3 -- pixels
local COMPASS_CENTRE, COMPASS_SCALE = COMPASS_INSET + COMPASS_SIZE / 2, COMPASS_SIZE / COMPASS_RING_PIXELS
local function placeCompassSprite(component, pixels, frame)
    local size = math.floor(pixels * COMPASS_SCALE + 0.5)
    setBox(component, math.floor(frame.left + COMPASS_CENTRE - size / 2 + 0.5),
        math.floor(frame.top + COMPASS_CENTRE - size / 2 + 0.5), size, size)
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

-- Outlines the legend entry whose route is drawn, covers the rows of absent nodes, and shows the buttons pressed or
-- not.
local function showLegendStates()
    NodeLegend.showStates(parts)
    PuzzleLegend.showStates(parts)
end

local function showCounts()
    local kinds, total = showCountText()
    setHidden(parts.duplicatesText, total <= kinds)
    NodeLegend.showCounts(parts)
    PuzzleLegend.showCounts(parts)
    showLegendStates()
end

-- Shows what the forest holds in the frame as laid out.
local function showFound()
    MapLayer.showFound(parts)
    showCounts()
end

-- Returns the window size that fits the frame around a map of mapSize.
local function fittedWindowSize(mapSize)
    local shows = view()
    local headerHeight = shows.header and HEADER_HEIGHT or EDGE
    local width = EDGE * 2 + mapSize
    if MapView.nodeLegendShown() and not shows.nodeLegendPopped then
        width = width + EDGE + NodeLegend.widthBeside(mapSize, headerHeight + mapSize - EDGE)
    end
    local height = headerHeight + mapSize + EDGE
    if MapView.puzzleLegendShown() and not shows.puzzleLegendPopped then
        height = height + PuzzleLegend.height() + EDGE
    end
    return width + EDGE_WIDTH, height + EDGE_HEIGHT
end

-- Returns whether the legends must be laid out again: the puzzle legend coming or going, rows hidden or shown again,
-- the puzzles shown changing, or a simplified cell's picture switching between key and door.
local function needsLayout()
    return parts.puzzleShown ~= MapView.puzzleLegendShown()
        or parts.hiddenRowsKey ~= MapView.legendRowsShown().hiddenKey
        or parts.shownPairsKey ~= PuzzleLegend.shownKey(parts)
end

local layoutFitting -- defined below layout

local function showForest()
    newRedraw()
    if needsLayout() then layoutFitting() else showFound() end
end


-- Draws the frame's panels and outlines, and the legends' borders, arrows and dividers on an overlay above the cells
-- in the frame, as the cells would cover them if drawn under.
local function drawFrame()
    local canvas, frame = parts.chrome, parts.frame
    canvas:Clear()
    canvas:AddRectangle(frame.left, frame.top, frame.width, frame.height, MapWidgets.FRAME_COLOUR)
    canvas:AddOutline(frame.left, frame.top, frame.width, frame.height, 2, MapWidgets.FRAME_LINE_COLOUR)
    canvas:AddOutline(frame.mapLeft - 2, frame.mapTop - 2, frame.mapSize + 4, frame.mapSize + 4, 2,
        MapWidgets.FRAME_LINE_COLOUR)
    parts.overlay:Clear()
    if parts.puzzleShown and parts.puzzleHost.window == nil then
        PuzzleLegend.drawOverlay(parts.overlay, parts.puzzleBox)
    end
    if parts.legendShown and parts.nodeHost.window == nil then NodeLegend.drawOverlay(parts.overlay, parts.nodeBox) end
end

-- Lays the frame out in the window's content, contentWidth by contentHeight.
local function layout(contentWidth, contentHeight)
    -- A part shown again (the puzzle legend in a new forest, the header in map sharing mode) can raise the minimum.
    -- The window then grows to it, and SetSize lays it out again.
    local minimumWidth, minimumHeight = fittedWindowSize(MINIMUM_MAP_SIZE)
    if parts.window.minWidth ~= minimumWidth or parts.window.minHeight ~= minimumHeight then
        WindowPlace.setMinimumSize(parts.window, minimumWidth, minimumHeight)
        local windowWidth, windowHeight = contentWidth + EDGE_WIDTH, contentHeight + EDGE_HEIGHT
        if windowWidth < minimumWidth or windowHeight < minimumHeight then
            return parts.window:SetSize(math.max(windowWidth, minimumWidth), math.max(windowHeight, minimumHeight))
        end
    end
    parts.contentWidth, parts.contentHeight = contentWidth, contentHeight
    local shows = view()
    local showsPuzzle, showsHeader, showsLegend = MapView.puzzleLegendShown(), shows.header, MapView.nodeLegendShown()
    parts.puzzleShown, parts.legendShown, parts.simpleShown = showsPuzzle, showsLegend, shows.simpleLegends
    parts.headerShown = showsHeader
    local nodePopped, puzzlePopped = parts.nodeHost.window ~= nil, parts.puzzleHost.window ~= nil
    local legendInFrame, puzzleInFrame = showsLegend and not nodePopped, showsPuzzle and not puzzlePopped
    local puzzleLegendTall = PuzzleLegend.height()
    local puzzleHeight = puzzleInFrame and puzzleLegendTall + EDGE or 0
    local headerHeight = showsHeader and HEADER_HEIGHT or EDGE
    local widthRoom = contentWidth - EDGE * 2 - (legendInFrame and EDGE or 0)
    local leastLegendWidth = NodeLegend.minimumWidth()
    local function legendWidthFor(mapSize) return NodeLegend.widthBeside(mapSize, headerHeight + mapSize - EDGE) end
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
            math.max(widthRoom - NodeLegend.MAXIMUM_WIDTH, widthRoom / (1 + NodeLegend.TO_MAP)))
    end
    local mapSize = math.floor(math.min(heightLimit, mapWidth))
    local legendWidth = 0
    if legendInFrame and shows.simpleLegends then
        legendWidth = math.min(legendWidthFor(mapSize), widthRoom - mapSize)
    elseif legendInFrame then
        -- rounded up like the fitted width, so a fitted window shows no slack beside the legend
        legendWidth = NodeLegend.clampedWidth(math.min(mapSize * NodeLegend.TO_MAP, widthRoom - mapSize),
            leastLegendWidth)
    end
    local frame = {
        width = EDGE * 2 + mapSize + (legendInFrame and legendWidth + EDGE or 0),
        height = headerHeight + mapSize + EDGE + puzzleHeight,
        mapSize = mapSize,
        iconScale = MapLayer.iconScale(mapSize),
    }
    frame.left = math.floor((contentWidth - frame.width) / 2)
    frame.top = math.floor((contentHeight - frame.height) / 2)
    frame.mapLeft, frame.mapTop = frame.left + EDGE, frame.top + headerHeight
    parts.frame = frame

    setBox(parts.chrome, 0, 0, contentWidth, contentHeight)
    MapLayer.layout(parts)
    placeCompassSprite(parts.compassRing, COMPASS_RING_PIXELS, frame)
    placeCompassSprite(parts.compassBacking, COMPASS_BACKING_PIXELS, frame)
    placeCompassSprite(parts.compass, COMPASS_NEEDLE_PIXELS, frame)
    setAllHidden(not showsHeader, parts.countLine.text, parts.headerLine.text)
    if showsHeader then placeHeaderTexts() end

    parts.hiddenRowsKey = MapView.legendRowsShown().hiddenKey
    LegendWindows.fit(parts)
    -- The node legend beside the map, from the frame's top to the map's foot, and the puzzle legend under both.
    if nodePopped then
        LegendWindows.layout(parts, parts.nodeHost)
    else
        NodeLegend.layout(parts, { left = frame.mapLeft + mapSize + EDGE, top = frame.top + EDGE, width = legendWidth,
            height = headerHeight + mapSize - EDGE })
    end
    if puzzlePopped then
        LegendWindows.layout(parts, parts.puzzleHost)
    else
        PuzzleLegend.layout(parts, { left = frame.mapLeft, top = frame.mapTop + mapSize + EDGE,
            width = frame.width - EDGE * 2, height = puzzleLegendTall })
    end
    setBox(parts.overlay, 0, 0, contentWidth, contentHeight)
    drawFrame()
    LegendWindows.show(parts)
    showFound()
end

-- Builds the map's components in drawing order: the frame's panels, then the map, then the compass, texts and legends
-- on the frame. A legend in its own window (nodeWindow, puzzleWindow) is built there.
local function build(nodeWindow, puzzleWindow)
    local content = parts.window.content
    parts.chrome = MapWidgets.create(ui.Canvas, content)
    MapLayer.build(parts, content)
    -- The ring is filled in the middle, so it goes under the backing and needle.
    parts.compassRing = MapWidgets.addGameSprite(content, COMPASS_RING_SPRITE)
    parts.compassBacking = MapWidgets.addGameSprite(content, COMPASS_BACKING_SPRITE)
    parts.compass = MapWidgets.addGameSprite(content, COMPASS_SPRITE)
    parts.countLine = StatusText.new(MapWidgets.addText(content, HEADER_FONT, MapWidgets.TEXT_COLOUR,
        ui.AlignMode.TOPLEFT))
    parts.headerLine = StatusText.new(MapWidgets.addText(content, HEADER_FONT, MapWidgets.TEXT_COLOUR,
        ui.AlignMode.BOTTOMRIGHT))
    StatusText.set(parts.headerLine, Settings.headerText)

    -- Returns where a legend draws: the frame, or its own window, with a canvas of its own there for its
    -- background, border and dividers.
    local function hostIn(window)
        if window == nil then return { content = content, chrome = parts.chrome } end
        return { window = window, content = window.content, chrome = MapWidgets.create(ui.Canvas, window.content) }
    end
    parts.nodeHost, parts.puzzleHost = hostIn(nodeWindow), hostIn(puzzleWindow)
    NodeLegend.build(parts, parts.nodeHost.content)
    if nodeWindow ~= nil then parts.nodeHost.overlay = MapWidgets.create(ui.Canvas, parts.nodeHost.content) end
    PuzzleLegend.build(parts, parts.puzzleHost.content, function()
        if puzzleWindow ~= nil then
            parts.puzzleHost.overlay = MapWidgets.create(ui.Canvas, parts.puzzleHost.content)
        end
        -- The frame's overlay covers the legends in the frame, so it is made after them.
        parts.overlay = MapWidgets.create(ui.Canvas, content)
    end)
end

-- Saves the window's place, destroys its legends' own windows, and forgets it.
local function release()
    WindowPlace.remember(parts.window.root, "map")
    LegendWindows.release(parts)
    parts = nil
    FinalRoute.stopWaiting()
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
        LegendWindows.show(parts)
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
    local map = { window = window, closedPopped = {}, PrettyUI = PrettyUI, pluginLayer = pluginLayer,
        close = MapWindow.close }
    map.isOpen = function() return isOpen() and parts == map end
    parts = map
    -- The X only hides the map while a legend's own window is shown, so that window stays open until its own X.
    local closeWindow = window.Close
    window.Close = function(closingWindow)
        if not LegendWindows.anyShown(parts) then return closeWindow(closingWindow) end
        LegendWindows.hideWindow(closingWindow)
    end
    parts.sharingButton = SharingButton.add(PrettyUI, window, function() MapWindow.onSharingToggled() end)
    build(LegendWindows.open(parts))
    -- A window's content takes its new size a moment after a resize, so the layout uses the size passed to
    -- SetSize, which PrettyUI's resize handle calls on each step of a drag.
    local setWindowSize = window.SetSize
    window.SetSize = function(resizedWindow, newWidth, newHeight)
        setWindowSize(resizedWindow, newWidth, newHeight)
        layout(math.max(resizedWindow.minWidth, math.floor(newWidth)) - EDGE_WIDTH,
            math.max(resizedWindow.minHeight, math.floor(newHeight)) - EDGE_HEIGHT)
        if resizedWindow.resize.dragState ~= nil then
            Event.Draw.Subscribe(RESIZE_END_SUBSCRIPTION, fitAfterResize)
        end
    end
    -- PrettyUI clamps the window to its minimum, so the layout takes the size the window got.
    layout(window.root.width - EDGE_WIDTH, window.root.height - EDGE_HEIGHT)
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
    if isOpen() then MapLayer.showNpcMoved(parts, entry) end
end

-- Called when the tools held change, with the chosen route worked out again.
function MapWindow.showHeld()
    if not isOpen() then return end
    newRedraw()
    if needsLayout() then return layoutFitting() end
    MapLayer.placeMarkers(parts)
    MapLayer.paintRoutes(parts)
    showCounts()
end

-- Called when the forest is left: it is gone, so the map shows none entered.
function MapWindow.showForestLeft()
    if isOpen() then showForest() end
end

-- Called when the player's tile changes: the player marker follows. The chosen route follows by MapWindow.showRoutes.
function MapWindow.showPlayer()
    if not isOpen() then return end
    newRedraw()
    MapLayer.showPlayer(parts)
end

-- Called when the route chosen or drawn changes (RouteChoice.onDrawn).
function MapWindow.showRoutes()
    if not isOpen() then return end
    newRedraw()
    MapLayer.showRoute(parts)
    showLegendStates()
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
    if parts.simpleShown ~= wasSimple then LegendWindows.fitSimplified(parts, puzzleSize) end
end

-- Returns whether the map is open and shown.
-- Its X only hides it while a legend's own window is shown.
function MapWindow.isOpen()
    return isOpen() and parts.window.root.hidden ~= true
end

-- Returns what of the map shows, for MapWindow.restore: nil when closed, or { mapHidden (by its X), legendsClosed
-- (each legend's host -> true while its window is closed by its X) }.
function MapWindow.shownState()
    if not isOpen() then return nil end
    local closed = {}
    for _, host in ipairs({ "nodeHost", "puzzleHost" }) do
        local window = parts[host].window
        if window ~= nil and parts.closedPopped[window] then closed[host] = true end
    end
    return { mapHidden = parts.window.root.hidden == true, legendsClosed = closed }
end

-- Puts the map back as it showed (state, from MapWindow.shownState): closed, or with the same windows closed or
-- hidden by their X, closing it if nothing would show.
function MapWindow.restore(state)
    if state == nil then return MapWindow.close() end
    if not isOpen() then return end
    for host in pairs(state.legendsClosed) do
        if parts[host].window ~= nil then parts.closedPopped[parts[host].window] = true end
    end
    LegendWindows.show(parts)
    if state.mapHidden and parts.window.root.hidden ~= true then
        if not LegendWindows.anyShown(parts) then return MapWindow.close() end
        LegendWindows.hideWindow(parts.window)
    end
end

function MapWindow.close()
    if not isOpen() then return end
    local window = parts.window
    release()
    window:Destroy()
end

return MapWindow

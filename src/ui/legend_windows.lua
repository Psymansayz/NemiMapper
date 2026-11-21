-- The legends' own windows, by their settings. Each opens beside the map the first time (the puzzle legend's under
-- it), and keeps its place and size after. Its X hides it until the map is opened again; the legend stays out of the
-- map. With the map hidden by its X, the last one closed closes the map.
-- Its functions take the map window's parts (map), whose isOpen and close are the map window's.

local MapWidgets = require("src/ui/map_widgets")
local MapView = require("src/ui/map_view")
local NodeLegend = require("src/ui/node_legend")
local PuzzleLegend = require("src/ui/puzzle_legend")
local WindowPlace = require("src/ui/window_place")

local LegendWindows = {}

local EDGE_WIDTH, EDGE_HEIGHT = WindowPlace.EDGE_WIDTH, WindowPlace.EDGE_HEIGHT
local EDGE = MapWidgets.EDGE
local view = MapView.view
-- The least row height of a node legend in its own window, about a row's height in the smallest frame.
local LEAST_ROW_HEIGHT = 16
local CLOSE_SUBSCRIPTION = "nemi_mapper_map_close"

-- A puzzle legend window is at least as wide as the frame's smallest map and legend.
local PUZZLE_LEAST_WIDTH = EDGE + MapWidgets.MINIMUM_MAP_SIZE
    + NodeLegend.clampedWidth(MapWidgets.MINIMUM_MAP_SIZE * NodeLegend.TO_MAP, NodeLegend.MINIMUM_WIDTH) + EDGE_WIDTH

local LEGEND_DEFAULT_WIDTH = NodeLegend.clampedWidth(MapWidgets.DEFAULT_MAP_SIZE * NodeLegend.TO_MAP,
    NodeLegend.MINIMUM_WIDTH)
local WINDOWS = {
    { host = "nodeHost", place = "nodeLegend", title = "Node legend",
        width = LEGEND_DEFAULT_WIDTH + EDGE_WIDTH, defaultHeight = MapWidgets.DEFAULT_MAP_SIZE + EDGE_HEIGHT,
        minWidth = NodeLegend.MINIMUM_WIDTH + EDGE_WIDTH, minHeight = MapWidgets.MINIMUM_MAP_SIZE + EDGE_HEIGHT },
    { host = "puzzleHost", place = "puzzleLegend", title = "Puzzle legend",
        width = EDGE + MapWidgets.DEFAULT_MAP_SIZE + LEGEND_DEFAULT_WIDTH + EDGE_WIDTH,
        under = true, minWidth = PUZZLE_LEAST_WIDTH }, -- open sets its height
}

-- Hides a window without destroying it, as PrettyUI's Close does without destroyOnClose.
-- PrettyUI 1.4.0's Window:Hide will replace it.
function LegendWindows.hideWindow(window)
    window.root.hidden = true
    if window.titleDrag then window.titleDrag.hidden = true end
    window:_SyncOverlays(true)
end

-- Returns whether a legend's own window shows.
function LegendWindows.anyShown(map)
    for _, host in ipairs({ map.nodeHost, map.puzzleHost }) do
        if host.window ~= nil and host.window.root.hidden ~= true then return true end
    end
    return false
end

-- Lays out a legend in its own window (host): the frame's colour behind it, and its overlay.
function LegendWindows.layout(map, host)
    local root = host.window.root
    local box = { left = 0, top = 0, width = root.width - EDGE_WIDTH, height = root.height - EDGE_HEIGHT }
    host.chrome:Clear()
    host.chrome:AddRectangle(0, 0, box.width, box.height, MapWidgets.FRAME_COLOUR)
    host.overlay:Clear()
    if host == map.nodeHost then
        NodeLegend.layout(map, box)
        NodeLegend.drawOverlay(host.overlay, box)
        NodeLegend.showStates(map)
    else
        PuzzleLegend.layout(map, box)
        PuzzleLegend.drawOverlay(host.overlay, box)
        PuzzleLegend.showStates(map)
    end
end

-- Opens a legend's own window (popped, one of WINDOWS).
local function open(map, popped)
    local mapRoot, pluginLayer = map.window.root, map.pluginLayer
    -- The puzzle legend's window is as high as the legend in the frame, at least and at first.
    local minimumHeight, defaultHeight = popped.minHeight, popped.defaultHeight
    if popped.under then
        minimumHeight = PuzzleLegend.height() + EDGE_HEIGHT
        defaultHeight = minimumHeight
    end
    local besideX, besideY = mapRoot.x + mapRoot.width, mapRoot.y
    if popped.under then besideX, besideY = mapRoot.x, mapRoot.y + mapRoot.height end
    local x, y, width, height = WindowPlace.restore(pluginLayer, popped.place, popped.width, defaultHeight, nil,
        besideX, besideY)
    local window = map.PrettyUI.Window.new(pluginLayer, {
        categoryID = "auto", title = popped.title, x = x, y = y, width = width, height = height,
        minWidth = popped.minWidth, minHeight = minimumHeight,
        resizable = true, scrollable = false,
    })
    window.Close = function(closingWindow)
        LegendWindows.hideWindow(closingWindow)
        map.closedPopped[closingWindow] = true
        if map.window.root.hidden == true and not LegendWindows.anyShown(map) then map.close() end
    end
    local setWindowSize = window.SetSize
    window.SetSize = function(resizedWindow, newWidth, newHeight)
        setWindowSize(resizedWindow, newWidth, newHeight)
        LegendWindows.layout(map, map[popped.host])
    end
    return window
end

-- Opens the legends' own windows the settings ask for, and returns them: the node legend's and the puzzle legend's,
-- each nil when that legend is in the frame.
function LegendWindows.open(map)
    local shows = view()
    return shows.nodeLegendPopped and open(map, WINDOWS[1]) or nil,
        shows.puzzleLegendPopped and open(map, WINDOWS[2]) or nil
end

-- Closes the map on the next frame if nothing of it shows then: hidden by its X, with no legend window left.
-- A legend window hides as its legend goes, in the middle of a layout, so the map cannot be destroyed there.
local function closeWhenNothingShows(map)
    Event.Draw.Subscribe(CLOSE_SUBSCRIPTION, function()
        Event.Draw.Unsubscribe(CLOSE_SUBSCRIPTION)
        if map.isOpen() and map.window.root.hidden == true and not LegendWindows.anyShown(map) then map.close() end
    end)
end

-- Shows each legend's window while its legend shows and its X has not hidden it, or hides it.
function LegendWindows.show(map)
    for _, host in ipairs({ map.nodeHost, map.puzzleHost }) do
        local window = host.window
        if window ~= nil then
            local legendShown = map.puzzleShown
            if host == map.nodeHost then legendShown = map.legendShown end
            local shown = not map.closedPopped[window] and legendShown
            if shown and window.root.hidden == true then
                window:Show()
            elseif not shown and window.root.hidden ~= true then
                LegendWindows.hideWindow(window)
                if map.window.root.hidden == true and not LegendWindows.anyShown(map) then
                    closeWhenNothingShows(map)
                end
            end
        end
    end
end

-- Fits the windows to their legends as the frame is laid out. A node legend window's height follows its rows: when
-- rows come or go (nodes claimed, another setting), each row keeps its height, so the window shrinks or grows by the
-- rows'. A puzzle legend window's least size follows the simplified legends setting, and the window grows to it.
function LegendWindows.fit(map)
    local shows = view()
    local window = map.nodeHost.window
    if window ~= nil then
        local legendRows = MapView.legendRowsShown()
        local rowsNow, headingsNow = legendRows.rows, legendRows.headings
        local headingHeight = NodeLegend.heading(window.root.width - EDGE_WIDTH)
        local fixedHeight = (shows.mapRoute and NodeLegend.BUTTON_HEIGHT or 0) + headingHeight * headingsNow
            + EDGE_HEIGHT
        local leastHeight = fixedHeight + rowsNow * LEAST_ROW_HEIGHT
        local leastWidth = NodeLegend.poppedWidth(leastHeight - EDGE_HEIGHT) + EDGE_WIDTH
        WindowPlace.setMinimumSize(window, leastWidth, leastHeight)
        local height = window.root.height
        if map.nodeRowHeight ~= nil and rowsNow ~= map.nodeRowCount then
            height = math.floor(fixedHeight + map.nodeRowHeight * rowsNow + 0.5)
        end
        height = math.max(height, leastHeight)
        local width = math.max(window.root.width, leastWidth)
        if width ~= window.root.width or height ~= window.root.height then window:SetSize(width, height) end
    end
    window = map.puzzleHost.window
    if window ~= nil then
        local leastWidth = shows.simpleLegends
            and math.max(1, #MapView.shownPuzzles()) * PuzzleLegend.SIMPLE_PAIR_LEAST_WIDTH + EDGE
                + PuzzleLegend.SIMPLE_SOLVE_WIDTH + EDGE_WIDTH
            or PUZZLE_LEAST_WIDTH
        local leastHeight = PuzzleLegend.height() + EDGE_HEIGHT
        WindowPlace.setMinimumSize(window, leastWidth, leastHeight)
        if window.root.width < leastWidth or window.root.height < leastHeight then
            window:SetSize(math.max(window.root.width, leastWidth), math.max(window.root.height, leastHeight))
        end
    end
end

-- Shrinks or grows the windows with their legends when simplified legends are turned on or off.
-- The node legend's fits its legend's width at the window's height, leaving no room beside a simplified legend's
-- pictures. The puzzle legend's changes by what the legend gains or loses (SOLVE's column and the line of names) from
-- its size before (puzzleSize).
function LegendWindows.fitSimplified(map, puzzleSize)
    local simple = view().simpleLegends
    local window = map.nodeHost.window
    if window ~= nil then
        local width = NodeLegend.poppedWidth(window.root.height - EDGE_HEIGHT) + EDGE_WIDTH
        window:SetSize(math.max(width, window.minWidth), window.root.height)
    end
    window = map.puzzleHost.window
    if window ~= nil then
        local sign = simple and -1 or 1
        local widthChange = PuzzleLegend.SOLVE_WIDTH - PuzzleLegend.SIMPLE_SOLVE_WIDTH
        window:SetSize(math.max(window.minWidth, puzzleSize[1] + sign * widthChange),
            math.max(window.minHeight, puzzleSize[2] + sign * PuzzleLegend.HEIGHT_CHANGE))
    end
end

-- Saves the windows' places and destroys them, as the map closes.
function LegendWindows.release(map)
    Event.Draw.Unsubscribe(CLOSE_SUBSCRIPTION)
    for _, popped in ipairs(WINDOWS) do
        local window = map[popped.host].window
        if window ~= nil then
            WindowPlace.remember(window.root, popped.place)
            window:Destroy()
        end
    end
end

return LegendWindows

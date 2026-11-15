-- Where a window opens: where it was left or centred, and always fully on screen. Each window's place and size are
-- remembered in the settings under its name (map, scout, settings, nodeLegend, puzzleLegend).

local Settings = require("src/data/settings")

local WindowPlace = {}

-- Remembers a window's place and size from its root, less heightLess (a row the window has only sometimes).
function WindowPlace.remember(root, name, heightLess)
    Settings[name .. "X"], Settings[name .. "Y"] = math.floor(root.x), math.floor(root.y)
    Settings[name .. "Width"] = math.floor(root.width)
    Settings[name .. "Height"] = math.floor(root.height) - (heightLess or 0)
end

function WindowPlace.position(pluginLayer, width, height, savedX, savedY)
    local x = savedX or math.floor((pluginLayer.width - width) / 2)
    local y = savedY or math.floor((pluginLayer.height - height) / 2)
    return math.max(0, math.min(x, pluginLayer.width - width)), math.max(0, math.min(y, pluginLayer.height - height))
end

return WindowPlace

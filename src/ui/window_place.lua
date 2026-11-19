-- Saves window positions so they reopen in the same place.

local Settings = require("src/data/settings")

local WindowPlace = {}

-- Remembers a window's place and size from its root, less heightLess (a row the window has only sometimes).
function WindowPlace.remember(root, name, heightLess)
    Settings[name .. "X"], Settings[name .. "Y"] = math.floor(root.x), math.floor(root.y)
    Settings[name .. "Width"] = math.floor(root.width)
    Settings[name .. "Height"] = math.floor(root.height) - (heightLess or 0)
end

-- Returns the named window's top-left corner and size: its saved size or the default, at least minimumWidth wide
-- and within pluginLayer, at its saved place or defaultX, defaultY (centred without them), kept on screen.
function WindowPlace.restore(pluginLayer, name, defaultWidth, defaultHeight, minimumWidth, defaultX, defaultY)
    local width = math.min(math.max(minimumWidth or 0, Settings[name .. "Width"] or defaultWidth), pluginLayer.width)
    local height = math.min(Settings[name .. "Height"] or defaultHeight, pluginLayer.height)
    local x = Settings[name .. "X"] or defaultX or math.floor((pluginLayer.width - width) / 2)
    local y = Settings[name .. "Y"] or defaultY or math.floor((pluginLayer.height - height) / 2)
    return math.max(0, math.min(x, pluginLayer.width - width)), math.max(0, math.min(y, pluginLayer.height - height)),
        width, height
end

return WindowPlace

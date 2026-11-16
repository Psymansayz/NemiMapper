-- Raises the draw distance to High temporarily on entering the forest.
-- On High or Ultra every zone's models load by the third tick, so the whole forest's data is read at once
-- at Medium or low the far zones load only as the player nears them.
-- Once the forest map is settled, the plugin keeps the scanned data even after the client
-- lets far squares go again at Low, so the player's setting can be restored.

local DrawDistance = {}

local LOADS_EVERY_ZONE = 2 -- High: every zone's models load at once
local SENDS_WHOLE_FOREST = 1 -- Medium: the server sends the whole forest

local raisedFrom = nil -- the player's own setting, while the plugin has raised it

function DrawDistance.raise()
    local option = game.options.DrawDistance
    if raisedFrom ~= nil or option.setting >= LOADS_EVERY_ZONE then return false end
    local playerSetting = option.setting
    if not option:Set(LOADS_EVERY_ZONE) then return false end
    raisedFrom = playerSetting
    return playerSetting < SENDS_WHOLE_FOREST
end

function DrawDistance.restore()
    if raisedFrom == nil then return end
    local option = game.options.DrawDistance
    if option.setting == LOADS_EVERY_ZONE then option:Set(raisedFrom) end
    raisedFrom = nil
end

return DrawDistance

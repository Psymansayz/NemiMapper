-- Raises the draw distance to High on entering the forest and sets the player's own back once the forest's grid has
-- settled. Settings run 0 (Low) to 3 (Ultra); the game has no constants for them.
-- From High every zone's models load by the third tick, so all the zones' standing heights, and with them their turns,
-- are read at once; at Medium the far zones load only as the player nears them (measured 2026-11-15: 14 forests
-- entered at High or Ultra settled on tick 3, one at Medium not before the player walked over). At Low the server
-- also sends only the map squares near the player. Once settled, what the plugin keeps (the heights, everything
-- found, the zones' locations) stays though the client lets far squares go again at Low, so the setting can go back.

local DrawDistance = {}

local LOADS_EVERY_ZONE = 2 -- High: every zone's models load at once
local SENDS_WHOLE_FOREST = 1 -- Medium: the server sends the whole forest

local raisedFrom = nil -- the player's own setting, while the plugin has raised it

-- Raises the draw distance to High if it is lower, and returns whether the server will now send more of the forest,
-- which is only when it was below Medium.
function DrawDistance.raise()
    local option = game.options.DrawDistance
    if raisedFrom ~= nil or option.setting >= LOADS_EVERY_ZONE then return false end
    local playerSetting = option.setting
    if not option:Set(LOADS_EVERY_ZONE) then return false end
    raisedFrom = playerSetting
    return playerSetting < SENDS_WHOLE_FOREST
end

-- Sets the player's setting back, once the grid has settled or on leaving, unless they changed it meanwhile.
function DrawDistance.restore()
    if raisedFrom == nil then return end
    local option = game.options.DrawDistance
    if option.setting == LOADS_EVERY_ZONE then option:Set(raisedFrom) end
    raisedFrom = nil
end

return DrawDistance

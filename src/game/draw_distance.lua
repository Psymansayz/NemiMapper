-- Raises the draw distance to Medium in the forest and restores it on leaving. At Low the server sends only
-- the map squares near the player, so part of the forest stays unknown until the player walks there; from
-- Medium up it sends the whole forest.
-- Raising it inside the forest works too: the rest arrives within a few ticks.

local DrawDistance = {}

-- Medium. Settings run 0 (Low) to 3 (Ultra); the game has no constants for them.
local WHOLE_FOREST_SETTING = 1

local raisedFrom = nil -- the player's own setting, while the plugin has raised it

-- Raises the draw distance to Medium if it is lower. Returns whether it did.
function DrawDistance.raise()
    local option = game.options.DrawDistance
    if raisedFrom ~= nil or option.setting >= WHOLE_FOREST_SETTING then return false end
    local playerSetting = option.setting
    if not option:Set(WHOLE_FOREST_SETTING) then return false end
    raisedFrom = playerSetting
    return true
end

-- Restores the player's setting, unless they changed it after the plugin raised it.
function DrawDistance.restore()
    if raisedFrom == nil then return end
    local option = game.options.DrawDistance
    if option.setting == WHOLE_FOREST_SETTING then option:Set(raisedFrom) end
    raisedFrom = nil
end

return DrawDistance

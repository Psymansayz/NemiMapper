-- The player's world number. The game has no call for it, but the friends list's title shows it
-- while that interface is loaded.

local GameIds = require("src/game/game_ids")

local WorldNumber = {}

local titleID = GameIds.resolve("Component", "FRIENDS2__FRIENDS_TITLE")
local world = nil

-- Returns the world as text ("205").
function WorldNumber.read()
    if world == nil and titleID ~= nil then
        local title = ui.Interfaces:GetComponent(titleID)
        if title ~= nil and title.type == ui.ComponentType.LABEL then
            world = title.content:match("RuneScape%s*(%d+)")
        end
    end
    return world
end

-- Called when the world may change: the lobby or a world hop.
function WorldNumber.forget()
    world = nil
end

return WorldNumber

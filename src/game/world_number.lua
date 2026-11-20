-- The player's world number. The game has no call for it, but the friends list's title shows it
-- while that interface is loaded.

local GameIds = require("src/game/game_ids")

local WorldNumber = {}

local titleID = GameIds.resolve("Component", "FRIENDS2__FRIENDS_TITLE")
WorldNumber.world = nil -- as text ("205"), once read

-- Reads the world from the friends list's title, if not known yet.
function WorldNumber.read()
    if WorldNumber.world ~= nil or titleID == nil then return end
    local title = ui.Interfaces:GetComponent(titleID)
    if title ~= nil then WorldNumber.world = title.content:match("RuneScape%s*(%d+)") end
end

-- Called when the world may change: the lobby or a world hop.
function WorldNumber.forget()
    WorldNumber.world = nil
end

return WorldNumber

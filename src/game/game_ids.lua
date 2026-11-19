-- Turns the game's config names (id.Loc, id.NPC, id.Component, ...) into ids at load.
-- Ids can differ between builds and between the dev and live worlds; the names do not.

local GameIds = {}

GameIds.unresolved = {} -- "<kind>.<name>" for every name the game did not know, once each
local noted = {}

function GameIds.noteUnknown(kind, name)
    local key = kind .. "." .. name
    if noted[key] then return end
    noted[key] = true
    GameIds.unresolved[#GameIds.unresolved + 1] = key
end

-- Returns the named player variable (a VarType, read via .value).
-- An unknown name reads as nil.
function GameIds.playerVariable(name)
    local variable = var.VarPlayer[name]
    if variable == nil then GameIds.noteUnknown("VarPlayer", name) end
    return variable
end

-- Returns the id of a config's name.
-- An unknown name reads as -1.
function GameIds.resolve(kind, name)
    local value = id[kind][name]
    if value < 0 then
        GameIds.noteUnknown(kind, name)
        return nil
    end
    return value
end

return GameIds

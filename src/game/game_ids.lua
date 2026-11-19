-- Turns the game's config names (id.Loc, id.NPC, id.Component, ...) into ids at load.
-- Ids can differ between builds and between the dev and live worlds; the names do not.

local GameIds = {}

GameIds.unresolved = {} -- "<kind>.<name>" -> true for every name the game did not know

function GameIds.noteUnknown(kind, name)
    GameIds.unresolved[kind .. "." .. name] = true
end

-- Returns the named player variable (a VarType, read via .value).
-- An unknown name reads as nil.
function GameIds.playerVariable(name)
    local variable = var.VarPlayer[name]
    if variable == nil then GameIds.noteUnknown("VarPlayer", name) end
    return variable
end

-- Returns the id of a player variable's base variable, which is what the server sends when it changes.
-- The variables watched are all VarBits, so each has one.
function GameIds.baseIDOf(variable)
    return variable ~= nil and variable.baseVar.id or nil
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

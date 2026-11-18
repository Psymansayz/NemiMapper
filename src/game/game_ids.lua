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

local function lookUp(kind, name)
    return id[kind][name]
end

local function lookUpPlayerVariable(name)
    return var.VarPlayer[name]
end

-- Returns the named player variable (a VarType, read via .value).
function GameIds.playerVariable(name)
    local found, variable = pcall(lookUpPlayerVariable, name)
    if not found or variable == nil then
        GameIds.noteUnknown("VarPlayer", name)
        return nil
    end
    return variable
end

-- Returns the id of a config's name.
function GameIds.resolve(kind, name)
    -- The game's id table gives -1 for an unknown name.
    local found, value = pcall(lookUp, kind, name)
    if not found or value == nil or value < 0 then
        GameIds.noteUnknown(kind, name)
        return nil
    end
    return value
end

return GameIds

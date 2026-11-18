-- The forest's walkable tiles: each zone's walkable tiles from its template, turned the way the game turned the
-- zone. The game does not say how it turned a zone, so the zones' standing heights are compared against the
-- template's to determine how it was rotated.

local ZoneWalkability = require("src/data/zone_walkability")
local TemplateStanding = require("src/data/template_standing")

local ForestGrid = {}

local ZONE_SIZE = 8 -- tiles
local ZONE_TILES = ZONE_SIZE * ZONE_SIZE


local Grid = {}
Grid.__index = Grid

-- Returns whether the template zone sourceKey has anything standing on it, so that its heights can tell its turn.
-- The data leaves out a zone with nothing standing.
function ForestGrid.hasStanding(sourceKey)
    return TemplateStanding[sourceKey] ~= nil
end

-- Returns values, a zone's 64 per-tile values (standing heights or ground flags, tile x, z at z * 8 + x + 1), turned
-- clockwise quarterTurns times: (x, z) -> (z, 7 - x).
local function turnedTiles(values, quarterTurns)
    for _ = 1, quarterTurns do
        local turnedValues = {}
        for z = 0, ZONE_SIZE - 1 do
            for x = 0, ZONE_SIZE - 1 do
                turnedValues[(ZONE_SIZE - 1 - x) * ZONE_SIZE + z + 1] = values[z * ZONE_SIZE + x + 1]
            end
        end
        values = turnedValues
    end
    return values
end

-- Cache of each template zone's standing heights when turned: "x_z" -> [quarter turns] -> heights.
local standingTurnsCache = {}

-- Returns the clockwise quarter turns that best match the template zone sourceKey's standing heights to
-- standing; none when two turns match equally well.
-- The forest replaces a few tiles (nodes, barriers) and a zone read from afar lacks small plants, but the turn with the
-- most matching tiles still stands out.
local function turnByStanding(sourceKey, standing)
    local template = TemplateStanding[sourceKey]
    if template == nil or standing == nil then return nil end
    local standingTurns = standingTurnsCache[sourceKey]
    if standingTurns == nil then
        standingTurns = {}
        for quarterTurns = 0, 3 do standingTurns[quarterTurns] = turnedTiles(template, quarterTurns) end
        standingTurnsCache[sourceKey] = standingTurns
    end
    local bestTurns, bestAlike, tied = nil, -1, false
    for quarterTurns = 0, 3 do
        local turnedStanding, alike = standingTurns[quarterTurns], 0
        for tileIndex = 1, ZONE_TILES do
            if turnedStanding[tileIndex] == standing[tileIndex] then alike = alike + 1 end
        end
        if alike > bestAlike then bestTurns, bestAlike, tied = quarterTurns, alike, false
        elseif alike == bestAlike then tied = true end
    end
    return not tied and bestTurns or nil
end

-- Returns the template zone sourceKey's ground flags, indexed as in turnedTiles, from the data's text rows.
local function groundTiles(sourceKey)
    local rows, tiles = ZoneWalkability[sourceKey], {}
    for z = 0, ZONE_SIZE - 1 do
        local row = rows and rows[ZONE_SIZE - z]
        for x = 0, ZONE_SIZE - 1 do
            tiles[z * ZONE_SIZE + x + 1] = row ~= nil and row:byte(x + 1) == 46 -- "."
        end
    end
    return tiles
end

-- Cache of each template zone in every turn: "x_z" -> { ground, turnMatters }. ground: by quarter turns, its
-- walkable tiles as flat x, z offset pairs from the south-west corner. turnMatters: whether its turns differ in
-- which tiles are walkable; one that does not (open ground) cannot be turned wrongly.
local groundTurnsCache = {}
local function groundTurns(sourceKey)
    local template = groundTurnsCache[sourceKey]
    if template ~= nil then return template end
    local tiles = groundTiles(sourceKey)
    template = { ground = {}, turnMatters = false }
    for quarterTurns = 0, 3 do
        local turned = turnedTiles(tiles, quarterTurns)
        local ground = {}
        for tileIndex = 1, ZONE_TILES do
            if turned[tileIndex] then
                ground[#ground + 1], ground[#ground + 2] = (tileIndex - 1) % ZONE_SIZE, (tileIndex - 1) // ZONE_SIZE
            end
            if turned[tileIndex] ~= tiles[tileIndex] then template.turnMatters = true end
        end
        template.ground[quarterTurns] = ground
    end
    groundTurnsCache[sourceKey] = template
    return template
end

-- Returns the grid over the forest's bounds (minX, minZ, width, length in tiles) with every zone's tiles.
-- standingByZone: "x,z" of a zone -> its 64 standing heights (src/game/standing_heights.lua).
-- grid.settled is false while a zone whose turn matters has no heights to turn it by.
function ForestGrid.build(zones, bounds, standingByZone)
    local grid = setmetatable({
        minX = bounds.minX, minZ = bounds.minZ, width = bounds.width, length = bounds.length,
        walkable = {}, -- tile index -> true
        turns = {}, -- zone index -> quarter turns
        settled = true,
    }, Grid)
    for index, zone in ipairs(zones) do
        local zoneKey, sourceKey = zone.x .. "," .. zone.z, zone.sourceX .. "_" .. zone.sourceZ
        local template = groundTurns(sourceKey)
        local turns = turnByStanding(sourceKey, standingByZone[zoneKey])
        if turns == nil and template.turnMatters then grid.settled = false end
        turns = turns or 0
        grid.turns[index] = turns
        local ground = template.ground[turns]
        for position = 1, #ground, 2 do
            grid.walkable[grid:index(zone.x + ground[position], zone.z + ground[position + 1])] = true
        end
    end
    return grid
end

-- Returns whether two grids have the same extent, turns, walkable tiles and settledness.
function ForestGrid.same(first, second)
    if first == nil or second == nil or first.minX ~= second.minX or first.minZ ~= second.minZ
        or first.width ~= second.width or first.length ~= second.length or #first.turns ~= #second.turns
        or first.settled ~= second.settled then
        return false
    end
    for index = 1, #first.turns do
        if first.turns[index] ~= second.turns[index] then return false end
    end
    for index in pairs(first.walkable) do
        if not second.walkable[index] then return false end
    end
    for index in pairs(second.walkable) do
        if not first.walkable[index] then return false end
    end
    return true
end

-- Returns a tile's index in the grid.
function Grid:index(x, z)
    if x < self.minX or z < self.minZ or x >= self.minX + self.width or z >= self.minZ + self.length then return nil end
    return (z - self.minZ) * self.width + (x - self.minX) + 1
end

-- Returns the tile of an index.
function Grid:tile(index)
    local offset = index - 1
    return self.minX + offset % self.width, self.minZ + offset // self.width
end

-- Drops the template zones' turned tiles and standing heights, which every forest reuses, once no forest is
-- likely soon. The next grid makes them again from the data, which is why the walkability rows are kept.
function ForestGrid.forgetTemplates()
    groundTurnsCache, standingTurnsCache = {}, {}
end

return ForestGrid

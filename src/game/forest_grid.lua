-- The forest's walkable tiles: each zone's walkable tiles from its template, turned the way the game turned the
-- zone. The game does not say how it turned a zone, but the zone's standing heights (trees, plants) and locations
-- are the template's turned the same way, so matching either gives the rotation. A zone with neither (read before it
-- loaded) is turned to fit its neighbours along shared sides (paths continue, trees meet trees) and to have
-- ground where things were found in it. A node spot the forest left empty is blocked.

local ZoneWalkability = require("src/data/zone_walkability")
local TemplateStanding = require("src/data/template_standing")
local TemplateLocs = require("src/data/template_locs")
local GameIds = require("src/game/game_ids")

local ForestGrid = {}

local ZONE_SIZE = 8 -- tiles
local FITTING_ROUNDS = 12 -- maximum rounds of re-turning each zone to fit its neighbours
local PATH_CARRIES_ON = 2 -- score: ground meets ground across a side
local PATH_MEETS_TREES = -1 -- score: ground meets trees across a side
local THING_ON_GROUND = 6 -- score: a found thing stands on or next to ground
local ZONE_TILES = ZONE_SIZE * ZONE_SIZE
-- Each side's neighbour offset (north, east, south, west) and the neighbour's side that faces back.
local SIDES = { { 0, 1, 3 }, { 1, 0, 4 }, { 0, -1, 1 }, { -1, 0, 2 } }

-- The forest puts a node, a barrier or nothing on these, so any location in their place matches them.
local PLACEHOLDERS = { RAID1_FOREST_HOTSPOT = true, RAID1_FOREST_DOORLOC = true }
-- A hotspot left without a node shows as rocks and blocks the tile, though the standing heights show nothing there.
local HOTSPOT_ID = GameIds.resolve("Loc", "RAID1_FOREST_HOTSPOT")

-- The template zones' locations with ids: "x_z" -> [n] = { id, x, z, width, length, rotation, anyKind }.
-- A name the game does not know has no id, so it matches only if it is a placeholder.
-- The data's table is emptied once converted, as the client's require normally keeps it for good.
local templateOf = {}
do
    local idOf = {}
    for zoneKey, entries in pairs(TemplateLocs) do
        local locations = {}
        for _, entry in ipairs(entries) do
            local name = entry[1]
            if idOf[name] == nil then idOf[name] = GameIds.resolve("Loc", name) or false end
            locations[#locations + 1] = {
                id = idOf[name] or nil, x = entry[2], z = entry[3], width = entry[4], length = entry[5],
                rotation = entry[6], anyKind = PLACEHOLDERS[name] == true,
            }
        end
        templateOf[zoneKey] = locations
    end
    for zoneKey in pairs(templateOf) do TemplateLocs[zoneKey] = nil end
end

local Grid = {}
Grid.__index = Grid

-- Returns location's tiles and rotation after its zone turns clockwise quarterTurns times, as the game turns it.
-- Each turn takes (x, z) to (z, 7 - x) and advances the rotation by one.
local function turnedLocation(location, quarterTurns)
    local left, bottom, width, length = location.x, location.z, location.width, location.length
    for _ = 1, quarterTurns do
        left, bottom, width, length = bottom, ZONE_SIZE - left - width, length, width
    end
    return left, bottom, width, length, (location.rotation + quarterTurns) % 4
end

-- Returns the clockwise quarter turns that best match the template zone sourceKey's locations to locations, or
-- nil if none clearly does.
local function turnByLocations(sourceKey, locations)
    local template = templateOf[sourceKey]
    if template == nil or locations == nil then return nil end
    local bestTurns, bestMatches, tied = nil, 0, false
    for quarterTurns = 0, 3 do
        local matches = 0
        for _, expected in ipairs(template) do
            local x, z, width, length, rotation = turnedLocation(expected, quarterTurns)
            for _, location in ipairs(locations) do
                if location.x == x and location.z == z and location.width == width and location.length == length
                    and location.rotation == rotation and (expected.anyKind or expected.id == location.id) then
                    matches = matches + 1
                    break
                end
            end
        end
        if matches > bestMatches then bestTurns, bestMatches, tied = quarterTurns, matches, false
        elseif matches == bestMatches and matches > 0 then tied = true end
    end
    return not tied and bestTurns or nil
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

-- Cache of each template zone's standing heights in every turn: "x_z" -> [quarter turns] -> heights.
local turnedTemplateStanding = {}

-- Returns the clockwise quarter turns that best match the template zone sourceKey's standing heights to
-- standing, or nil if none does.
-- The forest replaces a few tiles (nodes, barriers) and a zone read from afar lacks small plants, but the turn with the
-- most matching tiles still stands out.
local function turnByStanding(sourceKey, standing)
    local template = TemplateStanding[sourceKey]
    if template == nil or standing == nil then return nil end
    local turnedTemplates = turnedTemplateStanding[sourceKey]
    if turnedTemplates == nil then
        turnedTemplates = {}
        for quarterTurns = 0, 3 do turnedTemplates[quarterTurns] = turnedTiles(template, quarterTurns) end
        turnedTemplateStanding[sourceKey] = turnedTemplates
    end
    local bestTurns, bestAlike, tied = nil, -1, false
    for quarterTurns = 0, 3 do
        local turnedTemplate, alike = turnedTemplates[quarterTurns], 0
        for tileIndex = 1, ZONE_TILES do
            if turnedTemplate[tileIndex] == standing[tileIndex] then alike = alike + 1 end
        end
        if alike > bestAlike then bestTurns, bestAlike, tied = quarterTurns, alike, false
        elseif alike == bestAlike then tied = true end
    end
    return not tied and bestTurns or nil
end

-- Returns the template zone sourceKey's ground flags, indexed as in turnedTiles, from the data's text rows (north to
-- south, west to east, "." for ground), or nil if the data lacks the zone.
-- The rows are kept, as turnedTemplate's cache of the result expires between forests.
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

-- Looks only at the edge's of each tile so we can later compare how they line up with their neighbours.
local function sides(tiles)
    local ground = { {}, {}, {}, {} }
    local top = ZONE_SIZE - 1
    for position = 1, ZONE_SIZE do
        local across, down = position - 1, top - (position - 1)
        ground[1][position] = tiles[top * ZONE_SIZE + across + 1]
        ground[2][position] = tiles[down * ZONE_SIZE + top + 1]
        ground[3][position] = tiles[across + 1]
        ground[4][position] = tiles[down * ZONE_SIZE + 1]
    end
    return ground
end

-- Cache of each template zone in every turn: "x_z" -> { tiles, sides, ground } by quarter turns.
-- tiles: its 64 ground flags; ground: its walkable tiles as flat x, z offset pairs from the south-west corner.
local turnedTemplates = {}
local function turnedTemplate(sourceKey)
    local template = turnedTemplates[sourceKey]
    if template ~= nil then return template end
    local tiles = groundTiles(sourceKey)
    template = { tiles = {}, sides = {}, ground = {} }
    for quarterTurns = 0, 3 do
        local turned = turnedTiles(tiles, quarterTurns)
        local ground = {}
        for tileIndex = 1, ZONE_TILES do
            if turned[tileIndex] then
                ground[#ground + 1], ground[#ground + 2] = (tileIndex - 1) % ZONE_SIZE, (tileIndex - 1) // ZONE_SIZE
            end
        end
        template.tiles[quarterTurns], template.sides[quarterTurns] = turned, sides(turned)
        template.ground[quarterTurns] = ground
    end
    turnedTemplates[sourceKey] = template
    return template
end

-- Whether a zone's tile (x, z from its south-west corner, 0 to 7) or one next to it is ground.
local AROUND = { { 0, 0 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
local function groundAt(tiles, x, z)
    for _, offset in ipairs(AROUND) do
        local aroundX, aroundZ = x + offset[1], z + offset[2]
        if aroundX >= 0 and aroundX < ZONE_SIZE and aroundZ >= 0 and aroundZ < ZONE_SIZE
            and tiles[aroundZ * ZONE_SIZE + aroundX + 1] then
            return true
        end
    end
    return false
end

-- Returns each zone's quarter turns: from its standing heights or locations where they tell, or whichever best fits its
-- neighbours and the things in it, refined over rounds.
-- standingByZone and locationsByZone: "x,z" of a zone -> its standing heights, its locations.
local function fitTurns(zones, things, standingByZone, locationsByZone)
    local zoneAt, templates, known, allKnown = {}, {}, {}, true
    for index, zone in ipairs(zones) do
        local zoneKey, sourceKey = zone.x .. "," .. zone.z, zone.sourceX .. "_" .. zone.sourceZ
        zoneAt[zoneKey] = index
        templates[index] = turnedTemplate(sourceKey)
        known[index] = turnByStanding(sourceKey, standingByZone[zoneKey])
            or turnByLocations(sourceKey, locationsByZone[zoneKey])
        allKnown = allKnown and known[index] ~= nil
    end
    if allKnown then return known, templates end
    -- a zone's things score each turn the same whatever its neighbours, so score them once
    local thingScores = {}
    for index in ipairs(zones) do thingScores[index] = { [0] = 0, 0, 0, 0 } end
    for _, thing in ipairs(things) do
        local index = zoneAt[(thing.x // ZONE_SIZE * ZONE_SIZE) .. "," .. (thing.z // ZONE_SIZE * ZONE_SIZE)]
        if index ~= nil then
            local zone = zones[index]
            for quarterTurns = 0, 3 do
                if groundAt(templates[index].tiles[quarterTurns], thing.x - zone.x, thing.z - zone.z) then
                    thingScores[index][quarterTurns] = thingScores[index][quarterTurns] + THING_ON_GROUND
                end
            end
        end
    end
    -- each zone's neighbour per side (false outside the forest), looked up once rather than at every fit
    local neighbours = {}
    for index, zone in ipairs(zones) do
        neighbours[index] = {}
        for side, facing in ipairs(SIDES) do
            neighbours[index][side] =
                zoneAt[(zone.x + facing[1] * ZONE_SIZE) .. "," .. (zone.z + facing[2] * ZONE_SIZE)] or false
        end
    end
    -- Returns how well zone index, turned quarterTurns, fits its neighbours in their current turns
    -- (turns) and the things in it.
    local function fit(index, quarterTurns, turns)
        local score = thingScores[index][quarterTurns]
        for side, facing in ipairs(SIDES) do
            local neighbour = neighbours[index][side]
            local mine = templates[index].sides[quarterTurns][side]
            local theirs = neighbour and templates[neighbour].sides[turns[neighbour]][facing[3]] or nil
            for position = 1, ZONE_SIZE do
                -- outside the forest counts as trees, like its border
                local groundMeets = theirs ~= nil and theirs[position]
                if mine[position] and groundMeets then
                    score = score + PATH_CARRIES_ON
                elseif mine[position] ~= (groundMeets or false) then
                    score = score + PATH_MEETS_TREES
                end
            end
        end
        return score
    end
    -- Each zone in turn takes its best-fitting turn (keeping its current one on a tie) until none changes.
    -- The result depends on the start, so every uniform starting turn is tried and the best overall fit is kept.
    local order = {}
    for index = 1, #zones do order[index] = index end
    table.sort(order, function(first, second)
        if zones[first].z ~= zones[second].z then return zones[first].z < zones[second].z end
        return zones[first].x < zones[second].x
    end)
    local bestTurns, bestFit = nil, nil
    for startTurns = 0, 3 do
        local turns = {}
        for index = 1, #zones do turns[index] = known[index] or startTurns end
        for _ = 1, FITTING_ROUNDS do
            local changed = false
            for _, index in ipairs(order) do
                if known[index] == nil then
                    local fits = {}
                    for quarterTurns = 0, 3 do fits[quarterTurns] = fit(index, quarterTurns, turns) end
                    local chosen, chosenFit = turns[index], fits[turns[index]]
                    for quarterTurns = 0, 3 do
                        if fits[quarterTurns] > chosenFit then chosen, chosenFit = quarterTurns, fits[quarterTurns] end
                    end
                    if chosen ~= turns[index] then turns[index], changed = chosen, true end
                end
            end
            if not changed then break end
        end
        local wholeFit = 0
        for index = 1, #zones do wholeFit = wholeFit + fit(index, turns[index], turns) end
        if bestFit == nil or wholeFit > bestFit then bestTurns, bestFit = turns, wholeFit end
    end
    return bestTurns, templates
end

-- The grid over the forest's bounds (minX, minZ, width, length in tiles) with every zone's tiles. things: tiles
-- ({ x, z }) of what was found, which stand on or next to ground. standingByZone: "x,z" of a zone -> its 64
-- standing heights (src/game/standing_heights.lua). locationsByZone: "x,z" of a zone -> its locations
-- { id, x, z, width, length, rotation }, x and z from its south-west corner.
local NONE = {}
function ForestGrid.build(zones, bounds, things, standingByZone, locationsByZone)
    locationsByZone = locationsByZone or NONE
    local turns, templates = fitTurns(zones, things or NONE, standingByZone or NONE, locationsByZone)
    local grid = setmetatable({
        minX = bounds.minX, minZ = bounds.minZ, width = bounds.width, length = bounds.length,
        walkable = {}, -- tile index -> true
        turns = turns, -- zone index -> quarter turns
    }, Grid)
    for index, zone in ipairs(zones) do
        local ground = templates[index].ground[turns[index]]
        for position = 1, #ground, 2 do
            grid.walkable[grid:index(zone.x + ground[position], zone.z + ground[position + 1])] = true
        end
        for _, location in ipairs(locationsByZone[zone.x .. "," .. zone.z] or NONE) do
            if location.id == HOTSPOT_ID then
                grid.walkable[grid:index(zone.x + location.x, zone.z + location.z)] = nil
            end
        end
    end
    return grid
end

-- Returns whether two grids have the same extent, turns and walkable tiles.
function ForestGrid.same(first, second)
    if first == nil or second == nil or first.minX ~= second.minX or first.minZ ~= second.minZ
        or first.width ~= second.width or first.length ~= second.length or #first.turns ~= #second.turns then
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

-- Returns a tile's index in the grid, or nil outside it.
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
    turnedTemplates, turnedTemplateStanding = {}, {}
end

return ForestGrid

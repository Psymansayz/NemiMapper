-- The edges of a route drawn as a ribbon of even width, for the map's routes and the route on the ground.
-- At a turn both steps share the mitre point, so a diagonal meets a straight step flush.

local MITRE_LEAST = 0.001 -- when the normals sum to less than this, the route doubled back and gets no mitre
local MITRE_LONGEST = 3 -- in half widths; a sharp turn's mitre grows without limit, so it is capped here

-- The client's require only keeps a module that returns a table, so this is a module of one function.
local RibbonEdges = {}

-- Fills leftX, leftY, rightX and rightY with the edge points half a width (half) to each side of the count points
-- pointX, pointY, and directionX, directionY with each step's direction. Filling given arrays lets the map draw
-- without making tables. The ends extend half a width outward, but a start joining another route (joinsAtStart)
-- does not.
function RibbonEdges.fill(pointX, pointY, count, half, joinsAtStart, directionX, directionY, leftX, leftY, rightX,
    rightY)
    for position = 1, count - 1 do
        local stepX, stepY = pointX[position + 1] - pointX[position], pointY[position + 1] - pointY[position]
        local length = math.sqrt(stepX ^ 2 + stepY ^ 2)
        directionX[position], directionY[position] = stepX / length, stepY / length
    end
    for position = 1, count do
        local hasBefore, hasAfter = position > 1, position < count
        local beforeX, beforeY = directionX[position - 1], directionY[position - 1]
        local afterX, afterY = directionX[position], directionY[position]
        local x, y = pointX[position], pointY[position]
        local offsetX, offsetY
        local normalX, normalY, size = 0, 0, 0
        if hasBefore and hasAfter then
            normalX, normalY = -beforeY - afterY, beforeX + afterX
            size = math.sqrt(normalX ^ 2 + normalY ^ 2)
        end
        if size > MITRE_LEAST then
            -- The mitre lies along the summed normals, far enough to keep each side half a width from the centre.
            local reach = math.min(half * MITRE_LONGEST, half / ((normalX * -beforeY + normalY * beforeX) / size))
            offsetX, offsetY = normalX / size * reach, normalY / size * reach
        elseif hasBefore and hasAfter then
            -- The route doubled back, so there is no mitre and the incoming step's sides are kept.
            offsetX, offsetY = -beforeY * half, beforeX * half
        else
            local alongX, alongY = hasAfter and afterX or beforeX, hasAfter and afterY or beforeY
            offsetX, offsetY = -alongY * half, alongX * half
            local outward = hasAfter and (joinsAtStart and 0 or -half) or half
            x, y = x + alongX * outward, y + alongY * outward
        end
        leftX[position], leftY[position] = x + offsetX, y + offsetY
        rightX[position], rightY[position] = x - offsetX, y - offsetY
    end
end

return RibbonEdges

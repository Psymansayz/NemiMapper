-- Writes a component's place, size and hidden state only when they change, as each property write has a cost in the
-- client. A component placed or hidden through these must not be placed or hidden any other way.

local ComponentWrites = {}

-- Each component's last written box and hidden state. A component destroyed with its window is let go.
local boxOf = setmetatable({}, { __mode = "k" })
local hiddenOf = setmetatable({}, { __mode = "k" })

function ComponentWrites.setBox(component, left, top, width, height)
    local x, y = math.floor(left), math.floor(top)
    local boxWidth, boxHeight = math.max(1, math.floor(width)), math.max(1, math.floor(height))
    local box = boxOf[component]
    if box == nil then
        box = {}
        boxOf[component] = box
    end
    if box[1] ~= x or box[2] ~= y then
        box[1], box[2] = x, y
        component:SetPos(x, y)
    end
    if box[3] ~= boxWidth or box[4] ~= boxHeight then
        box[3], box[4] = boxWidth, boxHeight
        component:SetSize(boxWidth, boxHeight)
    end
end

function ComponentWrites.setBoxes(first, second, left, top, width, height)
    ComponentWrites.setBox(first, left, top, width, height)
    ComponentWrites.setBox(second, left, top, width, height)
end

function ComponentWrites.setHidden(component, isHidden)
    if hiddenOf[component] ~= isHidden then
        hiddenOf[component] = isHidden
        component.hidden = isHidden
    end
end

function ComponentWrites.setAllHidden(isHidden, ...)
    for index = 1, select("#", ...) do
        local component = select(index, ...)
        if component ~= nil then ComponentWrites.setHidden(component, isHidden) end
    end
end

return ComponentWrites

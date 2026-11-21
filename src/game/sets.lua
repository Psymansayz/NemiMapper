-- Sets kept as tables of key -> true.

local Sets = {}

-- Returns whether two sets hold the same keys.
function Sets.same(first, second)
    for key in pairs(first) do
        if not second[key] then return false end
    end
    for key in pairs(second) do
        if not first[key] then return false end
    end
    return true
end

return Sets

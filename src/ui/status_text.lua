-- Saves a text's content and color.

local StatusText = {}

function StatusText.new(text)
    return { text = text }
end

-- Writes the content, and the colour if given, where they differ from the last written.
function StatusText.set(line, content, colour)
    if line.content ~= content then
        line.content = content
        line.text.content = content
    end
    if colour ~= nil and line.colour ~= colour then
        line.colour = colour
        line.text.rgba = colour
    end
end

return StatusText

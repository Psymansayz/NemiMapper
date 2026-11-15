-- A text whose content and colour are written only when they change, as each write to a component costs the client.
-- The game's components take no fields of the plugin's own, so the values last written are kept beside the component.

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

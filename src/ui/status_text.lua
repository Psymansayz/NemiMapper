-- A text that writes its content and colour only when they change, and the status colours the windows and the hub
-- page share.

local StatusText = {}

StatusText.GREEN = 0x7DDC5AFF -- complete
StatusText.GOLD = 0xF2C66DFF -- incomplete, the settings' headings and hints
StatusText.RED = 0xE0433A00 -- a node absent but still unclaimed today; add an alpha

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

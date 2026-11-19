# Copies the forests the dev probe saved (saveForest in src/debug/forest_probe.lua) from the beta client's plugin
# database to tools/forests/<layout hash>.txt, in the pasted console log's format the route tests read.
# A forest saved again since the last export replaces its file. The client may be running.
# NPCs are only found once in view, so each NPC feature a forest lacks is placed at its north opening, as on a walk
# that brought them along, with a PLACED| line naming them.
import pathlib, re, sqlite3

DATABASE = r"C:\ProgramData\Jagex\RuneScape-BETA\plugins\PluginData.db"
PLUGIN = "Nemi Mapper"  # plugin.json's name
NPC_FEATURES = ("lightning", "goebie", "traitor")  # src/data/forest_features.lua's features with npcs
OPENING_SOURCE = "4200.664"  # src/game/forest.lua's OPENING_SOURCE_X, OPENING_SOURCE_Z
ZONE_SIZE = 8
PREFIX = "[nemi_mapper] "


# Returns the north opening's mouth (as readRegion in src/game/forest.lua places it): the middle of the opening
# zone's side on the forest's edge.
def northMouth(text):
    zones = [(int(x), int(z), source) for x, z, source in re.findall(r"HEIGHT\|(\d+),(\d+)\|([\d.]+)\|", text)]
    minX, maxX = min(x for x, _, _ in zones), max(x for x, _, _ in zones)
    minZ, maxZ = min(z for _, z, _ in zones), max(z for _, z, _ in zones)
    mouths = []
    for x, z, source in zones:
        if source == OPENING_SOURCE:
            mouthX, mouthZ = x + ZONE_SIZE // 2, z + ZONE_SIZE // 2
            if z == maxZ: mouthZ = z + ZONE_SIZE - 1
            elif z == minZ: mouthZ = z
            elif x == maxX: mouthX = x + ZONE_SIZE - 1
            elif x == minX: mouthX = x
            mouths.append((mouthX, mouthZ))
    return max(mouths, key=lambda mouth: (mouth[1], -mouth[0]))


def withNpcs(text):
    found = set(re.findall(r"FOUND\|(\w+)\|", text))
    missing = [key for key in NPC_FEATURES if key not in found]
    if not missing:
        return text
    x, z = northMouth(text)
    lines = text.split("\n")
    at = next(index for index, line in enumerate(lines) if "WORLD|" in line)
    placed = [f"{PREFIX}FOUND|{key}|{x}.5,{z}.5" for key in missing]
    placed.append(f"{PREFIX}PLACED|{','.join(missing)}|at the north opening {x},{z}")
    return "\n".join(lines[:at] + placed + lines[at:])


folder = pathlib.Path(__file__).parent / "forests"
folder.mkdir(exist_ok=True)
connection = sqlite3.connect(f"file:{DATABASE}?mode=ro", uri=True)
rows = connection.execute("select Key, Value from DataStore where PluginID = ? and Key like 'forest|%'",
                          (PLUGIN,)).fetchall()
added = updated = placed = 0
for key, value in sorted(rows):
    text = (value.decode() if isinstance(value, bytes) else value).rstrip("\0").replace("\r\n", "\n")
    text = withNpcs(text)
    placed += "PLACED|" in text
    path = folder / (key.split("|", 1)[1] + ".txt")
    data = (text.replace("\n", "\r\n") + "\r\n").encode()
    if path.exists() and path.read_bytes() == data:
        continue
    added, updated = added + (not path.exists()), updated + path.exists()
    path.write_bytes(data)
print(f"{len(rows)} forests saved in the game: {added} new, {updated} updated, {placed} with NPCs placed, "
      f"in {folder}")

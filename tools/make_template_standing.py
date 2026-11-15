"""Writes src/data/template_standing.lua and src/data/zone_walkability.lua from a console paste holding the
probe's TEMPLATEHEIGHT| and TEMPLATELOC| lines. Press the page button "Debug: log the template square" standing near the middle of
map square 65,10, since the client drops small scenery far from the player.

    python tools/make_template_standing.py <the paste>

For each template zone, what stands on each tile: World.GetGroundHeight with HeightOffsetType.LOCATION less the
ground, which shows the trees and plants that LocList does not list. A forest zone holds the same, turned, so
comparing them tells how the zone was turned (src/game/forest_grid.lua). A tile with nothing standing on it is
ground.
"""
import pathlib
import re
import sys

ZONE = 8
# The opening zone, at the middle of the entrance and the exit: all ground, the one zone a forest uses with nothing
# standing. The square's other zones with nothing standing are blank (no ground texture), unused by the game.
OPENING = "4200_664"
# Tiles found blocked in game though the height reading sees nothing standing on them: template zone -> (x, z)
# within it, from its south-west corner.
BLOCKED = {
    "4208_672": [(0, 6), (1, 6)],
    # One blocker across these two zones' shared side.
    "4216_688": [(6, 0), (7, 0)],
    "4192_688": [(7, 6), (7, 7)],
}

paste = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
zones = {}
# Node spots: a node or rocks stand on each in every forest, so it is never walkable, though the heights show
# nothing there. TEMPLATELOC|zone x,z||id|config|x,z within the zone|size|shape|rotation
hotspots = {}
for line in paste.splitlines():
    found = re.search(r"TEMPLATELOC\|(\d+),(\d+)\|\|\d+\|RAID1_FOREST_HOTSPOT\|(\d+),(\d+)\|", line)
    if found:
        hotspots.setdefault(f"{found.group(1)}_{found.group(2)}", []).append((int(found.group(3)), int(found.group(4))))
if not hotspots:
    sys.exit("no TEMPLATELOC| line names a RAID1_FOREST_HOTSPOT: the paste lacks the template's locations")
for line in paste.splitlines():
    found = re.search(r"TEMPLATEHEIGHT\|(\d+),(\d+)\|\|([\d -]+)\|([\d -]+)", line)
    if found:
        standing = [int(value) for value in found.group(4).split()]
        if len(standing) == ZONE * ZONE:
            zones[f"{found.group(1)}_{found.group(2)}"] = standing
if sum(1 for standing in zones.values() if any(standing)) < 20:
    sys.exit(f"{len(zones)} zones, few with something standing: no TEMPLATEHEIGHT| lines, or the dump was taken"
             " too far from the zones, or outside the template")

data_folder = pathlib.Path(__file__).resolve().parent.parent / "src" / "data"
ordered = sorted(zones, key=lambda key: tuple(int(part) for part in key.split("_")))

standing_lines = [
    "-- The height of the tree or plant on each tile of each zone the forest is built of, as the map square they are",
    "-- copied from has it, and 0 where nothing stands. Rows run from the south, tiles from the west. The forest's",
    "-- zones hold the same heights turned, so comparing them tells how each zone was turned. A zone with nothing",
    "-- standing on it is left out, as it looks the same in every turn. Made by tools/make_template_standing.py",
    "-- from the probe's log: run it again instead of editing.",
    "",
    "return {",
]
for zone in ordered:
    if not any(zones[zone]):
        continue
    standing_lines.append(f'    ["{zone}"] = {{')
    for row in range(ZONE):
        values = zones[zone][row * ZONE:(row + 1) * ZONE]
        standing_lines.append("        " + " ".join(f"{value}," for value in values))
    standing_lines.append("    },")
standing_lines.append("}")
(data_folder / "template_standing.lua").write_bytes(("\r\n".join(standing_lines) + "\r\n").encode("utf-8"))

walkability_lines = [
    "-- Which tiles of each zone the forest is built of can be walked on: those with nothing standing on them in",
    "-- the map square they are copied from (template_standing.lua). A zone is named by the tile of its south-west",
    "-- corner in that map square. Its rows run north to south and west to east, \".\" for ground and \"#\" for a",
    "-- tree, a plant, a node spot (RAID1_FOREST_HOTSPOT: a node or rocks stand there in every forest) or a tile found",
    "-- blocked in game (BLOCKED in the tool). Only the zones a forest uses are listed: those with something standing,",
    "-- and the opening, all ground. The square's other zones are blank, unused by the game.",
    "-- Made by tools/make_template_standing.py: run it again instead of editing.",
    "",
    "return {",
]
for zone in ordered:
    if not any(zones[zone]) and zone != OPENING:
        continue
    rows = []
    for row in reversed(range(ZONE)):
        values = zones[zone][row * ZONE:(row + 1) * ZONE]
        blocked = BLOCKED.get(zone, []) + hotspots.get(zone, [])
        rows.append('"' + "".join("." if value == 0 and (x, row) not in blocked else "#"
                                  for x, value in enumerate(values)) + '"')
    rows = ", ".join(rows)
    walkability_lines.append(f'    ["{zone}"] = {{ {rows} }},')
walkability_lines.append("}")
(data_folder / "zone_walkability.lua").write_bytes(("\r\n".join(walkability_lines) + "\r\n").encode("utf-8"))

ground = sum(1 for standing in zones.values() for value in standing if value == 0)
print(f"wrote template_standing.lua and zone_walkability.lua: {len(zones)} zones, {ground} ground tiles")

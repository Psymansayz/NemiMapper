"""Writes src/data/template_locs.lua from a console paste holding the probe's TEMPLATELOC| lines. Press the page
button "Debug: log the template square" standing in map square 65,10.

    python tools/make_template_locs.py <the paste>

Each template zone's locations: the game's name, the tile within the zone (x east, z north, from the zone's
south-west corner), size and rotation. The forest's zones hold the same locations turned, so comparing them tells
how each zone was turned (src/game/forest_grid.lua).
"""
import collections
import pathlib
import re
import sys

paste = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
zones = collections.defaultdict(list)
unreadable = 0
for line in paste.splitlines():
    found = re.search(r"TEMPLATELOC\|(\d+),(\d+)\|\|\d+\|(\S+?)\|(\d+),(\d+)\|(\d+)x(\d+)\|\d+\|(\d+)", line)
    if found:
        # The probe writes "?" for a name it could not read, which cannot be resolved to an id.
        if found.group(3) == "?":
            unreadable += 1
            continue
        zones[f"{found.group(1)}_{found.group(2)}"].append(tuple(found.group(3, 4, 5, 6, 7, 8)))
if unreadable:
    sys.exit(f"{unreadable} TEMPLATELOC| lines have no name (?): take the dump again")
if not zones:
    sys.exit("no TEMPLATELOC| lines in the paste")

lines = [
    "-- The locations of each zone the forest is built of, as the map square they are copied from has them. Each",
    "-- holds the game's name, the tile within the zone (x east, z north, from the zone's south-west corner), width,",
    "-- length and rotation. Made by tools/make_template_locs.py from the probe's log: run it again instead of",
    "-- editing.",
    "",
    "return {",
]
for zone in sorted(zones, key=lambda key: tuple(int(part) for part in key.split("_"))):
    entries = sorted(set(zones[zone]), key=lambda entry: (int(entry[1]), int(entry[2]), entry[0]))
    lines.append(f'    ["{zone}"] = {{')
    for name, x, z, width, length, rotation in entries:
        lines.append(f'        {{ "{name}", {x}, {z}, {width}, {length}, {rotation} }},')
    lines.append("    },")
lines.append("}")
target = pathlib.Path(__file__).resolve().parent.parent / "src" / "data" / "template_locs.lua"
target.write_bytes(("\r\n".join(lines) + "\r\n").encode("utf-8"))
print(f"wrote {target} ({len(zones)} zones, {sum(len(entries) for entries in zones.values())} locations)")

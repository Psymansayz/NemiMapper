# Nemi Mapper

A RuneScape 3 plugin for scouting and mapping Nemi Forest instances on Mazcab.

- **Scout window**: opens on entering a forest and shows how many of the nine kinds of skill node the instance has
  ("7 nodes", large), then the nine kinds in the order the forest lays them out, those not in the forest dimmed and
  those there twice marked (duplicates give no extra XP). It closes when you leave the forest.
- **Map window**: the forest as the minimap shows it, in a frame laid out like the maps made with the r/NemiForest
  map pack: the compass, the world and the node count in the header, an icon on every node found and on Trinks' task targets
  (Pahtli plant, traitor), the route from the entrance by every node to the exit drawn in white, and the legend
  naming each node beside the symbol of the skill it trains. The route runs from the entrance to the exit over
  the forest's walkable tiles, read from the game's own data.
- **Puzzle elements**: each tool's source and the barrier that tool opens (fire pit and web, mysterious weapon and
  barricade, lightning and pillars, axe in stake and bound logs, mysterious statue and mysterious statues, lost
  goebie and portal) are on the map with a legend under it. A click on a puzzle in that legend draws the route
  from you to its tool, or to its barrier once you hold the tool; SOLVE draws them all. A puzzle whose barrier
  is gone leaves the map. Switches on the plugin's page hide them, the header, the legend and the nodes, for a
  map to share.

Open both windows from the plugin's page (the ribbon icon). Requires the PrettyUI plugin. The world number is
read from the friends list: it shows once that list has been open. On entering a forest a draw distance below High
is raised to High for a few seconds, until the whole forest's layout is read, then set back to yours.

## Credits

- The node, task, tool and barrier icons and the forest's zone pictures are made from pictures and map tiles from the
  [RuneScape Wiki](https://runescape.wiki) (CC BY-NC-SA 3.0).
- Special thanks to FC Nemi & Krystal Cove for hosting all these years!
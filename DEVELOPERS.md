# Nemi Mapper: developer guide

This guide explains how the plugin works: the flow from loading to leaving a forest, where each piece of data comes
from, what each structure holds and which modules use it. The player-facing description is in `README.md`.

The plugin is Lua for the RuneScape 3 client's plugin API. Its windows are built with PrettyUI (a required
dependency, see `plugin.json`). The `main` branch is the release; `dev` has the same code plus the debug probe
(`src/debug/`), the data generators (`tools/`) and debug buttons added to the settings from `main.lua`.

## Files at a glance

| Folder | File | Job |
|---|---|---|
| | `main.lua` | Wiring: loads the settings, connects the forest's callbacks to the route, windows and highlights, the settings' changes to what shows them, and handles game-state changes and shutdown. |
| `src/data` | `forest_features.lua` | What the forest contains: nodes, puzzle pairs, Trinks' daily tasks, colours; each feature's kind, by key. |
| | `settings.lua` | Every setting, its default, which settings it counts under, and loading and saving through `PersistentDB`. |
| | `zone_walkability.lua` | Which tiles of each template zone can be walked on (generated). |
| | `template_standing.lua` | What stands on each tile of each template zone, by height (generated). |
| | `model_bounds.lua` | The box round each feature's model, for the 3D highlights. |
| | `icon_sizes.lua` | The size each icon picture is drawn at (generated). |
| `src/game` | `forest.lua` | Detects the forest and tracks everything in it: zones, features, the grid, claims, tasks, followers, the player. |
| | `forest_grid.lua` | Builds the grid of walkable tiles, turning each zone the way the game turned it. |
| | `standing_heights.lua` | Reads what stands on a zone's tiles from the client, to tell how the zone was turned. |
| | `routes.lua` | Searches over the grid: the route to a target, the final route, the walk toward the centre. |
| | `solve_plan.lua` | Chooses a plan's next stop from the shortest tour, and which keys and doors a tour needs. |
| | `forest_stops.lua` | Turns found features into stops for the plans, and caches NAVIGATE's stops. |
| | `route_choice.lua` | The route chosen (a click, NAVIGATE or SOLVE): works it out and follows the player. |
| | `final_route.lua` | The final route, from the entrance past every node to the exit, worked out once per entry. |
| | `sets.lua` | Compares two sets (key -> true). |
| | `tools_held.lua` | Which puzzle tools the player has (`held`, worked out by `refresh`); `update` (on each inventory change) notes a tool used on its barrier. |
| | `ribbon_edges.lua` | The mitred edges of a route drawn as a ribbon, for the map and the ground. |
| | `highlights.lua` | The 3D boxes, the beam over the route's target and the route drawn on the ground. |
| | `model_bounds.lua` | Turns the saved model boxes into each placed feature's box. |
| | `dialogue_text.lua` | Reads the info box and the NPC dialogue box, for follow messages and refusals. |
| | `draw_distance.lua` | Raises the draw distance on entering, and restores the player's setting. |
| | `game_ids.lua` | Turns the game's config names into ids at load. |
| | `world_number.lua` | Reads the world number from the friends list's title, at load and when map sharing mode is turned on. |
| `src/ui` | `map_window.lua` | The map window: its frame's layout, header and compass, and opening, closing and hiding it. |
| | `map_layer.lua` | The map in the frame: zone pictures, routes, markers, entrance signs, the player. |
| | `node_legend.lua` | The node legend: a row per node and task, and NAVIGATE. |
| | `puzzle_legend.lua` | The puzzle legend: a cell per key and door, and SOLVE. |
| | `legend_windows.lua` | The legends' own windows, by their settings. |
| | `map_view.lua` | What the map shows, from the settings and the forest, worked out once per redraw. |
| | `map_widgets.lua` | The map's building blocks: texts, sprites, cells, outlines and buttons in the frame's style. |
| | `component_writes.lua` | Writes a component's place, size and hidden state only when they change. |
| | `settings_page.lua` | The hub's settings page and the same settings in a window. |
| | `ribbon_page.lua` | The hub's ribbon page: buttons, today's claims and Trinks' task. |
| | `keybinds.lua` | The keybind that opens or closes the map. |
| | `scout_window.lua` | The scout window: node kinds found, counts, monsters left. |
| | `full_forest_alert.lua` | The green flash and the click block on a 9/9 forest. |
| | `sharing_button.lua` | The map title bar's sharing-mode button. |
| | `status_text.lua` | A text that writes its content and colour only when they change, and the shared status colours. |
| | `window_place.lua` | Saves and restores a window's place and size. |
| `resources` | `*.png` | Icons for features and signs, and `zone_<x>_<z>.png` pictures of each template zone for the map. |

## The overall flow

```
plugin load (main.lua)
  ├─ Settings.load()                         saved switches, numbers, texts, window places
  ├─ data modules load: game names → ids     forest_features, model_bounds, zone data
  └─ Forest.start()
        │
        ├─ RegionCreated ──► watchRegion(true)      a new instance (fresh entry)
        └─ already in a region ──► watchRegion(false)  plugin reloaded inside a forest
              │
              ▼  every ServerLogic tick (≈0.6 s) while a region is watched: onServerTick
        ┌───────────────────────────────────────────────────────────────────────────┐
        │ not inside yet: is the player's zone copied from the forest's map square? │
        │   no for ARRIVAL_TICKS → stop watching                                    │
        │   yes → enter(readRegion()): zones, bounds, openings; raise draw distance │
        │ inside:                                                                   │
        │   LocAdded / LocRemoved events update the features found (announcement)   │
        │   while settling: scan locations (if not announced), heights and NPCs     │
        │   read the dialogue for follow messages and refusals                      │
        │   followPlayer() → playerTile → onMoved                                   │
        │   if anything changed: publish() → Forest.found, countOf, grid → onChanged │
        │   restore the draw distance once the grid is in use                       │
        └───────────────────────────────────────────────────────────────────────────┘
              │ callbacks (wired in main.lua)
              ├─ onEntered  → open the scout window / map; NAVIGATE starts once the search ends, if set to
              │   (each of onChanged, onMoved and onInventoryChanged first runs ToolsHeld.refresh, which says whether
              │    the tools held changed; RouteChoice.onDrawn hands each route worked out or cut back to
              │    Highlights.showChosen and MapWindow.showRoutes, except during a change to the forest or the tools
              │    held, which draws the map and the highlights once after it, the route with them)
              ├─ onChanged  → ScoutWindow.showForest, RouteChoice.showForest, MapWindow.showForest,
              │               Highlights.refreshWith, FullForestAlert.check
              ├─ onMoved    → MapWindow.showPlayer; RouteChoice.showPlayer (route follows), or if the tools held
              │               changed: RouteChoice.showHeld, MapWindow.showHeld, Highlights.refreshWith
              ├─ onInventoryChanged → if the tools held changed (ToolsHeld.refresh, which notes tools used):
              │               RouteChoice.showHeld, MapWindow.showHeld, Highlights.refreshWith
              ├─ onNpcMoved → RouteChoice.showNpcMoved, MapWindow.showNpcMoved
              └─ onLeft     → close the windows not open before entering (the map shows as it did then), clear
                              highlights, forget the route, plans, final route and tools
```

Leaving: `WorldCreated` (or a new region) calls `stopWatching`, which unsubscribes the forest's events, restores the
draw distance, forgets the forest and calls `onLeft`. Going to the lobby or login screen stops everything and saves
the settings; coming back into the game loads them and starts the forest again. `PluginShutdown` closes every window,
clears the highlights and saves the settings.

## Data files (`src/data`)

### `forest_features.lua`
- **Source:** written by hand, using the game's config names (`id.Loc`, `id.NPC`, `id.Obj`, `var.VarPlayer`).
- **Holds:**
  - `nodes`: the nine skill nodes. Each has `key` (icon and settings key), `name`, `skill`, `claimed` (the VarBit
    set once the node's XP is claimed today), `locations` (the `_OP` and `_NOOP` forms) and `addedAs` (the MultiLoc
    the server announces).
  - `nodeRotation`: the order the forest lays nodes out in, reading zones row by row from the south. A kind
    skipped between two nodes means a node was missed. `nodesInRotation` is the nodes in that order.
  - `tools`: the six puzzle pairs. Each has a `source` ("key") and a `barrier` ("door") feature, the tool's item
    (`toolItem`) or, for NPC tools, `followMessages` and `refusals` (Lua patterns capturing another player's name),
    and the pair's `colour`.
  - `dailyTasks`: Trinks' ten daily tasks, each with its quest struct (which the game's enum maps to the current
    task's value) and the variables or items its progress is counted in, for the hub page. `trinksTasks` are the two
    with a target in the forest (Pahtli plant, Traitor), which have a `key` and what the forest scan finds them by. A target is needed until its task's
    parts are done.
  - `colourOf(feature)` (a node's or task's from its colour setting, a puzzle's from its pair), `monstersAtMost`,
    `tasksADay`.
  - Each feature's `kind`, `layer`, `isPuzzle` and `pair`, set at load, and `all` and `byKey` listing them.
- **Used by:** almost everything. `forest.lua` builds its lookups (`featureOfLocID`, `featureOfNpcID`,
  `featureAddedAs`) from the names.

### `settings.lua`
- **Source:** the defaults in the file, then `PersistentDB` (shared by every client in this install).
- **Holds:** `SWITCHES` (booleans), `Settings.numbers` (the transparency slider), `STRINGS` (the header text and
  the keybind, saved as `GameKey` names), `COLOURS` (each skill's node colour and Trinks' tasks', 0xRRGGBBAA, saved
  as 0xRRGGBB) and `PLACES` (window positions and sizes, -1 when unset). After
  `Settings.load()` every value is a field of `Settings` (`Settings.hideUsedNodes`, `Settings.mapX`, ...).
  A setting may count only while another is on (`Settings.under`, a sub-setting on the page) or off
  (`Settings.offWhen`); `Settings.effective(key)` is a switch as it takes effect, and `Settings.isEnabled(key)`
  whether it can.
- **Used by:** every window and `highlights.lua` read it. `settings_page.lua` builds the settings page from its own
  `settingRows` list, which names each setting's key and the kind of change it makes (`onChange`, wired in
  `main.lua`). `Settings.save()` runs on shutdown and on going to the lobby.

### `zone_walkability.lua` and `template_standing.lua`
- **Source:** generated on `dev` by `tools/make_template_standing.py` from the debug probe's log of the template map
  square (65, 10). Do not edit them by hand.
- **Holds:** keyed by a template zone's south-west tile (`"4160_680"`):
  - `zone_walkability`: eight text rows, north to south, `.` walkable and `#` blocked.
  - `template_standing`: 64 heights, south row first, of what stands on each tile (0 for nothing). Zones with
    nothing standing are left out.
- **Used by:** `forest_grid.lua`. Every forest is built from these template zones, each copied and turned by a
  quarter turn the game does not report.

### `model_bounds.lua`
- **Source:** the nodes', keys', doors' and plant's boxes were measured from their models on `dev`. The three
  highlighted NPCs' boxes are their tile, with heights chosen by hand.
- **Holds:** `{ west, east, south, north, height }` in fine units (512 per tile), from the middle of the tiles the
  thing stands on, keyed by the base location's or NPC's name.
- **Used by:** `src/game/model_bounds.lua`, which keys the boxes by feature (every form of a feature takes its
  base location's box).

### `icon_sizes.lua`
- **Source:** generated on `dev` by `tools/make_map_art.ps1`, which also makes the pictures in `resources/`.
- **Holds:** each icon's drawn width and height in pixels, by feature or sign key.
- **Used by:** the map and its legends, to size markers, signs and legend pictures.

## Runtime structures

### Game ids (`game_ids.lua`)
Every number the game names is referred to by its name and resolved once at load: `GameIds.resolve(kind, name)`
returns the id, or nil for a name the game does not know (the client gives -1; `var.VarPlayer`, `GameKey` and
`config.Struct` give nil, and none raise an error). Unknown names are collected in `GameIds.unresolved`, which `dev`
prints. Runtime code compares the resolved ids only.

### The forest (`Forest`, in `forest.lua`)
`Forest` is the shared state of the forest the player is in. Other modules read its fields; only `forest.lua` writes
them.

| Field | Where it comes from | What it holds | Used by |
|---|---|---|---|
| `isInside`, `isSearching` | `enter`; the settling count | Whether a forest was recognised, and whether more may still be found. | Windows (the "Still looking" state), NAVIGATE's start. |
| `zones` | `readRegion`: `World.GetRegionSourceForCoordGrid` for every zone of the region's map squares | `{ x, z, sourceX, sourceZ, templateKey }`: each zone's south-west tile, the template zone it copies and that zone's key in the template data. | The grid, the map's zone pictures. |
| `bounds` | `readRegion` | `{ minX, minZ, width, length }` in tiles. | The grid, the map's scale, `followPlayer`. |
| `openings` | `readRegion`: zones copied from the opening template (4200, 664) | The mouth tile of the entrance and the exit. | The final route, the entrance signs, routes to an opening. |
| `standingByZone` | `StandingHeights.read`, retried as zones load | `"x,z"` → 64 heights. | `ForestGrid.build`, to turn each zone. |
| `grid` | `ForestGrid.build`, used once settled or after `GRID_WAIT_TICKS` | The walkable tiles (see below). | Every route and plan. |
| `zoneTurns` | the last grid built, settled or not | Zone index → quarter turns. | The map's zone pictures, which turn before the grid settles. |
| `found` | `publish`: the locations found plus the NPCs found, sorted by layer then south to north | Entries (see below), in drawing order. | Windows, stops, highlights. |
| `countOf` | `publish` | Feature key → how many were found. | Scout window, legends, alert, `doorsGone`. |
| `doorsGone` | `publish`: a barrier found before and missing now | Barrier key → true once its puzzle is done. | Stops, highlights, legends. |
| `following` | the dialogue: a follow message | Source key → true while that NPC tool follows the player. | `ToolsHeld`. |
| `keysTaken` | the dialogue: a refusal naming another player | Source key → that player's name; freed when they leave. | Stops (a taken key is a last resort). |
| `monstersSpawned` | `noteMonster`: attackable NPCs that are not familiars or the forest's own, counted once by uid | A count. | Scout window ("monsters left"). |
| `playerTile`, `entryTile` | `followPlayer`, each tick | The player's tile, and their first tile in the forest. | Routes, plans, the final route's start. |
| `ticks` | `onServerTick` | A counter. | Grid timing, the tool grace period. |

**An entry in `Forest.found`** is `{ feature, x, z, width, length, shapeType, bounds, isUsed }`. `x` and `z` are the
centre in tiles, and `width` and `length` the size as placed (turned with the location). `bounds` is the model box
from `ModelBounds`. `isUsed` is set on nodes whose claim VarBit is set. NPC entries also have `isNpc`, `npcID` and
`npcEntity`, the live entity the highlight follows; it, `x` and `z` follow the NPC each server tick (`followNpcs`).
Entries keep their identity while the feature stays at that tile: plans and routes compare entries, and a change
announced at a known tile updates its entry in place.

**How features are found.**
1. On a fresh entry the server announces every node, key and barrier as `LocAdded` events in its first ticks,
   before the client loads them. `onLocationAdded` turns each into an entry in `locationsFound` (by packed tile).
2. After a reload inside a forest the announcement has passed, so `scan()` reads `LocList.All()` each settling tick
   instead.
3. `LocRemoved`, or another location replacing one of the same shape on its tile, drops the entry. That is how a
   door opened by anyone drops off the map.
4. NPCs come from `NPCList.All()` while settling, then again on the tick after `NPCEntityAdded`.
5. Every find restarts an 8-tick settling count (`SETTLING_TICKS`). A tick with nothing new announced ends the
   announcement and the search.

**Claims and tasks.** Each node's claim is a VarBit of one base variable; a `VarTransmit` of that base re-reads the
claims and republishes. The current Trinks' task is `RAID1_GOEBIE_CURRENT_QUEST`, mapped to each daily task through
the game's enum and the task's struct; a task's target counts as done once the task's parts are. The task can change only at Trinks, outside the
forest, so inside it only the base variables of those tasks' parts republish (the Traitor killed), and an inventory
change republishes when it makes a target done or needed again (the fruit picked). `Forest.itemsHeld()` reads the
backpack and worn items. Inside the forest the result is kept until an `InventoryUpdated` for one of those
inventories; outside it is read on each call.

**The draw distance.** On entering, `DrawDistance.raise()` sets it to High so every zone's models load and their
heights can be read. It is restored once the grid is in use (after a reload, once the scans settle too), and always
on leaving.

### The grid (`forest_grid.lua`)
`ForestGrid.build(zones, bounds, standingByZone)` returns a grid: `{ minX, minZ, width, length, walkable, turns,
settled }` with `grid:index(x, z)` and `grid:tile(index)`. For each zone it finds the quarter turn whose template
heights (`template_standing`) best match the heights read from the client, then marks that zone's template
walkable tiles (`zone_walkability`), turned the same way. A zone whose turn matters but cannot be told yet makes the
grid unsettled: one with no heights, or whose heights match turns that differ in walkable tiles equally well. Such a
tie takes one of those turns meanwhile, and the zone (`grid.tiedZones`) is read again on each zone the player
enters, as a read from nearer may hold what one from afar lacked. The heights are compared through a table of where each tile goes per turn (`turnedIndex`), with no
turned copies, and the turned walkable tiles are cached by template, dropped on leaving. Each zone's turns are
matched again on every build: under a millisecond for a whole forest, and builds happen only as heights are read, so
they are not kept. A build whose turns match the last grid's returns that grid.

Searches cache data on the grid itself (`grid.steps`, `grid.stopDistances`), which is why a build matching the last
grid returns it. Heights read on a step reach the grid on the same server tick.

### Stops, plans and routes
The words used in the code (also listed at the top of `forest_stops.lua`):
- **stop**: a place a plan must or may visit (a node, a task's target, a key or a door).
- **target**: what one route ends at.
- **plan**: the choice of the next stop. Only NAVIGATE and SOLVE have one.
- **route**: the tiles walked to one target, drawn on the map and the ground.

**Stops** (`forest_stops.lua`) are `{ kind = "key" or "door", x, z, tiles, colour, entry, needs }`. `needs` is the
key stop a door needs, or nil when the key is held.
- `stopsWhere(isStop)`: the found features passing a test, as stops (`stopsOfKind`, `takenKeyStops`, NAVIGATE's
  targets: unclaimed nodes and the active task's target).
- `solveStops(held)`: each unfinished puzzle's key, unless held or taken by another player, and its door.
- `stopsToward(targets, player, held)`: a plan, `{ stops, unseenKeyDoors, takenKeys, puzzleStops }`: the targets
  plus only the keys and doors a tour to them needs (`SolvePlan.neededStops` traces the doors on the way to each
  target), the doors on the way whose keys are not seen yet, and the source keys on the way another player has.
- NAVIGATE's plan (`mappingPlan`) is cached by a signature of the found features, the tools held and the keys
  taken; the forest's few loops never lead round a barrier, so where the player stands does not change it. Its
  `unneeded` holds the puzzles no route to a node needs, which the map and highlights can hide.
- A node with several copies (more than nine nodes) needs only one visited: node stops share a `group`, and the doors
  and keys on the way to a copy are `optional`, so the plan opens one only if that copy adds the fewest tiles.

**Plans** (`solve_plan.lua`): `SolvePlan.nextStop(grid, player, stops, alwaysBlocked, remembered)` finds the first
stop of the
shortest tour through every reachable required stop, visiting one copy of each node, respecting doors (a door can only be crossed after its key) and leaving
out stops that cannot be reached (each costs more than any tour). It searches once from the player and once from
each stop, then runs a dynamic program over the sets of stops visited. `RouteChoice` keeps the last plan by its
inputs, with the current target while the player follows its route. The program's cheapest tours from each stop
(`remembered`) do not depend on where the player is, so they are kept with the plan: a player straying from the
route has the first stop worked out again from those, a few milliseconds whatever the number of stops (about 150 ms
anew for 20 stops). They take up to about 200 KB for 12 to 14 stops and 1.5 MB for 20.

**Routes** (`routes.lua`) are breadth-first searches over the walkable tiles: four straight steps plus diagonals
between two open sides, with barrier tiles blocked. A target is reached from the tiles beside it (`tilesRound`).
Routes are returned as their corner tiles.
- `routeTo` / `routeFrom`: the route to the nearest of some targets, and the target it reaches.
- `finalRoute`: the tree of ways from the entrance to every node and to the exit, from one search, drawn in white.
- `routeTowardCentre`: when every needed door's key is still unseen, the route walks toward the forest's centre.

### The route chosen (`route_choice.lua`)
One route is chosen at a time, map open or not: `RouteChoice.choice` is nil, `{ plan = "navigate" }` (NAVIGATE down),
`{ plan = "solve" }` (SOLVE down) or `{ key }` (the feature, puzzle or sign clicked), set by `toggle`, `togglePlan`
and `clear`. `startMappingAfterSearch` presses NAVIGATE once the search ends, unless a route was chosen or dropped
before. `update` works the route out (`chosenRoute`): a plan's next stop
for NAVIGATE or SOLVE, or a route to the thing clicked; a target behind a door becomes a small plan toward it. It
keeps the result in `RouteChoice.drawn` (`{ tiles, colour, target, stops, unseen, ahead, trimmedX, trimmedZ }`)
and calls `RouteChoice.onDrawn`, which main.lua hands to the highlights and the map. It runs
again when the forest, the choice or the tools held (`ToolsHeld.held`) change; on each step `showPlayer` cuts the
route back to the player's nearest point on it (`ahead`, `onDrawn(true)`), and straying more than three tiles works
it out again. A plan drops its choice once it has nothing left, and a feature chosen with work left (`waitsFor`) drops
once that is done.

### The map window (`map_window.lua` and its parts)
The open window's state is the table `parts`, which `map_window.lua` passes to the modules drawing its parts: the
PrettyUI window, every component created and the frame's layout.
- `map_window.lua` lays the frame out (`layout`), draws its panels, header and compass, and opens, closes, hides and
  rebuilds the window. `MapWindow.shownState` and `MapWindow.restore` keep what of it showed before entering.
- `map_layer.lua` draws the map: zone pictures, routes, markers, entrance signs and the player.
- `node_legend.lua` and `puzzle_legend.lua` each build, lay out, count and outline their legend, in the frame or in
  its own window (`legend_windows.lua`).
- `map_view.lua` turns the settings into what to show (`view()`, where sharing mode overrides most of them) and works
  out the legend rows and puzzles shown, once per redraw (`MapView.newRedraw`, at each way in).
- `map_widgets.lua` makes the texts, sprites, cells, outlines and buttons in the frame's style.

It draws the route from `RouteChoice.drawn` whenever `RouteChoice.onDrawn` calls `showRoutes`, and a click (a
marker, a sign, a legend row, NAVIGATE or SOLVE) goes to `RouteChoice.toggle` or `togglePlan`.
Closing it leaves the route chosen running. While a legend is in its own window, its X only hides it.

Flow:
1. `MapWindow.open` builds the frame (`build`) and lays it out (`layout`) for the window's size.
2. `showForest` (each `onChanged`) places the zone pictures, the markers, the signs and the legends' counts, and paints
   the routes.
3. `MapLayer.paintRoutes` draws the chosen route from the player on, or with nothing chosen the final route
   (`final_route.lua`), worked out once per entry when first asked for after the search ends and the grid settles.
   `showRoutes` adds the legend's pressed buttons and outlines and the icons shown only as the route's stops. A canvas
   can only be cleared whole, so the piece the player walks along has a canvas of its own (`routeStart`), and the
   rest (`routes`) is drawn again only when it changes: a corner passed, another route, or the map's size
   (`restPainted`). The final route is drawn once that way too.
4. `showPlayer` (each step) moves the player marker; the route is drawn again by `showRoutes`. A moved NPC moves only
   its own marker (`markerOf`).
5. Window resizes go through an override of the window's `SetSize`, which lays the frame out for the new size.
6. While the map is hidden by its X (a legend's own window shown), its zones, routes, markers and player wait
   (`MapLayer.isHidden`, `mapStale`) and are placed when it shows again; the legends keep up.

Every component's place, size and hidden state is written only when it changes (`component_writes.lua`), and texts
likewise (`showLabel`, `StatusText`). On close the window's own `Destroy` takes its components. The sharing button is a child of the window's title drag layer, so
it hides and raises with the title bar; it is not a PrettyUI overlay, as PrettyUI raises overlays over every window on
each resize. Every window opts in to PrettyUI's automatic component IDs (`categoryID = "auto"`): raw components go
only under a window's content or the plugin layer, and the button is made with `PrettyUI.NewComponent`. The map's route and the ground ribbon share their mitred edges (`ribbon_edges.lua`).

### World highlights (`highlights.lua`)
- `wanted()` turns the settings and the route's stops into the highlights wanted now:
  `name → { entry, colour, x, z, box, faces, beam }`, each kind true when wanted.
- `shown` holds what exists:
  - locations get `ShapeList` entities (a box, and a beam over the route's target), with shapes shared through
    `shapes`, keyed by size and transparency;
  - NPCs get `ShapeList` instances (edges, faces and beam as separate shapes), moved to the live NPC on each
    `Logic` tick while one is tracked (`followTracked`).
- `refresh` adds, removes and recolours to match. When the target changes, the new beam may be made before the old
  one goes, within the same call. `showChosen` takes the chosen route and refreshes only when its target or stops
  change; `refreshWith` takes it and refreshes, after a change to the forest or the tools held.
- The chosen route is a flat ribbon on the ground (`routeEntity`, plus `segmentEntity` for the straight run the
  player is on), reshaped in place as the player walks (`trimRoute`). A refresh draws what is left ahead of the
  player, and leaves the ribbon alone when given the same tiles again.

### The scout window and the alert
`ScoutWindow` shows `Forest.scoutCounts()`: the node kinds found, plus kinds the rotation shows were missed once
the search settles, each kind's count, and `ForestFeatures.monstersAtMost - Forest.monstersSpawned` monsters left.
`FullForestAlert.check()` runs on every change and, once per entry, flashes the screen and optionally blocks clicks
when every kind is present (or, by a setting, every kind still unclaimed today: `Forest.isFull`).

### The hub pages and settings
- `ContentLayerReady` builds the ribbon page (`ribbon_page.lua`): buttons, and today's claims and tasks. The page
  listens to `VarTransmit` while it exists, and to the backpack while the current task counts items.
- `SettingsLayerReady` builds the settings page (`settings_page.lua`); the same rows also build the settings window.
- Each row's `onChange` names the kind of change, and `main.lua` maps each kind to what shows it
  (`MapWindow.showSettings`, `Highlights.refresh`, ...). The route settings only draw the route again. A colour
  setting recolours the node legend's outlines and the highlights, and works the chosen route out again, as a route
  takes its colour when worked out.
- A colour row's swatch is PrettyUI's colour picker (`AddColourPicker`), whose window sets the colour on Accept.
- The map's sharing button changes its setting on the frame after its click, as the change may rebuild the map and
  the button with it.
- The one keybind (`keybinds.lua`) opens or closes the map, and `KeyDown` is listened to only while it is bound.

## What runs when

| Event | Subscribed | Work |
|---|---|---|
| `ServerLogic` | While a region is watched | `onServerTick` (forest). |
| `LocAdded`, `LocRemoved`, `NPCEntityAdded`, `VarTransmit`, `InventoryUpdated` | While a region is watched | The forest's changes. |
| `Logic` (50/s) | While an NPC is highlighted | `followTracked` moves its box. |
| `Logic` (50/s) | During the 5 s alert | The flash. |
| `Draw` (per frame) | During a map resize drag | Fits the window on release. |
| `Draw` (per frame) | For one frame after the alert's unblock button is clicked | Removes the button. |
| `Draw` (per frame) | For one frame after the map's sharing button is clicked | Turns map sharing mode on or off. |
| `Draw` (per frame) | For one frame after the hidden map's last legend window hides | Closes the map. |
| `Draw` (per frame) | For two frames after each resize step of the settings window | Sets the sliders again, so their thumbs match their values (until PrettyUI 1.4.0). |
| `KeyDown` | While the keybind is bound | The keybind. |
| `ContentLayerReady`, `SettingsLayerReady`, `GameStateChanged` | Always | The pages and the game state. |

Nothing else runs every frame. State the server owns is checked on `ServerLogic`, not `Draw`.

## Working on the plugin
- Reload in game with `prl nemi_mapper`. Log lines start with `[nemi_mapper]`.
- There is no Lua interpreter on the machine. Syntax checks and stub tests run under Python with `lupa` (Lua 5.5).
  The stub test replays logged forests with stand-in globals (`Event`, `World`, `LocList`, `NPCList`, `ui`,
  `PersistentDB`, ...). It lives outside the repo and is run against `dev`.
- Source files are CRLF in the working copy and lines stay within 120 columns.
- Changes go to `dev` and `main` alike, except `main.lua`, which differs (the probe, and the debug buttons it adds
  to the settings through `SettingsPage.addExtras`).
- Regenerate data with the tools on `dev` rather than editing the generated files.

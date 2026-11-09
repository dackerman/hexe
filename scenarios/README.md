# Scenarios

Declarative regression worlds. Each `*.zon` file here describes a small
world, what happens to it, and what must be true afterwards. The headless
runner (`zig build scenarios`) builds the world on the GPU, simulates it and
checks the assertions. Parsing and validation live in
`src/data/scenario.zig`; `zig build test` parses every file here and checks
that every material name exists.

## Coordinates

Cells. `x` grows to the right, `y` grows **downward** (gravity is +y), the
origin is the top-left corner. A rect covers `x ≤ cx < x + w`,
`y ≤ cy < y + h`. The world is not a torus: cells outside it are treated as
the world edge.

## File layout

```zig
.{
    .name = "dam_break",              // must equal the file name
    .description = "...",             // one or two sentences, shown on failure
    .size = .{ .w = 256, .h = 256 },  // optional, default 256 x 256, max 2048
    .requires = .{ .flip },           // optional: systems needed (flip, air_field, explosions, particles, bodies)
    .seed = 0,                        // optional, seeds the simulation hash
    .ticks = 900,                     // how long to run
    .fills = .{ ... },                // optional, applied in order before tick 0
    .commands = .{ ... },             // optional, applied at ticks
    .assertions = .{ ... },           // at least one
}
```

Everything not listed in a fill starts as air at 20 °C.

### Shapes

Fills, `remove`, `ignite` and `heat` take exactly one shape:

| shape | fields |
|---|---|
| `.rect` | `.x, .y, .w, .h` |
| `.circle` | `.x, .y, .r` (cells within distance `r` of the center) |
| `.line` | `.x0, .y0, .x1, .y1`, optional `.width = 1` |

Shapes may extend past the world edge and are clipped, but a shape entirely
outside the world is an error.

### Fills

```zig
.{ .rect = .{ .x = 0, .y = 248, .w = 256, .h = 8 }, .material = "bedrock" },
.{ .circle = .{ .x = 40, .y = 60, .r = 6 }, .material = "lava", .temperature = 1200 },
.{ .rect = .{ .x = 92, .y = 96, .w = 4, .h = 64 }, .material = "wood", .state = 1 },
.{ .rect = .{ .x = 60, .y = 42, .w = 20, .h = 4 }, .material = "water", .only = "air" },
```

| field | default | meaning |
|---|---|---|
| `.material` | required | material name from `materials/` (or `"air"`) |
| `.temperature` | material's spawn temperature | °C, −40 to 2000 |
| `.state` | material default | state byte 0–255 (health, lifetime) |
| `.only` | paint everything | only paint over cells of this material |

Later fills overwrite earlier ones, so carving is "fill stone, then fill air".

### Commands

```zig
.{ .tick = 60, .remove = .{ .rect = .{ .x = 128, .y = 120, .w = 1, .h = 112 } } },
.{ .tick = 1, .ignite = .{ .rect = .{ .x = 108, .y = 200, .w = 40, .h = 40 } } },
.{ .tick = 5, .heat = .{ .circle = .{ .x = 30, .y = 30, .r = 4 }, .temperature = 900 } },
.{ .tick = 10, .explode = .{ .x = 24, .y = 59, .radius = 6, .strength = 1.0 } },
.{ .tick = 0, .every = 1, .until = 60, .fill = .{ .rect = .{ ... }, .material = "water", .only = "air" } },
```

Each command has `.tick` and exactly one action:

| action | effect |
|---|---|
| `.fill` | paint a material, same fields as a fill |
| `.remove` | set the shape to air |
| `.ignite` | set the burning flag on flammable cells in the shape |
| `.heat` | set the temperature of every cell in the shape, `.temperature` in °C |
| `.explode` | explosion command at `.x, .y` with `.radius` in cells and `.strength` relative to a standard (gunpowder) explosion, default 1 |

`.every = N` repeats the command every N ticks from `.tick` up to and
including `.until` (or to the end). Pouring is a repeated `.fill` with
`.only = "air"`. Commands apply before the simulation step of their tick;
commands on the same tick apply in file order.

### Assertions

Checked after the simulation step of `.tick` (default: the last tick).
Each has exactly one kind and an optional `.label` printed on failure.

| kind | fields | passes when |
|---|---|---|
| `.count` | `.material`, `.rect` (default world), `.min = 0`, `.max` (default unbounded) | the number of `material` cells in the rect is within `min…max` |
| `.at` | `.x, .y, .material` | that cell is `material` |
| `.none` | `.material`, `.rect` (default world) | no cell of `material` in the rect |
| `.particles` | `.rect` (default world), `.min = 0`, `.max` | the number of particle-backed (awake liquid) cells is within range; `.max = 0` means asleep |
| `.pressure` | `.x, .y`, `.min` and/or `.max` | air-field density at the cell, relative to ambient 1.0, is within range |
| `.temperature` | `.material`, `.rect` (default world), `.min` and/or `.max` (°C) | the mean temperature of the `material` cells in the rect is within range (fails when there are none) |
| `.deterministic` | `.runs = 2` | running the whole scenario `runs` times from scratch gives bit-identical cell images at the tick |

Assertion rects and points must lie inside the world.

## The scenarios

| file | protects |
|---|---|
| `sand_pile.zon` | powder fall and slide, mass conservation |
| `water_spreads_flat.zon` | liquid spread to a level layer, sleep after settling |
| `lava_water.zon` | water + lava → stone + steam |
| `lava_enclosed.zon` | lava sealed in rock stays molten; an open surface cools slowly (decision 142) |
| `wood_burns.zon` | burning: wood → charcoal → ash with smoke |
| `sand_lava_glass.zon` | sand + lava → molten glass → glass on cooling |
| `u_tube.zon` | 04-fluids scenario 1: U-tube equalizes within 2 s |
| `dam_break.zon` | 04-fluids scenario 2: dam removed, wave crosses, levels settle |
| `sealed_steam_room.zon` | 04-fluids scenario 3: sealed steam raises pressure, weak wall fails first |
| `corridor_blast.zon` | 04-fluids scenario 4: a corridor carries a blast twice as far |
| `pool_sleep.zon` | 04-fluids scenario 5: pool sleeps, wakes locally, far edge stays asleep |
| `determinism.zon` | 04-fluids scenario 6: identical results from the same seed |

The numeric thresholds (counts, ticks, pressures) are first guesses from
the material tables; expect to tune them when the runner first executes
these, and record any change of intent in `docs/decisions/`.

## Running

`zig build scenarios` runs every file here; `hexe --headless --scenario
FILE` runs one (`--screenshot PREFIX` writes PNGs at assertion ticks,
`--shot-every N` more). A scenario whose `.requires` names a system not
built yet is reported SKIP with the reason. The world is framed by a
one-cell bedrock ring. Details: docs/decisions/44-reactions-scenario-runner.md.

## Adding a scenario

1. Copy the closest existing file and rename it; `.name` must match.
2. Build the world with fills, add commands, and assert the behavior you
   want to protect with the loosest bounds that still catch a regression.
3. `zig build test` checks that it parses and names real materials.

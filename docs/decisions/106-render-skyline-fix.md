# Render: terrain surface by 1D morphology, no fake walls beside objects

**Context**: beside any small standing object in the open (a corpse body,
a post, a crate, a falling sand stream, the witch's body cells, a 2 px
step), the world pass drew dark, blurry, ~24 px wide back-wall shapes about
24 px to either side, from the floor up to the object's height, with less
ambient light there. There were no cells. Cause: `surface_at` in
`shade.glsl` was `min(skyline(x), skyline(x - 24), skyline(x + 24))`
(decision 102), a dilation of the terrain height. It fills narrow shafts
(so they show the back wall, the intent) but also widens every narrow
upward feature by 24 px per side, and both the sky-or-back-wall choice in
`world.frag` and the ambient depth (`ambient_at`, also used by sprites)
read it. The cascade sky escape in `rc_cascade.comp` already used the
exact column's skyline and was not involved.

**Decision**:
- `skyline.comp` gets a second pass (push constant `pass_index = 1`, one
  64-thread workgroup per 64 region columns, dispatched after the skyline
  pass and the light-scene pass's barrier) that writes the *terrain
  surface* per region column at `skyline[region_size.x + col]` (the buffer
  is now `2 * max_region` ints). It is the skyline under a 1D
  morphological opening, then closing, of the height, radius R = 24
  columns (window 49): in y-down terms max-filter, min-filter (removes
  upward features narrower than 49 columns: bodies, posts, crates, the
  witch, sand streams, thin spires), then min-filter, max-filter (fills
  dips narrower than 49: shafts, gaps between walls). Wide features keep
  their exact edges, so nothing spreads sideways. Each workgroup loads
  64 + 2 * 4R skyline values into shared memory (edge columns repeated,
  equal to clamping the window to the region) and filters there.
- `surface_at` reads that row; `background()` (sky above the surface,
  back wall below) and `ambient_at` use it unchanged otherwise.
- The cascades keep testing the raw skyline of the ray's exit column:
  sky light still enters open shafts and real occluders (thin pillars
  included) still shadow through the cascades.

**Alternatives**: exact per-column skyline for the background (the first
suggestion): a shaft or a hole in a cave ceiling then shows a sky stripe
all the way down to the cave floor (the `lighting` scene's 40 px skylight
shaft would paint the cave), and a body in the air (jumping witch, flying
debris) would paint back wall under itself down to the floor. A vertical
"solid above within 64 px" test per fragment: same shaft problem, 64
loads per air pixel. Closing only (no opening): fixes the sideways spread
but still puts back wall under floating small bodies and between a
corpse's legs. A single-workgroup filter over the whole row: correct but
serial (and 16-24 KB of static shared memory hurt the skyline pass's
occupancy), +45 us; the tiled version costs about +5 us of light_build.

**Consequences**: small things in the open show sky beside, under and
between them; caves, roofed interiors and shafts up to 48 px wide show
the back wall as before; wider shafts and cave mouths show sky down to
their floor, as before. An object that is part of a wider solid profile
(a 60 px crate stack) is terrain for this purpose and has sky only above
it, which is correct. Verified by view screenshots of walker_death
"died", walk "stand"/"jump_apex", `lighting` (zoom 2 at 1060,1150 and
zoom 1 at 1024,950: identical cave, shaft and lava lighting; the fake
24 px slabs beside the rock mass are gone) and `fire_demo` (the fake
posts beside the sand stream, the box, the rim walls and the 2 px steps
are gone). bench-render light_build ~0.019-0.028 ms -> ~0.023-0.036 ms;
all configurations well under the 3 ms budget. R would be reopened if
levels need a different notion of "narrow" (it is SURFACE_R in
skyline.comp).

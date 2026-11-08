# Bodies on the torus: unwrapped coordinates, recentered near the camera

**Context**: the grid is a 2048-px torus; Box2D does not wrap.

**Decision**: bodies live in unwrapped world coordinates. Rasterization,
readback and commands wrap them (`wrap_coord`, 64 px tiles map modulo the
world). Static collision tiles are keyed by unwrapped tile coordinates, read
from wrapped cells, so collision is correct on both sides of a seam. After
each step `recenter` shifts every body (beams as a whole) by a multiple of
2048 px when it is more than half a world from the center
(`BodySim.setCenter`: the camera center in the app, the world center
headless); welded beam ends are released and re-welded at the shifted
position. A shift changes nothing on screen.

**Alternatives**: wrapping Box2D positions (impossible without a custom
broadphase); one Box2D world per torus copy (duplication).

**Consequences**: `bodies_crate` drops a second crate onto a floor across
x = 2047|0; it lands straddling the seam, is recentered from x 2049.35 to
1.35 and rasterizes its 1600 cells intact. When chunk streaming moves the
window, the same shift is what moves bodies with it; anchored beams lose
their accumulated plastic bend at the anchor joint when re-welded.

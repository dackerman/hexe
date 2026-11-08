# Beam joints: stiffness, plastic yield, fracture

**Context**: D7 and the architecture call for beams as segment chains with
weld joints that flex, take a permanent bend past yield, and break past
fracture. Box2D v3 welds are soft constraints, and its solver is
approximate for long chains.

**Decision**:
- `createBeam` makes `segments` box bodies of whole-pixel length (so the
  segment bitmaps tile exactly) joined by welds at the shared end points,
  with optional welds of either end to a shapeless static anchor body. The
  anchor joints yield and break like the others; a cantilever's moment peaks
  there.
- **Stiffness.** Box2D's "rigid" welds still have a position stiffness of
  roughly I_segment / h², and a long chain of light segments sagged like a
  rope (34 px tip drop at 0.5 s on a bare 120 px steel cantilever, whatever
  the substep count or joint hertz). Segment rotational inertia is therefore
  multiplied by `Config.beam_inertia_scale = 60`. The whole beam's inertia is
  dominated by the parallel-axis term, so a 12-segment beam's inertia grows by
  only a few percent, while the bare cantilever's elastic sag drops to about
  1.5 px. Welds use `angularHertz = 0` (stiffest) by default;
  `BeamProps.angular_hertz` can soften a material.
- **Yield (plastic flow).** After each step, for each awake joint, read
  |M| = |`b2Joint_GetConstraintTorque`|. Above M_yield, the joint's rest angle
  moves against the torque's sign (rotate local frame A) by
  `min(flow_rate · (|M|/M_yield − 1) · dt, max_flow_per_tick)`. This
  viscoplastic rule bends steadily under steady overload and stops when the
  bend lowers the moment. The bend is kept in the joint frame, so it is
  permanent.
- **Fracture.** Destroy the joint when the smoothed |M| exceeds
  M_fracture, the smoothed joint force exceeds F_fracture, or the accumulated
  plastic angle exceeds `fracture_plastic_angle` (ductility). Smoothing is an
  exponential moving average with weight `fracture_smoothing` per tick:
  ductile steel (0.15) rides out one-tick contact spikes and bends instead of
  shattering on landing; brittle materials use 1 (instant).
- **Scaling with thickness t (px).** M_yield = yield_moment · t²,
  M_fracture = fracture_moment · t² (section modulus of a rectangle),
  F_fracture = fracture_force · t, each times the joint's `strength`
  (1, lowered by `weakenBeamAt` when cells are cut: moment capacity goes with
  the remaining thickness squared).
- **Values** (moments in kg/s², forces in kg/s² per px, since
  kg·px²/s² ÷ px² = kg/s²):

| material | density kg/px | yield_moment | fracture_moment | fracture_force | ductility rad | smoothing | flow rad/s | max flow rad/tick |
|---|---|---|---|---|---|---|---|---|
| steel | 0.98 | 5.0e5 | 1.25e6 | 2.0e7 | 0.5 | 0.15 | 0.08 | 0.003 |
| wood | 0.075 | 6.0e4 | 6.6e4 | 2.0e6 | 0.1 | 0.6 | 0.3 | 0.005 |
| concrete | 0.30 | 1.0e5 | 1.0e5 | 3.0e5 | none | 1 | 0 | n/a |

  Steel is about 1/4 of a real 250 MPa section (k = σ·depth/6 with 5 cm depth
  ≈ 2e6), so ordinary loads bend 4 px beams. Wood is weaker than real
  timber so planks snap under a person-sized load. Concrete is unreinforced
  and brittle: a 4 × 120 px concrete cantilever cannot hold itself.
- Measured (120 × 4 px, 12 segments, load welded at the tip; tests and
  `zig build bodies-demo`): steel unloaded sags about 1.5 px and holds; steel
  with 200 kg sags 7 px at 0.5 s and 12 px at 2 s, all joints intact, root
  bent permanently; with 1000 kg it snaps at the wall at 0.38 s; wood with
  40 kg snaps at 0.22 s with about 4 px of tip deflection; a torch cutting the
  loaded steel beam at 15 % thickness per second from 2 s makes it sag from 12
  to 31 px and snap at 4.55 s.

**Alternatives**: soft welds with tuned `angularHertz` alone (stiffness
scales with segment inertia, so beams were rubbery under any useful load);
more sub-steps (cost is world-wide, and 16 sub-steps barely changed the sag);
Box2D's `torqueThreshold` joint events (break only, no plastic flow, no
smoothing); a custom beam solver (D7 says no).

**Consequences**: free beam segments spin a bit slowly after snapping
(60 × self inertia). Parameters are per material, ready to move into the
material ZON files when the material loader lands. Reopen if beams need
to be much longer (more than about 30 segments) or carry loads more than
about 30 times their own mass, where the chain sags elastically again.

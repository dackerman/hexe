# Impact events, blast and fluid forces

**Context**: gameplay needs hard landings reported (chips, sparks, rubble),
and the air and liquid solvers need hooks to push bodies.

**Decision**:
- **Impacts.** All body shapes enable Box2D hit events; the world's hit
  threshold is `Config.hit_speed_threshold` (20 px/s = 1 m/s). After each step
  every hit event becomes an `Impact` with both bodies (null = static
  terrain), world point, normal, approach speed, `normal_impulse` =
  reduced mass × approach speed, and `solver_impulse` = the normal impulse
  Box2D applied in that step (sum of manifold `totalNormalImpulse`).
  Events below `Config.impact_impulse` (500 kg·px/s) on `normal_impulse` are
  dropped. Box2D's soft contacts spread a landing over a few steps (a 30 kg
  box landing at 166 px/s showed 2600 kg·px/s in the hit step against the
  true 4980), so the momentum-based value is the stable one to threshold.
- **Blast** (`applyBlast(cx, cy, radius, strength)`): every body whose
  bounding circle (half radius) is within `radius` gets an impulse of
  `strength · (1 − d/radius) · pixel_count` along center → center of mass.
  `strength` is impulse per body pixel, so Δv ≈ strength / density: wood
  flies, steel shifts. Beam segments are pushed individually, which loads
  their joints.
- **Fluid** (`applyFluid(h, fluid_velocity, drag, angular_drag,
  buoyancy_force)`): force = drag · (v_fluid − v_body) + buoyancy, torque =
  −angular_drag · ω, applied for the next step. Drag is clamped to
  mass / dt (and angular drag to inertia / dt) so a large coefficient cannot
  reverse the relative velocity in one tick. The liquid solver computes
  buoyancy (ρ · submerged pixels · 196, upward) from its readback.

**Alternatives**: thresholding Box2D's per-step impulse (depends on contact
softness and sub-steps); begin-touch events plus manifold reads (no approach
speed, impulse not yet solved); `b2Shape_ApplyWind` for drag (per shape, no
buoyancy, no clamp).

**Consequences**: impact strength is comparable across materials and
solver settings. Resting contacts produce no events because hits need an
approach speed above the threshold. Up to `Config.max_impacts` events per
step are kept; extra ones are counted in `impacts_dropped`.

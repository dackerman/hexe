# Hexe Documentation

Read in order the first time. After that, the decision log is the place to
check before changing anything structural.

| document | what it covers |
|---|---|
| [00-vision.md](00-vision.md) | what the game is, its pillars, what the world can and cannot do, scale |
| [01-architecture.md](01-architecture.md) | engine layers, cell format, CPU–GPU boundary, streaming, rendering, budget, limits, repo layout |
| [02-interaction-classes.md](02-interaction-classes.md) | the fixed set of mechanisms, their representatives, how to add a material or a class |
| [03-materials.md](03-materials.md) | material schema and the version one set with properties, reactions and byproducts |
| [04-fluids.md](04-fluids.md) | the air field and liquid solver in detail, coupling, sleep and wake, first scenarios |
| [05-milestones.md](05-milestones.md) | build order with done criteria |
| [06-decisions.md](06-decisions.md) | why each major choice was made and what would reopen it |
| [07-tech-demo.md](07-tech-demo.md) | the first playable level: zones, tools, controls, enemies, what must be visible |
| [08-engineering.md](08-engineering.md) | toolchain, build targets, code and shader conventions, testing, decision recording, git |
| [09-decision-review.md](09-decision-review.md) | review of every implementation decision made during M0-M8 and integration: departures, tuning knobs, open items |
| [decisions/](decisions/) | implementation-time decisions, one file each |

`materials.md` is generated from the ZON files in `materials/` by
`zig build docs`; the loaded set is the engine's only material table
(decisions/110-integrate-material-layout.md). Decisions 110-119 record the
integration of the milestone branches.

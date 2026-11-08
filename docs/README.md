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
| [08-engineering.md](08-engineering.md) | toolchain, build targets, code and shader conventions, testing, decision recording, git |
| [decisions/](decisions/) | implementation-time decisions, one file each |

`materials.md` will be generated from the ZON files by `zig build docs`
starting at milestone 3 and will replace the tables in `03-materials.md`.

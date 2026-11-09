# Hexe

A 2D action game where every pixel is simulated material and pressure is
real. Written in Zig, simulated on the GPU with Vulkan.

Status: playable tech demo. The engine is complete (pixel grid with
reactions and fire, lattice Boltzmann air with real pressure waves, FLIP
water with sleeping pools, Box2D bodies rasterized into the world,
particles, radiance-cascade lighting, streamed procedural world), and the
Proving Grounds level shows every interaction. There is no game yet.

## Play

Requires Linux with a Vulkan driver, SDL3, `glslc`, and Zig 0.17.1
(`.zigversion`; the dev machine has it at `~/.local/bin/zig`).

```bash
zig build run -Doptimize=ReleaseFast
```

You spawn at the hub on the surface. Press **F1** for the tool and key
table. The short version:

| keys | action |
|---|---|
| A / D, Space | move, jump (held for higher); in water Space swims up, S dives |
| mouse | aim; left button fires the tool, right button its secondary; wheel changes brush size or the painter's material |
| 1 fire bolt, 2 blast charge, 3 water, 4 lava, 5 acid, 6 dig, 7 lightning, 8 cutter / steel beam, 9 gunpowder / wood box, 0 painter | tools |
| Tab | cycle overlays: activity tiles, air pressure, air velocity, liquid particles, bodies, temperature, light |
| R | reset the level; P pause; F3 timings; Escape quit |

Things to try, left to right and down: shoot the sand dunes with a blast
charge, burn the village and watch smoke follow the air, shoot the thin
wooden dam and the steam-room plug, set off the gunpowder at both mouths
of the corridor and compare it with the open field, pour lava on the sand
pit, cut the steel beams in the ruin with the cutter and blow out the
pillar under the watchtower, put lightning into the pool with the
walker standing in it, pile up gunpowder with tool 9 and light it with a
fire bolt, and pour water onto the lava in the steam room to boil it.

Other modes: `--sandbox` (paint materials, pan), `--world --seed N`
(endless procedural caves, F5 saves), `--scene proving_grounds_auto
--headless --demo-script shots/demo` (the scripted showcase as PNGs).

## Verify

```bash
zig build test && zig build verify-determinism && zig build scenarios && zig build bench
```

`docs/08-engineering.md` lists every build target. `docs/09-decision-review.md`
is the one-sitting review of every decision made during the build.

Start with [docs/README.md](docs/README.md).

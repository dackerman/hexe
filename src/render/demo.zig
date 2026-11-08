//! Per-scene render decorations: point lights, placeholder sprites and
//! floating signs that a scene has no cells for (until gameplay exists),
//! plus the render settings a scene wants. Called once per frame by the
//! windowed app and before headless view screenshots.
const scenes = @import("../sim/scenes.zig");
const Renderer = @import("renderer.zig").Renderer;
const Settings = @import("renderer.zig").Settings;
const Hud = @import("hud.zig").Hud;

/// Adjust the defaults for `scene` (call once, after the engine is created).
pub fn configure(scene: scenes.Scene, settings: *Settings) void {
    switch (scene) {
        .lighting => {},
        // Tech demo: lit by sky, lava and torches, with enough cave ambient
        // that unlit rooms still read.
        .proving_grounds, .proving_grounds_auto, .proving_grounds_burst => settings.ambient_cave = .{ 0.16, 0.16, 0.19 },
        // Closed boxes without light sources: keep them readable.
        else => {
            settings.ambient_cave = .{ 0.30, 0.30, 0.32 };
            settings.ambient_surface = .{ 0.42, 0.42, 0.45 };
        },
    }
}

/// This frame's lights, sprites and signs for `scene` at `tick`.
pub fn decorate(scene: scenes.Scene, tick: u32, r: *Renderer, hud: *Hud) void {
    switch (scene) {
        .lighting => lighting(tick, r, hud),
        // Tech demo: torches and every sign (the app passes its camera to level.drawSigns instead).
        .proving_grounds, .proving_grounds_auto, .proving_grounds_burst => @import("../game/level.zig").decorate(r, hud),
        else => {},
    }
}

fn lighting(tick: u32, r: *Renderer, hud: *Hud) void {
    const t: f32 = @floatFromInt(tick);
    // Wall sconces: warm on the left, cold crystal on the right.
    r.addLight(782, 975, 90, .{ 1.0, 0.62, 0.3 });
    r.addLight(1192, 960, 80, .{ 0.35, 0.6, 1.0 });
    // The witch's wand, bobbing a little.
    const wx: f32 = 1048;
    const wy: f32 = 1150;
    r.drawSprite(wx, wy, 12, 30, r.witch, false, .{ 1, 1, 1, 1 });
    r.addLight(wx + 10.5, wy + 13.5 + @sin(t * 0.05) * 1.5, 40, .{ 0.4, 0.9, 1.0 });
    r.drawSprite(1066, 1164, 16, 16, r.crate, false, .{ 1, 1, 1, 1 });
    r.drawSprite(1078, 1148, 16, 16, r.crate, true, .{ 0.85, 0.85, 0.85, 1 });
    // Debug primitives: the tank's bounds and a line to the lava.
    r.drawRect(1098, 1088, 124, 94, .{ 0.2, 1.0, 0.4, 0.6 }, false);
    r.drawLine(1048, 1146, 880, 1186, .{ 1.0, 0.3, 0.2, 0.5 });
    hud.printWorld(810, 1150, "LAVA", .{});
    hud.printWorld(1160, 1084, "GLASS TANK", .{});
    hud.printWorld(1054, 1144, "WITCH", .{});
    hud.printWorld(902, 1040, "SMOKE", .{});
}

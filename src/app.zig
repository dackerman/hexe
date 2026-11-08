//! Windowed app, fixed 60 Hz ticks rendered at vsync:
//!   - play (default): the witch, her tools and the enemies (src/game/,
//!     keys in docs/07-tech-demo.md "Controls", decision 127);
//!   - sandbox (`--sandbox`, `--world`): mouse painting, pan, HUD, below.
//!
//! Input mapping (docs/decisions/07-input-mapping.md):
//!   left mouse     paint the selected material    right mouse   erase (air)
//!   1-9            select a palette material        wheel         brush radius
//!   0              ignite brush (sets fire)
//!   WASD / arrows  pan                             middle drag   pan
//!   = / -          zoom in / out (integer)         space         pause
//!   .              single tick while paused        F1            toggle HUD
//!   F2             activity tile overlay           F12           screenshot
//!   F5             save (--world --save DIR)       Esc           quit
//!   E              explosion at the cursor (air, bodies, connectivity: game/explode.zig)
//!   Q (hold)       spray sand particles at cursor  R (hold)      spray water particles
//!   X              eject (cells fly as particles) at the cursor, brush radius
//!   Tab / shift    cycle debug overlays            T             cursor torch
//!   F3             air pressure overlay on/off     F4            lighting mode (cascades, simple, off)
//!   F6             probe spacing 1/2/4 (quality)   F7 bloom      F8 vignette
//! Bodies (M7, docs/decisions/99-bodies-gpu-sandbox-keys.md):
//!   C  concrete crate at the cursor     Z  wood crate at the cursor
//!   V  stone slab at the cursor         B  steel beam: then click both ends
//!   (right mouse, the eject tool, cuts bodies and makes loose terrain fall)
//! Key reconciliation of the merged branches: docs/decisions/114-integrate-keys.md.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("sdl");
const Cli = @import("main.zig").Cli;
const Engine = @import("engine.zig").Engine;
const Window = @import("platform/window.zig").Window;
const Input = @import("platform/window.zig").Input;
const View = @import("render/world.zig").View;
const cell = @import("sim/cell.zig");
const commands = @import("sim/commands.zig");
const materials = @import("sim/materials.zig");
const data = @import("data");
const overlay = @import("render/overlay.zig");
const demo = @import("render/demo.zig");
const renderer_mod = @import("render/renderer.zig");
const max_ticks_per_frame = @import("sim/pipeline.zig").max_ticks_per_frame;
const Profile = @import("profile.zig").Profile;
const game_explode = @import("game/explode.zig");
const world_mode = @import("world_mode.zig");
const scenes = @import("sim/scenes.zig");
const game_mod = @import("game/game.zig");

const tick_ns: i96 = std.time.ns_per_s / 60;

/// Brush materials on keys 1-9, by name (missing ones are skipped).
pub const palette = [_][]const u8{ "sand", "water", "stone", "lava", "wood", "oil", "flame", "steel", "gunpowder" };
/// Ticks between polls of the materials directory.
const reload_poll_ticks = 30;
/// How long the reload message stays in the HUD.
const reload_message_ticks = 300;

/// Windowed entry: the playable demo, or the sandbox with `--sandbox` and
/// in the streamed world (`--world`).
pub fn run(gpa: std.mem.Allocator, io: std.Io, cli: Cli, lib: *materials.Library) !u8 {
    if (cli.world or cli.sandbox) return runSandbox(gpa, io, cli, lib);
    return runPlay(gpa, io, cli, lib);
}

/// The sandbox: paint, pan, explode; no witch.
fn runSandbox(gpa: std.mem.Allocator, io: std.Io, cli: Cli, lib: *materials.Library) !u8 {
    var window = try Window.init("hexe", cli.width, cli.height);
    defer window.deinit();
    const bodies_on = cli.bodies orelse true;
    const engine = try gpa.create(Engine);
    defer gpa.destroy(engine);
    try engine.init(gpa, .{
        .window = &window,
        .vsync = cli.vsync,
        .library = lib,
        .validation = cli.validation orelse (builtin.mode == .debug),
        // The sandbox starts with the liquid solver on (L toggles it).
        .pipeline = .{ .sleep = cli.sleep, .noise = cli.scene == .noise, .air = cli.air, .air_sleep = cli.air_sleep, .bodies = bodies_on, .liquid = true, .liquid_params = cli.liquid_params },
        .overlap = cli.overlap,
    });
    defer engine.deinit();
    var profile: Profile = .{};
    engine.profile = &profile;
    var tools: BodyTools = .{};
    var explosions: game_explode.Explosions = .{};
    @import("main.zig").applyRenderCli(&engine.renderer.settings, cli);
    const rs = &engine.renderer.settings;
    var torch = true;
    var frame_ms_sum: f64 = 0;
    var frame_ms_count: u64 = 0;

    // World mode (--world): streamed endless world, camera in world cells.
    var session: ?*world_mode.Session = null;
    defer if (session) |s| {
        if (s.save_path != null) _ = s.save() catch |err| std.log.err("save: {s}", .{@errorName(err)});
        s.deinit();
        gpa.destroy(s);
    };
    if (cli.world) {
        const s = try gpa.create(world_mode.Session);
        errdefer gpa.destroy(s);
        try s.init(gpa, io, engine, lib, .{ .seed = cli.seed, .save_dir = cli.save_dir, .ops_per_tick = cli.stream_ops }, cli.center);
        session = s;
    }
    const scene = if (cli.world) .empty else cli.scene;

    const win_w, const win_h = window.pixelSize();
    var view: View = .{ .scale = cli.zoom };
    const scene_center: [2]i32 = if (cli.scene == .lighting) @import("sim/scenes.zig").lighting_center else .{ cell.world_size / 2, cell.world_size / 2 };
    const start = if (session) |s| (cli.center orelse s.spawn()) else (cli.center orelse scene_center);
    view.camera_x = start[0] - @as(i32, @intCast(win_w / 2 / view.scale));
    view.camera_y = start[1] - @as(i32, @intCast(win_h / 2 / view.scale));

    var material: u8 = lib.id("sand") orelse 1;
    var igniting = false;
    var radius: i32 = 8;
    var watcher: ?data.reload.Watcher = data.reload.Watcher.init(io, cli.materials) catch null;
    var reload_diag: materials.Diagnostics = .init(gpa);
    defer reload_diag.deinit();
    var reload_msg_buf: [96]u8 = undefined;
    var reload_msg: []const u8 = "";
    var reload_msg_tick: u32 = 0;
    var last_poll: u32 = 0;
    var paused = false;
    var show_hud = true;
    var pending: commands.CommandList = .{};
    pending.begin(0);
    var last_paint: ?[2]i32 = null;
    var accumulator: i96 = 0;
    var prev = std.Io.Timestamp.now(io, .awake);
    var frame_ms: f64 = 16.7;
    var pan_frac: [2]f32 = .{ 0, 0 };
    const run_start = prev;
    var frames: u64 = 0;

    while (true) {
        try engine.poll(); // newest readback before building this frame's commands
        const input = window.poll();
        if (input.quit or input.wasPressed(c.SDL_SCANCODE_ESCAPE)) break;

        const now = std.Io.Timestamp.now(io, .awake);
        const dt = prev.durationTo(now).nanoseconds;
        prev = now;
        frame_ms = frame_ms * 0.9 + @as(f64, @floatFromInt(dt)) / 1e6 * 0.1;
        accumulator = @min(accumulator + dt, tick_ns * max_ticks_per_frame);
        var ticks: u32 = @intCast(@divTrunc(accumulator, tick_ns));
        accumulator -= tick_ns * ticks;
        if (paused) ticks = 0;
        if (input.wasPressed(c.SDL_SCANCODE_SPACE)) paused = !paused;
        if (paused and input.wasPressed(c.SDL_SCANCODE_PERIOD)) ticks = 1;
        if (input.wasPressed(c.SDL_SCANCODE_F1)) show_hud = !show_hud;
        if (input.wasPressed(c.SDL_SCANCODE_F2)) rs.overlay = if (rs.overlay == .tiles) .none else .tiles;
        if (input.wasPressed(c.SDL_SCANCODE_F3)) rs.overlay = if (rs.overlay == .air_pressure) .none else .air_pressure;
        if (input.wasPressed(c.SDL_SCANCODE_TAB)) {
            const back = input.isDown(c.SDL_SCANCODE_LSHIFT) or input.isDown(c.SDL_SCANCODE_RSHIFT);
            rs.overlay = if (back) overlay.prev(rs.overlay) else overlay.next(rs.overlay);
        }
        if (input.wasPressed(c.SDL_SCANCODE_F4)) rs.light_mode = @fromBackingInt(@intCast((@backingInt(rs.light_mode) + 1) % 3));
        if (input.wasPressed(c.SDL_SCANCODE_F6)) rs.probe_spacing = if (rs.probe_spacing >= 4) 1 else rs.probe_spacing * 2;
        if (input.wasPressed(c.SDL_SCANCODE_F7)) rs.bloom = !rs.bloom;
        if (input.wasPressed(c.SDL_SCANCODE_F8)) rs.vignette = !rs.vignette;
        if (input.wasPressed(c.SDL_SCANCODE_T)) torch = !torch;
        // ---- liquid solver (M6) ----
        if (input.wasPressed(c.SDL_SCANCODE_L)) engine.pipeline.config.liquid = !engine.pipeline.config.liquid;
        // ---- end liquid solver ----

        // Material selection: number keys pick from the palette, 0 ignites.
        for (palette, 0..) |name, k| {
            if (input.wasPressed(c.SDL_SCANCODE_1 + @as(c_int, @intCast(k)))) {
                if (lib.id(name)) |id| {
                    material = id;
                    igniting = false;
                }
            }
        }
        if (input.wasPressed(c.SDL_SCANCODE_0)) igniting = true;

        // Hot reload: poll the materials directory every few ticks.
        if (watcher != null and engine.tick -% last_poll >= reload_poll_ticks) {
            last_poll = engine.tick;
            reload_diag.clear();
            if (watcher.?.poll(io, gpa, &lib.set, &reload_diag)) |maybe| {
                if (maybe) |r| {
                    var fresh = r;
                    const fresh_lib: materials.Library = .{ .set = fresh.set, .tables = fresh.tables };
                    if (engine.reloadTables(&fresh_lib)) |_| {
                        lib.deinit(gpa);
                        lib.* = fresh_lib;
                        engine.tables = lib.tables;
                        reload_msg = std.fmt.bufPrint(&reload_msg_buf, "materials reloaded{s}", .{if (fresh.ids_changed) " (ids changed: existing cells may be wrong)" else ""}) catch "materials reloaded";
                        if (lib.set.get(material) == null) material = lib.id("sand") orelse 1;
                    } else |err| {
                        fresh.deinit(gpa);
                        reload_msg = std.fmt.bufPrint(&reload_msg_buf, "materials reload failed: {s}", .{@errorName(err)}) catch "materials reload failed";
                    }
                    reload_msg_tick = engine.tick;
                }
            } else |err| {
                const first = if (reload_diag.messages.items.len > 0) reload_diag.messages.items[0] else @errorName(err);
                reload_msg = std.fmt.bufPrint(&reload_msg_buf, "materials not reloaded: {s}", .{first}) catch "materials not reloaded";
                reload_msg_tick = engine.tick;
                std.log.err("materials reload: {f}", .{reload_diag});
            }
        }
        // Brush radius on the wheel.
        if (input.wheel != 0) radius = std.math.clamp(radius + (if (input.wheel > 0) @as(i32, 1) else -1) * @max(1, @divTrunc(radius, 4)), 1, 200);

        // Zoom around the cursor.
        var zoom: i32 = 0;
        if (input.wasPressed(c.SDL_SCANCODE_EQUALS) or input.wasPressed(c.SDL_SCANCODE_KP_PLUS)) zoom = 1;
        if (input.wasPressed(c.SDL_SCANCODE_MINUS) or input.wasPressed(c.SDL_SCANCODE_KP_MINUS)) zoom = -1;
        if (zoom != 0) {
            const new_scale: u32 = @intCast(std.math.clamp(@as(i32, @intCast(view.scale)) + zoom, 1, 16));
            const mx: i32 = @intFromFloat(input.mouse_x);
            const my: i32 = @intFromFloat(input.mouse_y);
            const wx = view.camera_x + @divFloor(mx, @as(i32, @intCast(view.scale)));
            const wy = view.camera_y + @divFloor(my, @as(i32, @intCast(view.scale)));
            view.scale = new_scale;
            view.camera_x = wx - @divFloor(mx, @as(i32, @intCast(new_scale)));
            view.camera_y = wy - @divFloor(my, @as(i32, @intCast(new_scale)));
        }

        // Pan: keys (screen pixels per second) and middle drag.
        const speed: f32 = 900.0 * @as(f32, @floatFromInt(dt)) / 1e9 / @as(f32, @floatFromInt(view.scale));
        var pan: [2]f32 = .{ 0, 0 };
        if (input.isDown(c.SDL_SCANCODE_A) or input.isDown(c.SDL_SCANCODE_LEFT)) pan[0] -= speed;
        if (input.isDown(c.SDL_SCANCODE_D) or input.isDown(c.SDL_SCANCODE_RIGHT)) pan[0] += speed;
        if (input.isDown(c.SDL_SCANCODE_W) or input.isDown(c.SDL_SCANCODE_UP)) pan[1] -= speed;
        if (input.isDown(c.SDL_SCANCODE_S) or input.isDown(c.SDL_SCANCODE_DOWN)) pan[1] += speed;
        if (input.middle) {
            pan[0] -= input.mouse_dx / @as(f32, @floatFromInt(view.scale));
            pan[1] -= input.mouse_dy / @as(f32, @floatFromInt(view.scale));
        }
        for (0..2) |k| {
            pan_frac[k] += pan[k];
            const whole = @trunc(pan_frac[k]);
            pan_frac[k] -= whole;
            if (k == 0) view.camera_x += @intFromFloat(whole) else view.camera_y += @intFromFloat(whole);
        }
        if (session == null) {
            view.camera_x = @mod(view.camera_x, cell.world_size);
            view.camera_y = @mod(view.camera_y, cell.world_size);
        }

        // Painting: circles along the cursor path since last frame.
        const scale: i32 = @intCast(view.scale);
        const mwx = view.camera_x + @divFloor(@as(i32, @intFromFloat(input.mouse_x)), scale);
        const mwy = view.camera_y + @divFloor(@as(i32, @intFromFloat(input.mouse_y)), scale);
        // Body tools (M7); while placing a beam, left clicks pick its ends.
        if (bodies_on) tools.update(engine, input, .{ @floatFromInt(mwx), @floatFromInt(mwy) }, .{
            @floatFromInt(view.camera_x + @as(i32, @intCast(win_w / 2 / view.scale))),
            @floatFromInt(view.camera_y + @as(i32, @intCast(win_h / 2 / view.scale))),
        });
        if ((input.left and !tools.placing_beam and !tools.consumed_click) or input.right) {
            const paint: u8 = if (input.right) materials.air else material;
            const from = last_paint orelse [2]i32{ mwx, mwy };
            strokeLine(&pending, from, .{ mwx, mwy }, radius, paint, input.left and igniting);
            last_paint = .{ mwx, mwy };
        } else last_paint = null;
        // Explosions: E at the cursor (brush radius), and every gunpowder
        // ignition the GPU reported (EVENT_EXPLODE, one tick late).
        const blast_opts: game_explode.Options = .{ .air = engine.pipeline.config.air, .liquid = engine.pipeline.config.liquid };
        if (input.wasPressed(c.SDL_SCANCODE_E)) game_explode.explode(&pending, mwx, mwy, @max(radius, 4), 1.0, blast_opts);
        _ = explosions.drain(engine.mirror(), &pending, blast_opts);

        // Particle tools (M4): sprays and the interim explosion.
        if (input.isDown(c.SDL_SCANCODE_Q) or input.isDown(c.SDL_SCANCODE_R)) {
            const mat = if (input.isDown(c.SDL_SCANCODE_Q)) engine.ids.sand else engine.ids.water;
            pending.spray(.{ .x = mwx, .y = mwy, .material = mat, .count = 48, .speed = 260, .spread = 90, .direction = 0.75, .cone = 0.08 });
        }
        if (input.wasPressed(c.SDL_SCANCODE_X)) pending.eject(mwx, mwy, @max(radius, 4), 1000);
        // Pour: water at the cursor every frame the key is held, woken at
        // once so it falls as particles (not as cellular water).
        if (input.isDown(c.SDL_SCANCODE_P)) {
            const r = @max(@divTrunc(radius, 2), 2);
            pending.fillCircle(mwx, mwy, r, engine.ids.water, .{ .only_air = true });
            pending.wakeLiquid(mwx, mwy, r + 1, 1);
        }

        if (input.wasPressed(c.SDL_SCANCODE_F12)) {
            var name_buf: [64]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "hexe-{d}.png", .{engine.tick});
            engine.screenshot(io, name, null) catch |err| std.log.err("screenshot: {s}", .{@errorName(err)});
        }
        if (session) |s| if (input.wasPressed(c.SDL_SCANCODE_F5)) {
            _ = s.save() catch |err| std.log.err("save: {s}", .{@errorName(err)});
        };

        // Render decorations: scene lights/sprites/signs and the cursor torch.
        engine.hud.clear();
        demo.decorate(cli.scene, engine.tick, &engine.renderer, &engine.hud);
        if (torch) engine.renderer.addLight(@as(f32, @floatFromInt(mwx)) + 0.5, @as(f32, @floatFromInt(mwy)) + 0.5, 70, .{ 1.0, 0.8, 0.55 });

        if (show_hud) fillHud(engine, &profile, .{
            .frame_ms = frame_ms,
            .paused = paused,
            .material = if (igniting) "ignite" else lib.name(material),
            .radius = radius,
            .view = view,
            .cursor = if (session != null) .{ mwx, mwy } else .{ @mod(mwx, cell.world_size), @mod(mwy, cell.world_size) },
            .material_count = palette.len,
            .world = session,
            .message = if (reload_msg.len > 0 and engine.tick -% reload_msg_tick < reload_message_ticks) reload_msg else "",
            .extent = .{ win_w, win_h },
        });
        if (show_hud and bodies_on) tools.hud(engine, &profile);

        // Streaming runs once per tick, before the ticks are recorded.
        if (session) |s| {
            const ww, const wh = window.pixelSize();
            const cam = [2]i32{
                view.camera_x + @as(i32, @intCast(ww / 2 / view.scale)),
                view.camera_y + @as(i32, @intCast(wh / 2 / view.scale)),
            };
            for (0..ticks) |_| try s.tick(cam);
        }

        const src: @import("engine.zig").TickSource = .{
            .scene = scene,
            .seed = cli.seed,
            .extra = if (ticks > 0) pending.slice() else &.{},
        };
        try engine.frame(ticks, src, view);
        if (ticks > 0) pending.begin(engine.tick);
        frames += 1;
        if (frames > 60) {
            frame_ms_sum += @as(f64, @floatFromInt(dt)) / 1e6;
            frame_ms_count += 1;
        }
        if (cli.frames > 0 and frames >= cli.frames) break;
    }
    try engine.finish();
    if (session) |s| s.report();
    const secs = @as(f64, @floatFromInt(run_start.untilNow(io, .awake).nanoseconds)) / 1e9;
    std.log.info("{d} frames in {d:.2} s ({d:.1} fps), {d} ticks ({d:.1}/s), grid {d:.3} ms, mean frame {d:.3} ms after warm-up, overlap {s}", .{
        frames,                                                          secs,                             @as(f64, @floatFromInt(frames)) / secs, engine.tick, @as(f64, @floatFromInt(engine.tick)) / secs, profile.gridSmooth(&engine.names),
        frame_ms_sum / @as(f64, @floatFromInt(@max(frame_ms_count, 1))), if (cli.overlap) "on" else "off",
    });
    return 0;
}

// ---------------------------------------------------------------- play mode

/// The playable mode's scene: the Proving Grounds tech-demo level
/// (docs/07-tech-demo.md, src/game/level.zig).
pub const default_scene: scenes.Scene = .proving_grounds;
const level = @import("game/level.zig");

/// Where the witch starts in a scene (feet position).
pub fn defaultSpawn(scene: scenes.Scene) [2]f32 {
    return switch (scene) {
        .proving_grounds, .proving_grounds_auto, .proving_grounds_burst => .{ @floatFromInt(level.spawn_point[0]), @floatFromInt(level.spawn_point[1]) },
        // On the cave floor between the pillars and the glass tank.
        .lighting => .{ 1060, 1180 },
        // On the stone ground between the lava basin and the hut.
        .fire_demo => .{ 1024 - 60, 1024 + 120 },
        // A standing spot in the sandbox's left half.
        .sandbox => .{ 300, 300 },
        else => .{ cell.world_size / 2, cell.world_size / 2 },
    };
}

/// The scene's enemies (the level module takes this over).
pub fn populate(g: *game_mod.Game, scene: scenes.Scene) void {
    switch (scene) {
        .proving_grounds, .proving_grounds_auto, .proving_grounds_burst => {
            for (level.enemy_spawns) |e| {
                const kind: game_mod.enemies_mod.Kind = switch (e.kind) {
                    .walker => .walker,
                    .flyer => .flyer,
                };
                _ = g.enemies.spawn(kind, @floatFromInt(e.x), @floatFromInt(e.y));
            }
        },
        .lighting => {
            _ = g.enemies.spawn(.walker, 1245, 1180);
            _ = g.enemies.spawn(.flyer, 860, 1010);
        },
        else => {},
    }
}

/// Camera smoothing rate (1/s) and the share of the cursor's offset from
/// the window center the camera leads by.
const camera_rate: f32 = 7;
const camera_lead: f32 = 0.3;

fn runPlay(gpa: std.mem.Allocator, io: std.Io, cli_in: Cli, lib: *materials.Library) !u8 {
    var cli = cli_in;
    if (!cli.scene_set) cli.scene = default_scene;
    const scene = cli.scene;
    var window = try Window.init("hexe", cli.width, cli.height);
    defer window.deinit();
    const opts: @import("engine.zig").Options = .{
        .window = &window,
        .vsync = cli.vsync,
        .library = lib,
        .validation = cli.validation orelse (builtin.mode == .debug),
        .pipeline = .{ .sleep = cli.sleep, .air = cli.air, .air_sleep = cli.air_sleep, .bodies = cli.bodies orelse true, .liquid = true, .liquid_params = cli.liquid_params },
        .overlap = cli.overlap,
    };
    const engine = try gpa.create(Engine);
    defer gpa.destroy(engine);
    try engine.init(gpa, opts);
    defer engine.deinit();
    var profile: Profile = .{};
    engine.profile = &profile;
    @import("main.zig").applyRenderCli(&engine.renderer.settings, cli);
    const rs = &engine.renderer.settings;

    const spawn = cli.spawn orelse defaultSpawn(scene);
    const game = try gpa.create(game_mod.Game);
    defer gpa.destroy(game);
    try game.init(engine, lib, spawn);
    populate(game, scene);
    game.debug_spawn = cli.spawn_enemies;

    const win_w, const win_h = window.pixelSize();
    var view: View = .{ .scale = if (cli.zoom_set) cli.zoom else 3 };
    var cam = [2]f32{ spawn[0], spawn[1] - 20 };
    var input: game_mod.Input = .{ .aim = spawn };
    var pending: commands.CommandList = .{};
    pending.begin(0);
    var paused = false;
    var show_help = false;
    var show_timings = false;
    var accumulator: i96 = 0;
    var prev = std.Io.Timestamp.now(io, .awake);
    var frame_ms: f64 = 16.7;
    var frame_ms_sum: f64 = 0;
    var frame_ms_count: u64 = 0;
    const run_start = prev;
    var frames: u64 = 0;
    var resets: u32 = 0;

    while (true) {
        try engine.poll();
        const sdl = window.poll();
        if (sdl.quit or sdl.wasPressed(c.SDL_SCANCODE_ESCAPE)) break;
        const now = std.Io.Timestamp.now(io, .awake);
        const dt = prev.durationTo(now).nanoseconds;
        prev = now;
        const dt_s: f32 = @floatCast(@as(f64, @floatFromInt(dt)) / 1e9);
        frame_ms = frame_ms * 0.9 + @as(f64, @floatFromInt(dt)) / 1e6 * 0.1;
        accumulator = @min(accumulator + dt, tick_ns * max_ticks_per_frame);
        var ticks: u32 = @intCast(@divTrunc(accumulator, tick_ns));
        accumulator -= tick_ns * ticks;

        // ---- system keys ----
        if (sdl.wasPressed(c.SDL_SCANCODE_P)) paused = !paused;
        if (paused) ticks = 0;
        if (paused and sdl.wasPressed(c.SDL_SCANCODE_PERIOD)) ticks = 1;
        if (sdl.wasPressed(c.SDL_SCANCODE_F1)) show_help = !show_help;
        if (sdl.wasPressed(c.SDL_SCANCODE_F3)) show_timings = !show_timings;
        if (sdl.wasPressed(c.SDL_SCANCODE_F2)) rs.overlay = if (rs.overlay == .tiles) .none else .tiles;
        if (sdl.wasPressed(c.SDL_SCANCODE_TAB)) {
            const back = sdl.isDown(c.SDL_SCANCODE_LSHIFT) or sdl.isDown(c.SDL_SCANCODE_RSHIFT);
            rs.overlay = if (back) overlay.prev(rs.overlay) else overlay.next(rs.overlay);
        }
        if (sdl.wasPressed(c.SDL_SCANCODE_F4)) rs.light_mode = @fromBackingInt(@intCast((@backingInt(rs.light_mode) + 1) % 3));
        if (sdl.wasPressed(c.SDL_SCANCODE_F6)) rs.probe_spacing = if (rs.probe_spacing >= 4) 1 else rs.probe_spacing * 2;
        if (sdl.wasPressed(c.SDL_SCANCODE_F7)) rs.bloom = !rs.bloom;
        if (sdl.wasPressed(c.SDL_SCANCODE_F8)) rs.vignette = !rs.vignette;
        if (sdl.wasPressed(c.SDL_SCANCODE_L)) engine.pipeline.config.liquid = !engine.pipeline.config.liquid;
        var zoom: i32 = 0;
        if (sdl.wasPressed(c.SDL_SCANCODE_EQUALS) or sdl.wasPressed(c.SDL_SCANCODE_KP_PLUS)) zoom = 1;
        if (sdl.wasPressed(c.SDL_SCANCODE_MINUS) or sdl.wasPressed(c.SDL_SCANCODE_KP_MINUS)) zoom = -1;
        if (zoom != 0) view.scale = @intCast(std.math.clamp(@as(i32, @intCast(view.scale)) + zoom, 1, 8));
        if (sdl.wasPressed(c.SDL_SCANCODE_F12)) {
            var name_buf: [64]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "hexe-{d}.png", .{engine.tick});
            engine.screenshot(io, name, null) catch |err| std.log.err("screenshot: {s}", .{@errorName(err)});
        }
        // R: the level starts over from a fresh engine (cells, air, liquid,
        // bodies, particles all reset; decision 129).
        if (sdl.wasPressed(c.SDL_SCANCODE_R) or (cli.reset_at > 0 and frames == cli.reset_at and resets == 0)) {
            const saved = engine.renderer.settings;
            const liquid_on = engine.pipeline.config.liquid;
            try engine.finish();
            engine.deinit();
            try engine.init(gpa, opts);
            engine.profile = &profile;
            engine.renderer.settings = saved;
            engine.pipeline.config.liquid = liquid_on;
            try game.rebind(engine);
            game.reset(spawn);
            populate(game, scene);
            game.debug_spawn = cli.spawn_enemies;
            pending.begin(0);
            cam = .{ spawn[0], spawn[1] - 20 };
            resets += 1;
            frames += 1;
            prev = std.Io.Timestamp.now(io, .awake);
            accumulator = 0;
            std.log.info("level reset ({d})", .{resets});
            continue;
        }

        // ---- gameplay input ----
        const scale: f32 = @floatFromInt(view.scale);
        input.left = sdl.isDown(c.SDL_SCANCODE_A) or sdl.isDown(c.SDL_SCANCODE_LEFT);
        input.right = sdl.isDown(c.SDL_SCANCODE_D) or sdl.isDown(c.SDL_SCANCODE_RIGHT);
        input.up = sdl.isDown(c.SDL_SCANCODE_W) or sdl.isDown(c.SDL_SCANCODE_UP);
        input.setButtons(
            sdl.isDown(c.SDL_SCANCODE_SPACE) or sdl.isDown(c.SDL_SCANCODE_W) or sdl.isDown(c.SDL_SCANCODE_UP),
            sdl.isDown(c.SDL_SCANCODE_S) or sdl.isDown(c.SDL_SCANCODE_DOWN),
            sdl.left,
            sdl.right,
        );
        for (0..10) |k| {
            if (sdl.wasPressed(c.SDL_SCANCODE_1 + @as(c_int, @intCast(k)))) input.select = @intCast(k);
        }
        if (sdl.wheel != 0) input.wheel += if (sdl.wheel > 0) 1 else -1;
        const aim = [2]f32{
            @as(f32, @floatFromInt(view.camera_x)) + sdl.mouse_x / scale,
            @as(f32, @floatFromInt(view.camera_y)) + sdl.mouse_y / scale,
        };
        input.aim = aim;
        const iax: i32 = @intFromFloat(@floor(aim[0]));
        const iay: i32 = @intFromFloat(@floor(aim[1]));
        // Sandbox keys kept in play: explosion, eject, bodies.
        if (sdl.wasPressed(c.SDL_SCANCODE_E)) {
            game_explode.explode(&pending, iax, iay, 10, 1.0, .{ .air = engine.pipeline.config.air, .liquid = engine.pipeline.config.liquid });
            game.blasts.add(.{ .x = aim[0], .y = aim[1], .radius = 10, .strength = 1 });
        }
        if (sdl.wasPressed(c.SDL_SCANCODE_X)) pending.eject(iax, iay, 10, 1000);
        {
            const sim = engine.pipeline.bodies.sim;
            const roles = sim.mats.roles;
            if (sdl.wasPressed(c.SDL_SCANCODE_C)) _ = sim.spawnCrate(aim[0], aim[1], 40, roles.concrete) catch {};
            if (sdl.wasPressed(c.SDL_SCANCODE_Z)) _ = sim.spawnCrate(aim[0], aim[1], 30, roles.wood) catch {};
            if (sdl.wasPressed(c.SDL_SCANCODE_V)) _ = sim.dropSlab(aim[0], aim[1], 120, 12, roles.stone) catch {};
        }

        // ---- simulate ----
        if (ticks > 0) game.requestReadback();
        for (0..ticks) |_| {
            game.tick(&input, &pending);
            input.consumeEdges();
        }

        // ---- camera: follow the witch, lead toward the cursor ----
        const vw = @as(f32, @floatFromInt(win_w)) / scale;
        const vh = @as(f32, @floatFromInt(win_h)) / scale;
        const lead = [2]f32{
            std.math.clamp((sdl.mouse_x - @as(f32, @floatFromInt(win_w)) * 0.5) / scale * camera_lead, -vw * 0.25, vw * 0.25),
            std.math.clamp((sdl.mouse_y - @as(f32, @floatFromInt(win_h)) * 0.5) / scale * camera_lead, -vh * 0.25, vh * 0.25),
        };
        const target = [2]f32{ game.player.actor.cx() + lead[0], game.player.actor.cy() - 16 + lead[1] };
        const k = 1 - @exp(-camera_rate * @min(dt_s, 0.1));
        cam[0] += (target[0] - cam[0]) * k;
        cam[1] += (target[1] - cam[1]) * k;
        view.camera_x = @intFromFloat(@round(cam[0] - vw * 0.5));
        view.camera_y = @intFromFloat(@round(cam[1] - vh * 0.5));
        input.aim = .{
            @as(f32, @floatFromInt(view.camera_x)) + sdl.mouse_x / scale,
            @as(f32, @floatFromInt(view.camera_y)) + sdl.mouse_y / scale,
        };

        // ---- draw ----
        engine.hud.clear();
        // Level decorations: torches and the floating zone signs.
        demo.decorate(scene, engine.tick, &engine.renderer, &engine.hud);
        game.draw(view, .{ win_w, win_h }, &input);
        if (show_help) game_mod.Game.helpLines(&engine.hud) else {
            game.hudLines(&engine.hud);
            if (paused) engine.hud.print("[paused]  P resume  . single step", .{});
        }
        if (show_timings) fillHud(engine, &profile, .{
            .frame_ms = frame_ms,
            .paused = paused,
            .material = game.tools.info().name,
            .radius = game.tools.brush,
            .view = view,
            .cursor = .{ iax, iay },
            .extent = .{ win_w, win_h },
            .play = true,
        });

        const src: @import("engine.zig").TickSource = .{
            .scene = scene,
            .seed = cli.seed,
            .extra = if (ticks > 0) pending.slice() else &.{},
        };
        try engine.frame(ticks, src, view);
        if (ticks > 0) pending.begin(engine.tick);
        frames += 1;
        if (frames > 60) {
            frame_ms_sum += @as(f64, @floatFromInt(dt)) / 1e6;
            frame_ms_count += 1;
        }
        if (cli.frames > 0 and frames >= cli.frames) break;
    }
    try engine.finish();
    const secs = @as(f64, @floatFromInt(run_start.untilNow(io, .awake).nanoseconds)) / 1e9;
    const pa = &game.player.actor;
    std.log.info("play: {d} frames in {d:.2} s ({d:.1} fps), {d} ticks ({d:.1}/s), mean frame {d:.3} ms after warm-up, grid {d:.3} ms; witch at {d:.0},{d:.0} hp {d:.0}, {d} enemies, {d} kills, {d} resets", .{
        frames,                                                          secs,                              @as(f64, @floatFromInt(frames)) / secs, engine.tick, @as(f64, @floatFromInt(engine.tick)) / secs,
        frame_ms_sum / @as(f64, @floatFromInt(@max(frame_ms_count, 1))), profile.gridSmooth(&engine.names), pa.cx(),                                pa.cy(),     pa.health,
        game.enemies.len,                                                game.enemies.kills,                resets,
    });
    return 0;
}

pub const HudInfo = struct {
    frame_ms: f64,
    paused: bool = false,
    material: []const u8 = "",
    radius: i32 = 0,
    view: View = .{},
    cursor: [2]i32 = .{ 0, 0 },
    material_count: u32 = 0,
    /// World mode: streaming lines.
    world: ?*const world_mode.Session = null,
    /// Extra status line (hot reload result).
    message: []const u8 = "",
    /// Window size in pixels (for the light plan shown in the HUD).
    extent: [2]u32 = .{ 1920, 1080 },
    /// Play mode: leave out the sandbox key hints.
    play: bool = false,
};

/// The HUD text: frame time, grid time, per-pass GPU ms, tool state.
pub fn fillHud(engine: *Engine, profile: *const Profile, info: HudInfo) void {
    const hud = &engine.hud;
    const names = &engine.names;
    hud.print("hexe  frame {d:5.2} ms  tick {d}{s}", .{ info.frame_ms, engine.tick, if (info.paused) "  [paused]" else "" });
    hud.print("grid {d:6.3} ms  active tiles {d}/{d}", .{ profile.gridSmooth(names), engine.last.active_tiles, cell.tile_count });
    var line: [160]u8 = undefined;
    var w: std.Io.Writer = .fixed(&line);
    w.writeAll("gpu ms") catch {};
    for (0..names.count) |i| w.print("  {s} {d:.3}", .{ names.get(i), profile.smooth[i] }) catch {};
    hud.print("{s}", .{w.buffered()});
    // Render timings (also in the line above) and lighting state.
    const r = &engine.renderer;
    const plan = r.plan(info.view, .{ .width = info.extent[0], .height = info.extent[1] });
    var rl: [160]u8 = undefined;
    var rw: std.Io.Writer = .fixed(&rl);
    var total: f64 = 0;
    for (render_passes) |rp| {
        for (0..names.count) |i| {
            if (std.mem.eql(u8, names.get(i), rp)) {
                rw.print(" {s} {d:.3}", .{ rp, profile.smooth[i] }) catch {};
                total += profile.smooth[i];
            }
        }
    }
    if (total > 0) hud.print("render {d:.3} ms:{s}", .{ total, rw.buffered() }) else hud.print("render ms: not timed (capture)", .{});
    hud.print("light {s}  spacing {d}px  cascades {d}  region {d}x{d}  lights {d}  bloom {s}  vignette {s}", .{
        @tagName(r.settings.light_mode), plan.spacing, plan.count, plan.size[0], plan.size[1], r.light_count, if (r.settings.bloom) "on" else "off", if (r.settings.vignette) "on" else "off",
    });
    const ov = overlay.info(r.settings.overlay);
    hud.print("overlay [Tab] {s}{s}{s}", .{ ov.name, if (ov.legend.len > 0) ": " else "", ov.legend });
    const ps = engine.mirror().particles;
    hud.print("particles {d} live (cap {d})  spawned {d} landed {d} refused {d} lost {d} impacts {d}", .{ ps.live, ps.capacity, ps.spawned, ps.landed, ps.refused, ps.lost, ps.impacts });
    hud.print("brush {s} r{d}  zoom {d}x  cam {d},{d}  cursor {d},{d}", .{ info.material, info.radius, info.view.scale, info.view.camera_x, info.view.camera_y, info.cursor[0], info.cursor[1] });
    if (info.world) |s| s.hudLines(hud);
    if (!info.play) {
        hud.print("1-{d} material  0 ignite  LMB paint  RMB erase  wheel size  WASD pan  =/- zoom  space pause  Tab overlay  F2 tiles  F3 air", .{info.material_count});
        hud.print("E explosion  X eject  Q/R spray sand/water  T torch  F4 light  F6 quality  F7 bloom  F8 vignette", .{});
    }
    if (info.message.len > 0) hud.print("{s}", .{info.message});
    // ---- liquid solver (M6) ----
    const lq = &engine.pipeline.liquid;
    if (engine.pipeline.config.liquid) {
        const ls = lq.statsSettled();
        hud.print("liquid on ({s})  {d} awake, {d} ballistic  woke {d} slept {d}  {s}L off  Tab overlay", .{ @tagName(lq.mode), ls.alive, ls.ballistic, ls.spawned, ls.slept, if (info.play) "" else "P pour  " });
    } else {
        hud.print("liquid off (cellular water)  L on", .{});
    }
    // ---- end liquid solver ----
}

/// Sandbox keys for bodies: crates, slabs, two-click beams.
const BodyTools = struct {
    placing_beam: bool = false,
    beam_start: ?[2]f32 = null,
    prev_left: bool = false,
    /// The left button went down this frame for a body tool: do not paint
    /// until it is released.
    consumed_click: bool = false,

    fn update(self: *BodyTools, engine: *Engine, input: *const Input, cursor: [2]f32, center: [2]f32) void {
        const sim = engine.pipeline.bodies.sim;
        const roles = sim.mats.roles;
        // Keep bodies in the unwrapped frame around the camera (torus).
        sim.setCenter(center[0], center[1]);
        if (input.wasPressed(c.SDL_SCANCODE_C)) _ = sim.spawnCrate(cursor[0], cursor[1], 40, roles.concrete) catch {};
        if (input.wasPressed(c.SDL_SCANCODE_Z)) _ = sim.spawnCrate(cursor[0], cursor[1], 40, roles.wood) catch {};
        if (input.wasPressed(c.SDL_SCANCODE_V)) _ = sim.dropSlab(cursor[0], cursor[1], 160, 16, roles.stone) catch {};
        if (input.wasPressed(c.SDL_SCANCODE_B)) {
            self.placing_beam = !self.placing_beam;
            self.beam_start = null;
        }
        const clicked = input.left and !self.prev_left;
        self.prev_left = input.left;
        if (!input.left) self.consumed_click = false;
        if (self.placing_beam and clicked) {
            self.consumed_click = true;
            if (self.beam_start) |a| {
                sim.placeBeam(a[0], a[1], cursor[0], cursor[1], roles.steel, 6);
                self.placing_beam = false;
                self.beam_start = null;
            } else self.beam_start = cursor;
        }
    }

    fn hud(self: *const BodyTools, engine: *Engine, profile: *const Profile) void {
        const sim = engine.pipeline.bodies.sim;
        var gpu_ms: f64 = 0;
        for (0..engine.names.count) |i| {
            if (std.mem.eql(u8, engine.names.get(i), "bodies")) gpu_ms = profile.smooth[i];
        }
        engine.hud.print("bodies {d}  cpu {d:.2} ms  readback {d:.2} ms  gpu {d:.3} ms  C crate  Z wood  V slab  B beam{s}", .{
            sim.bodyCount(),
            sim.stats.cpu_ms,
            sim.stats.readback_ms,
            gpu_ms,
            if (self.placing_beam) (if (self.beam_start != null) "  [click the beam's end]" else "  [click the beam's start]") else "",
        });
    }
};

/// Passes summed into the HUD's render line.
const render_passes = [_][]const u8{ "light_build", "cascades", "merge", "world", "sprites", "post", "hud" };

/// Circles every radius/2 pixels from `a` to `b` (at least one).
fn strokeLine(list: *commands.CommandList, a: [2]i32, b: [2]i32, radius: i32, material: u8, ignite: bool) void {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len: i32 = @intFromFloat(@sqrt(@as(f32, @floatFromInt(dx * dx + dy * dy))));
    const step = @max(1, @divTrunc(radius, 2));
    const n = @min(@divTrunc(len, step) + 1, 64);
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        const x = a[0] + if (n > 1) @divTrunc(dx * i, n - 1) else 0;
        const y = a[1] + if (n > 1) @divTrunc(dy * i, n - 1) else 0;
        if (ignite) list.igniteCircle(x, y, radius) else list.fillCircle(x, y, radius, material, .{});
    }
}

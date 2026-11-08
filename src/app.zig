//! Windowed sandbox: fixed 60 Hz ticks, mouse painting, camera, HUD.
//!
//! Input mapping (docs/decisions/07-input-mapping.md):
//!   left mouse     paint the selected material    right mouse   erase (air)
//!   1-9            select material by id           wheel         brush radius
//!   WASD / arrows  pan                             middle drag   pan
//!   = / -          zoom in / out (integer)         space         pause
//!   .              single tick while paused        F1            toggle HUD
//!   F2             activity tile overlay           F12           screenshot
//!   F5             save (--world --save DIR)    Esc           quit
//!   F3             air field overlay (M5)          E             explosion at the cursor
//!   Q (hold)       spray sand particles at cursor  E (hold)      spray water particles
//!   X              eject (interim explosion) at the cursor, brush radius
//!   Esc            quit
//! Bodies (M7, docs/decisions/99-bodies-gpu-sandbox-keys.md):
//!   C  concrete crate at the cursor     X  wood crate at the cursor
//!   V  stone slab at the cursor         B  steel beam: then click both ends
//!   (right mouse, the eject tool, cuts bodies and makes loose terrain fall)
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
const materials_builtin = @import("sim/materials_builtin.zig");
const materials = @import("sim/materials.zig");
const max_ticks_per_frame = @import("sim/pipeline.zig").max_ticks_per_frame;
const Profile = @import("profile.zig").Profile;
const world_mode = @import("world_mode.zig");
const bodies_materials = @import("sim/bodies_materials.zig");

const tick_ns: i96 = std.time.ns_per_s / 60;

pub fn run(gpa: std.mem.Allocator, io: std.Io, cli: Cli) !u8 {
    var window = try Window.init("hexe", cli.width, cli.height);
    defer window.deinit();
    var table = materials_builtin.table();
    const bodies_on = cli.bodies orelse true;
    if (bodies_on) bodies_materials.ensureMaterials(&table);
    const engine = try gpa.create(Engine);
    defer gpa.destroy(engine);
    try engine.init(gpa, .{
        .window = &window,
        .vsync = cli.vsync,
        .table = &table,
        .validation = cli.validation orelse (builtin.mode == .debug),
        .pipeline = .{ .sleep = cli.sleep, .noise = cli.scene == .noise, .air = cli.air, .air_sleep = cli.air_sleep, .bodies = bodies_on },
    });
    defer engine.deinit();
    engine.pipeline.air.overlay = cli.overlay;
    var profile: Profile = .{};
    engine.profile = &profile;
    var tools: BodyTools = .{};

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
        try s.init(gpa, io, engine, &table, .{ .seed = cli.seed, .save_dir = cli.save_dir, .ops_per_tick = cli.stream_ops }, cli.center);
        session = s;
    }
    const scene = if (cli.world) .empty else cli.scene;

    const win_w, const win_h = window.pixelSize();
    var view: View = .{ .scale = 2, .show_overlay = cli.overlay };
    const start = if (session) |s| (cli.center orelse s.spawn()) else [2]i32{ cell.world_size / 2, cell.world_size / 2 };
    view.camera_x = start[0] - @as(i32, @intCast(win_w / 2 / view.scale));
    view.camera_y = start[1] - @as(i32, @intCast(win_h / 2 / view.scale));

    var material: u8 = materials_builtin.sand;
    var radius: i32 = 8;
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
        if (input.wasPressed(c.SDL_SCANCODE_F2)) view.show_tiles = !view.show_tiles;
        if (input.wasPressed(c.SDL_SCANCODE_F3)) {
            view.show_overlay = !view.show_overlay;
            engine.pipeline.air.overlay = view.show_overlay;
        }

        // Material selection: number keys pick ids 1-9.
        for (0..9) |k| {
            const id: u8 = @intCast(k + 1);
            if (input.wasPressed(c.SDL_SCANCODE_1 + @as(c_int, @intCast(k))) and id < table.len) material = id;
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
            strokeLine(&pending, from, .{ mwx, mwy }, radius, paint);
            last_paint = .{ mwx, mwy };
        } else last_paint = null;
        // Explosion (air field pressure injection) at the cursor, brush radius.
        if (input.wasPressed(c.SDL_SCANCODE_E)) pending.explosion(mwx, mwy, @max(radius, 4), 1.0);

        // Particle tools (M4): sprays and the interim explosion.
        if (input.isDown(c.SDL_SCANCODE_Q) or input.isDown(c.SDL_SCANCODE_E)) {
            const mat = if (input.isDown(c.SDL_SCANCODE_Q)) materials_builtin.sand else materials_builtin.water;
            pending.spray(.{ .x = mwx, .y = mwy, .material = mat, .count = 48, .speed = 260, .spread = 90, .direction = 0.75, .cone = 0.08 });
        }
        if (input.wasPressed(c.SDL_SCANCODE_X)) pending.eject(mwx, mwy, @max(radius, 4), 1000);

        if (input.wasPressed(c.SDL_SCANCODE_F12)) {
            var name_buf: [64]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "hexe-{d}.png", .{engine.tick});
            engine.screenshot(io, name, null) catch |err| std.log.err("screenshot: {s}", .{@errorName(err)});
        }
        if (session) |s| if (input.wasPressed(c.SDL_SCANCODE_F5)) {
            _ = s.save() catch |err| std.log.err("save: {s}", .{@errorName(err)});
        };

        // HUD.
        engine.hud.clear();
        if (show_hud) fillHud(engine, &profile, .{
            .frame_ms = frame_ms,
            .paused = paused,
            .material = table.names[material],
            .radius = radius,
            .view = view,
            .cursor = if (session != null) .{ mwx, mwy } else .{ @mod(mwx, cell.world_size), @mod(mwy, cell.world_size) },
            .material_count = table.len,
            .world = session,
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
    }
    try engine.finish();
    if (session) |s| s.report();
    const secs = @as(f64, @floatFromInt(run_start.untilNow(io, .awake).nanoseconds)) / 1e9;
    std.log.info("{d} frames in {d:.2} s ({d:.1} fps), {d} ticks ({d:.1}/s), grid {d:.3} ms", .{
        frames, secs, @as(f64, @floatFromInt(frames)) / secs, engine.tick, @as(f64, @floatFromInt(engine.tick)) / secs, profile.gridSmooth(&engine.names),
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
    const ps = engine.mirror().particles;
    hud.print("particles {d} live (cap {d})  spawned {d} landed {d} refused {d} lost {d} impacts {d}", .{ ps.live, ps.capacity, ps.spawned, ps.landed, ps.refused, ps.lost, ps.impacts });
    hud.print("brush {s} r{d}  zoom {d}x  cam {d},{d}  cursor {d},{d}", .{ info.material, info.radius, info.view.scale, info.view.camera_x, info.view.camera_y, info.cursor[0], info.cursor[1] });
    if (info.world) |s| s.hudLines(hud);
    hud.print("1-{d} material  LMB paint  RMB erase  wheel size  WASD pan  =/- zoom  space pause  F2 tiles  F3 air  E boom", .{info.material_count -| 1});
    hud.print("1-{d} material  LMB paint  RMB erase  wheel size  WASD pan  =/- zoom  space pause  F2 tiles", .{info.material_count -| 1});
    hud.print("Q spray sand  E spray water  X eject (explosion) at cursor", .{});
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
        if (input.wasPressed(c.SDL_SCANCODE_X)) _ = sim.spawnCrate(cursor[0], cursor[1], 40, roles.wood) catch {};
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
        engine.hud.print("bodies {d}  cpu {d:.2} ms  readback {d:.2} ms  gpu {d:.3} ms  C crate  X wood  V slab  B beam{s}", .{
            sim.bodyCount(),
            sim.stats.cpu_ms,
            sim.stats.readback_ms,
            gpu_ms,
            if (self.placing_beam) (if (self.beam_start != null) "  [click the beam's end]" else "  [click the beam's start]") else "",
        });
    }
};

/// Circles every radius/2 pixels from `a` to `b` (at least one).
fn strokeLine(list: *commands.CommandList, a: [2]i32, b: [2]i32, radius: i32, material: u8) void {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len: i32 = @intFromFloat(@sqrt(@as(f32, @floatFromInt(dx * dx + dy * dy))));
    const step = @max(1, @divTrunc(radius, 2));
    const n = @min(@divTrunc(len, step) + 1, 64);
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        const x = a[0] + if (n > 1) @divTrunc(dx * i, n - 1) else 0;
        const y = a[1] + if (n > 1) @divTrunc(dy * i, n - 1) else 0;
        list.fillCircle(x, y, radius, material, .{});
    }
}

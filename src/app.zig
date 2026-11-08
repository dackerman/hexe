//! Windowed sandbox: fixed 60 Hz ticks, mouse painting, camera, HUD.
//!
//! Input mapping (docs/decisions/07-input-mapping.md):
//!   left mouse     paint the selected material    right mouse   erase (air)
//!   1-9            select material by id           wheel         brush radius
//!   WASD / arrows  pan                             middle drag   pan
//!   = / -          zoom in / out (integer)         space         pause
//!   .              single tick while paused        F1            toggle HUD
//!   F2             activity tile overlay           F12           screenshot
//!   Tab / shift    cycle debug overlays            T             cursor torch
//!   F5             lighting mode (cascades, simple, off)
//!   F6             probe spacing 1/2/4 (quality)   F7 bloom      F8 vignette
//!   Esc            quit
//! (render keys: docs/decisions/103-render-overlays.md)
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
const materials_extra = @import("sim/materials_extra.zig");
const materials = @import("sim/materials.zig");
const overlay = @import("render/overlay.zig");
const demo = @import("render/demo.zig");
const renderer_mod = @import("render/renderer.zig");
const max_ticks_per_frame = @import("sim/pipeline.zig").max_ticks_per_frame;
const Profile = @import("profile.zig").Profile;

const tick_ns: i96 = std.time.ns_per_s / 60;

pub fn run(gpa: std.mem.Allocator, io: std.Io, cli: Cli) !u8 {
    var window = try Window.init("hexe", cli.width, cli.height);
    defer window.deinit();
    const table = materials_extra.table();
    const engine = try gpa.create(Engine);
    defer gpa.destroy(engine);
    try engine.init(gpa, .{
        .window = &window,
        .vsync = cli.vsync,
        .table = &table,
        .validation = cli.validation orelse (builtin.mode == .debug),
        .pipeline = .{ .sleep = cli.sleep, .noise = cli.scene == .noise },
        .overlap = cli.overlap,
    });
    defer engine.deinit();
    var profile: Profile = .{};
    engine.profile = &profile;
    @import("main.zig").applyRenderCli(&engine.renderer.settings, cli);
    const rs = &engine.renderer.settings;
    var torch = true;

    const win_w, const win_h = window.pixelSize();
    var view: View = .{ .scale = cli.zoom };
    const start_center: [2]i32 = cli.center orelse if (cli.scene == .lighting) @import("sim/scenes.zig").lighting_center else .{ cell.world_size / 2, cell.world_size / 2 };
    view.camera_x = start_center[0] - @as(i32, @intCast(win_w / 2 / view.scale));
    view.camera_y = start_center[1] - @as(i32, @intCast(win_h / 2 / view.scale));
    var frame_ms_sum: f64 = 0;
    var frame_ms_count: u64 = 0;

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
        if (input.wasPressed(c.SDL_SCANCODE_TAB)) {
            const back = input.isDown(c.SDL_SCANCODE_LSHIFT) or input.isDown(c.SDL_SCANCODE_RSHIFT);
            rs.overlay = if (back) overlay.prev(rs.overlay) else overlay.next(rs.overlay);
        }
        if (input.wasPressed(c.SDL_SCANCODE_F5)) rs.light_mode = @fromBackingInt(@intCast((@backingInt(rs.light_mode) + 1) % 3));
        if (input.wasPressed(c.SDL_SCANCODE_F6)) rs.probe_spacing = if (rs.probe_spacing >= 4) 1 else rs.probe_spacing * 2;
        if (input.wasPressed(c.SDL_SCANCODE_F7)) rs.bloom = !rs.bloom;
        if (input.wasPressed(c.SDL_SCANCODE_F8)) rs.vignette = !rs.vignette;
        if (input.wasPressed(c.SDL_SCANCODE_T)) torch = !torch;

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
        view.camera_x = @mod(view.camera_x, cell.world_size);
        view.camera_y = @mod(view.camera_y, cell.world_size);

        // Painting: circles along the cursor path since last frame.
        const scale: i32 = @intCast(view.scale);
        const mwx = view.camera_x + @divFloor(@as(i32, @intFromFloat(input.mouse_x)), scale);
        const mwy = view.camera_y + @divFloor(@as(i32, @intFromFloat(input.mouse_y)), scale);
        if (input.left or input.right) {
            const paint: u8 = if (input.right) materials.air else material;
            const from = last_paint orelse [2]i32{ mwx, mwy };
            strokeLine(&pending, from, .{ mwx, mwy }, radius, paint);
            last_paint = .{ mwx, mwy };
        } else last_paint = null;

        if (input.wasPressed(c.SDL_SCANCODE_F12)) {
            var name_buf: [64]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "hexe-{d}.png", .{engine.tick});
            engine.screenshot(io, name, null) catch |err| std.log.err("screenshot: {s}", .{@errorName(err)});
        }

        // Render decorations: scene lights/sprites/signs and the cursor torch.
        engine.hud.clear();
        demo.decorate(cli.scene, engine.tick, &engine.renderer, &engine.hud);
        if (torch) engine.renderer.addLight(@as(f32, @floatFromInt(mwx)) + 0.5, @as(f32, @floatFromInt(mwy)) + 0.5, 70, .{ 1.0, 0.8, 0.55 });

        if (show_hud) fillHud(engine, &profile, .{
            .frame_ms = frame_ms,
            .paused = paused,
            .material = table.names[material],
            .radius = radius,
            .view = view,
            .cursor = .{ @mod(mwx, cell.world_size), @mod(mwy, cell.world_size) },
            .material_count = table.len,
            .extent = .{ win_w, win_h },
        });

        const src: @import("engine.zig").TickSource = .{
            .scene = cli.scene,
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
    std.log.info("{d} frames in {d:.2} s ({d:.1} fps), {d} ticks ({d:.1}/s), grid {d:.3} ms, mean frame {d:.3} ms after warm-up, overlap {s}", .{
        frames,                                                          secs,                             @as(f64, @floatFromInt(frames)) / secs, engine.tick, @as(f64, @floatFromInt(engine.tick)) / secs, profile.gridSmooth(&engine.names),
        frame_ms_sum / @as(f64, @floatFromInt(@max(frame_ms_count, 1))), if (cli.overlap) "on" else "off",
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
    /// Window size in pixels (for the light plan shown in the HUD).
    extent: [2]u32 = .{ 1920, 1080 },
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
    hud.print("render {d:.3} ms:{s}", .{ total, rw.buffered() });
    hud.print("light {s}  spacing {d}px  cascades {d}  region {d}x{d}  lights {d}  bloom {s}  vignette {s}", .{
        @tagName(r.settings.light_mode), plan.spacing, plan.count, plan.size[0], plan.size[1], r.light_count, if (r.settings.bloom) "on" else "off", if (r.settings.vignette) "on" else "off",
    });
    const ov = overlay.info(r.settings.overlay);
    hud.print("overlay [Tab] {s}{s}{s}", .{ ov.name, if (ov.legend.len > 0) ": " else "", ov.legend });
    hud.print("brush {s} r{d}  zoom {d}x  cam {d},{d}  cursor {d},{d}", .{ info.material, info.radius, info.view.scale, info.view.camera_x, info.view.camera_y, info.cursor[0], info.cursor[1] });
    hud.print("1-{d} material  LMB paint  RMB erase  wheel size  WASD pan  =/- zoom  space pause  T torch  F5 light  F6 quality", .{@min(info.material_count -| 1, 9)});
}

/// Passes summed into the HUD's render line.
const render_passes = [_][]const u8{ "light_build", "cascades", "merge", "world", "sprites", "post", "hud" };

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

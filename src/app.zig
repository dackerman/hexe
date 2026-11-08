//! Windowed sandbox: fixed 60 Hz ticks, mouse painting, camera, HUD.
//!
//! Input mapping (docs/decisions/07-input-mapping.md):
//!   left mouse     paint the selected material    right mouse   erase (air)
//!   1-9            select a palette material        wheel         brush radius
//!   0              ignite brush (sets fire)
//!   WASD / arrows  pan                             middle drag   pan
//!   = / -          zoom in / out (integer)         space         pause
//!   .              single tick while paused        F1            toggle HUD
//!   F2             activity tile overlay           F12           screenshot
//!   Esc            quit
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
const max_ticks_per_frame = @import("sim/pipeline.zig").max_ticks_per_frame;
const Profile = @import("profile.zig").Profile;

const tick_ns: i96 = std.time.ns_per_s / 60;

/// Brush materials on keys 1-9, by name (missing ones are skipped).
pub const palette = [_][]const u8{ "sand", "water", "stone", "lava", "wood", "oil", "flame", "steel", "gunpowder" };
/// Ticks between polls of the materials directory.
const reload_poll_ticks = 30;
/// How long the reload message stays in the HUD.
const reload_message_ticks = 300;

pub fn run(gpa: std.mem.Allocator, io: std.Io, cli: Cli, lib: *materials.Library) !u8 {
    var window = try Window.init("hexe", cli.width, cli.height);
    defer window.deinit();
    const engine = try gpa.create(Engine);
    defer gpa.destroy(engine);
    try engine.init(gpa, .{
        .window = &window,
        .vsync = cli.vsync,
        .tables = lib.tables,
        .ids = lib.ids(),
        .validation = cli.validation orelse (builtin.mode == .debug),
        .pipeline = .{ .sleep = cli.sleep, .noise = cli.scene == .noise },
    });
    defer engine.deinit();
    var profile: Profile = .{};
    engine.profile = &profile;

    const win_w, const win_h = window.pixelSize();
    var view: View = .{ .scale = 2 };
    view.camera_x = @as(i32, cell.world_size / 2) - @as(i32, @intCast(win_w / 2 / view.scale));
    view.camera_y = @as(i32, cell.world_size / 2) - @as(i32, @intCast(win_h / 2 / view.scale));

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
                    if (engine.reloadTables(fresh.tables, materials.Ids.resolve(&fresh.set))) |_| {
                        lib.deinit(gpa);
                        lib.* = .{ .set = fresh.set, .tables = fresh.tables };
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
        view.camera_x = @mod(view.camera_x, cell.world_size);
        view.camera_y = @mod(view.camera_y, cell.world_size);

        // Painting: circles along the cursor path since last frame.
        const scale: i32 = @intCast(view.scale);
        const mwx = view.camera_x + @divFloor(@as(i32, @intFromFloat(input.mouse_x)), scale);
        const mwy = view.camera_y + @divFloor(@as(i32, @intFromFloat(input.mouse_y)), scale);
        if (input.left or input.right) {
            const paint: u8 = if (input.right) materials.air else material;
            const from = last_paint orelse [2]i32{ mwx, mwy };
            strokeLine(&pending, from, .{ mwx, mwy }, radius, paint, input.left and igniting);
            last_paint = .{ mwx, mwy };
        } else last_paint = null;

        if (input.wasPressed(c.SDL_SCANCODE_F12)) {
            var name_buf: [64]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "hexe-{d}.png", .{engine.tick});
            engine.screenshot(io, name, null) catch |err| std.log.err("screenshot: {s}", .{@errorName(err)});
        }

        // HUD.
        engine.hud.clear();
        if (show_hud) fillHud(engine, &profile, .{
            .frame_ms = frame_ms,
            .paused = paused,
            .material = if (igniting) "ignite" else lib.name(material),
            .radius = radius,
            .view = view,
            .cursor = .{ @mod(mwx, cell.world_size), @mod(mwy, cell.world_size) },
            .material_count = palette.len,
            .message = if (reload_msg.len > 0 and engine.tick -% reload_msg_tick < reload_message_ticks) reload_msg else "",
        });

        const src: @import("engine.zig").TickSource = .{
            .scene = cli.scene,
            .seed = cli.seed,
            .extra = if (ticks > 0) pending.slice() else &.{},
        };
        try engine.frame(ticks, src, view);
        if (ticks > 0) pending.begin(engine.tick);
        frames += 1;
    }
    try engine.finish();
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
    /// Extra status line (hot reload result).
    message: []const u8 = "",
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
    hud.print("brush {s} r{d}  zoom {d}x  cam {d},{d}  cursor {d},{d}", .{ info.material, info.radius, info.view.scale, info.view.camera_x, info.view.camera_y, info.cursor[0], info.cursor[1] });
    hud.print("1-{d} material  0 ignite  LMB paint  RMB erase  wheel size  WASD pan  =/- zoom  space pause  F2 tiles", .{info.material_count});
    if (info.message.len > 0) hud.print("{s}", .{info.message});
}

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

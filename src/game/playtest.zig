//! Headless scripted play (`--script FILE`): drives the witch with a
//! timeline of inputs, paints fixtures, spawns enemies and writes view
//! screenshots (with the game's sprites and HUD) at chosen ticks, so the
//! gameplay can be looked at without a window
//! (docs/decisions/128-gameplay-playtests.md).
//!
//! Script: one statement per line, `#` comments.
//!   scene NAME              scene to run (default empty)
//!   spawn X Y               witch feet position
//!   ticks N                 run length
//!   zoom N                  screenshot zoom (default --zoom)
//!   liquid on|off           FLIP solver (default on, as in the app)
//!   air on|off              air field (default on)
//!   debug_air               print every air sample a character takes
//!   at T VERB ...           at tick T (ticks since start), in file order:
//!     hold KEY / release KEY / tap KEY   left right up down jump primary secondary
//!     tool N                select tool slot N (1-9, 0 = painter)
//!     aim X Y / aimrel DX DY   cursor in world px / relative to the witch
//!     aimenemy DX DY        cursor relative to the first enemy
//!     fill MAT X0 Y0 X1 Y1 / circle MAT X Y R / ignite X Y R / charge X Y R
//!     wake X Y R            wake solver liquid in a circle (it becomes FLIP particles)
//!     explode X Y R STRENGTH
//!     enemy walker|flyer X Y   (feet / bottom center)
//!     center X Y / center player   screenshot camera
//!     shot NAME             write PREFIX-NAME.png (PREFIX = --view-screenshot)
//!     census X Y W H        print the materials in a rectangle (synchronous readback)
//!     help                  toggle the F1 help in the shots
//!     note TEXT             print a line
const std = @import("std");
const builtin = @import("builtin");
const Engine = @import("../engine.zig").Engine;
const materials = @import("../sim/materials.zig");
const commands = @import("../sim/commands.zig");
const scenes = @import("../sim/scenes.zig");
const View = @import("../render/world.zig").View;
const Cli = @import("../main.zig").Cli;
const cell = @import("../sim/cell.zig");
const game_mod = @import("game.zig");
const Game = game_mod.Game;
const Input = game_mod.Input;

const max_steps = 512;

const Key = enum { left, right, up, down, jump, primary, secondary };

const Verb = union(enum) {
    hold: Key,
    release: Key,
    tap: Key,
    tool: u8,
    aim: [2]f32,
    aimrel: [2]f32,
    aimenemy: [2]f32,
    fill: struct { m: u8, r: [4]i32 },
    circle: struct { m: u8, x: i32, y: i32, r: i32 },
    ignite: [3]i32,
    charge: [3]i32,
    wake: [3]i32,
    explode: struct { x: i32, y: i32, r: i32, s: f32 },
    enemy: struct { kind: game_mod.EnemyKind, x: f32, y: f32 },
    center: ?[2]i32,
    shot: []const u8,
    note: []const u8,
    census: [4]i32,
    help,
};

const Step = struct { at: u32, verb: Verb };

pub const Script = struct {
    scene: scenes.Scene = .empty,
    spawn: [2]f32 = .{ 1024, 1024 },
    ticks: u32 = 300,
    zoom: ?u32 = null,
    liquid: bool = true,
    air: bool = true,
    steps: [max_steps]Step = undefined,
    len: u32 = 0,

    pub fn parse(text: []const u8, lib: *const materials.Library) !Script {
        var s: Script = .{};
        var lines = std.mem.splitScalar(u8, text, '\n');
        var line_no: u32 = 0;
        while (lines.next()) |raw| {
            line_no += 1;
            const line = std.mem.trim(u8, if (std.mem.indexOfScalar(u8, raw, '#')) |i| raw[0..i] else raw, " \t\r");
            if (line.len == 0) continue;
            s.parseLine(line, lib) catch |err| {
                std.debug.print("script line {d}: {s}: {s}\n", .{ line_no, @errorName(err), line });
                return err;
            };
        }
        return s;
    }

    fn parseLine(s: *Script, line: []const u8, lib: *const materials.Library) !void {
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const head = it.next() orelse return;
        if (std.mem.eql(u8, head, "scene")) {
            s.scene = std.meta.stringToEnum(scenes.Scene, it.next() orelse return error.Missing) orelse return error.UnknownScene;
        } else if (std.mem.eql(u8, head, "spawn")) {
            s.spawn = .{ try float(&it), try float(&it) };
        } else if (std.mem.eql(u8, head, "ticks")) {
            s.ticks = try int(u32, &it);
        } else if (std.mem.eql(u8, head, "zoom")) {
            s.zoom = try int(u32, &it);
        } else if (std.mem.eql(u8, head, "liquid")) {
            s.liquid = std.mem.eql(u8, it.next() orelse "on", "on");
        } else if (std.mem.eql(u8, head, "air")) {
            s.air = std.mem.eql(u8, it.next() orelse "on", "on");
        } else if (std.mem.eql(u8, head, "debug_air")) {
            @import("world.zig").debug_air = true;
        } else if (std.mem.eql(u8, head, "at")) {
            if (s.len >= max_steps) return error.TooManySteps;
            const at = try int(u32, &it);
            const verb = it.next() orelse return error.Missing;
            const v: Verb = if (std.mem.eql(u8, verb, "hold"))
                .{ .hold = try key(&it) }
            else if (std.mem.eql(u8, verb, "release"))
                .{ .release = try key(&it) }
            else if (std.mem.eql(u8, verb, "tap"))
                .{ .tap = try key(&it) }
            else if (std.mem.eql(u8, verb, "tool"))
                .{ .tool = blk: {
                    const n = try int(u8, &it);
                    break :blk if (n == 0) 9 else n - 1;
                } }
            else if (std.mem.eql(u8, verb, "aim"))
                .{ .aim = .{ try float(&it), try float(&it) } }
            else if (std.mem.eql(u8, verb, "aimrel"))
                .{ .aimrel = .{ try float(&it), try float(&it) } }
            else if (std.mem.eql(u8, verb, "aimenemy"))
                .{ .aimenemy = .{ try float(&it), try float(&it) } }
            else if (std.mem.eql(u8, verb, "fill"))
                .{ .fill = .{ .m = try mat(&it, lib), .r = .{ try int(i32, &it), try int(i32, &it), try int(i32, &it), try int(i32, &it) } } }
            else if (std.mem.eql(u8, verb, "circle"))
                .{ .circle = .{ .m = try mat(&it, lib), .x = try int(i32, &it), .y = try int(i32, &it), .r = try int(i32, &it) } }
            else if (std.mem.eql(u8, verb, "ignite"))
                .{ .ignite = .{ try int(i32, &it), try int(i32, &it), try int(i32, &it) } }
            else if (std.mem.eql(u8, verb, "charge"))
                .{ .charge = .{ try int(i32, &it), try int(i32, &it), try int(i32, &it) } }
            else if (std.mem.eql(u8, verb, "wake"))
                .{ .wake = .{ try int(i32, &it), try int(i32, &it), try int(i32, &it) } }
            else if (std.mem.eql(u8, verb, "explode"))
                .{ .explode = .{ .x = try int(i32, &it), .y = try int(i32, &it), .r = try int(i32, &it), .s = try float(&it) } }
            else if (std.mem.eql(u8, verb, "enemy"))
                .{ .enemy = .{ .kind = std.meta.stringToEnum(game_mod.EnemyKind, it.next() orelse return error.Missing) orelse return error.UnknownEnemy, .x = try float(&it), .y = try float(&it) } }
            else if (std.mem.eql(u8, verb, "center"))
                .{ .center = blk: {
                    const a = it.next() orelse return error.Missing;
                    if (std.mem.eql(u8, a, "player")) break :blk null;
                    break :blk .{ try std.fmt.parseInt(i32, a, 10), try int(i32, &it) };
                } }
            else if (std.mem.eql(u8, verb, "shot"))
                .{ .shot = it.next() orelse return error.Missing }
            else if (std.mem.eql(u8, verb, "census"))
                .{ .census = .{ try int(i32, &it), try int(i32, &it), try int(i32, &it), try int(i32, &it) } }
            else if (std.mem.eql(u8, verb, "help"))
                .help
            else if (std.mem.eql(u8, verb, "note"))
                .{ .note = it.rest() }
            else
                return error.UnknownVerb;
            s.steps[s.len] = .{ .at = at, .verb = v };
            s.len += 1;
        } else return error.UnknownStatement;
    }

    fn int(comptime T: type, it: anytype) !T {
        return std.fmt.parseInt(T, it.next() orelse return error.Missing, 10);
    }
    fn float(it: anytype) !f32 {
        return std.fmt.parseFloat(f32, it.next() orelse return error.Missing);
    }
    fn key(it: anytype) !Key {
        return std.meta.stringToEnum(Key, it.next() orelse return error.Missing) orelse error.UnknownKey;
    }
    fn mat(it: anytype, lib: *const materials.Library) !u8 {
        const name = it.next() orelse return error.Missing;
        return lib.id(name) orelse error.UnknownMaterial;
    }
};

/// Material census of a rectangle (synchronous readback; waits for the GPU).
fn printCensus(engine: *Engine, lib: *const materials.Library, cells: []u32, r: [4]i32, t: u32) !void {
    try engine.readbackCells(cells);
    var counts: [256]u32 = @splat(0);
    var burning: u32 = 0;
    var body: u32 = 0;
    var particle: u32 = 0;
    var y = r[1];
    while (y < r[1] + r[3]) : (y += 1) {
        var x = r[0];
        while (x < r[0] + r[2]) : (x += 1) {
            const c = cells[cell.index(cell.wrap(x), cell.wrap(y))];
            counts[cell.material(c)] += 1;
            burning += @intFromBool(cell.has(c, cell.flag_burning));
            body += @intFromBool(cell.has(c, cell.flag_body));
            particle += @intFromBool(cell.has(c, cell.flag_particle));
        }
    }
    std.debug.print("  [tick {d}] census {d},{d} {d}x{d}:", .{ t, r[0], r[1], r[2], r[3] });
    for (counts, 0..) |n, m| if (n > 0 and m != 0) std.debug.print(" {s} {d}", .{ lib.name(@intCast(m)), n });
    std.debug.print(" (burning {d}, body-owned {d}, particle-backed {d})\n", .{ burning, body, particle });
}

fn setKey(in: *Input, k: Key, down: bool) void {
    switch (k) {
        .left => in.left = down,
        .right => in.right = down,
        .up => in.up = down,
        .jump => in.setButtons(down, in.down, in.primary, in.secondary),
        .down => in.setButtons(in.jump, down, in.primary, in.secondary),
        .primary => in.setButtons(in.jump, in.down, down, in.secondary),
        .secondary => in.setButtons(in.jump, in.down, in.primary, down),
    }
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, cli: Cli, lib: *const materials.Library, path: []const u8) !u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        std.debug.print("cannot read script {s}: {s}\n", .{ path, @errorName(err) });
        return 2;
    };
    defer gpa.free(text);
    const script = try gpa.create(Script);
    defer gpa.destroy(script);
    script.* = Script.parse(text, lib) catch return 2;

    const engine = try gpa.create(Engine);
    defer gpa.destroy(engine);
    try engine.init(gpa, .{
        .library = lib,
        .validation = cli.validation orelse (builtin.mode == .debug),
        .pipeline = .{ .sleep = cli.sleep, .air = script.air, .air_sleep = cli.air_sleep, .bodies = cli.bodies orelse true, .liquid = script.liquid, .liquid_params = cli.liquid_params },
        .overlap = cli.overlap,
    });
    defer engine.deinit();
    @import("../main.zig").applyRenderCli(&engine.renderer.settings, .{ .scene = script.scene, .bloom = cli.bloom, .vignette = cli.vignette, .light_mode = cli.light_mode });

    const game = try gpa.create(Game);
    defer gpa.destroy(game);
    try game.init(engine, lib, script.spawn);
    game.log.echo = true;
    if (cli.spawn_enemies > 0) game.debug_spawn = cli.spawn_enemies;

    const prefix = cli.view_screenshot orelse "playtest";
    const stem = if (std.mem.endsWith(u8, prefix, ".png")) prefix[0 .. prefix.len - 4] else prefix;
    const zoom = script.zoom orelse cli.zoom;
    var center: ?[2]i32 = null;
    var show_help = false;
    var input: Input = .{ .aim = .{ script.spawn[0] + 40, script.spawn[1] - 14 } };
    var aim_rel: ?[2]f32 = null;
    var taps: [8]Key = undefined;
    var n_taps: u32 = 0;
    var list: commands.CommandList = .{};
    const cells = try gpa.alloc(u32, cell.world_size * cell.world_size);
    defer gpa.free(cells);
    std.debug.print("playtest {s}: scene {s}, {d} ticks, {d} steps\n", .{ path, @tagName(script.scene), script.ticks, script.len });

    for (0..script.ticks) |ti| {
        const t: u32 = @intCast(ti);
        try engine.poll();
        list.begin(engine.tick);
        // Taps from the previous tick are released now.
        for (taps[0..n_taps]) |k| setKey(&input, k, false);
        n_taps = 0;
        var shots: [4][]const u8 = undefined;
        var n_shots: u32 = 0;
        var census: ?[4]i32 = null;
        for (script.steps[0..script.len]) |st| {
            if (st.at != t) continue;
            switch (st.verb) {
                .hold => |k| setKey(&input, k, true),
                .release => |k| setKey(&input, k, false),
                .tap => |k| {
                    setKey(&input, k, true);
                    if (n_taps < taps.len) {
                        taps[n_taps] = k;
                        n_taps += 1;
                    }
                },
                .tool => |n| input.select = n,
                .aim => |a| {
                    input.aim = a;
                    aim_rel = null;
                },
                .aimrel => |a| aim_rel = a,
                .aimenemy => |a| if (game.enemies.len > 0) {
                    const e = &game.enemies.items[0].actor;
                    input.aim = .{ e.cx() + a[0], e.cy() + a[1] };
                    aim_rel = null;
                },
                .fill => |f| list.fillRect(f.r[0], f.r[1], f.r[2], f.r[3], f.m, .{}),
                .circle => |c| list.fillCircle(c.x, c.y, c.r, c.m, .{}),
                .ignite => |c| list.igniteCircle(c[0], c[1], c[2]),
                .charge => |c| list.chargeCircle(c[0], c[1], c[2]),
                .wake => |c| list.wakeLiquid(c[0], c[1], c[2], 1),
                .explode => |e| {
                    game_mod.explode.explode(&list, e.x, e.y, e.r, e.s, .{ .air = engine.pipeline.config.air, .liquid = engine.pipeline.config.liquid });
                    game.blasts.add(.{ .x = @floatFromInt(e.x), .y = @floatFromInt(e.y), .radius = @floatFromInt(e.r), .strength = e.s });
                },
                .enemy => |e| _ = game.enemies.spawn(e.kind, e.x, e.y),
                .center => |c| center = c,
                .shot => |name| if (n_shots < shots.len) {
                    shots[n_shots] = name;
                    n_shots += 1;
                },
                .note => |s| std.debug.print("  [tick {d}] note: {s}\n", .{ t, s }),
                .census => |r| census = r,
                .help => show_help = !show_help,
            }
        }
        if (aim_rel) |r| input.aim = .{ game.player.actor.cx() + r[0], game.player.actor.cy() + r[1] };
        game.requestReadback();
        game.tick(&input, &list);
        input.consumeEdges();
        try engine.frame(1, .{ .scene = script.scene, .seed = cli.seed, .extra = list.slice() }, null);
        if (census) |r| try printCensus(engine, lib, cells, r, t);
        for (shots[0..n_shots]) |name| {
            var buf: [256]u8 = undefined;
            const out = try std.fmt.bufPrint(&buf, "{s}-{s}.png", .{ stem, name });
            const c = center orelse [2]i32{ @intFromFloat(game.player.actor.cx()), @intFromFloat(game.player.actor.cy()) };
            const view: View = .{
                .scale = zoom,
                .camera_x = c[0] - @as(i32, @intCast(cli.width / 2 / zoom)),
                .camera_y = c[1] - @as(i32, @intCast(cli.height / 2 / zoom)),
            };
            engine.hud.clear();
            game.draw(view, .{ cli.width, cli.height }, &input);
            if (cli.hud and show_help) Game.helpLines(&engine.hud) else if (cli.hud) {
                game.hudLines(&engine.hud);
                engine.hud.print("playtest {s}  tick {d}  shot {s}", .{ std.fs.path.basename(path), t, name });
            }
            try engine.screenshotView(io, out, view, cli.width, cli.height);
            engine.renderer.clearDraws();
            const pa = &game.player.actor;
            var sbuf: [64]u8 = undefined;
            std.debug.print("  [tick {d}] shot {s}: witch at {d:.0},{d:.0} hp {d:.0} v {d:.0},{d:.0} liquid {d:.2} breath {d:.1}{s}; enemies {d} kills {d} bodies {d}\n", .{ t, std.fs.path.basename(out), pa.cx(), pa.cy(), pa.health, pa.body.vx, pa.body.vy, pa.liquid, pa.status.breath, pa.status.describe(&sbuf), game.enemies.len, game.enemies.kills, engine.pipeline.bodies.sim.bodyCount() });
            for (game.enemies.items[0..game.enemies.len]) |*e| {
                std.debug.print("      {s} at {d:.0},{d:.0} hp {d:.0} v {d:.0},{d:.0} liquid {d:.2}{s}\n", .{ @tagName(e.kind), e.actor.cx(), e.actor.cy(), e.actor.health, e.actor.body.vx, e.actor.body.vy, e.actor.liquid, e.actor.status.describe(&sbuf) });
            }
        }
    }
    try engine.finish();
    const pa = &game.player.actor;
    std.debug.print("playtest done: witch hp {d:.0} deaths {d}, enemies {d} alive, {d} killed, {d} bodies, {d} tool uses; gameplay CPU {d:.4} ms/tick mean\n", .{ pa.health, game.player.deaths, game.enemies.len, game.enemies.kills, engine.pipeline.bodies.sim.bodyCount(), game.tools.uses, game.tick_ms_total / @as(f64, @floatFromInt(@max(game.ticks, 1))) });
    const bt = engine.pipeline.bodies.sim.totals;
    std.debug.print("  bodies layer: {d} destruction events, {d} connectivity runs (max {d:.3} ms), {d} loose components -> bodies, {d} -> rubble, {d} events queued at the end\n", .{ bt.events, bt.connectivity_runs, bt.connectivity_ms_max, bt.extracted, bt.rubble_components, engine.pipeline.bodies.sim.event_len });
    return 0;
}

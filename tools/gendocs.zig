//! Generates docs/materials.md from materials/*.zon.
//!
//! Usage: gendocs <materials-dir> <output.md>
//! Run through `zig build docs`. Exits non-zero (with the loader's
//! diagnostics) if the materials do not validate.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const data = @import("data");
const mats = data.materials;
const temperature = data.temperature;
const gpu = data.gpu_tables;
const Material = mats.Material;
const MaterialSet = mats.MaterialSet;
const Def = mats.Def;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.log.err("usage: gendocs <materials-dir> <output.md>", .{});
        std.process.exit(2);
    }
    var diag: mats.Diagnostics = .init(gpa);
    defer diag.deinit();
    var set = mats.loadDir(io, gpa, args[1], &diag) catch |err| {
        std.log.err("materials failed to load:\n{f}", .{diag});
        return err;
    };
    defer set.deinit();

    // Leading `//` comment of each file, used as the notes column.
    const sources = try mats.readZonDir(io, arena, args[1]);
    var notes: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (sources) |s| try notes.put(arena, std.fs.path.stem(s.path), leadingComment(arena, s.text));

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try generate(arena, &out.writer, &set, &notes);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = out.written() });
    std.log.info("wrote {s} ({d} materials)", .{ args[2], set.materials.len });
}

fn leadingComment(a: Allocator, text: []const u8) []const u8 {
    var parts: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, t, "//")) break;
        if (parts.items.len > 0) parts.append(a, ' ') catch return "";
        parts.appendSlice(a, std.mem.trim(u8, t[2..], " ")) catch return "";
    }
    return parts.items;
}

// ------------------------------------------------------------- formatting

const Ctx = struct {
    a: Allocator,
    set: *const MaterialSet,

    fn p(c: Ctx, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(c.a, fmt, args) catch "?";
    }

    fn temp(c: Ctx, celsius: i32) []const u8 {
        return c.p("{d} °C", .{celsius});
    }

    fn change(c: Ctx, pc: mats.PhaseChange, rel: []const u8) []const u8 {
        return c.p("{s} {d} °C → {s}", .{ rel, pc.at, pc.to });
    }
};

/// One table column: returns null when the field has its default value.
const Column = struct {
    title: []const u8,
    cell: *const fn (Ctx, *const Material) ?[]const u8,
};

fn nz(c: Ctx, v: i32) ?[]const u8 {
    return if (v == 0) null else c.p("{d}", .{v});
}

const columns = [_]Column{
    .{ .title = "solver", .cell = struct {
        fn f(_: Ctx, m: *const Material) ?[]const u8 {
            return if (m.def.solver == .cellular) null else @tagName(m.def.solver);
        }
    }.f },
    .{ .title = "density", .cell = struct {
        fn f(c: Ctx, m: *const Material) ?[]const u8 {
            return c.p("{d}", .{m.def.density});
        }
    }.f },
    .{ .title = "dispersion", .cell = struct {
        fn f(c: Ctx, m: *const Material) ?[]const u8 {
            return nz(c, m.def.dispersion);
        }
    }.f },
    .{ .title = "slide", .cell = struct {
        fn f(c: Ctx, m: *const Material) ?[]const u8 {
            return nz(c, m.def.slide);
        }
    }.f },
    .{ .title = "health", .cell = struct {
        fn f(c: Ctx, m: *const Material) ?[]const u8 {
            return nz(c, m.def.health);
        }
    }.f },
    .{ .title = "lifetime", .cell = struct {
        fn f(c: Ctx, m: *const Material) ?[]const u8 {
            if (m.def.lifetime == 0) return null;
            return c.p("{d} ticks → {s}", .{ m.def.lifetime, m.def.decays_to.? });
        }
    }.f },
    .{ .title = "temp", .cell = struct {
        fn f(c: Ctx, m: *const Material) ?[]const u8 {
            return if (m.def.temperature == 20) null else c.temp(m.def.temperature);
        }
    }.f },
    .{ .title = "conductivity", .cell = struct {
        fn f(c: Ctx, m: *const Material) ?[]const u8 {
            return nz(c, m.def.conductivity);
        }
    }.f },
    .{ .title = "emits heat", .cell = struct {
        fn f(c: Ctx, m: *const Material) ?[]const u8 {
            return if (m.def.emits_heat == 0) null else c.p("{d} °C/tick", .{m.def.emits_heat});
        }
    }.f },
    .{ .title = "phase changes", .cell = struct {
        fn f(c: Ctx, m: *const Material) ?[]const u8 {
            var parts: std.ArrayList([]const u8) = .empty;
            if (m.def.melt) |pc| parts.append(c.a, c.change(pc, "melts >")) catch {};
            if (m.def.boil) |pc| parts.append(c.a, c.change(pc, "boils >")) catch {};
            if (m.def.freeze) |pc| parts.append(c.a, c.change(pc, "freezes <")) catch {};
            if (parts.items.len == 0) return null;
            return std.mem.join(c.a, "; ", parts.items) catch "?";
        }
    }.f },
    .{ .title = "flammable", .cell = struct {
        fn f(c: Ctx, m: *const Material) ?[]const u8 {
            const fl = m.def.flammable orelse return null;
            var s = c.p("ignites > {d} °C, {d} ticks → {s}", .{ fl.ignite_at, fl.burn_ticks, fl.to });
            if (fl.smoke) |sm| s = c.p("{s}, smoke {s}", .{ s, sm });
            if (fl.heat != 0) s = c.p("{s}, +{d} °C/tick", .{ s, fl.heat });
            if (fl.event != .none) s = c.p("{s}, event `{t}`", .{ s, fl.event });
            return s;
        }
    }.f },
    .{ .title = "impact", .cell = struct {
        fn f(c: Ctx, m: *const Material) ?[]const u8 {
            if (m.def.impact == .none and !m.def.ricochet) return null;
            return if (m.def.ricochet) c.p("{t}, ricochet", .{m.def.impact}) else @tagName(m.def.impact);
        }
    }.f },
    .{ .title = "blast", .cell = struct {
        fn f(c: Ctx, m: *const Material) ?[]const u8 {
            if (m.def.blast_threshold == 0) return "immune";
            return c.p("{d}, {t}", .{ m.def.blast_threshold, m.def.blast_response });
        }
    }.f },
    .{ .title = "rubble", .cell = struct {
        fn f(_: Ctx, m: *const Material) ?[]const u8 {
            return m.def.rubble;
        }
    }.f },
    .{ .title = "drag", .cell = struct {
        fn f(c: Ctx, m: *const Material) ?[]const u8 {
            return nz(c, m.def.drag);
        }
    }.f },
    .{ .title = "pressure event", .cell = struct {
        fn f(c: Ctx, m: *const Material) ?[]const u8 {
            return nz(c, m.def.pressure_event);
        }
    }.f },
    .{ .title = "light", .cell = struct {
        fn f(c: Ctx, m: *const Material) ?[]const u8 {
            var parts: std.ArrayList([]const u8) = .empty;
            if (m.def.emissive != 0) parts.append(c.a, c.p("emissive {d}", .{m.def.emissive})) catch {};
            if (m.def.glow) |g| parts.append(c.a, c.p("glow {d}–{d} °C", .{ g.from, g.to })) catch {};
            if (m.def.translucent) parts.append(c.a, "translucent") catch {};
            if (m.def.blocks_light) parts.append(c.a, "blocks light") catch {};
            if (parts.items.len == 0) return null;
            return std.mem.join(c.a, ", ", parts.items) catch "?";
        }
    }.f },
    .{ .title = "flags", .cell = struct {
        fn f(c: Ctx, m: *const Material) ?[]const u8 {
            var parts: std.ArrayList([]const u8) = .empty;
            if (m.def.conductive) parts.append(c.a, "conductive") catch {};
            if (m.def.extinguishes) parts.append(c.a, "extinguishes") catch {};
            if (m.def.feeds_air) parts.append(c.a, "feeds air") catch {};
            if (m.def.anchor) parts.append(c.a, "anchor") catch {};
            if (parts.items.len == 0) return null;
            return std.mem.join(c.a, ", ", parts.items) catch "?";
        }
    }.f },
    .{ .title = "ramp", .cell = struct {
        fn f(c: Ctx, m: *const Material) ?[]const u8 {
            var parts: std.ArrayList([]const u8) = .empty;
            for (m.def.ramp) |rgb| parts.append(c.a, c.p("`{x:0>6}`", .{rgb})) catch {};
            return std.mem.join(c.a, " ", parts.items) catch "?";
        }
    }.f },
};

const phase_titles = [_]struct { mats.Phase, []const u8 }{
    .{ .static, "Static solids" },
    .{ .powder, "Powders" },
    .{ .liquid, "Liquids" },
    .{ .gas, "Gases" },
};

fn generate(a: Allocator, w: *Io.Writer, set: *const MaterialSet, notes: *const std.StringHashMapUnmanaged([]const u8)) !void {
    const c: Ctx = .{ .a = a, .set = set };
    try w.writeAll(
        \\# Materials
        \\
        \\<!-- Generated by `zig build docs` (tools/gendocs.zig) from materials/*.zon. Do not edit. -->
        \\
        \\Generated from `materials/*.zon`; edit those files and run
        \\`zig build docs`. The schema and the meaning of each field are in
        \\[03-materials.md](03-materials.md). Temperatures are shown in °C as
        \\authored; the GPU stores them as bytes, `°C = 8·t − 40`, rounded to the
        \\nearest step. Melt and boil fire strictly above their threshold, freeze
        \\strictly below it.
        \\
        \\
    );

    // Index.
    try w.print("## Index\n\n{d} materials including built-in air.\n\n| id | name | phase | notes |\n|---|---|---|---|\n", .{set.materials.len});
    for (set.materials) |m| {
        const note = if (m.id == mats.air_id) "built in; every empty cell" else notes.get(m.def.name) orelse "";
        try w.print("| {d} | {s} | {t} | {s} |\n", .{ m.id, m.def.name, m.def.phase, note });
    }
    try w.writeAll("\n");

    // One table per phase with the columns that any material of that phase sets.
    for (phase_titles) |pt| {
        var rows: std.ArrayList(*const Material) = .empty;
        for (set.materials[1..]) |*m| if (m.def.phase == pt[0]) try rows.append(a, m);
        if (rows.items.len == 0) continue;
        var used: [columns.len]bool = @splat(false);
        for (rows.items) |m| for (columns, 0..) |col, i| {
            if (col.cell(c, m) != null) used[i] = true;
        };
        try w.print("## {s}\n\n| material |", .{pt[1]});
        for (columns, used) |col, u| if (u) try w.print(" {s} |", .{col.title});
        try w.writeAll("\n|---|");
        for (used) |u| if (u) try w.writeAll("---|");
        try w.writeAll("\n");
        for (rows.items) |m| {
            try w.print("| **{s}** |", .{m.def.name});
            for (columns, used) |col, u| if (u) try w.print(" {s} |", .{col.cell(c, m) orelse ""});
            try w.writeAll("\n");
        }
        try w.writeAll("\n");
    }

    try writeReactions(c, w);
    try writeContact(c, w);
    try writeByproducts(c, w);
    try writeGpuLayout(w);
}

fn writeReactions(c: Ctx, w: *Io.Writer) !void {
    const set = c.set;
    try w.writeAll(
        \\## Reactions
        \\
        \\Each entry is defined once, in one of the two files, and applies to the
        \\pair symmetrically. "—" means unchanged. Chance is per tick per
        \\adjacent pair, out of 255 (255 = always). Temperature bounds apply to
        \\the mean of the two cells' temperatures.
        \\
        \\| A | B | A becomes | B becomes | chance | temperature | catalyst | event | defined in |
        \\|---|---|---|---|---|---|---|---|---|
        \\
    );
    var involved: [mats.max_materials]bool = @splat(false);
    for (set.materials) |m| for (m.def.reactions) |r| {
        involved[m.id] = true;
        involved[set.idOf(r.with).?] = true;
        var range: []const u8 = "";
        if (r.min_temp != null and r.max_temp != null) {
            range = c.p("{d}–{d} °C", .{ r.min_temp.?, r.max_temp.? });
        } else if (r.min_temp) |t| {
            range = c.p("≥ {d} °C", .{t});
        } else if (r.max_temp) |t| range = c.p("≤ {d} °C", .{t});
        try w.print("| {s} | {s} | {s} | {s} | {d} | {s} | {s} | {s} | `{s}` |\n", .{
            m.def.name,                   r.with,
            r.self orelse "—",
            r.other orelse "—",
            r.chance,                     range,
            r.catalyst orelse "",         if (r.event == .none) "" else @tagName(r.event),
            std.fs.path.basename(m.path),
        });
    };

    try w.writeAll(
        \\
        \\### Reaction matrix
        \\
        \\Rows are the cell, columns its neighbor; each cell of the matrix shows
        \\what the row material becomes (`·` unchanged, `air` consumed). Only
        \\materials that take part in a reaction are listed.
        \\
        \\
    );
    const t = try gpu.build(c.a, set);
    try w.writeAll("| |");
    for (set.materials) |m| if (involved[m.id]) try w.print(" {s} |", .{m.def.name});
    try w.writeAll("\n|---|");
    for (set.materials) |m| if (involved[m.id]) try w.writeAll("---|");
    try w.writeAll("\n");
    for (set.materials) |row| {
        if (!involved[row.id]) continue;
        try w.print("| **{s}** |", .{row.def.name});
        for (set.materials) |col| {
            if (!involved[col.id]) continue;
            const e = t.reaction(row.id, col.id);
            if (e.chance == 0) {
                try w.writeAll(" |");
            } else if (e.self_result == row.id) {
                try w.writeAll(" · |");
            } else {
                try w.print(" {s} |", .{set.get(e.self_result).?.def.name});
            }
        }
        try w.writeAll("\n");
    }
    try w.writeAll("\n");
}

fn writeContact(c: Ctx, w: *Io.Writer) !void {
    try w.writeAll("## Entity contact effects\n\n| material | effects |\n|---|---|\n");
    for (c.set.materials[1..]) |m| {
        const o = m.def.on_contact;
        var parts: std.ArrayList([]const u8) = .empty;
        if (o.slow != 0) try parts.append(c.a, c.p("slow {d}%", .{@as(i32, @intFromFloat(@round(o.slow * 100)))}));
        if (o.burn != 0) try parts.append(c.a, c.p("burn {d} hp/s", .{o.burn}));
        if (o.corrode != 0) try parts.append(c.a, c.p("corrode {d} hp/s", .{o.corrode}));
        inline for (.{ "drown", "buoyant", "ignite", "extinguish", "wet", "strip_armor", "oily", "slippery", "blind", "bloody" }) |f| {
            if (@field(o, f)) try parts.append(c.a, f);
        }
        if (parts.items.len == 0) continue;
        try w.print("| {s} | {s} |\n", .{ m.def.name, try std.mem.join(c.a, ", ", parts.items) });
    }
    try w.writeAll("\n");
}

fn writeByproducts(c: Ctx, w: *Io.Writer) !void {
    const set = c.set;
    try w.writeAll(
        \\## Byproduct graph
        \\
        \\Derived from melt, freeze, boil, lifetime decay, burning, rubble and
        \\reaction fields. Every arrow is data.
        \\
        \\```
        \\
    );
    for (set.materials[1..]) |m| {
        const d = m.def;
        if (d.melt) |pc| try w.print("{s} ─melt >{d}°C→ {s}\n", .{ d.name, pc.at, pc.to });
        if (d.boil) |pc| try w.print("{s} ─boil >{d}°C→ {s}\n", .{ d.name, pc.at, pc.to });
        if (d.freeze) |pc| try w.print("{s} ─freeze <{d}°C→ {s}\n", .{ d.name, pc.at, pc.to });
        if (d.decays_to) |to| try w.print("{s} ─decay {d} ticks→ {s}\n", .{ d.name, d.lifetime, to });
        if (d.flammable) |fl| {
            try w.print("{s} ─burn→ {s}", .{ d.name, fl.to });
            if (fl.event != .none) try w.print(" + {t} event", .{fl.event});
            if (fl.smoke) |s| try w.print(", emits {s} while burning", .{s});
            try w.writeAll("\n");
        }
        if (d.rubble) |r| try w.print("{s} ─break→ {s}\n", .{ d.name, r });
        for (d.reactions) |r| {
            try w.print("{s} + {s}", .{ d.name, r.with });
            if (r.catalyst) |k| try w.print(" (with {s})", .{k});
            try w.print(" → {s} + {s}", .{ r.self orelse d.name, r.other orelse r.with });
            if (r.event != .none) try w.print(" + {t} event", .{r.event});
            try w.writeAll("\n");
        }
    }
    try w.writeAll("```\n\n");

    // Mermaid version of the transformation edges (no reactions, to stay legible).
    try w.writeAll("```mermaid\nflowchart LR\n");
    for (set.materials[1..]) |m| {
        const d = m.def;
        if (d.melt) |pc| try w.print("    {s} -- melt --> {s}\n", .{ d.name, pc.to });
        if (d.boil) |pc| try w.print("    {s} -- boil --> {s}\n", .{ d.name, pc.to });
        if (d.freeze) |pc| try w.print("    {s} -- freeze --> {s}\n", .{ d.name, pc.to });
        if (d.decays_to) |to| if (!std.mem.eql(u8, to, "air")) try w.print("    {s} -- decay --> {s}\n", .{ d.name, to });
        if (d.flammable) |fl| try w.print("    {s} -- burn --> {s}\n", .{ d.name, fl.to });
        if (d.rubble) |r| try w.print("    {s} -- break --> {s}\n", .{ d.name, r });
    }
    try w.writeAll("```\n\n");
}

fn writeGpuLayout(w: *Io.Writer) !void {
    try w.print(
        \\## GPU table layout
        \\
        \\`MaterialGpu` (src/data/gpu_tables.zig), {d} bytes, 256 entries,
        \\std140- and std430-compatible. Every field is a `uint`; `ramp` is
        \\`uvec4 ramp[2]` holding 8 RGBA8 colors.
        \\
        \\| offset | field |
        \\|---|---|
        \\
    , .{@sizeOf(gpu.MaterialGpu)});
    const info = @typeInfo(gpu.MaterialGpu).@"struct";
    inline for (info.field_names) |name| {
        try w.print("| {d} | `{s}` |\n", .{ @offsetOf(gpu.MaterialGpu, name), name });
    }
    try w.print(
        \\
        \\`ReactionEntry`, {d} bytes, 256 × 256 entries indexed `[self * 256 + neighbor]`
        \\(std430 `uvec2`):
        \\
        \\| offset | field |
        \\|---|---|
        \\
    , .{@sizeOf(gpu.ReactionEntry)});
    const rinfo = @typeInfo(gpu.ReactionEntry).@"struct";
    inline for (rinfo.field_names) |name| {
        try w.print("| {d} | `{s}` |\n", .{ @offsetOf(gpu.ReactionEntry, name), name });
    }
}

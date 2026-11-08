//! Hot reload of the materials directory.
//!
//! `Watcher.poll` stats every `*.zon` file (name, size, mtime); when that
//! fingerprint differs from the last poll it reloads the whole directory
//! and returns fresh tables for the caller to re-upload. Polling costs one
//! directory listing plus one stat per file, so call it at most a few times
//! per second, never per tick. A failed reload keeps the fingerprint, so the
//! same broken files are reported once, not every poll; the caller keeps
//! using its previous tables until the files are fixed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const materials = @import("materials.zig");
const gpu_tables = @import("gpu_tables.zig");

/// A successful reload. The caller owns it; free with `deinit`.
pub const Reload = struct {
    set: materials.MaterialSet,
    tables: *gpu_tables.Tables,
    /// A material of the previous set is gone or has a different id. Cells
    /// already in the world now name the wrong material (or the magenta
    /// placeholder); the caller may want to warn or reset the world.
    ids_changed: bool,

    pub fn deinit(self: *Reload, gpa: Allocator) void {
        gpa.destroy(self.tables);
        self.set.deinit();
        self.* = undefined;
    }
};

pub const Watcher = struct {
    dir_path: []const u8,
    fingerprint: u64,

    /// Takes the initial fingerprint; the first `poll` reports no change
    /// unless files changed since.
    pub fn init(io: Io, dir_path: []const u8) !Watcher {
        return .{ .dir_path = dir_path, .fingerprint = try fingerprintDir(io, dir_path) };
    }

    /// Whether the directory changed since the last poll, without reloading.
    pub fn changed(self: *const Watcher, io: Io) !bool {
        return try fingerprintDir(io, self.dir_path) != self.fingerprint;
    }

    /// Returns null when nothing changed, a new `Reload` when the directory
    /// changed and loaded cleanly, or `error.InvalidMaterials` with `diag`
    /// filled when it changed and failed validation. `previous` (the set in
    /// use) is only read, to compute `ids_changed`.
    pub fn poll(
        self: *Watcher,
        io: Io,
        gpa: Allocator,
        previous: ?*const materials.MaterialSet,
        diag: *materials.Diagnostics,
    ) !?Reload {
        const fp = try fingerprintDir(io, self.dir_path);
        if (fp == self.fingerprint) return null;
        self.fingerprint = fp;
        return try loadTables(io, gpa, self.dir_path, previous, diag);
    }
};

/// Loads the directory and builds tables in one step (also used at startup).
pub fn loadTables(
    io: Io,
    gpa: Allocator,
    dir_path: []const u8,
    previous: ?*const materials.MaterialSet,
    diag: *materials.Diagnostics,
) !Reload {
    var set = try materials.loadDir(io, gpa, dir_path, diag);
    errdefer set.deinit();
    const tables = try gpu_tables.build(gpa, &set);
    return .{ .set = set, .tables = tables, .ids_changed = if (previous) |p| idsChanged(p, &set) else false };
}

/// Whether any material of `old` is missing from `new` or moved id.
pub fn idsChanged(old: *const materials.MaterialSet, new: *const materials.MaterialSet) bool {
    for (old.materials) |m| {
        const id = new.idOf(m.def.name) orelse return true;
        if (id != m.id) return true;
    }
    return false;
}

/// Order-independent hash of (name, size, mtime) over the `*.zon` files.
pub fn fingerprintDir(io: Io, dir_path: []const u8) !u64 {
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var sum: u64 = 0;
    var count: u64 = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zon")) continue;
        const st = try dir.statFile(io, entry.name, .{});
        var h: std.hash.Wyhash = .init(0);
        h.update(entry.name);
        h.update(std.mem.asBytes(&st.size));
        const ns: i128 = st.mtime.nanoseconds;
        h.update(std.mem.asBytes(&ns));
        sum +%= h.final();
        count += 1;
    }
    return sum +% count *% 0x9e3779b97f4a7c15;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

const file_a = ".{ .name = \"a\", .id = 1, .density = 5, .ramp = .{ 1, 2, 3, 4 } }";
const file_a2 = ".{ .name = \"a\", .id = 1, .density = 77, .ramp = .{ 1, 2, 3, 4 } }";
const file_b = ".{ .name = \"b\", .id = 2, .density = 6, .ramp = .{ 1, 2, 3, 4 } }";
const file_b_moved = ".{ .name = \"b\", .id = 3, .density = 6, .ramp = .{ 1, 2, 3, 4 } }";
const file_bad = ".{ .name = \"b\", .id = 2, .density = 6, .ramp = .{ 1, 2, 3, 4 }, .melt = .{ .at = 10, .to = \"zzz\" } }";

test "watcher reloads on change and keeps working after a bad edit" {
    const io = testing.io;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(path);

    try tmp.dir.writeFile(io, .{ .sub_path = "a.zon", .data = file_a });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zon", .data = file_b });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "ignored" });

    var diag: materials.Diagnostics = .init(gpa);
    defer diag.deinit();
    var current = try loadTables(io, gpa, path, null, &diag);
    defer current.deinit(gpa);
    try testing.expectEqual(@as(u32, 5), current.tables.materials[1].density);

    var w: Watcher = try .init(io, path);
    try testing.expect(try w.poll(io, gpa, &current.set, &diag) == null);

    // Content change (size differs, so this is robust to coarse mtimes).
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zon", .data = file_a2 });
    try testing.expect(try w.changed(io));
    {
        var r = (try w.poll(io, gpa, &current.set, &diag)).?;
        defer r.deinit(gpa);
        try testing.expectEqual(@as(u32, 77), r.tables.materials[1].density);
        try testing.expect(!r.ids_changed);
    }
    try testing.expect(try w.poll(io, gpa, &current.set, &diag) == null);

    // A broken edit is reported once, then not again until the next change.
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zon", .data = file_bad });
    try testing.expectError(error.InvalidMaterials, w.poll(io, gpa, &current.set, &diag));
    try testing.expect(diag.contains("b.zon: .melt.to: unknown material \"zzz\""));
    diag.clear();
    try testing.expect(try w.poll(io, gpa, &current.set, &diag) == null);

    // Fixing it reloads; moving b's id is flagged.
    try tmp.dir.writeFile(io, .{ .sub_path = "b.zon", .data = file_b_moved });
    {
        var r = (try w.poll(io, gpa, &current.set, &diag)).?;
        defer r.deinit(gpa);
        try testing.expect(r.ids_changed);
        try testing.expect(r.tables.materials[2].flags & gpu_tables.Flag.missing != 0);
        try testing.expectEqual(@as(u32, 6), r.tables.materials[3].density);
    }

    // Adding a file is a change too.
    try tmp.dir.writeFile(io, .{ .sub_path = "c.zon", .data = ".{ .name = \"c\", .density = 1, .ramp = .{ 1, 2, 3, 4 } }" });
    {
        var r = (try w.poll(io, gpa, &current.set, &diag)).?;
        defer r.deinit(gpa);
        try testing.expect(r.set.idOf("c") != null);
    }
}

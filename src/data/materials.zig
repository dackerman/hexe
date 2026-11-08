//! Material definitions: the ZON schema, the loader and its validation.
//!
//! One ZON file per material in `materials/`. The schema is documented in
//! `docs/03-materials.md`; `Def` below is its exact Zig mirror. Every field
//! has a default meaning "not in this class", so a file lists only what
//! matters. Air is material 0 and built in.
//!
//! Loading never panics on bad data: every problem is appended to a
//! `Diagnostics` list naming the file and the field, and the load returns
//! `error.InvalidMaterials` once all files have been checked.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const temperature = @import("temperature.zig");

/// Material id of air, built into the engine.
pub const air_id: u8 = 0;
/// The id space is one byte of the cell format.
pub const max_materials = 256;

// ---------------------------------------------------------------- schema

pub const Phase = enum(u8) { static = 0, powder = 1, liquid = 2, gas = 3 };
pub const Solver = enum(u8) { cellular = 0, flip = 1 };
pub const Impact = enum(u8) { none = 0, splash = 1, spray = 2, chip = 3, dent = 4, ricochet = 5 };
pub const BlastResponse = enum(u8) { fly = 0, chip = 1, @"break" = 2 };

/// Event ids appended to the GPU event queue. 0 means no event.
pub const Event = enum(u8) {
    none = 0,
    /// Gunpowder ignition: the CPU issues an explosion command next tick.
    explode = 1,
    /// A cell's `pressure_event` threshold was exceeded.
    pressure = 2,
};

/// Melt, freeze or boil rule: `at` is °C, `to` a material name.
pub const PhaseChange = struct {
    at: i32,
    to: []const u8,
};

pub const Flammable = struct {
    /// Ignites when the cell temperature exceeds this, °C.
    ignite_at: i32,
    /// Ticks from ignition to becoming `to`.
    burn_ticks: i32,
    /// Burn product.
    to: []const u8,
    /// Gas emitted while burning; null for none.
    smoke: ?[]const u8 = null,
    /// °C added to neighbors per tick while burning (on top of flame).
    heat: i32 = 0,
    /// Event appended on ignition.
    event: Event = .none,
};

pub const Glow = struct {
    /// °C where glow starts.
    from: i32,
    /// °C where glow reaches the hot end of the ramp.
    to: i32,
};

/// Effects on characters touching the material. CPU gameplay only; not in
/// the GPU table.
pub const Contact = struct {
    /// Fraction of movement speed removed, 0–1.
    slow: f32 = 0,
    drown: bool = false,
    buoyant: bool = false,
    /// Burn damage, hp per second.
    burn: f32 = 0,
    /// Corrosion damage, hp per second.
    corrode: f32 = 0,
    ignite: bool = false,
    extinguish: bool = false,
    wet: bool = false,
    strip_armor: bool = false,
    oily: bool = false,
    slippery: bool = false,
    blind: bool = false,
    bloody: bool = false,
};

pub const Reaction = struct {
    /// The neighbor material this reaction pairs with.
    with: []const u8,
    /// What this cell becomes; null = unchanged, "air" = consumed.
    self: ?[]const u8 = null,
    /// What the neighbor becomes; null = unchanged, "air" = consumed.
    other: ?[]const u8 = null,
    /// Per-tick firing chance, 1–255 (255 = always).
    chance: i32 = 255,
    /// Pair temperature bounds, °C, inclusive; the pair temperature is the
    /// mean of the two cells' temperature bytes.
    min_temp: ?i32 = null,
    max_temp: ?i32 = null,
    /// A third material that must also be adjacent.
    catalyst: ?[]const u8 = null,
    event: Event = .none,
};

/// One material file. Field order and defaults follow docs/03-materials.md.
pub const Def = struct {
    name: []const u8,
    /// Optional explicit id, 1–255. See docs/decisions/01-material-ids.md.
    id: ?i32 = null,
    phase: Phase = .static,
    solver: Solver = .cellular,
    density: i32 = 0,
    dispersion: i32 = 0,
    slide: i32 = 0,
    health: i32 = 0,
    lifetime: i32 = 0,
    decays_to: ?[]const u8 = null,
    temperature: i32 = 20,
    conductivity: i32 = 0,
    emits_heat: i32 = 0,
    melt: ?PhaseChange = null,
    freeze: ?PhaseChange = null,
    boil: ?PhaseChange = null,
    flammable: ?Flammable = null,
    conductive: bool = false,
    impact: Impact = .none,
    /// Also ricochets hitters (steel is `.impact = .dent, .ricochet = true`).
    ricochet: bool = false,
    blast_threshold: i32 = 0,
    blast_response: BlastResponse = .fly,
    /// Material that chips and blast breakage land as; null = itself.
    rubble: ?[]const u8 = null,
    drag: i32 = 0,
    /// Pressure that appends a `pressure` event; 0 = never.
    pressure_event: i32 = 0,
    on_contact: Contact = .{},
    emissive: i32 = 0,
    glow: ?Glow = null,
    translucent: bool = false,
    /// Blocks light although not solid (smoke).
    blocks_light: bool = false,
    /// Puts out burning neighbors (water).
    extinguishes: bool = false,
    /// Creation injects mass into the air field (steam).
    feeds_air: bool = false,
    /// Connectivity anchor: islands touching it never fall (bedrock).
    anchor: bool = false,
    /// 4–8 colors, 0xRRGGBB.
    ramp: []const u32,
    reactions: []const Reaction = &.{},
};

/// Air, material 0: a gas with no lifetime and density 0.
pub const air_def: Def = .{
    .name = "air",
    .id = 0,
    .phase = .gas,
    .density = 0,
    .conductivity = 8,
    .translucent = true,
    .ramp = &.{ 0x000000, 0x000000, 0x000000, 0x000000 },
};

// ------------------------------------------------------------ loaded set

pub const Material = struct {
    id: u8,
    /// Path the material was loaded from, "<builtin>" for air.
    path: []const u8,
    def: Def,
};

pub const MaterialSet = struct {
    arena: std.heap.ArenaAllocator,
    /// Sorted by id; `materials[0]` is air.
    materials: []const Material,
    /// Index into `materials` per id, or null when the id is unused.
    index_of_id: [max_materials]?u8,
    names: std.StringHashMapUnmanaged(u8),

    pub fn deinit(self: *MaterialSet) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn idOf(self: *const MaterialSet, name: []const u8) ?u8 {
        return self.names.get(name);
    }

    pub fn get(self: *const MaterialSet, id: u8) ?*const Material {
        const i = self.index_of_id[id] orelse return null;
        return &self.materials[i];
    }

    pub fn byName(self: *const MaterialSet, name: []const u8) ?*const Material {
        return self.get(self.idOf(name) orelse return null);
    }

    /// Resolves an optional reference: null means `default`.
    pub fn ref(self: *const MaterialSet, name: ?[]const u8, default: u8) u8 {
        const n = name orelse return default;
        return self.idOf(n).?; // validated at load
    }
};

// ------------------------------------------------------------ diagnostics

/// Human readable load errors, each naming a file and a field.
pub const Diagnostics = struct {
    arena: std.heap.ArenaAllocator,
    messages: std.ArrayList([]const u8) = .empty,

    pub fn init(gpa: Allocator) Diagnostics {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Diagnostics) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn clear(self: *Diagnostics) void {
        _ = self.arena.reset(.retain_capacity);
        self.messages = .empty;
    }

    pub fn add(self: *Diagnostics, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const a = self.arena.allocator();
        try self.messages.append(a, try std.fmt.allocPrint(a, fmt, args));
    }

    /// Whether any message contains `needle` (for tests).
    pub fn contains(self: *const Diagnostics, needle: []const u8) bool {
        for (self.messages.items) |m| {
            if (std.mem.indexOf(u8, m, needle) != null) return true;
        }
        return false;
    }

    pub fn format(self: *const Diagnostics, w: *Io.Writer) Io.Writer.Error!void {
        for (self.messages.items, 0..) |m, i| {
            if (i > 0) try w.writeByte('\n');
            try w.writeAll(m);
        }
    }
};

pub const LoadError = error{InvalidMaterials} || Allocator.Error;

/// A material file's path and contents.
pub const Source = struct {
    path: []const u8,
    text: []const u8,
};

// ----------------------------------------------------------------- loader

/// Reads every `*.zon` file in `dir_path` and loads them. File-system
/// errors are reported in `diag` too, naming the path.
pub fn loadDir(io: Io, gpa: Allocator, dir_path: []const u8, diag: *Diagnostics) (LoadError || error{FileSystem})!MaterialSet {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();

    const sources = readZonDir(io, sa, dir_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try diag.add("{s}: cannot read materials directory: {t}", .{ dir_path, err });
            return error.FileSystem;
        },
    };
    return loadSources(gpa, sources, diag);
}

/// Reads all `*.zon` files of a directory, sorted by name. Allocates in `a`.
pub fn readZonDir(io: Io, a: Allocator, dir_path: []const u8) ![]Source {
    var dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zon")) continue;
        try names.append(a, try a.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessString);

    const sources = try a.alloc(Source, names.items.len);
    for (names.items, sources) |name, *s| {
        s.* = .{
            .path = try std.fs.path.join(a, &.{ dir_path, name }),
            .text = try dir.readFileAlloc(io, name, a, .limited(1 << 20)),
        };
    }
    return sources;
}

fn lessString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Parses, assigns ids and validates a set of material sources.
pub fn loadSources(gpa: Allocator, sources: []const Source, diag: *Diagnostics) LoadError!MaterialSet {
    var set: MaterialSet = .{
        .arena = .init(gpa),
        .materials = &.{},
        .index_of_id = @splat(null),
        .names = .empty,
    };
    errdefer set.arena.deinit();
    const a = set.arena.allocator();
    const errors_before = diag.messages.items.len;

    // 1. Parse.
    var parsed: std.ArrayList(Material) = .empty;
    try parsed.append(a, .{ .id = air_id, .path = "<builtin>", .def = air_def });
    for (sources) |src| {
        const path = try a.dupe(u8, src.path);
        const text = try a.dupeSentinel(u8, src.text, 0);
        var zd: std.zon.parse.Diagnostics = .{ .errors = &.{} };
        const def = std.zon.parse.fromSlice(Def, .{
            .gpa = gpa,
            .arena = a,
            .source = text,
            .diagnostics = &zd,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseZon => {
                try diag.add("{f}", .{zd.fmt(path)});
                continue;
            },
        };
        try parsed.append(a, .{ .id = 0, .path = path, .def = def });
    }

    // 2. Names: match the file stem, reserved, unique.
    var keep: std.ArrayList(Material) = .empty;
    try keep.append(a, parsed.items[0]);
    for (parsed.items[1..]) |m| {
        const stem = std.fs.path.stem(m.path);
        if (!validName(m.def.name)) {
            try diag.add("{s}: .name: \"{s}\" must be lowercase letters, digits and '_'", .{ m.path, m.def.name });
            continue;
        }
        if (!std.mem.eql(u8, stem, m.def.name)) {
            try diag.add("{s}: .name: \"{s}\" does not match the file name \"{s}\"", .{ m.path, m.def.name, stem });
            continue;
        }
        if (std.mem.eql(u8, m.def.name, "air")) {
            try diag.add("{s}: .name: \"air\" is built in and cannot be defined in a file", .{m.path});
            continue;
        }
        if (set.names.get(m.def.name)) |_| {
            try diag.add("{s}: .name: duplicate material \"{s}\"", .{ m.path, m.def.name });
            continue;
        }
        try set.names.put(a, m.def.name, 0);
        try keep.append(a, m);
    }

    // 3. Ids: explicit first, then the rest by name into the lowest free ids.
    var taken: [max_materials]?usize = @splat(null); // index into keep
    taken[air_id] = 0;
    for (keep.items[1..], 1..) |*m, i| {
        const want = m.def.id orelse continue;
        if (want < 1 or want > 255) {
            try diag.add("{s}: .id: {d} out of range 1–255 (0 is air)", .{ m.path, want });
            m.def.id = null;
            continue;
        }
        const id: u8 = @intCast(want);
        if (taken[id]) |other| {
            try diag.add("{s}: .id: {d} already used by {s}", .{ m.path, want, keep.items[other].path });
            m.def.id = null;
            continue;
        }
        taken[id] = i;
        m.id = id;
    }
    {
        var unassigned: std.ArrayList(usize) = .empty;
        for (keep.items[1..], 1..) |m, i| {
            if (m.def.id == null) try unassigned.append(a, i);
        }
        std.mem.sort(usize, unassigned.items, keep.items, lessByName);
        var next: usize = 1;
        for (unassigned.items) |i| {
            while (next < max_materials and taken[next] != null) next += 1;
            if (next >= max_materials) {
                try diag.add("{s}: more than 255 materials; no id left", .{keep.items[i].path});
                break;
            }
            taken[next] = i;
            keep.items[i].id = @intCast(next);
        }
    }
    var materials: std.ArrayList(Material) = .empty;
    for (taken) |slot| {
        const i = slot orelse continue;
        try materials.append(a, keep.items[i]);
    }
    // Rebuild the name map from the materials that got an id, so a file that
    // overflowed the id space does not resolve.
    set.names.clearRetainingCapacity();
    for (materials.items, 0..) |m, i| {
        set.index_of_id[m.id] = @intCast(i);
        try set.names.put(a, m.def.name, m.id);
    }
    set.materials = materials.items;

    // 4. Per-material field validation.
    for (set.materials[1..]) |*m| try validateDef(&set, m, diag);

    // 5. Cross-material checks.
    try checkReactionPairs(&set, diag);
    try checkPhaseCycles(&set, diag);

    if (diag.messages.items.len > errors_before) return error.InvalidMaterials;
    return set;
}

fn lessByName(ms: []const Material, a: usize, b: usize) bool {
    return std.mem.lessThan(u8, ms[a].def.name, ms[b].def.name);
}

fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| switch (c) {
        'a'...'z', '0'...'9', '_' => {},
        else => return false,
    };
    return true;
}

// ------------------------------------------------------------- validation

const Checker = struct {
    set: *const MaterialSet,
    m: *const Material,
    diag: *Diagnostics,

    fn fail(c: Checker, field: []const u8, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const a = c.diag.arena.allocator();
        const msg = try std.fmt.allocPrint(a, fmt, args);
        try c.diag.add("{s}: .{s}: {s}", .{ c.m.path, field, msg });
    }

    fn range(c: Checker, field: []const u8, v: i32, lo: i32, hi: i32) Allocator.Error!void {
        if (v < lo or v > hi) try c.fail(field, "{d} out of range {d}–{d}", .{ v, lo, hi });
    }

    fn temp(c: Checker, field: []const u8, v: i32) Allocator.Error!void {
        if (!temperature.inRange(v))
            try c.fail(field, "{d} °C out of range {d}–{d}", .{ v, temperature.min_celsius, temperature.max_celsius });
    }

    fn name(c: Checker, field: []const u8, n: []const u8) Allocator.Error!void {
        if (c.set.idOf(n) == null) try c.fail(field, "unknown material \"{s}\"", .{n});
    }

    fn onlyFor(c: Checker, field: []const u8, set_: bool, ok: bool, what: []const u8) Allocator.Error!void {
        if (set_ and !ok) try c.fail(field, "only applies to {s} materials, this is {t}", .{ what, c.m.def.phase });
    }
};

fn validateDef(set: *const MaterialSet, m: *const Material, diag: *Diagnostics) Allocator.Error!void {
    const c: Checker = .{ .set = set, .m = m, .diag = diag };
    const d = m.def;
    const liquid_or_gas = d.phase == .liquid or d.phase == .gas;

    try c.range("density", d.density, 1, 65535);
    try c.range("dispersion", d.dispersion, 0, 8);
    try c.onlyFor("dispersion", d.dispersion != 0, liquid_or_gas, "liquid and gas");
    try c.range("slide", d.slide, 0, 255);
    try c.onlyFor("slide", d.slide != 0, d.phase == .powder, "powder");
    try c.onlyFor("solver", d.solver != .cellular, d.phase == .liquid, "liquid");
    try c.range("health", d.health, 0, 255);
    try c.range("lifetime", d.lifetime, 0, 65535);
    if (d.lifetime > 0 and d.decays_to == null)
        try c.fail("decays_to", "required when .lifetime is set", .{});
    if (d.lifetime == 0 and d.decays_to != null)
        try c.fail("decays_to", "set but .lifetime is 0, so it never decays", .{});
    if (d.decays_to) |n| try c.name("decays_to", n);
    if (d.lifetime > 0 and d.health > 0)
        try c.fail("lifetime", "health and lifetime both use the state byte; set only one", .{});
    try c.temp("temperature", d.temperature);
    try c.range("conductivity", d.conductivity, 0, 255);
    try c.range("emits_heat", d.emits_heat, 0, 2040);

    inline for (.{ "melt", "freeze", "boil" }) |f| {
        if (@field(d, f)) |pc| {
            try c.temp(f ++ ".at", pc.at);
            try c.name(f ++ ".to", pc.to);
            if (std.mem.eql(u8, pc.to, d.name)) try c.fail(f ++ ".to", "turns into itself", .{});
        }
    }
    if (d.melt) |pc| if (temperature.toByte(pc.at) == 255)
        try c.fail("melt.at", "{d} °C is the top of the range and can never be exceeded", .{pc.at});
    if (d.boil) |pc| if (temperature.toByte(pc.at) == 255)
        try c.fail("boil.at", "{d} °C is the top of the range and can never be exceeded", .{pc.at});
    if (d.freeze) |pc| if (temperature.toByte(pc.at) == 0)
        try c.fail("freeze.at", "{d} °C is the bottom of the range and can never be undercut", .{pc.at});
    if (d.melt != null and d.boil != null and
        temperature.toByte(d.boil.?.at) <= temperature.toByte(d.melt.?.at))
        try c.fail("boil.at", "must be above .melt.at", .{});
    if (d.freeze) |fz| {
        const fb = temperature.toByte(fz.at);
        inline for (.{ "melt", "boil" }) |f| {
            if (@field(d, f)) |up| if (fb > temperature.toByte(up.at) + 1)
                try c.fail("freeze.at", "{d} °C overlaps ." ++ f ++ ".at {d} °C: both would fire in between", .{ fz.at, up.at });
        }
    }

    if (d.flammable) |fl| {
        try c.temp("flammable.ignite_at", fl.ignite_at);
        if (temperature.toByte(fl.ignite_at) == 255)
            try c.fail("flammable.ignite_at", "{d} °C can never be exceeded", .{fl.ignite_at});
        try c.range("flammable.burn_ticks", fl.burn_ticks, 1, 65535);
        try c.name("flammable.to", fl.to);
        if (fl.smoke) |s| try c.name("flammable.smoke", s);
        try c.range("flammable.heat", fl.heat, 0, 2040);
        if (d.health == 0 and d.lifetime > 0)
            try c.fail("flammable", "burning without health uses the state byte, which .lifetime already uses", .{});
    }

    if (d.impact == .ricochet and d.ricochet)
        try c.fail("ricochet", "redundant with .impact = .ricochet", .{});
    try c.range("blast_threshold", d.blast_threshold, 0, 255);
    if (d.rubble) |r| try c.name("rubble", r);
    try c.range("drag", d.drag, 0, 255);
    try c.range("pressure_event", d.pressure_event, 0, 255);
    try c.range("emissive", d.emissive, 0, 255);
    if (d.glow) |g| {
        try c.temp("glow.from", g.from);
        try c.temp("glow.to", g.to);
        if (g.from >= g.to) try c.fail("glow", ".from must be below .to", .{});
    }
    if (d.on_contact.slow < 0 or d.on_contact.slow > 1)
        try c.fail("on_contact.slow", "{d} out of range 0–1", .{d.on_contact.slow});
    if (d.on_contact.burn < 0) try c.fail("on_contact.burn", "must not be negative", .{});
    if (d.on_contact.corrode < 0) try c.fail("on_contact.corrode", "must not be negative", .{});

    if (d.ramp.len < 4 or d.ramp.len > 8)
        try c.fail("ramp", "has {d} colors, needs 4–8", .{d.ramp.len});
    for (d.ramp, 0..) |rgb, i| {
        if (rgb > 0xffffff) try c.fail("ramp", "color {d} (0x{x}) is not 0xRRGGBB", .{ i, rgb });
    }

    var buf: [64]u8 = undefined;
    for (d.reactions, 0..) |r, i| {
        const fld = std.fmt.bufPrint(&buf, "reactions[{d}]", .{i}) catch "reactions";
        const rc: Checker = c;
        if (set.idOf(r.with) == null) {
            try rc.fail(fld, ".with: unknown material \"{s}\"", .{r.with});
        }
        if (r.self) |n| if (set.idOf(n) == null) try rc.fail(fld, ".self: unknown material \"{s}\"", .{n});
        if (r.other) |n| if (set.idOf(n) == null) try rc.fail(fld, ".other: unknown material \"{s}\"", .{n});
        if (r.catalyst) |n| if (set.idOf(n) == null) try rc.fail(fld, ".catalyst: unknown material \"{s}\"", .{n});
        if (r.chance < 1 or r.chance > 255) try rc.fail(fld, ".chance: {d} out of range 1–255", .{r.chance});
        if (r.min_temp) |t| if (!temperature.inRange(t)) try rc.fail(fld, ".min_temp: {d} °C out of range", .{t});
        if (r.max_temp) |t| if (!temperature.inRange(t)) try rc.fail(fld, ".max_temp: {d} °C out of range", .{t});
        if (r.min_temp != null and r.max_temp != null and r.min_temp.? > r.max_temp.?)
            try rc.fail(fld, ".min_temp is above .max_temp", .{});
        if (r.self == null and r.other == null and r.event == .none)
            try rc.fail(fld, "has no effect: .self, .other and .event are all unset", .{});
        if (std.mem.eql(u8, r.with, d.name) and !optEql(r.self, r.other))
            try rc.fail(fld, "a reaction with itself must have .self equal to .other", .{});
    }
}

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// One table entry per unordered pair: a pair declared twice (in either
/// file) is an error naming both places.
fn checkReactionPairs(set: *const MaterialSet, diag: *Diagnostics) Allocator.Error!void {
    const Where = struct { path: []const u8, index: usize };
    var seen: std.AutoHashMapUnmanaged(u16, Where) = .empty;
    const a = diag.arena.allocator();
    for (set.materials[1..]) |m| {
        for (m.def.reactions, 0..) |r, i| {
            const other = set.idOf(r.with) orelse continue;
            const lo = @min(m.id, other);
            const hi = @max(m.id, other);
            const key = @as(u16, lo) << 8 | hi;
            const gop = try seen.getOrPut(a, key);
            if (gop.found_existing) {
                try diag.add("{s}: .reactions[{d}]: pair {s} + {s} already defined at {s} .reactions[{d}]", .{
                    m.path, i, m.def.name, r.with, gop.value_ptr.path, gop.value_ptr.index,
                });
            } else gop.value_ptr.* = .{ .path = m.path, .index = i };
        }
    }
}

/// Phase changes fire on the cell's own temperature byte: melt and boil
/// when `t > at`, freeze when `t < at` (strict on both sides, so ice
/// melting "at 0" and water freezing "at 0" are both stable at exactly
/// 0 °C). A chain of phase changes that returns to its start with every
/// step enabled at one common temperature would flip every tick; reject it.
fn checkPhaseCycles(set: *const MaterialSet, diag: *Diagnostics) Allocator.Error!void {
    var reported: [max_materials]bool = @splat(false);
    var t: u16 = 0;
    while (t <= 255) : (t += 1) {
        const tb: u8 = @intCast(t);
        for (set.materials) |start| {
            if (reported[start.id]) continue;
            var path: [max_materials]u8 = undefined;
            var on_path: [max_materials]bool = @splat(false);
            var len: usize = 0;
            var cur: u8 = start.id;
            while (true) {
                if (on_path[cur]) {
                    // Cycle from first occurrence of cur.
                    const first = std.mem.indexOfScalar(u8, path[0..len], cur).?;
                    const cycle = path[first..len];
                    var any_reported = false;
                    for (cycle) |id| any_reported = any_reported or reported[id];
                    if (!any_reported) {
                        var msg: Io.Writer.Allocating = .init(diag.arena.allocator());
                        for (cycle) |id| msg.writer.print("{s} -> ", .{set.get(id).?.def.name}) catch return error.OutOfMemory;
                        msg.writer.print("{s}", .{set.get(cur).?.def.name}) catch return error.OutOfMemory;
                        const m = set.get(cycle[0]).?;
                        try diag.add("{s}: .melt/.freeze/.boil: phase changes {s} all fire at {d} °C and would flip every tick", .{
                            m.path, msg.written(), temperature.toCelsius(tb),
                        });
                        for (cycle) |id| reported[id] = true;
                    }
                    break;
                }
                on_path[cur] = true;
                path[len] = cur;
                len += 1;
                cur = activeTransition(set, cur, tb) orelse break;
            }
        }
    }
}

/// The phase change of material `id` active at temperature byte `t`, if any.
/// Boil takes precedence over melt; freeze cannot overlap either (validated).
pub fn activeTransition(set: *const MaterialSet, id: u8, t: u8) ?u8 {
    const d = set.get(id).?.def;
    if (d.boil) |pc| if (t > temperature.toByte(pc.at)) return set.idOf(pc.to);
    if (d.melt) |pc| if (t > temperature.toByte(pc.at)) return set.idOf(pc.to);
    if (d.freeze) |pc| if (t < temperature.toByte(pc.at)) return set.idOf(pc.to);
    return null;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;
const build_options = @import("build_options");

fn expectLoadError(sources: []const Source, needle: []const u8) !void {
    var diag: Diagnostics = .init(testing.allocator);
    defer diag.deinit();
    var set = loadSources(testing.allocator, sources, &diag) catch |err| {
        try testing.expectEqual(error.InvalidMaterials, err);
        if (!diag.contains(needle)) {
            std.debug.print("expected a diagnostic containing \"{s}\", got:\n{f}\n", .{ needle, diag });
            return error.TestUnexpectedResult;
        }
        return;
    };
    set.deinit();
    return error.TestExpectedError;
}

const ramp4 = ".ramp = .{ 0x101010, 0x202020, 0x303030, 0x404040 }";

test "load the shipped materials directory" {
    var diag: Diagnostics = .init(testing.allocator);
    defer diag.deinit();
    var set = loadDir(testing.io, testing.allocator, build_options.materials_dir, &diag) catch |err| {
        std.debug.print("{f}\n", .{diag});
        return err;
    };
    defer set.deinit();
    // Air plus the 30 version one materials.
    try testing.expectEqual(@as(usize, 31), set.materials.len);
    try testing.expectEqual(air_id, set.idOf("air").?);
    const expected = [_][]const u8{
        "bedrock", "stone",       "concrete", "steel",    "wood",   "charcoal",     "glass",
        "ice",     "sand",        "dirt",     "gravel",   "rubble", "ash",          "gunpowder",
        "water",   "lava",        "oil",      "acid",     "mud",    "molten_glass", "molten_steel",
        "blood",   "steam",       "smoke",    "acid_gas", "flame",  "moss",         "flesh",
        "bone",    "blood_crust",
    };
    for (expected) |n| {
        if (set.idOf(n) == null) {
            std.debug.print("missing material {s}\n", .{n});
            return error.TestUnexpectedResult;
        }
    }
    // Shipped ids are the name-sorted order (docs/decisions/01-material-ids.md).
    for (set.materials[1..], 1..) |m, i| {
        try testing.expectEqual(@as(u8, @intCast(i)), m.id);
        if (i > 1) try testing.expect(std.mem.lessThan(u8, set.materials[i - 1].def.name, m.def.name));
    }
    try testing.expectEqual(Phase.liquid, set.byName("water").?.def.phase);
    try testing.expectEqual(Solver.flip, set.byName("water").?.def.solver);
}

test "minimal material loads and gets the first free id" {
    var diag: Diagnostics = .init(testing.allocator);
    defer diag.deinit();
    var set = try loadSources(testing.allocator, &.{
        .{ .path = "m/b.zon", .text = ".{ .name = \"b\", .density = 5, " ++ ramp4 ++ " }" },
        .{ .path = "m/a.zon", .text = ".{ .name = \"a\", .id = 1, .density = 5, " ++ ramp4 ++ " }" },
        .{ .path = "m/c.zon", .text = ".{ .name = \"c\", .density = 5, " ++ ramp4 ++ " }" },
    }, &diag);
    defer set.deinit();
    try testing.expectEqual(@as(u8, 1), set.idOf("a").?);
    try testing.expectEqual(@as(u8, 2), set.idOf("b").?);
    try testing.expectEqual(@as(u8, 3), set.idOf("c").?);

    var set2 = try loadSources(testing.allocator, &.{
        .{ .path = "m/z.zon", .text = ".{ .name = \"z\", .id = 1, .density = 5, " ++ ramp4 ++ " }" },
        .{ .path = "m/a.zon", .text = ".{ .name = \"a\", .density = 5, " ++ ramp4 ++ " }" },
    }, &diag);
    defer set2.deinit();
    try testing.expectEqual(@as(u8, 1), set2.idOf("z").?);
    try testing.expectEqual(@as(u8, 2), set2.idOf("a").?);
}

test "unknown material names are rejected with file and field" {
    try expectLoadError(&.{
        .{ .path = "m/a.zon", .text = ".{ .name = \"a\", .density = 5, .melt = .{ .at = 100, .to = \"nope\" }, " ++ ramp4 ++ " }" },
    }, "m/a.zon: .melt.to: unknown material \"nope\"");
    try expectLoadError(&.{
        .{ .path = "m/a.zon", .text = ".{ .name = \"a\", .density = 5, " ++ ramp4 ++ ", .reactions = .{ .{ .with = \"ghost\", .self = \"air\" } } }" },
    }, "m/a.zon: .reactions[0]: .with: unknown material \"ghost\"");
    try expectLoadError(&.{
        .{ .path = "m/a.zon", .text = ".{ .name = \"a\", .density = 5, .lifetime = 5, .decays_to = \"x\", " ++ ramp4 ++ " }" },
    }, "m/a.zon: .decays_to: unknown material \"x\"");
}

test "missing ramp and bad ramps are rejected" {
    try expectLoadError(&.{
        .{ .path = "m/a.zon", .text = ".{ .name = \"a\", .density = 5 }" },
    }, "missing required field ramp");
    try expectLoadError(&.{
        .{ .path = "m/a.zon", .text = ".{ .name = \"a\", .density = 5, .ramp = .{ 1, 2, 3 } }" },
    }, "m/a.zon: .ramp: has 3 colors, needs 4–8");
    try expectLoadError(&.{
        .{ .path = "m/a.zon", .text = ".{ .name = \"a\", .density = 5, .ramp = .{ 1, 2, 3, 0x1000000 } }" },
    }, "m/a.zon: .ramp: color 3");
}

test "out of range values are rejected" {
    try expectLoadError(&.{
        .{ .path = "m/a.zon", .text = ".{ .name = \"a\", .density = 5, .conductivity = 300, " ++ ramp4 ++ " }" },
    }, "m/a.zon: .conductivity: 300 out of range 0–255");
    try expectLoadError(&.{
        .{ .path = "m/a.zon", .text = ".{ .name = \"a\", .density = 5, .temperature = 2500, " ++ ramp4 ++ " }" },
    }, "m/a.zon: .temperature: 2500 °C out of range");
    try expectLoadError(&.{
        .{ .path = "m/a.zon", .text = ".{ .name = \"a\", .density = 5, .slide = 10, " ++ ramp4 ++ " }" },
    }, "m/a.zon: .slide: only applies to powder");
    try expectLoadError(&.{
        .{ .path = "m/a.zon", .text = ".{ .name = \"a\", .id = 0, .density = 5, " ++ ramp4 ++ " }" },
    }, "m/a.zon: .id: 0 out of range");
    try expectLoadError(&.{
        .{ .path = "m/a.zon", .text = ".{ .name = \"a\", .density = 5, " ++ ramp4 ++ ", .reactions = .{ .{ .with = \"air\", .self = \"air\", .chance = 0 } } }" },
    }, "m/a.zon: .reactions[0]: .chance: 0 out of range 1–255");
}

test "schema typos are rejected by the parser with location" {
    try expectLoadError(&.{
        .{ .path = "m/a.zon", .text = ".{ .name = \"a\", .densty = 5, " ++ ramp4 ++ " }" },
    }, "m/a.zon:1:");
}

test "name must match file and be unique and not air" {
    try expectLoadError(&.{
        .{ .path = "m/a.zon", .text = ".{ .name = \"b\", .density = 5, " ++ ramp4 ++ " }" },
    }, "does not match the file name");
    try expectLoadError(&.{
        .{ .path = "m/air.zon", .text = ".{ .name = \"air\", .density = 5, " ++ ramp4 ++ " }" },
    }, "built in");
    try expectLoadError(&.{
        .{ .path = "m/a.zon", .text = ".{ .name = \"a\", .id = 3, .density = 5, " ++ ramp4 ++ " }" },
        .{ .path = "m/b.zon", .text = ".{ .name = \"b\", .id = 3, .density = 5, " ++ ramp4 ++ " }" },
    }, "m/b.zon: .id: 3 already used by m/a.zon");
}

test "phase change ping-pong is rejected" {
    // a melts to b above 100 °C; b freezes back below 300 °C: both fire in between.
    try expectLoadError(&.{
        .{ .path = "m/a.zon", .text = ".{ .name = \"a\", .density = 5, .melt = .{ .at = 100, .to = \"b\" }, " ++ ramp4 ++ " }" },
        .{ .path = "m/b.zon", .text = ".{ .name = \"b\", .phase = .liquid, .density = 5, .freeze = .{ .at = 300, .to = \"a\" }, " ++ ramp4 ++ " }" },
    }, "would flip every tick");
    // Three-step chain: a -melt-> b -boil-> c -melt-> a, all above 200 °C.
    try expectLoadError(&.{
        .{ .path = "m/a.zon", .text = ".{ .name = \"a\", .density = 5, .melt = .{ .at = 100, .to = \"b\" }, " ++ ramp4 ++ " }" },
        .{ .path = "m/b.zon", .text = ".{ .name = \"b\", .density = 5, .boil = .{ .at = 150, .to = \"c\" }, " ++ ramp4 ++ " }" },
        .{ .path = "m/c.zon", .text = ".{ .name = \"c\", .density = 5, .melt = .{ .at = 200, .to = \"a\" }, " ++ ramp4 ++ " }" },
    }, "a -> b -> c -> a");
    // Same thresholds with hysteresis (freeze at the same °C as melt) load fine.
    var diag: Diagnostics = .init(testing.allocator);
    defer diag.deinit();
    var set = try loadSources(testing.allocator, &.{
        .{ .path = "m/a.zon", .text = ".{ .name = \"a\", .density = 5, .melt = .{ .at = 0, .to = \"b\" }, " ++ ramp4 ++ " }" },
        .{ .path = "m/b.zon", .text = ".{ .name = \"b\", .phase = .liquid, .density = 5, .freeze = .{ .at = 0, .to = \"a\" }, " ++ ramp4 ++ " }" },
    }, &diag);
    set.deinit();
}

test "overlapping melt and freeze within one material is rejected" {
    try expectLoadError(&.{
        .{ .path = "m/a.zon", .text = ".{ .name = \"a\", .density = 5, .melt = .{ .at = 100, .to = \"air\" }, .freeze = .{ .at = 200, .to = \"air\" }, " ++ ramp4 ++ " }" },
    }, "m/a.zon: .freeze.at: 200 °C overlaps .melt.at");
}

test "duplicate reaction pair is rejected naming both files" {
    try expectLoadError(&.{
        .{ .path = "m/a.zon", .text = ".{ .name = \"a\", .density = 5, " ++ ramp4 ++ ", .reactions = .{ .{ .with = \"b\", .self = \"air\" } } }" },
        .{ .path = "m/b.zon", .text = ".{ .name = \"b\", .density = 5, " ++ ramp4 ++ ", .reactions = .{ .{ .with = \"a\", .other = \"air\" } } }" },
    }, "m/b.zon: .reactions[0]: pair b + a already defined at m/a.zon .reactions[0]");
}

test "all errors in a set are reported, not just the first" {
    var diag: Diagnostics = .init(testing.allocator);
    defer diag.deinit();
    const r = loadSources(testing.allocator, &.{
        .{ .path = "m/a.zon", .text = ".{ .name = \"a\", .density = 0, " ++ ramp4 ++ " }" },
        .{ .path = "m/b.zon", .text = ".{ .name = \"b\", .density = 5, .drag = -1, " ++ ramp4 ++ " }" },
    }, &diag);
    try testing.expectError(error.InvalidMaterials, r);
    try testing.expect(diag.contains("m/a.zon: .density"));
    try testing.expect(diag.contains("m/b.zon: .drag"));
}

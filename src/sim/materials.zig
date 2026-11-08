//! The engine's view of the material and reaction tables. The data layer
//! (src/data, ZON files in `materials/`) is the single source: it validates
//! the files, assigns ids and packs `MaterialGpu` and `ReactionEntry`
//! (src/data/gpu_tables.zig). This file loads a `Library` (set + tables),
//! resolves the ids scenes and tools use by name, and holds the small
//! builtin fallback set for tests that run without the materials directory
//! (docs/decisions/40-reactions-material-table.md).
//!
//! GPU layout: `MaterialGpu`, 192 bytes per material, std430, declared in
//! shaders/common.glsl from `gpu_tables.glsl_material_struct` (a test checks
//! the text). Temperatures are temperature bytes (degrees C = 8*t - 40);
//! material references are ids where "no transition" is the material's own
//! id; colors are RGBA8 with R in the low byte.
const std = @import("std");
const data = @import("data");
const cell = @import("cell.zig");

pub const gpu_tables = data.gpu_tables;
pub const MaterialGpu = gpu_tables.MaterialGpu;
pub const ReactionEntry = gpu_tables.ReactionEntry;
pub const Tables = gpu_tables.Tables;
pub const Flag = gpu_tables.Flag;
pub const ReactionFlag = gpu_tables.ReactionFlag;
pub const MaterialSet = data.materials.MaterialSet;
pub const Diagnostics = data.materials.Diagnostics;
pub const Phase = data.materials.Phase;
pub const Impact = data.materials.Impact;
pub const BlastResponse = data.materials.BlastResponse;

pub const count = data.materials.max_materials;
pub const air: u8 = data.materials.air_id;
pub const ramp_max = 8;
pub const sort_key_air = gpu_tables.sort_key_air;
pub const sort_key_dense_base = gpu_tables.sort_key_dense_base;
pub const sort_key_static = gpu_tables.sort_key_static;

/// Default materials directory, relative to the working directory.
pub const default_dir = "materials";

/// A loaded material set and its packed GPU tables.
pub const Library = struct {
    set: MaterialSet,
    tables: *Tables,

    /// Load and validate every `*.zon` file in `dir`. On failure `diag`
    /// names the files and fields.
    pub fn loadDir(io: std.Io, gpa: std.mem.Allocator, dir: []const u8, diag: *Diagnostics) !Library {
        var r = try data.reload.loadTables(io, gpa, dir, null, diag);
        _ = &r;
        return .{ .set = r.set, .tables = r.tables };
    }

    /// The builtin fallback set (air, stone, sand, water, smoke, bedrock),
    /// for tests without the materials directory. Same ids as the shipped
    /// files.
    pub fn builtin(gpa: std.mem.Allocator) !Library {
        var diag: Diagnostics = .init(gpa);
        defer diag.deinit();
        var set = data.materials.loadSources(gpa, &builtin_sources, &diag) catch |err| {
            std.debug.print("builtin materials: {f}\n", .{diag});
            return err;
        };
        errdefer set.deinit();
        return .{ .set = set, .tables = try gpu_tables.build(gpa, &set) };
    }

    pub fn deinit(self: *Library, gpa: std.mem.Allocator) void {
        gpa.destroy(self.tables);
        self.set.deinit();
        self.* = undefined;
    }

    pub fn id(self: *const Library, material_name: []const u8) ?u8 {
        return self.set.idOf(material_name);
    }

    pub fn name(self: *const Library, material: u8) []const u8 {
        const m = self.set.get(material) orelse return "?";
        return m.def.name;
    }

    /// Number of ids in use (highest id + 1).
    pub fn len(self: *const Library) u32 {
        const ms = self.set.materials;
        return @as(u32, ms[ms.len - 1].id) + 1;
    }

    pub fn ids(self: *const Library) Ids {
        return Ids.resolve(&self.set);
    }
};

/// The cell an empty world is made of: air at its spawn temperature and
/// state. A world of zero words would be air at -40 C, a heat sink that
/// keeps every tile next to anything painted awake forever.
pub fn ambientAir(tables: *const Tables) u32 {
    const a = &tables.materials[air];
    return cell.make(air, a.temperature, a.state_init, 0, 0);
}

/// Material ids the engine's scenes and tools refer to by name. A material
/// missing from the set resolves to air, so a scene drawn with a reduced set
/// paints nothing where it would have used it.
pub const Ids = struct {
    air: u8 = air,
    stone: u8 = air,
    sand: u8 = air,
    water: u8 = air,
    smoke: u8 = air,
    bedrock: u8 = air,
    lava: u8 = air,
    wood: u8 = air,
    oil: u8 = air,
    flame: u8 = air,
    steel: u8 = air,
    ice: u8 = air,
    gunpowder: u8 = air,
    dirt: u8 = air,
    glass: u8 = air,
    molten_glass: u8 = air,
    steam: u8 = air,
    concrete: u8 = air,
    gravel: u8 = air,

    pub fn resolve(set: *const MaterialSet) Ids {
        var r: Ids = .{};
        inline for (@typeInfo(Ids).@"struct".field_names) |f| {
            @field(r, f) = set.idOf(f) orelse air;
        }
        return r;
    }
};

fn src(comptime name: []const u8, comptime body: []const u8) data.materials.Source {
    return .{ .path = "<builtin>/" ++ name ++ ".zon", .text = ".{ .name = \"" ++ name ++ "\", " ++ body ++ " }" };
}

/// Fallback set: values copied from the shipped files (ids included), minus
/// reactions and transitions that name materials not in this set.
const builtin_sources = [_]data.materials.Source{
    src("bedrock", ".id = 4, .phase = .static, .density = 1000, .conductivity = 30, .impact = .ricochet, .anchor = true, .ramp = .{ 0x1c1b22, 0x26252e, 0x302e3a, 0x3a3846, 0x221f29 }"),
    src("sand", ".id = 24, .phase = .powder, .density = 150, .slide = 200, .conductivity = 25, .impact = .spray, .blast_threshold = 20, .drag = 60, .ramp = .{ 0xd9b464, 0xe6c47a, 0xc9a052, 0xf0d48e, 0xbd9446 }"),
    src("smoke", ".id = 25, .phase = .gas, .density = 8, .dispersion = 4, .lifetime = 1200, .decays_to = \"air\", .conductivity = 10, .blocks_light = true, .drag = 255, .translucent = true, .ramp = .{ 0x3a3a3c, 0x4a4a4d, 0x58585c, 0x2e2e30 }"),
    src("stone", ".id = 28, .phase = .static, .density = 300, .health = 200, .conductivity = 40, .impact = .chip, .blast_threshold = 200, .blast_response = .@\"break\", .drag = 20, .ramp = .{ 0x5e5a56, 0x6c6762, 0x7a746e, 0x524e4a, 0x87807a, 0x45423f }"),
    src("water", ".id = 29, .phase = .liquid, .density = 100, .dispersion = 5, .conductivity = 60, .conductive = true, .extinguishes = true, .impact = .splash, .blast_threshold = 10, .drag = 200, .translucent = true, .ramp = .{ 0x1a3a6b, 0x215091, 0x2a66b5, 0x3a7ad0, 0x2459a0 }"),
};

test "builtin set loads with the shipped ids" {
    var lib = try Library.builtin(std.testing.allocator);
    defer lib.deinit(std.testing.allocator);
    const i = lib.ids();
    try std.testing.expectEqual(@as(u8, 0), i.air);
    try std.testing.expectEqual(@as(u8, 28), i.stone);
    try std.testing.expectEqual(@as(u8, 24), i.sand);
    try std.testing.expectEqual(@as(u8, 29), i.water);
    try std.testing.expectEqual(@as(u8, 25), i.smoke);
    try std.testing.expectEqual(@as(u8, 0), i.lava); // not in the builtin set
    try std.testing.expectEqual(@as(u32, 30), lib.len());
    try std.testing.expectEqual(sort_key_static, lib.tables.materials[i.stone].sort_key);
}

test "common.glsl declares MaterialGpu from the data layer" {
    const glsl = @embedFile("common_glsl");
    if (std.mem.indexOf(u8, glsl, gpu_tables.glsl_material_struct) == null) {
        std.debug.print("shaders/common.glsl must contain gpu_tables.glsl_material_struct verbatim:\n{s}\n", .{gpu_tables.glsl_material_struct});
        return error.TestUnexpectedResult;
    }
}

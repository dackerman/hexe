//! Data layer: material definitions, GPU tables, hot reload, scenarios.
//! Import as the `data` module.

pub const temperature = @import("temperature.zig");
pub const materials = @import("materials.zig");
pub const gpu_tables = @import("gpu_tables.zig");
pub const reload = @import("reload.zig");
pub const scenario = @import("scenario.zig");

test {
    _ = temperature;
    _ = materials;
    _ = gpu_tables;
    _ = reload;
    _ = scenario;
}

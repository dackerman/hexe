const std = @import("std");

pub fn main() !void {
    std.debug.print("hexe: nothing here yet\n", .{});
}

test "skeleton" {
    try std.testing.expect(true);
}

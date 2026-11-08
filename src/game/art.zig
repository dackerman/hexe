//! Gameplay sprites (sRGB RGBA8, R in the low byte), compiled from ASCII
//! art with `sprites.parseBitmap` and uploaded into the renderer's atlas by
//! `Art.upload`. All face right; the renderer mirrors them.
const std = @import("std");
const sprites = @import("../render/sprites.zig");
const gpu = @import("../gpu/gpu.zig");

pub const witch_w = 12;
pub const witch_h = 30;

const witch_palette = [_]struct { u8, u32 }{
    .{ 'h', 0x2a1f3d }, // hat
    .{ 'H', 0xc8a040 }, // hat band
    .{ 'r', 0xb8442a }, // hair
    .{ 's', 0xe0b694 }, // skin
    .{ 'e', 0x30d0a0 }, // eye
    .{ 'c', 0x4b2f6e }, // cloak
    .{ 'C', 0x37224f }, // cloak shade
    .{ 'b', 0xc8a040 }, // buckle
    .{ 'k', 0x6a4a2a }, // wand
    .{ 'w', 0xa0e8ff }, // wand tip
    .{ 'p', 0x2b2230 }, // boots
};

const witch_head = [_][]const u8{
    ".....hh.....",
    "....hhh.....",
    "....hhhh....",
    "...hhhhh....",
    "...hhhhhh...",
    "..hhHHHhh...",
    "hhhhhhhhhhh.",
    ".hhhhhhhhh..",
    "..rssss.....",
    "..rssess....",
    "..rsssss....",
    "..rr.ss.....",
};

const witch_arm_idle = [_][]const u8{
    "..rcccc...w.",
    "..cccccc..k.",
    ".ccccccc.k..",
    ".cccccccsk..",
    ".cccccc.....",
};

const witch_arm_cast = [_][]const u8{
    "..rcccc.....",
    "..ccccccsskw",
    ".cccccccc...",
    ".ccccccc....",
    ".cccccc.....",
};

const witch_body = [_][]const u8{
    ".cccbccc....",
    ".cccbccc....",
    ".ccccccc....",
    "cccccccc....",
    "Cccccccc....",
    "CCcccccc....",
    "CCcccccccc..",
    "CCCccccccc..",
};

const witch_legs_stand = [_][]const u8{
    "CCCcccccccc.",
    "CCCCcccccccc",
    "...pp..pp...",
    "...pp..pp...",
    "..ppp..ppp..",
};

const witch_legs_stride = [_][]const u8{
    "CCCcccccccc.",
    ".CCCccccccc.",
    "..pp....pp..",
    ".pp......pp.",
    ".ppp.....ppp",
};

pub const witch_idle = sprites.parseBitmap(witch_w, witch_h, &(witch_head ++ witch_arm_idle ++ witch_body ++ witch_legs_stand), &witch_palette);
pub const witch_walk = sprites.parseBitmap(witch_w, witch_h, &(witch_head ++ witch_arm_idle ++ witch_body ++ witch_legs_stride), &witch_palette);
pub const witch_cast = sprites.parseBitmap(witch_w, witch_h, &(witch_head ++ witch_arm_cast ++ witch_body ++ witch_legs_stand), &witch_palette);
pub const witch_cast_walk = sprites.parseBitmap(witch_w, witch_h, &(witch_head ++ witch_arm_cast ++ witch_body ++ witch_legs_stride), &witch_palette);

pub const walker_w = 20;
pub const walker_h = 28;

const walker_palette = [_]struct { u8, u32 }{
    .{ 'g', 0x6f8a5a }, // skin
    .{ 'G', 0x4f6640 }, // skin shade
    .{ 'r', 0xff3a20 }, // eye
    .{ 'm', 0x2a1a1a }, // mouth
    .{ 't', 0x5a4a3a }, // rags
    .{ 'T', 0x463828 }, // rag shade
    .{ 'l', 0x3a3040 }, // trousers
    .{ 'b', 0x241c1c }, // feet
};

const walker_top = [_][]const u8{
    "......gggggg........",
    ".....gggggggg.......",
    ".....ggrgggrgg......",
    ".....gggggggg.......",
    "......gmmmmg........",
    ".......gggg.........",
    "....tttttttttt......",
    "...tttttttttttt.....",
    "..gttttTTttttttg....",
    "..gtttttTTtttttgg...",
    "..ggtttttTTttttgg...",
    "..gg.tttttttttt.gg..",
    "..gg.tttttttttt.gg..",
    "..gg.TtttttttTt..gg.",
    "..gg.tttttttttt..gg.",
    ".ggg.tttttttttt..ggg",
    ".GG..llllllllll...GG",
    ".....llllllllll.....",
};

const walker_legs_a = [_][]const u8{
    ".....llll..llll.....",
    ".....lll....lll.....",
    ".....lll....lll.....",
    ".....ggg....ggg.....",
    ".....ggg....ggg.....",
    ".....ggg....ggg.....",
    "....gggg....gggg....",
    "....bbbb....bbbb....",
    "...bbbbb....bbbbb...",
    "....................",
};

const walker_legs_b = [_][]const u8{
    ".....lllllllll......",
    "....lll.....lll.....",
    "...lll.......lll....",
    "...ggg........ggg...",
    "..ggg..........ggg..",
    "..ggg..........ggg..",
    ".gggg..........gggg.",
    ".bbbb..........bbbb.",
    "bbbbb..........bbbbb",
    "....................",
};

pub const walker_a = sprites.parseBitmap(walker_w, walker_h, &(walker_top ++ walker_legs_a), &walker_palette);
pub const walker_b = sprites.parseBitmap(walker_w, walker_h, &(walker_top ++ walker_legs_b), &walker_palette);

pub const flyer_w = 14;
pub const flyer_h = 14;

const flyer_palette = [_]struct { u8, u32 }{
    .{ 'w', 0x5a2a48 }, // wing
    .{ 'W', 0x7a3a60 }, // wing edge
    .{ 'b', 0x8a3a3a }, // body
    .{ 'e', 0xffd040 }, // eye
    .{ 'f', 0xff7a20 }, // fire mouth
};

pub const flyer_a = sprites.parseBitmap(flyer_w, flyer_h, &.{
    "W............W",
    "Ww..........wW",
    "Www...bb...wwW",
    "Wwww.bbbb.wwwW",
    ".wwwwbebbwwww.",
    "..wwwbbbbwww..",
    "...wwbbfbww...",
    "......bbb.....",
    "......bb......",
    ".....b..b.....",
    "..............",
    "..............",
    "..............",
    "..............",
}, &flyer_palette);

pub const flyer_b = sprites.parseBitmap(flyer_w, flyer_h, &.{
    "..............",
    "..............",
    "......bb......",
    ".....bbbb.....",
    "....wbebbw....",
    "...wwbbbbww...",
    "..wwwbbfbwww..",
    ".wwww.bbbwwww.",
    "Wwww..bb..wwwW",
    "Www..b..b..wwW",
    "Ww..........wW",
    "W............W",
    "..............",
    "..............",
}, &flyer_palette);

/// Corpse bitmaps: the sprite's opaque pixels as flesh, a skeleton of bone.
pub fn corpseBitmap(comptime w: u32, comptime h: u32, sprite: *const [w * h]u32, kind: enum { walker, flyer }, flesh: u8, bone: u8, out: *[w * h]u8) void {
    for (0..h) |y| {
        for (0..w) |x| {
            const opaque_px = sprite[y * w + x] >> 24 != 0;
            if (!opaque_px) {
                out[y * w + x] = 0;
                continue;
            }
            const xi: i32 = @intCast(x);
            const yi: i32 = @intCast(y);
            const is_bone = switch (kind) {
                // Skull, spine, arm bones, shins.
                .walker => (yi >= 1 and yi <= 3 and xi >= 7 and xi <= 11) or
                    ((xi == 9 or xi == 10) and yi >= 5 and yi <= 17) or
                    (yi >= 8 and yi <= 15 and (xi == 3 or xi == 17)) or
                    (yi >= 20 and yi <= 24 and (xi == 6 or xi == 13 or xi == 3 or xi == 16)),
                .flyer => (xi == 6 or xi == 7) and yi >= 2 and yi <= 8,
            };
            out[y * w + x] = if (is_bone) bone else flesh;
        }
    }
}

/// Atlas rects of the gameplay sprites.
pub const Art = struct {
    witch_idle: sprites.AtlasRect = undefined,
    witch_walk: sprites.AtlasRect = undefined,
    witch_cast: sprites.AtlasRect = undefined,
    witch_cast_walk: sprites.AtlasRect = undefined,
    walker: [2]sprites.AtlasRect = undefined,
    flyer: [2]sprites.AtlasRect = undefined,
    uploaded: bool = false,

    pub fn upload(self: *Art, ctx: *gpu.Context, atlas: *sprites.Atlas) !void {
        self.witch_idle = try atlas.upload(ctx, &witch_idle, witch_w, witch_h);
        self.witch_walk = try atlas.upload(ctx, &witch_walk, witch_w, witch_h);
        self.witch_cast = try atlas.upload(ctx, &witch_cast, witch_w, witch_h);
        self.witch_cast_walk = try atlas.upload(ctx, &witch_cast_walk, witch_w, witch_h);
        self.walker[0] = try atlas.upload(ctx, &walker_a, walker_w, walker_h);
        self.walker[1] = try atlas.upload(ctx, &walker_b, walker_w, walker_h);
        self.flyer[0] = try atlas.upload(ctx, &flyer_a, flyer_w, flyer_h);
        self.flyer[1] = try atlas.upload(ctx, &flyer_b, flyer_w, flyer_h);
        self.uploaded = true;
    }
};

test "gameplay sprites parse and corpses keep the silhouette" {
    try std.testing.expect(witch_idle[0 * witch_w + 5] >> 24 == 0xff);
    try std.testing.expect(witch_cast[13 * witch_w + 11] >> 24 == 0xff); // wand tip forward
    var corpse: [walker_w * walker_h]u8 = undefined;
    corpseBitmap(walker_w, walker_h, &walker_a, .walker, 12, 7, &corpse);
    var flesh: u32 = 0;
    var bone: u32 = 0;
    var opaque_px: u32 = 0;
    for (corpse, walker_a) |c, p| {
        flesh += @intFromBool(c == 12);
        bone += @intFromBool(c == 7);
        opaque_px += @intFromBool(p >> 24 != 0);
    }
    try std.testing.expectEqual(opaque_px, flesh + bone);
    try std.testing.expect(bone > 20 and flesh > bone * 3);
}

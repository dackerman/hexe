//! The renderer (M8): world pass with material shading, 2D global
//! illumination with radiance cascades, sprites and debug primitives,
//! overlays, bloom, vignette, integer upscale to the window, and the cell
//! snapshots that let rendering overlap the next simulation tick.
//!
//! Per rendered frame, on the graphics queue (docs/decisions/100-render-pipeline.md):
//!   light_build  skyline.comp, light_scene.comp, light_mip.comp
//!   cascades     rc_cascade.comp, top cascade down to 0
//!   merge        light_resolve.comp, light_dilate.comp -> irradiance
//!   world        world.frag into the scene image (one fragment per world px)
//!   sprites      quads.vert/frag into the scene image
//!   post         bloom.comp (half res), composite.frag into the target
//!   hud          hud.frag, hud_text.* (world-anchored text)
//!
//! Gameplay API (per frame, consumed by the next render):
//!   addLight, drawSprite, drawRect, drawLine; `settings` for modes.
const std = @import("std");
const gpu = @import("../gpu/gpu.zig");
const vk = gpu.vk;
const shaders = @import("shaders");
const cell = @import("../sim/cell.zig");
const sim_materials = @import("../sim/materials.zig");
const Shared = @import("../sim/pipeline.zig").Shared;
const frames_in_flight = @import("../sim/pipeline.zig").frames_in_flight;
const render_materials = @import("materials.zig");
const lighting = @import("lighting.zig");
const overlay = @import("overlay.zig");
const sprites = @import("sprites.zig");
const world = @import("world.zig");
const View = world.View;
const Hud = @import("hud.zig").Hud;
const HudTarget = @import("hud.zig").Target;

pub const max_lights = 256;
pub const max_cascades = lighting.max_cascades;
pub const scene_mips = lighting.scene_mips;
pub const max_quads = sprites.max_quads;
/// Snapshots in the ring (one being read by a render while the sim writes
/// the other).
pub const snapshot_count = 2;

pub const LightMode = enum(u32) { cascades = 0, simple = 1, off = 2 };

pub const frame_flag_light_mode_mask: u32 = 3;
pub const frame_flag_bloom: u32 = 4;
pub const frame_flag_vignette: u32 = 8;
pub const frame_flag_sky: u32 = 16;
pub const frame_flag_texture: u32 = 32;
pub const frame_flag_overlay_additive: u32 = 64;

const hdr_format: vk.Format = .r16g16b16a16_sfloat;
/// Scene image capacity: the view in world pixels (1920x1080 at zoom 1 fits).
const scene_capacity = 2048;

pub const Settings = struct {
    light_mode: LightMode = .cascades,
    /// Cascade-0 probe spacing in world pixels: 1 full, 2 half (default),
    /// 4 quarter. The quality knob; raised automatically when the light
    /// region would not fit the probe capacity.
    probe_spacing: u32 = 2,
    /// Target march steps per cascade interval (8 low, 16 default, 32 high).
    march_samples: u32 = 16,
    margin: u32 = 64,
    overlay: overlay.Mode = .none,
    bloom: bool = true,
    vignette: bool = true,
    sky: bool = true,
    texture: bool = true,
    /// Linear radiance of the open sky.
    sky_color: [3]f32 = .{ 0.55, 0.68, 0.95 },
    ambient_surface: [3]f32 = .{ 0.30, 0.32, 0.36 },
    ambient_cave: [3]f32 = .{ 0.035, 0.035, 0.045 },
    /// Depth below the skyline (world px) over which ambient fades.
    ambient_fade: f32 = 260,
    exposure: f32 = 1.8,
    /// Display brightness of emissive materials and of temperature glow.
    emissive_gain: f32 = 1.0,
    glow_gain: f32 = 0.3,
    /// How much light emissive cells put into the light scene, relative to
    /// their display emission.
    light_emission_gain: f32 = 2.5,
    irradiance_gain: f32 = 1.0,
    bloom_strength: f32 = 0.55,
    bloom_threshold: f32 = 0.4,
    vignette_strength: f32 = 0.35,
    /// Brightness of the back wall behind air and translucent cells.
    background: f32 = 0.4,
    /// How far light reaches into solids (world px).
    wall_depth: f32 = 10,
};

pub const LightGpu = extern struct {
    pos: [2]f32,
    radius: f32,
    pad: f32 = 0,
    color: [4]f32,
};

pub const RenderFrame = extern struct {
    camera: [2]i32,
    view_size: [2]u32,
    region_origin: [2]i32,
    region_size: [2]u32,
    probes: [2]u32,
    probe_spacing: u32,
    probe_shift: u32,
    cascade_count: u32,
    tick: u32,
    overlay: u32,
    flags: u32,
    light_count: u32,
    quad_count: u32,
    cells_slot: u32,
    owner_slot: u32,
    tiles_slot: u32,
    overlay_slot: u32,
    materials_slot: u32,
    lights_slot: u32,
    skyline_slot: u32,
    irradiance_tex: u32,
    scene_img: [scene_mips]u32,
    /// r32ui ballistic particle overlay (snapshot or live), 0 = none.
    particles_slot: u32,
    pad: [2]u32 = @splat(0),
    sky: [4]f32,
    ambient_surface: [4]f32,
    ambient_cave: [4]f32,
    tuning: [4]f32,
    tuning2: [4]f32,
    tuning3: [4]f32,
};

comptime {
    std.debug.assert(@offsetOf(RenderFrame, "sky") == 144);
    std.debug.assert(@sizeOf(RenderFrame) == 240);
}

/// Where the render reads the world from: a snapshot (overlapped with the
/// next tick) or the live images (after the GPU went idle).
pub const Sources = struct {
    cells: u32,
    owner: u32,
    /// Buffer slot, TILE_MARKS layout.
    tiles: u32,
    overlay_image: u32,
    /// r32ui ballistic particles in flight (SLOT_IMG_PARTICLE_OVERLAY layout).
    particles: u32,
};

pub const Target = struct {
    view: vk.ImageView,
    extent: vk.Extent2D,
    kind: HudTarget,
};

/// Image with a storage slot and optionally a sampled-texture slot, GENERAL.
const SlottedImage = struct {
    image: gpu.Image = .{},
    texture: u32 = 0,

    fn init(ctx: *gpu.Context, w: u32, h: u32, format: vk.Format, extra: vk.ImageUsageFlags, sampled: bool, fixed_slot: ?u32) !SlottedImage {
        var usage = extra;
        usage.storage = true;
        if (sampled) usage.sampled = true;
        var self: SlottedImage = .{};
        self.image = try gpu.Image.init(ctx, .{ .width = w, .height = h, .format = format, .usage = usage });
        errdefer self.image.deinit(ctx);
        try self.image.initLayout(ctx, .general, true);
        self.image.register(ctx, fixed_slot orelse try ctx.descriptors.allocImageSlot());
        if (sampled) {
            self.texture = try ctx.descriptors.allocTextureSlot();
            ctx.descriptors.writeSampledImage(ctx, self.texture, self.image.view, .general);
        }
        return self;
    }

    fn deinit(self: *SlottedImage, ctx: *gpu.Context) void {
        self.image.deinit(ctx);
    }

    fn slot(self: *const SlottedImage) u32 {
        return self.image.slot;
    }
};

pub const Renderer = struct {
    ctx: *gpu.Context,
    settings: Settings = .{},

    // CPU-side draw lists for the next render.
    lights: [max_lights]LightGpu = undefined,
    light_count: u32 = 0,
    quads: [max_quads]sprites.QuadGpu = undefined,
    quad_count: u32 = 0,
    dropped_draws: u32 = 0,

    materials: gpu.Buffer = .{},
    frame_params: [frames_in_flight]gpu.Buffer = @splat(.{}),
    light_bufs: [frames_in_flight]gpu.Buffer = @splat(.{}),
    quad_bufs: [frames_in_flight]gpu.Buffer = @splat(.{}),
    skyline: gpu.Buffer = .{},

    snap_cells: [snapshot_count]SlottedImage = @splat(.{}),
    snap_owner: [snapshot_count]SlottedImage = @splat(.{}),
    snap_overlay: [snapshot_count]SlottedImage = @splat(.{}),
    snap_tiles: [snapshot_count]gpu.Buffer = @splat(.{}),
    snap_particles: [snapshot_count]SlottedImage = @splat(.{}),
    /// RGBA8 debug overlay at SLOT_IMG_DEBUG_OVERLAY, written by sim passes.
    overlay_image: SlottedImage = .{},

    scene_mips: [scene_mips]SlottedImage = @splat(.{}),
    cascades: [2]SlottedImage = @splat(.{}),
    irradiance_raw: SlottedImage = .{},
    irradiance: SlottedImage = .{},
    scene_color: SlottedImage = .{},
    bloom: [2]SlottedImage = @splat(.{}),
    atlas: sprites.Atlas = .{},
    witch: sprites.AtlasRect = undefined,
    crate: sprites.AtlasRect = undefined,

    p_skyline: vk.Pipeline = .null,
    p_scene: vk.Pipeline = .null,
    p_mip: vk.Pipeline = .null,
    p_cascade: vk.Pipeline = .null,
    p_resolve: vk.Pipeline = .null,
    p_dilate: vk.Pipeline = .null,
    p_bloom: vk.Pipeline = .null,
    p_world: vk.Pipeline = .null,
    p_quads: vk.Pipeline = .null,
    /// Composite pipelines per target kind (present, capture).
    p_composite: [2]vk.Pipeline = @splat(.null),

    /// The last frame's light plan (HUD, bench).
    last_plan: lighting.Plan = undefined,

    /// In place; `self` must stay at this address.
    pub fn init(self: *Renderer, ctx: *gpu.Context, lib: *const sim_materials.Library, present_format: vk.Format, capture_format: vk.Format) !void {
        self.* = .{ .ctx = ctx };
        errdefer self.deinit();
        self.materials = try gpu.Buffer.initSlotted(ctx, @sizeOf(render_materials.Table), .{}, .cpu_to_gpu);
        self.uploadMaterials(lib);
        for (0..frames_in_flight) |i| {
            self.frame_params[i] = try gpu.Buffer.initSlotted(ctx, @sizeOf(RenderFrame), .{}, .cpu_to_gpu);
            self.light_bufs[i] = try gpu.Buffer.initSlotted(ctx, max_lights * @sizeOf(LightGpu), .{}, .cpu_to_gpu);
            self.quad_bufs[i] = try gpu.Buffer.initSlotted(ctx, max_quads * @sizeOf(sprites.QuadGpu), .{}, .cpu_to_gpu);
        }
        // Per region column: skyline, then terrain surface (skyline.comp).
        self.skyline = try gpu.Buffer.initSlotted(ctx, lighting.max_region * 2 * 4, .{}, .gpu_only);

        const W = cell.world_size;
        const ov = gpu.constants.debug_overlay_size;
        for (0..snapshot_count) |i| {
            self.snap_cells[i] = try SlottedImage.init(ctx, W, W, .r32_uint, .{ .transfer_dst = true, .transfer_src = true }, false, null);
            self.snap_owner[i] = try SlottedImage.init(ctx, W, W, .r32_uint, .{ .transfer_dst = true }, false, null);
            self.snap_overlay[i] = try SlottedImage.init(ctx, ov, ov, .r8g8b8a8_unorm, .{ .transfer_dst = true }, false, null);
            self.snap_tiles[i] = try gpu.Buffer.initSlotted(ctx, cell.tile_mark_bytes, .{ .transfer_dst = true }, .gpu_only);
            self.snap_particles[i] = try SlottedImage.init(ctx, W, W, .r32_uint, .{ .transfer_dst = true }, false, null);
        }
        self.overlay_image = try SlottedImage.init(ctx, ov, ov, .r8g8b8a8_unorm, .{ .transfer_src = true, .transfer_dst = true }, false, gpu.constants.slot_img_debug_overlay);

        for (0..scene_mips) |m| {
            const s: u32 = @as(u32, lighting.max_region) >> @intCast(m);
            self.scene_mips[m] = try SlottedImage.init(ctx, s, s, hdr_format, .{}, false, null);
        }
        // Cascades hold RGB9E5 radiance in r32ui (4 bytes per texel).
        for (&self.cascades) |*c| c.* = try SlottedImage.init(ctx, lighting.max_probes * 2, lighting.max_probes * 2, .r32_uint, .{}, false, null);
        self.irradiance_raw = try SlottedImage.init(ctx, lighting.max_probes, lighting.max_probes, hdr_format, .{}, false, null);
        self.irradiance = try SlottedImage.init(ctx, lighting.max_probes, lighting.max_probes, hdr_format, .{}, true, null);
        self.scene_color = try SlottedImage.init(ctx, scene_capacity, scene_capacity, hdr_format, .{ .color_attachment = true }, true, null);
        for (&self.bloom) |*b| b.* = try SlottedImage.init(ctx, scene_capacity / 2, scene_capacity / 2, hdr_format, .{}, true, null);

        self.atlas = try sprites.Atlas.init(ctx);
        self.witch = try self.atlas.upload(ctx, &sprites.witch, sprites.witch_w, sprites.witch_h);
        self.crate = try self.atlas.upload(ctx, &sprites.crate, sprites.crate_w, sprites.crate_h);

        self.p_skyline = try gpu.pipelines.createCompute(ctx, &shaders.render_skyline_comp);
        self.p_scene = try gpu.pipelines.createCompute(ctx, &shaders.render_light_scene_comp);
        self.p_mip = try gpu.pipelines.createCompute(ctx, &shaders.render_light_mip_comp);
        self.p_cascade = try gpu.pipelines.createCompute(ctx, &shaders.render_rc_cascade_comp);
        self.p_resolve = try gpu.pipelines.createCompute(ctx, &shaders.render_light_resolve_comp);
        self.p_dilate = try gpu.pipelines.createCompute(ctx, &shaders.render_light_dilate_comp);
        self.p_bloom = try gpu.pipelines.createCompute(ctx, &shaders.render_bloom_comp);
        self.p_world = try gpu.pipelines.createGraphics(ctx, .{
            .vert = &shaders.render_fullscreen_vert,
            .frag = &shaders.render_world_frag,
            .color_format = hdr_format,
        });
        self.p_quads = try gpu.pipelines.createGraphics(ctx, .{
            .vert = &shaders.render_quads_vert,
            .frag = &shaders.render_quads_frag,
            .color_format = hdr_format,
            .blend = .alpha,
        });
        for ([2]vk.Format{ present_format, capture_format }, 0..) |f, i| {
            self.p_composite[i] = try gpu.pipelines.createGraphics(ctx, .{
                .vert = &shaders.render_fullscreen_vert,
                .frag = &shaders.render_composite_frag,
                .color_format = f,
            });
        }
        self.last_plan = lighting.plan(.{ 0, 0 }, .{ 64, 64 }, .{});
    }

    pub fn deinit(self: *Renderer) void {
        const ctx = self.ctx;
        for ([_]*vk.Pipeline{ &self.p_skyline, &self.p_scene, &self.p_mip, &self.p_cascade, &self.p_resolve, &self.p_dilate, &self.p_bloom, &self.p_world, &self.p_quads, &self.p_composite[0], &self.p_composite[1] }) |p| {
            if (p.* != .null) gpu.pipelines.destroy(ctx, p.*);
            p.* = .null;
        }
        self.atlas.deinit(ctx);
        for (&self.bloom) |*b| b.deinit(ctx);
        self.scene_color.deinit(ctx);
        self.irradiance.deinit(ctx);
        self.irradiance_raw.deinit(ctx);
        for (&self.cascades) |*c| c.deinit(ctx);
        for (&self.scene_mips) |*m| m.deinit(ctx);
        self.overlay_image.deinit(ctx);
        for (0..snapshot_count) |i| {
            self.snap_tiles[i].deinit(ctx);
            self.snap_particles[i].deinit(ctx);
            self.snap_overlay[i].deinit(ctx);
            self.snap_owner[i].deinit(ctx);
            self.snap_cells[i].deinit(ctx);
        }
        self.skyline.deinit(ctx);
        for (0..frames_in_flight) |i| {
            self.quad_bufs[i].deinit(ctx);
            self.light_bufs[i].deinit(ctx);
            self.frame_params[i].deinit(ctx);
        }
        self.materials.deinit(ctx);
    }

    /// Rebuild the render material table from the sim table (hot reload:
    /// call while no render is pending, e.g. after `Engine.finish`).
    pub fn uploadMaterials(self: *Renderer, lib: *const sim_materials.Library) void {
        const out: *render_materials.Table = @ptrCast(@alignCast(self.materials.mapped.?));
        render_materials.build(out, lib);
    }

    // ------------------------------------------------------------ draw API

    /// A point light at world pixel (x, y) for the next rendered frame.
    /// `color` is linear and may exceed 1; it is about 1/4 as bright at
    /// `radius` world pixels (radiance cascades: soft 1/d falloff with
    /// shadows; simple mode: (1 - d/radius)^2, zero beyond).
    pub fn addLight(self: *Renderer, x: f32, y: f32, radius: f32, color: [3]f32) void {
        if (self.light_count >= max_lights) {
            self.dropped_draws += 1;
            return;
        }
        self.lights[self.light_count] = .{ .pos = .{ x, y }, .radius = @max(radius, 1), .color = .{ color[0], color[1], color[2], 1 } };
        self.light_count += 1;
    }

    fn pushQuad(self: *Renderer, q: sprites.QuadGpu) void {
        if (self.quad_count >= max_quads) {
            self.dropped_draws += 1;
            return;
        }
        self.quads[self.quad_count] = q;
        self.quad_count += 1;
    }

    /// Draw atlas rect `rect` with its top-left at world pixel (x, y), w x h
    /// world pixels, optionally mirrored, tinted (linear rgba), lit like the
    /// world.
    pub fn drawSprite(self: *Renderer, x: f32, y: f32, w: f32, h: f32, rect: sprites.AtlasRect, flip: bool, tint: [4]f32) void {
        self.pushQuad(.{
            .p0 = .{ @floor(x), @floor(y) },
            .p1 = .{ w, h },
            .color = tint,
            .uv = .{ @floatFromInt(rect.x), @floatFromInt(rect.y), @floatFromInt(rect.w), @floatFromInt(rect.h) },
            .kind = sprites.kind_sprite,
            .flags = sprites.flag_lit | (if (flip) sprites.flag_flip_x else 0),
        });
    }

    /// Debug rectangle in world pixels (unlit), filled or as a 1 px outline.
    pub fn drawRect(self: *Renderer, x: f32, y: f32, w: f32, h: f32, color: [4]f32, filled: bool) void {
        if (filled) {
            self.pushQuad(.{ .p0 = .{ x, y }, .p1 = .{ w, h }, .color = color, .kind = sprites.kind_rect });
            return;
        }
        self.drawLine(x, y, x + w - 1, y, color);
        self.drawLine(x, y + h - 1, x + w - 1, y + h - 1, color);
        self.drawLine(x, y + 1, x, y + h - 2, color);
        self.drawLine(x + w - 1, y + 1, x + w - 1, y + h - 2, color);
    }

    /// Debug line between world pixels (inclusive), 1 world pixel wide, unlit.
    pub fn drawLine(self: *Renderer, x0: f32, y0: f32, x1: f32, y1: f32, color: [4]f32) void {
        self.pushQuad(.{ .p0 = .{ x0, y0 }, .p1 = .{ x1, y1 }, .color = color, .kind = sprites.kind_line, .width = 1 });
    }

    /// Drop this frame's lights, sprites and primitives (the engine calls
    /// it after each rendered frame).
    pub fn clearDraws(self: *Renderer) void {
        self.light_count = 0;
        self.quad_count = 0;
    }

    // ------------------------------------------------------------ snapshots

    pub fn snapshotSources(self: *const Renderer, index: usize) Sources {
        return .{
            .cells = self.snap_cells[index].slot(),
            .owner = self.snap_owner[index].slot(),
            .tiles = self.snap_tiles[index].slot,
            .overlay_image = self.snap_overlay[index].slot(),
            .particles = self.snap_particles[index].slot(),
        };
    }

    pub fn liveSources(self: *const Renderer, shared: *const Shared) Sources {
        return .{
            .cells = shared.cells.slot,
            .owner = shared.owner.slot,
            .tiles = shared.tile_marks.slot,
            .overlay_image = self.overlay_image.slot(),
            .particles = gpu.constants.slot_img_particle_overlay,
        };
    }

    /// Copy what the render reads from the live world into snapshot
    /// `index`: cells and tile flags always, the owner image and the debug
    /// overlay image only when the current overlay needs them. Recorded at
    /// the end of a sim command buffer (compute queue) or at the start of a
    /// render one.
    pub fn recordSnapshot(self: *Renderer, cmd: vk.CommandBuffer, shared: *const Shared, particle_overlay: ?vk.Image, index: usize) void {
        const ctx = self.ctx;
        gpu.memory.memoryBarrier(ctx, cmd, .{ .all_commands = true }, .{ .memory_write = true }, .{ .all_transfer = true }, .{ .transfer_read = true, .transfer_write = true });
        copyImage(ctx, cmd, shared.cells.handle, self.snap_cells[index].image.handle, cell.world_size);
        const mode = self.settings.overlay;
        if (mode == .bodies) copyImage(ctx, cmd, shared.owner.handle, self.snap_owner[index].image.handle, cell.world_size);
        if (overlay.info(mode).image) copyImage(ctx, cmd, self.overlay_image.image.handle, self.snap_overlay[index].image.handle, gpu.constants.debug_overlay_size);
        ctx.vkd.cmdCopyBuffer(cmd, shared.tile_marks.handle, self.snap_tiles[index].handle, &.{.{ .src_offset = 0, .dst_offset = 0, .size = cell.tile_mark_bytes }});
        // Ballistic particles in flight (src/sim/particles.zig overlay).
        if (particle_overlay) |img| copyImage(ctx, cmd, img, self.snap_particles[index].image.handle, cell.world_size);
        gpu.memory.memoryBarrier(ctx, cmd, .{ .all_transfer = true }, .{ .transfer_write = true }, .{ .all_commands = true }, .{ .memory_read = true });
    }

    fn copyImage(ctx: *gpu.Context, cmd: vk.CommandBuffer, src: vk.Image, dst: vk.Image, size: u32) void {
        const layers = vk.ImageSubresourceLayers{ .aspect_mask = .{ .color = true }, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 };
        ctx.vkd.cmdCopyImage(cmd, src, .general, dst, .general, &.{.{
            .src_subresource = layers,
            .src_offset = .{ .x = 0, .y = 0, .z = 0 },
            .dst_subresource = layers,
            .dst_offset = .{ .x = 0, .y = 0, .z = 0 },
            .extent = .{ .width = size, .height = size, .depth = 1 },
        }});
    }

    // ------------------------------------------------------------ render

    /// The view in world pixels (the scene image size) for a target extent.
    pub fn sceneSize(view: View, extent: vk.Extent2D) [2]u32 {
        const scale = @max(view.scale, 1);
        return .{
            @min((extent.width + scale - 1) / scale, scene_capacity),
            @min((extent.height + scale - 1) / scale, scene_capacity),
        };
    }

    /// The light region and cascades a render of `view` at `extent` uses.
    pub fn plan(self: *const Renderer, view: View, extent: vk.Extent2D) lighting.Plan {
        const s = &self.settings;
        return lighting.plan(.{ view.camera_x, view.camera_y }, sceneSize(view, extent), .{
            .margin = s.margin,
            .spacing = std.math.ceilPowerOfTwo(u32, std.math.clamp(s.probe_spacing, 1, 16)) catch 2,
            .samples = s.march_samples,
        });
    }

    const Timer = struct {
        rec: ?*gpu.timestamps.Recorder,
        ctx: *const gpu.Context,
        cmd: vk.CommandBuffer,

        fn begin(self: Timer, name: []const u8) ?gpu.timestamps.Scope {
            const r = self.rec orelse return null;
            return r.begin(self.ctx, self.cmd, name);
        }

        fn end(self: Timer, scope: ?gpu.timestamps.Scope) void {
            if (scope) |s| self.rec.?.end(self.ctx, self.cmd, s);
        }
    };

    fn computeBarrier(ctx: *const gpu.Context, cmd: vk.CommandBuffer) void {
        gpu.memory.computeBarrier(ctx, cmd);
    }

    fn groups(n: u32) u32 {
        return (n + 15) / 16;
    }

    /// Record a whole frame: lighting, world, sprites and post into
    /// `target` (begins and ends the target's rendering scope; the caller
    /// transitions it to COLOR_ATTACHMENT_OPTIMAL before and away after),
    /// then the HUD. Graphics queue; descriptors bound for compute and
    /// graphics.
    pub fn record(self: *Renderer, cmd: vk.CommandBuffer, slot: u32, src: Sources, view: View, target: Target, hud: *Hud, timer_rec: ?*gpu.timestamps.Recorder, tick: u32) void {
        const ctx = self.ctx;
        const s = &self.settings;
        const timer = Timer{ .rec = timer_rec, .ctx = ctx, .cmd = cmd };
        const scale = @max(view.scale, 1);
        const vw, const vh = sceneSize(view, target.extent);
        const p = self.plan(view, target.extent);
        self.last_plan = p;

        var flags: u32 = @backingInt(s.light_mode);
        if (s.bloom) flags |= frame_flag_bloom;
        if (s.vignette) flags |= frame_flag_vignette;
        if (s.sky) flags |= frame_flag_sky;
        if (s.texture) flags |= frame_flag_texture;
        if (overlay.info(s.overlay).blend == .additive) flags |= frame_flag_overlay_additive;
        var mips: [scene_mips]u32 = undefined;
        for (&mips, self.scene_mips) |*m, img| m.* = img.slot();
        const fr = &self.frame_params[slot].typed(RenderFrame)[0];
        fr.* = .{
            .camera = .{ view.camera_x, view.camera_y },
            .view_size = .{ vw, vh },
            .region_origin = p.origin,
            .region_size = p.size,
            .probes = p.probes,
            .probe_spacing = p.spacing,
            .probe_shift = p.shift,
            .cascade_count = p.count,
            .tick = tick,
            .overlay = @backingInt(s.overlay),
            .flags = flags,
            .light_count = self.light_count,
            .quad_count = self.quad_count,
            .cells_slot = src.cells,
            .owner_slot = src.owner,
            .tiles_slot = src.tiles,
            .overlay_slot = src.overlay_image,
            .materials_slot = self.materials.slot,
            .lights_slot = self.light_bufs[slot].slot,
            .skyline_slot = self.skyline.slot,
            .irradiance_tex = self.irradiance.texture,
            .scene_img = mips,
            .particles_slot = src.particles,
            .sky = .{ s.sky_color[0], s.sky_color[1], s.sky_color[2], 1 },
            .ambient_surface = .{ s.ambient_surface[0], s.ambient_surface[1], s.ambient_surface[2], s.ambient_fade },
            .ambient_cave = .{ s.ambient_cave[0], s.ambient_cave[1], s.ambient_cave[2], s.exposure },
            .tuning = .{ s.emissive_gain, s.glow_gain, s.bloom_strength, s.vignette_strength },
            .tuning2 = .{ s.background, s.wall_depth, s.irradiance_gain, s.bloom_threshold },
            .tuning3 = .{ s.light_emission_gain, 0, 0, 0 },
        };
        @memcpy(self.light_bufs[slot].typed(LightGpu)[0..self.light_count], self.lights[0..self.light_count]);
        @memcpy(self.quad_bufs[slot].typed(sprites.QuadGpu)[0..self.quad_count], self.quads[0..self.quad_count]);
        const frame_slot = self.frame_params[slot].slot;

        // Everything earlier on this queue (last frame's composite reading
        // the scene image, ...) before this frame's writes.
        gpu.memory.memoryBarrier(ctx, cmd, .{ .all_commands = true }, .{ .memory_write = true }, .{ .all_commands = true }, .{ .memory_read = true, .memory_write = true });

        // ---- light scene ----
        const t_build = timer.begin("light_build");
        ctx.vkd.cmdBindPipeline(cmd, .compute, self.p_skyline);
        gpu.pipelines.push(ctx, cmd, extern struct { f: u32, pass: u32 }{ .f = frame_slot, .pass = 0 });
        ctx.vkd.cmdDispatch(cmd, p.size[0], 1, 1);
        ctx.vkd.cmdBindPipeline(cmd, .compute, self.p_scene);
        gpu.pipelines.push(ctx, cmd, extern struct { f: u32 }{ .f = frame_slot });
        ctx.vkd.cmdDispatch(cmd, groups(p.size[0]), groups(p.size[1]), 1);
        computeBarrier(ctx, cmd);
        // Terrain surface from the skyline (read by world.frag and sprites).
        ctx.vkd.cmdBindPipeline(cmd, .compute, self.p_skyline);
        gpu.pipelines.push(ctx, cmd, extern struct { f: u32, pass: u32 }{ .f = frame_slot, .pass = 1 });
        ctx.vkd.cmdDispatch(cmd, (p.size[0] + 63) / 64, 1, 1);
        const top_mip = if (s.light_mode == .cascades) p.maxMip() else @max(p.shift, 1);
        ctx.vkd.cmdBindPipeline(cmd, .compute, self.p_mip);
        var level: u32 = 1;
        while (level <= top_mip) : (level += 1) {
            gpu.pipelines.push(ctx, cmd, extern struct { f: u32, level: u32 }{ .f = frame_slot, .level = level });
            ctx.vkd.cmdDispatch(cmd, groups(p.size[0] >> @intCast(level)), groups(p.size[1] >> @intCast(level)), 1);
            computeBarrier(ctx, cmd);
        }
        timer.end(t_build);

        // ---- cascades, top down ----
        const t_casc = timer.begin("cascades");
        var c0: u32 = self.cascades[0].slot();
        if (s.light_mode == .cascades) {
            ctx.vkd.cmdBindPipeline(cmd, .compute, self.p_cascade);
            const cs = p.cascadeSize();
            var i: u32 = p.count;
            while (i > 0) {
                i -= 1;
                const dst = self.cascades[i % 2].slot();
                const src_c = self.cascades[(i + 1) % 2].slot();
                const c = p.cascades[i];
                gpu.pipelines.push(ctx, cmd, extern struct { f: u32, cascade: u32, src: u32, dst: u32, t0: f32, t1: f32, mip: u32, top: u32 }{
                    .f = frame_slot,
                    .cascade = i,
                    .src = src_c,
                    .dst = dst,
                    .t0 = c.t_start,
                    .t1 = c.t_end,
                    .mip = c.mip,
                    .top = @intFromBool(i + 1 == p.count),
                });
                ctx.vkd.cmdDispatch(cmd, groups(cs[0]), groups(cs[1]), 1);
                computeBarrier(ctx, cmd);
                c0 = dst;
            }
        }
        timer.end(t_casc);

        // ---- irradiance ----
        const t_merge = timer.begin("merge");
        ctx.vkd.cmdBindPipeline(cmd, .compute, self.p_resolve);
        gpu.pipelines.push(ctx, cmd, extern struct { f: u32, c0: u32, dst: u32 }{ .f = frame_slot, .c0 = c0, .dst = self.irradiance_raw.slot() });
        ctx.vkd.cmdDispatch(cmd, groups(p.probes[0]), groups(p.probes[1]), 1);
        computeBarrier(ctx, cmd);
        ctx.vkd.cmdBindPipeline(cmd, .compute, self.p_dilate);
        gpu.pipelines.push(ctx, cmd, extern struct { f: u32, src: u32, dst: u32 }{ .f = frame_slot, .src = self.irradiance_raw.slot(), .dst = self.irradiance.slot() });
        ctx.vkd.cmdDispatch(cmd, groups(p.probes[0]), groups(p.probes[1]), 1);
        gpu.memory.memoryBarrier(ctx, cmd, .{ .compute_shader = true }, .{ .shader_storage_write = true }, .{ .all_graphics = true, .compute_shader = true }, .{ .shader_read = true, .shader_storage_read = true });
        timer.end(t_merge);

        // ---- world + sprites into the scene image ----
        const scene_extent = vk.Extent2D{ .width = vw, .height = vh };
        const scene_att = vk.RenderingAttachmentInfo{
            .image_view = self.scene_color.image.view,
            .image_layout = .general,
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
            .load_op = .dont_care,
            .store_op = .store,
            .clear_value = .{ .color = .{ .float_32 = .{ 0, 0, 0, 1 } } },
        };
        ctx.vkd.cmdBeginRendering(cmd, &.{
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = scene_extent },
            .layer_count = 1,
            .view_mask = 0,
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast(&scene_att),
        });
        world.setViewport(ctx, cmd, scene_extent);
        const t_world = timer.begin("world");
        ctx.vkd.cmdBindPipeline(cmd, .graphics, self.p_world);
        gpu.pipelines.push(ctx, cmd, extern struct { f: u32 }{ .f = frame_slot });
        ctx.vkd.cmdDraw(cmd, 3, 1, 0, 0);
        timer.end(t_world);
        const t_sprites = timer.begin("sprites");
        if (self.quad_count > 0) {
            ctx.vkd.cmdBindPipeline(cmd, .graphics, self.p_quads);
            gpu.pipelines.push(ctx, cmd, extern struct { f: u32, quads: u32, atlas: u32 }{ .f = frame_slot, .quads = self.quad_bufs[slot].slot, .atlas = self.atlas.texture_slot });
            ctx.vkd.cmdDraw(cmd, self.quad_count * 6, 1, 0, 0);
        }
        timer.end(t_sprites);
        ctx.vkd.cmdEndRendering(cmd);

        // ---- post ----
        const t_post = timer.begin("post");
        gpu.memory.memoryBarrier(ctx, cmd, .{ .color_attachment_output = true }, .{ .color_attachment_write = true }, .{ .compute_shader = true, .fragment_shader = true }, .{ .shader_read = true, .shader_storage_read = true });
        if (s.bloom) {
            const bw = (vw + 1) / 2;
            const bh = (vh + 1) / 2;
            const Bloom = extern struct { f: u32, mode: u32, src: u32, dst: u32, dir: [2]i32, size: [2]u32 };
            ctx.vkd.cmdBindPipeline(cmd, .compute, self.p_bloom);
            gpu.pipelines.push(ctx, cmd, Bloom{ .f = frame_slot, .mode = 0, .src = self.scene_color.slot(), .dst = self.bloom[0].slot(), .dir = .{ 0, 0 }, .size = .{ bw, bh } });
            ctx.vkd.cmdDispatch(cmd, groups(bw), groups(bh), 1);
            computeBarrier(ctx, cmd);
            gpu.pipelines.push(ctx, cmd, Bloom{ .f = frame_slot, .mode = 1, .src = self.bloom[0].slot(), .dst = self.bloom[1].slot(), .dir = .{ 1, 0 }, .size = .{ bw, bh } });
            ctx.vkd.cmdDispatch(cmd, groups(bw), groups(bh), 1);
            computeBarrier(ctx, cmd);
            gpu.pipelines.push(ctx, cmd, Bloom{ .f = frame_slot, .mode = 1, .src = self.bloom[1].slot(), .dst = self.bloom[0].slot(), .dir = .{ 0, 1 }, .size = .{ bw, bh } });
            ctx.vkd.cmdDispatch(cmd, groups(bw), groups(bh), 1);
            gpu.memory.memoryBarrier(ctx, cmd, .{ .compute_shader = true }, .{ .shader_storage_write = true }, .{ .fragment_shader = true }, .{ .shader_read = true });
        }
        const att = vk.RenderingAttachmentInfo{
            .image_view = target.view,
            .image_layout = .color_attachment_optimal,
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
            .load_op = .dont_care,
            .store_op = .store,
            .clear_value = .{ .color = .{ .float_32 = .{ 0, 0, 0, 1 } } },
        };
        ctx.vkd.cmdBeginRendering(cmd, &.{
            .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = target.extent },
            .layer_count = 1,
            .view_mask = 0,
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast(&att),
        });
        world.setViewport(ctx, cmd, target.extent);
        ctx.vkd.cmdBindPipeline(cmd, .graphics, self.p_composite[@backingInt(target.kind)]);
        gpu.pipelines.push(ctx, cmd, extern struct { f: u32, scene: u32, bloom: u32, scale: u32, extent: [2]u32 }{
            .f = frame_slot,
            .scene = self.scene_color.texture,
            .bloom = self.bloom[0].texture,
            .scale = scale,
            .extent = .{ target.extent.width, target.extent.height },
        });
        ctx.vkd.cmdDraw(cmd, 3, 1, 0, 0);
        timer.end(t_post);
        const t_hud = timer.begin("hud");
        hud.recordWorld(ctx, cmd, slot, target.extent, target.kind, view);
        hud.record(ctx, cmd, slot, target.extent, target.kind);
        timer.end(t_hud);
        ctx.vkd.cmdEndRendering(cmd);
    }
};

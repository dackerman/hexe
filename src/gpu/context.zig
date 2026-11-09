//! Vulkan instance, physical device selection, logical device and queues.
//!
//! One `Context` per process, at a stable address (the dispatch tables are
//! large and referenced by pointer). Owns the global bindless descriptor set
//! and the pipeline layout every pipeline shares (see descriptors.zig).
const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const sdl = @import("sdl");
const Descriptors = @import("descriptors.zig").Descriptors;
const constants = @import("constants.zig");

const log = std.log.scoped(.gpu);

pub const Queue = struct {
    family: u32,
    handle: vk.Queue,
};

pub const QueueKind = enum(u1) { graphics = 0, compute = 1 };

/// Creates a presentation surface for the new instance (SDL in windowed mode).
pub const SurfaceProvider = struct {
    context: *anyopaque,
    create: *const fn (context: *anyopaque, instance: vk.Instance) anyerror!vk.SurfaceKHR,
};

pub const Options = struct {
    /// Enable VK_LAYER_KHRONOS_validation when it is installed. Silently
    /// skipped when it is not.
    validation: bool = builtin.mode == .debug,
    /// Use the window system's loader when presenting to its surface.
    get_instance_proc_addr: ?vk.PfnGetInstanceProcAddr = null,
    /// Instance extensions the window system needs; empty when headless.
    window_extensions: []const [*:0]const u8 = &.{},
    /// Null when headless: no surface, no swapchain extension.
    surface: ?SurfaceProvider = null,
};

const validation_layer = "VK_LAYER_KHRONOS_validation";
const loader_name = switch (builtin.os.tag) {
    .windows => "vulkan-1.dll",
    .macos => "libvulkan.1.dylib",
    else => "libvulkan.so.1",
};

pub const Context = struct {
    gpa: std.mem.Allocator,
    lib: ?*sdl.SDL_SharedObject,
    vkb: vk.BaseWrapper,
    vki: vk.InstanceWrapper,
    vkd: vk.DeviceWrapper,
    instance: vk.Instance,
    messenger: vk.DebugUtilsMessengerEXT,
    surface: vk.SurfaceKHR,
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    mem_props: vk.PhysicalDeviceMemoryProperties,
    device: vk.Device,
    /// Graphics + present (when a surface exists) + compute.
    graphics: Queue,
    /// A compute-only family when the device has one (async compute), else
    /// the graphics queue.
    compute: Queue,
    /// Distinct queue family indices; resources are created CONCURRENT
    /// across them so no ownership transfers are needed.
    families: [2]u32,
    family_count: u32,
    /// Nanoseconds per timestamp tick.
    timestamp_period: f64,
    descriptors: Descriptors,
    /// The one pipeline layout: set 0 = bindless set, 128 B push constants.
    pipeline_layout: vk.PipelineLayout,
    /// One-shot command pools, indexed by `QueueKind`.
    once_pools: [2]vk.CommandPool,
    once_fence: vk.Fence,

    pub fn init(self: *Context, gpa: std.mem.Allocator, opts: Options) !void {
        self.* = undefined;
        self.gpa = gpa;
        self.messenger = .null;
        self.surface = .null;
        self.lib = null;
        errdefer if (self.lib) |lib| sdl.SDL_UnloadObject(lib);
        const get_proc = opts.get_instance_proc_addr orelse blk: {
            const lib = sdl.SDL_LoadObject(loader_name) orelse {
                log.err("could not load {s}: {s}", .{ loader_name, sdl.SDL_GetError() });
                return error.VulkanLoaderMissing;
            };
            self.lib = lib;
            const proc = sdl.SDL_LoadFunction(lib, "vkGetInstanceProcAddr") orelse
                return error.VulkanLoaderMissing;
            break :blk @as(vk.PfnGetInstanceProcAddr, @ptrCast(proc));
        };
        self.vkb = vk.BaseWrapper.load(get_proc);

        try self.createInstance(opts);
        errdefer self.vki.destroyInstance(self.instance, null);
        errdefer if (self.messenger != .null) self.vki.destroyDebugUtilsMessengerEXT(self.instance, self.messenger, null);

        if (opts.surface) |sp| self.surface = try sp.create(sp.context, self.instance);
        errdefer if (self.surface != .null) self.vki.destroySurfaceKHR(self.instance, self.surface, null);

        try self.pickPhysicalDevice();
        try self.createDevice();
        errdefer self.vkd.destroyDevice(self.device, null);

        self.descriptors = try Descriptors.init(self);
        errdefer self.descriptors.deinit(self);

        const push_range = vk.PushConstantRange{
            .stage_flags = .{ .compute = true, .vertex = true, .fragment = true },
            .offset = 0,
            .size = constants.push_constant_bytes,
        };
        self.pipeline_layout = try self.vkd.createPipelineLayout(self.device, &.{
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast(&self.descriptors.layout),
            .push_constant_range_count = 1,
            .p_push_constant_ranges = @ptrCast(&push_range),
        }, null);
        errdefer self.vkd.destroyPipelineLayout(self.device, self.pipeline_layout, null);

        self.once_pools[0] = try self.vkd.createCommandPool(self.device, &.{
            .flags = .{ .reset_command_buffer = true },
            .queue_family_index = self.graphics.family,
        }, null);
        errdefer self.vkd.destroyCommandPool(self.device, self.once_pools[0], null);
        self.once_pools[1] = try self.vkd.createCommandPool(self.device, &.{
            .flags = .{ .reset_command_buffer = true },
            .queue_family_index = self.compute.family,
        }, null);
        errdefer self.vkd.destroyCommandPool(self.device, self.once_pools[1], null);
        self.once_fence = try self.vkd.createFence(self.device, &.{}, null);
    }

    pub fn deinit(self: *Context) void {
        self.vkd.deviceWaitIdle(self.device) catch {};
        self.vkd.destroyFence(self.device, self.once_fence, null);
        for (self.once_pools) |p| self.vkd.destroyCommandPool(self.device, p, null);
        self.vkd.destroyPipelineLayout(self.device, self.pipeline_layout, null);
        self.descriptors.deinit(self);
        self.vkd.destroyDevice(self.device, null);
        if (self.surface != .null) self.vki.destroySurfaceKHR(self.instance, self.surface, null);
        if (self.messenger != .null) self.vki.destroyDebugUtilsMessengerEXT(self.instance, self.messenger, null);
        self.vki.destroyInstance(self.instance, null);
        if (self.lib) |lib| sdl.SDL_UnloadObject(lib);
    }

    pub fn waitIdle(self: *Context) void {
        self.vkd.deviceWaitIdle(self.device) catch |err| log.err("deviceWaitIdle: {s}", .{@errorName(err)});
    }

    /// Record and run a command buffer on a queue, then wait for it. For
    /// init-time uploads, readbacks and tests, never inside the tick loop.
    /// `record` is called as `record(cmd, args...)`. The bindless set is
    /// bound for the queue's bind points before `record` runs.
    pub fn runOnce(self: *Context, kind: QueueKind, comptime record: anytype, args: anytype) !void {
        const pool = self.once_pools[@backingInt(kind)];
        const queue = if (kind == .graphics) self.graphics.handle else self.compute.handle;
        var cmd: vk.CommandBuffer = undefined;
        try self.vkd.allocateCommandBuffers(self.device, &.{
            .command_pool = pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&cmd));
        defer self.vkd.freeCommandBuffers(self.device, pool, &.{cmd});
        try self.vkd.beginCommandBuffer(cmd, &.{ .flags = .{ .one_time_submit = true } });
        self.descriptors.bind(self, cmd, .compute);
        if (kind == .graphics) self.descriptors.bind(self, cmd, .graphics);
        @call(.auto, record, .{cmd} ++ args);
        try self.vkd.endCommandBuffer(cmd);
        const cmd_info = vk.CommandBufferSubmitInfo{ .command_buffer = cmd, .device_mask = 0 };
        const submit = vk.SubmitInfo2{ .command_buffer_info_count = 1, .p_command_buffer_infos = @ptrCast(&cmd_info) };
        try self.vkd.queueSubmit2(queue, &.{submit}, self.once_fence);
        _ = try self.vkd.waitForFences(self.device, &.{self.once_fence}, .true, std.math.maxInt(u64));
        try self.vkd.resetFences(self.device, &.{self.once_fence});
    }

    pub fn sharingMode(self: *const Context) vk.SharingMode {
        return if (self.family_count > 1) .concurrent else .exclusive;
    }

    fn createInstance(self: *Context, opts: Options) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var layers: std.ArrayList([*:0]const u8) = .empty;
        var exts: std.ArrayList([*:0]const u8) = .empty;
        try exts.appendSlice(arena, opts.window_extensions);

        var debug_utils = false;
        if (opts.validation) {
            const available = try self.vkb.enumerateInstanceLayerPropertiesAlloc(arena);
            for (available) |l| {
                if (std.mem.eql(u8, std.mem.sliceTo(&l.layer_name, 0), validation_layer)) {
                    try layers.append(arena, validation_layer);
                    break;
                }
            }
            if (layers.items.len == 0) log.debug("validation layer not installed; continuing without it", .{});
        }
        const inst_exts = try self.vkb.enumerateInstanceExtensionPropertiesAlloc(null, arena);
        const portability_name = vk.instance_extensions.khr_portability_enumeration.name;
        var portability = false;
        // Older SDL versions may already include this extension.
        for (exts.items) |name| {
            if (std.mem.eql(u8, std.mem.span(name), portability_name)) portability = true;
        }
        for (inst_exts) |e| {
            const name = std.mem.sliceTo(&e.extension_name, 0);
            if (std.mem.eql(u8, name, vk.instance_extensions.ext_debug_utils.name)) {
                if (layers.items.len > 0) {
                    try exts.append(arena, vk.instance_extensions.ext_debug_utils.name);
                    debug_utils = true;
                }
            }
            if (builtin.os.tag == .macos and !portability and std.mem.eql(u8, name, portability_name)) {
                try exts.append(arena, portability_name);
                portability = true;
            }
        }

        const app_info = vk.ApplicationInfo{
            .p_application_name = "hexe",
            .application_version = 0,
            .p_engine_name = "hexe",
            .engine_version = 0,
            .api_version = @bitCast(vk.API_VERSION_1_3),
        };
        self.instance = try self.vkb.createInstance(&.{
            .flags = .{ .enumerate_portability_khr = portability },
            .p_application_info = &app_info,
            .enabled_layer_count = @intCast(layers.items.len),
            .pp_enabled_layer_names = layers.items.ptr,
            .enabled_extension_count = @intCast(exts.items.len),
            .pp_enabled_extension_names = exts.items.ptr,
        }, null);
        self.vki = vk.InstanceWrapper.load(self.instance, self.vkb.dispatch.vkGetInstanceProcAddr.?);

        if (debug_utils) {
            self.messenger = try self.vki.createDebugUtilsMessengerEXT(self.instance, &.{
                .message_severity = .{ .warning_ext = true, .error_ext = true },
                .message_type = .{ .general_ext = true, .validation_ext = true, .performance_ext = true },
                .pfn_user_callback = debugCallback,
            }, null);
            log.info("validation enabled", .{});
        }
    }

    fn pickPhysicalDevice(self: *Context) !void {
        const devices = try self.vki.enumeratePhysicalDevicesAlloc(self.instance, self.gpa);
        defer self.gpa.free(devices);
        var best: ?vk.PhysicalDevice = null;
        var best_score: i32 = -1;
        for (devices) |pd| {
            const p = self.vki.getPhysicalDeviceProperties(pd);
            const version: vk.Version = @bitCast(p.api_version);
            if (version.major < 1 or (version.major == 1 and version.minor < 3)) continue;
            var score: i32 = 0;
            if (p.device_type == .discrete_gpu) score += 100;
            if (p.device_type == .integrated_gpu) score += 10;
            if (p.vendor_id == 0x10de) score += 50; // NVIDIA
            if (score > best_score) {
                best_score = score;
                best = pd;
            }
        }
        self.pdev = best orelse return error.NoVulkan13Device;
        self.props = self.vki.getPhysicalDeviceProperties(self.pdev);
        self.mem_props = self.vki.getPhysicalDeviceMemoryProperties(self.pdev);
        self.timestamp_period = self.props.limits.timestamp_period;
        log.info("device: {s}", .{std.mem.sliceTo(&self.props.device_name, 0)});
    }

    fn createDevice(self: *Context) !void {
        const families = try self.vki.getPhysicalDeviceQueueFamilyPropertiesAlloc(self.pdev, self.gpa);
        defer self.gpa.free(families);

        var graphics: ?u32 = null;
        var compute_only: ?u32 = null;
        for (families, 0..) |f, i| {
            const idx: u32 = @intCast(i);
            if (f.timestamp_valid_bits == 0) continue;
            if (f.queue_flags.graphics and f.queue_flags.compute and graphics == null) {
                const present_ok = if (self.surface == .null)
                    true
                else
                    (try self.vki.getPhysicalDeviceSurfaceSupportKHR(self.pdev, idx, self.surface)) == .true;
                if (present_ok) graphics = idx;
            }
            if (f.queue_flags.compute and !f.queue_flags.graphics and compute_only == null) compute_only = idx;
        }
        const gfam = graphics orelse return error.NoGraphicsQueue;
        const cfam = compute_only orelse gfam;

        const priority = [_]f32{1.0};
        var queue_infos: [2]vk.DeviceQueueCreateInfo = undefined;
        queue_infos[0] = .{ .queue_family_index = gfam, .queue_count = 1, .p_queue_priorities = &priority };
        var queue_count: u32 = 1;
        if (cfam != gfam) {
            queue_infos[1] = .{ .queue_family_index = cfam, .queue_count = 1, .p_queue_priorities = &priority };
            queue_count = 2;
        }

        // Features: required set, checked against what the device supports.
        var have13 = vk.PhysicalDeviceVulkan13Features{};
        var have12 = vk.PhysicalDeviceVulkan12Features{ .p_next = &have13 };
        var have = vk.PhysicalDeviceFeatures2{ .p_next = &have12, .features = .{} };
        self.vki.getPhysicalDeviceFeatures2(self.pdev, &have);

        var f13 = vk.PhysicalDeviceVulkan13Features{
            .synchronization_2 = .true,
            .dynamic_rendering = .true,
            .maintenance_4 = .true,
        };
        var f12 = vk.PhysicalDeviceVulkan12Features{
            .p_next = &f13,
            .storage_buffer_8_bit_access = .true,
            .shader_int_8 = .true,
            .descriptor_indexing = .true,
            .runtime_descriptor_array = .true,
            .descriptor_binding_partially_bound = .true,
            .descriptor_binding_storage_image_update_after_bind = .true,
            .descriptor_binding_storage_buffer_update_after_bind = .true,
            .descriptor_binding_sampled_image_update_after_bind = .true,
            .descriptor_binding_update_unused_while_pending = .true,
            .scalar_block_layout = .true,
            .host_query_reset = .true,
            .timeline_semaphore = .true,
            .buffer_device_address = have12.buffer_device_address,
            .vulkan_memory_model = have12.vulkan_memory_model,
            .vulkan_memory_model_device_scope = have12.vulkan_memory_model_device_scope,
        };
        const f10 = vk.PhysicalDeviceFeatures{
            .shader_int_64 = have.features.shader_int_64,
            .shader_int_16 = have.features.shader_int_16,
            .shader_storage_image_read_without_format = have.features.shader_storage_image_read_without_format,
            .shader_storage_image_write_without_format = have.features.shader_storage_image_write_without_format,
            .fragment_stores_and_atomics = have.features.fragment_stores_and_atomics,
        };
        inline for (.{
            .{ have13, f13, "1.3" },
            .{ have12, f12, "1.2" },
        }) |entry| {
            const T = @TypeOf(entry[0]);
            const info = @typeInfo(T).@"struct";
            inline for (info.field_names, info.field_types) |name, ftype| {
                if (ftype == vk.Bool32) {
                    if (@field(entry[1], name) == .true and @field(entry[0], name) != .true) {
                        log.err("missing Vulkan {s} feature: {s}", .{ entry[2], name });
                        return error.MissingDeviceFeature;
                    }
                }
            }
        }
        const features2 = vk.PhysicalDeviceFeatures2{ .p_next = &f12, .features = f10 };

        var exts: [2][*:0]const u8 = undefined;
        var ext_count: u32 = 0;
        if (self.surface != .null) {
            exts[0] = vk.device_extensions.khr_swapchain.name;
            ext_count = 1;
        }
        // Vulkan requires enabling this extension when the chosen device advertises it.
        const device_exts = try self.vki.enumerateDeviceExtensionPropertiesAlloc(self.pdev, null, self.gpa);
        defer self.gpa.free(device_exts);
        const portability_subset = vk.device_extensions.khr_portability_subset.name;
        for (device_exts) |e| {
            if (std.mem.eql(u8, std.mem.sliceTo(&e.extension_name, 0), portability_subset)) {
                exts[ext_count] = portability_subset;
                ext_count += 1;
                break;
            }
        }

        self.device = try self.vki.createDevice(self.pdev, &.{
            .p_next = &features2,
            .queue_create_info_count = queue_count,
            .p_queue_create_infos = &queue_infos,
            .enabled_extension_count = ext_count,
            .pp_enabled_extension_names = &exts,
        }, null);
        self.vkd = vk.DeviceWrapper.load(self.device, self.vki.dispatch.vkGetDeviceProcAddr.?);
        self.graphics = .{ .family = gfam, .handle = self.vkd.getDeviceQueue(self.device, gfam, 0) };
        self.compute = .{ .family = cfam, .handle = self.vkd.getDeviceQueue(self.device, cfam, 0) };
        self.families = .{ gfam, cfam };
        self.family_count = if (cfam != gfam) 2 else 1;
        log.info("queues: graphics family {d}, compute family {d}{s}", .{
            gfam, cfam, if (cfam != gfam) " (async)" else " (shared)",
        });
    }

    /// Index of a memory type allowed by `type_bits` with all of `required`,
    /// preferring one that also has `preferred`.
    pub fn findMemoryType(self: *const Context, type_bits: u32, required: vk.MemoryPropertyFlags, preferred: vk.MemoryPropertyFlags) ?u32 {
        const want = required.merge(preferred);
        var fallback: ?u32 = null;
        for (0..self.mem_props.memory_type_count) |i| {
            if (type_bits & (@as(u32, 1) << @intCast(i)) == 0) continue;
            const flags = self.mem_props.memory_types[i].property_flags;
            if (flags.contains(want)) return @intCast(i);
            if (flags.contains(required) and fallback == null) fallback = @intCast(i);
        }
        return fallback;
    }
};

fn debugCallback(
    severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    types: vk.DebugUtilsMessageTypeFlagsEXT,
    data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    user: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    _ = types;
    _ = user;
    const msg: [*:0]const u8 = if (data) |d| d.p_message orelse "?" else "?";
    if (severity.error_ext) log.err("vulkan: {s}", .{msg}) else log.warn("vulkan: {s}", .{msg});
    return .false;
}

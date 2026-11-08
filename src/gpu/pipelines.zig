//! Compute and graphics pipelines from embedded SPIR-V. Every pipeline uses
//! the context's single pipeline layout (bindless set 0 + push constants).
const std = @import("std");
const vk = @import("vulkan");
const Context = @import("context.zig").Context;

/// SPIR-V as embedded by the generated `shaders` module (4-byte aligned).
pub const Spirv = []align(4) const u8;

fn createModule(ctx: *Context, code: Spirv) !vk.ShaderModule {
    return ctx.vkd.createShaderModule(ctx.device, &.{
        .code_size = code.len,
        .p_code = @ptrCast(code.ptr),
    }, null);
}

pub fn createCompute(ctx: *Context, code: Spirv) !vk.Pipeline {
    const module = try createModule(ctx, code);
    defer ctx.vkd.destroyShaderModule(ctx.device, module, null);
    const info = vk.ComputePipelineCreateInfo{
        .stage = .{ .stage = .{ .compute = true }, .module = module, .p_name = "main" },
        .layout = ctx.pipeline_layout,
        .base_pipeline_index = -1,
    };
    var pipeline: vk.Pipeline = undefined;
    _ = try ctx.vkd.createComputePipelines(ctx.device, .null, &.{info}, null, @ptrCast(&pipeline));
    return pipeline;
}

pub const Blend = enum { none, alpha };

pub const GraphicsDesc = struct {
    vert: Spirv,
    frag: Spirv,
    color_format: vk.Format,
    blend: Blend = .none,
};

/// A fullscreen-triangle style pipeline: no vertex input, triangle list,
/// no depth, dynamic viewport and scissor, dynamic rendering.
pub fn createGraphics(ctx: *Context, desc: GraphicsDesc) !vk.Pipeline {
    const vert = try createModule(ctx, desc.vert);
    defer ctx.vkd.destroyShaderModule(ctx.device, vert, null);
    const frag = try createModule(ctx, desc.frag);
    defer ctx.vkd.destroyShaderModule(ctx.device, frag, null);

    const stages = [_]vk.PipelineShaderStageCreateInfo{
        .{ .stage = .{ .vertex = true }, .module = vert, .p_name = "main" },
        .{ .stage = .{ .fragment = true }, .module = frag, .p_name = "main" },
    };
    const vertex_input = vk.PipelineVertexInputStateCreateInfo{};
    const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{ .topology = .triangle_list, .primitive_restart_enable = .false };
    const viewport = vk.PipelineViewportStateCreateInfo{ .viewport_count = 1, .scissor_count = 1 };
    const raster = vk.PipelineRasterizationStateCreateInfo{
        .depth_clamp_enable = .false,
        .rasterizer_discard_enable = .false,
        .polygon_mode = .fill,
        .cull_mode = .{},
        .front_face = .counter_clockwise,
        .depth_bias_enable = .false,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1,
    };
    const multisample = vk.PipelineMultisampleStateCreateInfo{
        .rasterization_samples = .{ .@"1" = true },
        .sample_shading_enable = .false,
        .min_sample_shading = 1,
        .alpha_to_coverage_enable = .false,
        .alpha_to_one_enable = .false,
    };
    const blend_attachment = vk.PipelineColorBlendAttachmentState{
        .blend_enable = if (desc.blend == .alpha) .true else .false,
        .src_color_blend_factor = .src_alpha,
        .dst_color_blend_factor = .one_minus_src_alpha,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .one_minus_src_alpha,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r = true, .g = true, .b = true, .a = true },
    };
    const blend = vk.PipelineColorBlendStateCreateInfo{
        .logic_op_enable = .false,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @ptrCast(&blend_attachment),
        .blend_constants = .{ 0, 0, 0, 0 },
    };
    const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
    const dynamic = vk.PipelineDynamicStateCreateInfo{ .dynamic_state_count = dynamic_states.len, .p_dynamic_states = &dynamic_states };
    const rendering = vk.PipelineRenderingCreateInfo{
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachment_formats = @ptrCast(&desc.color_format),
        .depth_attachment_format = .undefined,
        .stencil_attachment_format = .undefined,
    };
    const info = vk.GraphicsPipelineCreateInfo{
        .p_next = &rendering,
        .stage_count = stages.len,
        .p_stages = &stages,
        .p_vertex_input_state = &vertex_input,
        .p_input_assembly_state = &input_assembly,
        .p_viewport_state = &viewport,
        .p_rasterization_state = &raster,
        .p_multisample_state = &multisample,
        .p_color_blend_state = &blend,
        .p_dynamic_state = &dynamic,
        .layout = ctx.pipeline_layout,
        .subpass = 0,
        .base_pipeline_index = -1,
    };
    var pipeline: vk.Pipeline = undefined;
    _ = try ctx.vkd.createGraphicsPipelines(ctx.device, .null, &.{info}, null, @ptrCast(&pipeline));
    return pipeline;
}

pub fn destroy(ctx: *Context, pipeline: vk.Pipeline) void {
    ctx.vkd.destroyPipeline(ctx.device, pipeline, null);
}

/// Push a struct as push constants (all stages, offset 0).
pub fn push(ctx: *const Context, cmd: vk.CommandBuffer, value: anytype) void {
    const T = @TypeOf(value);
    comptime std.debug.assert(@sizeOf(T) <= @import("constants.zig").push_constant_bytes);
    ctx.vkd.cmdPushConstants(cmd, ctx.pipeline_layout, .{ .compute = true, .vertex = true, .fragment = true }, 0, @sizeOf(T), &value);
}

//! SDL3 window, Vulkan surface and per-frame input snapshot. Gameplay and
//! tools read `Input`; nothing outside this file calls SDL.
const std = @import("std");
const c = @import("sdl");
const vk = @import("vulkan");

const log = std.log.scoped(.platform);

pub const Input = struct {
    quit: bool = false,
    resized: bool = false,
    /// Cursor in framebuffer pixels.
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    /// Cursor motion this frame, framebuffer pixels.
    mouse_dx: f32 = 0,
    mouse_dy: f32 = 0,
    left: bool = false,
    right: bool = false,
    middle: bool = false,
    /// Wheel steps this frame (positive = away from the user).
    wheel: f32 = 0,
    /// Keys that went down this frame (no repeats), by SDL scancode.
    pressed: [512]bool = @splat(false),
    /// Keys held, by SDL scancode.
    down: [512]bool = @splat(false),

    pub fn wasPressed(self: *const Input, scancode: c_int) bool {
        return self.pressed[@intCast(scancode)];
    }
    pub fn isDown(self: *const Input, scancode: c_int) bool {
        return self.down[@intCast(scancode)];
    }
};

pub const Window = struct {
    handle: *c.SDL_Window,
    input: Input = .{},

    pub fn init(title: [*:0]const u8, width: u32, height: u32) !Window {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
            log.err("SDL_Init: {s}", .{c.SDL_GetError()});
            return error.SdlInit;
        }
        errdefer c.SDL_Quit();
        const flags = c.SDL_WINDOW_VULKAN | c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY;
        const handle = c.SDL_CreateWindow(title, @intCast(width), @intCast(height), flags) orelse {
            log.err("SDL_CreateWindow: {s}", .{c.SDL_GetError()});
            return error.SdlWindow;
        };
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Window) void {
        c.SDL_DestroyWindow(self.handle);
        c.SDL_Quit();
    }

    /// Instance extensions SDL needs for surface creation.
    pub fn instanceExtensions() []const [*:0]const u8 {
        var count: u32 = 0;
        const names = c.SDL_Vulkan_GetInstanceExtensions(&count);
        if (names == null) return &.{};
        const ptr: [*]const [*:0]const u8 = @ptrCast(names);
        return ptr[0..count];
    }

    pub fn createSurface(context: *anyopaque, instance: vk.Instance) anyerror!vk.SurfaceKHR {
        const self: *Window = @ptrCast(@alignCast(context));
        var surface: c.VkSurfaceKHR = null;
        if (!c.SDL_Vulkan_CreateSurface(self.handle, @ptrCast(instance), null, &surface)) {
            log.err("SDL_Vulkan_CreateSurface: {s}", .{c.SDL_GetError()});
            return error.SdlSurface;
        }
        return @fromBackingInt(@intCast(@intFromPtr(surface)));
    }

    pub fn pixelSize(self: *const Window) struct { u32, u32 } {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(self.handle, &w, &h);
        return .{ @intCast(@max(w, 1)), @intCast(@max(h, 1)) };
    }

    /// Drain SDL events into a fresh `Input` snapshot.
    pub fn poll(self: *Window) *const Input {
        const prev_x = self.input.mouse_x;
        const prev_y = self.input.mouse_y;
        self.input.pressed = @splat(false);
        self.input.wheel = 0;
        self.input.resized = false;
        var ev: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&ev)) {
            switch (ev.type) {
                c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => self.input.quit = true,
                c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => self.input.resized = true,
                c.SDL_EVENT_KEY_DOWN => {
                    const sc: usize = @intCast(ev.key.scancode);
                    if (!ev.key.repeat and sc < self.input.pressed.len) self.input.pressed[sc] = true;
                },
                c.SDL_EVENT_MOUSE_WHEEL => self.input.wheel += ev.wheel.y,
                else => {},
            }
        }
        var n: c_int = 0;
        const keys = c.SDL_GetKeyboardState(&n);
        for (0..@min(@as(usize, @intCast(n)), self.input.down.len)) |i| self.input.down[i] = keys[i];

        var mx: f32 = 0;
        var my: f32 = 0;
        const buttons = c.SDL_GetMouseState(&mx, &my);
        const density = c.SDL_GetWindowPixelDensity(self.handle);
        self.input.mouse_x = mx * density;
        self.input.mouse_y = my * density;
        self.input.mouse_dx = self.input.mouse_x - prev_x;
        self.input.mouse_dy = self.input.mouse_y - prev_y;
        self.input.left = buttons & c.SDL_BUTTON_LMASK != 0;
        self.input.right = buttons & c.SDL_BUTTON_RMASK != 0;
        self.input.middle = buttons & c.SDL_BUTTON_MMASK != 0;
        return &self.input;
    }
};

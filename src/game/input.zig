//! Gameplay input for one tick, filled from SDL by the app or from a
//! playtest script. Edges (`*_pressed`, `*_released`, `select`, `wheel`)
//! are latched by the producer until a tick consumes them (`consumeEdges`),
//! so a press on a frame that records no tick is not lost.
pub const Input = struct {
    left: bool = false,
    right: bool = false,
    up: bool = false,
    down: bool = false,
    jump: bool = false,
    primary: bool = false,
    secondary: bool = false,
    jump_pressed: bool = false,
    down_pressed: bool = false,
    primary_pressed: bool = false,
    primary_released: bool = false,
    secondary_pressed: bool = false,
    secondary_released: bool = false,
    /// Tool slot chosen this tick (0-9: keys 1..9, 0).
    select: ?u8 = null,
    /// Wheel steps.
    wheel: i32 = 0,
    /// Cursor in world pixels.
    aim: [2]f32 = .{ 0, 0 },

    /// Clear the edges after a tick used them.
    pub fn consumeEdges(self: *Input) void {
        self.jump_pressed = false;
        self.down_pressed = false;
        self.primary_pressed = false;
        self.primary_released = false;
        self.secondary_pressed = false;
        self.secondary_released = false;
        self.select = null;
        self.wheel = 0;
    }

    /// Set held state and latch edges from the previous held state.
    pub fn setButtons(self: *Input, jump: bool, down: bool, primary: bool, secondary: bool) void {
        if (jump and !self.jump) self.jump_pressed = true;
        if (down and !self.down) self.down_pressed = true;
        if (primary and !self.primary) self.primary_pressed = true;
        if (!primary and self.primary) self.primary_released = true;
        if (secondary and !self.secondary) self.secondary_pressed = true;
        if (!secondary and self.secondary) self.secondary_released = true;
        self.jump = jump;
        self.down = down;
        self.primary = primary;
        self.secondary = secondary;
    }
};

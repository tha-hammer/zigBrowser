const std = @import("std");
const display_mod = @import("display.zig");
const event_loop = @import("platform/event_loop.zig");

pub const c = @cImport({
    @cInclude("sdl2.h");
});

pub const SdlError = error{
    SdlInitFailed,
    WindowCreateFailed,
    RendererCreateFailed,
    TextureCreateFailed,
    TextureUpdateFailed,
};

pub const PollResult = union(enum) {
    event: event_loop.Event,
    quit,
};

pub fn hasSdl2Headers() bool {
    return c.ZB_HAS_SDL2 == 1;
}

pub const SdlDisplay = struct {
    window: ?*c.SDL_Window = null,
    renderer: ?*c.SDL_Renderer = null,
    texture: ?*c.SDL_Texture = null,
    width: u32,
    height: u32,

    pub fn init(width: u32, height: u32) SdlError!SdlDisplay {
        try sdlCheck(c.SDL_Init(c.SDL_INIT_VIDEO), error.SdlInitFailed);
        errdefer c.SDL_Quit();

        const window = try sdlCheckPtr(
            c.SDL_CreateWindow(
                "zigBrowser",
                c.SDL_WINDOWPOS_CENTERED,
                c.SDL_WINDOWPOS_CENTERED,
                @as(c_int, @intCast(width)),
                @as(c_int, @intCast(height)),
                c.SDL_WINDOW_RESIZABLE,
            ),
            error.WindowCreateFailed,
        );
        errdefer c.SDL_DestroyWindow(window);

        const renderer = try sdlCheckPtr(
            c.SDL_CreateRenderer(window, -1, 0),
            error.RendererCreateFailed,
        );
        errdefer c.SDL_DestroyRenderer(renderer);

        const texture = try sdlCheckPtr(
            c.SDL_CreateTexture(
                renderer,
                c.SDL_PIXELFORMAT_ARGB8888,
                c.SDL_TEXTUREACCESS_STREAMING,
                @as(c_int, @intCast(width)),
                @as(c_int, @intCast(height)),
            ),
            error.TextureCreateFailed,
        );
        errdefer c.SDL_DestroyTexture(texture);

        return .{
            .window = window,
            .renderer = renderer,
            .texture = texture,
            .width = width,
            .height = height,
        };
    }

    pub fn deinitOwned(self: *SdlDisplay) void {
        if (self.texture) |texture| {
            c.SDL_DestroyTexture(texture);
            self.texture = null;
        }
        if (self.renderer) |renderer| {
            c.SDL_DestroyRenderer(renderer);
            self.renderer = null;
        }
        if (self.window) |window| {
            c.SDL_DestroyWindow(window);
            self.window = null;
        }
        c.SDL_Quit();
    }

    pub fn display(self: *SdlDisplay) display_mod.Display {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn present(ptr: *anyopaque, pixels: []const u32, width: u32, height: u32) display_mod.DisplayError!void {
        const self: *SdlDisplay = @ptrCast(@alignCast(ptr));
        const expected_len = std.math.mul(usize, width, height) catch return error.DimensionMismatch;
        if (pixels.len != expected_len) return error.DimensionMismatch;
        if (width != self.width or height != self.height) return error.DimensionMismatch;

        const texture = self.texture orelse return error.BackendFailure;
        const renderer = self.renderer orelse return error.BackendFailure;

        const pitch = std.math.mul(u32, width, @sizeOf(u32)) catch return error.DimensionMismatch;
        sdlCheck(
            c.SDL_UpdateTexture(texture, null, @ptrCast(pixels.ptr), @as(c_int, @intCast(pitch))),
            error.TextureUpdateFailed,
        ) catch return error.BackendFailure;
        sdlCheck(c.SDL_RenderClear(renderer), error.TextureUpdateFailed) catch return error.BackendFailure;
        sdlCheck(c.SDL_RenderCopy(renderer, texture, null, null), error.TextureUpdateFailed) catch return error.BackendFailure;
        c.SDL_RenderPresent(renderer);
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *SdlDisplay = @ptrCast(@alignCast(ptr));
        self.deinitOwned();
    }

    const vtable = display_mod.Display.VTable{
        .present = present,
        .deinit = deinit,
    };
};

pub fn pollOneEvent() ?PollResult {
    var raw = std.mem.zeroes(c.SDL_Event);
    if (c.SDL_PollEvent(&raw) == 0) return null;
    return translateSdlEvent(&raw);
}

pub fn translateSdlEvent(raw: *const c.SDL_Event) ?PollResult {
    switch (raw.type) {
        c.SDL_QUIT => return .quit,
        c.SDL_MOUSEWHEEL => return .{ .event = .{ .scroll = @as(f32, @floatFromInt(raw.wheel.y)) } },
        c.SDL_MOUSEBUTTONDOWN => {
            return .{ .event = .{ .click = .{
                .x = @floatFromInt(raw.button.x),
                .y = @floatFromInt(raw.button.y),
            } } };
        },
        c.SDL_WINDOWEVENT => {
            if (raw.window.event == c.SDL_WINDOWEVENT_RESIZED) {
                return .{ .event = .{ .resize = .{
                    .w = @floatFromInt(raw.window.data1),
                    .h = @floatFromInt(raw.window.data2),
                } } };
            }
        },
        else => {},
    }
    return null;
}

fn sdlCheck(status: c_int, err: SdlError) SdlError!void {
    if (status < 0) {
        std.debug.print("SDL failure: {s}\n", .{sdlErrorText()});
        return err;
    }
}

fn sdlCheckPtr(ptr: anytype, err: SdlError) SdlError!@TypeOf(ptr.?) {
    if (ptr == null) {
        std.debug.print("SDL failure: {s}\n", .{sdlErrorText()});
        return err;
    }
    return ptr.?;
}

fn sdlErrorText() []const u8 {
    const text = c.SDL_GetError();
    return if (text == null) "unknown SDL error" else std.mem.span(text);
}

test "0b.3 sdlCheck is the raw SDL status normalization boundary" {
    try sdlCheck(0, error.SdlInitFailed);
    try std.testing.expectError(error.SdlInitFailed, sdlCheck(-1, error.SdlInitFailed));
}

test "0b.4 event translation maps wheel click resize and quit" {
    var wheel = std.mem.zeroes(c.SDL_Event);
    wheel.type = c.SDL_MOUSEWHEEL;
    wheel.wheel.y = 2;
    const mapped_wheel = translateSdlEvent(&wheel) orelse return error.TestExpectedEqual;
    switch (mapped_wheel) {
        .event => |ev| switch (ev) {
            .scroll => |delta| try std.testing.expectEqual(@as(f32, 2), delta),
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }

    var click = std.mem.zeroes(c.SDL_Event);
    click.type = c.SDL_MOUSEBUTTONDOWN;
    click.button.x = 10;
    click.button.y = 20;
    const mapped_click = translateSdlEvent(&click) orelse return error.TestExpectedEqual;
    switch (mapped_click) {
        .event => |ev| switch (ev) {
            .click => |point| {
                try std.testing.expectEqual(@as(f32, 10), point.x);
                try std.testing.expectEqual(@as(f32, 20), point.y);
            },
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }

    var resize = std.mem.zeroes(c.SDL_Event);
    resize.type = c.SDL_WINDOWEVENT;
    resize.window.event = c.SDL_WINDOWEVENT_RESIZED;
    resize.window.data1 = 640;
    resize.window.data2 = 480;
    const mapped_resize = translateSdlEvent(&resize) orelse return error.TestExpectedEqual;
    switch (mapped_resize) {
        .event => |ev| switch (ev) {
            .resize => |size| {
                try std.testing.expectEqual(@as(f32, 640), size.w);
                try std.testing.expectEqual(@as(f32, 480), size.h);
            },
            else => return error.TestExpectedEqual,
        },
        else => return error.TestExpectedEqual,
    }

    var quit = std.mem.zeroes(c.SDL_Event);
    quit.type = c.SDL_QUIT;
    const mapped_quit = translateSdlEvent(&quit) orelse return error.TestExpectedEqual;
    try std.testing.expect(mapped_quit == .quit);
}

test "0b.3 SdlDisplay init+present under SDL_VIDEODRIVER=dummy" {
    if (!hasSdl2Headers()) return error.SkipZigTest;
    const driver = std.c.getenv("SDL_VIDEODRIVER") orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, std.mem.span(driver), "dummy")) return error.SkipZigTest;

    var display = try SdlDisplay.init(2, 2);
    defer display.deinitOwned();

    const frame = [_]u32{
        0xFF000000, 0xFFFFFFFF,
        0xFF00FF00, 0xFFFF0000,
    };
    try display.display().present(&frame, 2, 2);
}

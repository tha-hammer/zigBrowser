const std = @import("std");

const app = @import("zigBrowser");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const command = app.cli.parseArgs(args);

    switch (command) {
        .version => {
            var out_buffer: [64]u8 = undefined;
            var writer: std.Io.File.Writer = .init(.stdout(), init.io, &out_buffer);
            try writer.interface.writeAll("zigBrowser 0.1.0\n");
            try writer.interface.flush();
        },
        .open => |url_text| {
            const parsed = try app.net.url.parse(arena, url_text);
            var page = app.page.Page.init(arena, app.script.NoopEngine.make());
            defer page.deinit();
            try page.navigate(init.io, parsed);
        },
        .usage => {
            var err_buffer: [128]u8 = undefined;
            var writer: std.Io.File.Writer = .init(.stderr(), init.io, &err_buffer);
            try writer.interface.writeAll("usage: zigBrowser [--version|URL]\n");
            try writer.interface.flush();
            return error.InvalidArguments;
        },
    }
}

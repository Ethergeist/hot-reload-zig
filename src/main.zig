const std = @import("std");
const Plugin = @import("plugin").Plugin;

fn writeFn(level: u8, msg: [*:0]const u8) callconv(.c) void {
    const s = std.mem.span(msg);
    switch (@as(std.log.Level, @enumFromInt(level))) {
        .err => std.log.err("{s}", .{s}),
        .warn => std.log.warn("{s}", .{s}),
        .info => std.log.info("{s}", .{s}),
        .debug => std.log.debug("{s}", .{s}),
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const log = Plugin.Log{ ._write = writeFn };

    var plugin = try Plugin.init(allocator, log, "plugin-test");
    defer plugin.deinit();
    try plugin.open();

    std.log.info("Running. Edit src/plugin-test/plugin.zig and rebuild to hot reload.", .{});

    while (true) {
        try plugin.onUpdate();
        try plugin.checkForUpdate();
        std.Thread.sleep(16 * std.time.ns_per_ms);
    }
}

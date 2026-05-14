const std = @import("std");
const memcached = @import("memcached");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Connect
    var client = try memcached.connect(allocator, io, "localhost:11211");
    defer client.deinit();

    // Version
    var ver_buf: [64]u8 = undefined;
    const ver = try client.version(&ver_buf);
    std.debug.print("Connected to memcached version: {s}\n", .{ver});

    // Set
    try client.set("hello", "world", .{});
    std.debug.print("SET hello = world\n", .{});

    // Get
    var buf: [1024]u8 = undefined;
    if (try client.get("hello", &buf, .{})) |info| {
        std.debug.print("GET hello = {s} (flags={d}, cas={d})\n", .{ info.value, info.flags, info.cas });
    } else {
        std.debug.print("GET hello = (not found)\n", .{});
    }

    // Set with TTL and flags
    try client.set("test", "value123", .{ .ttl = 60, .flags = 42 });
    std.debug.print("SET test = value123 (ttl=60, flags=42)\n", .{});

    if (try client.get("test", &buf, .{})) |info| {
        std.debug.print("GET test = {s} (flags={d}, cas={d})\n", .{ info.value, info.flags, info.cas });
    }

    // Delete
    try client.delete("hello");
    std.debug.print("DELETE hello\n", .{});

    if (try client.get("hello", &buf, .{})) |info| {
        std.debug.print("GET hello = {s}\n", .{info.value});
    } else {
        std.debug.print("GET hello = (not found)\n", .{});
    }

    std.debug.print("\nDone!\n", .{});
}

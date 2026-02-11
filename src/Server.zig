const std = @import("std");
const Allocator = std.mem.Allocator;
const Pool = @import("Pool.zig");

const Server = @This();

host: []const u8,
port: u16,
pool: Pool,
hash_id: u64, // precomputed hash for rendezvous

pub fn init(gpa: Allocator, host: []const u8, port: u16, pool_opts: Pool.Options) Server {
    // Precompute server identity hash
    var h = std.hash.Wyhash.init(0);
    h.update(host);
    h.update(std.mem.asBytes(&port));

    return .{
        .host = host,
        .port = port,
        .pool = Pool.init(gpa, host, port, pool_opts),
        .hash_id = h.final(),
    };
}

pub fn deinit(self: *Server) void {
    self.pool.deinit();
}

test "hash_id is deterministic" {
    const s1 = Server.init(std.testing.allocator, "localhost", 11211, .{});
    const s2 = Server.init(std.testing.allocator, "localhost", 11211, .{});
    try std.testing.expectEqual(s1.hash_id, s2.hash_id);
}

test "hash_id differs for different servers" {
    const s1 = Server.init(std.testing.allocator, "server1", 11211, .{});
    const s2 = Server.init(std.testing.allocator, "server2", 11211, .{});
    try std.testing.expect(s1.hash_id != s2.hash_id);
}

test "hash_id differs for different ports" {
    const s1 = Server.init(std.testing.allocator, "localhost", 11211, .{});
    const s2 = Server.init(std.testing.allocator, "localhost", 11212, .{});
    try std.testing.expect(s1.hash_id != s2.hash_id);
}

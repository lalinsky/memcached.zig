const std = @import("std");
const Server = @import("Server.zig");

pub const Hasher = union(enum) {
    none,
    rendezvous,
    // maglev: MaglevTable, // later

    pub fn pick(self: Hasher, servers: []const Server, key: []const u8) usize {
        if (servers.len <= 1) return 0;

        return switch (self) {
            .none => unreachable, // handled by Client with atomic counter
            .rendezvous => rendezvousHash(servers, key),
        };
    }
};

fn rendezvousHash(servers: []const Server, key: []const u8) usize {
    var best: u64 = 0;
    var index: usize = 0;

    for (servers, 0..) |server, i| {
        // Use precomputed server hash_id as seed, hash the key
        var h = std.hash.XxHash64.init(server.hash_id);
        h.update(key);
        const score = h.final();

        if (score > best) {
            best = score;
            index = i;
        }
    }
    return index;
}

test "rendezvous deterministic" {
    const servers = &[_]Server{
        .{ .hash_id = 111, .host = "s1", .port = 11211, .pool = undefined },
        .{ .hash_id = 222, .host = "s2", .port = 11211, .pool = undefined },
        .{ .hash_id = 333, .host = "s3", .port = 11211, .pool = undefined },
    };

    // Same key should always pick same server
    const idx1 = rendezvousHash(servers, "mykey");
    const idx2 = rendezvousHash(servers, "mykey");
    try std.testing.expectEqual(idx1, idx2);

    // Different keys may pick different servers
    _ = rendezvousHash(servers, "other");
}

test "rendezvous distribution" {
    const servers = &[_]Server{
        .{ .hash_id = 100, .host = "s1", .port = 11211, .pool = undefined },
        .{ .hash_id = 200, .host = "s2", .port = 11211, .pool = undefined },
        .{ .hash_id = 300, .host = "s3", .port = 11211, .pool = undefined },
    };

    var counts = [_]usize{ 0, 0, 0 };
    var buf: [32]u8 = undefined;

    for (0..1000) |i| {
        const key = std.fmt.bufPrint(&buf, "key{d}", .{i}) catch unreachable;
        const idx = rendezvousHash(servers, key);
        counts[idx] += 1;
    }

    // Each server should get roughly 1/3 of keys (with some variance)
    for (counts) |c| {
        try std.testing.expect(c > 200); // at least 20%
        try std.testing.expect(c < 500); // at most 50%
    }
}

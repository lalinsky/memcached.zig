const std = @import("std");
const Allocator = std.mem.Allocator;
const Connection = @import("Connection.zig");
const Pool = @import("Pool.zig");
const Protocol = @import("Protocol.zig");
const Server = @import("Server.zig");
const Hasher = @import("hasher.zig").Hasher;

const log = std.log.scoped(.memcached);

const Client = @This();

gpa: Allocator,
io: std.Io,
servers: []Server,
hasher: Hasher,
round_robin: std.atomic.Value(usize),

pub const Options = struct {
    servers: []const []const u8 = &.{},
    /// Which server a key goes to. Rendezvous hashing by default; `.none`
    /// spreads even the same key over all of them, which only suits servers
    /// that all hold the same data.
    hasher: Hasher = .rendezvous,
    max_idle: usize = 2,
    read_buffer_size: usize = 4096,
    write_buffer_size: usize = 4096,
    connect_timeout: std.Io.Timeout = .none,
};

// Re-export types for convenience
pub const Info = Connection.Info;
pub const GetOpts = Connection.GetOpts;
pub const SetOpts = Connection.SetOpts;
pub const Error = Connection.Error;

pub fn init(gpa: Allocator, io: std.Io, options: Options) !Client {
    if (options.servers.len == 0) return error.NoServers;

    const servers = try gpa.alloc(Server, options.servers.len);
    errdefer gpa.free(servers);

    const pool_opts: Pool.Options = .{
        .max_idle = options.max_idle,
        .read_buffer_size = options.read_buffer_size,
        .write_buffer_size = options.write_buffer_size,
        .connect_timeout = options.connect_timeout,
    };

    for (options.servers, 0..) |server_str, i| {
        const host, const port = parseServer(server_str) orelse return error.InvalidServer;
        servers[i] = Server.init(gpa, io, host, port, pool_opts);
    }

    return .{
        .gpa = gpa,
        .io = io,
        .servers = servers,
        .hasher = options.hasher,
        .round_robin = std.atomic.Value(usize).init(0),
    };
}

pub fn deinit(self: *Client) void {
    for (self.servers) |*server| {
        server.deinit();
    }
    self.gpa.free(self.servers);
}

/// The index in `Options.servers` of the server `key` goes to. With the
/// `.none` hasher, the next one in turn.
pub fn serverIndex(self: *Client, key: []const u8) usize {
    if (self.servers.len == 1) return 0;
    return switch (self.hasher) {
        .none => self.round_robin.fetchAdd(1, .monotonic) % self.servers.len,
        else => self.hasher.pick(self.servers, key),
    };
}

fn pickServer(self: *Client, key: []const u8) *Server {
    return &self.servers[self.serverIndex(key)];
}

fn withConnection(self: *Client, key: []const u8, comptime func: anytype, args: anytype) !ReturnType(func) {
    return withServer(self.pickServer(key), func, args);
}

fn withAnyConnection(self: *Client, comptime func: anytype, args: anytype) !ReturnType(func) {
    const index = self.round_robin.fetchAdd(1, .monotonic) % self.servers.len;
    return withServer(&self.servers[index], func, args);
}

/// Runs `func` on a connection from the server's pool. A connection that
/// failed in a way that may have left it mid-response is closed rather than
/// returned to the pool, so a canceled call never leaves one behind for the
/// next caller. Nothing is retried: a connection that went stale while
/// idle, as after a server restart, fails the one call that picks it up.
fn withServer(server: *Server, comptime func: anytype, args: anytype) !ReturnType(func) {
    const conn = try server.pool.acquire();
    var ok = false;
    defer server.pool.release(conn, ok);

    const result = @call(.auto, func, .{conn} ++ args) catch |err| {
        log.debug("{s}:{d} operation error: {}", .{ server.host, server.port, err });
        ok = Protocol.isResumable(err);
        return err;
    };
    ok = true;
    return result;
}

fn ReturnType(comptime func: anytype) type {
    const Return = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
    return @typeInfo(Return).error_union.payload;
}

/// Splits `host:port`, where an IPv6 host is in brackets, `[::1]:11211`.
fn parseServer(server: []const u8) ?struct { []const u8, u16 } {
    const colon_pos = std.mem.lastIndexOfScalar(u8, server, ':') orelse return null;
    var host = server[0..colon_pos];
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host = host[1 .. host.len - 1];
    const port = std.fmt.parseInt(u16, server[colon_pos + 1 ..], 10) catch return null;
    return .{ host, port };
}

// --- Key-based operations (use pickServer) ---

pub fn get(self: *Client, key: []const u8, buf: []u8, opts: GetOpts) !?Info {
    return self.withConnection(key, Connection.get, .{ key, buf, opts });
}

pub fn set(self: *Client, key: []const u8, value: []const u8, opts: SetOpts) !void {
    return self.withConnection(key, Connection.set, .{ key, value, opts, .set });
}

pub fn add(self: *Client, key: []const u8, value: []const u8, opts: SetOpts) !void {
    return self.withConnection(key, Connection.set, .{ key, value, opts, .add });
}

pub fn replace(self: *Client, key: []const u8, value: []const u8, opts: SetOpts) !void {
    return self.withConnection(key, Connection.set, .{ key, value, opts, .replace });
}

pub fn append(self: *Client, key: []const u8, value: []const u8) !void {
    return self.withConnection(key, Connection.set, .{ key, value, .{}, .append });
}

pub fn prepend(self: *Client, key: []const u8, value: []const u8) !void {
    return self.withConnection(key, Connection.set, .{ key, value, .{}, .prepend });
}

pub fn delete(self: *Client, key: []const u8) !void {
    return self.withConnection(key, Connection.delete, .{key});
}

pub fn incr(self: *Client, key: []const u8, delta: u64) !u64 {
    return self.withConnection(key, Connection.incr, .{ key, delta });
}

pub fn decr(self: *Client, key: []const u8, delta: u64) !u64 {
    return self.withConnection(key, Connection.decr, .{ key, delta });
}

pub fn touch(self: *Client, key: []const u8, ttl: u32) !void {
    return self.withConnection(key, Connection.touch, .{ key, ttl });
}

/// `Connection.getMulti` on the server at `server` in `Options.servers`,
/// which the keys should all go to, see `serverIndex`.
pub fn getMultiFrom(self: *Client, server: usize, keys: []const []const u8, results: []?Info, buf: []u8, opts: GetOpts) !void {
    return withServer(&self.servers[server], Connection.getMulti, .{ keys, results, buf, opts });
}

/// Gets many keys from all the servers they go to at the same time, with
/// `Connection.getMulti` on each. `results[i]` is the value of `keys[i]`, or
/// null for a miss. Each server's values go into a part of `buf` as large as
/// its share of the keys.
///
/// A server that fails does not hold up the others. Once they are all done,
/// the call fails with the error of one that failed, and `results` has what
/// was read, so null is a miss or a key on a server that failed. The same
/// goes for a canceled call, which fails with `error.Canceled`.
pub fn getMulti(self: *Client, keys: []const []const u8, results: []?Info, buf: []u8, opts: GetOpts) (GetMultiFromError || Allocator.Error)!void {
    std.debug.assert(results.len == keys.len);
    if (self.servers.len == 1) return self.getMultiFrom(0, keys, results, buf, opts);
    @memset(results, null);
    if (keys.len == 0) return;

    // The keys grouped by server, in a counting sort, with where each came
    // from.
    const num_servers = self.servers.len;
    const server_of = try self.gpa.alloc(usize, keys.len);
    defer self.gpa.free(server_of);
    const origin = try self.gpa.alloc(usize, keys.len);
    defer self.gpa.free(origin);
    const grouped_keys = try self.gpa.alloc([]const u8, keys.len);
    defer self.gpa.free(grouped_keys);
    const grouped_results = try self.gpa.alloc(?Info, keys.len);
    defer self.gpa.free(grouped_results);
    @memset(grouped_results, null);
    const starts = try self.gpa.alloc(usize, num_servers + 1);
    defer self.gpa.free(starts);
    const ends = try self.gpa.alloc(usize, num_servers);
    defer self.gpa.free(ends);
    const errors = try self.gpa.alloc(?GetMultiFromError, num_servers);
    defer self.gpa.free(errors);
    @memset(errors, null);

    @memset(starts, 0);
    for (keys, server_of) |key, *server| {
        server.* = self.serverIndex(key);
        starts[server.* + 1] += 1;
    }
    for (1..num_servers + 1) |server| starts[server] += starts[server - 1];
    @memcpy(ends, starts[0..num_servers]);
    for (keys, server_of, 0..) |key, server, i| {
        grouped_keys[ends[server]] = key;
        origin[ends[server]] = i;
        ends[server] += 1;
    }

    // A group may run a task right away on this task, which then takes a
    // cancel meant for this call, and the group drops the `error.Canceled`
    // it returns. So the tasks report it here, and once one has taken it,
    // no more are started.
    var canceled: std.atomic.Value(bool) = .init(false);
    var group: std.Io.Group = .init;
    for (0..num_servers) |server| {
        const from = starts[server];
        const to = starts[server + 1];
        if (from == to) continue;
        group.async(self.io, getMultiTask, .{
            self,
            server,
            grouped_keys[from..to],
            grouped_results[from..to],
            buf[bufShare(buf.len, from, keys.len)..bufShare(buf.len, to, keys.len)],
            opts,
            &errors[server],
            &canceled,
        });
        if (canceled.load(.acquire)) break;
    }
    const awaited = if (canceled.load(.acquire)) blk: {
        group.cancel(self.io);
        break :blk error.Canceled;
    } else group.await(self.io);

    for (grouped_results, origin) |result, i| results[i] = result;
    try awaited;
    if (canceled.load(.acquire)) return error.Canceled;
    for (errors) |err| {
        if (err) |e| return e;
    }
}

const GetMultiFromError = @typeInfo(@typeInfo(@TypeOf(getMultiFrom)).@"fn".return_type.?).error_union.error_set;

/// Where the share of `len` for the keys before `index` of `count` ends.
fn bufShare(len: usize, index: usize, count: usize) usize {
    return @intCast(@as(u128, len) * index / count);
}

fn getMultiTask(
    self: *Client,
    server: usize,
    keys: []const []const u8,
    results: []?Info,
    buf: []u8,
    opts: GetOpts,
    err: *?GetMultiFromError,
    canceled: *std.atomic.Value(bool),
) void {
    self.getMultiFrom(server, keys, results, buf, opts) catch |e| {
        err.* = e;
        if (e == error.Canceled) canceled.store(true, .release);
    };
}

// --- Non-key operations ---

pub fn version(self: *Client, buf: []u8) ![]u8 {
    return self.withAnyConnection(Connection.version, .{buf});
}

// --- Tests ---

test "parseServer" {
    {
        const result = parseServer("localhost:11211");
        try std.testing.expect(result != null);
        try std.testing.expectEqualStrings("localhost", result.?[0]);
        try std.testing.expectEqual(11211, result.?[1]);
    }
    {
        const result = parseServer("invalid");
        try std.testing.expect(result == null);
    }
}

test "parseServer ipv6" {
    const result = parseServer("[::1]:11211");
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("::1", result.?[0]);
    try std.testing.expectEqual(11211, result.?[1]);
}

test "Client get/set" {
    var client = try Client.init(std.testing.allocator, std.testing.io, .{
        .servers = &.{"127.0.0.1:21211"},
    });
    defer client.deinit();

    try client.set("client_test_key", "client_test_value", .{});

    var buf: [1024]u8 = undefined;
    const info = try client.get("client_test_key", &buf, .{});

    try std.testing.expect(info != null);
    try std.testing.expectEqualStrings("client_test_value", info.?.value);
}

test "Client get non-existent returns null" {
    var client = try Client.init(std.testing.allocator, std.testing.io, .{
        .servers = &.{"127.0.0.1:21211"},
    });
    defer client.deinit();

    var buf: [1024]u8 = undefined;
    const info = try client.get("non_existent_client_key", &buf, .{});

    try std.testing.expect(info == null);
}

test "Client incr/decr" {
    var client = try Client.init(std.testing.allocator, std.testing.io, .{
        .servers = &.{"127.0.0.1:21211"},
    });
    defer client.deinit();

    try client.set("client_counter", "100", .{});

    const val1 = try client.incr("client_counter", 10);
    try std.testing.expectEqual(110, val1);

    const val2 = try client.decr("client_counter", 5);
    try std.testing.expectEqual(105, val2);
}

test "Client delete" {
    var client = try Client.init(std.testing.allocator, std.testing.io, .{
        .servers = &.{"127.0.0.1:21211"},
    });
    defer client.deinit();

    try client.set("client_delete_key", "to_delete", .{});
    try client.delete("client_delete_key");

    var buf: [1024]u8 = undefined;
    const info = try client.get("client_delete_key", &buf, .{});
    try std.testing.expect(info == null);
}

test "Client connection reused after NotStored error" {
    var client = try Client.init(std.testing.allocator, std.testing.io, .{
        .servers = &.{"127.0.0.1:21211"},
        .max_idle = 1,
    });
    defer client.deinit();

    // Ensure key doesn't exist
    client.delete("reuse_test_key") catch {};

    // add() on non-existent key succeeds
    try client.add("reuse_test_key", "first", .{});

    // add() again should fail with NotStored - but connection should be reused
    try std.testing.expectError(error.NotStored, client.add("reuse_test_key", "second", .{}));

    // Connection should still work - this would fail if connection was closed
    var buf: [1024]u8 = undefined;
    const info = try client.get("reuse_test_key", &buf, .{});
    try std.testing.expectEqualStrings("first", info.?.value);

    // Verify connection was reused (pool should not be empty)
    try std.testing.expect(!client.servers[0].pool.isEmpty());
}

test "Client connection reused after Exists error (CAS conflict)" {
    var client = try Client.init(std.testing.allocator, std.testing.io, .{
        .servers = &.{"127.0.0.1:21211"},
        .max_idle = 1,
    });
    defer client.deinit();

    try client.set("cas_reuse_key", "original", .{});

    var buf: [1024]u8 = undefined;
    const info = try client.get("cas_reuse_key", &buf, .{});
    const old_cas = info.?.cas;

    // Update the key to invalidate the CAS token
    try client.set("cas_reuse_key", "updated", .{});

    // CAS with old token should fail with Exists - but connection should be reused
    try std.testing.expectError(error.Exists, client.set("cas_reuse_key", "conflict", .{ .cas = old_cas }));

    // Connection should still work
    const info2 = try client.get("cas_reuse_key", &buf, .{});
    try std.testing.expectEqualStrings("updated", info2.?.value);

    // Verify connection was reused
    try std.testing.expect(!client.servers[0].pool.isEmpty());
}

test "Client connection reused after a value too large for the buffer" {
    var client = try Client.init(std.testing.allocator, std.testing.io, .{
        .servers = &.{"127.0.0.1:21211"},
        .max_idle = 1,
    });
    defer client.deinit();

    try client.set("large_value_key", "a value longer than the buffer", .{});
    try client.set("small_value_key", "small", .{});

    var small_buf: [8]u8 = undefined;
    try std.testing.expectError(error.ValueTooLarge, client.get("large_value_key", &small_buf, .{}));
    try std.testing.expect(!client.servers[0].pool.isEmpty());

    // The connection is past the value it could not take, at the next
    // response.
    const info = try client.get("small_value_key", &small_buf, .{});
    try std.testing.expectEqualStrings("small", info.?.value);
    try std.testing.expect(!client.servers[0].pool.isEmpty());
}

test "a canceled call returns Canceled and leaves no connection in the pool" {
    const testing = @import("testing.zig");
    const io = std.testing.io;

    var silent = try testing.SilentServer.init(io);
    defer silent.deinit(io);
    var server_buf: [32]u8 = undefined;
    const server = try std.fmt.bufPrint(&server_buf, "127.0.0.1:{d}", .{silent.port()});

    var client = try Client.init(std.testing.allocator, io, .{ .servers = &.{server}, .max_idle = 1 });
    defer client.deinit();

    var buf: [64]u8 = undefined;
    var future = try io.concurrent(Client.get, .{ &client, "never_answered", &buf, GetOpts{} });
    // Let it send the request and block on the response.
    try io.sleep(.fromMilliseconds(50), .awake);
    try std.testing.expectError(error.Canceled, future.cancel(io));
    // The connection is mid-response, so it is closed, not pooled.
    try std.testing.expect(client.servers[0].pool.isEmpty());
}

test "Client getMulti across servers" {
    var client = try Client.init(std.testing.allocator, std.testing.io, .{
        .servers = &.{ "127.0.0.1:21211", "127.0.0.1:21212", "127.0.0.1:21213" },
    });
    defer client.deinit();

    const n = 300;
    var key_bufs: [n][24]u8 = undefined;
    var keys: [n][]const u8 = undefined;
    var on_server = [_]usize{ 0, 0, 0 };
    for (&keys, &key_bufs, 0..) |*key, *key_buf, i| {
        key.* = try std.fmt.bufPrint(key_buf, "client_multi_{d}", .{i});
        on_server[client.serverIndex(key.*)] += 1;
        // Every fifth one is a miss.
        if (i % 5 == 0) {
            client.delete(key.*) catch {};
        } else {
            try client.set(key.*, key.*, .{});
        }
    }
    for (on_server) |count| try std.testing.expect(count > 0);

    var results: [n]?Info = undefined;
    var buf: [n * 24]u8 = undefined;
    try client.getMulti(&keys, &results, &buf, .{});
    for (keys, results, 0..) |key, result, i| {
        if (i % 5 == 0) {
            try std.testing.expectEqual(null, result);
        } else {
            try std.testing.expectEqualStrings(key, result.?.value);
        }
    }
}

test "Client getMulti gets what it can when a server is down" {
    var client = try Client.init(std.testing.allocator, std.testing.io, .{
        // Nothing listens on port 1.
        .servers = &.{ "127.0.0.1:21211", "127.0.0.1:21212", "127.0.0.1:1" },
    });
    defer client.deinit();

    const n = 60;
    var key_bufs: [n][24]u8 = undefined;
    var keys: [n][]const u8 = undefined;
    for (&keys, &key_bufs, 0..) |*key, *key_buf, i| {
        key.* = try std.fmt.bufPrint(key_buf, "partial_multi_{d}", .{i});
        if (client.serverIndex(key.*) != 2) try client.set(key.*, key.*, .{});
    }

    var results: [n]?Info = undefined;
    var buf: [n * 24]u8 = undefined;
    try std.testing.expectError(error.ConnectionRefused, client.getMulti(&keys, &results, &buf, .{}));
    for (keys, results) |key, result| {
        if (client.serverIndex(key) == 2) {
            try std.testing.expectEqual(null, result);
        } else {
            try std.testing.expectEqualStrings(key, result.?.value);
        }
    }
}

test "a canceled Client getMulti leaves no connection mid-response in a pool" {
    const testing = @import("testing.zig");
    const io = std.testing.io;

    var silent = try testing.SilentServer.init(io);
    defer silent.deinit(io);
    var server_buf: [32]u8 = undefined;
    const silent_server = try std.fmt.bufPrint(&server_buf, "127.0.0.1:{d}", .{silent.port()});

    var client = try Client.init(std.testing.allocator, io, .{
        .servers = &.{ "127.0.0.1:21211", silent_server },
        .max_idle = 1,
    });
    defer client.deinit();

    // Keys for both servers.
    var key_bufs: [20][24]u8 = undefined;
    var keys: [20][]const u8 = undefined;
    for (&keys, &key_bufs, 0..) |*key, *key_buf, i| key.* = try std.fmt.bufPrint(key_buf, "canceled_multi_{d}", .{i});

    var results: [keys.len]?Info = undefined;
    var buf: [256]u8 = undefined;
    var future = try io.concurrent(Client.getMulti, .{ &client, &keys, &results, &buf, GetOpts{} });
    // Until the server that answers is done, and its connection is back.
    try waitUntilPooled(io, &client.servers[0]);
    try std.testing.expectError(error.Canceled, future.cancel(io));

    // The one that never answered had its connection closed.
    try std.testing.expect(client.servers[1].pool.isEmpty());
}

test "a canceled Client getMulti fails with Canceled when its tasks run on the caller" {
    const testing = @import("testing.zig");

    // With one task allowed to run apart, and the getMulti being that one,
    // the group runs each server's task on it.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .async_limit = .limited(1) });
    defer threaded.deinit();
    const io = threaded.io();

    var silent = try testing.SilentServer.init(io);
    defer silent.deinit(io);
    var server_buf: [32]u8 = undefined;
    const silent_server = try std.fmt.bufPrint(&server_buf, "127.0.0.1:{d}", .{silent.port()});

    // The silent server first, so the cancel lands in its task, and the
    // other one has to be skipped.
    var client = try Client.init(std.testing.allocator, io, .{
        .servers = &.{ silent_server, "127.0.0.1:21211" },
    });
    defer client.deinit();

    var key_bufs: [20][24]u8 = undefined;
    var keys: [20][]const u8 = undefined;
    for (&keys, &key_bufs, 0..) |*key, *key_buf, i| key.* = try std.fmt.bufPrint(key_buf, "inline_multi_{d}", .{i});

    var results: [keys.len]?Info = undefined;
    var buf: [256]u8 = undefined;
    var future = try io.concurrent(Client.getMulti, .{ &client, &keys, &results, &buf, GetOpts{} });
    try io.sleep(.fromMilliseconds(50), .awake);
    try std.testing.expectError(error.Canceled, future.cancel(io));
}

test "a canceled Client getMulti does not go on to a server after the cancel was taken" {
    const testing = @import("testing.zig");

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .async_limit = .limited(1) });
    defer threaded.deinit();
    const io = threaded.io();

    // Two servers that never answer, the tasks for both run on the caller:
    // the first takes the cancel, and the second would wait forever.
    var silent_1 = try testing.SilentServer.init(io);
    defer silent_1.deinit(io);
    var silent_2 = try testing.SilentServer.init(io);
    defer silent_2.deinit(io);
    var server_bufs: [2][32]u8 = undefined;
    var client = try Client.init(std.testing.allocator, io, .{ .servers = &.{
        try std.fmt.bufPrint(&server_bufs[0], "127.0.0.1:{d}", .{silent_1.port()}),
        try std.fmt.bufPrint(&server_bufs[1], "127.0.0.1:{d}", .{silent_2.port()}),
    } });
    defer client.deinit();

    var key_bufs: [20][24]u8 = undefined;
    var keys: [20][]const u8 = undefined;
    for (&keys, &key_bufs, 0..) |*key, *key_buf, i| key.* = try std.fmt.bufPrint(key_buf, "skipped_multi_{d}", .{i});
    var on_server = [_]usize{ 0, 0 };
    for (keys) |key| on_server[client.serverIndex(key)] += 1;
    try std.testing.expect(on_server[0] > 0 and on_server[1] > 0);

    var results: [keys.len]?Info = undefined;
    var buf: [256]u8 = undefined;
    var future = try io.concurrent(Client.getMulti, .{ &client, &keys, &results, &buf, GetOpts{} });
    try io.sleep(.fromMilliseconds(50), .awake);
    try std.testing.expectError(error.Canceled, future.cancel(io));
}

fn waitUntilPooled(io: std.Io, server: *Server) !void {
    for (0..500) |_| {
        if (!server.pool.isEmpty()) return;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.Timeout;
}

test "key distribution across servers" {
    const servers = &[_][]const u8{
        "127.0.0.1:21211",
        "127.0.0.1:21212",
        "127.0.0.1:21213",
    };

    // Create distributed client
    var client = try Client.init(std.testing.allocator, std.testing.io, .{
        .servers = servers,
        .hasher = .rendezvous,
    });
    defer client.deinit();

    // Set 100 keys via distributed client
    const num_keys = 100;
    var key_buf: [32]u8 = undefined;
    for (0..num_keys) |i| {
        const key = std.fmt.bufPrint(&key_buf, "dist_test_{d}", .{i}) catch unreachable;
        try client.set(key, "value", .{});
    }

    // Connect to each server individually and count keys found
    var counts = [_]usize{ 0, 0, 0 };

    for (servers, 0..) |server_str, server_idx| {
        const host, const port = parseServer(server_str).?;

        var conn: Connection = undefined;
        try conn.connect(std.testing.allocator, std.testing.io, host, port, .{});
        defer conn.close();

        var buf: [1024]u8 = undefined;
        for (0..num_keys) |i| {
            const key = std.fmt.bufPrint(&key_buf, "dist_test_{d}", .{i}) catch unreachable;
            if (try conn.get(key, &buf, .{})) |_| {
                counts[server_idx] += 1;
            }
        }
    }

    // Verify distribution
    errdefer std.debug.print("\nDistribution: {d} / {d} / {d}\n", .{ counts[0], counts[1], counts[2] });

    var total: usize = 0;
    for (counts) |c| {
        total += c;
        // Each server should have some keys (at least 10%)
        try std.testing.expect(c >= 10);
        // But not all keys (at most 60%)
        try std.testing.expect(c <= 60);
    }

    // Total should equal num_keys (each key on exactly one server)
    try std.testing.expectEqual(num_keys, total);
}

test "a connection gone stale in the pool fails one call, not the next" {
    const testing = @import("testing.zig");
    const io = std.testing.io;

    var client = try Client.init(std.testing.allocator, io, .{
        .servers = &.{"127.0.0.1:21211"},
        .max_idle = 1,
    });
    defer client.deinit();

    try client.set("restart_test_key", "before_restart", .{});
    try std.testing.expect(!client.servers[0].pool.isEmpty());

    try testing.runDockerCompose(std.testing.allocator, io, &.{ "restart", "-t", "0", "memcached-1" });
    try testing.waitForNode(io, testing.node1, .fromSeconds(30));

    // The pooled connection is to the server that went away. Using it
    // fails, and it is closed rather than put back.
    var buf: [1024]u8 = undefined;
    if (client.get("restart_test_key", &buf, .{})) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
    try std.testing.expect(client.servers[0].pool.isEmpty());

    // A new one works; the restart emptied the cache.
    try std.testing.expectEqual(null, try client.get("restart_test_key", &buf, .{}));
}

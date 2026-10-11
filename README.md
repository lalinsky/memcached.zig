# memcached.zig

A memcached client library for Zig, built on `std.Io`. Uses the modern [meta protocol](https://docs.memcached.org/protocols/meta/) for efficient communication.

Works with Zig 0.16 and 0.17.

## Features

- Async I/O via `std.Io`, with any implementation of it
- Connection pooling per server
- Multi-server support with consistent hashing (rendezvous)
- Meta protocol (mg, ms, md, ma commands)
- CAS (compare-and-swap) support
- TTL and flags support

## Example

```zig
const std = @import("std");
const memcached = @import("memcached");

pub fn main(init: std.process.Init) !void {
    var client = try memcached.connect(init.gpa, init.io, "localhost:11211");
    defer client.deinit();

    // Set a value
    try client.set("hello", "world", .{ .ttl = 300 });

    // Get a value
    var buf: [1024]u8 = undefined;
    if (try client.get("hello", &buf, .{})) |info| {
        std.debug.print("Value: {s}\n", .{info.value});
    }

    // Increment a counter
    try client.set("counter", "0", .{});
    const val = try client.incr("counter", 1);
    std.debug.print("Counter: {d}\n", .{val});
}
```

## Multi-server

```zig
var client = try memcached.Client.init(gpa, io, .{
    .servers = &.{
        "server1:11211",
        "server2:11211",
        "server3:11211",
    },
    .hasher = .rendezvous,
});
defer client.deinit();
```

## Getting many keys at once

`getMulti` pipelines meta gets (`mg ... q`, ended by `mn`), so a batch takes
one round trip per server, and the servers are asked at the same time.

```zig
const keys = [_][]const u8{ "a", "b", "c" };
var results: [keys.len]?memcached.Client.Info = undefined;
var buf: [4096]u8 = undefined; // the values go here
try client.getMulti(&keys, &results, &buf, .{});
for (keys, results) |key, result| {
    if (result) |info| std.debug.print("{s} = {s}\n", .{ key, info.value });
}
```

`serverIndex` and `getMultiFrom` do the same for one server at a time, for
callers that want to handle each server on their own.

## Timeouts and cancellation

There are no read or write timeouts and nothing is retried: the caller
decides how long to wait and what to do about a failure. To bound a call,
cancel it, for example by running it with `io.concurrent` and canceling the
future, or with the timeouts of the `std.Io` implementation in use. A
canceled call returns `error.Canceled`, and a connection it left in the
middle of a response is closed, never put back in the pool.

## Installation

Add memcached.zig as a dependency in your `build.zig.zon`:

```bash
zig fetch --save "git+https://github.com/lalinsky/memcached.zig"
```

In your `build.zig`:

```zig
const memcached = b.dependency("memcached", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("memcached", memcached.module("memcached"));
```

## License

MIT

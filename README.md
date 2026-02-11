# memcached.zig

A memcached client library for Zig, built on [zio](https://github.com/lalinsky/zio) for async I/O. Uses the modern [meta protocol](https://github.com/memcached/memcached/wiki/MetaCommands) for efficient communication.

## Features

- Async I/O via zio coroutines
- Connection pooling per server
- Multi-server support with consistent hashing (rendezvous)
- Meta protocol (mg, ms, md, ma commands)
- CAS (compare-and-swap) support
- TTL and flags support

## Example

```zig
const std = @import("std");
const zio = @import("zio");
const memcached = @import("memcached");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var rt = try zio.Runtime.init(gpa.allocator(), .{});
    defer rt.deinit();

    var client = try memcached.connect(gpa.allocator(), "localhost:11211");
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
var client = try memcached.Client.init(gpa.allocator(), .{
    .servers = &.{
        "server1:11211",
        "server2:11211",
        "server3:11211",
    },
    .hasher = .rendezvous,
});
defer client.deinit();
```

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

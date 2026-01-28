//! Tests belong here if they access internal state of std.Io.Threaded or
//! otherwise assume details of that particular implementation.
const builtin = @import("builtin");

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const assert = std.debug.assert;

test "concurrent vs main prevents deadlock via oversubscription" {
    if (true) {
        // https://codeberg.org/ziglang/zig/issues/30141
        return error.SkipZigTest;
    }

    var threaded: Io.Threaded = .init(std.testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();

    threaded.async_limit = .nothing;

    var queue: Io.Queue(u8) = .init(&.{});

    var putter = io.concurrent(put, .{ io, &queue }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => {
            try testing.expect(builtin.single_threaded);
            return;
        },
    };
    defer putter.cancel(io);

    try testing.expectEqual(42, queue.getOneUncancelable(io));
}

fn put(io: Io, queue: *Io.Queue(u8)) void {
    queue.putOneUncancelable(io, 42);
}

fn get(io: Io, queue: *Io.Queue(u8)) void {
    assert(queue.getOneUncancelable(io) == 42);
}

test "concurrent vs concurrent prevents deadlock via oversubscription" {
    if (true) {
        // https://codeberg.org/ziglang/zig/issues/30141
        return error.SkipZigTest;
    }

    var threaded: Io.Threaded = .init(std.testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();

    threaded.async_limit = .nothing;

    var queue: Io.Queue(u8) = .init(&.{});

    var putter = io.concurrent(put, .{ io, &queue }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => {
            try testing.expect(builtin.single_threaded);
            return;
        },
    };
    defer putter.cancel(io);

    var getter = try io.concurrent(get, .{ io, &queue });
    defer getter.cancel(io);

    getter.await(io);
    putter.await(io);
}

const ByteArray256 = struct { x: [32]u8 align(32) };
const ByteArray512 = struct { x: [64]u8 align(64) };

fn concatByteArrays(a: ByteArray256, b: ByteArray256) ByteArray512 {
    return .{ .x = a.x ++ b.x };
}

test "async/concurrent context and result alignment" {
    var buffer: [2048]u8 align(@alignOf(ByteArray512)) = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);

    var threaded: std.Io.Threaded = .init(fba.allocator(), .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();

    const a: ByteArray256 = .{ .x = @splat(2) };
    const b: ByteArray256 = .{ .x = @splat(3) };
    const expected: ByteArray512 = .{ .x = @as([32]u8, @splat(2)) ++ @as([32]u8, @splat(3)) };

    {
        var future = io.async(concatByteArrays, .{ a, b });
        const result = future.await(io);
        try std.testing.expectEqualSlices(u8, &expected.x, &result.x);
    }
    {
        var future = io.concurrent(concatByteArrays, .{ a, b }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {
                try testing.expect(builtin.single_threaded);
                return;
            },
        };
        const result = future.await(io);
        try std.testing.expectEqualSlices(u8, &expected.x, &result.x);
    }
}

fn concatByteArraysResultPtr(a: ByteArray256, b: ByteArray256, result: *ByteArray512) void {
    result.* = .{ .x = a.x ++ b.x };
}

test "Group.async context alignment" {
    var buffer: [2048]u8 align(@alignOf(ByteArray512)) = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);

    var threaded: std.Io.Threaded = .init(fba.allocator(), .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();

    const a: ByteArray256 = .{ .x = @splat(2) };
    const b: ByteArray256 = .{ .x = @splat(3) };
    const expected: ByteArray512 = .{ .x = @as([32]u8, @splat(2)) ++ @as([32]u8, @splat(3)) };

    var group: std.Io.Group = .init;
    var result: ByteArray512 = undefined;
    group.async(io, concatByteArraysResultPtr, .{ a, b, &result });
    try group.await(io);
    try std.testing.expectEqualSlices(u8, &expected.x, &result.x);
}

fn returnArray() [32]u8 {
    return @splat(5);
}

test "async with array return type" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();

    var future = io.async(returnArray, .{});
    const result = future.await(io);
    try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(5)), &result);
}

test "cancel blocked read from pipe" {
    const global = struct {
        fn readFromPipe(io: Io, pipe: Io.File) !void {
            var buf: [1]u8 = undefined;
            if (pipe.readStreaming(io, &.{&buf})) |_| {
                return error.UnexpectedData;
            } else |err| switch (err) {
                error.Canceled => return,
                else => |e| return e,
            }
        }
    };

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();

    var read_end: Io.File = undefined;
    var write_end: Io.File = undefined;
    switch (builtin.target.os.tag) {
        .wasi => return error.SkipZigTest,
        .windows => try std.os.windows.CreatePipe(&read_end.handle, &write_end.handle, &.{
            .nLength = @sizeOf(std.os.windows.SECURITY_ATTRIBUTES),
            .lpSecurityDescriptor = null,
            .bInheritHandle = std.os.windows.FALSE,
        }),
        else => {
            const pipe = try std.Io.Threaded.pipe2(.{});
            read_end = .{ .handle = pipe[0] };
            write_end = .{ .handle = pipe[1] };
        },
    }
    defer {
        read_end.close(io);
        write_end.close(io);
    }

    var future = io.concurrent(global.readFromPipe, .{ io, read_end }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
    };
    defer _ = future.cancel(io) catch {};
    try io.sleep(.fromMilliseconds(10), .awake);
    try future.cancel(io);
}

test "memory mapping fallback" {
    if (builtin.os.tag == .wasi and builtin.link_libc) {
        // https://github.com/ziglang/zig/issues/20747 (open fd does not have write permission)
        return error.SkipZigTest;
    }

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
        .disable_memory_mapping = true,
    });
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "blah.txt",
        .data = "this is my data123",
    });

    {
        var file = try tmp.dir.openFile(io, "blah.txt", .{ .mode = .read_write });
        defer file.close(io);

        // The `Io.File.MemoryMap` API does not specify what happens if we supply a
        // length greater than file size, but this is testing specifically std.Io.Threaded
        // with disable_memory_mapping = true.
        var mm = try file.createMemoryMap(io, .{ .len = "this is my data123".len + 3 });
        defer mm.destroy(io);

        try testing.expectEqualStrings("this is my data123\x00\x00\x00", mm.memory);
        mm.memory[4] = '9';
        mm.memory[7] = '9';

        try mm.write(io);
    }

    var buffer: [100]u8 = undefined;
    const updated_contents = try tmp.dir.readFile(io, "blah.txt", &buffer);
    try testing.expectEqualStrings("this9is9my data123\x00\x00\x00", updated_contents);

    {
        var file = try tmp.dir.openFile(io, "blah.txt", .{ .mode = .read_only });
        defer file.close(io);

        var mm = try file.createMemoryMap(io, .{
            .len = "this9is9my".len,
            .protection = .{ .read = true },
        });
        defer mm.destroy(io);

        try testing.expectEqualStrings("this9is9my", mm.memory);

        const new_len = "this9is9my data123".len;
        mm.setLength(io, new_len) catch |err| switch (err) {
            error.OperationUnsupported => {
                mm.destroy(io);
                mm = try file.createMemoryMap(io, .{ .len = new_len });
            },
            else => |e| return e,
        };
        try mm.read(io);

        try testing.expectEqualStrings("this9is9my data123", mm.memory);
    }
}
